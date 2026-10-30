import XCTest
import SwiftUI
import Darwin
@testable import Tally

final class PillQueuePeekTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000)

    private func peek(_ id: String, style: Peek.Style = .session, sessionID: String? = nil) -> Peek {
        Peek(id: id, style: style, tint: .green, label: id, title: id, subtitle: nil, sessionId: sessionID)
    }

    private func add(_ id: String, to queue: inout PillQueue, at seconds: TimeInterval = 0,
                     style: Peek.Style = .session, sessionID: String? = nil) {
        queue.enqueue(peek(id, style: style, sessionID: sessionID), at: origin.addingTimeInterval(seconds),
                      sessionSeconds: 5, batterySeconds: 3)
    }

    private func record(_ id: String, provider: String = "claude", model: String? = "claude-opus-5") -> SessionRecord {
        var record = SessionRecord(sessionId: id, provider: provider, state: .running, cwd: "/repo", title: id, transcriptPath: "", message: nil,
                                   updatedAt: origin.timeIntervalSince1970 * 1000)
        record.model = model
        return record
    }

    private func project(_ id: String, _ sessions: [SessionRecord]) -> CrewProject {
        CrewProject(id: "claude:" + id, provider: "claude", path: id, name: String(id.split(separator: "/").last ?? "/"), sessions: sessions, mood: .run)
    }

    /// 工牌：通用版式的字段、按项目去重、不和同一会话的状态提示互相替换、展开面板清掉。
    func testBadgeDeduplicatesByProjectNotBySession() {
        let session = record("s1")
        let badge = Peek.badge(project("/code/repo", [session]))
        XCTAssertEqual(badge.style, .badge)
        XCTAssertEqual(badge.id, "badge-claude:s1")
        XCTAssertEqual(badge.label, "新会话")
        XCTAssertEqual(badge.title, "repo项目组")
        XCTAssertEqual(badge.subtitle, "Claude · Opus 5")
        XCTAssertEqual(badge.sessionId, "s1", "点工牌跳的是它最靠前的那条会话")
        XCTAssertNil(badge.provider, "不走会话版式")
        XCTAssertEqual(badge.crewMood, .run)
        XCTAssertEqual(badge.tint, CrewStyle.coral.lid, "工牌色跟项目当前状态的配色")

        var queue = PillQueue()
        queue.enqueue(badge, at: origin, sessionSeconds: 5, batterySeconds: 3)
        queue.enqueue(badge, at: origin.addingTimeInterval(1), sessionSeconds: 5, batterySeconds: 3)
        XCTAssertEqual(queue.visible.map(\.id), ["badge-claude:s1"], "同一会话只一张")
        queue.enqueue(Peek.session(session), at: origin.addingTimeInterval(2), sessionSeconds: 5, batterySeconds: 3)
        XCTAssertEqual(queue.visible.count, 2, "同一会话的完成提示不替换工牌")
        queue.enqueue(badge, at: origin.addingTimeInterval(3), sessionSeconds: 5, batterySeconds: 3)
        XCTAssertEqual(queue.visible.count, 2, "工牌也不替换会话提示")
        queue.enqueue(Peek.badge(project("/code/other", [record("s2")])), at: origin.addingTimeInterval(3), sessionSeconds: 5, batterySeconds: 3)
        XCTAssertEqual(queue.visible.count, 2)
        XCTAssertEqual(queue.pending.count, 1)
        queue.clear()
        XCTAssertTrue(queue.visible.isEmpty)
        XCTAssertTrue(queue.pending.isEmpty)
    }

    /// 停留跟会话走、优先级和配额一档、没有刘海屏不发通知；排队过期直接丢，不进「详情已过期」汇总。
    func testBadgeStaysSessionSecondsAndExpiredPendingIsDroppedNotSummarized() {
        let badge = Peek.badge(project("/code/repo", [record("s1")]))
        XCTAssertEqual(badge.duration(session: 5, battery: 3), 5)
        XCTAssertEqual(badge.priority, 1)
        XCTAssertFalse(badge.notifiesWithoutNotch)
        var queue = PillQueue()
        add("a", to: &queue, style: .ask, sessionID: "a")
        add("b", to: &queue, style: .ask, sessionID: "b")
        add("c", to: &queue, style: .ask, sessionID: "c")
        queue.enqueue(badge, at: origin, sessionSeconds: 5, batterySeconds: 3)
        XCTAssertEqual(queue.pending.map(\.id), [badge.id], "三条等你的占着位，工牌排队")
        queue.advance(to: origin.addingTimeInterval(61))
        XCTAssertTrue(queue.pending.isEmpty, "等了 60 秒的工牌丢掉")
        XCTAssertFalse((queue.visible + queue.pending).contains { $0.summary != nil }, "不进汇总")
    }

    func testBadgeIdentitiesStayStableAndHaveVariedCombinations() {
        let first = BadgeIdentity.forSession("badge-a")
        let again = BadgeIdentity.forSession("badge-a")
        XCTAssertEqual(first.name, again.name)
        XCTAssertEqual(first.likes, again.likes)
        XCTAssertEqual(first.dislike, again.dislike)
        XCTAssertEqual(first.motto, again.motto)
        XCTAssertEqual(first.secret, again.secret)
        XCTAssertEqual(first.accessory, again.accessory)
        let identities = (0..<200).map { BadgeIdentity.forSession("session-\($0)") }
        XCTAssertGreaterThan(Set(identities.map(\.name)).count, 20)
        XCTAssertGreaterThan(Set(identities.map(\.likes)).count, 20)
        XCTAssertGreaterThan(Set(identities.map(\.dislike)).count, 20)
        XCTAssertGreaterThan(Set(identities.map(\.motto)).count, 20)
        XCTAssertGreaterThan(Set(identities.map(\.secret)).count, 20)
        XCTAssertGreaterThan(Set(identities.map { "\($0.name)|\($0.likes)|\($0.dislike)|\($0.motto)|\($0.secret)" }).count, 150)
    }

    func testBadgeThemesAddOnlyEnabledSubjectsAndIgnoreOrder() {
        let samples = (0..<1000).map { "theme-session-\($0)" }
        let candidates: [(String, String)] = [
            ("development", "测试全绿，群里报喜"),
            ("writing", "一稿通过，原地过年"),
            ("design", "一稿定案甲方满意"),
            ("data", "报表对上提前下班")
        ]
        let defaults = Set(samples.map { BadgeIdentity.forSession($0).likes })
        for (theme, phrase) in candidates {
            XCTAssertFalse(defaults.contains(phrase), "通用池不应含额外主题")
            let values = Set(samples.map { BadgeIdentity.forSession($0, themes: [theme]).likes })
            XCTAssertTrue(values.contains(phrase), "开启的主题应该有机会被选到")
            for (_, other) in candidates where other != phrase {
                XCTAssertFalse(values.contains(other), "未开启的主题不能混入")
            }
        }
        let first = BadgeIdentity.forSession("same", themes: ["design", "writing"])
        let second = BadgeIdentity.forSession("same", themes: ["writing", "design", "writing", "invalid"])
        XCTAssertEqual(first.name, second.name)
        XCTAssertEqual(first.likes, second.likes)
        XCTAssertEqual(first.dislike, second.dislike)
        XCTAssertEqual(first.motto, second.motto)
        XCTAssertEqual(first.secret, second.secret)
        XCTAssertEqual(first.name, BadgeIdentity.forSession("same").name, "主题不改变花名")
    }

    func testBadgeLifecycleOnlyEmitsActualTransitions() {
        var lifecycle = BadgeLifecycle()
        var first = record("a")
        XCTAssertTrue(lifecycle.update([first], emit: true).isEmpty)
        var second = record("b")
        XCTAssertEqual(lifecycle.update([first, second], emit: true).map(\.0), [.joined])
        first.state = .done
        XCTAssertTrue(lifecycle.update([first, second], emit: true).isEmpty)
        first.state = .running
        XCTAssertTrue(lifecycle.update([first, second], emit: true).isEmpty)
        first.state = .ended
        XCTAssertEqual(lifecycle.update([first, second], emit: true).map(\.0), [.departed])
        XCTAssertTrue(lifecycle.update([first, second], emit: true).isEmpty)
        first.state = .running
        XCTAssertEqual(lifecycle.update([first, second], emit: true).map(\.0), [.returned])
        second.state = .ended
        XCTAssertTrue(lifecycle.update([first, second], emit: false).isEmpty)
        XCTAssertTrue(lifecycle.update([first, second], emit: true).isEmpty)
        lifecycle.reset()
        XCTAssertTrue(lifecycle.update([first], emit: true).isEmpty)
        XCTAssertTrue(lifecycle.update([], emit: true).isEmpty)
        XCTAssertTrue(lifecycle.update([first], emit: true).isEmpty)
        first.state = .ended
        XCTAssertEqual(lifecycle.update([first], emit: true).map(\.0), [.departed])
        XCTAssertTrue(lifecycle.update([], emit: true).isEmpty)
        first.state = .running
        XCTAssertEqual(lifecycle.update([first], emit: true).map(\.0), [.returned])
    }

    func testProvisionalHandoffRequiresUniquePIDAndTTY() {
        let process = CodexPendingProcess(pid: 42, started: 1_000_000, tty: "ttys010", cwd: "/repo")
        let placeholder = process.record()
        var real = record("real", provider: "codex")
        real.pid = 42
        real.tty = "ttys010"
        XCTAssertTrue(CodexPending.matches(process, real))
        var older = real
        older.updatedAt = 999
        XCTAssertFalse(CodexPending.matches(process, older))
        var tracker = BadgeLifecycle()
        XCTAssertTrue(tracker.update([], emit: true).isEmpty)
        XCTAssertEqual(tracker.update([placeholder], emit: true).map(\.0), [.joined])
        XCTAssertTrue(tracker.update([real], emit: true).isEmpty)
        real.state = .ended
        XCTAssertEqual(tracker.update([real], emit: true).map(\.0), [.departed])

        var ambiguous = BadgeLifecycle()
        XCTAssertTrue(ambiguous.update([placeholder], emit: true).isEmpty)
        real.state = .running
        real.pid = 999
        real.tty = nil
        XCTAssertFalse(CodexPending.matches(process, real))
        XCTAssertEqual(ambiguous.update([placeholder, real], emit: true).map(\.0), [.joined])
        XCTAssertTrue(placeholder.isProvisional)
    }

    func testProvisionalUsesProcessStartToDetectPIDReuse() {
        var info = proc_bsdinfo()
        let pid = getpid()
        XCTAssertEqual(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)), Int32(MemoryLayout<proc_bsdinfo>.size))
        let started = UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
        let current = CodexPendingProcess(pid: pid, started: started, tty: "ttys010", cwd: "/tmp").record()
        XCTAssertFalse(CodexPending.confirmedGone(current))
        let previous = CodexPendingProcess(pid: pid, started: started - 1, tty: "ttys010", cwd: "/tmp").record()
        XCTAssertTrue(CodexPending.confirmedGone(previous))
    }

    func testBadgeQueueRespectsScreenHeightAndRefills() {
        var queue = PillQueue()
        queue.setHeightLimit(900, at: origin)
        for id in ["a", "b", "c"] {
            queue.enqueue(Peek.badge(project("/code/repo", [record(id)])), at: origin, sessionSeconds: 5, batterySeconds: 3)
        }
        XCTAssertEqual(queue.visible.count, 1, "工牌依次悬挂，其他工牌排队")
        XCTAssertEqual(queue.pending.count, 2)
        add("short", to: &queue, style: .session, sessionID: "short")
        XCTAssertEqual(queue.visible.count, 2, "短提示可以利用工牌留下的空间")
        queue.dismiss(id: "badge-claude:a", at: origin.addingTimeInterval(1))
        XCTAssertTrue(queue.visible.contains { $0.id == "badge-claude:b" }, "上一张工牌消失后显示下一张")
        queue.setHeightLimit(400, at: origin.addingTimeInterval(2))
        XCTAssertLessThanOrEqual(queue.visible.count, 2, "屏幕变矮时放不下的提示回队列")
        XCTAssertFalse(queue.pending.isEmpty)
        queue.setHeightLimit(900, at: origin.addingTimeInterval(3))
        let restored = queue.visible.first { $0.id == "badge-claude:b" }
        XCTAssertEqual(restored?.shownAt, origin.addingTimeInterval(3))
        XCTAssertEqual(restored?.expiresAt, origin.addingTimeInterval(8), "重新展示后从头计算停留时间")
    }

    func testBadgeSubtitleFallsBackToProviderWhenModelUnknown() {
        XCTAssertEqual(Peek.badge(project("/code/repo", [record("s1", provider: "codex", model: nil)])).subtitle, "Codex")
        XCTAssertNil(Peek.badge(project("/code/empty", [])).subtitle)
        XCTAssertNil(Peek.badge(project("/code/empty", [])).sessionId)
    }

    func testBadgeTargetsTheNewSessionInAnExistingProject() {
        let old = record("old")
        let newcomer = record("new")
        let group = project("/code/repo", [old, newcomer])
        let badge = Peek.badge(group, session: newcomer)
        XCTAssertEqual(badge.id, "badge-claude:new")
        XCTAssertEqual(badge.sessionId, "new")
        XCTAssertEqual(badge.subtitle, "Claude · Opus 5")
        XCTAssertNotEqual(badge.id, Peek.badge(group, session: old).id)
    }

    func testBadgeDistinguishesUntitledSessions() {
        var first = record("first12345678")
        var second = record("second87654321")
        first.title = nil
        second.title = nil
        let group = project("/code/repo", [first, second])
        XCTAssertEqual(Peek.badge(group, session: first).subtitle, "Claude · Opus 5")
        XCTAssertEqual(Peek.badge(group, session: second).subtitle, "Claude · Opus 5")
    }

    func testThreeVisibleAndEachQueuedPillGetsFullTimeOnlyWhenShown() {
        var queue = PillQueue()
        add("a", to: &queue)
        add("b", to: &queue, at: 1)
        add("c", to: &queue, at: 2)
        add("d", to: &queue, at: 3)
        XCTAssertEqual(queue.visible.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(queue.pending.map(\.id), ["d"])
        XCTAssertEqual(queue.nextDeadline, origin.addingTimeInterval(5))

        queue.advance(to: origin.addingTimeInterval(5))
        XCTAssertEqual(queue.visible.map(\.id), ["b", "c", "d"])
        XCTAssertEqual(queue.visible.last?.shownAt, origin.addingTimeInterval(5))
        XCTAssertEqual(queue.visible.last?.expiresAt, origin.addingTimeInterval(10))
        queue.advance(to: origin.addingTimeInterval(6))
        XCTAssertEqual(queue.visible.map(\.id), ["c", "d"])
    }

    func testReplacementRestartsClockAndStaleDismissCannotRemoveNewState() {
        var queue = PillQueue()
        add("old", to: &queue, style: .ask, sessionID: "one")
        add("new", to: &queue, at: 2, style: .session, sessionID: "one")
        XCTAssertEqual(queue.visible.map(\.id), ["new"])
        XCTAssertEqual(queue.visible[0].expiresAt, origin.addingTimeInterval(7))
        queue.dismiss(id: "old", at: origin.addingTimeInterval(3))
        queue.advance(to: origin.addingTimeInterval(5))
        XCTAssertEqual(queue.visible.map(\.id), ["new"])
        queue.advance(to: origin.addingTimeInterval(7))
        XCTAssertTrue(queue.visible.isEmpty)
    }

    func testWaitingPriorityWithoutPreemptingAndReconciliation() {
        var queue = PillQueue()
        for id in ["a", "b", "c"] { add(id, to: &queue) }
        add("battery", to: &queue, style: .low)
        add("ask", to: &queue, style: .ask, sessionID: "waiting")
        XCTAssertEqual(queue.visible.map(\.id), ["a", "b", "c"])
        queue.dismiss(id: "a", at: origin.addingTimeInterval(1))
        XCTAssertEqual(queue.visible.map(\.id), ["b", "c", "ask"])
        queue.reconcileWaiting(activeSessionIDs: [], at: origin.addingTimeInterval(2))
        XCTAssertEqual(queue.visible.map(\.id), ["b", "c", "battery"])
    }

    func testNewWaitingPromptWinsSlotThatExpiresAtArrival() {
        var queue = PillQueue()
        for id in ["a", "b", "c"] { add(id, to: &queue) }
        add("battery", to: &queue, style: .low)
        add("ask", to: &queue, at: 5, style: .ask, sessionID: "waiting")
        XCTAssertEqual(queue.visible.map(\.id).first, "ask")
        XCTAssertTrue(queue.visible.contains { $0.id == "battery" })
    }

    func testLateJumpFailureDoesNotOverwriteNewerSessionEvent() {
        let old = SessionRecord(sessionId: "s", state: .done, cwd: "/tmp", title: "old", transcriptPath: "", message: nil, updatedAt: 1)
        var newer = old
        newer.updatedAt = 2
        newer.title = "new"
        var queue = PillQueue()
        queue.enqueue(.session(newer), at: origin, sessionSeconds: 5, batterySeconds: 3)
        XCTAssertFalse(queue.enqueueFailure(Peek.session(old).failed("无法确定窗口"), for: old, current: [newer], at: origin, sessionSeconds: 5, batterySeconds: 3))
        XCTAssertEqual(queue.visible.first?.peek?.title, "new")
        queue.clear()
        XCTAssertTrue(queue.enqueueFailure(Peek.session(old).failed("无法确定窗口"), for: old, current: [old], at: origin, sessionSeconds: 5, batterySeconds: 3))
        XCTAssertEqual(queue.visible.first?.peek?.failureMessage, "无法确定窗口")
    }

    func testWaitingItemsStayPendingBeyondMinuteAndCancelWhenSessionStopsWaiting() {
        var queue = PillQueue()
        for id in ["a", "b", "c"] { add(id, to: &queue) }
        add("ask", to: &queue, style: .ask, sessionID: "waiting")
        queue.reconcileWaiting(activeSessionIDs: ["waiting"], at: origin.addingTimeInterval(70))
        XCTAssertEqual(queue.visible.map(\.id), ["ask"])
        XCTAssertFalse(queue.visible.contains { $0.summary != nil })
        queue.reconcileWaiting(activeSessionIDs: [], at: origin.addingTimeInterval(71))
        XCTAssertTrue(queue.visible.isEmpty)
    }

    func testThirtyFirstDetailedPendingBecomesSummaryWithExplicitRoute() {
        var queue = PillQueue()
        for i in 0..<34 { add("session-\(i)", to: &queue) }
        XCTAssertEqual(queue.visible.count, 3)
        XCTAssertEqual(queue.pending.filter { $0.peek != nil }.count, 30)
        let summary = queue.pending.compactMap(\.summary).first
        XCTAssertEqual(summary?.category, .aiCompletion)
        XCTAssertEqual(summary?.count, 1)
        XCTAssertEqual(summary?.route, .ai)
        XCTAssertTrue(summary?.title.contains("详情已过期") == true)
    }

    func testSixtySecondBoundarySummarizesAndDoesNotRetainOldTarget() {
        var blocked = PillQueue()
        for i in 0..<27 { add("ask-\(i)", to: &blocked, style: .ask, sessionID: "s\(i)") }
        add("old", to: &blocked, style: .low)
        blocked.advance(to: origin.addingTimeInterval(59.999))
        XCTAssertTrue(blocked.pending.contains { $0.id == "old" })
        blocked.advance(to: origin.addingTimeInterval(60))
        XCTAssertFalse(blocked.pending.contains { $0.id == "old" })
        XCTAssertEqual(blocked.pending.compactMap(\.summary).first?.category, .battery)
    }

    func testAllFiveSummaryRoutes() {
        let cases: [(Peek.Style, PillQueue.Category, PillQueue.Route)] = [
            (.session, .aiCompletion, .ai), (.quotaHigh, .quota, .ai),
            (.low, .battery, .system), (.shelf, .shelf, .shelf), (.update, .update, .settings)
        ]
        for (style, category, route) in cases {
            var queue = PillQueue()
            for i in 0..<3 { add("ask-\(i)", to: &queue, style: .ask, sessionID: "s\(i)") }
            for i in 0..<31 {
                let id = style == .quotaHigh ? "quota-provider-window\(i)-1000" : "detail-\(i)"
                add(id, to: &queue, style: style)
            }
            let summary = queue.pending.compactMap(\.summary).first
            XCTAssertEqual(summary?.category, category)
            XCTAssertEqual(summary?.route, route)
        }
    }

    func testPendingQuotaWindowDeduplicatesAndClearCancelsAllDeadlines() {
        var queue = PillQueue()
        for i in 0..<3 { add("visible-\(i)", to: &queue) }
        add("quota-claude-five-hour-1000", to: &queue, style: .quotaHigh)
        add("quota-claude-five-hour-2000", to: &queue, at: 1, style: .quotaExhausted)
        XCTAssertEqual(queue.pending.map(\.id), ["quota-claude-five-hour-2000"])
        queue.clear()
        XCTAssertTrue(queue.visible.isEmpty)
        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertNil(queue.nextDeadline)
    }

    func testVisibleQuotaWindowKeepsLatestState() {
        var queue = PillQueue()
        add("quota-claude-five-hour-1000", to: &queue, style: .quotaHigh)
        add("quota-claude-five-hour-2000", to: &queue, at: 1, style: .quotaExhausted)
        XCTAssertEqual(queue.visible.map(\.id), ["quota-claude-five-hour-2000"])
        XCTAssertEqual(queue.visible[0].expiresAt, origin.addingTimeInterval(6))
    }

    func testOverflowSummarizesLowestPriorityThenOldest() {
        var queue = PillQueue()
        for i in 0..<3 { add("visible-\(i)", to: &queue) }
        add("battery-old", to: &queue, style: .low)
        for i in 0..<30 { add("done-\(i)", to: &queue, style: .session) }
        XCTAssertFalse(queue.pending.contains { $0.id == "battery-old" })
        XCTAssertEqual(queue.pending.compactMap(\.summary).first?.category, .battery)
        add("done-new", to: &queue, style: .session)
        XCTAssertFalse(queue.pending.contains { $0.id == "done-0" })
        XCTAssertEqual(queue.pending.compactMap(\.summary).first { $0.category == .aiCompletion }?.count, 1)
    }
}
