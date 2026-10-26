import AppKit
import XCTest
@testable import Tally

final class ShelfStoreTests: XCTestCase {

    private func temp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tally-shelf-\(UUID().uuidString)")
    }

    private func sampleFile(_ dir: URL, _ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("hello".utf8).write(to: url)
        return url
    }

    @MainActor
    func testAddCopiesAndPersistsAndRemoveDeletes() async throws {
        let root = temp()
        let source = try sampleFile(root.appendingPathComponent("src"), "a.txt")
        let store = ShelfStore(directory: root.appendingPathComponent("shelf"))
        store.setEnabled(true)
        await store.add(urls: [source, source])
        XCTAssertEqual(store.items.count, 2, "同名文件各自一个目录，不冲突")
        XCTAssertEqual(store.items.first?.name, "a.txt")
        XCTAssertEqual(store.items.first?.size, 5)
        for item in store.items {
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(item).path))
        }
        // 重开一个实例读同一目录：索引还在
        let again = ShelfStore(directory: root.appendingPathComponent("shelf"))
        again.setEnabled(true)
        XCTAssertEqual(again.items, store.items)
        let first = store.items[0]
        store.remove(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(first).path))
        XCTAssertEqual(store.items.count, 1)
        store.clear()
        XCTAssertTrue(store.items.isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testAutomaticScreenshotAndManualDropShareOneSource() async throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try sampleFile(root.appendingPathComponent("src"), "shot.png")
        for (index, order) in [[ShelfKind.screenshot, .file], [.file, .screenshot]].enumerated() {
            let store = ShelfStore(directory: root.appendingPathComponent("shelf-\(index)"))
            store.setEnabled(true)
            await store.add(urls: [source], kind: order[0])
            await store.add(urls: [source.resolvingSymlinksInPath()], kind: order[1])
            XCTAssertEqual(store.items.count, 1, "同一来源的自动收录和手动拖入只保留一项")
            XCTAssertEqual(store.items.first?.kind, .file, "手动拖入保留较长的文件时长")
        }
    }

    @MainActor
    func testAutomaticAndManualArrivalDuringCopyDoNotDuplicate() async throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try sampleFile(root.appendingPathComponent("src"), "shot.png")
        let store = ShelfStore(directory: root.appendingPathComponent("shelf"))
        store.setEnabled(true)
        async let automatic: ShelfStore.AddResult = store.add(urls: [source], kind: .screenshot)
        async let manual: ShelfStore.AddResult = store.add(urls: [source.resolvingSymlinksInPath()], kind: .file)
        _ = await (automatic, manual)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.kind, .file)
    }

    @MainActor
    func testManualDropRefreshesRetentionFromItsOwnArrival() async throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try sampleFile(root.appendingPathComponent("src"), "shot.png")
        let shelf = root.appendingPathComponent("shelf")
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        let old = ShelfItem(id: "old", name: "shot.png", size: 5,
                            addedAt: Date().addingTimeInterval(-300).timeIntervalSince1970 * 1000,
                            source: source.path, kind: .screenshot)
        try JSONEncoder().encode([old]).write(to: shelf.appendingPathComponent("index.json"))
        let storedCopy = shelf.appendingPathComponent("files/old/shot.png")
        try FileManager.default.createDirectory(at: storedCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: storedCopy)
        let store = ShelfStore(directory: shelf, retention: { (file: 60, screenshot: 3600) })
        store.setEnabled(true)
        await store.add(urls: [source], kind: .file)
        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(item.kind, .file)
        XCTAssertGreaterThan(ShelfStore.expiry(of: item, file: 60, screenshot: 3600), Date().addingTimeInterval(50))
    }

    @MainActor
    func testChangedSourceIsCopiedAsNewManualVersion() async throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try sampleFile(root.appendingPathComponent("src"), "shot.png")
        let store = ShelfStore(directory: root.appendingPathComponent("shelf"))
        store.setEnabled(true)
        await store.add(urls: [source], kind: .screenshot)
        try Data("new image".utf8).write(to: source)
        await store.add(urls: [source], kind: .file)
        XCTAssertEqual(store.items.count, 2, "同一路径更新后的内容必须保留新副本")
        let current = try XCTUnwrap(store.items.first)
        XCTAssertEqual(current.kind, .file)
        XCTAssertEqual(try Data(contentsOf: store.fileURL(current)), Data("new image".utf8))
    }

    @MainActor
    func testDisabledHoldsNothingAndIgnoresAdds() async throws {
        let root = temp()
        let source = try sampleFile(root.appendingPathComponent("src"), "b.txt")
        let store = ShelfStore(directory: root.appendingPathComponent("shelf"))
        await store.add(urls: [source])
        XCTAssertTrue(store.items.isEmpty, "没开就不收")
        store.setEnabled(true)
        await store.add(urls: [source])
        store.start()
        XCTAssertEqual(store.thumbnails.count, 1, "这页可见时缩略图在内存里")
        store.stop()
        XCTAssertTrue(store.thumbnails.isEmpty, "不可见就放掉")
        store.setEnabled(false)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("shelf/index.json").path), "关掉不删磁盘上的东西")
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testPersistedFileIconDoesNotBecomeLargeImagePreview() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let shelf = root.appendingPathComponent("shelf")
        let thumbs = shelf.appendingPathComponent("thumbs")
        try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        let items = ["preview", "icon"].map {
            ShelfItem(id: $0, name: "\($0).png", size: 10, addedAt: Date().timeIntervalSince1970 * 1000,
                      source: nil, kind: .file)
        }
        try JSONEncoder().encode(items).write(to: shelf.appendingPathComponent("index.json"))
        let image = NSWorkspace.shared.icon(forFileType: "png")
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        for item in items {
            try png.write(to: thumbs.appendingPathComponent(item.id + ".png"))
            try item.id.write(to: thumbs.appendingPathComponent(item.id + ".kind"), atomically: true, encoding: .utf8)
        }
        let store = ShelfStore(directory: shelf)
        store.setEnabled(true)
        store.start()
        XCTAssertEqual(store.thumbnails.count, 2)
        XCTAssertEqual(store.previewIDs, ["preview"], "持久化的文件图标不能当内容预览放大")
        store.stop()
        XCTAssertTrue(store.previewIDs.isEmpty)
    }

    /// 截图和文件各按各的时长过期；老索引里没标种类的按文件算。
    func testExpiryByKind() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        func item(_ id: String, minutesAgo: Double, kind: ShelfKind?) -> ShelfItem {
            ShelfItem(id: id, name: id, size: 1, addedAt: now.addingTimeInterval(-minutesAgo * 60).timeIntervalSince1970 * 1000, source: nil, kind: kind)
        }
        let day: TimeInterval = 86400, halfHour: TimeInterval = 1800
        let shotOld = item("s-old", minutesAgo: 31, kind: .screenshot)
        let shotNew = item("s-new", minutesAgo: 10, kind: .screenshot)
        let fileTwoHours = item("f", minutesAgo: 120, kind: .file)
        let legacyOld = item("legacy", minutesAgo: 25 * 60, kind: nil)
        XCTAssertEqual(ShelfStore.expired([shotOld, shotNew, fileTwoHours, legacyOld], now: now, file: day, screenshot: halfHour), [shotOld, legacyOld],
                       "截图 30 分钟过期、文件 1 天；老索引没标种类的按文件算")
        XCTAssertEqual(ShelfStore.nextExpiry([shotNew, fileTwoHours], file: day, screenshot: halfHour), now.addingTimeInterval(20 * 60),
                       "定时器排到最早那一件")
        XCTAssertNil(ShelfStore.nextExpiry([], file: day, screenshot: halfHour))
    }

    func testRetentionFormat() {
        XCTAssertEqual(RetentionFormat.text(30), "30 分钟")
        XCTAssertEqual(RetentionFormat.text(1440), "1 天")
        XCTAssertEqual(RetentionFormat.text(120), "2 小时")
        XCTAssertEqual(RetentionFormat.text(90), "90 分钟", "除不尽就用分钟")
        XCTAssertTrue(RetentionFormat.split(2880) == (2, .days))
    }

    /// 到点就清，不等打开这页。
    @MainActor
    func testExpiredItemsAreRemovedOnTime() async throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try sampleFile(root.appendingPathComponent("src"), "shot.png")
        let otherSource = try sampleFile(root.appendingPathComponent("other-src"), "shot.png")
        let store = ShelfStore(directory: root.appendingPathComponent("shelf"), retention: { (file: 3600, screenshot: 0.3) })
        store.setEnabled(true)
        defer { store.setEnabled(false) }
        await store.add(urls: [source], kind: .screenshot)
        await store.add(urls: [otherSource])
        XCTAssertEqual(store.items.count, 2)
        try await Task.sleep(nanoseconds: 1_800_000_000)
        XCTAssertEqual(store.items.map(\.kind), [.file], "截图到点清掉，文件还在")
    }

    /// 老索引里没有 source 这个键，解出来得是 nil，不能整条读不出来。
    func testLegacyIndexWithoutSourceDecodes() throws {
        let json = Data(#"[{"id":"a","name":"a.txt","size":5,"addedAt":1}]"#.utf8)
        let items = try JSONDecoder().decode([ShelfItem].self, from: json)
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].source)
        XCTAssertNil(items[0].kind, "老索引没有种类，按文件算保留时长")
    }

    /// 剪切交出去的是**来源文件本身**，不是架上那份快照：这样访达做的是一次改名，盘上不多一份副本，
    /// 也就没有「多出来的那份该不该进废纸篓」这回事。来源没了才退回架上那份。
    @MainActor
    func testCutHandsOverSourceItself() async throws {
        let root = temp()
        let source = try sampleFile(root.appendingPathComponent("src"), "cut.txt")
        let store = ShelfStore(directory: root.appendingPathComponent("shelf"))
        store.setEnabled(true)
        await store.add(urls: [source])
        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.source, source.path, "拖进来时记下原路径")
        XCTAssertEqual(store.cutURL(item), source, "来源还在就交来源")
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(store.cutURL(item), store.fileURL(item), "来源没了退回架上那份")
        try? FileManager.default.removeItem(at: root)
    }

    /// 右键「移动到…」：搬的是来源本身，架上那份跟着清掉，废纸篓里不该多出东西；
    /// 目标已有同名文件就报错，且什么都不动。
    @MainActor
    func testMoveToMovesSourceOrRefusesOnConflict() async throws {
        let root = temp()
        let name = "tally-test-\(UUID().uuidString).txt"
        let source = try sampleFile(root.appendingPathComponent("src"), name)
        let store = ShelfStore(directory: root.appendingPathComponent("shelf"))
        store.setEnabled(true)
        await store.add(urls: [source])
        let item = try XCTUnwrap(store.items.first)

        // 目标目录先放一个同名的：不能默默覆盖
        let destination = root.appendingPathComponent("dst")
        _ = try sampleFile(destination, name)
        XCTAssertNotNil(store.moveTo(item, directory: destination), "同名冲突要报错")
        XCTAssertEqual(store.items.count, 1, "报错了就什么都不动")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "来源也还在")

        try FileManager.default.removeItem(at: destination.appendingPathComponent(name))
        XCTAssertNil(store.moveTo(item, directory: destination))
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(name).path), "来源搬到了目标目录")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "原处没有了")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(item).path), "架上那份删掉")
        let trashed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(name)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.path), "不该往废纸篓里丢东西")
        try? FileManager.default.removeItem(at: root)
    }
}

private actor ShelfAuditGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

extension ShelfStoreTests {
    @MainActor
    func testReadyFilesDoNotWaitForThumbnail() async throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try sampleFile(root.appendingPathComponent("src"), "ready.txt")
        let gate = ShelfAuditGate()
        let started = expectation(description: "thumbnail started")
        let finished = expectation(description: "file ready before thumbnail")
        let store = ShelfStore(directory: root.appendingPathComponent("shelf"), thumbnail: { _ in
            started.fulfill()
            await gate.wait()
            return (NSImage(data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jD1sAAAAASUVORK5CYII=")!)!, false)
        })
        store.setEnabled(true)
        let addition = Task { await store.add(urls: [source]); finished.fulfill() }
        await fulfillment(of: [started], timeout: 2)
        await fulfillment(of: [finished], timeout: 0.3)
        XCTAssertEqual(store.items.count, 1, "Copied files must be usable before the preview arrives")
        await gate.release()
        _ = await addition.value
        store.clear()
    }

    @MainActor
    func testClearDiscardsAnInFlightCopy() async throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try sampleFile(root.appendingPathComponent("src"), "late.txt")
        let gate = ShelfAuditGate()
        let started = expectation(description: "copy started")
        let store = ShelfStore(directory: root.appendingPathComponent("shelf"), copy: { source, destination in
            started.fulfill()
            await gate.wait()
            try FileManager.default.copyItem(at: source, to: destination)
        })
        store.setEnabled(true)
        let addition = Task { await store.add(urls: [source]) }
        await fulfillment(of: [started], timeout: 2)
        store.clear()
        await gate.release()
        _ = await addition.value
        XCTAssertTrue(store.items.isEmpty, "Clear must invalidate pending copies")
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("shelf/files").path)
        XCTAssertTrue(contents.isEmpty)
    }
}

extension ShelfStoreTests {
    @MainActor
    func testFailuresNeverProduceSuccessPeekOrOrphanCopy() async throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try sampleFile(root.appendingPathComponent("src"), "kept.txt")
        let store = ShelfStore(directory: root.appendingPathComponent("shelf"))
        store.setEnabled(true)
        let partial = await store.add(urls: [source, root.appendingPathComponent("missing.txt")])
        XCTAssertEqual(partial.stored, ["kept.txt"])
        XCTAssertEqual(partial.failed, ["missing.txt"])
        XCTAssertEqual(Peek.shelf(result: partial)?.label, "部分文件未收进")
        XCTAssertNotNil(store.failure)
        store.clear()
        let index = store.directory.appendingPathComponent("index.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        let failedSave = await store.add(urls: [source])
        XCTAssertTrue(failedSave.stored.isEmpty)
        XCTAssertEqual(failedSave.failed, ["kept.txt"])
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(Peek.shelf(result: failedSave)?.label, "未能放进文件架")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.directory.appendingPathComponent("files").path).isEmpty)
        XCTAssertNil(Peek.shelf(result: .init(cancelled: true)))
    }

    @MainActor
    func testReenableDoesNotAcceptPreviousCopy() async throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try sampleFile(root.appendingPathComponent("src"), "late.txt")
        let gate = ShelfAuditGate()
        let started = expectation(description: "copy started")
        let store = ShelfStore(directory: root.appendingPathComponent("shelf"), copy: { source, destination in
            started.fulfill()
            await gate.wait()
            try FileManager.default.copyItem(at: source, to: destination)
        })
        store.setEnabled(true)
        let addition = Task { await store.add(urls: [source]) }
        await fulfillment(of: [started], timeout: 2)
        store.setEnabled(false)
        store.setEnabled(true)
        await gate.release()
        let result = await addition.value
        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(store.pendingAdds, 0)
    }
}
