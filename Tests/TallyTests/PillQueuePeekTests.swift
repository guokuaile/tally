import XCTest
import SwiftUI
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
