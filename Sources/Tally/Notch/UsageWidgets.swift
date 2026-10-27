import SwiftUI

/// 配额用色和 statusline 一致：85% 以上红，60% 以上黄，其余绿。
func quotaColor(_ fraction: Double) -> Color {
    let percent = fraction * 100
    if percent >= 85 { return .red }
    if percent >= 60 { return .yellow }
    return .green
}

/// 配速：窗口时间已经过去的比例，填充越过它就是用得比时间快。纯函数。
enum QuotaPace {
    /// 领先这么多（百分点）才算用快了：刚开窗口时一两次调用就会领先一大截，不值得标。
    static let aheadMargin = 0.1

    /// 没有重置时间、窗口长度未知、剩余时间不在 (0, 窗口] 里（数据对不上）都给 nil，不画。
    static func elapsedFraction(resetsAt: Date?, window: TimeInterval?, now: Date) -> Double? {
        guard let resetsAt, let window, window > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0, remaining <= window else { return nil }
        return 1 - remaining / window
    }

    /// 浮点减法 0.9 − 0.8 比 0.1 小一丁点，留个容差，正好领先 10 个百分点也算。
    static func isAhead(used: Double, elapsed: Double) -> Bool {
        used - elapsed >= aheadMargin - 1e-9
    }
}

/// 数字独立于动画，轨道只表达从左到右的已用比例。
struct QuotaBar: View {
    let label: String
    let limit: UsageLimit
    let stale: Bool
    let now: Date
    var window: TimeInterval? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var percent: String { "\(Int((limit.fraction * 100).rounded()))%\(stale ? "~" : "")" }
    private var elapsed: Double? { QuotaPace.elapsedFraction(resetsAt: limit.resetsAt, window: window, now: now) }

    var body: some View {
        VStack(spacing: 3) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    windowLabel.fixedSize()
                    amountLabel
                    Spacer(minLength: 2)
                    resetLabel
                }
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 5) {
                        windowLabel
                        Spacer(minLength: 2)
                        amountLabel
                    }
                    resetLabel
                }
            }
            UsageTrack(fraction: limit.fraction, elapsed: elapsed, paused: stale || reduceMotion)
                .accessibilityHidden(true)
        }
        .help("已用量从左向右增长，100% 填满后停止流光。刻线是时间配速。" + (stale ? "当前为缓存读数。" : ""))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilitySummary)
    }

    private var windowLabel: some View {
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.65))
            .lineLimit(1)
    }

    private var amountLabel: some View {
        Text("已用 " + percent)
            .font(.metric(10, .medium))
            .foregroundStyle(quotaColor(limit.fraction))
            .fixedSize()
    }

    private var resetLabel: some View {
        Text(ResetLabel.text(for: limit.resetsAt, now: now, style: .short) ?? "")
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(.white.opacity(0.45))
            .fixedSize()
    }

    private var accessibilitySummary: String {
        var parts = ["已用 " + percent]
        if stale { parts.append("缓存读数") }
        if let reset = ResetLabel.text(for: limit.resetsAt, now: now) { parts.append(reset) }
        if let elapsed {
            parts.append(QuotaPace.isAhead(used: limit.fraction, elapsed: elapsed) ? "用量快于时间配速" : "用量在时间配速内")
        }
        return parts.joined(separator: "，")
    }
}

/// 一笔余额：「余额 ¥110.00」。钱没有百分比和重置时间，不画条；花光了标红。
struct BalanceLabel: View {
    let balance: Balance

    var body: some View {
        HStack(spacing: 4) {
            Text(balance.label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
            Text(balance.amountText)
                .font(.metric(11, .medium))
                .foregroundStyle(balance.amount > 0 ? Color.white.opacity(0.85) : .red)
                .lineLimit(1)
        }
    }
}

/// 重置时间的文案。24 小时内给「HH:mm」，更远给「M/d HH:mm」，已过给「已重置」，没有就 nil。
/// `.long` 在时刻后面带「 重置」两个字；`.short` 给 ↻ 前缀，用在一行放两条的紧凑布局里。
enum ResetLabel {
    enum Style { case long, short }

    static func text(for date: Date?, now: Date, calendar: Calendar = .current, style: Style = .long) -> String? {
        guard let date else { return nil }
        if date <= now { return "已重置" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = date.timeIntervalSince(now) < 24 * 3600 ? "HH:mm" : "M/d HH:mm"
        let clock = formatter.string(from: date)
        return style == .long ? clock + " 重置" : "↻" + clock
    }
}

/// token 数按 1000 进制缩写：1234 → 1.2k，2400000 → 2.4M。小数是 0 就不带小数点。
/// 不用 `ByteFormat`：那个是 1024 进制的字节数，token 不是字节。
enum TokenFormat {
    static func short(_ tokens: Int) -> String {
        let n = max(0, tokens)
        if n < 1_000 { return "\(n)" }
        // 按舍入之后的值挑单位：999,950 舍到一位小数是 1000.0，按原值挑的话会写成「1000k」
        for (scale, suffix) in [(1_000.0, "k"), (1_000_000.0, "M")] where oneDecimal(Double(n) / scale) < 1_000 {
            return trim(Double(n) / scale) + suffix
        }
        return trim(Double(n) / 1_000_000_000) + "B"
    }

    private static func oneDecimal(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    private static func trim(_ value: Double) -> String {
        let rounded = oneDecimal(value)
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}

/// 两行：「今日 $x · 24.1M」「本周 $y · 312M」。价格不全时只显示 token。
/// 排成两行而不是挤一行：左格只有 150pt，一行放不下两个窗口的费用加 token。
struct UsageFigures: View {
    let today: UsageTotals
    let week: UsageTotals

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            line("今日", today)
            line("本周", week)
        }
        .font(.system(size: 9))
        .foregroundStyle(.white.opacity(0.8))
        .lineLimit(1)
    }

    private func line(_ label: String, _ totals: UsageTotals) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.white.opacity(0.45))
            if !totals.hasUnpricedModel {
                Text(String(format: "$%.2f", totals.costUSD)).font(.metric(10, .medium))
                Text("·").foregroundStyle(.white.opacity(0.3))
            }
            Text(TokenFormat.short(totals.inputTokens + totals.outputTokens))
                .font(.metric(10, .regular))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}
