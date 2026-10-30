import XCTest
@testable import Tally

final class QuotaBarRenderingTests: XCTestCase {
    func testWaitingExpressionsRemainAboveRightWithEyesPreserved() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let art = try XCTUnwrap(BloubArt(url: root.appendingPathComponent("Resources/bloub/frames.json")))
        for mood in [SessionEyes.Mood.permission, .input] {
            let expected: BloubArt.ExpressionSymbol = mood == .permission ? .approval : .question
            let clip = try XCTUnwrap(art.clips[mood.rawValue])
            let frames = clip.frames
            XCTAssertEqual(Double(frames.count) / clip.fps, 4, accuracy: 0.001)
            XCTAssertTrue(frames.allSatisfy { !$0.body.isEmpty && !$0.eyes.isEmpty && $0.alpha == 1 })
            XCTAssertTrue(frames.allSatisfy { $0.symbol == expected })
            XCTAssertTrue(frames.allSatisfy { $0.symbolAnchor.x > 100 && $0.symbolAnchor.y < -70 })
            XCTAssertTrue(frames.allSatisfy { $0.eyes.contains { $0.opacity > 0 } })
            for (current, next) in zip(frames, frames.dropFirst() + [frames[0]]) {
                XCTAssertLessThan(abs(current.symbolAnchor.y - next.symbolAnchor.y), 1)
                XCTAssertLessThan(abs(current.body.boundingRect.width - next.body.boundingRect.width), 12)
                XCTAssertLessThan(abs(current.body.boundingRect.minY - next.body.boundingRect.minY), 12)
            }
            XCTAssertTrue(frames.allSatisfy { ($0.notif != nil) == (mood == .permission) })
            if mood == .permission {
                XCTAssertTrue(frames.allSatisfy { ($0.notif?.boundingRect.maxX ?? 0) < 0 })
            }
            let still = try XCTUnwrap(art.frame(mood: mood, time: 0, still: true))
            XCTAssertEqual(still.symbol, expected)
            XCTAssertGreaterThan(still.symbolAnchor.x, 100)
            XCTAssertFalse(still.body.isEmpty)
        }
        XCTAssertNotEqual(art.frame(mood: .permission, time: 1)?.body, art.frame(mood: .input, time: 1)?.body)
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

    func testBloubKeepsBodyRotationDepthSortedOrbitsAndParticles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let art = try XCTUnwrap(BloubArt(url: root.appendingPathComponent("Resources/bloub/frames.json")))
        let orbit = try XCTUnwrap(art.frame(mood: .working, time: 3))
        let rotated = try XCTUnwrap(art.frame(mood: .working, time: 3.2))
        XCTAssertEqual(orbit.arcs.count, 6)
        XCTAssertNotEqual(orbit.body, rotated.body)
        XCTAssertTrue(orbit.arcs.allSatisfy { !$0.front.isEmpty && !$0.back.isEmpty })
        let burst = try XCTUnwrap(art.frame(mood: .compacting, time: 0.5))
        XCTAssertFalse(burst.dots.isEmpty)
        XCTAssertTrue(burst.dotsBehind)
        for mood in SessionEyes.Mood.allCases where mood != .sleeping {
            let clip = try XCTUnwrap(art.clips[mood.rawValue])
            let frames = clip.frames
            XCTAssertFalse(frames.isEmpty)
            let loop = try XCTUnwrap(art.frame(mood: mood, time: Double(frames.count)/clip.fps))
            XCTAssertEqual(loop.body, frames[0].body)
        }
        XCTAssertNil(art.clips[SessionEyes.Mood.sleeping.rawValue], "Closed sessions use static dots, not an animation clip")
        XCTAssertNil(BloubArt(url: root.appendingPathComponent("Resources/missing-bloub.json")))
    }
}
