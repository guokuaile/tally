import Foundation
import XCTest
@testable import Tally
import TallyWallpaperKit

private final class WallpaperHarness {
    let home = URL(fileURLWithPath: "/private/tmp/tally-service-\(UUID().uuidString.prefix(8))")
    var paths: WallpaperPaths { WallpaperPaths(root: home.appendingPathComponent("Support")) }
    var oldLoaded = false
    var newLoaded = false
    var disabled = false
    var oldAlive = false
    var newAlive = false
    var delayedNewExit = 0
    var didOverlap = false
    var failOldBootstrap = false
    var waits = 0
    var healthy = true
    var failReload = false
    var calls: [[String]] = []

    init() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/LaunchAgents"), withIntermediateDirectories: true)
    }

    func config(login: Bool) throws {
        try paths.save(WallpaperConfiguration(sources: [home.path], launchAtLogin: login))
    }

    func environment() -> WallpaperEnvironment {
        WallpaperEnvironment(paths: paths, home: home,
            binary: { self.home.appendingPathComponent("tally-wallpaper") },
            run: { args in
                self.calls.append(args)
                switch args.first {
                case "print": return args.last?.hasSuffix("com.aiden.video-wallpaper") == true ? "pid = 111\n" : "pid = 222\n"
                case "disable": self.disabled = true
                case "enable": self.disabled = false
                case "bootout":
                    if args.last?.hasSuffix("com.aiden.video-wallpaper") == true { self.oldLoaded = false; self.oldAlive = false }
                    else { self.newLoaded = false; if self.delayedNewExit == 0 { self.newAlive = false } }
                case "bootstrap":
                    if args.last?.contains("video-wallpaper") == true {
                        if self.failOldBootstrap { throw WallpaperError.unavailable("old bootstrap failed") }
                        self.didOverlap = self.didOverlap || self.newAlive
                        self.oldLoaded = true; self.oldAlive = true
                    } else { self.newLoaded = true; self.newAlive = true }
                default: break
                }
                return ""
            },
            loaded: { label in label == "com.aiden.video-wallpaper" ? self.oldLoaded : self.newLoaded },
            disabled: { self.disabled },
            send: { command, _ in
                guard self.newLoaded else { throw WallpaperError.unavailable("not running") }
                if command == .reload && self.failReload { self.failReload = false; throw WallpaperError.unavailable("reload failed") }
                guard self.healthy else { throw WallpaperError.unavailable("not ready") }
                return WallpaperStatus(pid: 222, playing: true, paused: false, currentItem: self.home.appendingPathComponent("a.jpg").path, itemCount: 1, error: nil)
            },
            alive: { pid in pid == 111 ? self.oldAlive : self.newAlive },
            wait: { _ in
                self.waits += 1
                if !self.newLoaded && self.delayedNewExit > 0 {
                    self.delayedNewExit -= 1
                    if self.delayedNewExit == 0 { self.newAlive = false }
                }
            }
        )
    }
}

final class WallpaperServiceTests: XCTestCase {
    func testCheckingLoginWhileStoppedCreatesAgentWithoutStarting() throws {
        let h = try WallpaperHarness(); defer { try? FileManager.default.removeItem(at: h.home) }
        try h.config(login: false)
        let env = h.environment()
        XCTAssertNil(try WallpaperService.saveSync(WallpaperConfiguration(sources: [h.home.path], launchAtLogin: true), environment: env))
        let data = try Data(contentsOf: env.loginAgent)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, "com.aiden.tally.wallpaper")
        XCTAssertFalse(h.newLoaded)
        XCTAssertFalse(h.calls.contains { $0.first == "bootstrap" })
    }
    func testUncheckingLoginWhileStoppedRemovesLoginAgent() throws {
        let h = try WallpaperHarness(); defer { try? FileManager.default.removeItem(at: h.home) }
        try h.config(login: true)
        let env = h.environment()
        try Data("old agent".utf8).write(to: env.loginAgent)
        let result = try WallpaperService.saveSync(WallpaperConfiguration(sources: [h.home.path], launchAtLogin: false), environment: env)
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.loginAgent.path))
        XCTAssertFalse(try h.paths.load().launchAtLogin)
    }

    func testReloadFailureRestoresPersistedConfigAndLoginEntry() throws {
        let h = try WallpaperHarness(); defer { try? FileManager.default.removeItem(at: h.home) }
        try h.config(login: true)
        let env = h.environment()
        let originalConfig = try Data(contentsOf: h.paths.configuration)
        let originalLogin = Data("old agent".utf8)
        try originalLogin.write(to: env.loginAgent)
        h.newLoaded = true; h.failReload = true
        XCTAssertThrowsError(try WallpaperService.saveSync(WallpaperConfiguration(sources: [h.home.path], slotSeconds: 90, launchAtLogin: false), environment: env))
        XCTAssertEqual(try Data(contentsOf: h.paths.configuration), originalConfig)
        XCTAssertEqual(try Data(contentsOf: env.loginAgent), originalLogin)
    }

    func testFailedTakeoverRestoresOldJobAndFiles() throws {
        let h = try WallpaperHarness(); defer { try? FileManager.default.removeItem(at: h.home) }
        try h.config(login: true)
        let env = h.environment()
        try Data("legacy".utf8).write(to: env.oldAgent)
        let originalLogin = Data("prior login".utf8)
        let originalMigration = Data("prior migration".utf8)
        try originalLogin.write(to: env.loginAgent)
        try originalMigration.write(to: h.paths.migration)
        h.oldLoaded = true; h.oldAlive = true; h.healthy = false
        XCTAssertThrowsError(try WallpaperService.startSync(environment: env))
        XCTAssertTrue(h.oldLoaded)
        XCTAssertFalse(h.newLoaded)
        XCTAssertFalse(h.disabled)
        XCTAssertEqual(try Data(contentsOf: env.loginAgent), originalLogin)
        XCTAssertEqual(try Data(contentsOf: h.paths.migration), originalMigration)
    }

    func testRepeatedStartPreservesFirstLegacyRecord() throws {
        let h = try WallpaperHarness(); defer { try? FileManager.default.removeItem(at: h.home) }
        try h.config(login: false)
        let env = h.environment()
        try Data("legacy".utf8).write(to: env.oldAgent)
        h.oldLoaded = true; h.oldAlive = true
        _ = try WallpaperService.startSync(environment: env)
        let record = try Data(contentsOf: h.paths.migration)
        h.newLoaded = false
        _ = try WallpaperService.startSync(environment: env)
        XCTAssertEqual(try Data(contentsOf: h.paths.migration), record)
    }

    func testStalledIPCWaitsForRealNewPIDBeforeRestoringOld() throws {
        let h = try WallpaperHarness(); defer { try? FileManager.default.removeItem(at: h.home) }
        try h.config(login: false)
        let env = h.environment()
        try Data("legacy".utf8).write(to: env.oldAgent)
        h.oldLoaded = true; h.oldAlive = true; h.healthy = false; h.delayedNewExit = 3
        XCTAssertThrowsError(try WallpaperService.startSync(environment: env))
        XCTAssertTrue(h.oldLoaded)
        XCTAssertFalse(h.didOverlap)
        XCTAssertGreaterThan(h.waits, 40)
        XCTAssertTrue(h.calls.contains { $0.first == "print" && $0.last?.hasSuffix("com.aiden.tally.wallpaper") == true })
    }

    func testUnconfirmedNewExitDoesNotStartOld() throws {
        let h = try WallpaperHarness(); defer { try? FileManager.default.removeItem(at: h.home) }
        try h.config(login: false)
        let env = h.environment()
        try Data("legacy".utf8).write(to: env.oldAgent)
        h.oldLoaded = true; h.oldAlive = true; h.healthy = false; h.delayedNewExit = 100
        XCTAssertThrowsError(try WallpaperService.startSync(environment: env))
        XCTAssertFalse(h.oldLoaded)
        XCTAssertFalse(h.didOverlap)
        XCTAssertFalse(h.calls.contains { $0.first == "bootstrap" && $0.last == env.oldAgent.path })
    }

    func testLoadedDisabledOldJobRestoresBothLoadedAndDisabled() throws {
        let h = try WallpaperHarness(); defer { try? FileManager.default.removeItem(at: h.home) }
        try h.config(login: false)
        let env = h.environment()
        try Data("legacy".utf8).write(to: env.oldAgent)
        h.oldLoaded = true; h.oldAlive = true; h.disabled = true; h.healthy = false
        XCTAssertThrowsError(try WallpaperService.startSync(environment: env))
        XCTAssertTrue(h.oldLoaded)
        XCTAssertTrue(h.disabled)
        XCTAssertFalse(h.didOverlap)
    }

    private func writeMigration(_ h: WallpaperHarness, oldPath: String) throws {
        try h.paths.prepare()
        let object: [String: Any] = ["wasLoaded": true, "wasDisabled": false, "plistPath": oldPath]
        try JSONSerialization.data(withJSONObject: object).write(to: h.paths.migration)
    }

    func testRestoreLegacyMissingPlistLeavesNewPlayerUntouched() throws {
        let h = try WallpaperHarness(); defer { try? FileManager.default.removeItem(at: h.home) }
        let env = h.environment()
        try writeMigration(h, oldPath: env.oldAgent.path)
        h.newLoaded = true; h.newAlive = true
        XCTAssertThrowsError(try WallpaperService.restoreLegacySync(environment: env))
        XCTAssertTrue(h.newLoaded)
        XCTAssertTrue(h.newAlive)
        XCTAssertTrue(h.calls.isEmpty)
    }

    func testRestoreLegacyFailedBootstrapRollsBackNewPlayer() throws {
        let h = try WallpaperHarness(); defer { try? FileManager.default.removeItem(at: h.home) }
        let env = h.environment()
        let plist: [String: Any] = ["Label": "com.aiden.video-wallpaper", "ProgramArguments": ["/bin/echo", "run"]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: env.oldAgent)
        try writeMigration(h, oldPath: env.oldAgent.path)
        h.newLoaded = true; h.newAlive = true; h.disabled = true; h.failOldBootstrap = true
        XCTAssertThrowsError(try WallpaperService.restoreLegacySync(environment: env))
        XCTAssertTrue(h.newLoaded)
        XCTAssertTrue(h.newAlive)
        XCTAssertFalse(h.oldLoaded)
        XCTAssertTrue(h.disabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.paths.migration.path))
    }
}
