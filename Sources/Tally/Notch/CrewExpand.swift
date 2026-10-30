import AppKit

/// 点一格该干什么；执行层按它分派，这里不碰终端。
enum CrewTap: Equatable {
    case jump(SessionRecord)
    case openAI
}

/// 悬停撑开的纯函数部分：点击分派、两行文案、显示状态机。定时器时长由状态自己说，控制器只排表、把该撑开的格告诉翅膀。
/// 曾经是挂在格子下面 300pt 宽的气泡（头部 + 会话行 + 固定列表），挡住下面的窗口、看着也重，去掉了。
enum CrewExpand {
    static let showDelay = 0.15
    static let hideDelay = 0.3

    /// 单会话直接跳；多会话和「+N」胶囊都展开 AI 页，那页本来就有完整列表，翼上不再养一份
    static func tap(_ slot: CrewSlot) -> CrewTap {
        guard let project = slot.project, project.sessions.count == 1 else { return .openAI }
        guard !project.sessions[0].isProvisional else { return .openAI }
        return .jump(project.sessions[0])
    }

    enum Event: Equatable {
        case enterSlot(CrewHover)
        case leaveSlot
        case tap(CrewTap)
        /// 名册刷新：挂着的项目现在在哪一格；nil 是不在翼上了
        case refresh(CrewHover?)
        case showTimer
        case hideTimer
        /// 面板展开：立刻收
        case dismiss
    }

    enum Phase: Equatable { case hidden, pending, shown, closing }

    enum State: Equatable {
        case hidden
        /// 进槽了，等 150 ms 再撑开
        case pending(CrewHover)
        case shown(CrewHover)
        /// 离开了，等一会儿再收；期间回来就取消
        case closing(CrewHover)

        var phase: Phase {
            switch self {
            case .hidden: .hidden
            case .pending: .pending
            case .shown: .shown
            case .closing: .closing
            }
        }

        var hover: CrewHover? {
            switch self {
            case .hidden: nil
            case .pending(let hover), .shown(let hover), .closing(let hover): hover
            }
        }

        var isVisible: Bool {
            switch self {
            case .shown, .closing: true
            case .hidden, .pending: false
            }
        }

        /// 这个状态要排的定时器（秒）；到点发 `showTimer` / `hideTimer`
        var delay: Double? {
            switch self {
            case .pending: CrewExpand.showDelay
            case .closing: CrewExpand.hideDelay
            case .hidden, .shown: nil
            }
        }

        func reduce(_ event: Event) -> State {
            switch (self, event) {
            case (_, .dismiss):
                return .hidden
            case (_, .refresh(let fresh)):
                guard let fresh else { return .hidden }
                switch self {
                case .hidden: return .hidden
                case .pending: return .pending(fresh)
                case .shown: return .shown(fresh)
                case .closing: return .closing(fresh)
                }
            case (.hidden, .enterSlot(let hover)), (.pending, .enterSlot(let hover)):
                return .pending(hover)
            case (.pending(let hover), .showTimer):
                return .shown(hover)
            // 点击本身就是动作（跳走或展开面板），没必要再撑开
            case (.pending, .leaveSlot), (.pending, .tap), (.shown, .tap), (.closing, .hideTimer):
                return .hidden
            case (.shown, .enterSlot(let next)), (.closing, .enterSlot(let next)):
                return .shown(next)
            case (.shown(let hover), .leaveSlot):
                return .closing(hover)
            default:
                return self
            }
        }
    }
}

/// 翅膀的悬停与点击都汇到这里：跑状态机、排定时器、告诉翅膀撑开哪格；跳转和展开 AI 页走注入的闭包。
@MainActor
final class CrewExpandController {
    var jump: ((SessionRecord) -> Void)?
    var openAI: (() -> Void)?
    /// 该撑开哪一格（nil 全收）；`CrewController` 据此重排两翼
    var apply: ((CrewHover?) -> Void)?
    private(set) var state: CrewExpand.State = .hidden
    private var timer: Timer?

    func hover(_ hover: CrewHover?) {
        send(hover.map { .enterSlot($0) } ?? .leaveSlot)
    }

    func click(_ hover: CrewHover) {
        let tap = CrewExpand.tap(hover.slot)
        send(.tap(tap))
        switch tap {
        case .jump(let session): jump?(session)
        case .openAI: openAI?()
        }
    }

    /// 名册刷新后由调用方按项目 id 找回它现在的槽；找不到就收。
    func refresh(_ locate: (CrewHover) -> CrewHover?) {
        guard let hover = state.hover else { return }
        send(.refresh(locate(hover)))
    }

    func dismiss() { send(.dismiss) }

    private func send(_ event: CrewExpand.Event) {
        let next = state.reduce(event)
        guard next != state else { return }
        // 只换了内容（名册刷新、同一格的会话更新）不重排表：hook 事件密的时候，每次都重排的话该收的永远收不掉、该出的永远出不来
        let rearm = next.phase != state.phase
        state = next
        if rearm {
            timer?.invalidate()
            timer = nil
            if let delay = next.delay {
                let phase = next.phase
                let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.state.phase == phase else { return }
                        self.send(phase == .closing ? .hideTimer : .showTimer)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
        }
        apply?(state.isVisible ? state.hover : nil)
    }
}
