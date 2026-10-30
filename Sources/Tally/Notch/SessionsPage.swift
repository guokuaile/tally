import SwiftUI

/// 会话列表：分「等你 / 在跑 / 完成 / 失联」四组，一行一个会话，点行跳回它的终端。
/// 已关闭的在会话卡片的另一页（`showingClosed`）：只列已关闭的，点行尾「接着聊」才开新终端。
struct SessionsPage: View {
    var store = SessionStore.shared
    var jump = SessionJump.shared
    /// 翻到「已关闭」那一页：由 AI 页会话卡片标题行的切换按钮决定。
    var showingClosed = false

    var body: some View {
        let now = Date()
        let rows = showingClosed
            ? SessionRecord.displayOrder(store.sessions, now: now).filter { $0.state == .ended }
            : SessionRecord.displayOrder(store.sessions, now: now).filter { $0.state != .ended }
        if rows.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: showingClosed ? "clock.arrow.circlepath" : "terminal")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.3))
                Text(showingClosed ? "没有已关闭的会话" : "没有在跑的会话")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                if !showingClosed, let waits = store.todayWaits {
                    WaitSummaryLine(day: waits)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 72, maxHeight: .infinity)
        } else {
            let crowded = SessionRecord.crowdedCWDs(rows)
            let shortcutIndices = Dictionary(uniqueKeysWithValues: SessionRecord.shortcutOrder(store.sessions, now: now).enumerated().map { ($0.element.id, $0.offset) })
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, session in
                        if !showingClosed, index == 0 || rows[index - 1].group(now: now) != session.group(now: now) {
                            GroupHeader(group: session.group(now: now), first: index == 0)
                        }
                        // 临时会话不可跳转，不占快捷键序号。
                        SessionRow(session: session, now: now,
                                   shortcut: !showingClosed && jump.shortcutHints ? shortcutIndices[session.id].flatMap { PanelKey.sessionShortcutLabel($0) } : nil,
                                   tty: crowded.contains(session.cwd) ? session.tty : nil)
                    }
                    if !showingClosed, let waits = store.todayWaits {
                        WaitSummaryLine(day: waits)
                    }
                }
            }
        }
    }
}

/// 等你账本的当天一行（docs/ai.md「等你账本」）：和组头同一色阶的灰字，在列表最底下；今天没等过就不画。
private struct WaitSummaryLine: View {
    let day: WaitLedger.Day

    var body: some View {
        Text(WaitLedger.label(day))
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.4))
            .padding(.leading, 6)
            .padding(.top, 6)
    }
}

/// 组头：一行灰色小字。
private struct GroupHeader: View {
    let group: SessionRecord.Group
    let first: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.4))
            .padding(.leading, 6)
            .padding(.top, first ? 0 : 4)
    }

    private var title: String {
        switch group {
        case .waiting: return "等你"
        case .working: return "在跑"
        case .idle: return "待关联"
        case .recent: return "完成"
        case .stale: return "失联"
        case .closed: return "已关闭"
        }
    }
}

struct SessionRow: View {
    let session: SessionRecord
    let now: Date
    /// 按住 ⌘ 时行尾显示的编号（⌘1…⌘9、⌘0），nil 不显示。
    let shortcut: String?
    /// 同目录有别的会话时跟在目录名后面的终端号，nil 不显示。
    let tty: String?
    var jump = SessionJump.shared
    @State private var hovered = false

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        if session.state == .ended {
            // 已关闭的行本身不可点：点下去会开新终端，只认行尾那颗「接着聊」
            content(stale: false, ended: true)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.05)))
        } else if session.isProvisional {
            content(stale: false, ended: false)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.05)))
        } else {
            Button(action: focus) {
                content(stale: session.isStale(now: now), ended: false)
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hovered ? 0.10 : 0.05)))
            .onHover { hovered = $0 }
            .animation(.smooth(duration: 0.2), value: hovered)
        }
    }

    private func content(stale: Bool, ended: Bool) -> some View {
            HStack(spacing: 8) {
                StateIcon(state: session.state, stale: stale, backgroundWork: session.backgroundWork != nil, identity: session.sessionId)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        // 从中间截断：URL、文件名这种能区分两条会话的部分都在尾巴上
                        Text(session.displayTitle)
                            .font(.system(size: 12, weight: .medium))
                            .italic(stale)
                            .foregroundStyle(stale || ended ? .white.opacity(0.45) : .white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        ProviderTag(session: session)
                        // tmux 里的会话点了先切 pane 再带外层终端，标出来免得以为跳错了地方
                        if session.term == "tmux" {
                            RowTag(text: "tmux", tint: .white.opacity(0.7))
                        }
                        // 主回合完了后台还有活：放标题旁、绿底绿字，灰字那栏太弱看不出来
                        if session.isProvisional { RowTag(text: "未关联", tint: .white.opacity(0.7)) }
                        if let work = session.backgroundWork {
                            RowTag(text: work == .agents ? "后台 agent 在跑" : "后台命令在跑", tint: .green)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(tty.map { "\(session.cwdLabel) · \($0)" } ?? session.cwdLabel)
                        Text(Self.relative.localizedString(for: session.updatedDate, relativeTo: now))
                        if stale { Text("失联") }
                        if session.state == .compacting { Text("压缩上下文中") }
                        if ended { Text("已关闭") }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let failure = jump.failures[session.sessionId] {
                    Text(failure)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.12)))
                }
                if ended {
                    Button(action: focus) {
                        Text("接着聊")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.white.opacity(0.14)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
    }

    private func focus() {
        // 脚本在后台跑，这里只等结果：第一次跳某个终端会弹自动化授权框，主线程不能卡在那儿
        Task { await jump.run(session) }
    }
}

/// 跳回会话的终端（已关闭的会话是在新终端里接着聊）。点会话行和 ⌘1–⌘9 / ⌘0 共用；失败的那句话按会话记在这儿，行里红字显示——
/// 记在行自己的 @State 里的话，⌘N 跳失败时面板里那一行根本不知道。
@MainActor
@Observable
final class SessionJump {
    static let shared = SessionJump()

    /// session_id → 上次跳失败的原因；跳成功就清掉。
    private(set) var failures: [String: String] = [:]
    /// 按住 ⌘ 时为真：前十行行尾显示 ⌘1…⌘9、⌘0。面板的键盘监视器写。
    var shortcutHints = false

    /// 返回跳没跳成。
    @discardableResult
    func run(_ session: SessionRecord) async -> Bool {
        let failure = await Self.attempt(session)
        failures[session.sessionId] = failure
        return failure == nil
    }

    private static func attempt(_ session: SessionRecord) async -> String? {
        guard !session.isProvisional else { return "未关联真实会话" }
        // 演示模式的会话没有终端：跳过去会把别的真窗口叫到前台，接着聊会开新终端；当作跳成了，行里不出红字
        guard !DemoMode.isOn else { return nil }
        do {
            if session.state == .ended {
                try await SessionResume.run(session)
            } else {
                try await TerminalLocator.focus(session: session)
            }
            return nil
        } catch TerminalLocator.Failure.notFound {
            return "找不到窗口"
        } catch TerminalLocator.Failure.ambiguous {
            return "无法确定窗口"
        } catch TerminalLocator.Failure.notRunning(let app) {
            return "\(app) 没在跑"
        } catch TerminalLocator.Failure.directoryMissing {
            return "会话目录不在了"
        } catch TerminalLocator.Failure.needsAutomationPermission(let app) {
            // 拒过之后系统不再弹框，只能自己把设置面板指出来
            TerminalLocator.openAutomationSettings()
            return "要允许 Tally 控制 \(app)"
        } catch {
            Log.error("定位失败: \(error)")
            return "定位失败"
        }
    }
}

/// 会话行的标签：提供方标志 + 模型短名（「Opus 5」「gpt-6-astra」），还不知道模型时写「Claude」「Codex」。
struct ProviderTag: View {
    let session: SessionRecord

    var body: some View {
        HStack(spacing: 3) {
            ProviderLogo(name: session.provider == "codex" ? "openai" : "claude", size: 9)
            Text(session.modelLabel ?? session.providerLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.14)))
    }
}

/// 标题旁的小标签：tmux、后台还在跑。
struct RowTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.18)))
    }
}

/// 状态语义保留在辅助功能文本中，不依赖颜色或动画。
struct StateIcon: View {
    let state: SessionRecord.State
    let stale: Bool
    let backgroundWork: Bool
    var identity = ""
    @State private var visible = false

    var body: some View {
        SessionEyes(mood: mood, identity: identity, active: visible)
            .accessibilityHidden(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .help(label)
            .onScrollVisibilityChange(threshold: 0.05) { visible = $0 }
    }

    private var mood: SessionEyes.Mood {
        if stale { return .stale }
        switch state {
        case .waitingPermission: return .permission
        case .waitingInput: return .input
        case .running: return .working
        case .compacting: return .compacting
        case .done: return backgroundWork ? .working : .happy
        case .ended: return .sleeping
        }
    }

    private var label: String {
        if stale { return "失联" }
        switch state {
        case .waitingPermission: return "等审批"
        case .waitingInput: return "等输入"
        case .running: return "正在工作"
        case .compacting: return "压缩上下文中"
        case .done: return backgroundWork ? "主回合已结束，后台仍在工作" : "已完成"
        case .ended: return "已关闭"
        }
    }


}
