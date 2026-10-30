import XCTest
@testable import Tally

/// 测试里把本进程当成 agent 本体：真进程表里 xctest 不是 claude / codex，存活判断会把带本进程 pid 的记录当成「进程没了」。
struct AgentProcessTable: ProcessTable {
    var comm = "claude"
    var args: [String] = []
    func entries() -> [ProcessEntry] {
        [ProcessEntry(pid: ProcessInfo.processInfo.processIdentifier, ppid: 1, comm: comm, path: "/usr/local/bin/\(comm)", tdev: nil)]
    }
    func arguments(of pid: Int32) -> [String] { args }
}

final class SessionModelTests: XCTestCase {

    private func record(state: SessionRecord.State, ageSeconds: Double, now: Date, title: String? = "标题") -> SessionRecord {
        SessionRecord(
            sessionId: "s1",
            state: state,
            cwd: "/Users/me/workspace/MacAppProject",
            title: title,
            transcriptPath: "",
            message: nil,
            updatedAt: now.addingTimeInterval(-ageSeconds).timeIntervalSince1970 * 1000
        )
    }

    func testDecodesHookJSON() throws {
        let json = """
        {"session_id":"abc","provider":"codex","pid":4242,"state":"waiting_permission","cwd":"/tmp/x","title":null,"transcript_path":"/t.jsonl","message":null,"updated_at":1700000000000}
        """
        let r = try JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8))
        XCTAssertEqual(r.sessionId, "abc")
        XCTAssertEqual(r.provider, "codex")
        XCTAssertEqual(r.providerLabel, "Codex")
        XCTAssertEqual(r.pid, 4242)
        XCTAssertEqual(r.state, .waitingPermission)
        XCTAssertNil(r.title)
        XCTAssertEqual(r.updatedDate, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(r.isWaiting)
    }

    func testModelShortNames() {
        XCTAssertEqual(SessionRecord.shortModelName("claude-opus-5"), "Opus 5")
        XCTAssertEqual(SessionRecord.shortModelName("claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(SessionRecord.shortModelName("claude-fable-5-1"), "Fable 5.1")
        XCTAssertEqual(SessionRecord.shortModelName("claude-haiku-4-5-20251001"), "Haiku 4.5", "去掉日期戳")
        XCTAssertEqual(SessionRecord.shortModelName("claude-3-5-sonnet-20241022"), "Sonnet 3.5", "老式命名版本号在前")
        XCTAssertEqual(SessionRecord.shortModelName("gpt-6-astra"), "gpt-6-astra", "别家的原样用，不猜营销名")
        var r = record(state: .running, ageSeconds: 0, now: Date())
        XCTAssertNil(r.modelLabel, "还不知道模型")
        r.model = "claude-sonnet-5"
        XCTAssertEqual(r.modelLabel, "Sonnet 5")
    }

    func testOldJSONWithoutModelDecodes() throws {
        let json = #"{"session_id":"abc","provider":"codex","state":"done","cwd":"/tmp","updated_at":1}"#
        XCTAssertNil(try JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8)).model)
    }

    func testOldJSONWithoutProviderIsClaude() throws {
        let json = #"{"session_id":"abc","state":"done","cwd":"/tmp","updated_at":1}"#
        let r = try JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8))
        XCTAssertEqual(r.provider, "claude")
        XCTAssertTrue(r.isClaude)
        XCTAssertNil(r.pid)
        XCTAssertEqual(r.transcriptPath, "")
    }

    // 陈旧与清理表 3 行

    func testNonDoneOlderThanTwoHoursIsStale() {
        let now = Date()
        XCTAssertTrue(record(state: .waitingPermission, ageSeconds: 2 * 3600 + 1, now: now).isStale(now: now))
        XCTAssertFalse(record(state: .running, ageSeconds: 2 * 3600 - 1, now: now).isStale(now: now))
    }

    func testDoneNeverStale() {
        let now = Date()
        XCTAssertFalse(record(state: .done, ageSeconds: 3 * 3600, now: now).isStale(now: now))
    }

    func testOrphansOlderThan24Hours() {
        let now = Date()
        let old = URL(fileURLWithPath: "/tmp/old.json")
        let fresh = URL(fileURLWithPath: "/tmp/fresh.json")
        let result = SessionRecord.orphans(
            files: [(old, now.addingTimeInterval(-24 * 3600 - 1)), (fresh, now.addingTimeInterval(-23 * 3600))],
            now: now
        )
        XCTAssertEqual(result, [old])
    }

    // 存活

    func testProcessIsGoneUsesKillZero() {
        var alive = record(state: .running, ageSeconds: 0, now: Date())
        alive.pid = Int(ProcessInfo.processInfo.processIdentifier)
        XCTAssertFalse(alive.processIsGone)

        var dead = alive
        dead.pid = 999_999 // 超过 macOS 的 pid 上限，不可能存在
        XCTAssertTrue(dead.processIsGone)

        var unknown = alive
        unknown.pid = nil
        XCTAssertFalse(unknown.processIsGone)
    }

    func testProcessIsGoneWhenThePidNoLongerBelongsToAnAgent() {
        // 关机重启后低位 pid 很快被系统进程拿走，kill(pid, 0) 对别人的进程返回 EPERM、看着像活着：进程表里那一行得是 agent 本体
        var record = record(state: .done, ageSeconds: 0, now: Date())
        record.pid = 2297
        let agent = ProcessEntry(pid: 2297, ppid: 1, comm: "2.1.311", path: "/Users/me/.local/share/claude/versions/2.1.311", tdev: nil)
        let daemon = ProcessEntry(pid: 2297, ppid: 1, comm: "mdworker", path: "/System/Library/Frameworks/CoreServices.framework/mdworker", tdev: nil)
        let table = AgentProcessTable()
        XCTAssertFalse(record.processIsGone(in: [2297: agent], table: table))
        XCTAssertTrue(record.processIsGone(in: [2297: daemon], table: table), "pid 被系统进程复用")
        XCTAssertTrue(record.processIsGone(in: [:], table: table), "进程表里没有")
        // 路径或 argv 读不到是瞬时失败（root 的进程也读得到路径，不是权限问题）：判不了就当还活着，误判成没了会把活会话改成已关闭
        let unreadable = ProcessEntry(pid: 2297, ppid: 1, comm: "2.1.311", path: "", tdev: nil)
        XCTAssertFalse(record.processIsGone(in: [2297: unreadable], table: table), "路径读不到")
        let node = ProcessEntry(pid: 2297, ppid: 1, comm: "node", path: "/opt/homebrew/bin/node", tdev: nil)
        XCTAssertFalse(record.processIsGone(in: [2297: node], table: AgentProcessTable(args: [])), "argv 读不到")
        XCTAssertTrue(record.processIsGone(in: [2297: node], table: AgentProcessTable(args: ["node", "/srv/app.js"])), "是别的 node")
        XCTAssertFalse(record.processIsGone(in: [2297: node], table: AgentProcessTable(args: ["node", "/x/claude-code/cli.js"])))
        record.pid = nil
        XCTAssertFalse(record.processIsGone(in: [:], table: table), "没拿到 pid 的记录不按进程判")
    }

    func testClaudeCodeStatusDistinguishesMissingSessionIdFromAnotherSession() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tally-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var record = record(state: .done, ageSeconds: 0, now: Date())
        record.pid = 4242
        let file = dir.appendingPathComponent("4242.json")
        try Data(#"{"pid":4242,"status":"busy"}"#.utf8).write(to: file)
        XCTAssertEqual(record.claudeCodeStatus(in: dir), .unknown, "没有 sessionId 的文件说不清是谁的，不能当成别的会话把活会话收掉")
        try Data(#"{"pid":4242,"sessionId":"someone-else","status":"busy"}"#.utf8).write(to: file)
        XCTAssertEqual(record.claudeCodeStatus(in: dir), .anotherSession)
        try Data(#"{"pid":4242,"sessionId":"s1","status":"waiting","waitingFor":"input needed"}"#.utf8).write(to: file)
        XCTAssertEqual(record.claudeCodeStatus(in: dir), .reported(status: "waiting", waitingFor: "input needed", since: nil))
        try Data(#"{"pid":4242,"sessionId":"s1","status":"waiting","statusUpdatedAt":1700000000500}"#.utf8).write(to: file)
        XCTAssertEqual(record.claudeCodeStatus(in: dir), .reported(status: "waiting", waitingFor: nil, since: Date(timeIntervalSince1970: 1_700_000_000.5)), "statusUpdatedAt 是毫秒")
        try Data(#"{"pid":4242,"sessionId":"s1"}"#.utf8).write(to: file)
        XCTAssertEqual(record.claudeCodeStatus(in: dir), .unknown, "没有 status 字段")
        record.pid = nil
        XCTAssertEqual(record.claudeCodeStatus(in: dir), .unknown)
    }

    // 徽标与显示

    func testWaitingCountExcludesStale() {
        let now = Date()
        XCTAssertTrue(record(state: .waitingInput, ageSeconds: 60, now: now).countsAsWaiting(now: now))
        XCTAssertFalse(record(state: .waitingInput, ageSeconds: 3 * 3600, now: now).countsAsWaiting(now: now))
        XCTAssertFalse(record(state: .running, ageSeconds: 60, now: now).countsAsWaiting(now: now))
    }

    func testDisplayTitleFallsBackToCwdLastComponent() {
        let now = Date()
        XCTAssertEqual(record(state: .running, ageSeconds: 0, now: now, title: nil).displayTitle, "MacAppProject")
        XCTAssertEqual(record(state: .running, ageSeconds: 0, now: now, title: "").displayTitle, "MacAppProject")
        var root = record(state: .running, ageSeconds: 0, now: now, title: nil)
        root.cwd = "/"
        XCTAssertEqual(root.cwdLabel, "/")
    }
}

final class SessionAlertTests: XCTestCase {

    private func record(_ id: String, _ state: SessionRecord.State) -> SessionRecord {
        SessionRecord(sessionId: id, state: state, cwd: "/tmp/x", title: "t", transcriptPath: "", message: nil, updatedAt: 1)
    }

    @MainActor
    func testRunningToDoneCounts() {
        let out = SessionStore.alerts(previous: [record("a", .running), record("b", .waitingInput)],
                                      current: [record("a", .done), record("b", .done)])
        XCTAssertEqual(out.map(\.sessionId), ["a", "b"])
    }

    @MainActor
    func testEnteringWaitingCounts() {
        XCTAssertEqual(SessionStore.alerts(previous: [record("a", .running)], current: [record("a", .waitingPermission)]).count, 1, "等审批要弹")
        XCTAssertEqual(SessionStore.alerts(previous: [record("a", .running)], current: [record("a", .waitingInput)]).count, 1, "等输入要弹")
        XCTAssertTrue(SessionStore.alerts(previous: [record("a", .waitingPermission)], current: [record("a", .running)]).isEmpty, "审批过了回到 running 不弹")
    }

    @MainActor
    func testFirstSeenAlreadyDoneDoesNotCount() {
        XCTAssertTrue(SessionStore.alerts(previous: [], current: [record("a", .done), record("b", .waitingPermission)]).isEmpty)
    }

    @MainActor
    func testSameStateDoesNotRepeat() {
        XCTAssertTrue(SessionStore.alerts(previous: [record("a", .done)], current: [record("a", .done)]).isEmpty)
        XCTAssertTrue(SessionStore.alerts(previous: [record("a", .waitingInput)], current: [record("a", .waitingInput)]).isEmpty)
    }

    @MainActor
    func testEveryTurnCounts() {
        // done → running → done：第二个回合结束也要提示
        XCTAssertTrue(SessionStore.alerts(previous: [record("a", .done)], current: [record("a", .running)]).isEmpty)
        XCTAssertEqual(SessionStore.alerts(previous: [record("a", .running)], current: [record("a", .done)]).count, 1)
    }

    @MainActor
    func testQuietSessionsDoNotCount() {
        let out = SessionStore.alerts(previous: [record("a", .running), record("b", .running)],
                                      current: [record("a", .done), record("b", .done)], quiet: ["a"])
        XCTAssertEqual(out.map(\.sessionId), ["b"], "打断补判出来的 done 不弹")
    }
}

/// 打断和 API 报错结束的回合不发 Stop：app 读 transcript 尾巴补判（docs/ai.md「打断与 API 报错」）。
final class SessionTurnEndTests: XCTestCase {

    private var directory: URL!
    private var transcript: URL!
    private var claudeSessions: URL!

    private let prompt = #"{"type":"user","message":{"role":"user","content":"跑一下"}}"#
    private let interrupt = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
    private let apiError = #"{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit · resets 3pm"}]}}"#
    private let snapshot = #"{"type":"file-history-snapshot","snapshot":{}}"#

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tally-turn-\(UUID().uuidString)")
        directory = root.appendingPathComponent("sessions")
        transcript = root.appendingPathComponent("t.jsonl")
        claudeSessions = root.appendingPathComponent("claude-sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeSessions, withIntermediateDirectories: true)
    }

    /// 模拟 hook 写的状态文件 + 此刻的 transcript。
    private func write(state: SessionRecord.State, provider: String = "claude", updatedAt: Double = 1, transcript lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let record = SessionRecord(sessionId: "s1", provider: provider, pid: Int(ProcessInfo.processInfo.processIdentifier),
                                   state: state, cwd: "/tmp/x", title: "t", transcriptPath: transcript.path, message: nil, updatedAt: updatedAt)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("s1.json"))
    }

    /// 模拟 Claude Code 自己写的 `~/.claude/sessions/<pid>.json`；pid 用测试进程自己的，存活判定才过得去。
    private func writeClaudeStatus(_ status: String, sessionId: String = "s1", waitingFor: String? = nil, sinceMs: Int = 1) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let extra = waitingFor.map { #","waitingFor":"\#($0)""# } ?? ""
        let json = #"{"pid":\#(pid),"sessionId":"\#(sessionId)","status":"\#(status)","statusUpdatedAt":\#(sinceMs)\#(extra)}"#
        try Data(json.utf8).write(to: claudeSessions.appendingPathComponent("\(pid).json"))
    }

    @MainActor
    private func makeStore() -> SessionStore {
        SessionStore(directory: directory, claudeSessions: claudeSessions, processTable: AgentProcessTable())
    }

    /// 开始等的时刻与等你账本（docs/ai.md「等你」「等你账本」）。
    @MainActor
    func testWaitingSinceFollowsClaudeAndFinishedWaitsGoToTheLedger() throws {
        let store = makeStore()
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let at = { (offsetMs: Int) in Date(timeIntervalSince1970: Double(nowMs + offsetMs) / 1000) }
        try write(state: .waitingPermission, updatedAt: Double(nowMs), transcript: [prompt])
        try writeClaudeStatus("waiting", waitingFor: "permission prompt", sinceMs: nowMs - 90_000)
        store.reload()
        XCTAssertEqual(store.sessions.first?.waitingSince, at(-90_000), "Claude 记录取 statusUpdatedAt，比 hook 写文件早")
        XCTAssertNil(store.todayWaits, "还在等，账本没有今天这行")

        // 批了、马上又弹，两次刷新之间：Claude 的 statusUpdatedAt 变晚就是新的一次等，上一次按两个时刻之差记
        try writeClaudeStatus("waiting", waitingFor: "permission prompt", sinceMs: nowMs - 30_000)
        store.reload()
        XCTAssertEqual(store.sessions.first?.waitingSince, at(-30_000))
        XCTAssertEqual(store.todayWaits, WaitLedger.Day(count: 1, totalMs: 60_000, maxMs: 60_000))

        // 别的 agent 的 PostToolUse 把文件冲回 running、updated_at 变新：还在等，开始等的时刻不往后挪
        try write(state: .running, updatedAt: Double(nowMs + 30_000), transcript: [prompt])
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .waitingPermission)
        XCTAssertEqual(store.sessions.first?.waitingSince, at(-30_000))
        XCTAssertEqual(store.todayWaits?.count, 1, "同一次等，不重复记")

        try writeClaudeStatus("busy")
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .running)
        XCTAssertNil(store.sessions.first?.waitingSince)
        let day = try XCTUnwrap(store.todayWaits, "批了：记一笔")
        XCTAssertEqual(day.count, 2)
        XCTAssertTrue((89_000...95_000).contains(day.totalMs), "60 秒加约 30 秒，实际 \(day.totalMs) ms")
        XCTAssertEqual(day.maxMs, 60_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("waits.json").path),
                      "账本落在会话目录旁边")

        // 没有 statusUpdatedAt 的来源（老版本、Codex）退回 hook 写文件的时刻，之后沿用
        try FileManager.default.removeItem(at: claudeSessions.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier).json"))
        try write(state: .waitingInput, updatedAt: Double(nowMs + 60_000), transcript: [prompt])
        store.reload()
        XCTAssertEqual(store.sessions.first?.waitingSince, at(60_000))
        try write(state: .waitingInput, updatedAt: Double(nowMs + 61_000), transcript: [prompt])
        store.reload()
        XCTAssertEqual(store.sessions.first?.waitingSince, at(60_000), "hook 再写不往后挪")

        try write(state: .done, updatedAt: Double(nowMs + 62_000), transcript: [prompt])
        store.reload()
        XCTAssertEqual(store.todayWaits?.count, 3, "答了：又一笔")
    }

    @MainActor
    func testInterruptSettlesToDoneQuietlyAndNextPromptRunsAgain() throws {
        var alerts: [SessionRecord] = []
        let store = makeStore()
        store.sessionAlert = { alerts.append($0) }

        try write(state: .waitingPermission, transcript: [prompt])
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .waitingPermission)

        // 在审批框上按 Esc：没有 Stop，文件还是等审批
        try write(state: .waitingPermission, transcript: [prompt, interrupt, snapshot])
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .done)
        XCTAssertNil(store.sessions.first?.message)
        XCTAssertTrue(alerts.isEmpty, "人就在终端前按的键，不弹")

        // 下一句话：hook 写 running，尾巴最后一条是新输入
        try write(state: .running, transcript: [prompt, interrupt, snapshot, prompt])
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .running)
        XCTAssertTrue(alerts.isEmpty)
    }

    @MainActor
    func testApiErrorSettlesToDoneAndAlertsWithTheError() throws {
        var alerts: [SessionRecord] = []
        let store = makeStore()
        store.sessionAlert = { alerts.append($0) }

        try write(state: .running, transcript: [prompt])
        store.reload()
        try write(state: .running, transcript: [prompt, apiError])
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .done)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.message, "You've hit your session limit · resets 3pm")
    }

    @MainActor
    func testCodexAndDoneRecordsAreLeftAlone() throws {
        let store = makeStore()
        try write(state: .running, provider: "codex", transcript: [prompt, interrupt])
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .running, "Codex 按自己 rollout 的格式判，Claude 的打断标记不算")

        try write(state: .done, transcript: [prompt, apiError])
        store.reload()
        XCTAssertNil(store.sessions.first?.message, "已经是 done 的不读尾巴、不改 message")
    }

    @MainActor
    func testCodexRolloutAbortSettlesQuietlyAndErrorAlerts() throws {
        // 实测 codex 0.154：Esc 和模型报错都不发 Stop，rollout 里当场写 turn_aborted / 带 error 的 task_complete
        var alerts: [SessionRecord] = []
        let store = makeStore()
        store.sessionAlert = { alerts.append($0) }
        let started = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"#

        try write(state: .running, provider: "codex", transcript: [started])
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .running)

        try write(state: .running, provider: "codex", transcript: [started, #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t1","reason":"interrupted"}}"#])
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .done)
        XCTAssertTrue(alerts.isEmpty, "Esc 是人按的，不弹")

        try write(state: .running, provider: "codex", transcript: [started, #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t2"}}"#])
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .running, "下一轮开始回到忙")
        try write(state: .running, provider: "codex",
                  transcript: [started, #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t2","error":{"message":"model not found"}}}"#])
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .done)
        XCTAssertEqual(alerts.map(\.message), [Optional("model not found")], "报错照常弹，带报错原文")
    }

    @MainActor
    func testClaudeCodeIdleStatusSettlesInterruptWithoutMarkerQuietly() throws {
        // 还没开始输出就按 Esc：打断标记要等下一句话才写进 transcript，只有 Claude Code 自己的 status 变成 idle
        var alerts: [SessionRecord] = []
        let store = makeStore()
        store.sessionAlert = { alerts.append($0) }

        try write(state: .running, transcript: [prompt])
        try writeClaudeStatus("busy")
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .running)

        try writeClaudeStatus("idle")
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .done)
        XCTAssertTrue(alerts.isEmpty, "打断不弹")
    }

    @MainActor
    func testDoneRecordShowsBackgroundWorkFromClaudeCodeStatus() throws {
        // 主回合 Stop 写了 done，后台 agent 还在跑：Claude Code 的 status 留在 busy；只剩后台命令是 shell（docs/ai.md「后台还在跑」）
        var alerts: [SessionRecord] = []
        let store = makeStore()
        store.sessionAlert = { alerts.append($0) }

        try write(state: .running, transcript: [prompt])
        try writeClaudeStatus("busy")
        store.reload()
        XCTAssertNil(store.sessions.first?.backgroundWork, "忙着的记录不标：busy 是主回合自己")

        try write(state: .done, transcript: [prompt])
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .done)
        XCTAssertEqual(store.sessions.first?.backgroundWork, .agents)
        XCTAssertEqual(store.sessions.first?.group(now: Date()), .working)
        XCTAssertEqual(alerts.count, 1, "完成提示只在 Stop 那次弹")

        try writeClaudeStatus("shell")
        store.reload()
        XCTAssertEqual(store.sessions.first?.backgroundWork, .shells)
        XCTAssertEqual(store.sessions.first?.group(now: Date()), .working)

        try writeClaudeStatus("idle")
        store.reload()
        XCTAssertNil(store.sessions.first?.backgroundWork, "后台的活干完了")
        XCTAssertEqual(store.sessions.first?.group(now: Date()), .recent)
        XCTAssertEqual(alerts.count, 1)

        try writeClaudeStatus("busy", sessionId: "someone-else")
        store.reload()
        XCTAssertNil(store.sessions.first?.backgroundWork, "pid 被复用、sessionId 对不上不算")
        XCTAssertEqual(store.sessions.first?.state, .ended, "状态文件属于别的会话，这条的会话已经不在了")

        try write(state: .done, provider: "codex", transcript: [prompt])
        try writeClaudeStatus("busy")
        store.reload()
        XCTAssertNil(store.sessions.first?.backgroundWork, "Codex 没有这种状态文件，碰巧同 pid 也不读")
    }

    @MainActor
    func testFreshDoneDoesNotTrustStaleBusyAndInterruptRoundNeverLabels() throws {
        // Stop 刚落地：上一回合的 busy 要等所有 Stop hook 跑完才换成 idle（本机实测 45 ms，门禁类 hook 能拖几秒），刚写的 done 读到 busy 不算
        let store = makeStore()
        try write(state: .done, updatedAt: Date().timeIntervalSince1970 * 1000, transcript: [prompt])
        try writeClaudeStatus("busy")
        store.reload()
        XCTAssertNil(store.sessions.first?.backgroundWork, "宽限期内的 busy 是上一回合的")

        try writeClaudeStatus("shell")
        store.reload()
        XCTAssertEqual(store.sessions.first?.backgroundWork, .shells, "shell 是主回合空闲时才写的，当场算")

        // 按 Esc 打断、下一句话刚发：app 按 transcript 补判成 done，这时的 busy 是新回合的，hook 的 running 马上就到
        try write(state: .running, transcript: [prompt, interrupt])
        try writeClaudeStatus("busy")
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .done)
        XCTAssertNil(store.sessions.first?.backgroundWork, "补判那轮不标，只认盘上已经是 done 的")
    }

    @MainActor
    func testClaudeCodeStatusMustBeIdleAndBelongToTheSession() throws {
        let store = makeStore()
        try write(state: .waitingPermission, transcript: [prompt])
        try writeClaudeStatus("waiting")
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .waitingPermission, "等审批时 Claude Code 写的是 waiting")

        try writeClaudeStatus("idle", sessionId: "someone-else")
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .ended, "pid 被复用成了别的会话，或同一进程 /clear 换了会话：这条记录的会话没了")

        try write(state: .waitingInput, transcript: [prompt])
        try writeClaudeStatus("idle")
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .waitingInput, "等输入（elicitation 对话框）不看 idle")
    }

    @MainActor
    func testWaitingQuestionAndAnswerFollowClaudeStatus() throws {
        let store = makeStore()
        let question = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","id":"q","input":{"questions":[{"question":"保留多久？"}]}}]}}"#
        let answer = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"q","content":"一天"}]}}"#
        try write(state: .waitingPermission, transcript: [prompt, question])
        try writeClaudeStatus("waiting", waitingFor: "input needed")
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .waitingInput)
        XCTAssertEqual(store.sessions.first?.waitingDetail, "问题：保留多久？")
        try write(state: .running, transcript: [prompt, question, answer])
        try writeClaudeStatus("busy")
        store.reload()
        XCTAssertNil(store.sessions.first?.waitingDetail)
    }

    @MainActor
    func testClaudeCodeWaitingStatusMarksWaitingWhateverTheHookWrote() throws {
        // AskUserQuestion、后台 agent 要审批、几个 agent 并行时别人的 PostToolUse 把等审批冲回 running：hook 那一路都看不出在等人，
        // Claude Code 自己的 status 是 waiting、waitingFor 说在等什么（docs/ai.md「等你」）
        var alerts: [SessionRecord] = []
        let store = makeStore()
        store.sessionAlert = { alerts.append($0) }

        try write(state: .done, transcript: [prompt])
        try writeClaudeStatus("idle")
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .done)

        try writeClaudeStatus("waiting", waitingFor: "permission prompt")
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .waitingPermission, "主回合 done 之后后台 agent 要审批")
        XCTAssertEqual(alerts.map(\.state), [.waitingPermission])
        XCTAssertNil(store.sessions.first?.backgroundWork, "标成等你的不再标后台")

        try write(state: .running, transcript: [prompt])
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .waitingPermission, "别的 agent 的 PostToolUse 把文件冲回 running，还是等你")
        XCTAssertEqual(alerts.count, 1, "状态没变就不再弹")

        try writeClaudeStatus("busy")
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .running, "审批过了")

        try writeClaudeStatus("waiting", waitingFor: "input needed")
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .waitingInput, "AskUserQuestion、elicitation 是等输入")
        XCTAssertEqual(alerts.map(\.state), [.waitingPermission, .waitingInput])

        // hook 写了等审批、Claude Code 已经在忙：对话框关了（答完、拒了）hook 还没写
        try write(state: .waitingPermission, transcript: [prompt])
        try writeClaudeStatus("busy")
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .running)
        XCTAssertEqual(alerts.count, 2)
    }

    @MainActor
    func testClaudeStatusFileChangeReloadsWithoutAHookEvent() async throws {
        // Claude Code 原地改写 <pid>.json（inode 不变），Tally 的目录没动：靠文件上的 vnode 监视器当场刷新
        let store = makeStore()
        try write(state: .done, transcript: [prompt])
        try writeClaudeStatus("idle")
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .done)

        try writeClaudeStatus("waiting", waitingFor: "permission prompt")
        for _ in 0..<40 where store.sessions.first?.state != .waitingPermission {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(store.sessions.first?.state, .waitingPermission)

        try FileManager.default.removeItem(at: claudeSessions.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier).json"))
        for _ in 0..<40 where store.sessions.first?.state != .done {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(store.sessions.first?.state, .done, "文件删了（.delete 也触发刷新）就回到 hook 写的状态；进程没了的话存活判断另算")
    }
}
