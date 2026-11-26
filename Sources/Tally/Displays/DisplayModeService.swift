import Foundation
import Observation

@MainActor
@Observable
final class DisplayModeService {
    static let shared = DisplayModeService(driver: NativeDisplayDriver(), preferences: .shared)

    private let driver: any DisplayDriving
    private let preferences: PreferencesStore
    private(set) var screens: [DisplaySnapshot] = []
    private(set) var busy = false
    private(set) var notice: String?
    private(set) var operationFailure: String?
    private(set) var refreshFailure: String?
    var failure: String? {
        let messages = [operationFailure, refreshFailure].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "；刷新失败：")
    }

    init(driver: any DisplayDriving, preferences: PreferencesStore) {
        self.driver = driver
        self.preferences = preferences
    }

    func refresh(clearOperationFeedback: Bool = false) {
        if clearOperationFeedback {
            operationFailure = nil
            notice = nil
        }
        do {
            screens = try driver.snapshots().filter { !$0.builtin }
            refreshFailure = nil
        } catch {
            screens = []
            refreshFailure = error.localizedDescription
        }
    }

    func target(for screen: DisplaySnapshot) -> DisplayModeSelection? {
        preferences.prefs.displayTargets[screen.id]
    }

    func preferencesUndoPending(for uuid: String) -> Bool {
        preferences.prefs.displayUndo[uuid]?.pending != nil
    }

    func saveTarget(_ mode: DisplayModeSelection, for uuid: String) throws {
        guard mode.isValid else { throw DisplayFailure("显示模式参数无效") }
        try preferences.setDisplayTarget(mode, for: uuid)
    }

    func undoReason(for screen: DisplaySnapshot) -> String? {
        guard let point = preferences.prefs.displayUndo[screen.id]?.confirmed else { return "没有可撤销的切换" }
        guard !screen.mirrored else { return "镜像屏需先改为扩展显示" }
        guard screen.current.matches(point.applied) else { return "系统模式已被改动，旧撤销不可用" }
        guard screen.matching(point.before) != nil else { return "原模式目前不可用" }
        return nil
    }

    func apply(uuid: String, mode: DisplayModeSelection? = nil) async {
        guard !busy else { return }
        notice = nil
        do { try DisplayOperationGate.shared.enter() }
        catch { operationFailure = error.localizedDescription; return }
        busy = true
        defer { DisplayOperationGate.shared.leave(); busy = false; refresh() }
        do {
            guard !DemoMode.isOn else { throw DisplayFailure("演示模式不能切换显示器") }
            guard let target = mode ?? preferences.prefs.displayTargets[uuid] else { throw DisplayFailure("请先选择或保存目标模式") }
            let changed = try await switchMode(uuid: uuid, target: target, undoing: false)
            notice = changed ? "已切换到 \(target.label)" : "当前已是所选模式，无需切换"
            operationFailure = nil
        } catch { operationFailure = error.localizedDescription }
    }

    func undo(uuid: String) async {
        guard !busy else { return }
        notice = nil
        do { try DisplayOperationGate.shared.enter() }
        catch { operationFailure = error.localizedDescription; return }
        busy = true
        defer { DisplayOperationGate.shared.leave(); busy = false; refresh() }
        do {
            guard !DemoMode.isOn else { throw DisplayFailure("演示模式不能切换显示器") }
            guard let screen = try currentScreen(uuid: uuid) else { throw DisplayFailure("显示器已断开") }
            if let reason = undoReason(for: screen) { throw DisplayFailure(reason) }
            guard let point = preferences.prefs.displayUndo[uuid]?.confirmed else { throw DisplayFailure("没有可撤销的切换") }
            _ = try await switchMode(uuid: uuid, target: point.before, undoing: true)
            notice = "已撤销，恢复到 \(point.before.label)"
            operationFailure = nil
        } catch { operationFailure = error.localizedDescription }
    }

    private func currentScreen(uuid: String) throws -> DisplaySnapshot? {
        try driver.snapshots().first { $0.id == uuid && !$0.builtin }
    }

    private func switchMode(uuid: String, target: DisplayModeSelection, undoing: Bool) async throws -> Bool {
        guard let before = try currentScreen(uuid: uuid) else { throw DisplayFailure("显示器已断开") }
        guard !before.mirrored else { throw DisplayFailure("镜像屏需先改为扩展显示") }
        guard let exact = before.matching(target) else { throw DisplayFailure("保存的精确模式已不可用") }
        if before.current.matches(exact) { return false }
        var records = preferences.prefs.displayUndo
        var record = records[uuid] ?? DisplayUndoRecord()
        if !undoing {
            record.pending = DisplayUndoPoint(before: before.current, applied: exact)
            records[uuid] = record
            try preferences.setDisplayUndo(records)
        }
        do {
            // Read again immediately before the platform transaction; visible external changes stop it.
            guard let latest = try currentScreen(uuid: uuid), !latest.mirrored,
                  latest.current.matches(before.current), latest.matching(exact) != nil else {
                throw DisplayFailure("切换前系统模式已改变")
            }
            try driver.commit(uuid: uuid, mode: exact)
            var verified = false
            for _ in 0..<50 {
                if let actual = try currentScreen(uuid: uuid), actual.current.matches(exact) {
                    verified = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard verified else { throw DisplayFailure("切换后未读回目标模式") }
            if undoing {
                records[uuid] = DisplayUndoRecord()
            } else {
                record.confirmed = record.pending
                record.pending = nil
                records[uuid] = record
            }
            do { try preferences.setDisplayUndo(records) }
            catch { throw DisplayFailure("模式已切换，撤销记录未保存：\(error.localizedDescription)") }
            return true
        } catch {
            let original = error.localizedDescription
            // A successful mode commit with failed bookkeeping must never be rolled back here.
            if original.hasPrefix("模式已切换，撤销记录未保存") { throw error }
            guard let latest = try? currentScreen(uuid: uuid) else {
                throw DisplayFailure("\(original)；无法读取实际模式，保留未确认记录")
            }
            if latest.current.matches(before.current) {
                if !undoing { try clearPending(uuid: uuid) }
                throw DisplayFailure("\(original)；原模式仍在使用")
            }
            guard latest.current.matches(exact), latest.matching(before.current) != nil else {
                throw DisplayFailure("\(original)；显示模式已被外部改变，保留未确认记录")
            }
            do {
                try driver.commit(uuid: uuid, mode: before.current)
                guard let restored = try currentScreen(uuid: uuid), restored.current.matches(before.current) else {
                    throw DisplayFailure("回退后读回不符")
                }
                if !undoing { try clearPending(uuid: uuid) }
                throw DisplayFailure("\(original)；已恢复切换前模式")
            } catch let rollback as DisplayFailure where rollback.message.hasSuffix("已恢复切换前模式") {
                throw rollback
            } catch { throw DisplayFailure("\(original)；恢复失败：\(error.localizedDescription)") }
        }
    }

    private func clearPending(uuid: String) throws {
        var records = preferences.prefs.displayUndo
        records[uuid]?.pending = nil
        try preferences.setDisplayUndo(records)
    }
}
