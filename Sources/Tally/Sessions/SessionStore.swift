import Foundation
import Observation

/// 会话状态目录的读取端：监视目录、解析文件、补标题、判存活、清孤儿。
///
/// hook 每次都是写临时文件再 rename，目录条目一变 kqueue 就会通知，
/// 所以用 `DispatchSource` 盯目录而不是轮询。
@MainActor
@Observable
final class SessionStore {

    /// 演示模式把两个目录都指到不存在的临时路径：默认参数里的 `ClaudeHome` 要问登录 shell、读心跳文件。
    static let shared = DemoMode.isOn
        ? SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("tally-demo-sessions"),
                       claudeSessions: FileManager.default.temporaryDirectory.appendingPathComponent("tally-demo-sessions"))
        : SessionStore()

    /// 按 updated_at 倒序。
    private(set) var sessions: [SessionRecord] = []
    /// 一个会话进入 done / 等审批 / 等输入时调一次，控制器拿它在闭合态弹提示。
    var sessionAlert: ((SessionRecord) -> Void)?
    var sessionsChanged: (([SessionRecord]) -> Void)?

    let directory: URL
    /// Claude Code 自己的 `~/.claude/sessions/<pid>.json`，见 `SessionRecord.claudeCodeStatus`。
    let claudeSessions: URL
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var reloadWork: DispatchWorkItem?
    private var cleanupTimer: Timer?
    private var refreshTimer: Timer?
    /// 宽限期到了再读一次 Claude Code 的 status，见「后台还在跑」。
    private var recheckWork: DispatchWorkItem?
    /// 刚写的 done 读到 busy 不算后台有活：上一回合的 busy 要等所有 Stop hook 跑完才换成 idle（本机实测 45 ms，门禁类 hook 能拖几秒）。
    static let backgroundGrace: TimeInterval = 10
    /// 整文件扫过一次的会话，不管有没有找到都记着，别反复扫几 MB 的文件。
    private var fullScanTitles: [String: String?] = [:]
    /// 标题都没有时拿第一句话顶上的会话。找到的记住（第一句话不会变）；没找到的连同读时的文件大小记住，
    /// 文件没长就不重读 1 MB：用户还没敲字、或第一句话在 1 MB 之外的会话，不然每轮刷新都读一遍。
    private var firstPrompts: [String: (size: UInt64, prompt: String?)] = [:]

    /// 设置里「保留已关闭的会话」；测试注入。
    private let keepClosed: () -> Bool
    /// 已关闭的会话最多留几条（设置里调，默认 10）：一天开关几十个会话的话，那一页会被它们挤满；测试注入。
    private let closedLimit: () -> Int
    private let activeCodexTUIByCWD: (ProcessTable, [ProcessEntry]) -> [String: Int]?
    /// 进程表：存活判断和找 Codex TUI 都用它，一轮刷新只拿一次；测试注入假表把自己当成 agent（真表里 xctest 不是）。
    private let processTable: ProcessTable
    /// Claude Code 自己的 `<pid>.json` 是原地改写的（inode 不变），盯目录收不到，按 pid 一个文件一个 vnode 监视器（docs/ai.md「等你」）。
    private var statusSources: [Int: DispatchSourceFileSystemObject] = [:]

    /// 单例整个进程周期都活着，不需要 deinit 里收 source。
    init(directory: URL = PreferencesStore.directory.appendingPathComponent("sessions"),
         claudeSessions: URL = ClaudeHome.url.appendingPathComponent("sessions"),
         keepClosed: (() -> Bool)? = nil,
         closedLimit: (() -> Int)? = nil,
         activeCodexTUIByCWD: ((ProcessTable, [ProcessEntry]) -> [String: Int]?)? = nil,
         processTable: ProcessTable = SysctlProcessTable()) {
        self.directory = directory
        self.claudeSessions = claudeSessions
        self.keepClosed = keepClosed ?? { PreferencesStore.shared.prefs.keepClosedSessions }
        self.closedLimit = closedLimit ?? { PreferencesStore.shared.prefs.closedSessionLimit }
        self.activeCodexTUIByCWD = activeCodexTUIByCWD ?? Self.liveCodexTUIByCWD(table:entries:)
        self.processTable = processTable
    }

    // MARK: 启动

    func start() {
        // 演示模式：会话是编的；不建目录、不读、不盯、不清孤儿、不回写，也就不会冒出状态变化的提示
        if DemoMode.isOn {
            sessions = DemoData.sessions(now: Date()).sorted { $0.updatedAt > $1.updatedAt }
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanupOrphans(now: Date())
        reload()
        watch()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.cleanupOrphans(now: Date())
                self?.reload()
            }
        }
        // 失联、存活和「几分钟前」都是时间的函数，文件不变也要定期重算一次。
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    private func watch() {
        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Log.error("打不开会话目录: \(directory.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .link],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    /// hook 连写几次时合并成一次读。
    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// 宽限期过了再读一次 status；连着几个回合结束只留最后一次。
    private func scheduleRecheck() {
        recheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        recheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.backgroundGrace, execute: work)
    }

    // MARK: 读取

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        let decoder = JSONDecoder()
        let now = Date()
        var recheck = false
        let decoded: [(URL, SessionRecord)] = files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(SessionRecord.self, from: data) else { return nil }
            return (file, record)
        }
        let table = processTable
        let entries = table.entries()
        let byPid = Dictionary(entries.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let closedCodexIDs = activeCodexTUIByCWD(table, entries).map { Self.codexSessionsWithoutTUI(decoded.map(\.1), activeByCWD: $0) } ?? []
        // 先挂监视器再读：挂在读之后的话，读完到挂上之间的那次改写会丢
        watchClaudeStatus(of: decoded.map(\.1))
        var loaded: [SessionRecord] = []
        var quiet: Set<String> = []
        for (file, original) in decoded {
            var record = original
            // Claude 会话一轮只读一次 Claude Code 自己的状态文件：存活、等你、补判、后台还在跑都看它
            var claudeStatus: String?
            var claudeWaitingFor: String?
            let claude = record.isClaude && record.state != .ended ? record.claudeCodeStatus(in: claudeSessions) : .unknown
            if case .reported(let status, let waitingFor) = claude {
                claudeStatus = status
                claudeWaitingFor = waitingFor
            }
            if record.state == .ended {
                // 已关闭的本来就没有进程，不走下面的存活判断；开关关着就删
                guard keepClosed() else {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
            } else if (entries.isEmpty ? record.processIsGone : record.processIsGone(in: byPid, table: table))
                        || (claude == .anotherSession && now.timeIntervalSince(record.updatedDate) >= Self.backgroundGrace)
                        || closedCodexIDs.contains(record.sessionId) {
                // 状态文件写着别的会话也算没了（pid 被别的 Claude 拿走、同一进程 /resume 换了会话）；刚写的记录不算：
                // /clear 之后新会话的 SessionStart hook 和 Claude Code 改写 sessionId 谁先谁后没有保证
                // 进程没了就是会话没了：终端被直接关掉时 SessionEnd 不会来。交互会话改成已关闭留着接着聊——
                // 进程已经没了，改文件不会和 hook 抢着写；脚本里跑的 claude -p / codex exec 直接删
                guard keepClosed(), !record.transcriptPath.isEmpty,
                      TranscriptTitle.isInteractive(transcript: URL(fileURLWithPath: record.transcriptPath), provider: record.provider)
                else {
                    try? FileManager.default.removeItem(at: file)
                    Log.debug("会话 \(record.sessionId) 的进程已退出，删掉状态文件")
                    continue
                }
                record.state = .ended
                record.message = nil
                record.updatedAt = (Date().timeIntervalSince1970 * 1000).rounded()
                do {
                    try JSONEncoder().encode(record).write(to: file, options: .atomic)
                } catch {
                    // 写不进去就只在内存里算已关闭，下一轮读目录再试
                    Log.error("会话 \(record.sessionId) 改成已关闭没写进去: \(error.localizedDescription)")
                }
            }
            if record.title == nil {
                record.title = resolveTitle(for: record)
            }
            // Claude Code 说有对话框在等人，就是等你，不管 hook 写的是什么（docs/ai.md「等你」）：permission_prompt 通知要等 6 秒才发；
            // 主回合 done 之后后台 agent 要审批、几个 agent 并行时别人的 PostToolUse 把等审批冲回 running，hook 这一路都接不住。
            // 反过来 hook 说等、Claude Code 说忙，就是对话框已经关了（审批过了、答完了、拒了）hook 还没写：AskUserQuestion 答完那次
            // PostToolUse 看到文件已经是 running 不会再写，不补这一笔「等你」会挂到下一次事件。
            // 打断和 API 报错结束的回合不发 Stop，文件停在 running / 等审批 / 等输入：补判成 done（docs/ai.md「打断与 API 报错」）。
            // 都只改内存不回写：回写会和 hook 抢，刚判完用户就发了下一句的话，app 写的 done 会盖掉 hook 写的 running。
            if claudeStatus == "waiting", record.state != .ended {
                record.state = SessionRecord.waitingState(for: claudeWaitingFor)
            } else if record.isWaiting, claudeStatus == "busy" {
                // busy 一定没有对话框：Claude Code 算 status 时先看对话框（有就是 waiting），没有才按在不在跑分 busy / idle
                record.state = .running
            } else if record.state != .done, record.state != .ended {
                let end = record.transcriptPath.isEmpty ? nil
                    : TranscriptTitle.turnEnd(in: URL(fileURLWithPath: record.transcriptPath), provider: record.provider)
                // 等输入不看 idle：elicitation 对话框是回合中途等人，那时写不写 idle 没验证过；idle_prompt 那种 hook 已经不写成等输入。
                // Codex 没有 status 文件，只看 rollout
                if end != nil || (record.state != .waitingInput && claudeStatus == "idle") {
                    record.state = .done
                    if case .apiError(let text) = end {
                        record.message = HookDecision.clip(text)
                    } else {
                        // 打断：人就在终端前按的 Esc，不用提示
                        record.message = nil
                        quiet.insert(record.sessionId)
                    }
                }
            }
            // 主回合 Stop 写了 done，后台 agent / 命令可能还在跑：子 agent 的 PostToolUse 故意不翻回 running（docs/ai.md「事件到状态」），
            // 「还有活」只有 Claude Code 自己的 status 知道——没结束的 agent 类任务是 busy，只剩后台命令是 shell。只标在内存里。
            // 只认盘上已经是 done 的：补判那轮读到的 busy 是下一句话的（busy 先于 UserPromptSubmit hook）；上面标成等你的不算
            if original.state == .done, record.state == .done {
                switch claudeStatus {
                case "busy":
                    if now.timeIntervalSince(record.updatedDate) >= Self.backgroundGrace {
                        record.backgroundWork = .agents
                    } else {
                        recheck = true
                    }
                case "shell":
                    // 主回合空闲时才写的值，没有上一回合残留的问题
                    record.backgroundWork = .shells
                default: break
                }
            }
            loaded.append(record)
        }
        // 已关闭的只留最新几条
        let dropped = Set(loaded.filter { $0.state == .ended }.sorted { $0.updatedAt > $1.updatedAt }
            .dropFirst(closedLimit()).map(\.sessionId))
        for id in dropped {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
        }
        loaded.removeAll { dropped.contains($0.sessionId) }
        if recheck { scheduleRecheck() }
        let alerts = Self.alerts(previous: sessions, current: loaded, quiet: quiet)
        sessions = loaded.sorted { $0.updatedAt > $1.updatedAt }
        sessionsChanged?(sessions)
        for record in alerts { sessionAlert?(record) }
    }

    /// Claude Code 原地改写 `<pid>.json`，目录级 kqueue 收不到内容变化，按文件挂 vnode 监视器：等你、后台还在跑、回合结束当场刷新，
    /// 不用等 hook 或 60 秒一次的重算；进程退出时它删文件，`.delete` 一来存活判断就把行收掉。
    /// 文件还没建出来（SessionStart hook 比它早几毫秒）就先不挂，下一轮读目录再试。
    private func watchClaudeStatus(of records: [SessionRecord]) {
        let wanted = Set(records.filter { $0.isClaude && $0.state != .ended }.compactMap(\.pid))
        for pid in statusSources.keys where !wanted.contains(pid) {
            statusSources.removeValue(forKey: pid)?.cancel()
        }
        for pid in wanted where statusSources[pid] == nil {
            let fd = open(claudeSessions.appendingPathComponent("\(pid).json").path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                // 删了、换了就丢掉监视器：旧 inode 上再也不会有事；下一轮读目录时文件还在再挂回去。只丢自己这个，别碰已经重挂的新监视器
                if !source.data.intersection([.delete, .rename]).isEmpty, self.statusSources[pid] === source {
                    self.statusSources.removeValue(forKey: pid)?.cancel()
                }
                self.scheduleReload()
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            statusSources[pid] = source
        }
    }

    /// Only a Codex TUI with a controlling terminal can keep one of the daemon-owned records open.
    /// If any TUI directory cannot be read, retain records until the next refresh.
    private static func liveCodexTUIByCWD(table: ProcessTable, entries: [ProcessEntry]) -> [String: Int]? {
        guard !entries.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for entry in entries where entry.tdev != nil && URL(fileURLWithPath: entry.path).lastPathComponent == "codex" {
            let args = table.arguments(of: entry.pid)
            if args.dropFirst().contains("exec") || args.dropFirst().contains("app-server") { continue }
            guard let cwd = SysctlProcessTable.workingDirectory(of: entry.pid) else { return nil }
            counts[canonicalCWD(cwd), default: 0] += 1
        }
        return counts
    }

    private static func canonicalCWD(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func codexSessionsWithoutTUI(_ records: [SessionRecord], activeByCWD: [String: Int]) -> Set<String> {
        let candidates = records.filter { record in
            record.provider == "codex" && record.state != .ended && record.pid != nil && record.tty == nil
                && !record.transcriptPath.isEmpty
                && TranscriptTitle.codexOriginator(rollout: URL(fileURLWithPath: record.transcriptPath)) == "codex-tui"
        }
        // A live TUI cannot be linked to one record when several sessions share a directory.
        // Close records only when that directory has no TUI at all.
        return Set(candidates.filter { activeByCWD[canonicalCWD($0.cwd), default: 0] == 0 }.map(\.sessionId))
    }

    /// 值得弹一下的会话：上一轮见过、这一轮进入了 done / 等审批 / 等输入，且和上一轮状态不同。
    /// 第一次露面就已经在那个状态的不算（Tally 晚于会话启动），done → running → done 每个回合都算。
    /// 进入压缩中、已关闭不算；`quiet` 里的会话不弹：打断补判出来的 done。
    static func alerts(previous: [SessionRecord], current: [SessionRecord], quiet: Set<String> = []) -> [SessionRecord] {
        let before = Dictionary(previous.map { ($0.sessionId, $0.state) }, uniquingKeysWith: { a, _ in a })
        return current.filter { record in
            guard record.state == .done || record.isWaiting, !quiet.contains(record.sessionId), let old = before[record.sessionId] else { return false }
            return old != record.state
        }
    }

    /// hook 没读到标题时 app 再试：Claude 先边车、文件尾、整文件扫一次并缓存；还没有（Codex 一律没有）就拿第一句话顶上。
    private func resolveTitle(for record: SessionRecord) -> String? {
        guard !record.transcriptPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: record.transcriptPath)
        if record.isClaude {
            if let quick = TranscriptTitle.read(from: url, sessionId: record.sessionId) { return quick }
            let full: String?
            if let cached = fullScanTitles[record.sessionId] {
                full = cached
            } else {
                full = TranscriptTitle.readFull(from: url)
                fullScanTitles[record.sessionId] = full
            }
            if let full { return full }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: record.transcriptPath)[.size] as? UInt64) ?? 0
        if let cached = firstPrompts[record.sessionId], cached.prompt != nil || cached.size == size { return cached.prompt }
        let prompt = TranscriptTitle.firstPrompt(in: url, provider: record.provider)
        firstPrompts[record.sessionId] = (size, prompt)
        return prompt
    }
    func waitingCount(now: Date = Date()) -> Int {
        sessions.filter { $0.countsAsWaiting(now: now) }.count
    }

    // MARK: 清理

    func cleanupOrphans(now: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        var candidates: [(url: URL, updatedAt: Date)] = []
        let decoder = JSONDecoder()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(SessionRecord.self, from: data)
            else { continue }
            candidates.append((file, record.updatedDate))
        }
        for url in SessionRecord.orphans(files: candidates, now: now) {
            try? FileManager.default.removeItem(at: url)
            fullScanTitles[url.deletingPathExtension().lastPathComponent] = nil
            firstPrompts[url.deletingPathExtension().lastPathComponent] = nil
            Log.debug("清掉孤儿会话文件 \(url.lastPathComponent)")
        }
    }
}
