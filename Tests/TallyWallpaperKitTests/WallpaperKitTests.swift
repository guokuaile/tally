import Foundation
import Darwin
import XCTest
@testable import TallyWallpaperKit

final class WallpaperKitTests: XCTestCase {
    private func temporaryPaths() throws -> WallpaperPaths {
        // Darwin sun_path is 104 bytes; isolate tests beneath a short, stable path.
        let root = URL(fileURLWithPath: "/private/tmp/tw-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return WallpaperPaths(root: root)
    }

    func testConfigurationIsValidatedAndSavedAtomically() throws {
        let paths = try temporaryPaths()
        let media = paths.root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let config = WallpaperConfiguration(sources: [media.path], slotSeconds: 120, launchAtLogin: true)
        try paths.save(config)
        XCTAssertEqual(try paths.load(), config)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: paths.root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertThrowsError(try paths.save(WallpaperConfiguration(sources: [media.path], slotSeconds: 9)))
        XCTAssertEqual(try paths.load(), config)
    }

    func testPauseStateDefaultsOnlyWhenAbsentAndKeepsCorruptFile() throws {
        let paths = try temporaryPaths()
        XCTAssertFalse(try paths.loadPaused())
        let invalid = Data("not json".utf8)
        try invalid.write(to: paths.playbackState)
        XCTAssertThrowsError(try paths.loadPaused())
        XCTAssertEqual(try Data(contentsOf: paths.playbackState), invalid)
        try Data("{\"paused\":true}".utf8).write(to: paths.playbackState)
        XCTAssertTrue(try paths.loadPaused())
    }

    func testNewFilePlaysNextAndDeletedFileLeavesQueue() throws {
        let paths = try temporaryPaths()
        let a = paths.root.appendingPathComponent("a.jpg")
        let b = paths.root.appendingPathComponent("b.mp4")
        try Data().write(to: a)
        var playlist = WallpaperPlaylist(seenURL: paths.seen)
        XCTAssertEqual(try playlist.next(sources: [paths.root.path]), a)
        try Data().write(to: b)
        XCTAssertEqual(try playlist.next(sources: [paths.root.path]), b)
        try FileManager.default.removeItem(at: b)
        XCTAssertEqual(try playlist.next(sources: [paths.root.path]), a)
        XCTAssertEqual(playlist.count, 1)
    }

    func testEnumerationFailureIsNotReportedAsEmptyAndKeepsQueue() throws {
        let paths = try temporaryPaths()
        let image = paths.root.appendingPathComponent("a.jpg")
        try Data().write(to: image)
        var playlist = WallpaperPlaylist(seenURL: paths.seen)
        XCTAssertEqual(try playlist.next(sources: [paths.root.path]), image)
        let previous = playlist.last
        XCTAssertThrowsError(try playlist.next(sources: [paths.root.path], enumerate: { _ in
            throw WallpaperError.unavailable("permission denied")
        }))
        XCTAssertEqual(playlist.last, previous)
        XCTAssertEqual(playlist.count, 1)
        XCTAssertThrowsError(try WallpaperPlaylist.collect([paths.root.appendingPathComponent("missing").path]))
    }

    func testControlRejectsDuplicateAndReturnsActualReply() throws {
        let paths = try temporaryPaths()
        let expected = WallpaperStatus(pid: getpid(), playing: true, paused: false, currentItem: "/tmp/a.jpg", itemCount: 1, error: nil)
        let server = WallpaperControlServer(paths: paths) { command in
            XCTAssertEqual(command, .status)
            return WallpaperResponse(status: expected)
        }
        try server.start()
        defer { server.stop() }
        let duplicate = WallpaperControlServer(paths: paths) { _ in WallpaperResponse(status: expected) }
        XCTAssertThrowsError(try duplicate.start())
        // Server delivers the handler on the main queue, so the test must keep the run loop alive.
        let finished = expectation(description: "status reply")
        DispatchQueue.global().async {
            XCTAssertEqual(try? WallpaperClient.send(.status, paths: paths), expected)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 3)
    }

    func testDisconnectedControlFailsWithinDeadline() throws {
        let paths = try temporaryPaths()
        let start = Date()
        XCTAssertThrowsError(try WallpaperClient.send(.status, paths: paths, timeout: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testHealthAllowsPausedAndEmptyButRejectsDecodeError() {
        XCTAssertTrue(WallpaperStatus(pid: 42, playing: false, paused: true, currentItem: "/tmp/a.jpg", itemCount: 1, error: nil).isHealthy)
        XCTAssertTrue(WallpaperStatus(pid: 42, playing: false, paused: false, currentItem: nil, itemCount: 0, error: nil).isHealthy)
        XCTAssertFalse(WallpaperStatus(pid: 42, playing: false, paused: false, currentItem: nil, itemCount: 1, error: nil).isHealthy)
        XCTAssertFalse(WallpaperStatus(pid: 42, playing: false, paused: false, currentItem: nil, itemCount: 1, error: "decode failed").isHealthy)
        XCTAssertFalse(WallpaperStatus(pid: 0, playing: false, paused: false, currentItem: "/tmp/a.jpg", itemCount: 1, error: nil).isHealthy)
    }

    func testSlowSegmentedClientCannotHoldServerBeyondTotalDeadline() throws {
        let paths = try temporaryPaths()
        let expected = WallpaperStatus(pid: getpid(), playing: true, paused: false, currentItem: "/tmp/a.jpg", itemCount: 1, error: nil)
        let server = WallpaperControlServer(paths: paths) { _ in WallpaperResponse(status: expected) }
        try server.start()
        defer { server.stop() }
        let finished = expectation(description: "slow client evicted")
        DispatchQueue.global().async {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd); finished.fulfill() }
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(paths.socket.path.utf8) + [0]
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            XCTAssertEqual(result, 0)
            for _ in 0..<9 {
                var byte: UInt8 = 115
                if send(fd, &byte, 1, 0) <= 0 { break }
                Thread.sleep(forTimeInterval: 0.3)
            }
            XCTAssertEqual(try? WallpaperClient.send(.status, paths: paths, timeout: 1), expected)
        }
        wait(for: [finished], timeout: 5)
    }
}
