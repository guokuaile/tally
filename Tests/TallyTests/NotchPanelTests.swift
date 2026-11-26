import AppKit
import os
import XCTest
@testable import Tally

final class NotchPanelTests: XCTestCase {

    /// 钉的是「为什么需要让路」这个前提：`runModal` 把模态窗口的 level 钉死在 `.modalPanel`，
    /// 面板比它高，所以 `NSAlert` / `NSOpenPanel` 天生就在面板底下（看不见也点不到）。
    /// 哪天面板 level 降到模态窗口之下，这条会红，提醒让路那套可以撤了。
    @MainActor
    func testPanelSitsAboveModalWindows() {
        _ = NSApplication.shared
        let panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 620, height: 160))
        defer { panel.close() }
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.modalPanel.rawValue,
                             "面板比模态窗口高，所以弹系统模态 UI 前必须 steppingAside 让路")
    }

    /// 让路期间要低于模态窗口，出来必须原样还原（`defer`，body 中途 return 也还原）。
    @MainActor
    func testSteppingAsideLowersThenRestores() {
        _ = NSApplication.shared
        let panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 620, height: 160))
        defer { panel.close() }
        let original = panel.level
        var levelDuringBody: NSWindow.Level?
        let returned = NotchPanel.steppingAside { () -> Int in
            levelDuringBody = panel.level
            return 7
        }
        XCTAssertEqual(returned, 7, "body 的返回值原样交出来")
        XCTAssertLessThan(try XCTUnwrap(levelDuringBody).rawValue, NSWindow.Level.modalPanel.rawValue,
                          "让路期间要低于模态窗口，否则弹框还是被盖住")
        XCTAssertEqual(panel.level, original, "出来还原成原来的 level")
    }

    @MainActor
    func testPillAcceptsFirstClickWithoutBecomingKey() throws {
        _ = NSApplication.shared
        var clicks = 0
        let peek = Peek(id: "test", style: .session, tint: .green, label: "Claude", title: "test", subtitle: nil, sessionId: "s")
        let pill = PillNotificationPanel(peek: peek, isInteractive: true) { clicks += 1 }
        defer { pill.close() }
        pill.orderFrontRegardless()
        pill.displayIfNeeded()
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 160, y: 22),
                                                     modifierFlags: [], timestamp: 0, windowNumber: pill.windowNumber,
                                                     context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        pill.sendEvent(event)
        XCTAssertEqual(clicks, 1)
        XCTAssertFalse(pill.canBecomeKey)
        XCTAssertFalse(pill.isKeyWindow)
        let original = pill.level
        NotchPanel.steppingAside { XCTAssertLessThan(pill.level.rawValue, NSWindow.Level.modalPanel.rawValue) }
        XCTAssertEqual(pill.level, original)
    }

    @MainActor
    func testRetiringBadgeStopsAcceptingClicksAndOnlyFadesWithReducedMotion() throws {
        _ = NSApplication.shared
        var clicks = 0
        let peek = Peek(id: "badge", style: .badge, tint: .green, label: "入职", title: "test", subtitle: nil, sessionId: "s")
        let pill = PillNotificationPanel(peek: peek, isInteractive: true) { clicks += 1 }
        defer { pill.close() }
        let frame = CGRect(x: 400, y: 300, width: 300, height: 370)
        pill.setFrame(frame, display: false)
        pill.retireBadge(duration: 0, reduceMotion: true)
        XCTAssertTrue(pill.ignoresMouseEvents)
        XCTAssertEqual(pill.frame, frame)
        XCTAssertEqual(pill.alphaValue, 0)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 150, y: 180),
                                                     modifierFlags: [], timestamp: 0, windowNumber: pill.windowNumber,
                                                     context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        pill.contentView?.mouseDown(with: event)
        XCTAssertEqual(clicks, 0)
        pill.retireBadge(duration: 0, reduceMotion: false)
        XCTAssertEqual(pill.frame, frame, "Refreshing the queue must not restart the exit")
    }
}

final class CrewWingTests: XCTestCase {
    let m14 = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), auxiliaryTopLeftWidth: 663, auxiliaryTopRightWidth: 664, safeAreaTop: 32)

    private func art() throws -> BloubArt {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(BloubArt(url: root.appendingPathComponent("Resources/bloub/frames.json")))
    }

    @MainActor
    func testCompletionDotsFollowProjectAndOverflowMembership() throws {
        _ = NSApplication.shared
        let crew = CrewController(art: try art())
        let now = Date()
        let records = DemoData.sessions(now: now, overflow: true)
        crew.apply(enabled: true, perSide: 3, skin: .glass, sharingType: .readOnly)
        crew.relayout(metrics: m14)
        defer { crew.apply(enabled: false, perSide: 3, skin: .glass, sharingType: .readOnly) }
        crew.refresh(records, now: now)
        let visible = crew.layout.left + crew.layout.right
        let shared = try XCTUnwrap(visible.first { $0.sessions.count > 1 })
        let hidden = try XCTUnwrap(crew.projects.first { project in !visible.contains { $0.id == project.id } })
        let a = shared.sessions[0].sessionId, b = shared.sessions[1].sessionId
        let hiddenID = try XCTUnwrap(hidden.sessions.first?.sessionId)
        func allSlots() -> [CrewSlot] {
            CrewGeometry.Side.allCases.flatMap { (crew.wing($0) as? CrewPanel)?.strip.slots ?? [] }
        }
        crew.refresh(records, now: now, completionIDs: [a, b, hiddenID])
        XCTAssertTrue(try XCTUnwrap(allSlots().first { $0.project?.id == shared.id }).hasNewCompletion)
        XCTAssertTrue(try XCTUnwrap(allSlots().first { $0.overflow > 0 }).hasNewCompletion)
        crew.refresh(records, now: now, completionIDs: [b])
        XCTAssertTrue(try XCTUnwrap(allSlots().first { $0.project?.id == shared.id }).hasNewCompletion)
        XCTAssertFalse(try XCTUnwrap(allSlots().first { $0.overflow > 0 }).hasNewCompletion)
        crew.refresh(records, now: now, completionIDs: [])
        XCTAssertFalse(try XCTUnwrap(allSlots().first { $0.project?.id == shared.id }).hasNewCompletion)
        XCTAssertEqual(crew.projects.first { $0.id == shared.id }?.mood, shared.mood)
    }

    @MainActor
    func testDropdownRowsSelectTheirOwnSessionWithoutActivatingPanel() throws {
        _ = NSApplication.shared
        let now = Date()
        let projects = CrewRoster.projects(DemoData.sessions(now: now, overflow: false), now: now)
        let project = try XCTUnwrap(projects.first { $0.sessions.count == 2 })
        var selected: [String] = []
        let panel = CrewDropdownPanel(project: project, side: .right, select: { selected.append($0.sessionId) }, hover: { _ in })
        defer { panel.close() }
        panel.setFrame(CrewDropdownPanel.frame(anchorX: 800, top: 950, screen: m14.frame, count: 2), display: true)
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        XCTAssertGreaterThan(panel.level.rawValue, (NSWindow.Level.mainMenu + 4).rawValue, "提示药丸同时存在时不挡下拉列表")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        for offset in [70.0, 115.0] {
            let point = CGPoint(x: 100, y: panel.frame.height - offset)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                            windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                panel.sendEvent(event)
            }
        }
        XCTAssertEqual(selected, project.sessions.map(\.sessionId))
        XCTAssertFalse(panel.isKeyWindow)
    }

    @MainActor
    func testSingleSessionDropdownAvatarSelectsItsSessionOnBothSides() throws {
        _ = NSApplication.shared
        let now = Date()
        let project = try XCTUnwrap(CrewRoster.projects(DemoData.sessions(now: now, overflow: false), now: now).first { $0.sessions.count == 1 })
        for side in CrewGeometry.Side.allCases {
            var selected: [String] = []
            let panel = CrewDropdownPanel(project: project, side: side, select: { selected.append($0.sessionId) }, hover: { _ in })
            panel.setFrame(CrewDropdownPanel.frame(anchorX: 800, top: 950, screen: m14.frame, count: 1, side: side), display: true)
            panel.orderFrontRegardless()
            panel.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let x: CGFloat = side == .right ? 29 : panel.frame.width - 29
            let point = CGPoint(x: x, y: panel.frame.height - 25)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                            windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                panel.sendEvent(event)
            }
            XCTAssertEqual(selected, [project.sessions[0].sessionId])
            panel.close()
        }
    }

    @MainActor
    func testAccessibleSlotFollowsItsProjectAfterReordering() throws {
        _ = NSApplication.shared
        let now = Date()
        let projects = CrewRoster.projects(DemoData.sessions(now: now, overflow: false), now: now)
        let first = CrewSlot(project: projects[0], overflow: 0, startedAt: now, phase: 0)
        let second = CrewSlot(project: projects[1], overflow: 0, startedAt: now, phase: 0)
        let panel = CrewPanel(side: .right)
        defer { panel.close() }
        let size = CGSize(width: CrewGeometry.wingWidth(slots: 2), height: 32)
        panel.setContentSize(size)
        panel.strip.configure(slots: [first, second], skin: .glass, size: size)
        let element = try XCTUnwrap(panel.strip.accessibilityChildren()?.first as? NSAccessibilityElement)
        var pressed: Int?
        panel.strip.onClick = { pressed = $0 }
        panel.strip.configure(slots: [second, first], skin: .glass, size: size)
        XCTAssertTrue(element.accessibilityPerformPress())
        XCTAssertEqual(pressed, 1, "同一项目换槽后不能激活原槽的新项目")
        panel.strip.configure(slots: [second], skin: .glass, size: size)
        XCTAssertFalse(element.accessibilityPerformPress(), "项目消失后不能假报激活成功")
    }

    /// 两翼跟着面板开合、全屏隐藏、屏幕变化、开关走；夹具是 ScreenMetrics，不看真机屏幕。
    @MainActor
    func testWingsFollowPanelStateScreenAndSwitch() throws {
        _ = NSApplication.shared
        let crew = CrewController(art: try art())
        let now = Date()
        crew.apply(enabled: true, perSide: 3, skin: .glass, sharingType: .readOnly)
        crew.relayout(metrics: m14)
        crew.refresh(DemoData.sessions(now: now, overflow: false), now: now)
        defer { crew.apply(enabled: false, perSide: 3, skin: .glass, sharingType: .readOnly) }
        let right = try XCTUnwrap(crew.wing(.right)), left = try XCTUnwrap(crew.wing(.left))
        XCTAssertTrue(right.isVisible)
        XCTAssertTrue(left.isVisible)
        let rightStrip = try XCTUnwrap((right as? CrewPanel)?.strip)
        let elements = try XCTUnwrap(rightStrip.accessibilityChildren())
        XCTAssertEqual(elements.count, 3)
        var activated: CrewHover?
        crew.onClick = { activated = $0 }
        let accessible = try XCTUnwrap(elements.first as? NSAccessibilityElement)
        XCTAssertTrue(accessible.accessibilityPerformPress())
        XCTAssertEqual(activated?.side, .right)
        XCTAssertEqual(activated?.index, 0)
        XCTAssertEqual(right.frame, CGRect(x: 836, y: 950, width: 121, height: 32))
        XCTAssertEqual(left.frame, CGRect(x: 554, y: 950, width: 121, height: 32))
        XCTAssertEqual(crew.layout.rightSlots, 3)
        XCTAssertEqual(crew.layout.leftSlots, 3)
        XCTAssertFalse(right.canBecomeKey)
        XCTAssertEqual(right.level, .mainMenu + 2)

        crew.setHidden(true)
        XCTAssertFalse(right.isVisible, "面板展开（或全屏隐藏）两翼不上屏")
        XCTAssertFalse(left.isVisible)
        crew.setHidden(false)
        XCTAssertTrue(right.isVisible)

        crew.relayout(metrics: nil)
        XCTAssertFalse(right.isVisible, "合盖只剩外接屏：两翼藏起来")
        crew.relayout(metrics: m14)
        XCTAssertTrue(right.isVisible, "开盖回内建屏：两翼回来，还是原来那两个窗口")
        XCTAssertTrue(crew.wing(.right) === right)

        crew.refresh([DemoData.sessions(now: now, overflow: false)[0]], now: now)
        XCTAssertEqual(right.frame.width, 59, "一个项目时右翼只有一格")
        XCTAssertFalse(left.isVisible, "空翼不上屏")

        let original = right.level
        NotchPanel.steppingAside { XCTAssertLessThan(right.level.rawValue, NSWindow.Level.modalPanel.rawValue, "弹系统模态 UI 时翅膀也让路") }
        XCTAssertEqual(right.level, original)

        crew.apply(enabled: false, perSide: 3, skin: .glass, sharingType: .readOnly)
        XCTAssertNil(crew.wing(.right), "关掉开关两翼不存在")
        XCTAssertNil(crew.wing(.left))
        XCTAssertNil(crew.clockInterval, "关掉开关停止动画")
        XCTAssertEqual(crew.frameCache?.count, 0, "关掉开关释放帧缓存")
        XCTAssertTrue(crew.projects.isEmpty, "关掉开关释放项目名册")
        XCTAssertFalse(right.isVisible)
    }

    /// 让开菜单（docs/crew.md）：量到菜单排到哪儿，两翼就缩到哪儿；菜单变短了再放回来。
    @MainActor
    func testWingsYieldToTheMenuBar() throws {
        _ = NSApplication.shared
        let crew = CrewController(art: try art())
        let now = Date()
        crew.apply(enabled: true, perSide: 3, skin: .glass, sharingType: .readOnly)
        crew.relayout(metrics: m14)
        crew.refresh(DemoData.sessions(now: now, overflow: false), now: now)
        defer { crew.apply(enabled: false, perSide: 3, skin: .glass, sharingType: .readOnly) }
        let right = try XCTUnwrap(crew.wing(.right)), left = try XCTUnwrap(crew.wing(.left))
        XCTAssertNil(crew.room, "没注入量菜单的函数：不量，照 perSide 排")
        XCTAssertEqual(left.frame.minX, 554)

        crew.menuBarRead(pid: 1, end: 592)
        XCTAssertEqual(crew.room, CrewRoom(left: 1, right: .max))
        XCTAssertGreaterThanOrEqual(left.frame.minX, 592, "Chrome 的菜单排到 592：左翼不能压过去")
        XCTAssertEqual(crew.layout.leftSlots, 1)
        XCTAssertEqual(crew.layout.rightSlots, 3, "右翼两个角色加胶囊")
        XCTAssertEqual(crew.layout.overflow, 3)
        XCTAssertEqual(crew.layout.overflowSide, .right)
        XCTAssertEqual(right.frame, CGRect(x: 836, y: 950, width: 121, height: 32), "右翼不动")

        crew.menuBarRead(pid: 1, end: 700)
        XCTAssertFalse(left.isVisible, "菜单折过刘海：两翼都撤下")
        XCTAssertFalse(right.isVisible)
        XCTAssertFalse(crew.projects.isEmpty, "名册还在，只是没地方画")

        crew.menuBarRead(pid: 1, end: 365)
        XCTAssertTrue(left.isVisible, "切回菜单短的 app：两翼回来")
        XCTAssertEqual(left.frame, CGRect(x: 554, y: 950, width: 121, height: 32))
        XCTAssertEqual(crew.layout.overflow, 0)

        crew.apply(enabled: false, perSide: 3, skin: .glass, sharingType: .readOnly)
        XCTAssertNil(crew.room, "关掉开关忘掉量到的结果")
    }

    /// 读不到菜单时：同一个 app 沿用上一次的，换了 app 不能接着用上一个 app 的（它把两翼挤没了的话小人会一直不见）。
    @MainActor
    func testUnreadableMenuBarKeepsTheSameAppsRoomButNotAnotherApps() throws {
        _ = NSApplication.shared
        let crew = CrewController(art: try art())
        let now = Date()
        crew.apply(enabled: true, perSide: 3, skin: .glass, sharingType: .readOnly)
        crew.relayout(metrics: m14)
        crew.refresh(DemoData.sessions(now: now, overflow: false), now: now)
        defer { crew.apply(enabled: false, perSide: 3, skin: .glass, sharingType: .readOnly) }
        let left = try XCTUnwrap(crew.wing(.left)), right = try XCTUnwrap(crew.wing(.right))

        crew.menuBarRead(pid: 1, end: 700)
        XCTAssertFalse(left.isVisible)
        XCTAssertFalse(right.isVisible)
        crew.menuBarRead(pid: 1, end: nil)
        XCTAssertEqual(crew.room, CrewRoom(left: 0, right: 0), "同一个 app 一时没响应：这一轮不算")

        crew.menuBarRead(pid: 2, end: nil)
        XCTAssertNil(crew.room, "换了 app 又读不到：回到不限")
        XCTAssertTrue(left.isVisible, "两翼回来，不跟着上一个 app 一直藏着")
        XCTAssertTrue(right.isVisible)
        XCTAssertEqual(crew.layout.leftSlots, 3)

        crew.menuBarRead(pid: 2, end: 592)
        XCTAssertEqual(crew.room, CrewRoom(left: 1, right: .max), "之后读到了照常让开")
        crew.menuBarRead(pid: 2, end: nil)
        XCTAssertEqual(crew.room, CrewRoom(left: 1, right: .max))
    }

    /// 格数按当前屏幕现算：屏幕变了不等下一次量；关掉开关后才回来的那一次读取不算。
    @MainActor
    func testRoomFollowsTheScreenAndIgnoresReadsAfterDisable() throws {
        _ = NSApplication.shared
        let crew = CrewController(art: try art())
        let now = Date()
        crew.apply(enabled: true, perSide: 3, skin: .glass, sharingType: .readOnly)
        crew.relayout(metrics: m14)
        crew.refresh(DemoData.sessions(now: now, overflow: false), now: now)
        crew.menuBarRead(pid: 1, end: 592)
        XCTAssertEqual(crew.layout.leftSlots, 1)
        // 16 寸：刘海左缘在 771，同样排到 592 的菜单离刘海远得多
        let m16 = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), auxiliaryTopLeftWidth: 771, auxiliaryTopRightWidth: 772, safeAreaTop: 32)
        crew.relayout(metrics: m16)
        XCTAssertEqual(crew.room, CrewRoom(left: 5, right: .max))
        XCTAssertEqual(crew.layout.leftSlots, 3, "换屏当场按新的刘海位置重排")
        XCTAssertEqual(crew.layout.overflow, 0)

        crew.apply(enabled: false, perSide: 3, skin: .glass, sharingType: .readOnly)
        crew.menuBarRead(pid: 1, end: 700)
        XCTAssertNil(crew.room, "关掉开关后在途的读取回来了：不写回去")
    }

    /// 「左边放不下时挪到右边」开着：左翼缩到一格，右翼接走其余五个，开关一拨当场重排。
    @MainActor
    func testSpillRightWidensTheRightWingInsteadOfFolding() throws {
        _ = NSApplication.shared
        let crew = CrewController(art: try art())
        let now = Date()
        crew.apply(enabled: true, perSide: 3, skin: .glass, sharingType: .readOnly, spillRight: true)
        crew.relayout(metrics: m14)
        crew.refresh(DemoData.sessions(now: now, overflow: false), now: now)
        defer { crew.apply(enabled: false, perSide: 3, skin: .glass, sharingType: .readOnly) }
        let right = try XCTUnwrap(crew.wing(.right)), left = try XCTUnwrap(crew.wing(.left))
        XCTAssertEqual(right.frame.width, 121, "菜单没挤过来：照旧三格")

        crew.menuBarRead(pid: 1, end: 592)
        XCTAssertEqual(left.frame, CGRect(x: 616, y: 950, width: 59, height: 32))
        XCTAssertEqual(right.frame, CGRect(x: 836, y: 950, width: 183, height: 32), "右翼五格")
        XCTAssertEqual(crew.layout.overflow, 0, "六个都在")

        crew.apply(enabled: true, perSide: 3, skin: .glass, sharingType: .readOnly, spillRight: false)
        XCTAssertEqual(right.frame.width, 121, "关掉开关：右翼回到上限，多的折进胶囊")
        XCTAssertEqual(crew.layout.overflow, 3)
    }

    /// 注入的函数真的被问到：有项目可画时自己起一轮，在后台队列问完回主线程重排。
    @MainActor
    func testWingsMeasureTheMenuBarOwnerOnTheirOwn() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSWorkspace.shared.menuBarOwningApplication == nil, "没有图形会话：菜单栏没有属主，问不到谁")
        let crew = CrewController(art: try art(), menuEnd: { _ in 592 })
        let now = Date()
        crew.apply(enabled: true, perSide: 3, skin: .glass, sharingType: .readOnly)
        crew.relayout(metrics: m14)
        defer { crew.apply(enabled: false, perSide: 3, skin: .glass, sharingType: .readOnly) }
        crew.refresh(DemoData.sessions(now: now, overflow: false), now: now)
        let deadline = Date().addingTimeInterval(3)
        while crew.room == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(crew.room, CrewRoom(left: 1, right: .max))
        XCTAssertEqual(crew.layout.leftSlots, 1)
    }

    /// 切 app 那一刻读不到（菜单栏还没换属主、app 刚启动）：半秒后补量一次，不等 2 秒那一轮。
    /// 名册空着所以 2 秒的定时器没起，量到只能靠切 app 的通知。按时间而不是按次数放行：跑测试时人在真切 app，次数说不准。
    @MainActor
    func testActivationMeasuresAgainHalfASecondLater() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSWorkspace.shared.menuBarOwningApplication == nil, "没有图形会话：菜单栏没有属主，问不到谁")
        let ready = OSAllocatedUnfairLock(initialState: false)
        let crew = CrewController(art: try art(), menuEnd: { _ in ready.withLock { $0 } ? 592 : nil })
        crew.apply(enabled: true, perSide: 3, skin: .glass, sharingType: .readOnly)
        crew.relayout(metrics: m14)
        defer { crew.apply(enabled: false, perSide: 3, skin: .glass, sharingType: .readOnly) }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertNil(crew.room, "当场那一次没读到：这一轮不算")
        ready.withLock { $0 = true }
        let deadline = Date().addingTimeInterval(1.5)
        while crew.room == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(crew.room, CrewRoom(left: 1, right: .max), "半秒后补量到了")
    }

    @MainActor
    func testOverflowCapsuleAndDonePlayback() throws {
        _ = NSApplication.shared
        let crew = CrewController(art: try art())
        let now = Date()
        crew.apply(enabled: true, perSide: 3, skin: .gradient, sharingType: .none)
        crew.relayout(metrics: m14)
        defer { crew.apply(enabled: false, perSide: 3, skin: .glass, sharingType: .readOnly) }
        var seen: [[String]] = []
        crew.rosterChanged = { seen.append($0.map(\.id)) }
        crew.refresh(DemoData.sessions(now: now, overflow: true), now: now)
        XCTAssertEqual(crew.layout.overflow, 3)
        XCTAssertEqual(crew.layout.leftSlots, 3)
        XCTAssertEqual(crew.wing(.left)?.frame.width, 121)
        XCTAssertEqual(crew.wing(.right)?.sharingType, NSWindow.SharingType.none)
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].count, 8)

        // 同一批会话再来一次名册不变、回调照发；mood 没变的槽时间原点不动
        crew.refresh(DemoData.sessions(now: now, overflow: true), now: now.addingTimeInterval(5))
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(crew.clockInterval, 0.05, "两翼在屏上就走 20 fps 的表")
        crew.setHidden(true)
        XCTAssertNil(crew.clockInterval, "藏起来就停表")
    }

    /// 翼重建（名册刷新、撤下再回来）后光标还停在原来那格：下一次移动照样报，不被「和上次一样」吞掉。
    @MainActor
    func testStripReportsTheSameSlotAgainAfterRebuild() {
        _ = NSApplication.shared
        let panel = CrewPanel(side: .right)
        panel.setFrame(CGRect(x: 0, y: 0, width: 109, height: 32), display: false)
        let now = Date()
        let slots = (0..<3).map { index in
            CrewSlot(project: CrewProject(id: "claude:/p\(index)", provider: "claude", path: "/p\(index)", name: "p\(index)", sessions: [], mood: .run),
                     overflow: 0, startedAt: now, phase: 0)
        }
        var reported: [Int?] = []
        panel.strip.onHover = { reported.append($0) }
        panel.strip.configure(slots: slots, skin: .glass, size: CGSize(width: 109, height: 32))
        let move = NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 33.5, y: 16), modifierFlags: [], timestamp: 0,
                                      windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        panel.strip.mouseMoved(with: move)
        panel.strip.mouseMoved(with: move)
        XCTAssertEqual(reported, [0], "没动就不重复报")
        panel.strip.configure(slots: slots, skin: .glass, size: CGSize(width: 109, height: 32))
        panel.strip.mouseMoved(with: move)
        XCTAssertEqual(reported, [0, 0], "重建后同一格再报一次")
        panel.close()
    }

    /// 屏幕睡着时关掉开关，醒来的通知没人听；再打开不能还当它睡着。
    @MainActor
    func testSleepFlagClearsWhenCrewIsDisabled() throws {
        _ = NSApplication.shared
        let crew = CrewController(art: try art())
        let now = Date()
        crew.apply(enabled: true, perSide: 3, skin: .glass, sharingType: .readOnly)
        defer { crew.apply(enabled: false, perSide: 3, skin: .glass, sharingType: .readOnly) }
        crew.relayout(metrics: m14)
        crew.refresh(DemoData.sessions(now: now, overflow: false), now: now)
        XCTAssertEqual(crew.clockInterval, 0.05)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(crew.clockInterval, "屏幕睡了停表")
        crew.apply(enabled: false, perSide: 3, skin: .glass, sharingType: .readOnly)
        crew.apply(enabled: true, perSide: 3, skin: .glass, sharingType: .readOnly)
        crew.relayout(metrics: m14)
        crew.refresh(DemoData.sessions(now: now, overflow: false), now: now)
        XCTAssertEqual(crew.clockInterval, 0.05, "关掉再打开，表要走")
    }

    /// 位图缓存：一帧画一次，键上带套系和调色板；名册换了把不在屏上的那几套扔掉。
    @MainActor
    func testFrameCacheRendersOnceAndEvictsUnusedLooks() throws {
        let cache = CrewFrameCache(art: try art())
        let look = CrewFrameCache.Look(mood: .run, skin: .glass, cast: .ball)
        let key = CrewFrameCache.Key(clip: "crew-run", index: 10, look: look, still: false)
        let image = try XCTUnwrap(cache.image(key, scale: 2))
        XCTAssertEqual(image.width, 96)
        XCTAssertEqual(image.height, 64)
        XCTAssertTrue(cache.image(key, scale: 2) === image, "第二次直接命中")
        XCTAssertEqual(cache.count, 1)
        _ = cache.image(CrewFrameCache.Key(clip: "crew-stale", index: 0, look: .init(mood: .stale, skin: .gradient, cast: .ball), still: true), scale: 2)
        XCTAssertEqual(cache.count, 2)
        cache.keep([look])
        XCTAssertEqual(cache.count, 1, "失联那套不在屏上了就扔掉")
        XCTAssertNil(cache.image(CrewFrameCache.Key(clip: "crew-run", index: 999, look: look, still: false), scale: 2), "越界的帧不画")
        XCTAssertNil(cache.image(CrewFrameCache.Key(clip: "nope", index: 0, look: look, still: false), scale: 2))
    }

    @MainActor
    func testMissingCrewClipsKeepWingsOffWithoutCrashing() throws {
        _ = NSApplication.shared
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/bloub/frames.json"))) as? [String: Any])
        var clips = try XCTUnwrap(json["clips"] as? [String: Any])
        clips["crew-done"] = nil
        json["clips"] = clips
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bloub-no-done-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        // 缺片段整份作废（AI 页和翅膀都靠这六段）：控制器拿到 nil 不崩、不画翅膀
        let crew = CrewController(art: BloubArt(url: url))
        crew.apply(enabled: true, perSide: 3, skin: .glass, sharingType: .readOnly)
        crew.relayout(metrics: m14)
        crew.refresh(DemoData.sessions(now: Date(), overflow: false))
        XCTAssertNil(crew.wing(.right), "缺片段：翅膀不画")
    }
}

final class PanelKeyTests: XCTestCase {

    private let one = UInt16(18), five = UInt16(23), six = UInt16(22), nine = UInt16(25), zero = UInt16(29), comma = UInt16(43)

    func testDigitsSwitchPagesOnlyWhenEnabledAndUnmodified() {
        XCTAssertEqual(PanelKey.action(keyCode: one, modifiers: [], pageKeys: true, sessionKeys: false), .page(0))
        XCTAssertEqual(PanelKey.action(keyCode: nine, modifiers: [], pageKeys: true, sessionKeys: false), .page(8))
        XCTAssertEqual(PanelKey.action(keyCode: five, modifiers: [.capsLock, .numericPad], pageKeys: true, sessionKeys: false), .page(4),
                       "大写锁、小键盘标记不算按了修饰键")
        XCTAssertNil(PanelKey.action(keyCode: one, modifiers: [], pageKeys: false, sessionKeys: true), "开关关着就放过")
        XCTAssertNil(PanelKey.action(keyCode: one, modifiers: [.option], pageKeys: true, sessionKeys: true), "⌥1 不归面板")
    }

    func testCommandDigitsJumpToTenSessionsOnlyWhenEnabled() {
        XCTAssertEqual(PanelKey.action(keyCode: one, modifiers: [.command], pageKeys: true, sessionKeys: true), .session(0))
        XCTAssertEqual(PanelKey.action(keyCode: six, modifiers: [.command], pageKeys: true, sessionKeys: true), .session(5), "第 6 个会话也有键")
        XCTAssertEqual(PanelKey.action(keyCode: nine, modifiers: [.command], pageKeys: true, sessionKeys: true), .session(8))
        XCTAssertEqual(PanelKey.action(keyCode: zero, modifiers: [.command], pageKeys: true, sessionKeys: true), .session(9), "⌘0 是第 10 个")
        XCTAssertNil(PanelKey.action(keyCode: zero, modifiers: [], pageKeys: true, sessionKeys: true), "单按 0 不归面板")
        XCTAssertNil(PanelKey.action(keyCode: zero, modifiers: [.command], pageKeys: true, sessionKeys: false))
        XCTAssertNil(PanelKey.action(keyCode: one, modifiers: [.command], pageKeys: true, sessionKeys: false), "开关关着就放过")
        XCTAssertNil(PanelKey.action(keyCode: one, modifiers: [.command, .shift], pageKeys: true, sessionKeys: true))
        XCTAssertEqual(PanelKey.sessionShortcutLabel(0), "⌘1")
        XCTAssertEqual(PanelKey.sessionShortcutLabel(8), "⌘9")
        XCTAssertEqual(PanelKey.sessionShortcutLabel(9), "⌘0")
        XCTAssertNil(PanelKey.sessionShortcutLabel(10), "第 11 个起没有键")
    }

    func testTextEditingReceivesDigitsWithoutNavigating() {
        for keyCode in PanelKey.digitKeyCodes + [zero] {
            XCTAssertNil(PanelKey.action(keyCode: keyCode, modifiers: [], pageKeys: true, sessionKeys: true, editingText: true))
            XCTAssertNil(PanelKey.action(keyCode: keyCode, modifiers: [.command], pageKeys: true, sessionKeys: true, editingText: true))
        }
        XCTAssertEqual(PanelKey.action(keyCode: comma, modifiers: [.command], pageKeys: true, sessionKeys: true, editingText: true), .settings)
    }

    func testCommandCommaAlwaysOpensSettings() {
        XCTAssertEqual(PanelKey.action(keyCode: comma, modifiers: [.command], pageKeys: false, sessionKeys: false), .settings)
        XCTAssertNil(PanelKey.action(keyCode: comma, modifiers: [], pageKeys: true, sessionKeys: true), "单按逗号不管")
        XCTAssertNil(PanelKey.action(keyCode: 0, modifiers: [], pageKeys: true, sessionKeys: true), "别的键放过")
    }
}
