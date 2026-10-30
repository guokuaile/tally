import XCTest
@testable import Tally

/// 等你账本（docs/ai.md「等你账本」）：哪些算一笔、按天汇总、只留 7 天、写盘读回、标签写法。
@MainActor
final class WaitLedgerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ id: String, _ state: SessionRecord.State, since: TimeInterval? = nil) -> SessionRecord {
        var record = SessionRecord(sessionId: id, state: state, cwd: "/repo", title: id, transcriptPath: "", message: nil,
                                   updatedAt: now.timeIntervalSince1970 * 1000)
        record.waitingSince = since.map { now.addingTimeInterval(-$0) }
        return record
    }

    func testOnlyWaitsThatEndedThisRoundCount() {
        let previous = [record("answered", .waitingPermission, since: 120), record("closed", .waitingInput, since: 30),
                        record("still", .waitingPermission, since: 600), record("restarted", .waitingPermission, since: 300),
                        record("never", .running)]
        let current = [record("answered", .running), record("still", .waitingPermission, since: 600),
                       record("restarted", .waitingInput, since: 20), record("never", .done)]
        XCTAssertEqual(WaitLedger.finished(previous: previous, current: current, now: now).sorted(), [30, 120, 280],
                       "批了的和记录没了的各一笔；还在等的不记；批完马上又弹（开始等的时刻变晚）按两个时刻之差记上一次；没等过的不记")
        XCTAssertTrue(WaitLedger.finished(previous: current, current: current, now: now).isEmpty)
        XCTAssertTrue(WaitLedger.finished(previous: [], current: previous, now: now).isEmpty, "第一次露面就在等的还没结束，不记")
    }

    func testAggregatesPerLocalDayKeepsSevenDaysAndRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tally-waits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("waits.json")
        let ledger = WaitLedger(file: file)
        ledger.add([120, 360, 30], now: now)
        ledger.add([210], now: now)
        XCTAssertEqual(ledger.summary(on: now), WaitLedger.Day(count: 4, totalMs: 720_000, maxMs: 360_000))
        XCTAssertNil(ledger.summary(on: now.addingTimeInterval(-86400)))
        let calendar = Calendar.current
        let sixDaysAgo = calendar.date(byAdding: .day, value: -6, to: now)!, sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now)!
        ledger.add([5], now: sevenDaysAgo)
        ledger.add([7], now: sixDaysAgo)
        XCTAssertEqual(ledger.days.count, 3, "往回补的两天和今天各一条")
        ledger.add([6], now: now)
        XCTAssertEqual(ledger.days.keys.sorted(), [WaitLedger.key(sixDaysAgo), WaitLedger.key(now)], "写新笔时只留最近 7 天（含今天）：6 天前的留着，7 天前的丢")
        XCTAssertEqual(WaitLedger(file: file).summary(on: now), WaitLedger.Day(count: 5, totalMs: 726_000, maxMs: 360_000), "读回")
        let memory = WaitLedger(file: nil)
        memory.add([1], now: now)
        XCTAssertEqual(memory.summary(on: now)?.count, 1)
    }

    func testUnreadableFileIsSetAsideInsteadOfOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tally-waits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("waits.json"), bak = file.appendingPathExtension("bak")
        try Data("not json".utf8).write(to: file)
        let ledger = WaitLedger(file: file)
        XCTAssertTrue(ledger.days.isEmpty)
        XCTAssertEqual(try String(contentsOf: bak, encoding: .utf8), "not json", "读不回来的文件挪到 .bak，不被下一笔覆盖")
        ledger.add([1], now: now)
        XCTAssertEqual(WaitLedger(file: file).summary(on: now)?.count, 1)
        XCTAssertEqual(try String(contentsOf: bak, encoding: .utf8), "not json")
    }

    func testLabelFormats() {
        XCTAssertEqual(WaitLedger.label(WaitLedger.Day(count: 4, totalMs: 720_000, maxMs: 360_000)), "今天等你 4 次 · 共 12 分钟 · 最长 6 分钟")
        XCTAssertEqual(WaitLedger.duration(45_000), "45 秒")
        XCTAssertEqual(WaitLedger.duration(89_500), "1 分钟")
        XCTAssertEqual(WaitLedger.duration(3_900_000), "1 小时 5 分")
    }
}
