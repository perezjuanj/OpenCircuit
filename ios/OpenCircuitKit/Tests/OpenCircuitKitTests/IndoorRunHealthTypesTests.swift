import XCTest

/// #339, decision 84f: running speed and running stride length are asked LAZILY, each in its own one-type
/// request in `IndoorRunHealthWriter.swift`, the VO₂ max pattern (`HealthKitAuthorizationSurfaceTests`
/// explains why a second request must never name a type another request names). This pins the shape:
/// each request names exactly its type in `toShare` and reads nothing, and neither type is spelled in any
/// other app source (so neither can drift into `HealthKitWriter.allTypes`).
final class IndoorRunHealthTypesTests: XCTestCase {

    private func appSources() throws -> [StrippedSource] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let appDir = repoRoot.appendingPathComponent("ios/OpenCircuit")
        let all = try FileManager.default.subpathsOfDirectory(atPath: appDir.path).filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(all.count, 40, "too few sources: FIX THE AUDIT rather than let it pass vacuously")
        return try all.map {
            StrippedSource(name: ($0 as NSString).lastPathComponent,
                           text: try String(contentsOf: appDir.appendingPathComponent($0), encoding: .utf8))
        }
    }

    private func count(_ pattern: String, in source: StrippedSource) throws -> Int {
        let re = try NSRegularExpression(pattern: pattern)
        return re.numberOfMatches(in: source.flat, range: NSRange(location: 0, length: (source.flat as NSString).length))
    }

    func testEachLazyRunningMetricRequestNamesOnlyItsOwnTypeAndReadsNothing() throws {
        let sources = try appSources()
        guard let writer = sources.first(where: { $0.name == "IndoorRunHealthWriter.swift" }) else {
            return XCTFail("IndoorRunHealthWriter.swift not found under ios/OpenCircuit — FIX THE AUDIT")
        }
        XCTAssertEqual(try count(#"requestAuthorization\s*\(\s*toShare\s*:\s*\[\s*Self\.runningSpeedType\s*\]\s*,\s*read\s*:\s*\[\s*\]\s*\)"#, in: writer), 1)
        XCTAssertEqual(try count(#"requestAuthorization\s*\(\s*toShare\s*:\s*\[\s*Self\.runningStrideLengthType\s*\]\s*,\s*read\s*:\s*\[\s*\]\s*\)"#, in: writer), 1)
        XCTAssertEqual(try count(#"requestAuthorization\s*\(\s*toShare\s*:"#, in: writer), 2, "no third request in this file")
        XCTAssertEqual(try count(#"HKQuantityType\(\s*\.runningSpeed\s*\)"#, in: writer), 1)
        XCTAssertEqual(try count(#"HKQuantityType\(\s*\.runningStrideLength\s*\)"#, in: writer), 1)
    }

    func testNeitherRunningMetricTypeIsNamedAnywhereElseInTheApp() throws {
        let pattern = #"HKQuantityType\s*\(\s*\.running(Speed|StrideLength)\b|HKQuantityTypeIdentifier\s*\.\s*running(Speed|StrideLength)\b|HKQuantityTypeIdentifierRunning(Speed|StrideLength)|\b(runningSpeedType|runningStrideLengthType)\b"#
        let elsewhere = try appSources().filter { $0.name != "IndoorRunHealthWriter.swift" }
            .filter { try count(pattern, in: $0) > 0 }.map(\.name)
        XCTAssertEqual(elsewhere, [], "running speed / stride length must stay out of every other request (the build-50 rule)")
    }
}
