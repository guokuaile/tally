import AppKit
import XCTest
@testable import Tally

@MainActor
final class CrewLifecycleTests: XCTestCase {
    private let metrics = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), auxiliaryTopLeftWidth: 663,
                                        auxiliaryTopRightWidth: 664, safeAreaTop: 32)
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func art() throws -> BloubArt {
        try XCTUnwrap(BloubArt(url: Self.root.appendingPathComponent("Resources/bloub/frames.json")))
    }

    private func controller(reduced: Bool = false) throws -> CrewController {
        _ = NSApplication.shared
        let crew = CrewController(art: try art(), motionReduced: reduced)
        crew.apply(enabled: true, perSide: 3, skin: .glass, sharingType: .none)
        crew.relayout(metrics: metrics)
        return crew
    }

    private func close(_ crew: CrewController) { crew.apply(enabled: false, perSide: 3, skin: .glass, sharingType: .none) }

    func testArrivalDoesNotReplayOnRefreshAndClickDispatchesImmediately() throws {
        let crew = try controller()
        defer { close(crew) }
        let now = Date()
        let record = DemoData.sessions(now: now, overflow: false)[0]
        crew.refresh([record], now: now)
        let wing = try XCTUnwrap(crew.wing(.right) as? CrewPanel)
        let arriving = try XCTUnwrap(wing.strip.layer?.sublayers?.first { $0.animation(forKey: "arrival") != nil })
        let originalStart = arriving.animation(forKey: "arrival")?.beginTime
        crew.refresh([record], now: now.addingTimeInterval(0.1))
        XCTAssertTrue(wing.strip.layer?.sublayers?.contains { $0 === arriving } == true)
        XCTAssertEqual(arriving.animation(forKey: "arrival")?.beginTime, originalStart)
        var clicks = 0
        crew.onClick = { _ in clicks += 1 }
        wing.strip.click(0)
        XCTAssertEqual(clicks, 1, "Animation must never postpone the original action")
        XCTAssertNotNil(arriving.animation(forKey: "click"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        crew.refresh([record], now: now.addingTimeInterval(1))
        XCTAssertNil(arriving.animation(forKey: "arrival"), "An ordinary snapshot must not reintroduce entry")
    }

    func testRealDepartureSurvivesWingRemovalWithoutKeepingAClickTarget() throws {
        let crew = try controller()
        defer { close(crew) }
        let now = Date()
        var record = DemoData.sessions(now: now, overflow: false)[0]
        crew.refresh([record], now: now)
        record.state = .ended
        crew.refresh([record], now: now.addingTimeInterval(1))
        XCTAssertTrue(crew.projects.isEmpty)
        XCTAssertFalse(crew.wing(.right)?.isVisible ?? true)
        let leaving = try XCTUnwrap(crew.departureWindows.first)
        XCTAssertTrue(leaving.isVisible)
        XCTAssertTrue(leaving.ignoresMouseEvents)
        XCTAssertFalse(leaving.canBecomeKey)
        XCTAssertEqual(leaving.sharingType, .none)
        NotchPanel.steppingAside { XCTAssertEqual(leaving.level, .normal) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(crew.departureWindows.isEmpty)
        XCTAssertFalse(leaving.isVisible)
    }

    func testClickRemainsVisibleWhenOriginalActionImmediatelyHidesItsSource() throws {
        let crew = try controller()
        defer { close(crew) }
        let record = DemoData.sessions(now: Date(), overflow: false)[0]
        crew.refresh([record])
        let wing = try XCTUnwrap(crew.wing(.right) as? CrewPanel)
        var clicks = 0
        crew.onClick = { _ in clicks += 1; crew.setHidden(true) }
        wing.strip.click(0)
        XCTAssertEqual(clicks, 1)
        XCTAssertFalse(wing.isVisible)
        let response = try XCTUnwrap(crew.clickWindow)
        XCTAssertTrue(response.isVisible)
        XCTAssertTrue(response.ignoresMouseEvents)
        XCTAssertGreaterThan(response.level.rawValue, (NSWindow.Level.mainMenu + 3).rawValue)
        XCTAssertEqual(response.sharingType, .none)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(crew.clickWindow)
        XCTAssertFalse(response.isVisible)
    }

    func testDropdownSelectionRespondsAtVisibleAvatarAndDispatchesWithoutDelay() throws {
        let crew = try controller()
        defer { close(crew) }
        let record = DemoData.sessions(now: Date(), overflow: false)[0]
        crew.refresh([record])
        let wing = try XCTUnwrap(crew.wing(.right) as? CrewPanel)
        let slot = try XCTUnwrap(wing.strip.slots.first)
        let hover = CrewHover(side: .right, index: 0, slot: slot)
        crew.setExpanded(hover)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let avatar = try XCTUnwrap(crew.avatarWindow)
        let frame = avatar.frame
        var selected: String?
        crew.onSessionClick = { session in selected = session.sessionId; crew.setExpanded(nil) }
        crew.select(record, from: hover)
        XCTAssertEqual(selected, record.sessionId)
        XCTAssertFalse(avatar.isVisible)
        XCTAssertTrue(crew.clickWindow?.isVisible == true)
        XCTAssertEqual(crew.clickWindow?.frame, frame)
        crew.setHidden(true)
        XCTAssertNil(crew.clickWindow)
    }

    func testMissingSnapshotIsNotDepartureButConfirmedOneShotEndIs() throws {
        let crew = try controller()
        defer { close(crew) }
        let record = DemoData.sessions(now: Date(), overflow: false)[0]
        crew.refresh([record])
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        crew.refresh([])
        XCTAssertTrue(crew.departureWindows.isEmpty, "An unreadable or missing file must not play farewell")
        crew.refresh([record])
        let wing = try XCTUnwrap(crew.wing(.right) as? CrewPanel)
        XCTAssertFalse(wing.strip.layer?.sublayers?.contains { $0.animation(forKey: "arrival") != nil } ?? true,
                       "Recovering a transiently missing snapshot must not replay entry")
        var ended = record
        ended.state = .ended
        crew.observeClosures([ended])
        crew.refresh([])
        XCTAssertEqual(crew.departureWindows.count, 1, "A confirmed end removed from history still plays farewell")
        crew.refresh([record])
        XCTAssertTrue(wing.strip.layer?.sublayers?.contains { $0.animation(forKey: "arrival") != nil } == true,
                      "Reopening after confirmed closure is a real entry")
        crew.refresh([])
        XCTAssertTrue(crew.departureWindows.isEmpty, "A prior one-shot end cannot close a reopened session")
    }

    func testHiddenMenuAndReducedMotionNeverRetainDepartureWindows() throws {
        let now = Date()
        let records = DemoData.sessions(now: now, overflow: false)
        let crew = try controller()
        defer { close(crew) }
        crew.refresh(records, now: now)
        crew.menuBarRead(pid: 1, end: 700)
        XCTAssertTrue(crew.departureWindows.isEmpty, "Menu occlusion is not a project exit")
        crew.menuBarRead(pid: 1, end: 100)
        let ended = records.map { record in var ended = record; ended.state = .ended; return ended }
        crew.refresh(ended, now: now.addingTimeInterval(1))
        XCTAssertFalse(crew.departureWindows.isEmpty)
        crew.setHidden(true)
        XCTAssertTrue(crew.departureWindows.isEmpty)
        crew.setHidden(false)
        crew.refresh(records, now: now.addingTimeInterval(2))
        crew.refresh(ended, now: now.addingTimeInterval(3))
        crew.relayout(metrics: nil)
        XCTAssertTrue(crew.departureWindows.isEmpty)

        let still = try controller(reduced: true)
        defer { close(still) }
        still.refresh([records[0]], now: now)
        let wing = try XCTUnwrap(still.wing(.right) as? CrewPanel)
        XCTAssertFalse(wing.strip.layer?.sublayers?.contains { $0.animation(forKey: "arrival") != nil } ?? true)
        var clicked = false
        still.onClick = { _ in clicked = true }
        wing.strip.click(0)
        XCTAssertTrue(clicked)
        XCTAssertFalse(wing.strip.layer?.sublayers?.contains { $0.animation(forKey: "click") != nil } ?? true)
        still.refresh([], now: now.addingTimeInterval(1))
        XCTAssertTrue(still.departureWindows.isEmpty)
        XCTAssertNil(still.clockInterval)
    }

    func testMissingProjectForgetsIdentityAfterAllSessionsCloseAcrossSnapshots() throws {
        let crew = try controller()
        defer { close(crew) }
        let record = DemoData.sessions(now: Date(), overflow: false)[0]
        var sibling = record
        sibling.sessionId += "-sibling"
        crew.refresh([record, sibling])
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        crew.refresh([])
        var ended = record
        ended.state = .ended
        crew.observeClosures([ended])
        crew.refresh([])
        sibling.state = .ended
        crew.observeClosures([sibling])
        crew.refresh([])
        crew.refresh([record])
        let wing = try XCTUnwrap(crew.wing(.right) as? CrewPanel)
        XCTAssertTrue(wing.strip.layer?.sublayers?.contains { $0.animation(forKey: "arrival") != nil } == true)
    }

    func testWakeIsRecordedOnceAndWaitsForAVisibleFace() throws {
        let crew = try controller()
        defer { close(crew) }
        let now = Date()
        var record = DemoData.sessions(now: now, overflow: false)[0]
        record.state = .running
        record.updatedAt = now.addingTimeInterval(-10800).timeIntervalSince1970 * 1000
        crew.refresh([record], now: now)
        record.updatedAt = now.timeIntervalSince1970 * 1000
        crew.refresh([record], now: now)
        let wing = try XCTUnwrap(crew.wing(.right) as? CrewPanel)
        XCTAssertEqual(wing.strip.slots.first?.wokeAt, now)
        crew.refresh([record], now: now.addingTimeInterval(0.1))
        XCTAssertEqual(wing.strip.slots.first?.wokeAt, now)

        let art = try art()
        for mood in [CrewMood.run, .input, .permission, .done, .compacting] {
            let clip = try XCTUnwrap(art.clips[mood.clip])
            for phase in [0.0, 0.41, 1.64, 3.5] {
                var found = false
                for step in 0..<Int((clip.duration + 1) * clip.fps) {
                    let age = Double(step) / clip.fps
                    if let wake = CrewPlayback.wakeMotion(mood: mood, tier: .fresh, elapsed: age, phase: phase, still: false, art: art) {
                        found = true
                        XCTAssertEqual(wake.kind, .wake)
                        let frame = clip.frames[clip.index(at: age + phase, loop: true)]
                        XCTAssertEqual(frame.eyeSpecs.count, 2)
                        XCTAssertGreaterThan(frame.fit.sx, 0.6)
                    }
                }
                XCTAssertTrue(found, "\(mood) phase \(phase)")
                XCTAssertNil(CrewPlayback.wakeMotion(mood: mood, tier: .fresh, elapsed: 0.4, phase: phase, still: true, art: art))
            }
        }
    }

    func testFrameCacheIsBoundedAcrossLongRunningVariantCycles() throws {
        let art = try art()
        let cast = CastArt(directory: Self.root.appendingPathComponent("Resources/cast"))
        let cache = CrewFrameCache(art: art, cast: cast)
        let clip = try XCTUnwrap(art.clips["crew-run"])
        let look = CrewFrameCache.Look(mood: .run, skin: .glass, cast: .ball)
        for index in 0..<(CrewFrameCache.capacity + 24) {
            let key = CrewFrameCache.Key(clip: "crew-run", index: index % clip.frames.count, look: look, still: false,
                motion: .init(kind: .think, step: index / (clip.frames.count * 5), variant: (index / clip.frames.count) % 5))
            XCTAssertNotNil(cache.image(key, scale: 2))
        }
        XCTAssertEqual(cache.count, CrewFrameCache.capacity)
        cache.keep([])
        XCTAssertEqual(cache.count, 0)
    }
}
