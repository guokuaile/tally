import Foundation

/// Claude 配额的只读客户端：拿 Claude Code 的 OAuth access token 查官方 usage 接口。
///
/// 底线：只读 accessToken 与 expiresAt，不碰刷新用的那个 token，不调刷新接口，401 也不调，
/// 不重试，不往凭据文件或钥匙串写一个字节。分享版没有 statusline 缓存时靠它。
///
/// token 读到就存在 `TokenBox` 里，不每轮都起一次 `security`；凭据被改写（切账号、重新登录、8 小时一次的刷新）才重读：
/// 切账号不会让旧账号的 token 过期，只等过期或 401 的话，切号之后查的一直是上一个账号，怎么刷新都不变。
enum ClaudeQuotaResult: Equatable {
    case limits(ClaudeLimits)
    case tokenExpired
    case unavailable
}

struct ClaudeQuotaReadOnly {

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    let session: URLSession
    let credentialsFile: URL
    let keychainItem: () -> String?
    /// 引用类型：这个 struct 被 provider 存着复制来复制去，缓存挂在盒子里才留得住。
    let tokenBox: TokenBox
    /// 凭据最后一次被改写的时刻，只看属性不取值；测试注入假的。
    let credentialStamp: () -> Date?
    /// 429 之后按接口退避；真 app 传落盘的 `QuotaBackoff.shared`。
    let backoff: QuotaBackoff
    static let backoffKey = "claude-oauth-usage"

    init(session: URLSession = .shared,
         credentialsFile: URL = ClaudeHome.url.appendingPathComponent(".credentials.json"),
         // 没设 CLAUDE_CONFIG_DIR 时按前缀挑最新的那条（老行为）；设了就是带哈希后缀的那一条，不会拿到别的账号
         keychainItem: @escaping () -> String? = { KeychainReader.freshestGenericPassword(servicePrefix: ClaudeHome.keychainService(ClaudeHome.rawValue))?.secret },
         tokenBox: TokenBox = TokenBox(),
         credentialStamp: (() -> Date?)? = nil,
         backoff: QuotaBackoff = QuotaBackoff()) {
        self.session = session
        self.credentialsFile = credentialsFile
        self.keychainItem = keychainItem
        self.tokenBox = tokenBox
        self.credentialStamp = credentialStamp ?? { Self.liveCredentialStamp(file: credentialsFile) }
        self.backoff = backoff
    }

    /// 凭据文件的 mtime 与钥匙串那条项的修改时间取晚的。不盯 `~/.claude.json` 的 accountUuid：
    /// `/login` 先后写两处，卡在中间读会把旧 token 再存一遍。
    static func liveCredentialStamp(file: URL) -> Date? {
        let fileDate = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        let keychainDate = KeychainReader.freshestGenericPasswordItem(servicePrefix: ClaudeHome.keychainService(ClaudeHome.rawValue))?.modified
        return [fileDate, keychainDate].compactMap { $0 }.max()
    }

    /// 存住已经读到的 token。读失败（文件没有、钥匙串被拒）也记一笔，10 分钟内不再读，
    /// 否则用户点一次「取消」之后每轮刷新都会再弹一个框。
    final class TokenBox: @unchecked Sendable {
        static let retryInterval: TimeInterval = 600

        private let lock = NSLock()
        private var token: Token?
        private var lastRead: Date = .distantPast
        /// 存着的 token 是凭据在哪个时刻的样子。
        private var stamp: Date?

        init() {}

        /// 凭据的改写时刻和记着的不一样：记下新的，扔掉 token，读失败的冷却也作废（刚登录完不该再等十分钟）。返回 true 表示刚扔。
        /// nil 是这一次没看到（钥匙串查询偶发失败、已退出登录），不是「变了」：当成变了会白扔一次 token、那条周窗口闪一下；
        /// 退出登录的 token 自己会过期或吃 401。
        func adopt(stamp: Date?) -> Bool {
            lock.withLock {
                guard let stamp, stamp != self.stamp else { return false }
                self.stamp = stamp
                token = nil
                lastRead = .distantPast
                return true
            }
        }

        /// 手动刷新：扔掉重读，不等冷却。
        func reset() {
            lock.withLock {
                token = nil
                lastRead = .distantPast
            }
        }

        func cached() -> Token? { lock.withLock { token } }

        func shouldRead(now: Date) -> Bool {
            lock.withLock { token == nil && now.timeIntervalSince(lastRead) > Self.retryInterval }
        }

        /// `stamp` 是开始读之前看到的改写时刻。读到一半别的一轮认出凭据换了（记着的时刻已经往前走），手里这份可能是上一个账号的，不存：
        /// 存了的话时刻对得上、token 却是旧的，之后再也不会触发重读。返回 false 表示没存。
        func store(_ token: Token?, readUnder stamp: Date?, now: Date) -> Bool {
            lock.withLock {
                guard stamp == nil || stamp == self.stamp else { return false }
                self.token = token
                lastRead = now
                return true
            }
        }

        /// token 过期或被接口拒了：扔掉，下次重新读一次，用户重新登录后才拿得到新的。
        func clear() {
            lock.withLock { token = nil }
        }
    }

    struct Token: Equatable {
        let accessToken: String
        /// 毫秒时间戳，可能没有。
        let expiresAt: Double?

        func isExpired(at now: Date) -> Bool { expiresAt.map { $0 / 1000 <= now.timeIntervalSince1970 } ?? false }
    }

    /// 凭据文件里没过期的 token 优先，没有或已过期就问钥匙串；钥匙串也没有时交回文件里那个（过期的），好让界面说「登录已过期」。
    /// 存住的 token 直接用；过期了才扔掉重读（那时用户多半已经重新登录，钥匙串里是新的）。
    func loadToken(now: Date = .now) -> Token? {
        let stamp = credentialStamp()
        _ = tokenBox.adopt(stamp: stamp)
        if let token = tokenBox.cached() {
            guard token.isExpired(at: now) else { return token }
            tokenBox.clear()
        }
        guard tokenBox.shouldRead(now: now) else { return nil }
        let token = readToken(now: now)
        return tokenBox.store(token, readUnder: stamp, now: now) ? token : nil
    }

    /// 凭据被改写过就扔掉存着的 token。返回 true 表示刚扔：提供方拿它清掉上一个账号的周窗口。
    @discardableResult
    func dropTokenIfCredentialsChanged() -> Bool {
        tokenBox.adopt(stamp: credentialStamp())
    }

    private func readToken(now: Date) -> Token? {
        let file = (try? Data(contentsOf: credentialsFile)).flatMap(Self.parseToken)
        // 新版 Claude Code 只写钥匙串，残留的旧文件里是早过期的 token；先认它的话钥匙串里的新 token 永远轮不到
        if let file, !file.isExpired(at: now) { return file }
        if let secret = keychainItem(), let token = Self.parseToken(Data(secret.utf8)) { return token }
        return file
    }

    static func parseToken(_ data: Data) -> Token? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.isEmpty
        else { return nil }
        return Token(accessToken: access, expiresAt: (oauth["expiresAt"] as? NSNumber)?.doubleValue)
    }

    func fetch(now: Date = .now) async -> ClaudeQuotaResult {
        guard let token = loadToken(now: now) else { return .unavailable }
        if token.isExpired(at: now) {
            tokenBox.clear()
            return .tokenExpired
        }
        // 429 退避期间不打接口：接着撞只会把退避越拉越长
        guard backoff.allows(Self.backoffKey, now: now) else { return .unavailable }
        var request = URLRequest(url: Self.usageURL)
        // 默认超时 60 秒：代理抽风时整行「加载中」要卡一分钟，用量不值得等这么久
        request.timeoutInterval = 10
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            if http.statusCode == 401 {
                // 接口说这个 token 不认：扔掉，下次重读（用户重新登录后钥匙串里是新的）
                tokenBox.clear()
                return .tokenExpired
            }
            if http.statusCode == 429 {
                backoff.throttled(Self.backoffKey, now: now, retryAfter: QuotaBackoff.retryAfter(http))
                return .unavailable
            }
            guard (200..<300).contains(http.statusCode) else { return .unavailable }
            backoff.succeeded(Self.backoffKey)
            return Self.parseUsage(data).map { .limits($0) } ?? .unavailable
        } catch {
            return .unavailable
        }
    }

    /// `{"five_hour":{"utilization":23.5,"resets_at":"…"},"seven_day":{…},"limits":[…]}`，utilization 是 0 到 100 的百分数。
    static func parseUsage(_ data: Data) -> ClaudeLimits? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let session = limit(from: object["five_hour"])
        let week = limit(from: object["seven_day"])
        let scoped = scopedLimits(from: object)
        guard session != nil || week != nil || !scoped.isEmpty else { return nil }
        return ClaudeLimits(session: session, week: week, scoped: scoped, isStale: false)
    }

    /// 按模型分的周窗口在 `limits` 数组里：`kind == "weekly_scoped"`，名字在 `scope.model.display_name`（如「Fable」）。
    /// 顶层那几个 `seven_day_opus` / `seven_day_sonnet` 现在恒为 null，别读它们。
    static func scopedLimits(from object: [String: Any]) -> [ScopedLimit] {
        guard let rows = object["limits"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard row["kind"] as? String == "weekly_scoped",
                  let percent = (row["percent"] as? NSNumber)?.doubleValue,
                  let scope = row["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String, !name.isEmpty
            else { return nil }
            return ScopedLimit(label: name,
                               limit: UsageLimit(used: percent, limit: 100, resetsAt: (row["resets_at"] as? String).flatMap(parseDate)))
        }
    }

    private static func limit(from raw: Any?) -> UsageLimit? {
        guard let window = raw as? [String: Any], let used = (window["utilization"] as? NSNumber)?.doubleValue else { return nil }
        return UsageLimit(used: used, limit: 100, resetsAt: (window["resets_at"] as? String).flatMap(parseDate))
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ text: String) -> Date? {
        isoWithFraction.date(from: text) ?? isoPlain.date(from: text)
    }
}
