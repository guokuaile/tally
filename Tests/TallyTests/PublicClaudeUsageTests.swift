import XCTest
@testable import Tally

final class PublicClaudeUsageTests: XCTestCase {
    private func provider(cache: String, identity: (String, String)?) throws -> ClaudeUsageProvider {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-public-claude-\(UUID().uuidString)")
        let project = directory.appendingPathComponent("projects")
        let limits = directory.appendingPathComponent("limits")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: limits, withIntermediateDirectories: true)
        try Data().write(to: project.appendingPathComponent("session.jsonl"))
        try cache.write(to: limits.appendingPathComponent("rate-limits.json"), atomically: true, encoding: .utf8)
        return ClaudeUsageProvider(root: project, limits: ClaudeLimitsCache(directory: limits),
                                   scopedBox: .init(), scan: UsageScanCache(),
                                   currentAccount: { identity.map { ($0.0, $0.1) } })
    }

    func testUnattributedStatuslineCacheDoesNotShowClaudeQuota() async throws {
        let provider = try provider(cache: #"{"five_hour":{"used_percentage":40}}"#, identity: ("A", "org-a"))
        let snapshot = try await provider.fetchSnapshot(now: .now)
        XCTAssertNil(snapshot.sessionLimit)
        XCTAssertNil(snapshot.weekLimit)
        XCTAssertTrue(snapshot.limitsNote?.contains("归属无法确认") == true)
    }

    func testAttributedStatuslineCacheRequiresCurrentIdentity() async throws {
        let body = #"{"account_uuid":"A","organization_uuid":"org-a","five_hour":{"used_percentage":40}}"#
        let matching = try provider(cache: body, identity: ("A", "org-a"))
        let other = try provider(cache: body, identity: ("B", "org-b"))
        let otherOrganization = try provider(cache: body, identity: ("A", "org-b"))
        let unknown = try provider(cache: body, identity: nil)
        let matchedSnapshot = try await matching.fetchSnapshot(now: .now)
        let otherSnapshot = try await other.fetchSnapshot(now: .now)
        let otherOrganizationSnapshot = try await otherOrganization.fetchSnapshot(now: .now)
        let unknownSnapshot = try await unknown.fetchSnapshot(now: .now)
        XCTAssertEqual(matchedSnapshot.sessionLimit?.used, 0.4)
        XCTAssertNil(otherSnapshot.sessionLimit)
        XCTAssertNil(otherOrganizationSnapshot.sessionLimit)
        XCTAssertNil(unknownSnapshot.sessionLimit)
    }

    @MainActor
    func testRefreshDoesNotCarryQuotaAcrossAccountChange() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-public-change-\(UUID().uuidString)")
        let project = directory.appendingPathComponent("projects")
        let limits = directory.appendingPathComponent("limits")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: limits, withIntermediateDirectories: true)
        try Data().write(to: project.appendingPathComponent("session.jsonl"))
        try #"{"account_uuid":"A","organization_uuid":"org-a","five_hour":{"used_percentage":40}}"#
            .write(to: limits.appendingPathComponent("rate-limits.json"), atomically: true, encoding: .utf8)
        var identity = (accountUUID: "A", organizationUUID: "org-a")
        let provider = ClaudeUsageProvider(root: project, limits: ClaudeLimitsCache(directory: limits),
                                           scopedBox: .init(), scan: UsageScanCache(), currentAccount: { identity })
        var now = Date()
        let store = UsageStore(providers: [provider], clock: { now })
        store.providersChanged()
        let firstRefresh = await store.refreshAndWait(reason: .manual)
        XCTAssertTrue(firstRefresh)
        if case .success(let snapshot)? = store.results[.claude] {
            XCTAssertEqual(snapshot.sessionLimit?.used, 0.4)
        } else {
            XCTFail("Claude quota was not read")
        }

        identity = ("B", "org-b")
        now.addTimeInterval(61)
        let secondRefresh = await store.refreshAndWait(reason: .manual)
        XCTAssertTrue(secondRefresh)
        if case .success(let snapshot)? = store.results[.claude] {
            XCTAssertNil(snapshot.sessionLimit)
            XCTAssertTrue(snapshot.limitsNote?.contains("归属无法确认") == true)
        } else {
            XCTFail("Claude usage disappeared")
        }
    }
}
