import Darwin
import XCTest
@testable import Tally

private final class CapturingOverrideIO: DisplayOverrideIO, @unchecked Sendable {
    var command = ""
    func read(_ url: URL) throws -> Data? { nil }
    func authorize(_ shell: String) throws {
        command = shell
        throw DisplayFailure("intercepted before root write")
    }
}

private final class ExecutingOverrideIO: DisplayOverrideIO, @unchecked Sendable {
    var stopAfterBackup = false
    var beforeRun: (() -> Void)?
    func read(_ url: URL) throws -> Data? { try SystemDisplayOverrideIO().read(url) }
    func authorize(_ shell: String) throws {
        beforeRun?()
        var script = shell
        if stopAfterBackup {
            let lines = shell.components(separatedBy: "\n")
            let secondStage = lines.indices.filter { lines[$0].hasPrefix("stage=$(") }.dropFirst().first
            guard let secondStage else { throw DisplayFailure("test script boundary missing") }
            script = lines[..<secondStage].joined(separator: "\n")
        }
        let result = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script], deadline: 10)
        guard result.status == 0, !result.timedOut else {
            throw DisplayFailure("temp root script rejected: \(String(decoding: result.stderr, as: UTF8.self))")
        }
        if stopAfterBackup { throw DisplayFailure("simulated interruption after backup") }
    }
}

@MainActor
private struct FixedOverrideDriver: DisplayDriving {
    let screen: DisplaySnapshot
    func snapshots() throws -> [DisplaySnapshot] { [screen] }
    func commit(uuid: String, mode: DisplayModeSelection) throws { XCTFail("override must not switch modes") }
}

@MainActor
final class HiDPIOverrideTests: XCTestCase {
    private let native = DisplayModeSelection(width: 3440, height: 1440,
        pixelWidth: 3440, pixelHeight: 1440, refreshRate: 60)

    private func screen() -> DisplaySnapshot {
        DisplaySnapshot(id: "UUID", name: "L34W-4C", vendor: 0x30ae, product: 0x68f0,
            builtin: false, mirrored: false, current: native, modes: [native])
    }

    private func temporaryRoot() -> URL {
        let path = FileManager.default.temporaryDirectory.path
        guard let pointer = realpath(path, nil) else { fatalError("temporary directory must resolve") }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
            .appendingPathComponent("tally-hidpi-\(UUID().uuidString)")
    }

    func testEntryUsesBigEndianDoubledPixelsAndRejectsWrongAspect() throws {
        let service = HiDPIOverrideService()
        let entries = try service.preview(screen(), sizes: [HiDPISize("2580x1080")])
        XCTAssertEqual(entries, [Data([0, 0, 0x14, 0x28, 0, 0, 0x08, 0x70])])
        XCTAssertThrowsError(try service.preview(screen(), sizes: [HiDPISize("2580x1200")]))
        XCTAssertThrowsError(try HiDPISize("٢٥٨٠x1080"))
    }

    func testNoNativeOneTimesModeRejectsGeneration() throws {
        var scaled = screen()
        scaled.modes = [DisplayModeSelection(width: 2580, height: 1080,
            pixelWidth: 5160, pixelHeight: 2160, refreshRate: 100)]
        XCTAssertThrowsError(try HiDPIOverrideService().preview(scaled,
            sizes: [HiDPISize("2580x1080")]))
    }

    func testRootScriptChecksPathsAndHashesBeforeEachWrite() async throws {
        let io = CapturingOverrideIO()
        let base = temporaryRoot()
        let service = HiDPIOverrideService(overrides: base.appendingPathComponent("Overrides"),
            backups: base.appendingPathComponent("MacHiDPI"), io: io,
            driver: FixedOverrideDriver(screen: screen()))
        do { try await service.install(screen(), sizes: [HiDPISize("2580x1080")]); XCTFail("expected injected stop") }
        catch { XCTAssertTrue(error.localizedDescription.contains("intercepted")) }
        XCTAssertTrue(io.command.contains("test ! -L"))
        XCTAssertTrue(io.command.contains("test ! -e"))
        XCTAssertEqual(io.command.components(separatedBy: "test ! -e").count - 1, 3,
            "both absent paths are checked first and the target is checked again before its write")
        XCTAssertTrue(io.command.contains("/usr/bin/shasum -a 256"),
            "the newly written backup is checked by hash before the target write")
        XCTAssertTrue(io.command.contains("backup.plist"))
        XCTAssertTrue(io.command.contains("DisplayProductID-68f0"))
    }

    func testTempScriptPreservesOriginalAcrossRepeatAndRestoresWithArchive() async throws {
        let io = ExecutingOverrideIO()
        let base = temporaryRoot()
        let service = HiDPIOverrideService(overrides: base.appendingPathComponent("Overrides"),
            backups: base.appendingPathComponent("MacHiDPI"), io: io,
            driver: FixedOverrideDriver(screen: screen()))
        try await service.install(screen(), sizes: [HiDPISize("2580x1080")])
        let target = base.appendingPathComponent("Overrides/DisplayVendorID-30ae/DisplayProductID-68f0")
        let backup = base.appendingPathComponent("MacHiDPI/30ae-68f0/backup.plist")
        let first = try Data(contentsOf: target)
        let firstState = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: backup),
            format: nil) as? [String: Any])
        XCTAssertEqual(firstState["originalExists"] as? Bool, false)
        try await service.install(screen(), sizes: [HiDPISize("2752x1152")])
        let secondState = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: backup),
            format: nil) as? [String: Any])
        XCTAssertEqual(secondState["originalExists"] as? Bool, false)
        XCTAssertEqual(secondState["previousInstalled"] as? Data, first)
        try await service.restore(screen())
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let archives = try FileManager.default.contentsOfDirectory(atPath: backup.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("last-installed.") }
        XCTAssertEqual(archives.count, 1)
    }

    func testTempScriptPreservesExactOriginalBytesAndExternalKeys() async throws {
        let io = ExecutingOverrideIO()
        let base = temporaryRoot()
        let target = base.appendingPathComponent("Overrides/DisplayVendorID-30ae/DisplayProductID-68f0")
        let backup = base.appendingPathComponent("MacHiDPI/30ae-68f0/backup.plist")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = try PropertyListSerialization.data(fromPropertyList:
            ["external-name": "keep this", "scale-resolutions": [Data([1, 2, 3, 4, 5, 6, 7, 8])]],
            format: .binary, options: 0)
        try original.write(to: target)
        let service = HiDPIOverrideService(overrides: base.appendingPathComponent("Overrides"),
            backups: base.appendingPathComponent("MacHiDPI"), io: io,
            driver: FixedOverrideDriver(screen: screen()))
        try await service.install(screen(), sizes: [HiDPISize("2580x1080")])
        let firstState = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: backup),
            format: nil) as? [String: Any])
        XCTAssertEqual(firstState["originalExists"] as? Bool, true)
        XCTAssertEqual(firstState["original"] as? Data, original)
        let firstInstalled = try Data(contentsOf: target)
        let merged = try XCTUnwrap(PropertyListSerialization.propertyList(from: firstInstalled, format: nil) as? [String: Any])
        XCTAssertEqual(merged["external-name"] as? String, "keep this")
        try await service.install(screen(), sizes: [HiDPISize("2752x1152")])
        let secondState = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: backup),
            format: nil) as? [String: Any])
        XCTAssertEqual(secondState["original"] as? Data, original)
        XCTAssertEqual(secondState["previousInstalled"] as? Data, firstInstalled)
        try await service.restore(screen())
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testTempScriptRejectsConcurrentHashChangeAndSymlink() async throws {
        let io = ExecutingOverrideIO()
        let base = temporaryRoot()
        let target = base.appendingPathComponent("Overrides/DisplayVendorID-30ae/DisplayProductID-68f0")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = try PropertyListSerialization.data(fromPropertyList: ["name": "original"], format: .xml, options: 0)
        try original.write(to: target)
        let service = HiDPIOverrideService(overrides: base.appendingPathComponent("Overrides"),
            backups: base.appendingPathComponent("MacHiDPI"), io: io,
            driver: FixedOverrideDriver(screen: screen()))
        io.beforeRun = { try? Data("external change".utf8).write(to: target) }
        do { try await service.install(screen(), sizes: [HiDPISize("2580x1080")]); XCTFail("expected hash rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("rejected")) }
        XCTAssertEqual(try Data(contentsOf: target), Data("external change".utf8))
        io.beforeRun = nil
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: base.appendingPathComponent("outside"))
        do { try await service.install(screen(), sizes: [HiDPISize("2580x1080")]); XCTFail("expected symlink rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("软链接")) }
    }

    func testInterruptedRepeatLeavesPreviousInstalledRecoverable() async throws {
        let io = ExecutingOverrideIO()
        let base = temporaryRoot()
        let service = HiDPIOverrideService(overrides: base.appendingPathComponent("Overrides"),
            backups: base.appendingPathComponent("MacHiDPI"), io: io,
            driver: FixedOverrideDriver(screen: screen()))
        try await service.install(screen(), sizes: [HiDPISize("2580x1080")])
        let target = base.appendingPathComponent("Overrides/DisplayVendorID-30ae/DisplayProductID-68f0")
        let first = try Data(contentsOf: target)
        io.stopAfterBackup = true
        do { try await service.install(screen(), sizes: [HiDPISize("2752x1152")]); XCTFail("expected interruption") }
        catch { XCTAssertTrue(error.localizedDescription.contains("interruption")) }
        XCTAssertEqual(try Data(contentsOf: target), first)
        io.stopAfterBackup = false
        try await service.restore(screen())
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
}
