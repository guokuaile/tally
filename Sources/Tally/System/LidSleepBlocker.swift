import Foundation
import Observation

/// 合盖也不休眠：置内核的 `SleepDisabled`（`pmset -a disablesleep 1`），要 root。
///
/// 为什么不能靠电源断言：`KeepAwake` 那个断言只挡**闲置**休眠，合盖触发的是 clamshell 休眠，低一层，
/// `caffeinate -d/-i/-s` 和任何 `IOPMAssertion` 都拦不住——没接外接屏时合盖必睡。不接屏还要合盖继续跑，
/// 只有内核这个开关。
///
/// **拿 root 的方式只有免密规则这一条**：往 `/etc/sudoers.d/tally` 装一条只管几条命令的 NOPASSWD 规则，
/// 一次密码，以后（跨重启、跨重装）都不再问。试过「每次开都走 `do shell script … with administrator
/// privileges`，顺带在授权里起个 root 看门狗负责恢复」——**授权层起的后台进程当场就被杀**（实测：pid 记下来了，
/// 进程不存在，一行日志都没写出来），于是恢复路径全是哑的：关掉开关、退出 app，系统里那个开关还开着，
/// 机器再也不休眠而界面显示是关的。有了免密就不需要看门狗了，Tally 自己置位、自己恢复。
///
/// 唯一恢复不了的路是 Tally 被 `SIGKILL` 或断电：`SleepDisabled` 是持久设置，重启也留着，
/// 所以启动时 `checkResidue()` 读一次真实状态，是 1 而不是自己开的就直接抹掉（免密，不弹框）。
/// Tally 是登录项，这个窗口最长到下次登录。
@MainActor
@Observable
final class LidSleepBlocker {

    static let shared = LidSleepBlocker()

    nonisolated static let sudoersPath = "/etc/sudoers.d/tally"

    private(set) var isActive = false

    /// 免密规则装没装。以 `sudo -n -l` 的实际结果为准，不看文件在不在——规则生效还得 sudoers 真的 include 了那个目录。
    private(set) var passwordless = false

    /// 系统里还开着、又不是这一轮开的，而且没免密规则可用（清它要一次密码）。
    private(set) var residue = false

    /// 上一次失败的原因，界面上要说出来。人点取消不算失败，这里是 nil。
    /// 装规则要管理员账号，别人拿到这个 app 时最常见的失败就是这条，不说的话就是「点了没反应」。
    private(set) var failure: String?
    private(set) var busy = false
    private let sleepCommand: (@Sendable (Bool) async -> Bool)?
    private let command: @Sendable (String, [String]) async -> Subprocess.Result?
    private let authorize: @Sendable (String) async -> AuthResult
    private let keepAwake: @MainActor () -> Void
    private var pending: Task<Bool, Never>?
    private var operationID = 0
    private var sleepIntent = 0
    private var stateKnown = false

    init(isActive: Bool = false, sleepCommand: (@Sendable (Bool) async -> Bool)? = nil,
         command: (@Sendable (String, [String]) async -> Subprocess.Result?)? = nil,
         authorize: (@Sendable (String) async -> AuthResult)? = nil,
         keepAwake: (@MainActor () -> Void)? = nil) {
        self.isActive = isActive
        self.stateKnown = isActive
        self.sleepCommand = sleepCommand
        self.command = command ?? Self.run
        self.authorize = authorize ?? Self.runAuthorized
        self.keepAwake = keepAwake ?? {
            if !KeepAwake.shared.isActive {
                KeepAwake.shared.start(minutes: nil, keepDisplay: PreferencesStore.shared.prefs.keepAwakeDisplay)
            }
        }
    }

    // Serialize system mutations; merely discarding an old callback cannot undo pmset.
    private func enqueue(_ operation: @escaping @MainActor () async -> Bool) -> Task<Bool, Never> {
        let previous = pending
        operationID += 1
        let id = operationID
        busy = true
        let task = Task { @MainActor in
            if let previous { _ = await previous.value }
            let result = await operation()
            if id == self.operationID { self.pending = nil; self.busy = false }
            return result
        }
        pending = task
        return task
    }

    func enable() async -> Bool {
        sleepIntent += 1
        let intent = sleepIntent
        return await enqueue {
            self.failure = nil
            guard intent == self.sleepIntent else { return false }
            if !DemoMode.isOn {
                guard await self.refreshPasswordless() else { return false }
                if !self.passwordless, !(await self.installRule()) { return false }
            }
            guard intent == self.sleepIntent else { return false }
            guard await self.setSleep(true) else {
                self.stateKnown = false
                self.failure = "pmset 没执行成功，免密规则可能被删了"
                return false
            }
            self.isActive = true
            self.stateKnown = true
            self.residue = false
            if intent == self.sleepIntent { self.keepAwake() }
            return intent == self.sleepIntent
        }.value
    }

    @discardableResult
    func disable() -> Task<Bool, Never> {
        sleepIntent += 1
        return enqueue { await self.disableCurrent() }
    }

    private func disableCurrent() async -> Bool {
        guard !stateKnown || isActive || residue else { return true }
        guard await setSleep(false) else {
            stateKnown = false
            failure = "未能恢复合盖休眠，系统可能仍保持唤醒；请重试或检查免密规则"
            return false
        }
        isActive = false
        stateKnown = true
        residue = false
        failure = nil
        return true
    }

    @discardableResult
    func checkResidue() -> Task<Bool, Never> {
        enqueue {
            _ = await self.refreshPasswordless()
            guard !self.isActive else { return true }
            guard let result = await self.command("/usr/bin/pmset", ["-g"]),
                  !result.timedOut, result.status == 0 else {
                self.stateKnown = false
                self.failure = "无法读取合盖休眠状态，请稍后重试"
                return false
            }
            self.residue = Self.sleepDisabled(inPmsetOutput: String(decoding: result.stdout, as: UTF8.self))
            self.stateKnown = true
            guard self.residue, self.passwordless else { return true }
            return await self.disableCurrent()
        }
    }

    func clearResidue() async -> Bool {
        sleepIntent += 1
        return await enqueue {
            switch await self.authorize("/usr/bin/pmset -a disablesleep 0") {
            case .ok:
                self.residue = false
                self.isActive = false
                self.stateKnown = true
                self.failure = nil
                return true
            case .cancelled: return false
            case .failed:
                self.failure = "没能恢复合盖休眠：这一步要管理员账号"
                return false
            }
        }.value
    }

    func installPasswordless() async -> Bool {
        await enqueue { await self.installRule() }.value
    }

    private func installRule() async -> Bool {
        failure = nil
        switch await authorize(Self.sudoersInstallScript(user: NSUserName())) {
        case .cancelled: return false
        case .failed:
            failure = "没能装上免密规则：这一步要管理员账号"
            return false
        case .ok: break
        }
        guard await refreshPasswordless() else { return false }
        if !passwordless { failure = "规则装上了却没生效：/etc/sudoers 里可能没有 @includedir /etc/sudoers.d" }
        return passwordless
    }

    func removePasswordless() async -> Bool {
        sleepIntent += 1
        return await enqueue {
            guard await self.disableCurrent() else { return false }
            if !(await self.succeeded("/usr/bin/sudo", ["-n", "/bin/rm", "-f", Self.sudoersPath])) {
                switch await self.authorize("/bin/rm -f \(Self.sudoersPath)") {
                case .ok: break
                case .cancelled: return false
                case .failed:
                    self.failure = "没能撤销免密规则：这一步要管理员账号"
                    return false
                }
            }
            guard await self.refreshPasswordless() else { return false }
            if self.passwordless { self.failure = "免密规则仍在生效，未能撤销" }
            return !self.passwordless
        }.value
    }

    private func refreshPasswordless() async -> Bool {
        guard let result = await command("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"]),
              !result.timedOut, let status = result.status else {
            failure = "无法确认免密规则状态，请稍后重试"
            return false
        }
        passwordless = status == 0
        return true
    }

    private func succeeded(_ path: String, _ arguments: [String]) async -> Bool {
        guard let result = await command(path, arguments) else { return false }
        return !result.timedOut && result.status == 0
    }

    private func setSleep(_ on: Bool) async -> Bool {
        guard !DemoMode.isOn else { return true }
        if let sleepCommand { return await sleepCommand(on) }
        return await succeeded("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"])
    }

    nonisolated static func sudoersInstallScript(user: String) -> String {
        """
        T=$(/usr/bin/mktemp) || exit 1
        /bin/cat > "$T" <<'TALLYRULE'
        # Tally：合盖也不休眠用的免密规则，只放行这几条命令。删掉这个文件即撤销。
        \(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0, /bin/rm -f \(sudoersPath)
        TALLYRULE
        /usr/sbin/visudo -cf "$T" >/dev/null 2>&1 || { /bin/rm -f "$T"; exit 1; }
        /usr/bin/install -m 440 -o root -g wheel "$T" \(sudoersPath) || { /bin/rm -f "$T"; exit 1; }
        /bin/rm -f "$T"
        """
    }

    /// `pmset -g` 里开着时有一行 `SleepDisabled\t\t1`，关着是 0，从没设过就整行不出现。
    /// **分隔符是制表符不是空格**（`od -c` 实测）：只按空格切的话整行成一个字段，永远判成没开——
    /// 于是残留既不自动抹也不报警，界面上什么都看不出来。
    nonisolated static func sleepDisabled(inPmsetOutput text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count >= 2 && fields[0] == "SleepDisabled" && fields[1] == "1"
        }
    }

    nonisolated private static func run(_ path: String, _ arguments: [String]) async -> Subprocess.Result? {
        await Task.detached(priority: .userInitiated) {
            do {
                return try Subprocess.run(URL(fileURLWithPath: path), arguments, deadline: 5)
            } catch {
                Log.error("休眠状态命令无法执行: \(error.localizedDescription)")
                return nil
            }
        }.value
    }

    /// 脚本 base64 进 `do shell script`：AppleScript 那层字符串里只剩 base64 字符，不用套两层引号。
    ///
    /// **必须放后台跑**，理由同 `TerminalLocator.runAppleScript`：`executeAndReturnError` 是同步的，
    /// 放主线程上会在密码框弹着的时候把整个面板冻死。用 in-process 的 `NSAppleScript` 而不是起 `osascript`，
    /// 密码框上写的才是「Tally 想要进行更改」；起 osascript 的话人看到的是「osascript 想要进行更改」，谁都不敢输。
    ///
    /// 只用来干**一次就结束**的事（装 / 删规则、抹残留）。别指望在这里面起长期进程：授权层退出时会把后台进程一起杀掉。
    nonisolated private static func runAuthorized(_ script: String) async -> AuthResult {
        let encoded = Data(script.utf8).base64EncodedString()
        let source = "do shell script \"/bin/echo \(encoded) | /usr/bin/base64 -D | /bin/sh\" with administrator privileges"
        return await Task.detached(priority: .userInitiated) { () -> AuthResult in
            var error: NSDictionary?
            guard let apple = NSAppleScript(source: source) else { return .failed }
            apple.executeAndReturnError(&error)
            guard let error else { return .ok }
            // -128 是人点了取消，不是错，界面上也不该报错
            guard (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue != -128 else { return .cancelled }
            Log.error("合盖不休眠授权失败: \(error)")
            return .failed
        }.value
    }

    /// 取消和失败要分开：取消是人的选择，界面不该报错；失败得说出来，否则点了没反应没人知道为什么。
    enum AuthResult: Sendable { case ok, cancelled, failed }
}
