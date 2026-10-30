import XCTest
@testable import Tally

final class DemoModeTests: XCTestCase {

    func testLaunchOptionsRecognisesDemoAlongsideOpen() {
        XCTAssertTrue(LaunchOptions.parse(["Tally", "--demo"]).demo)
        let both = LaunchOptions.parse(["Tally", "--demo", "--open", "network"])
        XCTAssertTrue(both.demo)
        XCTAssertEqual(both.openPage, .network, "--demo 不吞掉后面的 --open")
        let openOnly = LaunchOptions.parse(["Tally", "--open", "ai"])
        XCTAssertFalse(openOnly.demo)
        XCTAssertEqual(openOnly.openPage, .ai)
        XCTAssertTrue(LaunchOptions.parse(["Tally", "--demo", "--peek-test"]).peekTest)
        XCTAssertTrue(LaunchOptions.parse(["Tally", "--demo", "--crew-overflow"]).crewOverflow)
        XCTAssertFalse(LaunchOptions.parse(["Tally", "--demo"]).crewOverflow)
    }

    /// 测试进程不许进演示模式：进了的话各 store 的 shared 全是假数据，别的用例测的就不是真路径。
    func testDemoModeIsOffUnderTests() {
        XCTAssertFalse(DemoMode.isOn)
    }

    func testSessionFixturesCoverEveryGroupWithExactlyOneStale() {
        let now = Date()
        let sessions = DemoData.sessions(now: now, overflow: false)
        guard var pending = sessions.first else { return XCTFail("演示会话为空") }
        pending.isProvisional = true
        XCTAssertEqual(Set((sessions + [pending]).map { $0.group(now: now) }), Set(SessionRecord.Group.allCases))
        XCTAssertEqual(sessions.filter { $0.state != .ended && $0.isStale(now: now) }.count, 1, "恰有一条失联，刘海小人才有灰的那个")
        let projects = CrewRoster.projects(sessions, now: now)
        XCTAssertEqual(projects.count, 6, "六个项目正好 3 + 3 放满")
        XCTAssertEqual(Set(projects.map(\.mood)), Set(CrewMood.allCases), "六种状态各占一个项目")
        let layout = CrewRoster.layout(projects, perSide: 3)
        XCTAssertEqual(layout.overflow, 0)
        XCTAssertEqual(layout.left.map(\.name), ["shop-web", "infra", "api-server"], "Claude 占等审批、等输入、压缩中，在左翼")
        XCTAssertEqual(layout.right.map(\.name), ["mobile-app", "payments", "docs-site"], "Codex 占在跑、完成、失联，在右翼")
        XCTAssertTrue(layout.left.allSatisfy { $0.provider == "claude" })
        XCTAssertTrue(layout.right.allSatisfy { $0.provider == "codex" })
        let crowded = CrewRoster.projects(DemoData.sessions(now: now, overflow: true), now: now)
        XCTAssertEqual(crowded.count, 8)
        let crowdedLayout = CrewRoster.layout(crowded, perSide: 3)
        XCTAssertEqual(crowdedLayout.overflow, 3, "8 个项目显示 5 个加「+3」")
        XCTAssertEqual(crowdedLayout.overflowSide, .right, "Claude 四个把交界推过刘海，空出的是右翼最外格")
        XCTAssertTrue(sessions.compactMap(\.pid).allSatisfy { $0 > 99_999 }, "pid 不能落在 macOS 真进程的范围里")
        XCTAssertEqual(Set(sessions.map(\.sessionId)).count, sessions.count)
        let peek = sessions.first { $0.sessionId == DemoData.peekSessionId }
        XCTAssertEqual(peek?.state, .done)
        XCTAssertEqual(peek?.title, "修复支付回调重复入账")
    }

    func testFixturesMentionNoHomeFolderButDemo() {
        let now = Date()
        var text = ""
        dump(DemoData.sessions(now: now), to: &text)
        dump(DemoData.shelfItems(now: now), to: &text)
        dump(DemoData.apps, to: &text)
        dump(DemoData.interface, to: &text)
        dump(DemoData.hardware(now: now), to: &text)
        dump(DemoData.systemSample, to: &text)
        XCTAssertTrue(text.contains("/Users/demo/"), "确认 dump 真的带出了路径")
        let others = text.components(separatedBy: "/Users/").dropFirst().filter { !$0.hasPrefix("demo/") }
        XCTAssertEqual(others, [], "除了 /Users/demo 不许出现别的家目录")
    }

    func testNetworkAddressesAreInDocumentationRange() throws {
        let interface = DemoData.interface
        for address in [interface.address, interface.router] {
            let value = try XCTUnwrap(address)
            XCTAssertTrue(value.hasPrefix("192.0.2."), "\(value) 不在 192.0.2.0/24")
        }
    }

    func testDemoUsageResetsInTheFuture() async throws {
        let now = Date()
        for provider in DemoData.usageProviders {
            let snapshot = try await provider.fetchSnapshot(now: now)
            let limits = [snapshot.sessionLimit, snapshot.weekLimit].compactMap { $0 } + snapshot.scopedLimits.map(\.limit)
            for limit in limits {
                let reset = try XCTUnwrap(limit.resetsAt, "\(provider.id) 的配额没有重置时刻")
                XCTAssertGreaterThan(reset, now, "\(provider.id) 的配额一刷出来就过期，条不会画")
            }
            XCTAssertTrue(!limits.isEmpty || !snapshot.balances.isEmpty, "\(provider.id) 什么都没画")
        }
    }
}
