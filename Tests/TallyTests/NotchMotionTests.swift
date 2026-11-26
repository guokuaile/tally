import XCTest
@testable import Tally

final class NotchMotionTests: XCTestCase {
    private let closed = CGSize(width: 189, height: 32)
    private let opened = CGSize(width: 620, height: 545)

    func testOpenHasSmallReboundAndSettlesExactly() {
        var motion = NotchMotion(size: closed)
        motion.retarget(opened)
        var peak = closed.width
        for _ in 0..<120 {
            motion.advance(by: 1.0 / 120)
            peak = max(peak, motion.size.width)
        }
        XCTAssertGreaterThan(peak, opened.width)
        XCTAssertLessThan(peak, opened.width + 8)
        XCTAssertTrue(motion.isSettled)
        XCTAssertEqual(motion.size, opened)
        XCTAssertEqual(motion.velocity, .zero)
    }

    func testRapidReversalRetainsCurrentSizeAndVelocity() {
        var motion = NotchMotion(size: closed)
        motion.retarget(opened)
        motion.advance(by: 0.15)
        let size = motion.size, velocity = motion.velocity
        XCTAssertGreaterThan(velocity.width, 0)
        motion.retarget(closed)
        XCTAssertEqual(motion.size, size)
        XCTAssertEqual(motion.velocity, velocity)
        motion.advance(by: 1.0 / 240)
        XCTAssertGreaterThan(motion.size.width, size.width, "Reversal brakes existing momentum instead of jumping")
        motion.advance(by: 0.17)
        let reversingSize = motion.size, reversingVelocity = motion.velocity
        motion.retarget(opened)
        XCTAssertEqual(motion.size, reversingSize)
        XCTAssertEqual(motion.velocity, reversingVelocity)
        motion.advance(by: 2)
        XCTAssertEqual(motion.size, opened)
        XCTAssertTrue(motion.isSettled)
    }

    func testClosingAlwaysCoversCameraAndStaysTopCentered() {
        let screen = ScreenMetrics(frame: CGRect(x: 1440, y: 200, width: 1512, height: 982),
                                   auxiliaryTopLeftWidth: 663, auxiliaryTopRightWidth: 664, safeAreaTop: 32)
        var motion = NotchMotion(size: opened)
        motion.retarget(closed)
        for _ in 0..<120 {
            motion.advance(by: 1.0 / 120)
            let size = motion.visibleSize(minimum: closed)
            XCTAssertGreaterThanOrEqual(size.width, closed.width)
            XCTAssertGreaterThanOrEqual(size.height, closed.height)
            let frame = NotchGeometry.frame(for: size, on: screen)
            XCTAssertEqual(frame.midX, screen.frame.midX, accuracy: 0.001)
            XCTAssertEqual(frame.maxY, screen.frame.maxY, accuracy: 0.001)
        }
        XCTAssertEqual(motion.size, closed)
        XCTAssertTrue(motion.isSettled)
    }

    func testHeightChangesKeepWidthAndDoNotOvershoot() {
        var motion = NotchMotion(size: opened)
        let shorter = CGSize(width: opened.width, height: 260)
        motion.retarget(shorter, heightOnly: true)
        var previous = opened.height
        for _ in 0..<120 {
            motion.advance(by: 1.0 / 120)
            XCTAssertEqual(motion.size.width, opened.width)
            XCTAssertLessThanOrEqual(motion.size.height, previous)
            XCTAssertGreaterThanOrEqual(motion.size.height, shorter.height)
            previous = motion.size.height
        }
        XCTAssertEqual(motion.size, shorter)
    }

    func testInvalidClockIntervalsDoNotCorruptMotion() {
        var motion = NotchMotion(size: closed)
        motion.retarget(opened)
        for elapsed in [0.0, -1, .nan, .infinity] { motion.advance(by: elapsed) }
        XCTAssertEqual(motion.size, closed)
        XCTAssertEqual(motion.velocity, .zero)
        motion.advance(by: 30)
        XCTAssertEqual(motion.size, opened)
        XCTAssertTrue(motion.isSettled)
    }
}
