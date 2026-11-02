import AppKit
import ApplicationServices
import Observation

/// 退不退，纯函数。
enum AutoQuitRule {

    /// 没窗口、不在前台、上一次采样也没窗口，三者齐了才退。「不在前台」防关完最后一张图正要 ⌘O 时被抢；
    /// 「连续两次」滤掉关窗动画期间的瞬时零，也给刚启动、窗口还没出来的 app 留 3 到 6 秒。
    static func shouldQuit(windows: Int, frontmost: Bool, previousEmpty: Bool) -> Bool {
        windows == 0 && !frontmost && previousEmpty
    }
}

/// 列表里的 app 关掉最后一个窗口、切走之后替它 ⌘Q（docs/monitors.md「关窗自动退出」）。
/// macOS 关掉最后一个窗口不退出 app，预览这类看完就关的一直留在 Dock 里；新版预览不再声明 `NSSupportsAutomaticTermination`，系统也不替它回收。
/// 只挂 app 启停通知，列表里有 app 在跑才起 3 秒定时器。数窗口走辅助功能 API：CGWindowList 分不出「最小化的真窗口」和
/// 「从未显示过的隐藏窗」，预览没内容时它仍报 5 个 layer 0 窗口。关掉就全摘。
@MainActor
@Observable
final class AutoQuitWatcher {

    static let shared = AutoQuitWatcher()

    /// 有没有辅助功能权限，设置页据此出「去授权」。每次采样和设置页出现时刷新，勾完不用重启。
    private(set) var trusted = AXIsProcessTrusted()

    private var targets: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    /// 上一次采样时没窗口的目标（pid）。
    private var emptyLastTime: Set<pid_t> = []

    /// 幂等：设置每次变化都调。
    func apply(enabled: Bool, bundleIdentifiers: [String]) {
        targets = enabled ? Set(bundleIdentifiers) : []
        guard !targets.isEmpty else { return stop() }
        if observers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            observers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.syncTimer() }
                }
            }
        }
        syncTimer()
    }

    /// 测试用：通知挂着没有、定时器在不在跑。
    var isWatching: Bool { !observers.isEmpty }
    var isSampling: Bool { timer != nil }

    func refreshTrust() {
        trusted = AXIsProcessTrusted()
    }

    /// 「去授权」：系统弹框并把 Tally 加进「辅助功能」列表，人勾一下。
    func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
    }

    private func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        timer?.invalidate()
        timer = nil
        emptyLastTime = []
    }

    /// 列表里在跑的 app。
    private var running: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in app.bundleIdentifier.map(targets.contains) ?? false }
    }

    /// 列表里有 app 在跑才起定时器，全退了就停：没人在跑时零开销。
    private func syncTimer() {
        if running.isEmpty {
            timer?.invalidate()
            timer = nil
            emptyLastTime = []
        } else if timer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            timer.tolerance = 0.5
            self.timer = timer
            tick()
        }
    }

    private func tick() {
        trusted = AXIsProcessTrusted()
        guard trusted else { return }
        var empty: Set<pid_t> = []
        for app in running where app.isFinishedLaunching {
            let pid = app.processIdentifier
            // 拿不到（对方没响应）这一轮不算，下一轮再看
            guard let windows = Self.windowCount(pid: pid) else { continue }
            if AutoQuitRule.shouldQuit(windows: windows, frontmost: app.isActive, previousEmpty: emptyLastTime.contains(pid)) {
                Log.debug("关窗自动退出：\(app.localizedName ?? app.bundleIdentifier ?? "\(pid)") 没有窗口且不在前台")
                app.terminate()
            } else if windows == 0 {
                empty.insert(pid)
            }
        }
        emptyLastTime = empty
    }

    /// 辅助功能报的窗口数：已显示、最小化、⌘H 隐藏的都算，从未显示过的隐藏窗不算。没权限、对方没响应返回 nil。
    nonisolated static func windowCount(pid: pid_t) -> Int? {
        let element = AXUIElementCreateApplication(pid)
        // 对方卡死时别把 Tally 的主线程一起拖住
        AXUIElementSetMessagingTimeout(element, 1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success else { return nil }
        return (value as? [AXUIElement])?.count ?? 0
    }
}
