import XCTest
@testable import OpenCircuitKit

final class FirmwareInfoTests: XCTestCase {

    // MARK: - Generation detection

    func testGen1Prefix() {
        var info = FirmwareInfo()
        info.version = "FR01.010"
        XCTAssertEqual(info.generation, .gen1)
    }

    func testGen2Prefix() {
        var info = FirmwareInfo()
        info.version = "FR02.018"
        XCTAssertEqual(info.generation, .gen2)
    }

    func testGen2AirPrefix() {
        var info = FirmwareInfo()
        info.version = "FR04.003"
        XCTAssertEqual(info.generation, .gen2Air)
    }

    func testGen3Prefix() {
        var info = FirmwareInfo()
        info.version = "FR05.008"   // RingConn Gen3-C384
        XCTAssertEqual(info.generation, .gen3)
    }

    func testUnknownPrefix() {
        var info = FirmwareInfo()
        info.version = "FR99.001"
        XCTAssertEqual(info.generation, .unknown)
    }

    func testEmptyVersionIsUnknown() {
        let info = FirmwareInfo()
        XCTAssertEqual(info.generation, .unknown)
    }

    // MARK: - hasFirmwareMismatch

    func testExactPinnedVersionNoMismatch() {
        var info = FirmwareInfo()
        info.version = FirmwareInfo.pinnedVersion   // "FR02.018"
        XCTAssertFalse(info.hasFirmwareMismatch)
    }

    func testVersionStartingWithPinnedNoMismatch() {
        var info = FirmwareInfo()
        info.version = "FR02.018.extra"
        XCTAssertFalse(info.hasFirmwareMismatch)
    }

    func testDifferentVersionMismatch() {
        var info = FirmwareInfo()
        info.version = "FR02.020"
        XCTAssertTrue(info.hasFirmwareMismatch)
    }

    func testGen1VersionMismatch() {
        var info = FirmwareInfo()
        info.version = "FR01.010"
        XCTAssertTrue(info.hasFirmwareMismatch)
    }

    func testEmptyVersionNoMismatch() {
        let info = FirmwareInfo()
        // Empty version → we haven't read DIS yet; must not report mismatch.
        XCTAssertFalse(info.hasFirmwareMismatch)
    }

    // MARK: - MAC formatting

    func testMACStoredAndReadBack() {
        let mac = "AA:BB:CC:DD:EE:FF"
        var info = FirmwareInfo()
        info.mac = mac
        XCTAssertEqual(info.mac, mac)
    }

    func testNilMACByDefault() {
        let info = FirmwareInfo()
        XCTAssertNil(info.mac)
    }

    // MARK: - Equatable

    func testEqualInfos() {
        let a = FirmwareInfo(version: "FR02.018", modelName: "RingConn",
                             manufacturer: "RingConn", hardwareRevision: "1.0",
                             mac: "AA:BB:CC:DD:EE:FF")
        let b = FirmwareInfo(version: "FR02.018", modelName: "RingConn",
                             manufacturer: "RingConn", hardwareRevision: "1.0",
                             mac: "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(a, b)
    }
}
