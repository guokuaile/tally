import XCTest
@testable import Tally

final class QuotaBarRenderingTests: XCTestCase {
    @MainActor
    func testInsertedModelQuotaDoesNotReuseTotalWindowIdentity() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let total = UsageLimit(used: 61, limit: 100)
        let before = UsageStripRow(provider: .claude, result: .success(UsageSnapshot(weekLimit: total)), now: now).weeklyLimits
        let model = ScopedLimit(label: "Fable", limit: UsageLimit(used: 23, limit: 100))
        let after = UsageStripRow(provider: .claude,
                                  result: .success(UsageSnapshot(weekLimit: total, scopedLimits: [model])), now: now).weeklyLimits
        let originalID = try XCTUnwrap(before.first).id
        XCTAssertNotEqual(try XCTUnwrap(after.first).id, originalID)
        XCTAssertEqual(try XCTUnwrap(after.last).id, originalID)
    }

    @MainActor
    func testQuotaIdentitySurvivesReorderingAndSeparatesTotalFromSameNamedModel() {
        let now = Date(timeIntervalSince1970: 1_000)
        let total = UsageLimit(used: 61, limit: 100)
        let a = ScopedLimit(label: ProviderID.claude.stripLabels.week, limit: UsageLimit(used: 23, limit: 100))
        let b = ScopedLimit(label: "Fable", limit: UsageLimit(used: 42, limit: 100))
        let before = UsageStripRow(provider: .claude,
                                   result: .success(UsageSnapshot(weekLimit: total, scopedLimits: [a, b])), now: now).weeklyLimits
        let after = UsageStripRow(provider: .claude,
                                  result: .success(UsageSnapshot(weekLimit: total, scopedLimits: [b, a])), now: now).weeklyLimits
        XCTAssertEqual(Set(before.map(\.id)).count, 3)
        XCTAssertEqual(before[0].id, after[1].id)
        XCTAssertEqual(before[1].id, after[0].id)
        XCTAssertEqual(before[2].id, after[2].id)
    }

    func testUsedQuotaMovesLeftToRightAndFinishesAtRightEndpoint() {
        let positions = [0.0, 0.18, 0.2, 0.61, 1].map { UsageTrackLayout(fraction: $0).usedWidth(394) }
        XCTAssertTrue(zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertEqual(positions.first, 0)
        XCTAssertEqual(positions.last, 394)
        XCTAssertEqual(positions[1], 394*0.18, accuracy: 0.001)
        XCTAssertEqual(UsageTrackLayout(fraction: -0.1).fraction, 0)
        XCTAssertEqual(UsageTrackLayout(fraction: .nan).fraction, 0)
    }

    func testEmptyAndExhaustedQuotaDoNotAnimate() {
        for fraction in [0.0, 1, 1.2] {
            let layout = UsageTrackLayout(fraction: fraction)
            XCTAssertFalse(layout.animates)
            XCTAssertNil(layout.highlight(width: 394, phase: 0.5))
        }
        XCTAssertEqual(UsageTrackLayout(fraction: 1.2).usedWidth(394), 394)
    }

    func testHighlightAlwaysStaysInsideReportedUsage() throws {
        for fraction in [0.001, 0.18, 0.61, 0.99] {
            let layout = UsageTrackLayout(fraction: fraction)
            for phase in [0.0, 0.25, 0.75, 1] {
                let highlight = try XCTUnwrap(layout.highlight(width: 394, phase: phase))
                XCTAssertGreaterThanOrEqual(highlight.lowerBound, 0)
                XCTAssertLessThanOrEqual(highlight.upperBound, layout.usedWidth(394))
                XCTAssertEqual(layout.usedWidth(394), 394*fraction)
            }
        }
    }
}
