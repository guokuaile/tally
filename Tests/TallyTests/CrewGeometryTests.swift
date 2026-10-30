import AppKit
import XCTest
@testable import Tally

/// 翅膀的几何（docs/crew.md「翅膀」）：14 寸 1512 / 663 / 664 / 32。
final class CrewGeometryTests: XCTestCase {
    let m14 = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), auxiliaryTopLeftWidth: 663, auxiliaryTopRightWidth: 664, safeAreaTop: 32)

    func testWingFramesHugThePhysicalNotch() {
        XCTAssertEqual(CrewGeometry.wingFrame(side: .right, slots: 3, on: m14), CGRect(x: 836, y: 950, width: 121, height: 32), "从刘海右缘往里 12 起")
        XCTAssertEqual(CrewGeometry.wingFrame(side: .left, slots: 3, on: m14), CGRect(x: 554, y: 950, width: 121, height: 32), "到刘海左缘往里 12 止")
        XCTAssertEqual(CrewGeometry.wingFrame(side: .right, slots: 1, on: m14)?.width, 59)
        XCTAssertEqual(CrewGeometry.wingFrame(side: .left, slots: 1, on: m14), CGRect(x: 616, y: 950, width: 59, height: 32))
        XCTAssertNil(CrewGeometry.wingFrame(side: .right, slots: 0, on: m14), "空翼不上屏")
        let external = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), auxiliaryTopLeftWidth: 0, auxiliaryTopRightWidth: 0, safeAreaTop: 0)
        XCTAssertNil(CrewGeometry.wingFrame(side: .right, slots: 3, on: external), "没有刘海就没有翅膀")
    }

    func testWingWidthFollowsOccupiedSlotsNotTheLimit() {
        XCTAssertEqual(CrewGeometry.wingWidth(slots: 0), 0)
        XCTAssertEqual(CrewGeometry.wingWidth(slots: 1), 59)
        XCTAssertEqual(CrewGeometry.wingWidth(slots: 3), 121)
        XCTAssertEqual(CrewGeometry.wingWidth(slots: 4), 152)
    }

    func testClosedPanelOverlapsBothWingsSoTheSeamIsPanelBlack() throws {
        let closed = try XCTUnwrap(NotchGeometry.closedSize(m14))
        let panel = NotchGeometry.frame(for: closed, on: m14)
        let right = try XCTUnwrap(CrewGeometry.wingFrame(side: .right, slots: 2, on: m14))
        let left = try XCTUnwrap(CrewGeometry.wingFrame(side: .left, slots: 2, on: m14))
        XCTAssertGreaterThan(panel.maxX, right.minX)
        XCTAssertLessThan(panel.minX, left.maxX)
        XCTAssertGreaterThanOrEqual(panel.maxX - right.minX, NotchGeometry.closedBottomRadius, "翼伸到面板底角整段圆弧底下，缝填黑")
        XCTAssertGreaterThanOrEqual(left.maxX - panel.minX, NotchGeometry.closedBottomRadius)
        XCTAssertEqual(panel.minY, right.minY)
        XCTAssertEqual(panel.height, right.height)
    }

    func testSlotCentersCountFromTheNotchOutward() {
        XCTAssertEqual(CrewGeometry.slotCenterX(side: .right, index: 0, slots: 3), 35.5)
        XCTAssertEqual(CrewGeometry.slotCenterX(side: .right, index: 2, slots: 3), 97.5)
        XCTAssertEqual(CrewGeometry.slotCenterX(side: .left, index: 0, slots: 3), 85.5, "左翼第 0 格靠刘海，在翼的右边")
        XCTAssertEqual(CrewGeometry.slotCenterX(side: .left, index: 2, slots: 3), 23.5)
    }

    func testSlotHitTestingIgnoresTheMargins() {
        XCTAssertNil(CrewGeometry.slot(atX: 16, side: .right, slots: 3), "刘海底下和内边距不算格")
        XCTAssertEqual(CrewGeometry.slot(atX: 22, side: .right, slots: 3), 0)
        XCTAssertEqual(CrewGeometry.slot(atX: 35.5, side: .right, slots: 3), 0)
        XCTAssertEqual(CrewGeometry.slot(atX: 62, side: .right, slots: 3), 1)
        XCTAssertEqual(CrewGeometry.slot(atX: 110.9, side: .right, slots: 3), 2)
        XCTAssertNil(CrewGeometry.slot(atX: 113, side: .right, slots: 3), "外侧边距不算格")
        XCTAssertEqual(CrewGeometry.slot(atX: 85.5, side: .left, slots: 3), 0)
        XCTAssertEqual(CrewGeometry.slot(atX: 23.5, side: .left, slots: 3), 2)
        XCTAssertNil(CrewGeometry.slot(atX: 114, side: .left, slots: 3))
        for x: CGFloat in [49, 50.9, 51, 52.9] {
            XCTAssertNil(CrewGeometry.slot(atX: x, side: .right, slots: 3), "右翼相邻点击区之间留空")
        }
        for x: CGFloat in [68, 69.9, 70, 71.9] {
            XCTAssertNil(CrewGeometry.slot(atX: x, side: .left, slots: 3), "左翼相邻点击区之间留空")
        }
        XCTAssertNil(CrewGeometry.slot(atX: 20, side: .right, slots: 0))
    }

    func testSlotRectIsFullHeightAndCentred() {
        let rect = CrewGeometry.slotRect(side: .right, index: 1, slots: 3, height: 32)
        XCTAssertEqual(rect, CGRect(x: 51, y: 0, width: 31, height: 32))
    }

    func testPlaybackLoopsEveryMoodAndStillPicksTheFrozenFrame() {
        for mood in CrewMood.allCases {
            let playing = CrewPlayback.clip(mood: mood, elapsed: 7, still: false)
            XCTAssertEqual(playing.clip, mood.clip, "\(mood)")
            XCTAssertEqual(playing.time, 7, "\(mood)")
            XCTAssertTrue(playing.loop, "\(mood)")
        }
        let done = CrewPlayback.clip(mood: .done, elapsed: 9, still: false)
        XCTAssertEqual(done.clip, "crew-done", "完成和预览一样一遍遍拖彗尾、闪绿环，没有打盹片段")
        XCTAssertTrue(done.loop)
        let still = CrewPlayback.clip(mood: .permission, elapsed: 3, still: true)
        XCTAssertEqual(still.clip, "crew-permission")
        XCTAssertEqual(still.time, 1.6)
        XCTAssertFalse(still.loop)
        let stillDone = CrewPlayback.clip(mood: .done, elapsed: 1, still: true)
        XCTAssertEqual(stillDone.clip, "crew-done")
        XCTAssertEqual(stillDone.time, 3.0, "预览定格页 STILL.done")
    }

    func testStripOutlineRoundsOnlyTheOuterBottomCorner() {
        let right = CrewGeometry.outline(side: .right, size: CGSize(width: 109, height: 32))
        XCTAssertTrue(right.contains(CGPoint(x: 1, y: 31)), "内侧底角是直角")
        XCTAssertFalse(right.contains(CGPoint(x: 108, y: 31)), "外侧底角切圆")
        let left = CrewGeometry.outline(side: .left, size: CGSize(width: 109, height: 32))
        XCTAssertTrue(left.contains(CGPoint(x: 108, y: 31)))
        XCTAssertFalse(left.contains(CGPoint(x: 1, y: 31)))
    }
}
