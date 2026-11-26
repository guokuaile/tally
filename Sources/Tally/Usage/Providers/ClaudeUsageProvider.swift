// 移植自 Atoll（https://github.com/Ebullioscopic/Atoll），Copyright (C) 2024-2026 Atoll Contributors，GPL-3.0，见仓库 LICENSE 与 NOTICE。
// Tally 改动：配额不再调会回写凭据的客户端；先读 statusline 缓存，没有或陈旧再用只读客户端；按模型分的周窗口只有接口有，单独按 10 分钟节流取；凭据被改写（切账号）时清掉那条窗口重取，手动刷新不等节流；日志走 UsageScanCache 增量扫描；projects 与 .claude.json 跟着 ClaudeHome（CLAUDE_CONFIG_DIR）；没有日志的提示改成中文并写明下一步。
import Foundation

struct ClaudeUsageProvider: UsageProvider {
    let id: ProviderID = .claude
    let root: URL
    let limits: ClaudeLimitsCache
    let currentAccount: () -> (accountUUID: String, organizationUUID: String)?
    /// 引用类型：provider 是 struct，被 UsageStore 存着复制来复制去，节流状态与扫描缓存都得挂在盒子里才留得住。
    let scopedBox: ScopedLimitsBox
    let scan: UsageScanCache

    init(root: URL = ClaudeHome.url.appendingPathComponent("projects"),
         limits: ClaudeLimitsCache = ClaudeLimitsCache(),
         scopedBox: ScopedLimitsBox = ScopedLimitsBox(),
         scan: UsageScanCache = UsageScanCache(name: "claude"),
         currentAccount: @escaping () -> (accountUUID: String, organizationUUID: String)? = { Self.currentAccountIdentity() }) {
        self.root = root
        self.limits = limits
        self.scopedBox = scopedBox
        self.scan = scan
        self.currentAccount = currentAccount
    }

    /// 按模型分的周窗口（Fable 那条）只有官方接口给，statusline 缓存没有。缓存新鲜时也要每 10 分钟问一次接口
    /// 才拿得到它，其余时间沿用上一次的值——这个窗口按周走，差十分钟无所谓。
    /// 取成功隔 10 分钟再取；失败只隔 1 分钟——代理偶发 SSL 断连，等十分钟这条就一直不出现。
    /// 不管成没成都要记时间，否则 token 过期时会变成每次刷新都去读凭据。
    final class ScopedLimitsBox: @unchecked Sendable {
        static let interval: TimeInterval = 600
        static let retryInterval: TimeInterval = 60

        private let lock = NSLock()
        private var value: [ScopedLimit] = []
        private var nextFetch: Date = .distantPast
        private var requestID = 0
        private var owner: Int?
        private var onUpdate: ((Int, [ScopedLimit]) -> Void)?

        init() {}

        /// 后台那次取到值时叫一声，界面立刻补上这条，不用等下一轮刷新（进程刚起来时差 5 分钟太久）。
        func setOnUpdate(_ handler: @escaping (Int, [ScopedLimit]) -> Void) {
            lock.withLock { onUpdate = handler }
        }

        func needsFetch(now: Date) -> Bool {
            lock.withLock { now >= nextFetch }
        }

        func beginRequest(owner: Int?) -> Int? {
            lock.withLock {
                guard owner == self.owner else { return nil }
                requestID += 1
                return requestID
            }
        }

        func activateOwner(_ owner: Int) {
            lock.withLock {
                requestID += 1
                self.owner = owner
            }
        }

        func invalidateRequests() {
            lock.withLock {
                requestID += 1
                owner = nil
            }
        }

        func isCurrent(_ request: Int) -> Bool {
            lock.withLock { request == requestID }
        }

        /// value 为 nil 表示这一轮没拿到，只记尝试时间。
        func record(_ value: [ScopedLimit]?, now: Date, request: Int) {
            let handler: ((Int, [ScopedLimit]) -> Void)?
            let latest: [ScopedLimit]
            (handler, latest) = lock.withLock {
                guard request == requestID else { return (nil, self.value) }
                nextFetch = now.addingTimeInterval(value == nil ? Self.retryInterval : Self.interval)
                if let value { self.value = value }
                return (onUpdate, self.value)
            }
            if value != nil, let handler { handler(request, latest) }
        }

        var current: [ScopedLimit] { lock.withLock { value } }

        /// 凭据换了人：盒子里那条是上一个账号的，扔掉并立刻重取。
        func reset(owner: Int? = nil) {
            lock.withLock {
                guard owner == self.owner else { return }
                requestID += 1
                value = []
                nextFetch = .distantPast
            }
        }

        /// 手动刷新：不等节流。值留着，取到再换——清掉的话每点一次那行都闪一下。
        func refetchNow() {
            lock.withLock {
                requestID += 1
                nextFetch = .distantPast
            }
        }
    }

    /// 手动刷新是「现在就要真值」：存着的 token 扔掉重读，那条按模型分的窗口不等 10 分钟节流。429 退避不豁免。
    func forceFresh() {
    }

    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        try await fetchSnapshot(now: now, owner: nil)
    }

    func fetchSnapshot(now: Date, owner: Int?) async throws -> UsageSnapshot {
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw UsageError.notFound("没找到 \(root.path)：没装 Claude Code，或 CLAUDE_CONFIG_DIR 指到了别处")
        }
        let files = jsonlFiles(under: root)
        guard !files.isEmpty else { throw UsageError.notFound("还没有 Claude Code 的用量日志，跑一轮就有了") }
        var snapshot = scan.aggregate(files: files, now: now)
        let cache = limits.read(now: now)
        if let accountUUID = cache?.accountUUID,
           let organizationUUID = cache?.organizationUUID,
           let current = currentAccount(),
           accountUUID == current.accountUUID,
           organizationUUID == current.organizationUUID {
            snapshot.sessionLimit = cache?.session.flatMap { $0.isExpired(at: now) ? nil : $0 }
            snapshot.weekLimit = cache?.week.flatMap { $0.isExpired(at: now) ? nil : $0 }
            snapshot.limitsStale = cache?.isStale ?? true
            snapshot.claudeAccountID = accountUUID + "/" + organizationUUID
        } else {
            snapshot.limitsNote = "Claude 配额归属无法确认，请在 Claude Code 查看"
        }
        snapshot.plan = Self.readPlanLabel()
        return snapshot
    }

    private static func currentAccountIdentity() -> (accountUUID: String, organizationUUID: String)? {
        let url = ClaudeHome.globalConfig(ClaudeHome.rawValue)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["oauthAccount"] as? [String: Any],
              let uuid = account["accountUuid"] as? String, !uuid.isEmpty,
              let organization = account["organizationUuid"] as? String, !organization.isEmpty else { return nil }
        return (uuid, organization)
    }

    static func cacheIsFresh(_ cache: ClaudeLimits?) -> Bool {
        cache.map { !$0.isStale } ?? false
    }

    struct ResolvedLimits: Equatable {
        var session: UsageLimit?
        var week: UsageLimit?
        var stale: Bool
        var note: String?
    }

    /// 顺序：缓存新鲜 → 用缓存（`live` 是为那条按模型分的窗口顺带取的，不影响这两条）；
    /// 否则看只读客户端的结果：拿到就用；token 过期时标注并退回陈旧缓存；不可用时退回陈旧缓存，没有就两条都 nil。
    /// 不管哪条路，已过重置时间的窗口都丢掉：隔夜没开 Claude Code，缓存里还是昨天的 92%，那个窗口早就重置了。

    private func jsonlFiles(under dir: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return en.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    /// Reads the subscription plan from the plaintext `oauthAccount` fields in `~/.claude.json`
    /// (not a credential, no token). Prefers `organizationRateLimitTier` (distinguishes Max 5x / 20x),
    /// falling back to `organizationType`. Returns nil if the file is missing or malformed, so the
    /// badge simply does not render — this is best-effort and never fails the snapshot.
    private static func readPlanLabel() -> String? {
        let url = ClaudeHome.globalConfig(ClaudeHome.rawValue)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = obj["oauthAccount"] as? [String: Any] else { return nil }
        // Prefer the rate-limit tier, but fall back to organizationType when it is
        // absent OR blank/whitespace (a present-but-empty string must not short-circuit
        // the fallback). Return nil if neither yields a non-empty label so the badge
        // isn't rendered as an empty capsule.
        let raw = [account["organizationRateLimitTier"], account["organizationType"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let raw else { return nil }
        let label = prettyPlan(raw)
        return label.isEmpty ? nil : label
    }

    /// "default_claude_max_5x" → "Max 5x"; "claude_max" → "Max"; "claude_pro" → "Pro".
    private static func prettyPlan(_ raw: String) -> String {
        var s = raw
        for prefix in ["default_claude_", "claude_", "default_"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
            break
        }
        let parts = s.split(separator: "_").map { seg -> String in
            // Keep multiplier tokens like "5x" / "20x" as-is; capitalize the rest.
            if seg.range(of: "^[0-9]+x$", options: .regularExpression) != nil { return String(seg) }
            return seg.prefix(1).uppercased() + seg.dropFirst()
        }
        return parts.joined(separator: " ")
    }
}

enum UsageError: LocalizedError {
    case notFound(String)
    case notConfigured(String)
    var errorDescription: String? {
        switch self {
        case .notFound(let m), .notConfigured(let m): return m
        }
    }
}
