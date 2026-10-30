import Foundation

/// 等你账本：Tally 存在的理由是「等审批的会话晚发现几分钟是常态」，这里量它（docs/ai.md「等你账本」）。
/// 按本地日期汇总次数、总时长、最长一次；只留最近 7 天；有新笔才写盘。
@MainActor
final class WaitLedger {
    struct Day: Codable, Equatable {
        var count = 0
        var totalMs = 0
        var maxMs = 0

        enum CodingKeys: String, CodingKey {
            case count
            case totalMs = "total_ms"
            case maxMs = "max_ms"
        }
    }

    static let keepDays = 7

    private(set) var days: [String: Day]
    /// nil 只在内存（测试、演示）。
    let file: URL?

    init(file: URL?) {
        self.file = file
        guard let file, let data = try? Data(contentsOf: file) else { days = [:]; return }
        do {
            days = try JSONDecoder().decode([String: Day].self, from: data)
        } catch {
            // 自己写的文件读不回来（多半是格式改了）：挪到 .bak，别让下一笔把 7 天的数覆盖掉
            Log.error("等你账本读不回来，挪到 waits.json.bak: \(error.localizedDescription)")
            let bak = file.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: bak)
            try? FileManager.default.moveItem(at: file, to: bak)
            days = [:]
        }
    }

    /// 上一轮在等你、这一轮不等了或记录没了的会话，各算一笔：批了、答了、拒了、关了终端都算发现了它。这一轮还在等但开始等的时刻
    /// 变晚了（批完马上又弹，两次刷新之间）也算一笔，时长是两个时刻之差。纯函数。
    static func finished(previous: [SessionRecord], current: [SessionRecord], now: Date) -> [TimeInterval] {
        let stillSince = Dictionary(current.filter(\.isWaiting).map { ($0.sessionId, $0.waitingSince ?? now) }, uniquingKeysWith: { a, _ in a })
        return previous.compactMap { record in
            guard record.isWaiting, let since = record.waitingSince else { return nil }
            guard let next = stillSince[record.sessionId] else { return max(0, now.timeIntervalSince(since)) }
            return next > since ? next.timeIntervalSince(since) : nil
        }
    }

    /// 本地日期，`2026-10-30`；字符串比大小就是比日期
    static func key(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func add(_ durations: [TimeInterval], now: Date) {
        guard !durations.isEmpty else { return }
        let today = Self.key(now)
        var day = days[today] ?? Day()
        for duration in durations {
            let ms = Int((duration * 1000).rounded())
            day.count += 1
            day.totalMs += ms
            day.maxMs = max(day.maxMs, ms)
        }
        days[today] = day
        // 含今天共 7 天，按日历日算，不怕夏令时
        let cutoff = Self.key(Calendar.current.date(byAdding: .day, value: 1 - Self.keepDays, to: now) ?? now)
        days = days.filter { $0.key >= cutoff }
        save()
    }

    func summary(on date: Date) -> Day? { days[Self.key(date)] }

    private func save() {
        guard let file else { return }
        do {
            try JSONEncoder().encode(days).write(to: file, options: .atomic)
        } catch {
            Log.error("等你账本没写进去: \(error.localizedDescription)")
        }
    }

    /// 「今天等你 4 次 · 共 12 分钟 · 最长 6 分钟」
    static func label(_ day: Day) -> String {
        "今天等你 \(day.count) 次 · 共 \(duration(day.totalMs)) · 最长 \(duration(day.maxMs))"
    }

    /// 不到一分钟给秒，不到一小时给整分钟，再长给小时加分钟
    static func duration(_ ms: Int) -> String {
        let seconds = ms / 1000
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 { return "\(minutes) 分钟" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }
}
