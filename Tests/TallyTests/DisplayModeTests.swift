import XCTest
@testable import Tally

@MainActor
private final class FakeDisplayDriver: DisplayDriving {
    var screen: DisplaySnapshot
    var commits: [DisplayModeSelection] = []
    var commitError: Error?
    var readError: Error?
    var readCount = 0
    var readErrorOnCalls: Set<Int> = []
    var commitErrorOnCalls: Set<Int> = []
    var onCommit: (() -> Void)?
    init(_ screen: DisplaySnapshot) { self.screen = screen }
    func snapshots() throws -> [DisplaySnapshot] {
        readCount += 1
        if readErrorOnCalls.contains(readCount) { throw DisplayFailure("readback failed") }
        if let readError { throw readError }
        return [screen]
    }
    func commit(uuid: String, mode: DisplayModeSelection) throws {
        commits.append(mode)
        if commitErrorOnCalls.contains(commits.count) { throw DisplayFailure("rollback denied") }
        if let commitError { throw commitError }
        screen.current = mode
        onCommit?()
    }
}

@MainActor
final class DisplayModeTests: XCTestCase {
    private let normal = DisplayModeSelection(width: 3440, height: 1440, pixelWidth: 3440,
                                              pixelHeight: 1440, refreshRate: 60)
    private let hidpi = DisplayModeSelection(width: 2580, height: 1080, pixelWidth: 5160,
                                             pixelHeight: 2160, refreshRate: 100)

    private func fixture() -> (DisplayModeService, FakeDisplayDriver, PreferencesStore, URL) {
        let screen = DisplaySnapshot(id: "AA-BB", name: "External", vendor: 0x30ae,
            product: 0x68f0, builtin: false, mirrored: false, current: normal, modes: [normal, hidpi])
        let driver = FakeDisplayDriver(screen)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("preferences.json")
        let store = PreferencesStore(url: url)
        return (DisplayModeService(driver: driver, preferences: store), driver, store, url)
    }

    func testExactModeDistinguishesHiDPIAndZeroRefresh() {
        XCTAssertFalse(normal.matches(hidpi))
        let zero = DisplayModeSelection(width: 2580, height: 1080, pixelWidth: 5160,
                                        pixelHeight: 2160, refreshRate: 0)
        XCTAssertFalse(zero.matches(hidpi))
        XCTAssertTrue(hidpi.matches(hidpi))
    }

    func testTransientReadErrorClearsAfterSuccessfulRefresh() {
        let (service, driver, _, _) = fixture()
        driver.readErrorOnCalls = [1]
        service.refresh()
        XCTAssertTrue(service.screens.isEmpty)
        XCTAssertNotNil(service.failure)
        service.refresh()
        XCTAssertEqual(service.screens.count, 1)
        XCTAssertNil(service.failure)
    }

    func testSavingTargetNeverCommitsAndApplyPersistsConfirmed() async throws {
        let (service, driver, store, url) = fixture()
        try service.saveTarget(hidpi, for: driver.screen.id)
        XCTAssertTrue(driver.commits.isEmpty)
        await service.apply(uuid: driver.screen.id)
        XCTAssertNil(service.failure)
        XCTAssertEqual(driver.commits, [hidpi])
        XCTAssertEqual(store.prefs.displayUndo[driver.screen.id]?.confirmed?.before, normal)
        XCTAssertNil(store.prefs.displayUndo[driver.screen.id]?.pending)
        let reloaded = PreferencesStore(url: url)
        XCTAssertEqual(reloaded.prefs.displayUndo[driver.screen.id]?.confirmed?.applied, hidpi)
    }

    func testUndoRequiresCurrentAppliedAndKeepsRecordOnExternalChange() async throws {
        let (service, driver, store, _) = fixture()
        try service.saveTarget(hidpi, for: driver.screen.id)
        await service.apply(uuid: driver.screen.id)
        driver.screen.current = normal
        await service.undo(uuid: driver.screen.id)
        XCTAssertEqual(driver.commits.count, 1)
        XCTAssertNotNil(store.prefs.displayUndo[driver.screen.id]?.confirmed)
        XCTAssertTrue(service.failure?.contains("已被改动") == true)
    }

    func testApplyingSelectedModeUsesSelectionAndKeepsSavedTarget() async throws {
        let (service, driver, store, _) = fixture()
        try service.saveTarget(normal, for: driver.screen.id)
        await service.apply(uuid: driver.screen.id, mode: hidpi)
        XCTAssertEqual(driver.commits, [hidpi])
        XCTAssertEqual(store.prefs.displayTargets[driver.screen.id], normal)
        XCTAssertEqual(store.prefs.displayUndo[driver.screen.id]?.confirmed?.before, normal)
        XCTAssertTrue(service.notice?.contains("已切换到") == true)
        await service.undo(uuid: driver.screen.id)
        XCTAssertEqual(driver.screen.current, normal)
        XCTAssertTrue(service.notice?.contains("已撤销") == true)
    }

    func testApplyingCurrentModeExplainsNoChangeAndPreservesUndo() async throws {
        let (service, driver, store, _) = fixture()
        await service.apply(uuid: driver.screen.id, mode: hidpi)
        let undo = store.prefs.displayUndo[driver.screen.id]
        await service.apply(uuid: driver.screen.id, mode: hidpi)
        XCTAssertEqual(driver.commits, [hidpi])
        XCTAssertEqual(store.prefs.displayUndo[driver.screen.id], undo)
        XCTAssertEqual(service.notice, "当前已是所选模式，无需切换")
        driver.commitError = DisplayFailure("拒绝")
        await service.apply(uuid: driver.screen.id, mode: normal)
        XCTAssertNil(service.notice)
        XCTAssertNotNil(service.failure)
    }

    func testCommitFailureLeavesOldConfirmedAndClearsPending() async throws {
        let (service, driver, store, _) = fixture()
        store.prefs.displayUndo[driver.screen.id] = DisplayUndoRecord(
            confirmed: DisplayUndoPoint(before: hidpi, applied: normal), pending: nil)
        try service.saveTarget(hidpi, for: driver.screen.id)
        driver.commitError = DisplayFailure("拒绝")
        await service.apply(uuid: driver.screen.id)
        XCTAssertEqual(driver.commits.count, 1)
        XCTAssertNil(store.prefs.displayUndo[driver.screen.id]?.pending)
        XCTAssertEqual(store.prefs.displayUndo[driver.screen.id]?.confirmed?.before, hidpi)
        service.refresh()
        XCTAssertTrue(service.failure?.contains("拒绝") == true,
            "the settings view refresh must not erase a failed apply message")
    }

    func testPendingRestartDoesNotAutoCommitAndOldConfirmedRemainsUsable() async throws {
        let (service, driver, store, _) = fixture()
        store.prefs.displayUndo[driver.screen.id] = DisplayUndoRecord(
            confirmed: DisplayUndoPoint(before: hidpi, applied: normal),
            pending: DisplayUndoPoint(before: normal, applied: hidpi))
        service.refresh()
        XCTAssertTrue(driver.commits.isEmpty)
        XCTAssertNil(service.undoReason(for: driver.screen))
    }

    func testExplicitRefreshClearsOldOperationFeedbackButAutomaticRefreshKeepsIt() async {
        let (service, driver, _, _) = fixture()
        driver.commitError = DisplayFailure("拒绝")
        await service.apply(uuid: driver.screen.id, mode: hidpi)
        service.refresh()
        XCTAssertNotNil(service.operationFailure)
        service.refresh(clearOperationFeedback: true)
        XCTAssertNil(service.failure)
        XCTAssertNil(service.notice)
        driver.readError = DisplayFailure("读取失败")
        service.refresh(clearOperationFeedback: true)
        XCTAssertEqual(service.refreshFailure, "读取失败")
    }

    func testReadbackFailureNeverBlindlyRollsBack() async throws {
        let (service, driver, store, _) = fixture()
        try service.saveTarget(hidpi, for: driver.screen.id)
        driver.readErrorOnCalls = [3, 4, 5]
        await service.apply(uuid: driver.screen.id)
        XCTAssertEqual(driver.commits, [hidpi], "readback errors must not cause a second display write")
        XCTAssertNotNil(store.prefs.displayUndo[driver.screen.id]?.pending)
        XCTAssertTrue(service.failure?.contains("readback failed") == true, service.failure ?? "no failure reported")
        XCTAssertTrue(service.screens.isEmpty, "failed refresh must not display stale modes")
    }

    func testThirdModeAfterCommitDoesNotOverwriteExternalChoice() async throws {
        let (service, driver, store, _) = fixture()
        let third = DisplayModeSelection(width: 1920, height: 1080, pixelWidth: 1920,
                                         pixelHeight: 1080, refreshRate: 60)
        try service.saveTarget(hidpi, for: driver.screen.id)
        driver.onCommit = { driver.screen.current = third }
        driver.readErrorOnCalls = [3]
        await service.apply(uuid: driver.screen.id)
        XCTAssertEqual(driver.commits, [hidpi])
        XCTAssertEqual(driver.screen.current, third)
        XCTAssertNotNil(store.prefs.displayUndo[driver.screen.id]?.pending)
    }

    func testConfirmationSaveFailureReportsSwitchedModeWithoutRollback() async throws {
        let (service, driver, store, url) = fixture()
        try service.saveTarget(hidpi, for: driver.screen.id)
        driver.onCommit = {
            let moved = url.deletingLastPathComponent().appendingPathComponent("old-preferences.json")
            try? FileManager.default.moveItem(at: url, to: moved)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        await service.apply(uuid: driver.screen.id)
        XCTAssertEqual(driver.commits, [hidpi])
        XCTAssertEqual(driver.screen.current, hidpi)
        XCTAssertTrue(service.failure?.contains("模式已切换，撤销记录未保存") == true)
        XCTAssertNotNil(store.prefs.displayUndo[driver.screen.id]?.pending)
    }

    func testRollbackFailureReportsBothErrorsAndRetainsPending() async throws {
        let (service, driver, store, _) = fixture()
        try service.saveTarget(hidpi, for: driver.screen.id)
        driver.readErrorOnCalls = [3]
        driver.commitErrorOnCalls = [2]
        await service.apply(uuid: driver.screen.id)
        XCTAssertEqual(driver.commits, [hidpi, normal])
        XCTAssertTrue(service.failure?.contains("readback failed") == true)
        XCTAssertTrue(service.failure?.contains("rollback denied") == true)
        XCTAssertNotNil(store.prefs.displayUndo[driver.screen.id]?.pending)
    }

    func testGateRejectsConcurrentDisplayOperations() async throws {
        let (service, driver, _, _) = fixture()
        try service.saveTarget(hidpi, for: driver.screen.id)
        try DisplayOperationGate.shared.enter()
        await service.apply(uuid: driver.screen.id)
        XCTAssertTrue(driver.commits.isEmpty)
        XCTAssertTrue(service.failure?.contains("正在进行") == true)
        DisplayOperationGate.shared.leave()
    }

}
