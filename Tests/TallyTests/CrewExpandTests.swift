import AppKit
import XCTest
@testable import Tally

/// 翅膀的悬停撑开与点击（docs/crew.md「悬停撑开与点击」）：分派、两行文案、显示状态机、名册刷新后的定位、真定时器。
final class CrewExpandTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let m14 = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), auxiliaryTopLeftWidth: 663, auxiliaryTopRightWidth: 664, safeAreaTop: 32)

    private func session(_ id: String, _ state: SessionRecord.State, cwd: String = "/repo", age: TimeInterval = 10,
                         provider: String = "claude", model: String? = nil) -> SessionRecord {
        var record = SessionRecord(sessionId: id, provider: provider, state: state, cwd: cwd, title: "标题 \(id)", transcriptPath: "", message: nil,
                                   updatedAt: now.addingTimeInterval(-age).timeIntervalSince1970 * 1000)
        record.model = model
        return record
    }

    private func project(_ name: String, _ sessions: [SessionRecord], mood: CrewMood) -> CrewProject {
        CrewProject(id: "claude:/\(name)", provider: "claude", path: "/\(name)", name: name, sessions: sessions, mood: mood)
    }

    private func slot(_ project: CrewProject?, overflow: Int = 0) -> CrewSlot {
        CrewSlot(project: project, overflow: overflow, startedAt: now, phase: 0)
    }

    private func hover(_ slot: CrewSlot, index: Int = 0) -> CrewHover {
        CrewHover(side: .right, index: index, slot: slot)
    }

    private func art() throws -> BloubArt {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(BloubArt(url: root.appendingPathComponent("Resources/bloub/frames.json")))
    }

    func testTapJumpsForOneSessionAndOpensTheAIPageOtherwise() {
        let one = session("a", .running)
        XCTAssertEqual(CrewExpand.tap(slot(project("repo", [one], mood: .run))), .jump(one))
        var provisional = one
        provisional.isProvisional = true
        XCTAssertEqual(CrewExpand.tap(slot(project("repo", [provisional], mood: .run))), .openAI)
        XCTAssertEqual(CrewExpand.tap(slot(project("repo", [one, session("b", .done)], mood: .run))), .openAI, "多会话去 AI 页看列表，翼上不养一份")
        XCTAssertEqual(CrewExpand.tap(slot(nil, overflow: 3)), .openAI)
    }

    func testStateMachineExpandsAfterTheDelayAndCollapsesAfterLeaving() {
        let h = hover(slot(project("repo", [session("a", .running)], mood: .run)))
        let pending = CrewExpand.State.hidden.reduce(.enterSlot(h))
        XCTAssertEqual(pending, .pending(h))
        XCTAssertEqual(pending.delay, 0.15)
        XCTAssertFalse(pending.isVisible)
        XCTAssertEqual(pending.reduce(.leaveSlot), .hidden, "150 ms 内离开就不撑开")
        let shown = pending.reduce(.showTimer)
        XCTAssertEqual(shown, .shown(h))
        XCTAssertNil(shown.delay)
        XCTAssertTrue(shown.isVisible)
        let closing = shown.reduce(.leaveSlot)
        XCTAssertEqual(closing, .closing(h))
        XCTAssertEqual(closing.delay, 0.3)
        XCTAssertTrue(closing.isVisible, "收起前还撑着")
        XCTAssertEqual(closing.reduce(.hideTimer), .hidden)
        XCTAssertEqual(closing.reduce(.enterSlot(h)), shown, "300 ms 内回来就不收")
        XCTAssertEqual(CrewExpand.State.hidden.phase, .hidden)
        XCTAssertEqual(pending.phase, .pending)
        XCTAssertEqual(closing.phase, .closing)
    }

    func testMovingToAnotherSlotSwitchesWithoutWaiting() {
        let h = hover(slot(project("repo", [session("a", .running)], mood: .run)))
        let other = hover(slot(project("other", [session("b", .running)], mood: .run)), index: 1)
        XCTAssertEqual(CrewExpand.State.shown(h).reduce(.enterSlot(other)), .shown(other))
        XCTAssertEqual(CrewExpand.State.closing(h).reduce(.enterSlot(other)), .shown(other))
        XCTAssertFalse(other.sameSlot(as: h))
        let updated = hover(slot(project("repo", [session("a", .running, age: 1)], mood: .run)))
        XCTAssertNotEqual(h, updated)
        XCTAssertTrue(updated.sameSlot(as: h), "同一格的会话刷新过还是同一格")
    }

    func testTapAlwaysCollapses() {
        let two = project("api", [session("a", .running), session("b", .done)], mood: .run)
        let one = project("repo", [session("c", .running)], mood: .run)
        XCTAssertEqual(CrewExpand.State.shown(hover(slot(two))).reduce(.tap(.openAI)), .hidden)
        XCTAssertEqual(CrewExpand.State.shown(hover(slot(one))).reduce(.tap(.jump(one.sessions[0]))), .hidden)
        XCTAssertEqual(CrewExpand.State.pending(hover(slot(one))).reduce(.tap(.jump(one.sessions[0]))), .hidden, "还没等到 150 ms 就点了：点击本身是动作，不撑开")
        XCTAssertEqual(CrewExpand.State.closing(hover(slot(two))).reduce(.dismiss), .hidden, "面板展开立刻收")
        XCTAssertEqual(CrewExpand.State.hidden.reduce(.tap(.openAI)), .hidden)
    }

    func testRefreshFollowsTheProjectToItsNewSlotOrCollapses() {
        let h = hover(slot(project("repo", [session("a", .running)], mood: .run)))
        let moved = hover(h.slot, index: 2)
        XCTAssertEqual(CrewExpand.State.shown(h).reduce(.refresh(moved)), .shown(moved))
        XCTAssertEqual(CrewExpand.State.closing(h).reduce(.refresh(moved)), .closing(moved))
        XCTAssertEqual(CrewExpand.State.pending(h).reduce(.refresh(moved)), .pending(moved))
        XCTAssertEqual(CrewExpand.State.shown(h).reduce(.refresh(nil)), .hidden, "项目不在翼上了就收")
        XCTAssertEqual(CrewExpand.State.hidden.reduce(.refresh(moved)), .hidden)
    }

    /// 控制器真排定时器：进槽 150 ms 后把那格交给翅膀撑开，离开 300 ms 后交 nil；名册刷新只换内容不重排表。
    @MainActor
    func testControllerAppliesTheExpansionOnRealTimers() {
        _ = NSApplication.shared
        let controller = CrewExpandController()
        var applied: [CrewHover?] = []
        controller.apply = { applied.append($0) }
        let h = hover(slot(project("repo", [session("a", .running)], mood: .run)))
        let updated = hover(slot(project("repo", [session("a", .running, age: 1)], mood: .run)))
        controller.hover(h)
        XCTAssertEqual(controller.state, .pending(h))
        XCTAssertEqual(applied, [nil], "还没到 150 ms 不撑")
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        controller.refresh { _ in updated }
        XCTAssertEqual(controller.state, .pending(updated))
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        XCTAssertEqual(controller.state, .shown(updated), "150 ms 从进槽算，刷新不重计")
        XCTAssertEqual(applied.last, updated)
        controller.hover(nil)
        XCTAssertEqual(controller.state, .closing(updated))
        XCTAssertEqual(applied.last, updated, "收起前还撑着")
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        controller.refresh { _ in h }
        XCTAssertEqual(controller.state, .closing(h))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(controller.state, .hidden, "300 ms 从离开算，刷新不重计")
        XCTAssertEqual(applied.last, .some(nil))
        var jumped: [String] = []
        controller.jump = { jumped.append($0.sessionId) }
        controller.click(h)
        XCTAssertEqual(jumped, ["a"])
        XCTAssertEqual(controller.state, .hidden)
    }

    /// 名册刷新后按项目 id 找回它现在的槽：换了格跟着走，项目没了返回 nil，胶囊也能找回；撑开时翼往外长、球不挪。
    @MainActor
    func testControllerLocatesTheSameProjectAndExpandsOutward() throws {
        _ = NSApplication.shared
        let crew = CrewController(art: try art())
        crew.apply(enabled: true, perSide: 3, skin: .glass, sharingType: .readOnly)
        defer { crew.apply(enabled: false, perSide: 3, skin: .glass, sharingType: .readOnly) }
        crew.relayout(metrics: m14)
        let sessions = DemoData.sessions(now: now, overflow: false)
        crew.refresh(sessions, now: now)
        let shopWeb = try XCTUnwrap(crew.projects.first { $0.name == "shop-web" })
        let before = try XCTUnwrap(crew.hover(matching: CrewHover(side: .left, index: 0, slot: CrewSlot(project: shopWeb, overflow: 0, startedAt: now, phase: 0))))
        XCTAssertEqual(before.side, .left)
        XCTAssertEqual(before.index, 0, "等审批最急的 Claude，左翼贴刘海那格")
        let left = try XCTUnwrap(crew.wing(.left) as? CrewPanel)
        XCTAssertEqual(left.frame, CGRect(x: 554, y: 950, width: 121, height: 32))

        crew.setExpanded(before)
        XCTAssertEqual(left.frame, CGRect(x: 554, y: 950, width: 121, height: 32), "下拉时翼不变宽")
        XCTAssertTrue(try XCTUnwrap(crew.dropdownWindow).isVisible)
        XCTAssertTrue(try XCTUnwrap(crew.avatarWindow).isVisible)
        XCTAssertTrue(try XCTUnwrap(crew.avatarWindow).ignoresMouseEvents, "移动角色不能挡住列表点击")
        XCTAssertEqual(crew.dropdownWindow?.frame.maxY, left.frame.minY - CrewDropdownPanel.wingGap, "列表与角色光晕留出间隔")
        XCTAssertEqual(crew.wing(.right)?.frame.width, 121, "另一翼不动")
        var movedScreen = m14
        movedScreen.frame.origin.x += 20
        crew.relayout(metrics: movedScreen)
        XCTAssertNil(crew.expanded, "屏幕位置改变要取消旧悬停")
        XCTAssertFalse(try XCTUnwrap(crew.dropdownWindow).isVisible)
        XCTAssertFalse(try XCTUnwrap(crew.avatarWindow).isVisible)
        crew.relayout(metrics: m14)
        crew.setExpanded(before)
        crew.setExpanded(nil)
        XCTAssertEqual(left.frame.width, 121)
        XCTAssertFalse(try XCTUnwrap(crew.dropdownWindow).isVisible)

        // 审批通过开始跑：shop-web 不再最急，排到后面去（六个项目都在翼上，只是换格）
        let approved = sessions.map { record -> SessionRecord in
            var copy = record
            if copy.state == .waitingPermission { copy.state = .running }
            return copy
        }
        crew.refresh(approved, now: now)
        let after = try XCTUnwrap(crew.hover(matching: before))
        XCTAssertFalse(after.side == before.side && after.index == before.index, "不再是最急的，换了格")
        XCTAssertEqual(after.slot.project?.id, shopWeb.id)

        // 八个项目：被顶进胶囊的项目找不回（该收），胶囊自己能找回
        crew.refresh(DemoData.sessions(now: now, overflow: true), now: now)
        let hiddenByCapsule = try XCTUnwrap(crew.projects.first { project in !(crew.layout.right + crew.layout.left).contains { $0.id == project.id } })
        XCTAssertNil(crew.hover(matching: CrewHover(side: .left, index: 0, slot: CrewSlot(project: hiddenByCapsule, overflow: 0, startedAt: now, phase: 0))))
        let capsule = try XCTUnwrap(crew.hover(matching: CrewHover(side: .left, index: 0, slot: CrewSlot(project: nil, overflow: 1, startedAt: now, phase: 0))))
        XCTAssertNil(capsule.slot.project)
        XCTAssertEqual(capsule.side, .right)
        XCTAssertEqual(capsule.index, 2, "Claude 四个把交界推过刘海，胶囊在右翼最外")

        crew.refresh(sessions.filter { !$0.cwd.hasSuffix("shop-web") }, now: now)
        XCTAssertNil(crew.hover(matching: before), "项目没了")
    }
}
