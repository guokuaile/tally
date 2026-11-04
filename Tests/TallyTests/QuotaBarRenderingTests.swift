import XCTest
@testable import Tally

final class QuotaBarRenderingTests: XCTestCase {
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
