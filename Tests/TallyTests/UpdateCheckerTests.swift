import XCTest
@testable import Tally

private final class PendingReleaseProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [PendingReleaseProtocol] = []
    static var count: Int { lock.withLock { requests.count } }
    static func reset() { lock.withLock { requests = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.requests.append(self) } }
    override func stopLoading() {}

    static func complete(_ index: Int, version: String? = nil) {
        let instance = lock.withLock { requests[index] }
        if let version {
            let response = HTTPURLResponse(url: instance.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            instance.client?.urlProtocol(instance, didReceive: response, cacheStoragePolicy: .notAllowed)
            let body = Data(#"{"tag_name":"v\#(version)","html_url":"https://example.invalid/release"}"#.utf8)
            instance.client?.urlProtocol(instance, didLoad: body)
            instance.client?.urlProtocolDidFinishLoading(instance)
        } else {
            instance.client?.urlProtocol(instance, didFailWithError: URLError(.cannotConnectToHost))
        }
    }
}

/// 新版本提示（docs/hooks.md「发版与更新」）。
final class UpdateCheckerTests: XCTestCase {

    @MainActor
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw NSError(domain: "Timed out waiting for update request", code: 1)
    }

    @MainActor
    func testDisableInvalidatesLateSuccessAndAllowsReenable() async throws {
        PendingReleaseProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PendingReleaseProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let checker = UpdateChecker(session: session, currentVersion: "1.0.0")
        var notified: [String] = []
        checker.onNewVersion = { notified.append($0.version) }
        checker.setEnabled(true)
        try await waitFor { PendingReleaseProtocol.count == 1 }
        checker.setEnabled(false)
        XCTAssertFalse(checker.checking)
        checker.setEnabled(true)
        try await waitFor { PendingReleaseProtocol.count == 2 }
        PendingReleaseProtocol.complete(1, version: "3.0.0")
        try await waitFor { checker.available?.version == "3.0.0" }
        PendingReleaseProtocol.complete(0, version: "2.0.0")
        try await waitFor { !checker.checking }
        XCTAssertEqual(checker.available?.version, "3.0.0")
        XCTAssertEqual(notified, ["3.0.0"])
        checker.setEnabled(false)
    }

    @MainActor
    func testDisableInvalidatesLateError() async throws {
        PendingReleaseProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PendingReleaseProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let checker = UpdateChecker(session: session, currentVersion: "1.0.0")
        let request = Task { await checker.check() }
        try await waitFor { PendingReleaseProtocol.count == 1 }
        checker.setEnabled(false)
        PendingReleaseProtocol.complete(0)
        await request.value
        XCTAssertNil(checker.problem)
        XCTAssertNil(checker.lastChecked)
        XCTAssertFalse(checker.checking)
    }

    @MainActor
    func testDisableInvalidatesLateSuccess() async throws {
        PendingReleaseProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PendingReleaseProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let checker = UpdateChecker(session: session, currentVersion: "1.0.0")
        var notifications = 0
        checker.onNewVersion = { _ in notifications += 1 }
        let request = Task { await checker.check() }
        try await waitFor { PendingReleaseProtocol.count == 1 }
        checker.setEnabled(false)
        PendingReleaseProtocol.complete(0, version: "2.0.0")
        await request.value
        XCTAssertNil(checker.available)
        XCTAssertNil(checker.lastChecked)
        XCTAssertEqual(notifications, 0)
        XCTAssertFalse(checker.checking)
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("v1.0.1", than: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.10", than: "1.9"), "按整数比，不按字符串")
        XCTAssertTrue(UpdateChecker.isNewer("v2.0.0-beta", than: "1.0"), "后缀去掉再比")
        XCTAssertFalse(UpdateChecker.isNewer("v1.0.0", than: "1.0"), "补零后一样不算新")
        XCTAssertFalse(UpdateChecker.isNewer("0.9.9", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("nightly", than: "1.0.0"), "认不出的版本号不提示")
        XCTAssertFalse(UpdateChecker.isNewer("1..2", than: "1.0.0"))
    }

    func testParsesLatestRelease() throws {
        let json = #"{"tag_name":"v1.2.0","html_url":"https://github.com/guokuaile/tally/releases/tag/v1.2.0","assets":[]}"#
        let release = try XCTUnwrap(UpdateChecker.parse(Data(json.utf8)))
        XCTAssertEqual(release.version, "1.2.0")
        XCTAssertEqual(release.page.absoluteString, "https://github.com/guokuaile/tally/releases/tag/v1.2.0")
        XCTAssertNil(UpdateChecker.parse(Data(#"{"message":"Not Found"}"#.utf8)))
        XCTAssertNil(UpdateChecker.parse(Data(#"{"tag_name":"latest","html_url":"https://x"}"#.utf8)))
    }

    func testHomebrewDetection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tally-caskroom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(UpdateChecker.installedByHomebrew(caskrooms: ["/nonexistent", dir.path]))
        XCTAssertFalse(UpdateChecker.installedByHomebrew(caskrooms: ["/nonexistent"]))
    }

    func testUpdatePeek() {
        let peek = Peek.update("1.2.0")
        XCTAssertEqual(peek.style, .update)
        XCTAssertEqual(peek.title, "Tally 1.2.0")
        XCTAssertNil(peek.sessionId, "不可点")
        XCTAssertEqual(peek.id, Peek.update("1.2.0").id, "同一个版本同一个 id")
    }
}
