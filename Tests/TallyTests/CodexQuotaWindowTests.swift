import XCTest
@testable import Tally

final class CodexQuotaWindowTests: XCTestCase {

    private final class StubProtocol: URLProtocol {
        static var requests: [URLRequest] = []
        static var reply: ((URLRequest) -> (Int, String))?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var captured = request
            if captured.httpBody == nil, let stream = request.httpBodyStream {
                stream.open()
                var body = Data()
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    body.append(contentsOf: bytes.prefix(count))
                }
                stream.close()
                captured.httpBody = body
            }
            Self.requests.append(captured)
            let (status, body) = Self.reply?(request) ?? (500, "")
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func client(credentials: @escaping () -> CodexQuotaClient.Credentials? = {
        .init(accessToken: "synthetic-token", accountId: "synthetic-account")
    }) -> CodexQuotaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return CodexQuotaClient(session: URLSession(configuration: configuration), credentialLoader: credentials)
    }

    override func setUp() {
        StubProtocol.requests = []
        StubProtocol.reply = nil
    }

    func testSummaryCountAndFractionalExpiryUseSeparateReads() async {
        StubProtocol.reply = { request in
            if request.url!.path.hasSuffix("/usage") {
                return (200, #"{"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000}},"rate_limit_reset_credits":{"available_count":2}}"#)
            }
            return (200, #"{"available_count":2,"credits":[{"id":"later","status":"available","reset_type":"codex_rate_limits","expires_at":"2099-07-17T00:00:00Z"},{"id":"earlier","status":"available","reset_type":"codex_rate_limits","expires_at":"2099-07-16T00:00:00.123Z"},{"id":"wrong-type","status":"available","reset_type":"other"}]}"#)
        }
        let quota = await client().fetchLimits()
        XCTAssertEqual(quota.session?.used, 20)
        XCTAssertEqual(quota.resetCredits?.availableCount, 2)
        XCTAssertEqual(quota.resetCredits?.cards.count, 2)
        XCTAssertEqual(quota.resetCredits?.nextCard(at: Date())?.id, "earlier")
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }

    func testZeroMissingAndInvalidSummaryAreDistinctAndDoNotHideQuota() async {
        for (field, expected) in [(#""available_count":0"#, 0), ("", -1), (#""available_count":"bad""#, -1), (#""available_count":true"#, -1), (#""available_count":-1"#, -1)] {
            StubProtocol.requests = []
            StubProtocol.reply = { _ in (200, "{\"rate_limit\":{\"primary_window\":{\"used_percent\":15,\"limit_window_seconds\":18000}},\"rate_limit_reset_credits\":{\(field)}}") }
            let quota = await client().fetchLimits()
            XCTAssertEqual(quota.session?.used, 15)
            XCTAssertEqual(quota.resetCredits?.availableCount ?? -1, expected)
            XCTAssertEqual(StubProtocol.requests.count, 1)
        }
    }

    func testMalformedDetailsPreserveSummary() async {
        StubProtocol.reply = { request in
            request.url!.path.hasSuffix("/usage")
                ? (200, #"{"rate_limit_reset_credits":{"available_count":3}}"#)
                : (200, #"{"credits":"bad"}"#)
        }
        let quota = await client().fetchLimits()
        XCTAssertEqual(quota.resetCredits?.availableCount, 3)
        XCTAssertEqual(quota.resetCredits?.detailsNote, "卡片到期时间暂未取得")
        XCTAssertTrue(quota.resetCredits?.cards.isEmpty ?? false)
    }

    func testDetailsCountSupersedesEarlierUsageCountButMalformedCountDoesNot() async {
        for (detailsCount, expected) in [("0", 0), ("true", 2), ("-1", 2), (#""bad""#, 2)] {
            StubProtocol.requests = []
            StubProtocol.reply = { request in
                request.url!.path.hasSuffix("/usage")
                    ? (200, #"{"rate_limit_reset_credits":{"available_count":2}}"#)
                    : (200, "{\"available_count\":\(detailsCount),\"credits\":[]}")
            }
            let quota = await client().fetchLimits()
            XCTAssertEqual(quota.resetCredits?.availableCount, expected)
            XCTAssertEqual(StubProtocol.requests.count, 2)
        }
    }

    func testWrongExpiryTypeDoesNotCreateUsableCard() async {
        StubProtocol.reply = { request in
            request.url!.path.hasSuffix("/usage")
                ? (200, #"{"rate_limit_reset_credits":{"available_count":5}}"#)
                : (200, #"{"credits":[{"id":"number","status":"available","reset_type":"codex_rate_limits","expires_at":123},{"id":"boolean","status":"available","reset_type":"codex_rate_limits","expires_at":true},{"id":"object","status":"available","reset_type":"codex_rate_limits","expires_at":{}},{"id":"null","status":"available","reset_type":"codex_rate_limits","expires_at":null},{"id":"missing","status":"available","reset_type":"codex_rate_limits"}]}"#)
        }
        let quota = await client().fetchLimits()
        XCTAssertEqual(quota.resetCredits?.availableCount, 5)
        XCTAssertEqual(Set(quota.resetCredits?.cards.map(\.id) ?? []), Set(["null", "missing"]))
    }

    func testConsumeSendsExactlyOneBoundRequestAndParsesOfficialCode() async {
        StubProtocol.reply = { request in
            if request.url!.path.hasSuffix("/usage") { return (200, #"{"rate_limit_reset_credits":{"available_count":1}}"#) }
            if request.httpMethod == "GET" { return (200, #"{"credits":[{"id":"card-1","status":"available","reset_type":"codex_rate_limits","expires_at":"2099-07-17T00:00:00Z"}]}"#) }
            return (200, #"{"code":"reset","windows_reset":2}"#)
        }
        let client = client()
        let quota = await client.fetchLimits()
        let credits = try! XCTUnwrap(quota.resetCredits)
        let card = try! XCTUnwrap(credits.cards.first)
        let id = UUID().uuidString
        let result = await client.consumeResetCredit(credits: credits, card: card, requestID: id, now: Date())
        XCTAssertEqual(result, .reset(windows: 2))
        let posts = StubProtocol.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.url?.path, "/backend-api/wham/rate-limit-reset-credits/consume")
        XCTAssertEqual(posts.first?.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "synthetic-account")
        let body = try! XCTUnwrap(posts.first?.httpBody)
        let json = try! XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["redeem_request_id": id, "credit_id": "card-1"])
    }

    func testChangedAccountRejectsBeforePostAndUnknownResponseIsNotRetried() async {
        StubProtocol.reply = { request in
            if request.url!.path.hasSuffix("/usage") { return (200, #"{"rate_limit_reset_credits":{"available_count":1}}"#) }
            if request.httpMethod == "GET" { return (200, #"{"credits":[{"id":"card-1","status":"available","reset_type":"codex_rate_limits"}]}"#) }
            return (500, "")
        }
        var account = "synthetic-account"
        let client = client { .init(accessToken: "synthetic-token", accountId: account) }
        let quota = await client.fetchLimits()
        let credits = try! XCTUnwrap(quota.resetCredits)
        let card = try! XCTUnwrap(credits.cards.first)
        account = "other-account"
        let rejected = await client.consumeResetCredit(credits: credits, card: card, requestID: UUID().uuidString, now: Date())
        if case .rejected = rejected {} else { XCTFail("Account change must reject") }
        XCTAssertEqual(StubProtocol.requests.filter { $0.httpMethod == "POST" }.count, 0)
        account = "synthetic-account"
        let unknown = await client.consumeResetCredit(credits: credits, card: card, requestID: UUID().uuidString, now: Date())
        XCTAssertEqual(unknown, .unknown)
        XCTAssertEqual(StubProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testUndocumentedClientErrorsRemainUnknownButAuthIsRejected() async {
        for (status, isUnknown) in [(400, true), (409, true), (429, true), (401, false), (403, false)] {
            StubProtocol.requests = []
            StubProtocol.reply = { request in
                if request.url!.path.hasSuffix("/usage") { return (200, #"{"rate_limit_reset_credits":{"available_count":1}}"#) }
                if request.httpMethod == "GET" { return (200, #"{"credits":[{"id":"card-1","status":"available","reset_type":"codex_rate_limits"}]}"#) }
                return (status, "")
            }
            let client = client()
            let quota = await client.fetchLimits()
            let credits = try! XCTUnwrap(quota.resetCredits)
            let card = try! XCTUnwrap(credits.cards.first)
            let outcome = await client.consumeResetCredit(credits: credits, card: card, requestID: UUID().uuidString, now: Date())
            if isUnknown { XCTAssertEqual(outcome, .unknown) }
            else if case .rejected = outcome {} else { XCTFail("Authentication failure must be rejected") }
            XCTAssertEqual(StubProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
        }
    }

    @MainActor
    func testStoreCoalescesDoubleConfirmationAndRefetchesAfterReset() async throws {
        let root = try makeEmptySessionsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        StubProtocol.reply = { request in
            if request.url!.path.hasSuffix("/usage") { return (200, #"{"rate_limit_reset_credits":{"available_count":1}}"#) }
            if request.httpMethod == "GET" { return (200, #"{"credits":[{"id":"card-1","status":"available","reset_type":"codex_rate_limits"}]}"#) }
            return (200, #"{"code":"reset","windows_reset":1}"#)
        }
        let store = UsageStore(providers: [CodexUsageProvider(root: root, quotaClient: client(), scan: UsageScanCache())],
                               preferences: { Preferences() }, hasLiveSession: { false })
        store.providersChanged()
        let refreshed = await store.refreshAndWait(reason: .manual)
        XCTAssertTrue(refreshed)
        let confirmation = try storeConfirmation(store)
        async let first: Void = store.consumeCodexResetCredit(confirmation)
        async let second: Void = store.consumeCodexResetCredit(confirmation)
        _ = await (first, second)
        XCTAssertEqual(StubProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertEqual(StubProtocol.requests.filter { $0.url?.path.hasSuffix("/usage") == true }.count, 2)
        XCTAssertFalse(store.isUsingCodexResetCredit)
    }

    @MainActor
    func testStoreUnknownResultDoesNotRetryAndKeepsFeedback() async throws {
        let root = try makeEmptySessionsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferencesURL = root.appendingPathComponent("preferences.json")
        StubProtocol.reply = { request in
            if request.url!.path.hasSuffix("/usage") { return (200, #"{"rate_limit_reset_credits":{"available_count":1}}"#) }
            if request.httpMethod == "GET" { return (200, #"{"credits":[{"id":"card-1","status":"available","reset_type":"codex_rate_limits"}]}"#) }
            return (500, "")
        }
        let settings = PreferencesStore(url: preferencesURL)
        let store = UsageStore(providers: [CodexUsageProvider(root: root, quotaClient: client(), scan: UsageScanCache())],
                               preferences: { Preferences() }, hasLiveSession: { false }, resetPreferences: settings)
        store.providersChanged()
        let refreshed = await store.refreshAndWait(reason: .manual)
        XCTAssertTrue(refreshed)
        await store.consumeCodexResetCredit(try storeConfirmation(store))
        XCTAssertEqual(StubProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertTrue(store.codexResetNeedsReview)
        XCTAssertEqual(StubProtocol.requests.filter { $0.url?.path.hasSuffix("/usage") == true }.count, 2)
        XCTAssertTrue(store.codexResetFeedback?.contains("结果待确认") == true)
        // 服务端可能已扣卡但只读接口仍返回旧卡；新确认编号不能成为第二次兑换。
        await store.consumeCodexResetCredit(try storeConfirmation(store))
        XCTAssertEqual(StubProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
        let reloaded = PreferencesStore(url: preferencesURL)
        XCTAssertNotNil(reloaded.prefs.pendingCodexResetRequestID)
        let restarted = UsageStore(providers: [CodexUsageProvider(root: root, quotaClient: client(), scan: UsageScanCache())],
                                   preferences: { Preferences() }, hasLiveSession: { false }, resetPreferences: reloaded)
        restarted.providersChanged()
        _ = await restarted.refreshAndWait(reason: .manual)
        XCTAssertTrue(restarted.codexResetNeedsReview)
        await restarted.consumeCodexResetCredit(try storeConfirmation(restarted))
        XCTAssertEqual(StubProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
        await restarted.acknowledgeCodexResetOutcome()
        XCTAssertFalse(restarted.codexResetNeedsReview)
        XCTAssertEqual(StubProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    @MainActor
    func testPendingMarkerSaveFailurePreventsPost() async throws {
        let root = try makeEmptySessionsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        let settings = PreferencesStore(url: blocker.appendingPathComponent("preferences.json"))
        StubProtocol.reply = { request in
            if request.url!.path.hasSuffix("/usage") { return (200, #"{"rate_limit_reset_credits":{"available_count":1}}"#) }
            if request.httpMethod == "GET" { return (200, #"{"credits":[{"id":"card-1","status":"available","reset_type":"codex_rate_limits"}]}"#) }
            return (200, #"{"code":"reset"}"#)
        }
        let store = UsageStore(providers: [CodexUsageProvider(root: root, quotaClient: client(), scan: UsageScanCache())],
                               preferences: { Preferences() }, hasLiveSession: { false }, resetPreferences: settings)
        store.providersChanged()
        _ = await store.refreshAndWait(reason: .manual)
        await store.consumeCodexResetCredit(try storeConfirmation(store))
        XCTAssertNotNil(settings.saveError)
        XCTAssertTrue(store.codexResetFeedback?.contains("未发送") == true)
        XCTAssertEqual(StubProtocol.requests.filter { $0.httpMethod == "POST" }.count, 0)
    }

    private func makeEmptySessionsDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tally-codex-cards-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("empty.jsonl"))
        return root
    }

    @MainActor
    private func storeConfirmation(_ store: UsageStore) throws -> CodexResetCredits.Confirmation {
        guard case .success(let snapshot)? = store.results[.codex],
              let credits = snapshot.codexResetCredits,
              let card = credits.nextCard(at: Date()) else {
            throw NSError(domain: "CodexQuotaWindowTests", code: 1)
        }
        return .init(id: UUID(), credits: credits, card: card)
    }

    private func limit(_ used: Double) -> UsageLimit { UsageLimit(used: used, limit: 100) }

    func testSingleWeeklyWindowGoesToWeekSlot() {
        // 本机账号实测：只有一个 604800 秒的 primary_window
        let r = CodexQuotaClient.assign(windows: [(seconds: 604_800, limit: limit(33))])
        XCTAssertNil(r.session)
        XCTAssertEqual(r.week?.used, 33)
    }

    func testFiveHourAndWeeklyWindowsBothAssigned() {
        let r = CodexQuotaClient.assign(windows: [(seconds: 18_000, limit: limit(10)), (seconds: 604_800, limit: limit(40))])
        XCTAssertEqual(r.session?.used, 10)
        XCTAssertEqual(r.week?.used, 40)
    }

    func testMissingLengthFallsBackToPosition() {
        let r = CodexQuotaClient.assign(windows: [(seconds: nil, limit: limit(1)), (seconds: nil, limit: limit(2))])
        XCTAssertEqual(r.session?.used, 1)
        XCTAssertEqual(r.week?.used, 2)
    }

    func testTwoWindowsInSameSlotKeepFirst() {
        let r = CodexQuotaClient.assign(windows: [(seconds: 604_800, limit: limit(5)), (seconds: 2_592_000, limit: limit(9))])
        XCTAssertNil(r.session)
        XCTAssertEqual(r.week?.used, 5)
    }

    /// 登录过期（access_token 有效期 10 天）时界面要说人话，不能只是静默少两条配额。
    func testAuthFailureGetsNote() {
        XCTAssertEqual(CodexQuotaClient.authNote(status: 401), "登录已过期，去 Codex 跑一轮")
        XCTAssertEqual(CodexQuotaClient.authNote(status: 403), "登录已过期，去 Codex 跑一轮")
    }

    /// 网络断、5xx、响应变形不是用户能动手解决的，不写提示，只留日志。
    func testNonAuthFailureGetsNoNote() {
        XCTAssertNil(CodexQuotaClient.authNote(status: 500))
        XCTAssertNil(CodexQuotaClient.authNote(status: 200))
        XCTAssertNil(CodexQuotaClient.authNote(status: -1))
    }
}
