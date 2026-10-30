import Foundation

/// 刘海旁一个角色对应「一家工具在一个项目里」：同一家在同一个（规范化后的）首见 cwd 下所有没关闭的会话。
/// 同一目录两家都开着就是两个角色。
struct CrewProject: Equatable, Identifiable {
    /// `<工具>:<目录>`
    let id: String
    /// "claude" 或 "codex"
    let provider: String
    /// 规范化后的目录
    let path: String
    /// 目录最后一段；根目录是 "/"
    let name: String
    /// 不含 ended，按 `SessionRecord.displayOrder`
    let sessions: [SessionRecord]
    /// 会话里最急的那个
    let mood: CrewMood
    /// 等审批 / 等输入的项目里等得最久的那条开始等的时刻；排序用，不在等为 nil
    var waitingSince: Date? = nil
    /// 等了多久的档（docs/crew.md「等久了换档」）；不在等恒为刚弹出
    var tier: CrewTier = .fresh
}

/// 两翼各放哪些项目（下标 0 贴刘海）；`overflow > 0` 时 `overflowSide` 那翼最外一格是「+N」胶囊，N 连被顶掉的那一个一起数。
struct CrewLayout: Equatable {
    let right: [CrewProject]
    let left: [CrewProject]
    let overflow: Int
    var overflowSide: CrewGeometry.Side = .left

    var rightSlots: Int { right.count + (overflow > 0 && overflowSide == .right ? 1 : 0) }
    var leftSlots: Int { left.count + (overflow > 0 && overflowSide == .left ? 1 : 0) }
}

struct BadgeLifecycle {
    enum Kind: Equatable { case joined, departed, returned }
    private var previous: [String: SessionRecord]?

    mutating func reset() { previous = nil }

    mutating func update(_ records: [SessionRecord], emit: Bool) -> [(Kind, SessionRecord)] {
        let current = Dictionary(records.map { ("\(CrewRoster.tool(of: $0)):\($0.sessionId)", $0) }, uniquingKeysWith: { _, last in last })
        guard var known = previous else { previous = current; return [] }
        var events: [(Kind, SessionRecord)] = []
        for (key, record) in current where record.provider == "codex" && !record.isProvisional && record.state != .ended && known[key] == nil {
            let candidates = known.filter { $0.value.isProvisional && $0.value.state != .ended && $0.value.pid != nil && $0.value.pid == record.pid && $0.value.tty != nil && $0.value.tty == record.tty }
            let competing = current.values.filter { !$0.isProvisional && $0.state != .ended && $0.provider == "codex" && $0.pid == record.pid && $0.tty == record.tty }
            if candidates.count == 1, competing.count == 1, let match = candidates.first, current[match.key] == nil {
                known[key] = match.value
                known[match.key] = nil
            }
        }
        for (key, record) in current {
            if emit {
                if let old = known[key] {
                    if old.state != .ended && record.state == .ended { events.append((.departed, record)) }
                    else if old.state == .ended && record.state != .ended { events.append((.returned, record)) }
                } else if record.state != .ended { events.append((.joined, record)) }
            }
            known[key] = record
        }
        // shortcut: Keep 500 absent sessions in memory; use persistent history if users need older resume identities.
        let absent = known.filter { current[$0.key] == nil }.sorted { $0.value.updatedAt > $1.value.updatedAt }
        for entry in absent.dropFirst(500) {
            known[entry.key] = nil
        }
        previous = known
        return events.sorted { $0.1.sessionId < $1.1.sessionId }
    }
}

/// 会话 → 项目 → 槽位，全是纯函数；时间和目录规范化都由调用方传入，测试不碰真目录。
enum CrewRoster {
    static let launchGrace: TimeInterval = 10

    /// 名册只认两家：hook 只写 claude / codex（`HookRunner.providers`），别的值按 Claude 算，和 `providerLabel` 一致。
    static func tool(of session: SessionRecord) -> String { session.provider == "codex" ? "codex" : "claude" }

    /// 失联判在最前，和 AI 页「失联」同一函数；`done` 还有后台活算在跑。`ended` 不进名册，调用方先滤掉。
    static func mood(of session: SessionRecord, now: Date) -> CrewMood? {
        if session.state == .ended { return nil }
        if session.isStale(now: now) { return .stale }
        switch session.state {
        case .waitingPermission: return .permission
        case .waitingInput: return .input
        case .compacting: return .compacting
        case .running: return .run
        case .done: return session.backgroundWork == nil ? .done : .run
        case .ended: return nil
        }
    }

    /// `NSString.standardizingPath` 去掉 `.`、`..`、多余和结尾的斜杠；符号链接由调用方的闭包解，这里不碰文件系统。
    static func standardized(_ cwd: String) -> String {
        let path = (cwd as NSString).standardizingPath
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    static func projects(_ sessions: [SessionRecord], now: Date, canonicalize: (String) -> String = standardized) -> [CrewProject] {
        struct Key: Hashable { let tool: String, path: String }
        var groups: [Key: [SessionRecord]] = [:]
        for session in sessions where session.state != .ended {
            groups[Key(tool: tool(of: session), path: canonicalize(session.cwd)), default: []].append(session)
        }
        return groups.map { key, members in
            let ordered = SessionRecord.displayOrder(members, now: now)
            let last = URL(fileURLWithPath: key.path).lastPathComponent
            let folded = ordered.compactMap { mood(of: $0, now: now) }.min() ?? .done
            // 失联的等你不算：它已经按 stale 画了
            let waitingSince = folded.isWaiting
                ? ordered.compactMap { $0.isWaiting && !$0.isStale(now: now) ? ($0.waitingSince ?? $0.updatedDate) : nil }.min()
                : nil
            return CrewProject(id: "\(key.tool):\(key.path)", provider: key.tool, path: key.path, name: last.isEmpty ? "/" : last, sessions: ordered,
                               mood: folded, waitingSince: waitingSince, tier: CrewTier.of(waited: waitingSince.map { now.timeIntervalSince($0) }))
        }.sorted { a, b in
            if a.mood != b.mood { return a.mood < b.mood }
            // 等你的按开始等的时刻正序：等得最久的最靠刘海，被忘掉的那条才该最显眼
            if let wa = a.waitingSince, let wb = b.waitingSince, wa != wb { return wa < wb }
            let ua = a.sessions.map(\.updatedAt).max() ?? 0, ub = b.sessions.map(\.updatedAt).max() ?? 0
            if ua != ub { return ua > ub }
            return a.id < b.id
        }
    }

    /// FNV-1a 取模：只看字符串，换机器、重启都一样。
    static func bucket(_ text: String, of count: Int) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(count))
    }

    /// 每侧最多几个，夹在 1–4：0 等于关掉（开关另有），5 以上就压到菜单栏项目了。
    static func perSide(_ value: Int) -> Int { min(max(value, 1), 4) }

    /// 浮动交界：Claude 一块在左、Codex 一块在右，两块相邻；各家都不超过 perSide 时交界就是刘海，一家超过就把交界往对面推，
    /// 多出来的占对面翼贴刘海的格。每块里按离刘海由近到远放最急到最闲（同距先放自己那边）。只用一家时不分边，围着刘海左右交替。
    /// 放不下时按急缓砍最闲的（不分工具），只显示前 `2 × perSide − 1` 个，空出的最外一格给「+N」胶囊。
    static func layout(_ projects: [CrewProject], perSide: Int) -> CrewLayout {
        let perSide = Self.perSide(perSide)
        let capacity = 2 * perSide
        let overflow = projects.count > capacity ? projects.count - (capacity - 1) : 0
        let shown = Array(projects.prefix(overflow > 0 ? capacity - 1 : projects.count))
        let warm = shown.filter { $0.provider != "codex" }, cool = shown.filter { $0.provider == "codex" }
        if warm.isEmpty || cool.isEmpty {
            var right: [CrewProject] = [], left: [CrewProject] = []
            for (index, project) in shown.enumerated() {
                if index.isMultiple(of: 2) { right.append(project) } else { left.append(project) }
            }
            return CrewLayout(right: right, left: left, overflow: overflow, overflowSide: .left)
        }
        // 一排 capacity 个位置：0 ..< perSide 是左翼（0 最外），perSide ..< capacity 是右翼（perSide 贴刘海）
        let divider = warm.count > perSide ? warm.count : (cool.count > perSide ? capacity - cool.count : perSide)
        var row = [CrewProject?](repeating: nil, count: capacity)
        func place(_ block: [CrewProject], at positions: Range<Int>, ownSide: Range<Int>) {
            let nearestFirst = positions.sorted { a, b in
                let da = abs(2 * a + 1 - capacity), db = abs(2 * b + 1 - capacity)
                return da != db ? da < db : ownSide.contains(a)
            }
            for (project, position) in zip(block, nearestFirst) { row[position] = project }
        }
        place(warm, at: (divider - warm.count)..<divider, ownSide: 0..<perSide)
        place(cool, at: divider..<(divider + cool.count), ownSide: perSide..<capacity)
        let left = (0..<perSide).compactMap { row[perSide - 1 - $0] }
        let right = (0..<perSide).compactMap { row[perSide + $0] }
        return CrewLayout(right: right, left: left, overflow: overflow, overflowSide: row[0] == nil ? .left : .right)
    }

    /// 会话第一次露面才发；启动宽限期内也记住，避免晚些时候补发。
    static func newcomers(seen: Set<String>, current: [CrewProject], launchedAt: Date, now: Date) -> (badge: [(CrewProject, SessionRecord)], seen: Set<String>) {
        let records = current.flatMap { project in project.sessions.map { (project, $0) } }
        let fresh = records.filter { !seen.contains("\(tool(of: $0.1)):\($0.1.sessionId)") }
        let badge = now.timeIntervalSince(launchedAt) >= launchGrace ? fresh : []
        return (badge, seen.union(records.map { "\(tool(of: $0.1)):\($0.1.sessionId)" }))
    }
}
