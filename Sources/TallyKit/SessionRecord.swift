import Foundation

/// 一个 agent 会话的状态，和 hook 写的 JSON 一一对应。app 读、hook 写，所以放在共用库里。
public struct SessionRecord: Codable, Equatable, Identifiable {

    public enum State: String, Codable {
        case running
        case waitingPermission = "waiting_permission"
        case waitingInput = "waiting_input"
        /// 在压缩上下文（PreCompact）：长会话要几十秒，不标出来看着像卡住。
        case compacting
        case done
        /// 会话已关闭（交互会话的 SessionEnd，或进程没了），留一行给人接着聊。
        case ended
    }

    public var sessionId: String
    /// `claude` 或 `codex`。老文件没有这个键，按 claude 处理。
    public var provider: String
    /// agent 本体进程的 pid，用来判会话还活不活着。hook 找不到时为 nil。
    public var pid: Int?
    /// hook 进程环境里的 `TERM_PROGRAM`，定位窗口时按它分派。
    public var term: String?
    /// agent 进程的控制终端，形如 `ttys003`。
    public var tty: String?
    public var state: State
    /// 会话启动时的目录：定位窗口要的是 shell 所在目录，hook 收到的 cwd 会跟着会话里的 cd 走，所以只记第一次的。
    public var cwd: String
    public var title: String?
    public var transcriptPath: String
    public var message: String?
    public var waitingDetail: String?
    public var recentActivity: String?
    /// 毫秒时间戳。
    public var updatedAt: Double
    /// 会话在用的模型 id，如 `claude-opus-5`、`gpt-6-astra`；还不知道时为 nil。来源见 `HookRunner`。
    public var model: String?
    /// 主回合结束后还在后台干活的东西：agent 类任务（Claude Code 的 status 是 busy）或后台命令（shell）。
    /// app 每轮刷新从 Claude Code 自己的状态文件读出来放在内存里，不进 JSON，hook 不管它（docs/ai.md「后台还在跑」）。
    public var backgroundWork: BackgroundWork?
    /// 开始等你的时刻：Claude 记录取状态文件里的 `statusUpdatedAt`（status 翻成 waiting 的那一毫秒，永远优先，变晚就是新的一次等）；
    /// 没有就沿用上一轮的值、再没有才 `updated_at`，不随 hook 再写而往后挪。只在内存，不进 JSON，不在等时为 nil（docs/ai.md「等你」）。
    public var waitingSince: Date?
    /// A process-only placeholder; never serialized as a Codex session.
    public var isProvisional = false
    public var provisionalStart: UInt64?

    public enum BackgroundWork {
        case agents
        case shells
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case provider
        case pid
        case term
        case tty
        case state
        case cwd
        case title
        case transcriptPath = "transcript_path"
        case message
        case waitingDetail = "waiting_detail"
        case recentActivity = "recent_activity"
        case updatedAt = "updated_at"
        case model
    }

    public init(sessionId: String, provider: String = "claude", pid: Int? = nil, term: String? = nil, tty: String? = nil,
                state: State, cwd: String, title: String?, transcriptPath: String, message: String?, updatedAt: Double,
                model: String? = nil) {
        self.sessionId = sessionId
        self.provider = provider
        self.pid = pid
        self.term = term
        self.tty = tty
        self.state = state
        self.cwd = cwd
        self.title = title
        self.transcriptPath = transcriptPath
        self.message = message
        self.updatedAt = updatedAt
        self.model = model
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "claude"
        pid = try c.decodeIfPresent(Int.self, forKey: .pid)
        term = try c.decodeIfPresent(String.self, forKey: .term)
        tty = try c.decodeIfPresent(String.self, forKey: .tty)
        state = try c.decode(State.self, forKey: .state)
        cwd = try c.decode(String.self, forKey: .cwd)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message)
        waitingDetail = try c.decodeIfPresent(String.self, forKey: .waitingDetail)
        recentActivity = try c.decodeIfPresent(String.self, forKey: .recentActivity)
        updatedAt = try c.decode(Double.self, forKey: .updatedAt)
        model = try c.decodeIfPresent(String.self, forKey: .model)
    }

    /// 可空字段一律写成显式 null，不省键：契约里说每个键都在，读的一方靠键存在判格式版本。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(provider, forKey: .provider)
        try c.encode(pid, forKey: .pid)
        try c.encode(term, forKey: .term)
        try c.encode(tty, forKey: .tty)
        try c.encode(state, forKey: .state)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(title, forKey: .title)
        try c.encode(transcriptPath, forKey: .transcriptPath)
        try c.encode(message, forKey: .message)
        try c.encode(waitingDetail, forKey: .waitingDetail)
        try c.encode(recentActivity, forKey: .recentActivity)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(model, forKey: .model)
    }

    public var id: String { sessionId }

    public var updatedDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }

    public var isClaude: Bool { provider == "claude" }

    /// 行里的提供方标签。
    public var providerLabel: String { provider == "codex" ? "Codex" : "Claude" }

    /// 行里的模型短名，还不知道模型时为 nil。
    public var modelLabel: String? { model.map(Self.shortModelName) }

    /// `claude-opus-5` →「Opus 5」、`claude-fable-5-1` →「Fable 5.1」、`claude-haiku-4-5-20251001` →「Haiku 4.5」、
    /// 老式的 `claude-3-5-sonnet-20241022` →「Sonnet 3.5」。别家的原样用（`gpt-6-astra`），不去猜它的营销名。
    public static func shortModelName(_ raw: String) -> String {
        var parts = raw.split(separator: "-").map(String.init)
        guard parts.first == "claude", parts.count >= 2 else { return raw }
        parts.removeFirst()
        // 末尾 8 位数字是发布日期
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        let words = parts.filter { Int($0) == nil }
        let version = parts.filter { Int($0) != nil }.joined(separator: ".")
        guard let family = words.first else { return raw }
        let name = [family.prefix(1).uppercased() + family.dropFirst()] + words.dropFirst()
        return (name + (version.isEmpty ? [] : [version])).joined(separator: " ")
    }

    /// 等审批或等输入。
    public var isWaiting: Bool {
        state == .waitingPermission || state == .waitingInput
    }


    /// 非 done / ended 且两小时没动静。跑完了、关掉了的会话不算失联。
    public func isStale(now: Date) -> Bool {
        !isProvisional && state != .done && state != .ended && now.timeIntervalSince(updatedDate) > 2 * 3600
    }

    /// Group order keeps active work first, then completed and stale records; closed sessions are on their own page.
    public enum Group: Int, CaseIterable {
        case waiting, working, idle, recent, stale, closed
    }

    public func group(now: Date) -> Group {
        if state == .ended { return .closed }
        if isProvisional { return .idle }
        if isStale(now: now) { return .stale }
        switch state {
        case .waitingPermission, .waitingInput: return .waiting
        case .running, .compacting: return .working
        case .done: return backgroundWork == nil ? .recent : .working
        case .ended: return .closed
        }
    }

    /// 列表的显示顺序：等你 → 在跑 → 完成 → 失联 → 已关闭。等你组按开始等的时刻正序（等得最久的在最上面、就是 ⌘1：
    /// 被忘掉的那条才该最显眼），其余组按 updated_at 倒序。
    public static func displayOrder(_ sessions: [SessionRecord], now: Date) -> [SessionRecord] {
        sessions.sorted { a, b in
            let ga = a.group(now: now), gb = b.group(now: now)
            if ga != gb { return ga.rawValue < gb.rawValue }
            if ga == .waiting {
                let wa = a.waitingSince ?? a.updatedDate, wb = b.waitingSince ?? b.updatedDate
                if wa != wb { return wa < wb }
            } else if a.updatedAt != b.updatedAt {
                return a.updatedAt > b.updatedAt
            }
            return a.sessionId < b.sessionId
        }
    }

    /// ⌘1–⌘9 / ⌘0 按这个数：显示顺序里去掉已关闭的。已关闭的在会话卡片的另一页，只能点行尾「接着聊」，按键碰不到它。
    public static func shortcutOrder(_ sessions: [SessionRecord], now: Date) -> [SessionRecord] {
        displayOrder(sessions, now: now).filter { $0.state != .ended && !$0.isProvisional }
    }

    /// 这一页里同一目录下有不止一个会话时，行上要多标 tty 才分得清：同目录跑同一个 skill 的两条，标题只差 URL 尾巴。
    public static func crowdedCWDs(_ sessions: [SessionRecord]) -> Set<String> {
        var seen: Set<String> = []
        var crowded: Set<String> = []
        for session in sessions where !seen.insert(session.cwd).inserted {
            crowded.insert(session.cwd)
        }
        return crowded
    }

    /// 闭合态徽标计数用：在等我，且没失联。
    public func countsAsWaiting(now: Date) -> Bool {
        isWaiting && !isStale(now: now)
    }

    /// 标题为空时用 cwd 最后一段顶上。
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return cwdLabel
    }

    /// cwd 最后一段；根目录显示 `/`。
    public var cwdLabel: String {
        let last = URL(fileURLWithPath: cwd).lastPathComponent
        return last.isEmpty ? "/" : last
    }

    /// 带 pid 的记录：进程不在了就是会话没了（SessionEnd 没来的那种）。进程表拿不到时的退路。
    public var processIsGone: Bool {
        guard let pid else { return false }
        return kill(pid_t(pid), 0) == -1 && errno == ESRCH
    }

    /// 进程表版：pid 对应的那一行还得是 agent 本体。关机重启后低位 pid 很快被系统进程拿走，`kill(pid, 0)` 对别人的进程返回 EPERM，
    /// 看着像活着，那一行就一直留在「最近」里、点了也跳不到哪儿去。认 agent 的长相和 hook 找 pid 用同一套（`AgentLocator.isAgent`）。
    /// 路径或 argv 读不到是瞬时失败（root 的进程也读得到路径，不是权限问题）：判不了就当还活着，误判成没了会把活会话改成已关闭。
    public func processIsGone(in byPid: [Int32: ProcessEntry], table: ProcessTable) -> Bool {
        guard let pid else { return false }
        guard let entry = byPid[Int32(pid)] else { return true }
        if entry.path.isEmpty { return false }
        var arguments: [String]?
        if AgentLocator.isAgent(entry, arguments: { let read = table.arguments(of: entry.pid); arguments = read; return read }) { return false }
        return arguments?.isEmpty != true
    }

    /// Claude Code 的家：`CLAUDE_CONFIG_DIR` 设了就是它，没有就 `~/.claude`。hook 从 Claude Code 继承环境，直接看得到；
    /// app 的环境里没有，由 app 里的 `ClaudeHome` 问登录 shell 再传进来。
    public static func claudeHome(configDir: String?) -> URL {
        guard let configDir, !configDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        }
        return URL(fileURLWithPath: (configDir as NSString).expandingTildeInPath)
    }

    public static func claudeSessionsDirectory(configDir: String?) -> URL {
        claudeHome(configDir: configDir).appendingPathComponent("sessions")
    }

    /// Claude Code 自己维护的 `<pid>.json`（docs/ai.md「等你」「打断与 API 报错」「后台还在跑」）。
    public enum ClaudeCodeStatus: Equatable {
        /// 没有文件或没有 status 字段：老版本、桌面版托管的会话。
        case unknown
        /// 文件里的 sessionId 不是这条记录的：pid 被别的 Claude 拿走了，或同一个进程 /clear、/resume 换了会话，这条记录的会话都已经不在了。
        case anotherSession
        /// busy / shell / waiting / idle；waiting 时 `waitingFor` 说在等什么（「permission prompt」「input needed」「dialog open」…）；
        /// `since` 是 status 翻成现在这个值的那一毫秒（`statusUpdatedAt`），老版本没有。
        case reported(status: String, waitingFor: String?, since: Date?)
    }

    public func claudeCodeStatus(in directory: URL) -> ClaudeCodeStatus {
        guard let pid,
              let data = try? Data(contentsOf: directory.appendingPathComponent("\(pid).json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unknown }
        // 没有 sessionId 的文件说不清是谁的（老版本、半截文件），不能当成别的会话把活会话收掉
        guard let owner = object["sessionId"] as? String else { return .unknown }
        guard owner == sessionId else { return .anotherSession }
        guard let status = object["status"] as? String else { return .unknown }
        let since = (object["statusUpdatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return .reported(status: status, waitingFor: object["waitingFor"] as? String, since: since)
    }

    /// 回合一结束就写 idle，打断和 API 报错（这两种不发 Stop）也写，等审批写 waiting。
    public func claudeCodeReportsIdle(in directory: URL) -> Bool {
        if case .reported("idle", _, _) = claudeCodeStatus(in: directory) { return true }
        return false
    }

    /// Claude Code 说有对话框在等人时该标成哪种「等你」：审批框（含计划审批）是等审批，其余（AskUserQuestion、MCP elicitation、
    /// 各种对话框）是等输入。`waitingFor` 的默认值就是「permission prompt」，没单独标名字的对话框都按它报；字段都没有的版本也按等审批。
    public static func waitingState(for waitingFor: String?) -> State {
        waitingFor == nil || waitingFor == "permission prompt" ? .waitingPermission : .waitingInput
    }

    /// 超过 24 小时没更新的文件该删。活着但一天没事件的会话也会被清，
    /// 它下一次 UserPromptSubmit 会把文件重建。
    public static func orphans(files: [(url: URL, updatedAt: Date)], now: Date) -> [URL] {
        files.filter { now.timeIntervalSince($0.updatedAt) > 24 * 3600 }.map(\.url)
    }
}
