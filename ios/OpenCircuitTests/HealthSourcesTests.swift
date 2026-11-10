// Sources & methods (App Review 1.4.1): every topic the app links to has a method line and at least
// one citation with a stable https link, and opening on a topic puts it first without losing any.

import XCTest
@testable import OpenCircuit

final class HealthSourcesTests: XCTestCase {

    func testEveryTopicHasExactlyOneSourceWithCitations() {
        for topic in HealthSourceTopic.allCases {
            let matches = HealthSources.all.filter { $0.topic == topic }
            XCTAssertEqual(matches.count, 1, "\(topic) must appear once")
            guard let source = matches.first else { continue }
            XCTAssertFalse(source.title.isEmpty, "\(topic) title")
            XCTAssertGreaterThan(source.method.count, 40, "\(topic) needs a method line")
            XCTAssertFalse(source.citations.isEmpty, "\(topic) needs at least one citation")
        }
        XCTAssertEqual(HealthSources.all.count, HealthSourceTopic.allCases.count)
    }

    func testEveryCitationLinksToADOIOrPubMedRecord() {
        for source in HealthSources.all {
            for citation in source.citations {
                XCTAssertEqual(citation.url.scheme, "https", citation.text)
                XCTAssertTrue(["doi.org", "pubmed.ncbi.nlm.nih.gov"].contains(citation.url.host() ?? ""),
                              citation.text)
                XCTAssertGreaterThan(citation.url.path().count, 3, citation.text)
                XCTAssertTrue(citation.text.contains("("), "\(citation.text) should carry its year")
            }
        }
    }

    func testFocusPutsTheTopicFirstAndKeepsTheRest() {
        for topic in HealthSourceTopic.allCases {
            let ordered = HealthSources.ordered(focus: topic)
            XCTAssertEqual(ordered.first?.topic, topic)
            XCTAssertEqual(Set(ordered.map(\.topic)), Set(HealthSourceTopic.allCases))
            XCTAssertEqual(ordered.count, HealthSourceTopic.allCases.count)
        }
        XCTAssertEqual(HealthSources.ordered(focus: nil).map(\.topic), HealthSources.all.map(\.topic))
    }

    func testEveryTodayMetricDetailLinksToASource() {
        for metric in TodayTile.Metric.allCases {
            let topic = MetricDetailView.sourceTopic(metric)
            XCTAssertTrue(HealthSources.all.contains { $0.topic == topic }, "\(metric)")
        }
    }

    func testCopyStaysClearOfDiagnosticClaims() {
        let banned = ["diagnose", "detects", "apnea", "blood pressure", "medical-grade"]
        let text = ([HealthSources.intro] + HealthSources.all.flatMap { [$0.title, $0.method] })
            .joined(separator: " ").lowercased()
        for word in banned {
            XCTAssertFalse(text.contains(word), "copy must not say \(word)")
        }
    }
}
