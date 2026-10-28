import Foundation

/// The clock is supplied by the caller so each pill starts its own deadline when it becomes visible.
struct PillQueue {
    enum Route: Equatable {
        case ai, system, shelf, settings
    }

    enum Category: String, CaseIterable {
        case aiCompletion, quota, battery, shelf, update

        var route: Route {
            switch self {
            case .aiCompletion, .quota: return .ai
            case .battery: return .system
            case .shelf: return .shelf
            case .update: return .settings
            }
        }

        var title: String {
            switch self {
            case .aiCompletion: return "AI 完成"
            case .quota: return "配额"
            case .battery: return "电池"
            case .shelf: return "文件架"
            case .update: return "更新"
            }
        }
    }

    struct Summary: Equatable {
        var category: Category
        var count: Int
        var route: Route { category.route }
        var title: String { "\(category.title) \(count) 条 · 详情已过期" }
    }

    enum Content: Equatable {
        case peek(Peek)
        case summary(Summary)
    }

    struct Item: Equatable {
        var id: String
        var content: Content
        var enqueuedAt: Date
        var shownAt: Date?
        var expiresAt: Date?

        var peek: Peek? {
            if case .peek(let peek) = content { return peek }
            return nil
        }

        var summary: Summary? {
            if case .summary(let summary) = content { return summary }
            return nil
        }
    }

    private struct Queued {
        var item: Item
        var duration: TimeInterval
        var sequence: UInt64

        var priority: Int {
            switch item.content {
            case .peek(let peek): return peek.priority
            case .summary(let summary):
                switch summary.category {
                case .aiCompletion: return 2
                case .quota, .shelf, .update: return 1
                case .battery: return 0
                }
            }
        }

        var isWaiting: Bool { item.peek?.style == .ask }
    }

    private static let visibleLimit = 3
    private static let detailedPendingLimit = 30
    private static let pendingLifetime: TimeInterval = 60

    private var showing: [Queued] = []
    private var waiting: [Queued] = []
    private var nextSequence: UInt64 = 0

    var visible: [Item] { showing.map(\.item) }
    var pending: [Item] { waiting.map(\.item) }

    var nextDeadline: Date? {
        let shownDeadlines = showing.compactMap(\.item.expiresAt)
        let pendingDeadlines = waiting.compactMap { queued in
            queued.isWaiting || queued.item.summary != nil ? nil : queued.item.enqueuedAt.addingTimeInterval(Self.pendingLifetime)
        }
        return (shownDeadlines + pendingDeadlines).min()
    }

    @discardableResult
    mutating func enqueueFailure(_ peek: Peek, for session: SessionRecord, current: [SessionRecord],
                                 at now: Date, sessionSeconds: Int, batterySeconds: Int) -> Bool {
        guard canEnqueueFailure(for: session, current: current) else { return false }
        enqueue(peek, at: now, sessionSeconds: sessionSeconds, batterySeconds: batterySeconds)
        return true
    }

    func canEnqueueFailure(for session: SessionRecord, current: [SessionRecord]) -> Bool {
        current.contains(where: { $0.sessionId == session.sessionId && $0.state == session.state && $0.updatedAt == session.updatedAt })
            && !(visible + pending).contains(where: { $0.peek?.sessionId == session.sessionId })
    }

    mutating func enqueue(_ peek: Peek, at now: Date, sessionSeconds: Int, batterySeconds: Int) {
        expire(to: now)
        let duration = peek.duration(session: sessionSeconds, battery: batterySeconds)
        let item = Item(id: peek.id, content: .peek(peek), enqueuedAt: now, shownAt: nil, expiresAt: nil)
        let queued = Queued(item: item, duration: duration, sequence: takeSequence())

        let key = deduplicationKey(for: peek)
        if let key,
           let index = showing.firstIndex(where: { $0.item.peek.flatMap(deduplicationKey) == key }) {
            showing[index] = displayed(queued, at: now)
            refill(at: now)
            return
        }
        if let key,
           let index = waiting.firstIndex(where: { $0.item.peek.flatMap(deduplicationKey) == key }) {
            waiting[index] = queued
        } else {
            waiting.append(queued)
        }

        trimPending(at: now)
        refill(at: now)
    }

    /// Call after a fresh session snapshot. A waiting prompt is actionable only while that session still waits.
    mutating func reconcileWaiting(activeSessionIDs: Set<String>, at now: Date) {
        advance(to: now)
        showing.removeAll { entry in
            entry.isWaiting && !activeSessionIDs.contains(entry.item.peek?.sessionId ?? "")
        }
        waiting.removeAll { entry in
            entry.isWaiting && !activeSessionIDs.contains(entry.item.peek?.sessionId ?? "")
        }
        refill(at: now)
    }

    mutating func advance(to now: Date) {
        expire(to: now)
        refill(at: now)
    }

    private mutating func expire(to now: Date) {
        showing.removeAll { $0.item.expiresAt.map { $0 <= now } ?? false }
        var expired: [Queued] = []
        waiting.removeAll { entry in
            guard !entry.isWaiting, entry.item.summary == nil,
                  entry.item.enqueuedAt.addingTimeInterval(Self.pendingLifetime) <= now else { return false }
            expired.append(entry)
            return true
        }
        for entry in expired { foldIntoSummary(entry, at: now) }
    }

    mutating func dismiss(id: String, at now: Date) {
        showing.removeAll { $0.item.id == id }
        waiting.removeAll { $0.item.id == id }
        advance(to: now)
    }

    mutating func clear() {
        showing.removeAll()
        waiting.removeAll()
    }

    private mutating func takeSequence() -> UInt64 {
        defer { nextSequence &+= 1 }
        return nextSequence
    }

    private func displayed(_ entry: Queued, at now: Date) -> Queued {
        var result = entry
        result.item.shownAt = now
        result.item.expiresAt = now.addingTimeInterval(result.duration)
        return result
    }

    private mutating func refill(at now: Date) {
        while showing.count < Self.visibleLimit, !waiting.isEmpty {
            let index = waiting.indices.max { left, right in
                let a = waiting[left], b = waiting[right]
                return a.priority == b.priority ? a.sequence > b.sequence : a.priority < b.priority
            }!
            showing.append(displayed(waiting.remove(at: index), at: now))
        }
    }

    private mutating func trimPending(at now: Date) {
        while waiting.filter({ !$0.isWaiting && $0.item.summary == nil }).count > Self.detailedPendingLimit {
            guard let leastValuable = waiting.indices
                .filter({ !waiting[$0].isWaiting && waiting[$0].item.summary == nil })
                .min(by: {
                    let left = waiting[$0], right = waiting[$1]
                    return left.priority == right.priority ? left.sequence < right.sequence : left.priority < right.priority
                }) else { break }
            foldIntoSummary(waiting.remove(at: leastValuable), at: now)
        }
    }

    private mutating func foldIntoSummary(_ entry: Queued, at now: Date) {
        guard let peek = entry.item.peek else { return }
        let category: Category
        switch peek.style {
        case .session: category = .aiCompletion
        case .quotaHigh, .quotaExhausted, .quotaReset: category = .quota
        case .pluggedIn, .unplugged, .low, .full: category = .battery
        case .shelf: category = .shelf
        case .update: category = .update
        case .ask: return
        }
        let id = "summary-\(category.rawValue)"
        if let index = showing.firstIndex(where: { $0.item.id == id }) {
            var summary = showing[index].item.summary!
            summary.count += 1
            showing[index].item.content = .summary(summary)
            showing[index].item.shownAt = now
            showing[index].item.expiresAt = now.addingTimeInterval(showing[index].duration)
        } else if let index = waiting.firstIndex(where: { $0.item.id == id }) {
            var summary = waiting[index].item.summary!
            summary.count += 1
            waiting[index].item.content = .summary(summary)
        } else {
            let summary = Summary(category: category, count: 1)
            let item = Item(id: id, content: .summary(summary), enqueuedAt: now, shownAt: nil, expiresAt: nil)
            waiting.append(Queued(item: item, duration: entry.duration, sequence: takeSequence()))
        }
    }

    private func deduplicationKey(for peek: Peek) -> String? {
        if let sessionID = peek.sessionId { return "session:\(sessionID)" }
        guard peek.style == .quotaHigh || peek.style == .quotaExhausted || peek.style == .quotaReset else { return nil }
        // The trailing component is the timestamp from Peek.quota; the prefix identifies its provider/window.
        guard let separator = peek.id.lastIndex(of: "-") else { return nil }
        return String(peek.id[..<separator])
    }
}
