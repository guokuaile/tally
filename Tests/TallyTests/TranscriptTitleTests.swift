import XCTest
@testable import Tally

final class TranscriptTitleTests: XCTestCase {

    private func titleLine(_ title: String) -> String {
        let escaped = title.replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"type\":\"ai-title\",\"aiTitle\":\"\(escaped)\",\"sessionId\":\"s\"}"
    }

    private func customLine(_ title: String) -> String {
        "{\"type\":\"custom-title\",\"customTitle\":\"\(title)\",\"sessionId\":\"s\"}"
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tally-title-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func tempFile(_ content: String, in dir: URL? = nil) throws -> URL {
        let url = try (dir ?? tempDir()).appendingPathComponent("t.jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testPendingQuestionDisappearsAfterAnswerAndIgnoresSidechains() throws {
        let question = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","id":"u1","input":{"questions":[{"question":"保留多久？"}]}}]}}"#
        let answer = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"u1","content":"一天"}]}}"#
        let side = #"{"type":"user","isSidechain":true,"message":{"content":"background"}}"#
        let url = try tempFile(question + "\n" + side + "\n")
        XCTAssertEqual(TranscriptTitle.pendingQuestion(in: url), "问题：保留多久？")
        try (question + "\n" + answer + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(TranscriptTitle.pendingQuestion(in: url))
    }

    func testTakesLastTitleInTail() throws {
        let url = try tempFile([titleLine("旧"), "{\"type\":\"user\"}", titleLine("新"), "{\"type\":\"assistant\"}"].joined(separator: "\n") + "\n")
        XCTAssertEqual(TranscriptTitle.read(from: url, sessionId: "s"), "新")
    }

    func testCustomTitleRecordWins() throws {
        let url = try tempFile([titleLine("自动"), customLine("我改的"), "{\"type\":\"user\"}"].joined(separator: "\n") + "\n")
        XCTAssertEqual(TranscriptTitle.read(from: url, sessionId: "s"), "我改的")
    }

    func testSidecarBeatsTail() throws {
        let dir = try tempDir()
        let url = try tempFile(titleLine("文件尾") + "\n", in: dir)
        let sidecarDir = dir.appendingPathComponent("s")
        try FileManager.default.createDirectory(at: sidecarDir, withIntermediateDirectories: true)
        try #"{"customTitle":"边车"}"#.write(to: sidecarDir.appendingPathComponent("custom-title.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptTitle.read(from: url, sessionId: "s"), "边车")
        XCTAssertEqual(TranscriptTitle.read(from: url, sessionId: "other"), "文件尾")
    }

    func testNoTitleOrMissingFileIsNil() throws {
        let url = try tempFile("{\"type\":\"user\"}\n")
        XCTAssertNil(TranscriptTitle.read(from: url, sessionId: "s"))
        XCTAssertNil(TranscriptTitle.read(from: URL(fileURLWithPath: "/nonexistent/x.jsonl"), sessionId: "s"))
    }

    func testTruncatedFirstLineIsDropped() throws {
        // 第一行超过 64 KB，切口落在它中间；尾部有真标题。
        let huge = titleLine("假" + String(repeating: "x", count: 70 * 1024))
        let url = try tempFile(huge + "\n{\"type\":\"user\"}\n" + titleLine("真") + "\n")
        XCTAssertEqual(TranscriptTitle.readTail(from: url), "真")
    }

    func testTruncatedFirstLineWithoutLaterTitleIsNilButFullScanFindsIt() throws {
        let huge = titleLine("假" + String(repeating: "x", count: 70 * 1024))
        let url = try tempFile(titleLine("开头的") + "\n" + huge + "\n{\"type\":\"user\"}\n")
        XCTAssertNil(TranscriptTitle.readTail(from: url))
        XCTAssertEqual(TranscriptTitle.readFull(from: url), "假" + String(repeating: "x", count: 70 * 1024))
    }

    func testBlankTitleIgnoredAndTrimmed() {
        XCTAssertNil(TranscriptTitle.parse(titleLine("   ") + "\n", truncated: false))
        XCTAssertEqual(TranscriptTitle.parse(titleLine(" 有 ") + "\n", truncated: false), "有")
    }

    // ── 回合怎么结束的 ─────────────────────────────────────────

    private let prompt = #"{"type":"user","message":{"role":"user","content":"跑一下"}}"#
    private let reply = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"好"}],"stop_reason":"end_turn"}}"#
    private let interrupt = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
    private let apiError = #"{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit · resets 3pm"}]}}"#
    private let snapshot = #"{"type":"file-history-snapshot","messageId":"m","snapshot":{}}"#

    private func turnEnd(_ lines: [String]) -> TranscriptTitle.TurnEnd? {
        TranscriptTitle.parseTurnEnd(lines.joined(separator: "\n") + "\n", truncated: false)
    }

    func testInterruptEndsTurnInBothWordingsAndWithRecordsAppendedAfter() {
        XCTAssertEqual(turnEnd([prompt, reply, interrupt]), .interrupted)
        let toolUse = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
        let mode = #"{"type":"permission-mode","permissionMode":"default"}"#
        let local = #"{"type":"system","subtype":"local_command","content":"<local-command-stdout>ok</local-command-stdout>"}"#
        XCTAssertEqual(turnEnd([prompt, toolUse, snapshot, mode, local]), .interrupted, "打断后追加的快照、模式、本地命令记录跳过")
        XCTAssertEqual(turnEnd([prompt, #"{"type":"user","message":{"content":"[Request interrupted by user]"}}"#]), .interrupted, "正文是字符串的写法")
    }

    func testApiErrorEndsTurnWithItsText() {
        XCTAssertEqual(turnEnd([prompt, apiError, snapshot]), .apiError("You've hit your session limit · resets 3pm"))
    }

    func testTurnStillGoingIsNil() {
        XCTAssertNil(turnEnd([prompt]), "刚发出去")
        XCTAssertNil(turnEnd([prompt, reply]), "正常回复完靠 Stop，不归这里")
        XCTAssertNil(turnEnd([prompt, interrupt, prompt]), "打断后又发了一句")
        let queued = #"{"type":"attachment","attachment":{"type":"queued_command","prompt":"再试"}}"#
        XCTAssertNil(turnEnd([prompt, apiError, queued, reply]), "报错后排队的输入接着跑")
        XCTAssertNil(turnEnd([snapshot]), "尾巴里没有对话记录")
    }

    func testSidechainAndMetaRecordsAreSkipped() {
        let sidechain = #"{"type":"user","isSidechain":true,"message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        XCTAssertNil(turnEnd([prompt, reply, sidechain]), "子 agent 被打断不等于主回合结束")
        let meta = #"{"type":"user","isMeta":true,"message":{"content":"Continue from where you left off."}}"#
        XCTAssertEqual(turnEnd([prompt, apiError, meta]), .apiError("You've hit your session limit · resets 3pm"), "注入的提示不算新输入")
    }

    func testInteractiveSessionDetection() throws {
        XCTAssertTrue(TranscriptTitle.isInteractive(transcript: try tempFile(#"{"type":"user","entrypoint":"cli"}"# + "\n"), provider: "claude"))
        XCTAssertFalse(TranscriptTitle.isInteractive(transcript: try tempFile(#"{"type":"user","entrypoint":"sdk-cli"}"# + "\n"), provider: "claude"), "claude -p")
        XCTAssertTrue(TranscriptTitle.isInteractive(transcript: try tempFile(#"{"type":"file-history-snapshot"}"# + "\n"), provider: "claude"), "判不出来按交互算：误删了就接不回去")
        XCTAssertFalse(TranscriptTitle.isInteractive(transcript: URL(fileURLWithPath: "/nonexistent/x.jsonl"), provider: "claude"), "没有 transcript 就没有能接着聊的")

        XCTAssertFalse(TranscriptTitle.isScriptedCodexHead(#"{"timestamp":"t","type":"session_meta","payload":{"id":"x","source":"cli","originator":"codex-tui"}}"# + "\n{}"))
        XCTAssertTrue(TranscriptTitle.isScriptedCodexHead(#"{"type":"session_meta","payload":{"source":"exec","originator":"codex_exec"}}"#), "codex exec")
        XCTAssertTrue(TranscriptTitle.isScriptedCodexHead(#"{"type":"session_meta","payload":{"source":{"subagent":{}}}}"#), "子 agent")
        XCTAssertFalse(TranscriptTitle.isScriptedCodexHead(#"{"type":"event_msg"}"# + "\n" + #"{"type":"session_meta","payload":{"source":"exec"}}"#), "只看第一行")
        // 第一行带着整段系统提示，比 64 KB 还长也认得出
        let long = #"{"type":"session_meta","payload":{"source":"exec","base_instructions":""# + String(repeating: "x", count: 70_000) + "\"}}\n"
        XCTAssertFalse(TranscriptTitle.isInteractive(transcript: try tempFile(long), provider: "codex"))
    }

    func testCodexTurnEndFromRolloutLifecycle() {
        func event(_ payload: String) -> String { #"{"timestamp":"t","type":"event_msg","payload":"# + payload + "}" }
        let started = event(#"{"type":"task_started","turn_id":"t1"}"#)
        let aborted = event(#"{"type":"turn_aborted","turn_id":"t1","reason":"interrupted"}"#)
        let abortNote = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<turn_aborted>"}]}}"#
        let failed = event(#"{"type":"task_complete","turn_id":"t1","last_agent_message":null,"error":{"message":"model not found","codex_error_info":"other"}}"#)
        let completed = event(#"{"type":"task_complete","turn_id":"t1","last_agent_message":"好了","error":null}"#)
        let oldError = event(#"{"type":"error","message":"usage limit exceeded","codex_error_info":"usage_limit_exceeded"}"#)
        func end(_ lines: [String]) -> TranscriptTitle.TurnEnd? {
            TranscriptTitle.parseCodexTurnEnd(lines.joined(separator: "\n") + "\n", truncated: false)
        }
        XCTAssertEqual(end([started, abortNote, aborted]), .interrupted)
        XCTAssertEqual(end([started, failed]), .apiError("model not found"))
        XCTAssertEqual(end([started, oldError, completed]), .apiError("usage limit exceeded"), "0.128 及以前单独写 error 事件")
        XCTAssertNil(end([started, completed]), "正常完成交给 Stop")
        XCTAssertNil(end([aborted, started]), "打断后又开了一轮")
        XCTAssertNil(end([started, oldError]), "报错后还没完成，可能在重试")
        XCTAssertNil(end([abortNote]), "尾巴里没有生命周期事件")
        XCTAssertNil(TranscriptTitle.parseTurnEnd([started, aborted].joined(separator: "\n") + "\n", truncated: false), "Claude 的判法不认 Codex 的事件")
    }

    func testTurnEndReadsFileTail() throws {
        XCTAssertEqual(TranscriptTitle.turnEnd(in: try tempFile([prompt, interrupt].joined(separator: "\n") + "\n")), .interrupted)
        XCTAssertNil(TranscriptTitle.turnEnd(in: URL(fileURLWithPath: "/nonexistent/x.jsonl")))
    }

    // MARK: 第一句话

    private func userLine(_ content: String, meta: Bool = false, sidechain: Bool = false) -> String {
        let escaped = content.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        return "{\"type\":\"user\",\"isMeta\":\(meta),\"isSidechain\":\(sidechain),\"message\":{\"role\":\"user\",\"content\":\"\(escaped)\"}}"
    }

    private func codexUserLine(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        return "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"\(escaped)\"}]}}"
    }

    func testFirstPromptClaudeTakesFirstMainlineUserText() {
        let text = ["{\"type\":\"file-history-snapshot\"}", userLine("注入", meta: true), userLine("子 agent", sidechain: true),
                    "{\"type\":\"user\",\"isCompactSummary\":true,\"message\":{\"role\":\"user\",\"content\":\"This session is being continued from a previous conversation\"}}",
                    userLine(" 看下 codex 的安装\n还在跑吗 "), userLine("第二句")].joined(separator: "\n")
        XCTAssertEqual(TranscriptTitle.parseFirstPrompt(text, provider: "claude"), "看下 codex 的安装 还在跑吗")
    }

    func testFirstPromptClaudeSlashCommandBecomesNameAndArgs() {
        let text = userLine("<command-message>obsidian-article-review</command-message>\n<command-name>/obsidian-article-review</command-name>\n<command-args>https://x.y/z</command-args>")
        XCTAssertEqual(TranscriptTitle.parseFirstPrompt(text, provider: "claude"), "/obsidian-article-review https://x.y/z")
        XCTAssertEqual(TranscriptTitle.parseFirstPrompt(userLine("<command-name>/clear</command-name>\n<command-args></command-args>"), provider: "claude"), "/clear")
    }

    func testFirstPromptClaudeContentBlocksAndClip() {
        let long = String(repeating: "长", count: 100)
        let line = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"\(long)\"},{\"type\":\"text\",\"text\":\"尾\"}]}}"
        XCTAssertEqual(TranscriptTitle.parseFirstPrompt(line, provider: "claude"), String(repeating: "长", count: TranscriptTitle.promptCharacters))
        let toolResult = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"x\"}]}}"
        XCTAssertNil(TranscriptTitle.parseFirstPrompt(toolResult, provider: "claude"))
    }

    func testFirstPromptSkipsInjectedAngleBracketTexts() {
        XCTAssertNil(TranscriptTitle.parseFirstPrompt(userLine("<local-command-stdout>x</local-command-stdout>"), provider: "claude"))
        XCTAssertNil(TranscriptTitle.parseFirstPrompt("", provider: "codex"))
    }

    func testFirstPromptCodexSkipsAgentsAndEnvironmentMessages() {
        let text = ["{\"type\":\"session_meta\",\"payload\":{\"role\":\"user\"}}",
                    "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"developer\",\"content\":[{\"type\":\"input_text\",\"text\":\"You are Codex\"}]}}",
                    codexUserLine("# AGENTS.md instructions\n\n<INSTRUCTIONS>…"),
                    codexUserLine("<environment_context>cwd</environment_context>"),
                    "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"老格式\"}}",
                    codexUserLine("目前 macOS 升级了，检查下影响"),
                    "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"半行"].joined(separator: "\n")
        XCTAssertEqual(TranscriptTitle.parseFirstPrompt(text, provider: "codex"), "目前 macOS 升级了，检查下影响")
    }

    func testFirstPromptReadsFileHeadAndIgnoresTruncatedLine() throws {
        let fine = try tempFile(userLine("开头") + "\n")
        XCTAssertEqual(TranscriptTitle.firstPrompt(in: fine, provider: "claude"), "开头")
        // 第一条非 meta 的 user 记录超过 1 MB，被切在中间：跳过，不拿半行当标题
        let cut = try tempFile(userLine("注入", meta: true) + "\n" + userLine(String(repeating: "x", count: TranscriptTitle.headBytes)) + "\n")
        XCTAssertNil(TranscriptTitle.firstPrompt(in: cut, provider: "claude"))
        XCTAssertNil(TranscriptTitle.firstPrompt(in: URL(fileURLWithPath: "/nonexistent/x.jsonl"), provider: "codex"))
    }
}
