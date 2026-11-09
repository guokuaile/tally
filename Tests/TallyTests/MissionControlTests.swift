import XCTest
@testable import Tally

@MainActor
final class MissionControlTests: XCTestCase {
    private typealias Window = FullScreenDetector.Window
    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testOverviewRequiresBothFullScreenSystemWindowsOnSameDisplay() {
        let dock = Window(pid: 1, layer: 20, bounds: display)
        let manager = Window(pid: 2, layer: 19, bounds: display)
        func visible(_ windows: [Window]) -> Bool {
            MissionControl.isVisible(windows: windows, display: display, dockPID: 1, managerPID: 2)
        }
        XCTAssertTrue(visible([dock, manager]))
        XCTAssertFalse(visible([]))
        XCTAssertFalse(visible([dock]))
        XCTAssertFalse(visible([manager]))
        XCTAssertFalse(visible([dock, Window(pid: 3, layer: 19, bounds: display)]))
        XCTAssertFalse(visible([dock, Window(pid: 2, layer: 19, bounds: display.offsetBy(dx: 1512, dy: 0))]))
        XCTAssertFalse(visible([dock, Window(pid: 2, layer: 19, bounds: CGRect(x: 0, y: 0, width: 1512, height: 128))]))
    }

    func testNormalDesktopDoesNotLaunchOverview() async {
        var launched = false
        let control = MissionControl(inspect: { false }, launch: { launched = true; return true }, pause: { true })
        let result = await control.dismissIfVisible()
        XCTAssertTrue(result)
        XCTAssertFalse(launched)
    }

    func testCannotObserveOrConfirmExitIsReportedAsFailure() async {
        let unknown = MissionControl(inspect: { nil }, launch: { true }, pause: { true })
        let remainsVisible = MissionControl(inspect: { true }, launch: { true }, pause: { true })
        let failedLaunch = MissionControl(inspect: { true }, launch: { false }, pause: { true })
        let unknownResult = await unknown.dismissIfVisible()
        let remainsResult = await remainsVisible.dismissIfVisible()
        let failedResult = await failedLaunch.dismissIfVisible()
        XCTAssertFalse(unknownResult)
        XCTAssertFalse(remainsResult)
        XCTAssertFalse(failedResult)
    }

    func testDismissalWaitsThroughUncertainAnimationState() async {
        var observations: [Bool?] = [true, true, nil, nil, false]
        let control = MissionControl(inspect: { observations.isEmpty ? false : observations.removeFirst() },
                                     launch: { true }, pause: { true })
        let result = await control.dismissIfVisible()
        XCTAssertTrue(result)
        XCTAssertTrue(observations.isEmpty)
    }

    func testConcurrentDismissalsShareOneToggle() async {
        var visible = true
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "The first dismissal reaches the launcher")
        let control = MissionControl(inspect: { visible }, launch: {
            calls += 1
            await withCheckedContinuation { continuation in
                release = continuation
                started.fulfill()
            }
            visible = false
            return true
        }, pause: { true })
        let first = Task { await control.dismissIfVisible() }
        await fulfillment(of: [started], timeout: 2)
        guard let release else { first.cancel(); XCTFail("The launcher did not start"); return }
        let second = Task { await control.dismissIfVisible() }
        await Task.yield()
        release.resume()
        let results = await [first.value, second.value]
        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(calls, 1)
    }
}
