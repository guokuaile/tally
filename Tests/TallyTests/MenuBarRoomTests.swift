import AppKit
import XCTest
@testable import Tally

/// 菜单栏给两翼留几格（docs/crew.md「让开菜单」）：14 寸 1512 / 663 / 664 / 32，菜单排到哪儿的数是真机量的。
final class MenuBarRoomTests: XCTestCase {
    let m14 = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), auxiliaryTopLeftWidth: 663, auxiliaryTopRightWidth: 664, safeAreaTop: 32)

    func testLeftRoomIsWhatFitsBetweenTheLastMenuAndTheNotch() {
        XCTAssertEqual(MenuBarRoom.room(menuEnd: 365, on: m14), CrewRoom(left: 9, right: .max), "Ghostty：菜单短，左翼不受限")
        XCTAssertEqual(MenuBarRoom.room(menuEnd: 511, on: m14), CrewRoom(left: 4, right: .max), "Thunderbird")
        XCTAssertEqual(MenuBarRoom.room(menuEnd: 592, on: m14), CrewRoom(left: 1, right: .max), "Chrome 中文菜单：只剩一格")
        XCTAssertEqual(MenuBarRoom.room(menuEnd: 651, on: m14), CrewRoom(left: 0, right: .max), "Sublime Text：一格都放不下，右翼照常")
    }

    func testBoundaryIsTheWingEdgeIncludingBothInsets() {
        // 一格的翼露在菜单栏上 16 + 31 = 47pt：菜单正好排到 663 − 47 放得下，多半个点就不行
        XCTAssertEqual(MenuBarRoom.room(menuEnd: 616, on: m14).left, 1)
        XCTAssertEqual(MenuBarRoom.room(menuEnd: 616.5, on: m14).left, 0)
        XCTAssertEqual(MenuBarRoom.room(menuEnd: 663, on: m14), CrewRoom(left: 0, right: .max), "排到刘海左缘为止还没折行")
    }

    func testMenusWrappedPastTheNotchLeaveNoRoomOnEitherSide() {
        XCTAssertEqual(MenuBarRoom.room(menuEnd: 663.5, on: m14), CrewRoom(left: 0, right: 0))
        XCTAssertEqual(MenuBarRoom.room(menuEnd: 930, on: m14), CrewRoom(left: 0, right: 0), "折到刘海右边的菜单紧贴刘海，右翼一格也会压住")
    }

    /// 算出来的格数和翼的真实位置对得上：放得下的那么多格不碰菜单，再多一格就碰。
    func testRoomAgreesWithWingGeometry() throws {
        for end in stride(from: CGFloat(300), through: 663, by: 7.5) {
            let slots = MenuBarRoom.room(menuEnd: end, on: m14).left
            if slots > 0 {
                let wing = try XCTUnwrap(CrewGeometry.wingFrame(side: .left, slots: slots, on: m14))
                XCTAssertGreaterThanOrEqual(wing.minX, end, "菜单排到 \(end)：\(slots) 格的左翼压住了菜单")
            }
            let wider = try XCTUnwrap(CrewGeometry.wingFrame(side: .left, slots: slots + 1, on: m14))
            XCTAssertLessThan(wider.minX, end, "菜单排到 \(end)：明明还放得下 \(slots + 1) 格")
        }
    }

    /// 各项的范围是别的进程报上来的：只认落在菜单栏里、有宽度的。
    func testMenuEndIsRelativeToTheBarAndIgnoresItemsThatCannotBeOnIt() {
        let bar: ClosedRange<CGFloat> = 0...1512
        XCTAssertEqual(MenuBarRoom.menuEnd(bar: bar, items: [10...44, 43...115, 545...592]), 592)
        XCTAssertEqual(MenuBarRoom.menuEnd(bar: bar, items: [10...44, 497...575, 858...945, 1223...1272]), 1272, "折到刘海右边的也算")
        XCTAssertEqual(MenuBarRoom.menuEnd(bar: bar, items: [10...44, 43...115, 900...900]), 115, "没宽度的项不算")
        XCTAssertEqual(MenuBarRoom.menuEnd(bar: bar, items: [10...44, 43...115, 5000...5080, -300 ... -200]), 115, "跑到菜单栏外面的项不算")
        XCTAssertEqual(MenuBarRoom.menuEnd(bar: 1512...3024, items: [1522...1556, 1555...1627]), 115, "另一块屏上的菜单栏：减掉它的左缘")
        XCTAssertNil(MenuBarRoom.menuEnd(bar: bar, items: []))
        XCTAssertNil(MenuBarRoom.menuEnd(bar: bar, items: [0...0]), "一项能算的都没有：当没读到")
    }

    func testUnreachableProcessReadsAsUnknown() {
        // macOS 的 pid 到不了 999999：没这个进程、没权限都是 nil，调用方这一轮不算
        XCTAssertNil(MenuBarRoom.menuEnd(pid: 999_999))
    }
}
