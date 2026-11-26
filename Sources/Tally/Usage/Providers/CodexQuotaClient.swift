// 移植自 Atoll（https://github.com/Ebullioscopic/Atoll），Copyright (C) 2024-2026 Atoll Contributors，GPL-3.0，见仓库 LICENSE 与 NOTICE。
// Tally 改动：按窗口长度分槽；认证失败带提示；10 秒超时与独立 429 退避；只读重置卡汇总和明细、确认后单次兑换（docs/ai.md「Codex 重置卡」）。
import Foundation
import CryptoKit
import os

// Codex/ChatGPT rate-limit usage from chatgpt.com/backend-api/wham/usage; request+response shape per OpenUsage.
struct CodexQuotaClient {
    private static let log = os.Logger(subsystem: "com.aiden.tally", category: "CodexQuota")
    static let backoffKey = "codex-wham-usage"
    static let detailsBackoffKey = "codex-wham-reset-credits"
    let session: URLSession
    /// 429 之后按接口退避；真 app 传落盘的 `QuotaBackoff.shared`。
    let backoff: QuotaBackoff
    struct Credentials {
        let accessToken: String
        let accountId: String?
    }
    enum ResetOutcome: Equatable {
        case reset(windows: Int)
        case nothingToReset
        case noCredit
        case alreadyRedeemed
        case rejected(String)
        case unknown
    }
    private let credentialLoader: (() -> Credentials?)?
    private let noRedirects = NoRedirects()
    init(session: URLSession = URLSession(configuration: .ephemeral), backoff: QuotaBackoff = QuotaBackoff(), credentialLoader: (() -> Credentials?)? = nil) {
        self.session = session
        self.backoff = backoff
        self.credentialLoader = credentialLoader
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private struct AuthFile: Decodable {
        struct Tokens: Decodable {
            let accessToken: String
            let accountId: String?
        }
        let tokens: Tokens
    }

    private struct RateLimitWindow: Decodable {
        let usedPercent: Double
        let limitWindowSeconds: Double?
        let resetAt: Double?
        let resetAfterSeconds: Double?
    }

    private struct RateLimit: Decodable {
        let primaryWindow: RateLimitWindow?
        let secondaryWindow: RateLimitWindow?
    }

    private struct UsageResponse: Decodable {
        let rateLimit: RateLimit?
    }

    // Never throws: any credential/network/parse failure yields (nil, nil, note).
    struct Quota {
        let session: UsageLimit?
        let week: UsageLimit?
        let note: String?
        let resetCredits: CodexResetCredits?
    }

    func fetchLimits() async -> Quota {
        guard let creds = loadCredentials() else {
            Self.log.notice("no credentials: auth.json/Keychain missing or unparseable")
            return Quota(session: nil, week: nil, note: nil, resetCredits: nil)
        }
        // 429 退避期间不打接口
        guard backoff.allows(Self.backoffKey, now: Date()) else { return Quota(session: nil, week: nil, note: nil, resetCredits: nil) }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        // 默认 60 秒：代理卡住时这一行要「加载中」一分钟，和 Claude 那边一样钉 10 秒
        request.timeoutInterval = 10
        authorize(&request, credentials: creds)
        do {
            let (data, response) = try await session.data(for: request, delegate: noRedirects)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                if code == 429, let http = response as? HTTPURLResponse {
                    backoff.throttled(Self.backoffKey, now: Date(), retryAfter: QuotaBackoff.retryAfter(http))
                }
                Self.log.error("wham/usage HTTP \(code) — \(code == 401 || code == 403 ? "auth/credential" : "request") failure")
                return Quota(session: nil, week: nil, note: Self.authNote(status: code), resetCredits: nil)
            }
            backoff.succeeded(Self.backoffKey)
            let now = Date()
            let resetCredits = await creditsSummary(from: data, credentials: creds, now: now)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            if let decoded = try? decoder.decode(UsageResponse.self, from: data) {
                let windows = [decoded.rateLimit?.primaryWindow, decoded.rateLimit?.secondaryWindow]
                    .compactMap { $0 }
                    .map { (seconds: $0.limitWindowSeconds, limit: limit(from: $0, now: now)) }
                let assigned = Self.assign(windows: windows)
                if assigned.session != nil || assigned.week != nil { return Quota(session: assigned.session, week: assigned.week, note: nil, resetCredits: resetCredits) }
            }
            // 头部兜底也按窗口长分槽：只有 7 天窗口的账号，primary 就是那个 7 天窗口，按次序硬套又会贴成「5 小时」
            let fallback = Self.assign(windows: ["primary", "secondary"].compactMap { headerWindow(http, name: $0) })
            if fallback.session == nil && fallback.week == nil {
                Self.log.error("wham/usage 200 but no usage found — response shape may have changed (\(data.count) bytes)")
            }
            return Quota(session: fallback.session, week: fallback.week, note: nil, resetCredits: resetCredits)
        } catch {
            Self.log.error("wham/usage request failed")
            return Quota(session: nil, week: nil, note: nil, resetCredits: nil)
        }
    }

    private func creditsSummary(from data: Data, credentials: Credentials, now: Date) async -> CodexResetCredits? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let summary = root["rate_limit_reset_credits"] as? [String: Any],
              let count = Self.validCount(summary["available_count"]) else { return nil }
        var credits = CodexResetCredits(availableCount: count)
        // 账号标识缺失时仍显示次数，但不能把确认绑定到一个无法确认身份的登录。
        if let accountId = credentials.accountId, !accountId.isEmpty, !credentials.accessToken.isEmpty {
            credits.credentialBinding = Self.binding(for: credentials)
        }
        credits.accountLabel = credentials.accountId.map { "Codex 账号 · \(String($0.suffix(8)))" } ?? "当前 Codex 账号"
        credits.fetchedAt = now
        guard credits.availableCount > 0 else { return credits }
        guard backoff.allows(Self.detailsBackoffKey, now: now) else {
            credits.detailsNote = "卡片到期时间暂未取得"
            return credits
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!)
        request.timeoutInterval = 10
        authorize(&request, credentials: credentials)
        do {
            let (data, response) = try await session.data(for: request, delegate: noRedirects)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                if let http = response as? HTTPURLResponse, http.statusCode == 429 {
                    backoff.throttled(Self.detailsBackoffKey, now: Date(), retryAfter: QuotaBackoff.retryAfter(http))
                }
                credits.detailsNote = "卡片到期时间暂未取得"
                return credits
            }
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                credits.detailsNote = "卡片到期时间暂未取得"
                return credits
            }
            if let count = Self.validCount(root["available_count"]) { credits.availableCount = count }
            guard let items = root["credits"] as? [[String: Any]] else {
                credits.detailsNote = "卡片到期时间暂未取得"
                return credits
            }
            backoff.succeeded(Self.detailsBackoffKey)
            credits.cards = items.compactMap { item in
                guard item["status"] as? String == "available",
                      item["reset_type"] as? String == "codex_rate_limits",
                      let id = item["id"] as? String, !id.isEmpty else { return nil }
                let expiry: Date?
                if let raw = item["expires_at"] as? String {
                    guard let parsed = Self.parseDate(raw) else { return nil }
                    expiry = parsed
                } else if let value = item["expires_at"], !(value is NSNull) {
                    return nil
                } else { expiry = nil }
                guard expiry.map({ $0 > now }) ?? true else { return nil }
                return CodexResetCredits.Card(id: id, expiresAt: expiry)
            }
            credits.expiresAt = credits.cards.compactMap(\.expiresAt).sorted()
            return credits
        } catch {
            credits.detailsNote = "卡片到期时间暂未取得"
            return credits
        }
    }

    private static func validCount(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.intValue >= 0, number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }

    func consumeResetCredit(credits: CodexResetCredits, card: CodexResetCredits.Card, requestID: String, now: Date) async -> ResetOutcome {
        guard UUID(uuidString: requestID) != nil,
              credits.availableCount > 0,
              credits.cards.contains(where: { $0.id == card.id && $0.expiresAt == card.expiresAt }),
              !card.id.isEmpty, card.expiresAt.map({ $0 > now }) ?? true,
              now.timeIntervalSince(credits.fetchedAt) >= 0,
              now.timeIntervalSince(credits.fetchedAt) < 300,
              !credits.credentialBinding.isEmpty,
              let credentials = loadCredentials(),
              let accountId = credentials.accountId, !accountId.isEmpty, !credentials.accessToken.isEmpty,
              Self.binding(for: credentials) == credits.credentialBinding else {
            return .rejected("卡片或登录状态已改变，请刷新后重试")
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        authorize(&request, credentials: credentials)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["redeem_request_id": requestID, "credit_id": card.id])
        guard request.httpBody != nil else { return .rejected("请求参数无效") }
        do {
            let (data, response) = try await session.data(for: request, delegate: noRedirects)
            guard let http = response as? HTTPURLResponse else { return .unknown }
            // 只有登录失效能断定没有兑换；其他 4xx 的服务端语义未核实，保留待核对状态。
            if http.statusCode == 401 || http.statusCode == 403 { return .rejected("Codex 登录已过期，请重新登录后刷新") }
            guard (200..<300).contains(http.statusCode),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let code = root["code"] as? String else { return .unknown }
            switch code {
            case "reset":
                let windows = root["windows_reset"] as? Int ?? 0
                return .reset(windows: windows)
            case "nothing_to_reset": return .nothingToReset
            case "no_credit": return .noCredit
            case "already_redeemed": return .alreadyRedeemed
            default: return .unknown
            }
        } catch { return .unknown }
    }

    private func authorize(_ request: inout URLRequest, credentials: Credentials) {
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tally", forHTTPHeaderField: "User-Agent")
        if let accountId = credentials.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
    }

    private static func binding(for credentials: Credentials) -> String {
        let data = Data((credentials.accessToken + "\0" + (credentials.accountId ?? "")).utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    /// 401 / 403 是凭据问题，界面要说人话（Codex 的 access_token 有效期 10 天，Tally 只读不刷新）。
    /// 网络断、5xx、响应变形不写提示：那些不是用户能动手解决的，跟 Claude 侧一致只留日志。
    static func authNote(status: Int) -> String? {
        (status == 401 || status == 403) ? "登录已过期，去 Codex 跑一轮" : nil
    }

    /// 按窗口长度分槽：不到 24 小时的进 session（界面标「5 小时」），24 小时以上的进 week（标「7 天」）。
    /// 实测本机账号只有一个 604800 秒的 primary_window，按次序硬套会把周配额贴成 5 小时。
    /// 长度缺失时沿用原次序：第一个进 session，第二个进 week。同槽出现两个时保留第一个。
    static func assign(windows: [(seconds: Double?, limit: UsageLimit)]) -> (session: UsageLimit?, week: UsageLimit?) {
        var session: UsageLimit?
        var week: UsageLimit?
        for (index, window) in windows.enumerated() {
            let isWeek = window.seconds.map { $0 >= 24 * 3600 } ?? (index == 1)
            if isWeek {
                if week == nil { week = window.limit }
            } else if session == nil {
                session = window.limit
            }
        }
        return (session, week)
    }

    private func limit(from window: RateLimitWindow, now: Date) -> UsageLimit {
        let resets = window.resetAt.map { Date(timeIntervalSince1970: $0) } ?? window.resetAfterSeconds.map { now.addingTimeInterval($0) }
        return UsageLimit(used: window.usedPercent, limit: 100, resetsAt: resets)
    }

    private func headerWindow(_ http: HTTPURLResponse, name: String) -> (seconds: Double?, limit: UsageLimit)? {
        guard let raw = http.value(forHTTPHeaderField: "x-codex-\(name)-used-percent"), let percent = Double(raw) else { return nil }
        let minutes = http.value(forHTTPHeaderField: "x-codex-\(name)-window-minutes").flatMap(Double.init)
        return (minutes.map { $0 * 60 }, UsageLimit(used: percent, limit: 100))
    }

    // auth.json ($CODEX_HOME, ~/.codex, ~/.config/codex), then Keychain "Codex Auth" holding the same JSON payload.
    private func loadCredentials() -> Credentials? {
        if let credentialLoader { return credentialLoader() }
        for path in authPaths() {
            if let data = try? Data(contentsOf: path), let creds = parseAuth(data) { return creds }
        }
        guard let value = KeychainReader.genericPassword(service: "Codex Auth"),
              let creds = parseAuth(Data(value.utf8)) else { return nil }
        return creds
    }

    private func authPaths() -> [URL] {
        // Tally 改动：家目录统一由 CodexHome 定（问过登录 shell 的 CODEX_HOME），app 自己的环境里没有那个变量
        return [
            CodexHome.url.appendingPathComponent("auth.json"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/codex/auth.json"),
        ]
    }

    private func parseAuth(_ data: Data) -> Credentials? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let parsed = try? decoder.decode(AuthFile.self, from: data) else { return nil }
        return Credentials(accessToken: parsed.tokens.accessToken, accountId: parsed.tokens.accountId)
    }
}
