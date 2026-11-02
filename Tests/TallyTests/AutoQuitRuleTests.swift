import AppKit
import ApplicationServices
import XCTest
@testable import Tally

/// 关窗自动退出的判定、列表清洗、起停与辅助功能数窗口的口径（docs/monitors.md「关窗自动退出」）。
final class AutoQuitRuleTests: XCTestCase {

    func testQuitsOnlyWhenEmptyTwiceAndNotFrontmost() {
        XCTAssertFalse(AutoQuitRule.shouldQuit(windows: 1, frontmost: false, previousEmpty: true), "有窗口不退")
        XCTAssertFalse(AutoQuitRule.shouldQuit(windows: 0, frontmost: true, previousEmpty: true), "在前台不退：可能正要 ⌘O")
        XCTAssertFalse(AutoQuitRule.shouldQuit(windows: 0, frontmost: false, previousEmpty: false), "第一次为零不退：关窗动画、刚启动")
        XCTAssertTrue(AutoQuitRule.shouldQuit(windows: 0, frontmost: false, previousEmpty: true))
    }

    func testListIsTrimmedAndDeduplicated() {
        XCTAssertEqual(Preferences.autoQuitList([" com.apple.Preview ", "", "com.apple.Preview", "com.apple.TextEdit"]),
                       ["com.apple.Preview", "com.apple.TextEdit"])
    }

    @MainActor
    func testWatcherAttachesAndStops() {
        let watcher = AutoQuitWatcher.shared
        let neverRunning = ["com.aiden.tally.tests.never-running"]
        watcher.apply(enabled: true, bundleIdentifiers: neverRunning)
        XCTAssertTrue(watcher.isWatching, "开着就挂上启停通知")
        XCTAssertFalse(watcher.isSampling, "列表里的 app 没在跑不起定时器")
        watcher.apply(enabled: false, bundleIdentifiers: neverRunning)
        XCTAssertFalse(watcher.isWatching, "关掉全摘")
        watcher.apply(enabled: true, bundleIdentifiers: [])
        XCTAssertFalse(watcher.isWatching, "开着但列表为空等于关")
    }

    /// 在自己进程上验口径：显示 +1、最小化不变、关掉回原值。要辅助功能权限（跑测试的终端有就行），没有就跳过。
    @MainActor
    func testAccessibilityCountsShownAndMinimizedButNotClosedWindows() throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "跑测试的进程没有辅助功能权限")
        // xctest 没走 NSApplicationMain，自己进程的辅助功能服务要 finishLaunching 之后才应答（之前一律 cannotComplete）；accessory 不占 Dock
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        let pid = ProcessInfo.processInfo.processIdentifier
        let before = try XCTUnwrap(AutoQuitWatcher.windowCount(pid: pid))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 200),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        settle()
        XCTAssertEqual(AutoQuitWatcher.windowCount(pid: pid), before + 1, "显示出来的算")
        window.miniaturize(nil)
        settle()
        XCTAssertEqual(AutoQuitWatcher.windowCount(pid: pid), before + 1, "最小化的也算：CGWindowList 分不出这一条")
        // 不先 deminiaturize：还原动画是异步的，紧接着 orderOut 不生效；关掉最小化的窗口直接从列表里消失
        window.close()
        settle()
        XCTAssertEqual(AutoQuitWatcher.windowCount(pid: pid), before, "关掉的、没显示过的不算")
    }

    /// 窗口状态变化要过一趟 run loop 才反映到辅助功能树上。
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
}
