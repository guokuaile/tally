import XCTest
@testable import Tally

/// 会话列表的分组顺序（docs/ai.md「会话行」）。
final class SessionOrderTests: XCTestCase {

    private func record(_ id: String, _ state: SessionRecord.State, age: TimeInterval, now: Date) -> SessionRecord {
        SessionRecord(sessionId: id, state: state, cwd: "/tmp/x", title: id, transcriptPath: "", message: nil,
                      updatedAt: now.addingTimeInterval(-age).timeIntervalSince1970 * 1000)
    }

    func testGroupsThenRecencyWithEndedLast() {
        let now = Date()
        let sessions = [
            record("done-new", .done, age: 10, now: now),
            record("ended-newest", .ended, age: 1, now: now),
            record("running-old", .running, age: 300, now: now),
            record("ask", .waitingInput, age: 600, now: now),
            record("compacting", .compacting, age: 5, now: now),
            record("permission", .waitingPermission, age: 20, now: now),
            record("stale", .running, age: 3 * 3600, now: now),
            record("done-old", .done, age: 400, now: now),
        ]
        XCTAssertEqual(SessionRecord.displayOrder(sessions, now: now).map(\.sessionId),
                       ["permission", "ask", "compacting", "running-old", "done-new", "done-old", "stale", "ended-newest"])
        XCTAssertEqual(SessionRecord.shortcutOrder(sessions, now: now).map(\.sessionId),
                       ["permission", "ask", "compacting", "running-old", "done-new", "done-old", "stale"],
                       "⌘N 不数已关闭的：按到它会开新终端")
    }

    func testCrowdedCWDsOnlyWhereADirectoryRepeats() {
        // 同目录跑同一个 skill 的两条标题只差 URL 尾巴，行上得多标 tty；单独一条的目录不标
        let now = Date()
        var a = record("a", .running, age: 1, now: now); a.cwd = "/vault/note"
        var b = record("b", .done, age: 2, now: now); b.cwd = "/vault/note"
        var c = record("c", .running, age: 3, now: now); c.cwd = "/work/tally"
        XCTAssertEqual(SessionRecord.crowdedCWDs([a, b, c]), ["/vault/note"])
        XCTAssertEqual(SessionRecord.crowdedCWDs([a, c]), [])
    }

    func testGroupOfEachState() {
        let now = Date()
        XCTAssertEqual(record("a", .waitingPermission, age: 0, now: now).group(now: now), .waiting)
        XCTAssertEqual(record("a", .compacting, age: 0, now: now).group(now: now), .working)
        XCTAssertEqual(record("a", .done, age: 0, now: now).group(now: now), .recent)
        XCTAssertEqual(record("a", .ended, age: 0, now: now).group(now: now), .closed, "已关闭单独一组")
        XCTAssertEqual(record("a", .ended, age: 3 * 3600, now: now).group(now: now), .closed)
        XCTAssertEqual(record("a", .waitingInput, age: 3 * 3600, now: now).group(now: now), .recent, "失联的进最近")
        XCTAssertFalse(record("a", .ended, age: 3 * 3600, now: now).isStale(now: now), "已关闭不算失联")
    }
}

/// 已关闭的会话（docs/ai.md「陈旧、存活、清理」「已关闭的会话」）。
final class SessionLifecycleTests: XCTestCase {

    private var directory: URL!
    private var transcripts: URL!
    private var keep = true
    private var limit = 10

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tally-life-\(UUID().uuidString)")
        directory = root.appendingPathComponent("sessions")
        transcripts = root.appendingPathComponent("transcripts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        keep = true
    }

    /// entrypoint 决定是不是交互会话；pid 999_999 超过 macOS 的 pid 上限，一定是「进程没了」。
    private func write(_ id: String, state: SessionRecord.State, entrypoint: String = "cli", updatedAt: Double = 1) throws {
        let transcript = transcripts.appendingPathComponent("\(id).jsonl")
        try (#"{"type":"user","entrypoint":"\#(entrypoint)","message":{"content":"跑一下"}}"# + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let record = SessionRecord(sessionId: id, pid: 999_999, state: state, cwd: "/tmp/x", title: id,
                                   transcriptPath: transcript.path, message: "上一句", updatedAt: updatedAt)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("\(id).json"))
    }

    @MainActor
    private func makeStore() -> SessionStore {
        SessionStore(directory: directory, claudeSessions: transcripts, keepClosed: { [unowned self] in self.keep },
                     closedLimit: { [unowned self] in self.limit })
    }

    private func onDisk(_ id: String) throws -> SessionRecord? {
        let file = directory.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(SessionRecord.self, from: Data(contentsOf: file))
    }

    /// 没标题的会话用第一句话顶上：Codex 从不写标题，用户还没敲字时退回目录名，敲了之后下一次读目录就补上。
    @MainActor
    func testUntitledSessionGetsFirstPromptOnceTyped() throws {
        let transcript = transcripts.appendingPathComponent("codex.jsonl")
        try "{\"type\":\"session_meta\",\"payload\":{\"originator\":\"codex-tui\"}}\n".write(to: transcript, atomically: true, encoding: .utf8)
        let record = SessionRecord(sessionId: "codex", provider: "codex", pid: 999_999, state: .ended, cwd: "/tmp/x", title: nil,
                                   transcriptPath: transcript.path, message: nil, updatedAt: 1)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("codex.json"))
        let store = makeStore()
        store.reload()
        XCTAssertEqual(store.sessions.first?.displayTitle, "x")
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"看下安装\"}]}}\n".utf8))
        try handle.close()
        store.reload()
        XCTAssertEqual(store.sessions.first?.displayTitle, "看下安装")
    }

    @MainActor
    func testDeadInteractiveSessionBecomesEndedAndScriptedOneIsDeleted() throws {
        try write("interactive", state: .done)
        try write("scripted", state: .running, entrypoint: "sdk-cli")
        let store = makeStore()
        var alerts: [SessionRecord] = []
        store.sessionAlert = { alerts.append($0) }
        store.reload()
        XCTAssertEqual(store.sessions.map(\.sessionId), ["interactive"])
        XCTAssertEqual(store.sessions.first?.state, .ended)
        XCTAssertNil(store.sessions.first?.message)
        XCTAssertEqual(try onDisk("interactive")?.state, .ended, "改的是文件，下次读还是已关闭")
        XCTAssertNil(try onDisk("scripted"), "claude -p 这种不留")

        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .ended, "已关闭的本来就没有进程，不删")
        XCTAssertTrue(alerts.isEmpty, "进入已关闭不弹")
    }

    @MainActor
    func testOnlyNewestEndedAreKeptUpToTheSetting() throws {
        limit = 3
        for i in 0..<5 {
            try write("e\(i)", state: .ended, updatedAt: Double(i + 1))
        }
        let store = makeStore()
        store.reload()
        XCTAssertEqual(store.sessions.count, 3, "按设置里的条数留")
        XCTAssertNil(try onDisk("e0"), "最旧的两条删掉")
        XCTAssertNil(try onDisk("e1"))
        XCTAssertNotNil(try onDisk("e4"))
    }

    @MainActor
    func testTurningTheSwitchOffDeletesEndedAndDeadSessions() throws {
        try write("ended", state: .ended)
        try write("dead", state: .done)
        keep = false
        let store = makeStore()
        store.reload()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(try onDisk("ended"))
        XCTAssertNil(try onDisk("dead"))
    }

    @MainActor
    func testCodexDaemonPidDoesNotKeepClosedTUISessionsInRecent() throws {
        let cwd = transcripts.path
        for (id, updatedAt) in [("old", 1.0), ("middle", 2.0), ("current", 3.0)] {
            let transcript = transcripts.appendingPathComponent("\(id).jsonl")
            try #"{"type":"session_meta","payload":{"originator":"codex-tui","source":"vscode"}}"#
                .write(to: transcript, atomically: true, encoding: .utf8)
            let record = SessionRecord(sessionId: id, provider: "codex", pid: Int(ProcessInfo.processInfo.processIdentifier),
                                       state: .done, cwd: cwd, title: id, transcriptPath: transcript.path,
                                       message: nil, updatedAt: updatedAt)
            try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("\(id).json"))
        }
        var active = 1
        let store = SessionStore(directory: directory, claudeSessions: transcripts,
                                 keepClosed: { true }, closedLimit: { 10 },
                                 activeCodexTUIByCWD: { [unowned self] in [self.transcripts.path: active] })
        store.reload()
        XCTAssertEqual(try onDisk("old")?.state, .done, "An idle older session may be the live TUI")
        XCTAssertEqual(try onDisk("middle")?.state, .done)
        XCTAssertEqual(try onDisk("current")?.state, .done, "A newer session may have exited without SessionEnd")
        XCTAssertEqual(SessionRecord.shortcutOrder(store.sessions, now: Date()).count, 3)

        active = 0
        store.reload()
        XCTAssertEqual(try onDisk("old")?.state, .ended)
        XCTAssertEqual(try onDisk("middle")?.state, .ended)
        XCTAssertEqual(try onDisk("current")?.state, .ended, "The daemon survives after the last TUI exits")
        XCTAssertTrue(SessionRecord.shortcutOrder(store.sessions, now: Date()).isEmpty)
    }

    @MainActor
    func testCompactingAndEndedNeverAlert() {
        func record(_ state: SessionRecord.State) -> SessionRecord {
            SessionRecord(sessionId: "a", state: state, cwd: "/tmp", title: nil, transcriptPath: "", message: nil, updatedAt: 1)
        }
        XCTAssertTrue(SessionStore.alerts(previous: [record(.running)], current: [record(.compacting)]).isEmpty)
        XCTAssertTrue(SessionStore.alerts(previous: [record(.done)], current: [record(.ended)]).isEmpty)
        XCTAssertEqual(SessionStore.alerts(previous: [record(.compacting)], current: [record(.done)]).count, 1, "压缩完再跑完照常弹")
    }
}

final class TmuxLocatorTests: XCTestCase {

    func testPaneByTTY() {
        let listing = "/dev/ttys001\t%1\twork\n/dev/ttys003\t%0\ttally-probe\n"
        XCTAssertEqual(TmuxLocator.pane(tty: "ttys003", listing: listing)?.id, "%0", "记录里的 tty 不带 /dev/")
        XCTAssertEqual(TmuxLocator.pane(tty: "/dev/ttys001", listing: listing)?.session, "work")
        XCTAssertNil(TmuxLocator.pane(tty: "ttys009", listing: listing))
    }

    func testClientPrefersSameSessionThenMostRecent() {
        let listing = "/dev/ttys010\t501\tother\t300\n/dev/ttys011\t502\twork\t100\n/dev/ttys012\t503\tother\t200\n"
        XCTAssertEqual(TmuxLocator.client(session: "work", listing: listing), TmuxLocator.Client(tty: "/dev/ttys011", pid: 502, session: "work"))
        XCTAssertEqual(TmuxLocator.client(session: "nope", listing: listing)?.pid, 501, "没有挂在同一会话上的就取最近活动的")
        XCTAssertNil(TmuxLocator.client(session: "work", listing: ""), "detach 在后台的会话没有客户端")
    }

    func testKindRecognizesTmux() {
        XCTAssertEqual(TerminalLocator.kind(for: "tmux", running: { _ in false }), .tmux)
    }
}

final class SessionResumeTests: XCTestCase {

    private func record(provider: String, cwd: String) -> SessionRecord {
        SessionRecord(sessionId: "abc-123", provider: provider, state: .ended, cwd: cwd, title: nil, transcriptPath: "", message: nil, updatedAt: 1)
    }

    func testCommandPerProviderWithQuoting() {
        XCTAssertEqual(SessionResume.resumeCommand(for: record(provider: "claude", cwd: "/x")), "claude --resume 'abc-123'")
        XCTAssertEqual(SessionResume.command(for: record(provider: "claude", cwd: "/Users/me/my repo")),
                       "cd '/Users/me/my repo' && claude --resume 'abc-123'")
        XCTAssertEqual(SessionResume.command(for: record(provider: "codex", cwd: "/tmp/it's")),
                       "cd '/tmp/it'\\''s' && codex resume 'abc-123'")
    }

    func testAppleScriptStringEscapesQuotesAndBackslashes() {
        XCTAssertEqual(SessionResume.appleScriptString(#"cd "a\b""#), #""cd \"a\\b\"""#)
    }

    /// Ghostty 的 initial input 里不能有非 ASCII（它按字节转义再按码点解析，中文会二次编码），目录只能走 initial working directory。
    func testGhosttyScriptKeepsDirectoryOutOfInitialInput() {
        let script = SessionResume.ghosttyScript(cwd: "/Users/me/电脑壁纸", command: "claude --resume 'x'")
        XCTAssertTrue(script.contains(#"set initial working directory of cfg to "/Users/me/电脑壁纸""#))
        XCTAssertTrue(script.contains(#"set initial input of cfg to "claude --resume 'x'" & linefeed"#))
        XCTAssertFalse(script.contains("cd "))
    }

    /// 目录没了就不开终端：Ghostty / tmux 拿到不存在的目录会退回默认目录再跑 resume，报的会是「找不到会话」。
    @MainActor
    func testRunRefusesMissingDirectory() async {
        do {
            try await SessionResume.run(record(provider: "claude", cwd: "/nonexistent/\(UUID().uuidString)"))
            XCTFail("should throw before opening a terminal")
        } catch {
            XCTAssertEqual(error as? TerminalLocator.Failure, .directoryMissing)
        }
    }
}
