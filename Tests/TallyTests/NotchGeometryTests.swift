import XCTest
@testable import Tally

final class NotchGeometryTests: XCTestCase {

    /// 本机 14 寸 M3 Max 的实测参数。
    private let builtIn14 = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        auxiliaryTopLeftWidth: 663,
        auxiliaryTopRightWidth: 664,
        safeAreaTop: 32
    )

    func testClosedSizeOn14Inch() {
        XCTAssertEqual(NotchGeometry.closedSize(builtIn14), CGSize(width: 189, height: 32))
    }

    func testOpenHeightFollowsContentWithinBounds() {
        XCTAssertEqual(NotchGeometry.openHeight(content: 10, screenHeight: 982), 160, "小内容也不低于下限")
        XCTAssertEqual(NotchGeometry.openHeight(content: 200, screenHeight: 982), 256, "正常就是内容加固定部分")
        XCTAssertEqual(NotchGeometry.openHeight(content: 2000, screenHeight: 982), 589, "上限是屏幕高的六成")
    }

    func testPillsFitBelowNotchWithSeparateWindows() {
        let first = PillNotificationPanel.placementFrame(in: builtIn14.frame, safeAreaTop: builtIn14.safeAreaTop, index: 0)
        let second = PillNotificationPanel.placementFrame(in: builtIn14.frame, safeAreaTop: builtIn14.safeAreaTop, index: 1)
        XCTAssertEqual(first.width, 320)
        XCTAssertEqual(first.height, 44)
        XCTAssertEqual(first.midX, builtIn14.frame.midX)
        XCTAssertEqual(first.maxY, builtIn14.frame.maxY - 32 - 6)
        XCTAssertEqual(first.minY - second.maxY, 6)
        let narrow = PillNotificationPanel.placementFrame(in: CGRect(x: 0, y: 0, width: 250, height: 600), safeAreaTop: 32, index: 0)
        XCTAssertEqual(narrow.width, 218)
        XCTAssertEqual(narrow.minX, 16)
        let badge = PillNotificationPanel.placementFrame(in: builtIn14.frame, safeAreaTop: 32, offset: -6, width: 300, height: 370, rightAligned: true)
        let afterBadge = PillNotificationPanel.placementFrame(in: builtIn14.frame, safeAreaTop: 32, offset: 370, width: 320, height: 44)
        XCTAssertEqual(badge.height, 370)
        XCTAssertEqual(badge.maxX, builtIn14.frame.maxX - 16)
        let x = PillNotificationPanel.badgeX(in: builtIn14.frame, width: 300, leftWidth: 663, rightWidth: 664, right: true)
        XCTAssertEqual(x + 150, 888, "挂点在刘海右边缘外侧 40pt")
        let leftX = PillNotificationPanel.badgeX(in: builtIn14.frame, width: 300, leftWidth: 663, rightWidth: 664, right: false)
        XCTAssertEqual(leftX + 150, 623)
        XCTAssertEqual(badge.maxY, builtIn14.frame.maxY - 32, "第一张工牌的挂带贴着刘海")
        XCTAssertEqual(badge.minY - afterBadge.maxY, 6, "不同高度的提示不重叠")
    }

    func testCrewDropdownStaysOnScreenAndCapsHeight() {
        let screen = builtIn14.frame
        let frame = CrewDropdownPanel.frame(anchorX: 2, top: 950, screen: screen, count: 20)
        XCTAssertEqual(frame.minX, 8)
        XCTAssertEqual(frame.maxY, 950)
        XCTAssertEqual(frame.height, 240)
        let right = CrewDropdownPanel.frame(anchorX: 1511, top: 950, screen: screen, count: 1)
        XCTAssertEqual(right.maxX, screen.maxX - 8)
        let anchoredRight = CrewDropdownPanel.frame(anchorX: 850, top: 950, screen: screen, count: 2, side: .right)
        let anchoredLeft = CrewDropdownPanel.frame(anchorX: 650, top: 950, screen: screen, count: 2, side: .left)
        XCTAssertEqual(anchoredRight.minX + 29, 850)
        XCTAssertEqual(anchoredLeft.maxX - 29, 650)
    }

    func testBadgeHitRegionExcludesTransparentMargins() {
        let size = CGSize(width: 300, height: 370)
        XCTAssertTrue(PillNotificationPanel.badgeContains(CGPoint(x: 150, y: 100), in: size))
        XCTAssertTrue(PillNotificationPanel.badgeContains(CGPoint(x: 150, y: 350), in: size))
        XCTAssertFalse(PillNotificationPanel.badgeContains(CGPoint(x: 5, y: 100), in: size))
        XCTAssertFalse(PillNotificationPanel.badgeContains(CGPoint(x: 20, y: 100), in: size))
        XCTAssertTrue(PillNotificationPanel.badgeContains(CGPoint(x: 20, y: 100), in: size, entering: true), "摆动期间给卡片暂留运动余量")
        XCTAssertFalse(PillNotificationPanel.badgeContains(CGPoint(x: 150, y: 5), in: size))
        XCTAssertFalse(PillNotificationPanel.badgeContains(CGPoint(x: 30, y: 360), in: size))
    }

    func testHeaderGapCoversNotchWithMargin() {
        XCTAssertEqual(NotchGeometry.headerGap(closedWidth: 189), 197)
    }

    func testPinnedClickClosesOnlyOnTheNotch() {
        let panel = CGSize(width: NotchGeometry.openWidth, height: 300)
        let notch = CGSize(width: 189, height: 32)
        XCTAssertTrue(NotchGeometry.hitsNotch(CGPoint(x: 310, y: 290), panelSize: panel, notch: notch), "刘海正中")
        XCTAssertTrue(NotchGeometry.hitsNotch(CGPoint(x: 310 + 98, y: 270), panelSize: panel, notch: notch), "刘海那段的边上也算")
        XCTAssertFalse(NotchGeometry.hitsNotch(CGPoint(x: 100, y: 290), panelSize: panel, notch: notch), "左边的页签")
        XCTAssertFalse(NotchGeometry.hitsNotch(CGPoint(x: 520, y: 290), panelSize: panel, notch: notch), "右边的按钮")
        XCTAssertFalse(NotchGeometry.hitsNotch(CGPoint(x: 310, y: 200), panelSize: panel, notch: notch), "刘海下面的页内容")
    }

    func testNoNotchReturnsNil() {
        var external = builtIn14
        external.safeAreaTop = 0
        XCTAssertNil(NotchGeometry.closedSize(external))
    }

    func testFrameIsTopCentered() {
        let frame = NotchGeometry.frame(for: CGSize(width: 189, height: 32), on: builtIn14)
        XCTAssertEqual(frame.midX, 756, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, 982, accuracy: 0.001)
        XCTAssertEqual(frame.size, CGSize(width: 189, height: 32))
    }

    func testOpenFrameStaysAnchoredWhenScreenIsOffset() {
        // 外接屏排在左边时内建屏的 frame 原点不在 0，锚点仍要跟着内建屏走。
        var offset = builtIn14
        offset.frame = CGRect(x: 2560, y: -100, width: 1512, height: 982)
        let frame = NotchGeometry.frame(for: CGSize(width: NotchGeometry.openWidth, height: 320), on: offset)
        XCTAssertEqual(frame.midX, 2560 + 756, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, 882, accuracy: 0.001)
    }
}
