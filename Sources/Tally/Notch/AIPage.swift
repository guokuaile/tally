import SwiftUI

/// Stack quota windows so labels, exact percentages and reset times stay readable.
struct AIPage: View {
    var store = SessionStore.shared
    var usage = UsageStore.shared
    /// 会话卡片翻到「已关闭」那一页没有。不落盘：每次展开面板都回到会话——已关闭的点下去会开新终端，平时不该摆在手边。
    @State private var showingClosed = false

    var body: some View {
        VStack(spacing: 8) {
            let closedCount = store.sessions.filter { $0.state == .ended }.count
            Card(showingClosed ? "已关闭" : "会话", symbol: showingClosed ? "clock.arrow.circlepath" : "terminal", tint: .green,
                 accessory: closedCount > 0 || showingClosed
                    ? AnyView(ClosedPageToggle(count: closedCount, showingClosed: $showingClosed)) : nil) {
                SessionsPage(showingClosed: showingClosed)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            Card("配额与用量", symbol: "chart.bar.fill", tint: .blue) {
                UsageStrip(usage: usage)
            }
        }
    }
}

/// 会话卡片标题行右边：「已关闭 N ›」翻到已关闭那一页，「‹ 会话」翻回来。
struct ClosedPageToggle: View {
    let count: Int
    @Binding var showingClosed: Bool
    @State private var hovered = false

    var body: some View {
        Button { showingClosed.toggle() } label: {
            Text(showingClosed ? "‹ 会话" : "已关闭 \(count) ›")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12)
                .frame(minHeight: 28)
                .background(Capsule().fill(.white.opacity(hovered ? 0.20 : 0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(showingClosed ? "返回当前会话" : "查看已关闭的会话")
    }
}

/// 名字与费用固定在左侧，便于对照多个配额窗口。
struct UsageStrip: View {
    var usage: UsageStore

    private var rows: [(ProviderID, UsageResult)] {
        ProviderID.allCases.compactMap { id in usage.results[id].map { (id, $0) } }
    }

    var body: some View {
        let now = Date()
        VStack(spacing: 3) {
            if rows.isEmpty {
                Text("没有开启的提供方")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
            ForEach(rows, id: \.0) { id, result in
                UsageStripRow(provider: id, result: result, now: now)
                if id != rows.last?.0 {
                    Rectangle().fill(.white.opacity(0.15)).frame(height: 1).padding(.vertical, 4)
                }
            }
        }
    }
}

struct UsageStripRow: View {
    let provider: ProviderID
    let result: UsageResult
    let now: Date
    var usage = UsageStore.shared
    @State private var resetConfirmation: CodexResetCredits.Confirmation?
    @State private var resetButtonHovered = false

    var weeklyLimits: [(id: String, scoped: ScopedLimit)] {
        guard case .success(let snapshot) = result else { return [] }
        let total = snapshot.weekLimit.map {
            [(id: "total-week", scoped: ScopedLimit(label: provider.stripLabels.week, limit: $0))]
        } ?? []
        let scoped = snapshot.scopedLimits.map { (id: "model:" + $0.label, scoped: $0) }
        // A late model quota must not inherit the total window's animation state.
        return (provider == .claude ? scoped + total : total + scoped)
            .filter { !$0.scoped.limit.isExpired(at: now) }
    }

    var body: some View {
        standardRow
    }

    private var standardRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    ProviderLogo(name: provider.logoName)
                    Text(provider.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                    if case .success(let snapshot) = result, let plan = snapshot.plan {
                        Text(plan)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.white.opacity(0.8)))
                    }
                }
                // 只有 Claude、Codex 有本地日志算出来的花费；别家画「$0.00」会让人以为真没花钱
                if case .success(let snapshot) = result, provider.reportsSpend {
                    UsageFigures(today: snapshot.today, week: snapshot.week)
                        .help("本机日志用量合计，金额为模型价格估算，非账单。")
                }
            }
            .frame(width: 132, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                switch result {
                case .loading:
                    Text("加载中").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                case .failure(let message):
                    Text(message).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
                case .success(let snapshot):
                    if let limit = snapshot.sessionLimit, !limit.isExpired(at: now) {
                        QuotaBar(label: provider.stripLabels.session, limit: limit, stale: snapshot.limitsStale, now: now, window: provider.limitWindows.session)
                    }
                    let weekly = weeklyLimits
                    let columns = provider == .claude && weekly.count > 1 ? 2 : 1
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), alignment: .leading, spacing: 5) {
                        ForEach(weekly, id: \.id) { entry in
                            QuotaBar(label: entry.scoped.label, limit: entry.scoped.limit, stale: snapshot.limitsStale, now: now, window: provider.limitWindows.week)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(Array(snapshot.balances.enumerated()), id: \.offset) { _, balance in
                        BalanceLabel(balance: balance)
                    }
                    if provider == .codex {
                        if let credits = snapshot.codexResetCredits {
                            HStack(spacing: 6) {
                                Text("重置卡 \(credits.availableCount) 次")
                                    .foregroundStyle(.white.opacity(0.85))
                                    .help("\(credits.accountLabel)；更新于 \(credits.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                                if let expiry = credits.expiresAt?.filter({ $0 > now }).min() {
                                    Text("最早 \(expiry.formatted(.dateTime.month().day().hour().minute())) 到期")
                                        .foregroundStyle(.white.opacity(0.5))
                                } else if credits.availableCount > 0, credits.detailsNote == nil {
                                    Text(credits.cards.isEmpty ? "暂无可用卡明细" : "未提供到期时间")
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                                Spacer(minLength: 0)
                                if usage.isUsingCodexResetCredit {
                                    ProgressView().controlSize(.mini)
                                } else if credits.availableCount > 0 {
                                    let canUseResetCredit = !usage.codexResetNeedsReview && credits.nextCard(at: now) != nil
                                    Button {
                                        guard let card = credits.nextCard(at: .now) else { return }
                                        resetConfirmation = .init(id: UUID(), credits: credits, card: card)
                                    } label: {
                                        Label("使用 1 次…", systemImage: "ticket")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.white.opacity(canUseResetCredit ? (resetButtonHovered ? 0.9 : 0.7) : 0.35))
                                            .padding(.horizontal, 10)
                                            .frame(minHeight: 26)
                                            .background(RoundedRectangle(cornerRadius: 6)
                                                .fill(.white.opacity(canUseResetCredit ? (resetButtonHovered ? 0.10 : 0.04) : 0.02)))
                                            .overlay(RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(.white.opacity(canUseResetCredit ? (resetButtonHovered ? 0.24 : 0.14) : 0.08), lineWidth: 1))
                                            .contentShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                    .buttonStyle(.plain)
                                    .fixedSize()
                                    .padding(.leading, 8)
                                    .disabled(!canUseResetCredit)
                                    .onHover { resetButtonHovered = $0 }
                                    .help("使用一张已存的重置卡；需要再次确认，读数过期请先刷新。")
                                    .accessibilityLabel("使用 1 次 Codex 重置卡，需要确认")
                                    .accessibilityHint("打开确认框，确认后才会消耗 1 次。")
                                }
                            }
                            .font(.system(size: 9))
                            if let note = credits.detailsNote {
                                Text(note).font(.system(size: 9)).foregroundStyle(.orange)
                            }
                        } else {
                            Text("重置卡 · 暂未取得")
                                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    if let note = snapshot.limitsNote {
                        Text(note).font(.system(size: 9)).foregroundStyle(.red).lineLimit(2)
                    }
                }
                if provider == .codex {
                    if let message = usage.codexResetFeedback {
                        Text(message).font(.system(size: 9)).foregroundStyle(.white.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Codex 重置状态：\(message)")
                    }
                    if usage.codexResetNeedsReview, !usage.isUsingCodexResetCredit {
                        Button("已在 Codex 核对") {
                            Task { await usage.acknowledgeCodexResetOutcome() }
                        }
                        .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(.orange)
                        .help("确认已在 Codex 核对上次是否消耗卡片；只解除待核对标记，不重新兑换。")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .alert("使用 1 次 Codex 重置？", isPresented: Binding(
            get: { resetConfirmation != nil },
            set: { if !$0 { resetConfirmation = nil } }
        ), presenting: resetConfirmation) { confirmation in
            Button("取消", role: .cancel) {}
            Button("使用 1 次重置") {
                Task { await usage.consumeCodexResetCredit(confirmation) }
            }
        } message: { confirmation in
            Text("\(confirmation.credits.accountLabel)\n将消耗 1 次已存重置机会，立即重置适用的 Codex 额度。\n\(confirmation.card.expiresAt.map { "所选卡片到期：\($0.formatted(date: .abbreviated, time: .shortened))" } ?? "所选卡片未提供到期时间")\n此操作不能撤销。")
        }
    }
}
