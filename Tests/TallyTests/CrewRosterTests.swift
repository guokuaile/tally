import XCTest
@testable import Tally

/// 会话折叠成项目、排序、槽位、溢出、身份调色板、新项目检测（docs/crew.md「名册」）。
final class CrewRosterTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String, _ state: SessionRecord.State, cwd: String, age: TimeInterval = 10,
                         provider: String = "claude", background: SessionRecord.BackgroundWork? = nil) -> SessionRecord {
        var record = SessionRecord(sessionId: id, provider: provider, state: state, cwd: cwd, title: id, transcriptPath: "", message: nil,
                                   updatedAt: now.addingTimeInterval(-age).timeIntervalSince1970 * 1000)
        record.backgroundWork = background
        return record
    }

    private func project(_ id: String, mood: CrewMood = .run, provider: String = "claude") -> CrewProject {
        CrewProject(id: id, provider: provider, path: "/" + id, name: id, sessions: [], mood: mood)
    }

    func testSameDirectoryFoldsIntoOneProject() {
        let projects = CrewRoster.projects([session("a", .running, cwd: "/repo"), session("b", .done, cwd: "/repo")], now: now)
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].id, "claude:/repo")
        XCTAssertEqual(projects[0].path, "/repo")
        XCTAssertEqual(projects[0].sessions.map(\.sessionId), ["a", "b"])
        XCTAssertEqual(projects[0].name, "repo")
    }

    func testTrailingSlashAndDotSegmentsNormalizeButSubdirectoriesDoNot() {
        let projects = CrewRoster.projects([
            session("a", .running, cwd: "/repo"), session("b", .running, cwd: "/repo/"),
            session("c", .running, cwd: "/repo/./"), session("d", .running, cwd: "/repo/sub")
        ], now: now)
        XCTAssertEqual(projects.map(\.id).sorted(), ["claude:/repo", "claude:/repo/sub"])
        XCTAssertEqual(projects.first { $0.id == "claude:/repo" }?.sessions.count, 3)
    }

    func testCanonicalizeDefault() {
        XCTAssertEqual(CrewRoster.standardized("/repo/"), "/repo")
        XCTAssertEqual(CrewRoster.standardized("/repo/./"), "/repo")
        XCTAssertEqual(CrewRoster.standardized("/repo//sub/../sub"), "/repo/sub")
        XCTAssertEqual(CrewRoster.standardized("/"), "/")
    }

    func testSymlinksMergeOnlyWithAResolvingCanonicalizer() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("crew-roster-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real"), link = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }
        let sessions = [session("a", .running, cwd: real.path), session("b", .running, cwd: link.path)]
        XCTAssertEqual(CrewRoster.projects(sessions, now: now).count, 2, "默认不解符号链接")
        let resolving = { (cwd: String) in CrewRoster.standardized(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path) }
        let merged = CrewRoster.projects(sessions, now: now, canonicalize: resolving)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].sessions.count, 2)
        XCTAssertEqual(merged[0].name, "real")
    }

    func testEndedSessionsStayOutOfTheRoster() {
        let projects = CrewRoster.projects([session("a", .ended, cwd: "/repo"), session("b", .running, cwd: "/other")], now: now)
        XCTAssertEqual(projects.map(\.id), ["claude:/other"])
        XCTAssertNil(CrewRoster.mood(of: session("a", .ended, cwd: "/repo"), now: now))
    }

    func testMoodFoldsToTheMostUrgent() {
        let chain: [(SessionRecord.State, CrewMood)] = [(.done, .done), (.running, .run), (.compacting, .compacting), (.waitingInput, .input), (.waitingPermission, .permission)]
        var sessions: [SessionRecord] = []
        for (index, (state, mood)) in chain.enumerated() {
            sessions.append(session("s\(index)", state, cwd: "/repo", age: TimeInterval(10 - index)))
            XCTAssertEqual(CrewRoster.projects(sessions, now: now)[0].mood, mood)
        }
        XCTAssertEqual(CrewRoster.projects(sessions, now: now)[0].sessions.map(\.state), [.waitingInput, .waitingPermission, .compacting, .running, .done], "组内按 displayOrder：等你（等得久的在前，s3 比 s4 早一秒）→ 在跑 → 完成")
    }

    func testWaitingProjectsOrderByLongestWaitAndGetTiers() {
        var forgotten = session("forgotten", .waitingPermission, cwd: "/a", age: 5)
        forgotten.waitingSince = now.addingTimeInterval(-11 * 60)
        var lingering = session("lingering", .waitingInput, cwd: "/b", age: 1)
        lingering.waitingSince = now.addingTimeInterval(-4 * 60)
        let fresh = session("fresh", .waitingPermission, cwd: "/c", age: 20)
        let projects = CrewRoster.projects([fresh, lingering, forgotten, session("run", .running, cwd: "/d")], now: now)
        XCTAssertEqual(projects.map(\.id), ["claude:/a", "claude:/c", "claude:/b", "claude:/d"], "同 mood 按开始等的时刻正序；没有 waitingSince 退回 updatedAt")
        XCTAssertEqual(projects.map(\.tier), [.dusty, .fresh, .lingering, .fresh])
        XCTAssertNil(projects[3].waitingSince)
        XCTAssertEqual(CrewTier.of(waited: nil), .fresh)
        XCTAssertEqual(CrewTier.of(waited: 179), .fresh)
        XCTAssertEqual(CrewTier.of(waited: 180), .lingering)
        XCTAssertEqual(CrewTier.of(waited: 600), .dusty)
    }

    func testDoneWithBackgroundWorkCountsAsRunning() {
        XCTAssertEqual(CrewRoster.mood(of: session("a", .done, cwd: "/repo", background: .agents), now: now), .run)
        XCTAssertEqual(CrewRoster.mood(of: session("a", .done, cwd: "/repo", background: .shells), now: now), .run)
        XCTAssertEqual(CrewRoster.mood(of: session("a", .done, cwd: "/repo"), now: now), .done)
    }

    func testStaleIsTwoHoursWithoutNewsAndNeverCountsAsDone() {
        XCTAssertEqual(CrewRoster.mood(of: session("a", .running, cwd: "/repo", age: 3 * 3600), now: now), .stale)
        XCTAssertEqual(CrewRoster.mood(of: session("a", .waitingPermission, cwd: "/repo", age: 3 * 3600), now: now), .stale)
        XCTAssertEqual(CrewRoster.mood(of: session("a", .running, cwd: "/repo", age: 2 * 3600 - 1), now: now), .run)
        XCTAssertEqual(CrewRoster.mood(of: session("a", .done, cwd: "/repo", age: 30 * 3600), now: now), .done, "跑完了的不算失联")
        let mixed = CrewRoster.projects([session("old", .running, cwd: "/repo", age: 3 * 3600), session("new", .done, cwd: "/repo")], now: now)
        XCTAssertEqual(mixed[0].mood, .done, "完成比失联急")
    }

    func testProjectsSortByMoodThenMostRecentUpdate() {
        let projects = CrewRoster.projects([
            session("a", .done, cwd: "/done-old", age: 500),
            session("b", .running, cwd: "/run-old", age: 400),
            session("c", .running, cwd: "/run-new", age: 5),
            session("d", .waitingInput, cwd: "/ask", age: 900),
            session("e", .running, cwd: "/stale", age: 5 * 3600)
        ], now: now)
        XCTAssertEqual(projects.map(\.id), ["claude:/ask", "claude:/run-new", "claude:/run-old", "claude:/done-old", "claude:/stale"])
    }

    func testProjectsAlternateSidesMostUrgentNearestTheNotch() {
        let projects = (0..<5).map { project("p\($0)") }
        let layout = CrewRoster.layout(projects, perSide: 3)
        XCTAssertEqual(layout.right.map(\.id), ["p0", "p2", "p4"])
        XCTAssertEqual(layout.left.map(\.id), ["p1", "p3"])
        XCTAssertEqual(layout.overflow, 0)
        XCTAssertEqual(layout.rightSlots, 3)
        XCTAssertEqual(layout.leftSlots, 2)
        let three = CrewRoster.layout((0..<3).map { project("p\($0)") }, perSide: 3)
        XCTAssertEqual(three.right.map(\.id), ["p0", "p2"], "三个项目也两侧都有")
        XCTAssertEqual(three.left.map(\.id), ["p1"])
        let one = CrewRoster.layout([project("solo")], perSide: 3)
        XCTAssertEqual(one.rightSlots, 1)
        XCTAssertEqual(one.leftSlots, 0)
        XCTAssertEqual(CrewRoster.layout([], perSide: 3), CrewLayout(right: [], left: [], overflow: 0))
    }

    func testOverflowCapsuleTakesTheOutermostLeftSlotAndCountsTheOneItDisplaced() {
        let seven = CrewRoster.layout((0..<7).map { project("p\($0)") }, perSide: 3)
        XCTAssertEqual(seven.right.map(\.id), ["p0", "p2", "p4"])
        XCTAssertEqual(seven.left.map(\.id), ["p1", "p3"])
        XCTAssertEqual(seven.overflow, 2)
        XCTAssertEqual(seven.leftSlots, 3, "两个角色加一格胶囊")
        XCTAssertEqual(CrewRoster.layout((0..<8).map { project("p\($0)") }, perSide: 3).overflow, 3)
        XCTAssertEqual(CrewRoster.layout((0..<6).map { project("p\($0)") }, perSide: 3).overflow, 0, "正好放满不溢出")
        let tiny = CrewRoster.layout((0..<3).map { project("p\($0)") }, perSide: 1)
        XCTAssertEqual(tiny.right.count, 1)
        XCTAssertEqual(tiny.left.count, 0)
        XCTAssertEqual(tiny.overflow, 2)
        XCTAssertEqual(tiny.leftSlots, 1, "左翼只剩胶囊")
    }

    func testPerSideIsClampedToOneThroughFour() {
        XCTAssertEqual(CrewRoster.perSide(0), 1)
        XCTAssertEqual(CrewRoster.perSide(-3), 1)
        XCTAssertEqual(CrewRoster.perSide(9), 4)
        XCTAssertEqual(CrewRoster.perSide(2), 2)
        let projects = (0..<10).map { project("p\($0)") }
        XCTAssertEqual(CrewRoster.layout(projects, perSide: 9).right.count, 4)
        XCTAssertEqual(CrewRoster.layout(projects, perSide: 0).right.count, 1)
    }

    func testNewcomersDuringLaunchGraceAreRememberedButNotBadged() {
        let launched = now.addingTimeInterval(-3)
        let projects = CrewRoster.projects([session("a", .running, cwd: "/repo"), session("b", .running, cwd: "/repo")], now: now)
        let first = CrewRoster.newcomers(seen: [], current: projects, launchedAt: launched, now: now)
        XCTAssertTrue(first.badge.isEmpty)
        XCTAssertEqual(first.seen, ["claude:a", "claude:b"])
        let later = CrewRoster.newcomers(seen: first.seen, current: projects, launchedAt: launched, now: now.addingTimeInterval(60))
        XCTAssertTrue(later.badge.isEmpty, "启动时就在的之后也不补发")
    }

    func testNewcomersAfterGraceReportEachUnseenProjectOnce() {
        let launched = now.addingTimeInterval(-60)
        let projects = CrewRoster.projects([session("a", .running, cwd: "/repo"), session("b", .running, cwd: "/repo"), session("c", .running, cwd: "/other")], now: now)
        let first = CrewRoster.newcomers(seen: ["claude:a"], current: projects, launchedAt: launched, now: now)
        XCTAssertEqual(Set(first.badge.map { $0.1.sessionId }), ["b", "c"], "同项目新会话也发")
        XCTAssertEqual(first.seen, ["claude:a", "claude:b", "claude:c"])
        let again = CrewRoster.newcomers(seen: first.seen, current: projects, launchedAt: launched, now: now.addingTimeInterval(1))
        XCTAssertTrue(again.badge.isEmpty, "同一 id 第二次不再报")
        XCTAssertEqual(again.seen, first.seen)
        let exactly = CrewRoster.newcomers(seen: [], current: CrewRoster.projects([session("d", .running, cwd: "/d")], now: now), launchedAt: now.addingTimeInterval(-10), now: now)
        XCTAssertEqual(exactly.badge.map { $0.1.sessionId }, ["d"], "满 10 秒算过了宽限期")
    }

    func testSameDirectoryDifferentToolsAreTwoProjects() {
        let projects = CrewRoster.projects([
            session("a", .running, cwd: "/", age: 50, provider: "codex"),
            session("b", .waitingPermission, cwd: "/", age: 5, provider: "claude"),
            session("c", .running, cwd: "/", age: 1, provider: "codex")
        ], now: now)
        XCTAssertEqual(projects.map(\.id), ["claude:/", "codex:/"], "等审批的 Claude 排前")
        XCTAssertEqual(projects.map(\.name), ["/", "/"])
        XCTAssertEqual(projects.map(\.provider), ["claude", "codex"])
        XCTAssertEqual(projects[0].sessions.map(\.sessionId), ["b"])
        XCTAssertEqual(projects[1].sessions.map(\.sessionId), ["c", "a"], "组内按 displayOrder")
    }

    func testTwoToolsMeetAtTheNotchWhenNeitherExceedsPerSide() {
        let projects = [project("c0"), project("x0", provider: "codex"), project("c1"), project("x1", provider: "codex"), project("c2"), project("x2", provider: "codex")]
        let layout = CrewRoster.layout(projects, perSide: 3)
        XCTAssertEqual(layout.left.map(\.id), ["c0", "c1", "c2"], "Claude 在左，最急的贴刘海")
        XCTAssertEqual(layout.right.map(\.id), ["x0", "x1", "x2"], "Codex 在右")
        XCTAssertEqual(layout.overflow, 0)
        let two = CrewRoster.layout([project("x0", provider: "codex"), project("c0")], perSide: 3)
        XCTAssertEqual(two.left.map(\.id), ["c0"], "一边一个都贴刘海")
        XCTAssertEqual(two.right.map(\.id), ["x0"])
    }

    func testDividerSlidesWhenOneToolExceedsPerSide() {
        // 5 Claude + 1 Codex：暖块占满左翼再占右翼贴刘海两格，Codex 那个在右翼最外
        let projects = [project("c0"), project("c1"), project("x0", provider: "codex"), project("c2"), project("c3"), project("c4")]
        let layout = CrewRoster.layout(projects, perSide: 3)
        XCTAssertEqual(layout.left.map(\.id), ["c0", "c2", "c4"], "块内离刘海近的给最急的，同距先放自己那边")
        XCTAssertEqual(layout.right.map(\.id), ["c1", "c3", "x0"])
        XCTAssertEqual(layout.overflow, 0)
        // 1 Claude + 4 Codex：镜像，左翼只占两格
        let mirrored = [project("x0", provider: "codex"), project("x1", provider: "codex"), project("c0"), project("x2", provider: "codex"), project("x3", provider: "codex")]
        let m = CrewRoster.layout(mirrored, perSide: 3)
        XCTAssertEqual(m.left.map(\.id), ["x1", "c0"])
        XCTAssertEqual(m.right.map(\.id), ["x0", "x2", "x3"])
        XCTAssertEqual(m.leftSlots, 2, "翼宽跟着实际占用缩")
    }

    func testOverflowTrimsTheIdlestRegardlessOfToolAndPutsTheCapsuleOnTheFreeEnd() {
        // 8 个：砍最闲的 3 个，剩 4 Claude + 1 Codex，交界推过刘海，空出的是右翼最外格
        let projects = [project("c0"), project("c1"), project("c2"), project("x0", provider: "codex"), project("c3"),
                        project("x1", provider: "codex"), project("x2", provider: "codex"), project("c4")]
        let layout = CrewRoster.layout(projects, perSide: 3)
        XCTAssertEqual(layout.overflow, 3)
        XCTAssertEqual(layout.left.map(\.id), ["c0", "c2", "c3"])
        XCTAssertEqual(layout.right.map(\.id), ["c1", "x0"])
        XCTAssertEqual(layout.overflowSide, .right)
        XCTAssertEqual(layout.rightSlots, 3)
        XCTAssertEqual(layout.leftSlots, 3)
        // Codex 更多更急：胶囊到左边
        let mirrored = [project("x0", provider: "codex"), project("x1", provider: "codex"), project("x2", provider: "codex"), project("c0"),
                        project("x3", provider: "codex"), project("c1"), project("c2")]
        let m = CrewRoster.layout(mirrored, perSide: 3)
        XCTAssertEqual(m.overflow, 2)
        XCTAssertEqual(m.left.map(\.id), ["x1", "c0"])
        XCTAssertEqual(m.right.map(\.id), ["x0", "x2", "x3"])
        XCTAssertEqual(m.overflowSide, .left)
        XCTAssertEqual(m.leftSlots, 3)
        // 砍完只剩一家：退回围着刘海交替，胶囊固定在左
        let single = (0..<6).map { project("c\($0)") } + [project("x0", provider: "codex")]
        let s = CrewRoster.layout(single, perSide: 3)
        XCTAssertEqual(s.right.map(\.id), ["c0", "c2", "c4"])
        XCTAssertEqual(s.left.map(\.id), ["c1", "c3"])
        XCTAssertEqual(s.overflowSide, .left)
    }

    func testMoodOrderMatchesPriority() {
        XCTAssertLessThan(CrewMood.permission, .input)
        XCTAssertLessThan(CrewMood.input, .compacting)
        XCTAssertLessThan(CrewMood.compacting, .run)
        XCTAssertLessThan(CrewMood.run, .done)
        XCTAssertLessThan(CrewMood.done, .stale)
    }
}
