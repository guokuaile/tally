import XCTest
import TallyKit
@testable import Tally

/// 角色分配：纯函数的落点 / 探位 / 稳定性，分配表的键和名册同一个、活会话为准、目录规范化。
@MainActor
final class CrewCastTests: XCTestCase {
    private let keys = (1...16).map { "claude:/Users/you/code/project-\($0)" }
    /// 有素材用真池子（15 个），公开快照里只有球：这组用例只看表的行为，不看角色几个
    private func store() -> CrewCastStore {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return CrewCastStore(art: CastArt(directory: root.appendingPathComponent("Resources/cast")))
    }
    private func session(_ id: String, cwd: String, provider: String = "claude", state: SessionRecord.State = .running) -> SessionRecord {
        SessionRecord(sessionId: id, provider: provider, state: state, cwd: cwd, title: id, transcriptPath: "", message: nil,
                      updatedAt: Date().timeIntervalSince1970 * 1000)
    }

    func testStoreKeyMatchesRosterProjectID() {
        let store = store()
        let record = session("s1", cwd: "/tmp/shop-web/", provider: "codex")
        let projects = CrewRoster.projects([record], now: Date(), canonicalize: store.canonicalize)
        XCTAssertEqual(projects.first?.id, store.key(provider: record.provider, cwd: record.cwd))
        XCTAssertEqual(store.member(for: record), store.member(forKey: projects.first!.id))
    }

    func testSixKeysGetSixDifferentSlotsAndTheSeventhDoesNotMoveThem() {
        let six = Array(keys.prefix(6))
        let assigned = CrewCast.assign(order: six, existing: [:], poolCount: 15)
        XCTAssertEqual(Set(assigned.values).count, 6)
        let seven = CrewCast.assign(order: six + [keys[6]], existing: assigned, poolCount: 15)
        for key in six { XCTAssertEqual(seven[key], assigned[key], "先来的不挪") }
        XCTAssertEqual(Set(seven.values).count, 7)
    }

    func testRemovedKeyComesBackToTheSameCharacterWhenUncontested() {
        let six = Array(keys.prefix(6))
        let assigned = CrewCast.assign(order: six, existing: [:], poolCount: 15)
        let rest = Array(six.dropFirst())
        let without = CrewCast.assign(order: rest, existing: assigned, poolCount: 15)
        XCTAssertNil(without[six[0]])
        let back = CrewCast.assign(order: rest + [six[0]], existing: without, poolCount: 15)
        XCTAssertEqual(back[six[0]], assigned[six[0]])
    }

    func testSixteenKeysAllGetSlotsAndTheFirstFifteenDiffer() {
        let assigned = CrewCast.assign(order: keys, existing: [:], poolCount: 15)
        XCTAssertEqual(assigned.count, 16)
        XCTAssertEqual(Set(keys.prefix(15).map { assigned[$0]! }).count, 15)
        XCTAssertTrue(assigned.values.allSatisfy { (0..<15).contains($0) })
    }

    func testMemberOnDemandIsAssignedOnceAndStable() {
        let store = store()
        let first = store.member(forKey: keys[0])
        XCTAssertEqual(store.assigned.count, 1)
        XCTAssertEqual(store.member(forKey: keys[0]), first)
        XCTAssertEqual(store.assigned.count, 1)
        XCTAssertTrue(store.art.pool.contains(first))
    }

    func testSyncKeepsLiveKeysOnlyInFirstSeenOrder() {
        let store = store()
        store.sync([session("a", cwd: "/p/a"), session("b", cwd: "/p/b"), session("c", cwd: "/p/c", state: .ended), session("a2", cwd: "/p/a/")])
        let a = store.key(provider: "claude", cwd: "/p/a"), b = store.key(provider: "claude", cwd: "/p/b")
        XCTAssertEqual(Set(store.assigned.keys), [a, b], "已关闭的会话和重复目录不占位")
        let before = store.assigned[a]
        store.sync([session("b", cwd: "/p/b"), session("a", cwd: "/p/a")])
        XCTAssertEqual(store.assigned[a], before, "顺序变了不挪")
        store.sync([session("b", cwd: "/p/b")])
        XCTAssertEqual(Array(store.assigned.keys), [b])
    }

    func testKeyNormalizesTrailingSlashToolAndSymlinks() throws {
        let store = store()
        XCTAssertEqual(store.key(provider: "claude", cwd: "/a/b/"), store.key(provider: "claude", cwd: "/a/b"))
        XCTAssertNotEqual(store.key(provider: "claude", cwd: "/a/b"), store.key(provider: "codex", cwd: "/a/b"))
        XCTAssertEqual(store.key(provider: "cursor", cwd: "/a/b"), store.key(provider: "claude", cwd: "/a/b"), "名册只认两家")
        let real = FileManager.default.temporaryDirectory.appendingPathComponent("cast-real-\(UUID().uuidString)")
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("cast-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: link); try? FileManager.default.removeItem(at: real) }
        XCTAssertEqual(store.key(provider: "claude", cwd: link.path), store.key(provider: "claude", cwd: real.path))
    }

    /// 离职工牌和退场在同一份快照里发：那一份里退场的键还按原槽位答（哪怕位子已被顶掉），再下一份才忘
    func testRetiredKeyKeepsItsCharacterForOneSnapshotEvenWhenItsSlotGetsTaken() throws {
        let store = store()
        let count = store.art.pool.count
        try XCTSkipUnless(count > 1, "只有球时分不出角色")
        store.sync([session("a", cwd: "/p/a")])
        let keyA = store.key(provider: "claude", cwd: "/p/a")
        let slotA = try XCTUnwrap(store.assigned[keyA])
        // 找一个落点和 a 相同的新项目：a 退场后它顶上 a 的位子
        let rival = try XCTUnwrap((1...5000).map { "/p/rival-\($0)" }.first { CrewCast.slot(for: store.key(provider: "claude", cwd: $0), poolCount: count) == slotA })
        let before = store.member(forKey: keyA)
        store.sync([session("r", cwd: rival)])
        XCTAssertEqual(store.assigned[store.key(provider: "claude", cwd: rival)], slotA)
        XCTAssertNil(store.assigned[keyA])
        XCTAssertEqual(store.member(forKey: keyA), before, "离职那份快照里肖像还是它在翅膀上那个")
        XCTAssertNil(store.assigned[keyA], "问一下不把退场的键分回表里")
        store.sync([session("r", cwd: rival)])
        XCTAssertNotEqual(store.member(forKey: keyA), before, "下一份快照忘掉：位子被占，现场另分")
    }
}
