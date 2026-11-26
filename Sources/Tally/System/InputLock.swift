import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Observation

/// 吞不吞，纯函数（docs/monitors.md「清洁锁」）。
enum InputLockRule {

    enum Mode: Equatable {
        /// 只吞按键，触控板照常。
        case keyboard
        /// 键盘和触控板都锁，光标也钉住。
        case all
    }

    enum Verdict: Equatable {
        case pass, swallow
        /// 解锁组合按下了：吞掉、记下，等松手。
        case chord
        case unlock
    }

    /// 解锁组合 ⌥⇧T，故意和 HotKeyCenter 那组一样（不用另记）；键和文案都放这儿，那边哪天改了热键，这里的提示也不会说错。
    static let chordKey = Int64(kVK_ANSI_T)
    static let chordLabel = "⌥⇧T"

    /// 到点自动解锁：擦一遍用不了两分钟，拦截器出了岔子也最多锁这么久。
    static let duration: TimeInterval = 120

    /// `CGEventType` 里没有名字的那一类：功能键（亮度、音量、播放）和鼠标按键状态都走它，靠子类型分。
    static let systemDefined: UInt32 = 14
    /// 功能键的子类型（NX_SUBTYPE_AUX_CONTROL_BUTTONS）。
    static let auxControlSubtype = 8

    /// 交给拦截器的事件种类。只锁键盘时不带指针事件：触控板的事件根本不经过回调，主线程再忙光标和点击也不卡。
    static func mask(for mode: Mode) -> CGEventMask {
        switch mode {
        case .keyboard:
            return [CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue, systemDefined]
                .reduce(0) { $0 | CGEventMask(1) << $1 }
        case .all:
            // 手势、压感这些类型没有公开的名字，逐个列会漏：全要
            return ~CGEventMask(0)
        }
    }

    /// 会带着光标走的事件：单纯移动，和按着键拖。全锁时吞掉它们还不够，光标在更底下那层就动了，要再拽回去。
    static func movesCursor(_ type: UInt32) -> Bool {
        [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains { $0.rawValue == type }
    }

    /// `auxSubtype` 只在 `systemDefined` 事件上有值；`chordHeld` 是解锁组合按下过、T 还没松开。
    static func verdict(type: UInt32, keyCode: Int64, modifiers: CGEventFlags, auxSubtype: Int?, chordHeld: Bool, mode: Mode) -> Verdict {
        switch type {
        case CGEventType.keyDown.rawValue:
            // 修饰键恰好是 ⌥⇧ 才算：多按一个都不算，抹布压住一片时不会误开。大写锁定和 fn 不在这四个里，开着也能解
            let held = modifiers.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
            return keyCode == chordKey && held == [.maskAlternate, .maskShift] ? .chord : .swallow
        case CGEventType.keyUp.rawValue:
            // 松开 T 才解锁，不看这时修饰键还在不在（先松哪个都行）。按下那一刻就拆拦截器的话，
            // 按住不放时系统补发的重复按下全漏出去：落到 ⌥⇧T 热键上开合面板，热键关着就打进前台 app
            return chordHeld && keyCode == chordKey ? .unlock : .swallow
        case CGEventType.flagsChanged.rawValue:
            return .swallow
        case systemDefined:
            return mode == .all || auxSubtype == auxControlSubtype ? .swallow : .pass
        default:
            return mode == .all ? .swallow : .pass
        }
    }

    /// 倒计时文案「1:47」。
    static func countdown(_ seconds: Int) -> String {
        "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

/// 清洁锁：擦键盘、触控板时把输入吞掉。一个挂在系统输入入口的事件拦截器，只在锁着的那两分钟里存在；
/// 归 Tally 进程所有，进程没了系统自动撤掉，不需要退出钩子。
@MainActor
@Observable
final class InputLock {

    static let shared = InputLock()

    /// 当前锁的是哪一档；没锁是 nil。
    private(set) var mode: InputLockRule.Mode?
    /// 剩余秒数，卡片上的倒计时。
    private(set) var remaining = 0
    /// 没锁成的原因，卡片上橙字说出来：不说就是「点了没反应」。
    private(set) var failure: String?
    /// 锁上、解开时通知控制器钉住 / 放开面板。
    var onChange: ((_ locked: Bool) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    /// 单调时钟：睡眠照算，改系统时间不受影响。兜底的倒计时不能被一次对时拖长。
    private var deadline = ContinuousClock.now
    /// 解锁组合按下过、T 还没松开。
    private var chordHeld = false
    /// 全锁时光标钉在这儿（上锁那一刻的位置，左上角原点）；只锁键盘时是 nil。
    private var anchor: CGPoint?

    func start(_ mode: InputLockRule.Mode) {
        stop()
        failure = nil
        // 演示模式只翻界面状态：录屏时点一下不该真把键盘锁上两分钟
        if !DemoMode.isOn {
            // 带提示：没勾就弹系统框并把 Tally 加进辅助功能列表
            let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            guard AXIsProcessTrustedWithOptions(prompt) else {
                failure = "要先给 Tally 辅助功能权限才能拦按键，勾完再点一次"
                return
            }
            // 密码框聚焦时系统把按键直送前台 app，不经过任何拦截器：这时候锁了也是假的
            guard !IsSecureEventInputEnabled() else {
                failure = "有密码框正等着输入，按键拦不住；先点一下别处再锁"
                return
            }
            // 挂在 HID 这一层的最前面：系统快捷键和 ⌥⇧T 热键都在它下游，还没机会生效
            guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: InputLockRule.mask(for: mode),
                                               callback: { _, type, event, _ in
                                                   // 源挂在主 run loop 上，回调就在主线程，但编译器不知道
                                                   MainActor.assumeIsolated { InputLock.shared.swallows(type, event) }
                                                       ? nil : Unmanaged.passUnretained(event)
                                               }, userInfo: nil) else {
                failure = "拦截器没建起来，键盘没锁"
                Log.error("清洁锁：事件拦截器创建失败")
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            // shortcut: 回调跑在主线程，主线程卡到系统判超时，拦截器会被停掉、接回来之前的事件漏出去；
            // 真遇到擦到一半漏键，把事件源挪到独立线程的 run loop
            // .commonModes：拖东西、开菜单时主 run loop 换了模式，拦截不能跟着停
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            tap = port
            self.source = source
        }
        anchor = mode == .all ? CGEvent(source: nil)?.location : nil
        self.mode = mode
        deadline = .now + .seconds(InputLockRule.duration)
        remaining = Int(InputLockRule.duration)
        // 按到期时刻对表而不是数次数：中途睡过一觉，醒来照样准。同样挂 .common
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.debug("清洁锁：锁上（\(mode == .all ? "键盘 + 触控板" : "键盘")）")
        onChange?(true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
        chordHeld = false
        anchor = nil
        guard mode != nil else { return }
        mode = nil
        remaining = 0
        Log.debug("清洁锁：解开")
        onChange?(false)
    }

    private func tick() {
        guard mode != nil else { return }
        remaining = max(0, Int((ContinuousClock.now.duration(to: deadline) / .seconds(1)).rounded(.up)))
        if remaining == 0 { stop() }
    }

    /// 拦截器回调：返回真就吞掉这个事件。
    private func swallows(_ type: CGEventType, _ event: CGEvent) -> Bool {
        // 回调超时（主线程忙）时系统会把拦截器停掉；不接回来就是擦到一半键盘活了
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard let mode else { return false }
        let auxSubtype = type.rawValue == InputLockRule.systemDefined ? NSEvent(cgEvent: event).map { Int($0.subtype.rawValue) } : nil
        switch InputLockRule.verdict(type: type.rawValue, keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                                     modifiers: event.flags, auxSubtype: auxSubtype, chordHeld: chordHeld, mode: mode) {
        case .pass:
            return false
        case .swallow:
            // 拽回不产生事件，不会自己触发自己
            if let anchor, InputLockRule.movesCursor(type.rawValue) { CGWarpMouseCursorPosition(anchor) }
            return true
        case .chord:
            chordHeld = true
            return true
        case .unlock:
            // 延后一拍再拆：不在拦截器自己的回调里作废它的端口
            DispatchQueue.main.async { self.stop() }
            return true
        }
    }
}
