import XCTest
@testable import Tally

final class BundleLocationTests: XCTestCase {

    /// 从 DMG 或下载目录直接打开时，Gatekeeper 把 app 搬到一个重启就没的临时路径跑；
    /// 那个路径写进 hooks 配置，重启后两边 agent 都会去调一个不存在的文件。
    func testTranslocatedAndVolumePathsAreUnstable() {
        XCTAssertTrue(BundleLocation.isUnstable("/private/var/folders/q_/x/T/AppTranslocation/E478/d/Tally.app/Contents/MacOS/tally-hook"))
        XCTAssertTrue(BundleLocation.isUnstable("/Volumes/Tally/Tally.app/Contents/MacOS/tally-hook"))
        XCTAssertFalse(BundleLocation.isUnstable("/Applications/Tally.app/Contents/MacOS/tally-hook"))
        XCTAssertFalse(BundleLocation.isUnstable("/Users/me/Applications/Tally.app/Contents/MacOS/tally-hook"))
    }
}

final class HookInstallerTests: XCTestCase {

    private var dir: URL!
    private let binary = "/Applications/Tally.app/Contents/MacOS/tally-hook"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tally-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func installer() -> HookInstaller {
        HookInstaller(
            claudeSettings: dir.appendingPathComponent("settings.json"),
            codexHooks: dir.appendingPathComponent("hooks.json"),
            codexConfig: dir.appendingPathComponent("config.toml"),
            hookBinary: binary
        )
    }

    /// Tally 在 Codex 里的信任键：hooks.json 用的是测试目录里那份。
    private func codexKey(_ event: String, _ group: Int, _ handler: Int = 0) -> String {
        CodexTrust.key(hooksFile: dir.appendingPathComponent("hooks.json").path, event: event, group: group, handler: handler)
    }

    private func toml() throws -> String {
        try String(contentsOf: dir.appendingPathComponent("config.toml"), encoding: .utf8)
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func json(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(name))) as? [String: Any])
    }

    private func commands(_ root: [String: Any], _ event: String) -> [String] {
        ((root["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? [])
            .compactMap { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String }
    }

    func testMissingFileInstallsEveryEventAndReportsInstalled() throws {
        let i = installer()
        XCTAssertEqual(i.status(.claude), .missing)
        try i.install(.claude)
        XCTAssertEqual(i.status(.claude), .installed)
        let root = try json("settings.json")
        for event in HookSide.claude.events {
            XCTAssertEqual(commands(root, event), ["\"\(binary)\""], event)
        }
    }

    func testEmptyFileTreatedAsEmptyObjectAndInvalidJSONThrows() throws {
        try write("settings.json", "")
        try installer().install(.claude)
        XCTAssertEqual(installer().status(.claude), .installed)

        try write("hooks.json", "{not json")
        XCTAssertThrowsError(try installer().install(.codex)) { error in
            XCTAssertEqual(error as? HookInstallError, .invalidJSON(dir.appendingPathComponent("hooks.json").path))
        }
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("hooks.json"), encoding: .utf8), "{not json")
    }

    func testOtherHooksAreKeptAndIndicesUnchanged() throws {
        // 旧 node 匹配组排在别的 hook 前面：原位替换后别的 hook 还在原来的序号上
        try write("settings.json", """
        {"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"node /old/claude-event.js"}]},
                          {"matcher":"*","hooks":[{"type":"command","command":"node verify-gate.js"}]}],
                  "PreToolUse":[{"hooks":[{"type":"command","command":"node guard.js"}]}]}}
        """)
        let i = installer()
        XCTAssertEqual(i.status(.claude), .pointsElsewhere("SessionStart、UserPromptSubmit、Notification、PostToolUse、PreCompact、SessionEnd 未注册；命令指向 node /old/claude-event.js"))
        try i.install(.claude)
        let root = try json("settings.json")
        XCTAssertEqual(commands(root, "Stop"), ["\"\(binary)\"", "node verify-gate.js"])
        XCTAssertEqual(commands(root, "PreToolUse"), ["node guard.js"])
        XCTAssertEqual(i.status(.claude), .installed)
    }

    func testInstallIsIdempotentAndDeduplicates() throws {
        let i = installer()
        try i.install(.claude)
        let once = try Data(contentsOf: dir.appendingPathComponent("settings.json"))
        try i.install(.claude)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("settings.json")), once)

        try write("settings.json", """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\\"/x/tally-hook\\""}]},{"hooks":[{"type":"command","command":"\\"/y/tally-hook\\""}]}]}}
        """)
        XCTAssertEqual(i.status(.claude), .pointsElsewhere("SessionStart、UserPromptSubmit、Notification、PostToolUse、PreCompact、SessionEnd 未注册；命令指向 \"/x/tally-hook\""))
        try i.install(.claude)
        XCTAssertEqual(commands(try json("settings.json"), "Stop"), ["\"\(binary)\""])
    }

    func testPartialRegistrationReportsMissingEvents() throws {
        var hooks: [String: Any] = [:]
        for event in ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"] {
            hooks[event] = [["hooks": [["type": "command", "command": "\"\(binary)\"", "timeout": 5]]]]
        }
        try HookInstaller.save(["hooks": hooks], to: dir.appendingPathComponent("settings.json"))
        XCTAssertEqual(installer().status(.claude), .pointsElsewhere("Notification、PostToolUse、PreCompact 未注册"), "升级前装的机器会看到 PreCompact 未注册")
    }

    func testCodexInstallWritesProviderFlagAndPatchesTrustInPlace() throws {
        try write("hooks.json", """
        {"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"\\"/opt/homebrew/bin/node\\" \\"/old/claude-event.js\\" --provider codex","timeout":5}]}]}}
        """)
        try write("config.toml", """
        model = "x"

        [hooks.state."\(codexKey("Stop", 0))"]
        trusted_hash = "sha256:old"

        [hooks.state."\(codexKey("PreToolUse", 0))"]
        trusted_hash = "sha256:other"
        """)
        let i = installer()
        try i.install(.codex)
        XCTAssertEqual(commands(try json("hooks.json"), "Stop"), ["\"\(binary)\" --provider codex"])
        XCTAssertEqual(commands(try json("hooks.json"), "PermissionRequest"), ["\"\(binary)\" --provider codex"])
        let toml = try toml()
        XCTAssertEqual(toml.components(separatedBy: "[hooks.state.\"\(codexKey("Stop", 0))\"]").count, 2, "旧块只有一份")
        XCTAssertTrue(toml.contains("[hooks.state.\"\(codexKey("Stop", 0))\"]\ntrusted_hash = \"\(CodexTrustTests.appServer["Stop"]!)\""), toml)
        XCTAssertFalse(toml.contains("sha256:old"))
        XCTAssertTrue(toml.contains("trusted_hash = \"sha256:other\""), "别的 hook 的哈希不动")
        for event in HookSide.codex.events where event != "Stop" {
            XCTAssertTrue(toml.contains("[hooks.state.\"\(codexKey(event, 0))\"]\ntrusted_hash = \"\(CodexTrustTests.appServer[event]!)\""), event)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("hooks.json.tally-backup").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.toml.tally-backup").path))
    }

    func testUninstallRemovesOnlyTallyGroupsAndEmptyEvents() throws {
        try write("settings.json", """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\\"\(binary)\\""}]},
                          {"matcher":"*","hooks":[{"type":"command","command":"node verify-gate.js"}]}],
                  "SessionStart":[{"hooks":[{"type":"command","command":"\\"\(binary)\\""}]}],
                  "PreToolUse":[{"hooks":[{"type":"command","command":"node guard.js"}]}]},
         "model":"opus"}
        """)
        let i = installer()
        try i.uninstall(.claude)
        XCTAssertEqual(i.status(.claude), .missing)
        let root = try json("settings.json")
        XCTAssertEqual(commands(root, "Stop"), ["node verify-gate.js"], "别的 hook 留着")
        XCTAssertEqual(commands(root, "PreToolUse"), ["node guard.js"])
        XCTAssertNil((root["hooks"] as? [String: Any])?["SessionStart"], "只剩 Tally 的事件连键一起删")
        XCTAssertEqual(root["model"] as? String, "opus", "别的顶层键不动")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.json.tally-backup").path))
        try i.uninstall(.claude)
        XCTAssertEqual(i.status(.claude), .missing, "重复移除是空操作")

        try write("settings.json", "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"\\\"\(binary)\\\"\"}]}]},\"model\":\"opus\"}")
        try i.uninstall(.claude)
        XCTAssertNil(try json("settings.json")["hooks"], "只剩 Tally 的话 hooks 顶层键一起删")
    }

    /// 移除后同一事件里后面的 hook 序号前移，信任状态跟着挪；没信任过的不能顺手变成信任。
    func testCodexUninstallShiftsTrustOfRemainingHooks() throws {
        try write("hooks.json", """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"node gate.js"}]},
                          {"hooks":[{"type":"command","command":"\\"\(binary)\\" --provider codex"}]},
                          {"hooks":[{"type":"command","command":"node sketchy.js"}]},
                          {"hooks":[{"type":"command","command":"node a.js"},{"type":"command","command":"node b.js"}]}],
                  "SessionStart":[{"hooks":[{"type":"command","command":"\\"\(binary)\\" --provider codex"}]}]}}
        """)
        try write("config.toml", """
        model = "x"

        [hooks.state."\(codexKey("Stop", 0))"]
        trusted_hash = "sha256:gate"

        [hooks.state."\(codexKey("Stop", 1))"]
        trusted_hash = "sha256:tally"

        [hooks.state."\(codexKey("Stop", 3, 0))"]
        trusted_hash = "sha256:a"

        [hooks.state."\(codexKey("Stop", 3, 1))"]
        enabled = false
        trusted_hash = "sha256:b"

        [hooks.state."\(codexKey("SessionStart", 0))"]
        trusted_hash = "sha256:tally-start"
        """)
        let i = installer()
        try i.uninstall(.codex)
        XCTAssertEqual(i.status(.codex), .missing)
        XCTAssertEqual(commands(try json("hooks.json"), "Stop"), ["node gate.js", "node sketchy.js", "node a.js"])
        XCTAssertEqual(try toml(), """
        model = "x"

        [hooks.state."\(codexKey("Stop", 0))"]
        trusted_hash = "sha256:gate"

        [hooks.state."\(codexKey("Stop", 2, 0))"]
        trusted_hash = "sha256:a"

        [hooks.state."\(codexKey("Stop", 2, 1))"]
        enabled = false
        trusted_hash = "sha256:b"

        """, "前面的不动、Tally 的块删掉、后面的挪一位；sketchy 从没信任过，挪到 1 上也没有块")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.toml.tally-backup").path))
    }

    func testTrustFailureRollsBackTheJSONEdit() throws {
        let original = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"node keep.js\"}]}]}}"
        try write("hooks.json", original)
        // config.toml 的上一级是个普通文件，写不进去
        try write("blocker", "")
        let failing = HookInstaller(
            claudeSettings: dir.appendingPathComponent("settings.json"),
            codexHooks: dir.appendingPathComponent("hooks.json"),
            codexConfig: dir.appendingPathComponent("blocker/config.toml"),
            hookBinary: binary
        )
        XCTAssertThrowsError(try failing.install(.codex))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("hooks.json"), encoding: .utf8), original, "哈希写不进去就退回原样")
        XCTAssertEqual(failing.status(.codex), .missing)
    }

    /// config.toml 在但不是 UTF-8：当成空文件写回去会只剩 Tally 的几块，用户别的配置全没了。要报错、两个文件都不动。
    func testUnreadableConfigIsNotOverwritten() throws {
        let original = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"node keep.js\"}]}]}}"
        try write("hooks.json", original)
        let garbage = Data("model = \"x\"\n".utf8) + Data([0xFF, 0xFE, 0x0A])
        try garbage.write(to: dir.appendingPathComponent("config.toml"))
        XCTAssertThrowsError(try installer().install(.codex))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("config.toml")), garbage)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("hooks.json"), encoding: .utf8), original)
    }

    func testBackupIsWrittenBeforeChange() throws {
        try write("settings.json", "{\"hooks\":{}}")
        try installer().install(.claude)
        let backup = try String(contentsOf: dir.appendingPathComponent("settings.json.tally-backup"), encoding: .utf8)
        XCTAssertEqual(backup, "{\"hooks\":{}}")
    }
}

/// 信任哈希是照 Codex 源码自己算的，不跑 app-server。算错了 Codex 不执行 hook，界面上只剩「还没收到过事件」，所以拿真值钉住。
final class CodexTrustTests: XCTestCase {

    /// `codex app-server` 的 hooks/list 对 `"/Applications/Tally.app/Contents/MacOS/tally-hook" --provider codex`、超时 5 实报的
    /// currentHash（codex-cli 0.154.0）；另一台机器 config.toml 里同一条命令的 trusted_hash 与之逐个相同。
    static let appServer = [
        "SessionStart": "sha256:e47181287b4a61f12e96f670a637c456234344a7dbaecf927074fd12f73cae45",
        "UserPromptSubmit": "sha256:7e707fd6c1b0f500342532dd4fa7adce493ffeadecd8f224024629f18135190a",
        "PermissionRequest": "sha256:24e2f42ac9806a566637aaf8442d0c5f2d2830480b6cc6bd6f5d52c85c40aa1b",
        "PostToolUse": "sha256:13bf6ad3f1534ce3239bd3c677361f900c5a150f285d0d379f4066c5afef1431",
        "Stop": "sha256:413255748d3b8f05a7647ddd81b53b8c3a9d8b50eda28988a190a21b5c36c48f",
        // SessionEnd 的超时被 Codex 压到 3 秒，哈希按 3 算
        "SessionEnd": "sha256:aba9f1acc4dcac21ac181c3b8da4a5a1ca853338c519aeb72c07c82f6f63cc10",
    ]

    func testHashMatchesAppServer() throws {
        let command = "\"/Applications/Tally.app/Contents/MacOS/tally-hook\" --provider codex"
        for event in HookSide.codex.events {
            XCTAssertEqual(try CodexTrust.hash(event: event, command: command, timeout: 5), Self.appServer[event], event)
        }
    }

    func testKeyUsesSnakeCaseEvent() {
        XCTAssertEqual(CodexTrust.key(hooksFile: "/Users/a/.codex-cli/hooks.json", event: "UserPromptSubmit", group: 1),
                       "/Users/a/.codex-cli/hooks.json:user_prompt_submit:1:0")
        XCTAssertEqual(HookSide.codex.events.map(CodexTrust.label),
                       ["session_start", "user_prompt_submit", "permission_request", "post_tool_use", "stop", "session_end"])
    }
}

/// Claude Code 的家可以被 `CLAUDE_CONFIG_DIR` 指到别处：hook、用量日志、凭据、打断判定都跟着搬。
final class ClaudeHomeTests: XCTestCase {

    private func withEnvironmentValue(_ value: String?, _ body: () -> Void) {
        let saved = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        if let value { setenv("CLAUDE_CONFIG_DIR", value, 1) } else { unsetenv("CLAUDE_CONFIG_DIR") }
        body()
        if let saved { setenv("CLAUDE_CONFIG_DIR", saved, 1) } else { unsetenv("CLAUDE_CONFIG_DIR") }
    }

    func testResolvesFromEnvironmentThenShell() {
        withEnvironmentValue(nil) {
            XCTAssertNil(ClaudeHome.resolveRaw(shellValue: nil))
            XCTAssertNil(ClaudeHome.resolveRaw(shellValue: "  "), "空白当没设")
            XCTAssertEqual(ClaudeHome.resolveRaw(shellValue: "/Users/x/.claude-work/"), "/Users/x/.claude-work/", "原值不动：尾斜杠影响钥匙串哈希")
            XCTAssertEqual(ClaudeHome.resolveRaw(shellValue: nil, recorded: "/Users/x/.claude-zshrc"), "/Users/x/.claude-zshrc",
                           "只写在 .zshrc 里的变量登录 shell 问不出来，用 hook 记下的")
            XCTAssertEqual(ClaudeHome.resolveRaw(shellValue: "/from-shell", recorded: "/recorded"), "/from-shell", "shell 问得到就用 shell 的")
        }
        withEnvironmentValue("/tmp/from-environment") {
            XCTAssertEqual(ClaudeHome.resolveRaw(shellValue: "/tmp/from-shell"), "/tmp/from-environment")
        }
    }

    func testPathsFollowTheConfigDir() {
        let home = NSHomeDirectory()
        XCTAssertEqual(SessionRecord.claudeHome(configDir: nil).path, home + "/.claude")
        XCTAssertEqual(SessionRecord.claudeHome(configDir: " "), SessionRecord.claudeHome(configDir: nil), "空白当没设")
        XCTAssertEqual(SessionRecord.claudeSessionsDirectory(configDir: nil).path, home + "/.claude/sessions")
        XCTAssertEqual(SessionRecord.claudeSessionsDirectory(configDir: "/x/work").path, "/x/work/sessions")
        XCTAssertEqual(SessionRecord.claudeHome(configDir: "~/.claude-work").path, home + "/.claude-work")
        XCTAssertEqual(ClaudeHome.globalConfig(nil).path, home + "/.claude.json", "没设时 .claude.json 在家目录旁边")
        XCTAssertEqual(ClaudeHome.globalConfig("/x/work").path, "/x/work/.claude.json", "设了在目录里面")
    }

    /// 钥匙串服务名要和 Claude Code 算得一模一样，否则设了 CLAUDE_CONFIG_DIR 就读不到配额（或读到别的账号）。
    func testKeychainServiceMatchesClaudeCode() {
        XCTAssertEqual(ClaudeHome.keychainService(nil), "Claude Code-credentials")
        XCTAssertEqual(ClaudeHome.keychainService("/Users/vinz/.claude-work"), "Claude Code-credentials-19914660")
        XCTAssertEqual(ClaudeHome.keychainService("/Users/vinz/.claude-work/"), "Claude Code-credentials-e5649954", "按原字符串算，尾斜杠不去掉")
    }
}

/// codex 的家可以被 `CODEX_HOME` 指到别处（有人给终端 codex 单开一个家，跟 ChatGPT 桌面版隔开）。
/// hook 装错家 = 装了也收不到会话，所以这几条得钉住。
final class CodexHomeTests: XCTestCase {

    private func withoutEnvironmentValue(_ body: () -> Void) {
        let saved = ProcessInfo.processInfo.environment["CODEX_HOME"]
        unsetenv("CODEX_HOME")
        body()
        if let saved { setenv("CODEX_HOME", saved, 1) }
    }

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("tally-codexhome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// 在 `<家>/sessions/<年>/<月>/<日>/` 下写一个 rollout，第一行是带 originator 的 session_meta。
    private func rollout(_ dir: String, _ day: String, _ name: String, originator: String) throws {
        let folder = home.appendingPathComponent(dir).appendingPathComponent("sessions/" + day)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let line = #"{"timestamp":"2026-09-16T01:57:59.001Z","type":"session_meta","payload":{"id":"x","cwd":"/tmp","originator":"\#(originator)","source":"cli"}}"#
        try (line + "\n" + #"{"type":"event_msg"}"# + "\n").write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testFallsBackToDefaultHome() {
        withoutEnvironmentValue {
            let expected = home.appendingPathComponent(".codex")
            XCTAssertEqual(CodexHome.resolve(shellValue: nil, home: home), expected)
            XCTAssertEqual(CodexHome.resolve(shellValue: "   ", home: home), expected)
        }
    }

    /// 远端那台：隐私规则不许导出 CODEX_HOME，终端 codex 在 `~/.codex-cli`，`~/.codex` 里只有桌面版的会话。
    /// 退回 `~/.codex` 会把 hook 装给桌面版。
    func testPicksTerminalHomeOverDesktopHome() throws {
        try rollout(".codex", "2026/09/16", "rollout-2026-09-16T10-00-00-d.jsonl", originator: "Codex Desktop")
        try rollout(".codex-cli", "2026/09/14", "rollout-2026-09-14T09-10-20-a.jsonl", originator: "codex_exec")
        withoutEnvironmentValue {
            XCTAssertEqual(CodexHome.resolve(shellValue: nil, home: home).path,
                           CodexHome.canonical(home.appendingPathComponent(".codex-cli")).path, "桌面版的会话再新也不选")
        }
    }

    /// 两个家都有终端会话（比如 `~/.codex` 和旧备份 `~/.codex.bak-…`）：取最近用过的；默认的家不解软链接。
    func testPicksMostRecentTerminalHome() throws {
        try rollout(".codex", "2026/09/16", "rollout-2026-09-16T16-44-35-a.jsonl", originator: "codex-tui")
        try rollout(".codex.bak-20260407", "2026/04/07", "rollout-2026-04-07T09-00-00-b.jsonl", originator: "codex-tui")
        // 同一天里新的是桌面版，旧的才是终端：跳过桌面版接着往回找
        try rollout(".codex-work", "2026/09/15", "rollout-2026-09-15T23-00-00-c.jsonl", originator: "Codex Desktop")
        try rollout(".codex-work", "2026/09/15", "rollout-2026-09-15T08-00-00-d.jsonl", originator: "codex-tui")
        XCTAssertEqual(CodexHome.terminalHome(in: home), home.appendingPathComponent(".codex"))
        XCTAssertEqual(CodexHome.latestTerminalRollout(in: home.appendingPathComponent(".codex-work/sessions")),
                       "rollout-2026-09-15T08-00-00-d.jsonl")
    }

    /// 只有桌面版会话、或者根本没有会话的家不算；不是 `.codex` 开头的文件夹不看。
    func testIgnoresDesktopOnlyAndUnrelatedFolders() throws {
        try rollout(".codex", "2026/07/31", "rollout-2026-07-31T13-39-55-a.jsonl", originator: "Codex Desktop")
        try rollout("codex-elsewhere", "2026/09/16", "rollout-2026-09-16T10-00-00-b.jsonl", originator: "codex-tui")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codexbar"), withIntermediateDirectories: true)
        XCTAssertNil(CodexHome.terminalHome(in: home))
    }

    /// app 的环境里没有用户 shell 的变量，所以 shell 问回来的那个值必须算数。
    func testUsesShellValueAndExpandsTilde() {
        withoutEnvironmentValue {
            XCTAssertEqual(CodexHome.resolve(shellValue: "/Users/x/.codex-cli").path, "/Users/x/.codex-cli")
            XCTAssertEqual(CodexHome.resolve(shellValue: "~/.codex-cli").path,
                           NSHomeDirectory() + "/.codex-cli")
        }
    }

    /// 从终端启动 Tally 时环境里就带着 CODEX_HOME，那份比问 shell 更贴当下。
    func testEnvironmentWinsOverShell() {
        let saved = ProcessInfo.processInfo.environment["CODEX_HOME"]
        setenv("CODEX_HOME", "/tmp/from-environment", 1)
        defer { if let saved { setenv("CODEX_HOME", saved, 1) } else { unsetenv("CODEX_HOME") } }
        XCTAssertEqual(CodexHome.resolve(shellValue: "/tmp/from-shell").path, "/tmp/from-environment")
    }

    /// 标记行的解析：shell 启动脚本自己也会往 stdout 写东西，认前缀而不是整段拿。
    func testValuePicksMarkedLineAndTreatsEmptyAsMissing() {
        XCTAssertEqual(LoginShell.value(["主题噪声", "TALLY_CODEX_HOME=/a/b"], marker: "TALLY_CODEX_HOME"), "/a/b")
        XCTAssertNil(LoginShell.value(["TALLY_CODEX_HOME="], marker: "TALLY_CODEX_HOME"))
        XCTAssertNil(LoginShell.value(["别的东西"], marker: "TALLY_CODEX_HOME"))
    }
}
