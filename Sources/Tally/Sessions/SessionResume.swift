import AppKit
import Foundation

/// 接着聊一个已关闭的会话：在新终端里到会话目录再恢复（docs/ai.md「已关闭的会话」）。
enum SessionResume {

    /// `claude --resume <id>` 默认沿用原来的 session_id，接上之后 hook 写回同一个文件，还是这一行。
    static func tool(for session: SessionRecord) -> String {
        session.provider == "codex" ? "codex resume" : "claude --resume"
    }

    /// 接上会话的那半句。id 只有 `[A-Za-z0-9._-]`（hook 写文件时放行的字符），所以这句永远是纯 ASCII。
    static func resumeCommand(for session: SessionRecord) -> String {
        "\(tool(for: session)) \(shellQuote(session.sessionId))"
    }

    /// Terminal.app 与 iTerm 用：先 cd 再接。Ghostty 和 tmux 把目录交给终端自己，见 `ghosttyScript` / `inTmux`。
    static func command(for session: SessionRecord) -> String {
        "cd \(shellQuote(session.cwd)) && \(resumeCommand(for: session))"
    }

    /// 单引号包起来，内部的单引号写成 '\''。
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript 字符串字面量：反斜杠和双引号转义。
    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// 目录走 `initial working directory`，`initial input` 里只放纯 ASCII 的接续命令：Ghostty 把 initial input 的每个非 ASCII 字节
    /// 转义成 `\xNN` 再按码点解析（`src/apprt/embedded.zig` → `src/config/string.zig`，1.3.1 与 main 都这样），
    /// 中文目录经 `cd` 送进去会二次编码成乱码、cd 失败。
    static func ghosttyScript(cwd: String, command: String) -> String {
        """
        tell application id "com.mitchellh.ghostty"
            set cfg to new surface configuration
            set initial working directory of cfg to \(appleScriptString(cwd))
            set initial input of cfg to \(appleScriptString(command)) & linefeed
            new window with configuration cfg
            activate
        end tell
        """
    }

    static func terminalScript(_ command: String) -> String {
        """
        tell application id "com.apple.Terminal"
            do script \(appleScriptString(command))
            activate
        end tell
        """
    }

    static func itermScript(_ command: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
            set w to (create window with default profile)
            tell current session of w to write text \(appleScriptString(command))
            activate
        end tell
        """
    }

    @MainActor
    static func run(_ session: SessionRecord) async throws {
        // 目录没了就别开终端：Ghostty / tmux 拿到不存在的目录会退回默认目录再跑 resume，报的是「找不到会话」，看不出是目录的事
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: session.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TerminalLocator.Failure.directoryMissing
        }
        switch TerminalLocator.kind(for: session.term, running: TerminalLocator.isRunning) {
        case .terminalApp:
            _ = try await TerminalLocator.runAppleScript(terminalScript(command(for: session)), target: "Terminal")
        case .iterm:
            _ = try await TerminalLocator.runAppleScript(itermScript(command(for: session)), target: "iTerm")
        case .tmux:
            if try await inTmux(session) { return }
            try await inDefaultTerminal(session)
        case .ghostty:
            try await inGhostty(session)
        case .editor, .activate, .unknown:
            try await inDefaultTerminal(session)
        }
    }

    @MainActor
    private static func inGhostty(_ session: SessionRecord) async throws {
        _ = try await TerminalLocator.runAppleScript(ghosttyScript(cwd: session.cwd, command: resumeCommand(for: session)), target: "Ghostty")
    }

    /// 装了 Ghostty 用 Ghostty，否则 Terminal.app。
    @MainActor
    private static func inDefaultTerminal(_ session: SessionRecord) async throws {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: GhosttyLocator.bundleIdentifier) != nil {
            try await inGhostty(session)
        } else {
            _ = try await TerminalLocator.runAppleScript(terminalScript(command(for: session)), target: "Terminal")
        }
    }

    /// 在最近活动的客户端所在的 tmux 会话里开个新窗口跑，再把那个终端带到前台。没有 tmux 或没有客户端返回 false。
    @MainActor
    private static func inTmux(_ session: SessionRecord) async throws -> Bool {
        let shellCommand = resumeCommand(for: session)
        let cwd = session.cwd
        let client = await Task.detached(priority: .userInitiated) { () -> TmuxLocator.Client? in
            guard let tmux = TmuxLocator.binary(),
                  let client = TmuxLocator.client(session: nil, listing: TmuxLocator.run(tmux, ["list-clients", "-F", TmuxLocator.clientFormat]))
            else { return nil }
            TmuxLocator.run(tmux, ["new-window", "-t", client.session, "-c", cwd, shellCommand])
            return client
        }.value
        guard let client else { return false }
        try await TmuxLocator.focusHost(of: client)
        return true
    }
}
