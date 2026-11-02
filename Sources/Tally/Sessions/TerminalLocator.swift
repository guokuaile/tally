import AppKit
import Foundation

/// 定位窗口按会话记录里的 `term`（TERM_PROGRAM）分派到不同终端的做法。
enum BackendKind: Equatable {
    case ghostty
    case terminalApp
    case iterm
    /// tmux：按 pane 的 tty 找，切过去再把客户端所在的终端带到前台。
    case tmux
    /// 编辑器：没有能定位到某个终端标签的脚本接口，退而求其次用它打开会话目录。
    case editor(bundleId: String, name: String)
    /// 没有稳定脚本接口的终端：只把 app 激活。
    case activate(bundleId: String, name: String)
    case unknown
}

enum TerminalLocator {

    enum Failure: Error, Equatable {
        case notFound
        case ambiguous
        case notRunning(String)
        /// 没给或拒过「控制 <app>」的自动化授权。拒过之后系统不再弹框，每次点都静默失败，
        /// 所以要和「找不到窗口」分开，单独告诉用户去哪儿开。
        case needsAutomationPermission(String)
        case scriptFailed(String)
        /// 接着聊时会话目录已经不存在：不开终端，行里直说，别混进「定位失败」。
        case directoryMissing
        case backgroundUnavailable
        case backgroundQueryFailed
    }

    static let vscode = "com.microsoft.VSCode"
    static let cursor = "com.todesktop.230313mzl4w4u92"

    /// 纯分派，可测。`running` 的参数是 bundle id。
    static func kind(for term: String?, running: (_ bundleId: String) -> Bool) -> BackendKind {
        switch term {
        case "ghostty": return .ghostty
        case "Apple_Terminal": return .terminalApp
        case "iTerm.app": return .iterm
        case "tmux": return .tmux
        case "vscode":
            // Cursor 也报 vscode：谁在跑用谁，都没跑就让执行层抛「没在跑」
            if running(vscode) { return .editor(bundleId: vscode, name: "VS Code") }
            if running(cursor) { return .editor(bundleId: cursor, name: "Cursor") }
            return .editor(bundleId: vscode, name: "VS Code")
        case "WarpTerminal": return .activate(bundleId: "dev.warp.Warp-Stable", name: "Warp")
        case "kitty": return .activate(bundleId: "net.kovidgoyal.kitty", name: "kitty")
        case "WezTerm": return .activate(bundleId: "com.github.wez.wezterm", name: "WezTerm")
        default: return .unknown
        }
    }

    static func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    @MainActor
    static func focus(session: SessionRecord) async throws {
        if session.isClaudeSpare { throw Failure.backgroundUnavailable }
        if session.isBackgroundClaude || session.isClaudeBackground(in: ClaudeHome.url.appendingPathComponent("sessions")) {
            try await ClaudeBackground.attach(session)
            return
        }
        // 后台身份读不到时，Ghostty 的标题和目录回退可能命中别人的窗口。
        if session.isClaude, session.term == "ghostty", session.pid != nil,
           session.claudeCodeStatus(in: ClaudeHome.url.appendingPathComponent("sessions")) == .unknown {
            throw Failure.notFound
        }
        switch kind(for: session.term, running: isRunning) {
        case .ghostty:
            do {
                try await GhosttyLocator.focus(session: session)
            } catch GhosttyLocator.Failure.ghosttyNotRunning {
                throw Failure.notRunning("Ghostty")
            } catch GhosttyLocator.Failure.notFound {
                throw Failure.notFound
            } catch GhosttyLocator.Failure.ambiguous {
                throw Failure.ambiguous
            } catch let failure as Failure {
                // 未授权是从 runAppleScript 抛上来的，别被下面那条压成「定位失败」
                throw failure
            } catch {
                throw Failure.scriptFailed("\(error)")
            }
        case .terminalApp:
            try await TerminalAppLocator.focus(tty: session.tty)
        case .iterm:
            try await ITermLocator.focus(tty: session.tty)
        case .tmux:
            try await TmuxLocator.focus(session: session)
        case .editor(let bundleId, let name):
            // 编辑器定位不到具体的终端标签，就用它打开会话目录：对应那个工程的窗口会被带到前台。
            // 不用 NSRunningApplication.activate()：后台 app 调它会被协作激活规则挡掉，点了没反应。
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
                  !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty else {
                throw Failure.notRunning(name)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open([URL(fileURLWithPath: session.cwd)], withApplicationAt: appURL, configuration: configuration)
        case .activate(let bundleId, let name):
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
                throw Failure.notRunning(name)
            }
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty else {
                throw Failure.notRunning(name)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        case .unknown:
            throw Failure.notFound
        }
    }

    /// `ttys003` → `/dev/ttys003`；已经带 /dev/ 的原样。
    static func devicePath(_ tty: String) -> String {
        tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
    }

    /// `target` 是脚本要控制的 app 名字，报未授权时说给用户听。
    ///
    /// **必须放后台跑**：第一次控制某个 app 时 macOS 会弹「Tally 想控制 <终端>」，
    /// 而 `executeAndReturnError` 是同步的——放在主线程上，弹框期间整个面板冻死，
    /// 人看着没反应就走开了，120 秒后 AppleEvent 超时，macOS 把「弹框没人应答」
    /// 持久化成一条永久拒绝（TCC 里 `auth_reason=9 PromptTimeout`），从此再也不弹、每次点都失败。
    /// 每次都新建一个 `NSAppleScript` 实例，不跨线程共享。
    static func runAppleScript(_ source: String, target: String) async throws -> String {
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<String, Failure> in
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else { return .failure(.scriptFailed("脚本编译失败")) }
            let result = script.executeAndReturnError(&error)
            if let error { return .failure(Self.failure(fromScriptError: error, target: target)) }
            return .success(result.stringValue ?? "")
        }.value
        return try outcome.get()
    }

    /// 两种都是「没有控制 <app> 的自动化授权」，都得指给用户看设置：
    /// -1743 是拒过（系统从此不再弹框），-1712 是弹了框没人应答而超时（超时本身也会被记成拒绝）。
    /// 混进「找不到窗口」或笼统的「定位失败」，用户永远不知道该去哪儿开。
    static func failure(fromScriptError error: NSDictionary, target: String) -> Failure {
        let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        if code == -1743 || code == -1712 { return .needsAutomationPermission(target) }
        return .scriptFailed((error[NSAppleScript.errorMessage] as? String) ?? "\(error)")
    }

    /// 打开「系统设置 → 隐私与安全性 → 自动化」。
    @MainActor
    static func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Claude 后台伪终端不属于任何终端标签，用官方 CLI 的完整会话身份找短 ID 再接入。
enum ClaudeBackground {
    static func shortID(in data: Data, sessionID: String, pid: Int) -> String? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let matches = rows.filter { $0["kind"] as? String == "background" && $0["sessionId"] as? String == sessionID }
        guard matches.count == 1, matches[0]["pid"] as? Int == pid, let id = matches[0]["id"] as? String, !id.isEmpty,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return id
    }

    @MainActor
    static func attach(_ session: SessionRecord) async throws {
        guard let pid = session.pid else { throw TerminalLocator.Failure.notFound }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: session.cwd, isDirectory: &isDirectory), isDirectory.boolValue else { throw TerminalLocator.Failure.directoryMissing }
        let config = ClaudeHome.rawValue
        let target = try await Task.detached(priority: .userInitiated) { () throws -> (URL, String) in
            let local = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude")
            let paths = [local.path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            let executable: ([String]) -> String? = { $0.first { FileManager.default.isExecutableFile(atPath: $0) } }
            guard let path = executable(paths)
                    ?? executable(LoginShell.lines("-lc", "command -v claude"))
                    ?? executable(LoginShell.lines("-ilc", "command -v claude")) else { throw TerminalLocator.Failure.notRunning("Claude Code") }
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "CLAUDECODE")
            if let config { environment["CLAUDE_CONFIG_DIR"] = config } else { environment.removeValue(forKey: "CLAUDE_CONFIG_DIR") }
            let binary = URL(fileURLWithPath: path)
            let result: Subprocess.Result
            do {
                result = try Subprocess.run(binary, ["agents", "--json"], environment: environment, deadline: 10)
            } catch {
                Log.error("读取 Claude 后台会话失败：无法启动客户端")
                throw TerminalLocator.Failure.backgroundQueryFailed
            }
            guard !result.timedOut, result.status == 0,
                  (try? JSONSerialization.jsonObject(with: result.stdout)) is [[String: Any]] else {
                Log.error("读取 Claude 后台会话失败：超时=\(result.timedOut)，退出码=\(result.status.map(String.init) ?? "无")")
                throw TerminalLocator.Failure.backgroundQueryFailed
            }
            guard let id = shortID(in: result.stdout, sessionID: session.sessionId, pid: pid) else { throw TerminalLocator.Failure.backgroundUnavailable }
            return (binary, id)
        }.value
        let configArgument = config.map { " CLAUDE_CONFIG_DIR=\(SessionResume.shellQuote($0))" } ?? " -u CLAUDE_CONFIG_DIR"
        let command = "cd \(SessionResume.shellQuote(session.cwd)) && env -u CLAUDECODE\(configArgument) \(SessionResume.shellQuote(target.0.path)) attach \(SessionResume.shellQuote(target.1))"
        _ = try await TerminalLocator.runAppleScript(SessionResume.terminalScript(command), target: "Terminal")
    }
}
