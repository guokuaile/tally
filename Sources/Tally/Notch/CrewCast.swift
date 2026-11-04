import Foundation
import Observation
import TallyKit

/// 项目键 → 角色池下标，纯函数。落点用名册同一个 FNV-1a 散列：换机器、重启都一样；落点被占才探位，所以撞位的项目重启后可能换角色。
enum CrewCast {
    static func slot(for key: String, poolCount: Int) -> Int { CrewRoster.bucket(key, of: poolCount) }

    /// 按首见顺序分：已分的不挪；新键取散列落点，占了就往后找第一个空位；池子满了直接用落点（允许重复）。不在 `order` 里的键丢掉
    static func assign(order: [String], existing: [String: Int], poolCount: Int) -> [String: Int] {
        guard poolCount > 0 else { return [:] }
        var assigned: [String: Int] = [:]
        var taken = Set<Int>()
        for key in order {
            guard let slot = existing[key] else { continue }
            assigned[key] = slot
            taken.insert(slot)
        }
        for key in order where assigned[key] == nil {
            var slot = slot(for: key, poolCount: poolCount)
            if taken.count < poolCount {
                while taken.contains(slot) { slot = (slot + 1) % poolCount }
            }
            assigned[key] = slot
            taken.insert(slot)
        }
        return assigned
    }
}

/// 进程内唯一的一张分配表：以活会话为准，翅膀、AI 页行、药丸、工牌、悬停头像都查它，同一个键在哪儿都是同一个角色。
@MainActor @Observable
final class CrewCastStore {
    static let shared = CrewCastStore()

    let art: CastArt
    private(set) var assigned: [String: Int] = [:]
    /// cwd → 规范化目录：解符号链接要走文件系统，每次会话变化都对每条重解在主线程上不值当
    @ObservationIgnored private var canonical: [String: String] = [:]
    /// 上一份快照刚退场的键 → 槽位：离职工牌和退场在同一份快照里发，肖像得还是它在翅膀上那个；再下一份快照就忘掉
    @ObservationIgnored private var retired: [String: Int] = [:]

    init(art: CastArt = .bundled) { self.art = art }

    func canonicalize(_ cwd: String) -> String {
        if let hit = canonical[cwd] { return hit }
        let path = cwd.isEmpty ? "" : CrewRoster.standardized(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path)
        canonical[cwd] = path
        return path
    }

    /// 和名册拼项目 id 用的是同一个函数：翅膀和 AI 页不可能拿到两个键
    func key(provider: String, cwd: String) -> String {
        CrewRoster.projectKey(tool: CrewRoster.tool(provider: provider), path: canonicalize(cwd))
    }

    /// 每份会话快照调一次：活会话的键按首见顺序分，不活的键删掉
    func sync(_ sessions: [SessionRecord]) {
        var order: [String] = []
        var seen = Set<String>()
        for session in sessions where session.state != .ended {
            let key = key(provider: session.provider, cwd: session.cwd)
            if seen.insert(key).inserted { order.append(key) }
        }
        let next = CrewCast.assign(order: order, existing: assigned, poolCount: art.pool.count)
        retired = assigned.filter { next[$0.key] == nil }
        assigned = next
    }

    /// 没分过的当场分（也进表），所以谁先问都一样；刚退场的键按退场前的槽位答，不分回表里
    func member(forKey key: String) -> CastMember {
        if let slot = assigned[key] ?? retired[key] { return art.pool[slot] }
        assigned = CrewCast.assign(order: Array(assigned.keys) + [key], existing: assigned, poolCount: art.pool.count)
        return art.pool[assigned[key] ?? 0]
    }

    func member(for session: SessionRecord) -> CastMember { member(forKey: key(provider: session.provider, cwd: session.cwd)) }
}
