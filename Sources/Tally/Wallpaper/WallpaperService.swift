import Foundation
import Observation
import TallyWallpaperKit

private struct OldWallpaperRecord: Codable {
    var wasLoaded: Bool
    var wasDisabled: Bool
    var plistPath: String
}

struct WallpaperEnvironment {
    var paths: WallpaperPaths
    var home: URL
    var binary: () throws -> URL
    var run: ([String]) throws -> String
    var loaded: (String) throws -> Bool
    var disabled: () throws -> Bool
    var send: (WallpaperCommand, Double) throws -> WallpaperStatus
    var alive: (Int32) -> Bool
    var wait: (TimeInterval) -> Void

    var loginAgent: URL { home.appendingPathComponent("Library/LaunchAgents/com.aiden.tally.wallpaper.plist") }
    var oldAgent: URL { home.appendingPathComponent("Library/LaunchAgents/com.aiden.video-wallpaper.plist") }

    static let live = WallpaperEnvironment(
        paths: WallpaperPaths(), home: FileManager.default.homeDirectoryForCurrentUser,
        binary: { try WallpaperService.installedBinary() },
        run: { try WallpaperService.launch($0) },
        loaded: { try WallpaperService.isLoaded($0) },
        disabled: { try WallpaperService.oldDisabled() },
        send: { try WallpaperClient.send($0, timeout: $1) },
        alive: { kill($0, 0) == 0 },
        wait: { Thread.sleep(forTimeInterval: $0) }
    )
}

@MainActor
@Observable
final class WallpaperService {
    static let shared = WallpaperService()
    private(set) var status: WallpaperStatus?
    private(set) var message: String?
    private(set) var busy = false
    private(set) var configuration: WallpaperConfiguration?
    var legacyAvailable: Bool { !DemoMode.isOn && FileManager.default.fileExists(atPath: WallpaperPaths().migration.path) }

    private init() {
        if DemoMode.isOn {
            configuration = WallpaperConfiguration(sources: ["/演示/壁纸"], launchAtLogin: false)
            status = WallpaperStatus(pid: 0, playing: false, paused: false, currentItem: nil, itemCount: 3, error: nil)
        } else {
            configuration = try? WallpaperPaths().load()
        }
    }

    func refresh() async {
        guard !DemoMode.isOn else { return }
        let result = await Task.detached { try? WallpaperClient.send(.status) }.value
        status = result
        if result == nil { message = "壁纸播放器未运行" }
    }

    func save(_ config: WallpaperConfiguration) async throws {
        guard !DemoMode.isOn else { configuration = config; return }
        guard !busy else { message = "壁纸操作正在进行"; throw WallpaperError.unavailable("壁纸操作正在进行") }
        busy = true; defer { busy = false }
        do {
            let result = try await Task.detached { try Self.saveSync(config) }.value
            configuration = config
            if let result { status = result }
            message = "壁纸设置已保存"
        } catch { message = error.localizedDescription; throw error }
    }

    func start() async throws {
        guard !DemoMode.isOn else { return }
        guard !busy else { message = "壁纸操作正在进行"; throw WallpaperError.unavailable("壁纸操作正在进行") }
        busy = true; defer { busy = false }
        do {
            let result = try await Task.detached { try Self.startSync() }.value
            status = result; message = "壁纸正在播放"
        } catch { status = nil; message = error.localizedDescription; throw error }
    }

    func stop() async throws {
        guard !DemoMode.isOn else { return }
        guard !busy else { message = "壁纸操作正在进行"; throw WallpaperError.unavailable("壁纸操作正在进行") }
        busy = true; defer { busy = false }
        do {
            try await Task.detached { try Self.stopSync() }.value
            status = nil; message = "壁纸已停止"
        } catch { message = error.localizedDescription; throw error }
    }

    func pause() async throws { try await command(.pause) }
    func resume() async throws { try await command(.resume) }
    func next() async throws { try await command(.next) }
    func reload() async throws { try await command(.reload) }

    func restoreLegacy() async throws {
        guard !DemoMode.isOn else { return }
        guard !busy else { message = "壁纸操作正在进行"; throw WallpaperError.unavailable("壁纸操作正在进行") }
        busy = true; defer { busy = false }
        do {
            try await Task.detached { try Self.restoreLegacySync() }.value
            status = nil; message = "旧壁纸入口已恢复"
        } catch { message = error.localizedDescription; throw error }
    }

    private func command(_ value: WallpaperCommand) async throws {
        guard !DemoMode.isOn else { return }
        guard !busy else { message = "壁纸操作正在进行"; throw WallpaperError.unavailable("壁纸操作正在进行") }
        busy = true; defer { busy = false }
        do {
            let result = try await Task.detached { try WallpaperClient.send(value) }.value
            status = result; message = result.error
        } catch { status = nil; message = error.localizedDescription; throw error }
    }

    nonisolated static func saveSync(_ config: WallpaperConfiguration, environment: WallpaperEnvironment = .live) throws -> WallpaperStatus? {
        let paths = environment.paths
        let previousConfig = try? Data(contentsOf: paths.configuration)
        let previousLogin = try? Data(contentsOf: environment.loginAgent)
        let loaded = try environment.loaded(label)
        do {
            try paths.save(config)
            let status = loaded ? try environment.send(.reload, 2) : nil
            if let error = status?.error { throw WallpaperError.unavailable(error) }
            try updateLoginSync(config.launchAtLogin, environment: environment)
            return status
        } catch {
            let cause = error
            var rollback: [String] = []
            do {
                if let previousConfig { try previousConfig.write(to: paths.configuration, options: .atomic) }
                else if FileManager.default.fileExists(atPath: paths.configuration.path) { try FileManager.default.removeItem(at: paths.configuration) }
                if loaded { _ = try environment.send(.reload, 2) }
            } catch { rollback.append("配置恢复失败：\(error.localizedDescription)") }
            do {
                if let previousLogin { try previousLogin.write(to: environment.loginAgent, options: .atomic) }
                else if FileManager.default.fileExists(atPath: environment.loginAgent.path) { try FileManager.default.removeItem(at: environment.loginAgent) }
            } catch { rollback.append("登录入口恢复失败：\(error.localizedDescription)") }
            if !rollback.isEmpty { throw WallpaperError.unavailable("保存失败：\(cause.localizedDescription)；\(rollback.joined(separator: "；"))") }
            throw cause
        }
    }

    private nonisolated static let label = "com.aiden.tally.wallpaper"
    private nonisolated static let oldLabel = "com.aiden.video-wallpaper"

    fileprivate nonisolated static func launch(_ args: [String], acceptable: Set<Int32> = [0]) throws -> String {
        let result = try Subprocess.run(URL(fileURLWithPath: "/bin/launchctl"), args, deadline: 5)
        guard !result.timedOut, let code = result.status, acceptable.contains(code) else {
            let detail = String(data: result.stderr, encoding: .utf8) ?? "launchctl failed"
            throw WallpaperError.unavailable("壁纸任务操作失败：\(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return String(data: result.stdout, encoding: .utf8) ?? ""
    }

    private nonisolated static func domain() -> String { "gui/\(getuid())" }

    fileprivate nonisolated static func isLoaded(_ label: String) throws -> Bool {
        let result = try Subprocess.run(URL(fileURLWithPath: "/bin/launchctl"), ["print", "\(domain())/\(label)"], deadline: 5)
        if result.status == 0 { return true }
        if result.status == 113 { return false }
        throw WallpaperError.unavailable("无法读取壁纸任务状态：\(String(data: result.stderr, encoding: .utf8) ?? "未知错误")")
    }

    fileprivate nonisolated static func oldDisabled() throws -> Bool {
        let output = try launch(["print-disabled", domain()])
        return output.components(separatedBy: .newlines).contains { $0.contains("\"\(oldLabel)\"") && $0.contains("=> disabled") }
    }

    fileprivate nonisolated static func installedBinary() throws -> URL {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/TallyWallpaper.app/Contents/MacOS/tally-wallpaper")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw WallpaperError.unavailable("App 内没有壁纸播放器，请先安装新版 Tally") }
        return url
    }

    private nonisolated static func agentData(binary: URL) throws -> Data {
        let plist: [String: Any] = ["Label": label, "ProgramArguments": [binary.path], "RunAtLoad": true, "KeepAlive": true]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private nonisolated static func writeAgent(_ url: URL, binary: URL) throws {
        let data = try agentData(binary: binary)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    nonisolated static func updateLoginSync(_ enabled: Bool, environment: WallpaperEnvironment = .live) throws {
        let url = environment.loginAgent
        if enabled { try writeAgent(url, binary: environment.binary()) }
        else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private nonisolated static func waitStopped(pid: Int32?, label: String, environment: WallpaperEnvironment) throws {
        for _ in 0..<40 {
            if let pid {
                if !environment.alive(pid) { return }
            } else if !(try environment.loaded(label)) { return }
            environment.wait(0.1)
        }
        throw WallpaperError.unavailable("壁纸进程未退出：\(label)")
    }

    private nonisolated static func jobPID(_ label: String, environment: WallpaperEnvironment) throws -> Int32? {
        let output = try environment.run(["print", "\(domain())/\(label)"])
        for line in output.components(separatedBy: .newlines) where line.contains("pid =") {
            if let value = Int32(line.components(separatedBy: "pid =").last?.trimmingCharacters(in: .whitespaces) ?? "") { return value }
        }
        return nil
    }

    nonisolated static func startSync(environment: WallpaperEnvironment = .live) throws -> WallpaperStatus {
        let paths = environment.paths
        let binary = try environment.binary()
        let config = try paths.load()
        try paths.prepare()
        if let running = try? environment.send(.status, 1) {
            guard running.isHealthy else {
                throw WallpaperError.unavailable(running.error ?? "播放器尚未准备好素材")
            }
            return running
        }
        if try environment.loaded(label) { throw WallpaperError.unavailable("壁纸任务已加载，但播放器控制端点无响应") }
        let oldLoaded = try environment.loaded(oldLabel)
        let oldWasDisabled = try environment.disabled()
        let oldPlist = environment.oldAgent
        let priorLoginPlist = try? Data(contentsOf: environment.loginAgent)
        let priorMigration = try? Data(contentsOf: paths.migration)
        let priorSessionPlist = try? Data(contentsOf: paths.sessionAgent)
        if oldLoaded && !FileManager.default.fileExists(atPath: oldPlist.path) { throw WallpaperError.unavailable("旧壁纸任务配置丢失，无法安全接管") }
        // Validate all new assets before stopping the old job.
        let oldExists = FileManager.default.fileExists(atPath: oldPlist.path)
        var newPID: Int32?
        do {
            try writeAgent(paths.sessionAgent, binary: binary)
            try updateLoginSync(config.launchAtLogin, environment: environment)
            if (oldLoaded || oldExists) && priorMigration == nil {
                let record = OldWallpaperRecord(wasLoaded: oldLoaded, wasDisabled: oldWasDisabled, plistPath: oldPlist.path)
                try JSONEncoder().encode(record).write(to: paths.migration, options: .atomic)
            }
            if oldLoaded || oldExists { try environment.run(["disable", "\(domain())/\(oldLabel)"]) }
            if oldLoaded {
                let pid = try jobPID(oldLabel, environment: environment)
                try environment.run(["bootout", "\(domain())/\(oldLabel)"])
                try waitStopped(pid: pid, label: oldLabel, environment: environment)
            }
            try environment.run(["bootstrap", domain(), paths.sessionAgent.path])
            for _ in 0..<40 {
                if let status = try? environment.send(.status, 1) {
                    newPID = status.pid
                    if status.isHealthy { return status }
                }
                environment.wait(0.1)
            }
            throw WallpaperError.unavailable("新壁纸播放器启动后未响应")
        } catch {
            var rollbackErrors: [String] = []
            var newStopped = true
            do {
                if try environment.loaded(label) {
                    // A silent helper may never answer IPC; launchd still knows its process ID.
                    let pid: Int32?
                    if let newPID, newPID > 0 { pid = newPID }
                    else { pid = try jobPID(label, environment: environment) }
                    guard let pid else { throw WallpaperError.unavailable("无法确认新壁纸进程 ID，未恢复旧任务") }
                    try environment.run(["bootout", "\(domain())/\(label)"])
                    try waitStopped(pid: pid, label: label, environment: environment)
                }
            } catch {
                newStopped = false
                rollbackErrors.append("卸载新任务失败：\(error.localizedDescription)")
            }
            if let priorLoginPlist {
                do { try priorLoginPlist.write(to: environment.loginAgent, options: .atomic) }
                catch { rollbackErrors.append("恢复登录入口失败：\(error.localizedDescription)") }
            } else if FileManager.default.fileExists(atPath: environment.loginAgent.path) {
                do { try FileManager.default.removeItem(at: environment.loginAgent) }
                catch { rollbackErrors.append("撤销登录入口失败：\(error.localizedDescription)") }
            }
            if let priorMigration {
                do { try priorMigration.write(to: paths.migration, options: .atomic) }
                catch { rollbackErrors.append("恢复迁移记录失败：\(error.localizedDescription)") }
            } else if FileManager.default.fileExists(atPath: paths.migration.path) {
                do { try FileManager.default.removeItem(at: paths.migration) }
                catch { rollbackErrors.append("撤销迁移记录失败：\(error.localizedDescription)") }
            }
            if let priorSessionPlist {
                do { try priorSessionPlist.write(to: paths.sessionAgent, options: .atomic) }
                catch { rollbackErrors.append("恢复运行任务失败：\(error.localizedDescription)") }
            } else if FileManager.default.fileExists(atPath: paths.sessionAgent.path) {
                do { try FileManager.default.removeItem(at: paths.sessionAgent) }
                catch { rollbackErrors.append("撤销运行任务失败：\(error.localizedDescription)") }
            }
            if !newStopped {
                throw WallpaperError.unavailable("接管失败：\(error.localizedDescription)；新播放器未确认停止，未并行恢复旧任务：\(rollbackErrors.joined(separator: "；"))")
            }
            if oldLoaded || oldExists {
                do { try environment.run(["enable", "\(domain())/\(oldLabel)"]) }
                catch { rollbackErrors.append("恢复旧任务启用状态失败：\(error.localizedDescription)") }
                if oldLoaded {
                    do { try environment.run(["bootstrap", domain(), oldPlist.path]) }
                    catch { rollbackErrors.append("恢复旧播放器失败：\(error.localizedDescription)") }
                }
                if oldWasDisabled {
                    do { try environment.run(["disable", "\(domain())/\(oldLabel)"]) }
                    catch { rollbackErrors.append("恢复旧任务禁用状态失败：\(error.localizedDescription)") }
                }
            }
            if !rollbackErrors.isEmpty { throw WallpaperError.unavailable("接管失败：\(error.localizedDescription)；回退失败：\(rollbackErrors.joined(separator: "；"))") }
            throw error
        }
    }

    nonisolated static func stopSync(environment: WallpaperEnvironment = .live) throws {
        let loaded = try environment.loaded(label)
        let ipcPID = try? environment.send(.status, 1).pid
        let pid: Int32?
        if let ipcPID, ipcPID > 0 { pid = ipcPID }
        else if loaded { pid = try jobPID(label, environment: environment) }
        else { pid = nil }
        if loaded {
            guard pid != nil else { throw WallpaperError.unavailable("无法确认壁纸进程 ID，停止状态未变更") }
            try environment.run(["bootout", "\(domain())/\(label)"])
        }
        if let pid {
            for _ in 0..<40 {
                if !environment.alive(pid) { break }
                environment.wait(0.1)
            }
            guard !environment.alive(pid) else { throw WallpaperError.unavailable("壁纸播放器仍在运行") }
        }
        guard try !environment.loaded(label), (try? environment.send(.status, 0.2)) == nil else {
            throw WallpaperError.unavailable("壁纸任务尚未完全停止")
        }
        // Stopping current playback does not change login intent. The login plist is retained only when opted in.
    }

    nonisolated static func restoreLegacySync(environment: WallpaperEnvironment = .live) throws {
        let paths = environment.paths
        let record = try JSONDecoder().decode(OldWallpaperRecord.self, from: Data(contentsOf: paths.migration))
        guard FileManager.default.fileExists(atPath: record.plistPath) else { throw WallpaperError.unavailable("旧壁纸任务文件已不在原位") }
        let oldPlistData = try Data(contentsOf: URL(fileURLWithPath: record.plistPath))
        guard let oldPlist = try PropertyListSerialization.propertyList(from: oldPlistData, format: nil) as? [String: Any],
              oldPlist["Label"] as? String == oldLabel,
              (oldPlist["ProgramArguments"] as? [String])?.isEmpty == false else {
            throw WallpaperError.unavailable("旧壁纸任务文件不再有效")
        }
        let newWasLoaded = try environment.loaded(label)
        let newStatus = try? environment.send(.status, 1)
        do {
            try stopSync(environment: environment)
            try environment.run(["enable", "\(domain())/\(oldLabel)"])
            if record.wasLoaded {
                if try !environment.loaded(oldLabel) { try environment.run(["bootstrap", domain(), record.plistPath]) }
            }
            if record.wasDisabled { try environment.run(["disable", "\(domain())/\(oldLabel)"]) }
            if FileManager.default.fileExists(atPath: environment.loginAgent.path) { try FileManager.default.removeItem(at: environment.loginAgent) }
            try FileManager.default.removeItem(at: paths.migration)
        } catch {
            let restoreError = error
            do {
                if try environment.loaded(oldLabel) {
                    let pid = try jobPID(oldLabel, environment: environment)
                    try environment.run(["bootout", "\(domain())/\(oldLabel)"])
                    try waitStopped(pid: pid, label: oldLabel, environment: environment)
                }
                try environment.run(["disable", "\(domain())/\(oldLabel)"])
            } catch {
                throw WallpaperError.unavailable("恢复旧入口失败：\(restoreError.localizedDescription)；旧任务回退失败：\(error.localizedDescription)")
            }
            if newWasLoaded {
                do {
                    try environment.run(["bootstrap", domain(), paths.sessionAgent.path])
                    if newStatus?.paused == true { _ = try environment.send(.pause, 2) }
                } catch { throw WallpaperError.unavailable("恢复旧入口失败：\(restoreError.localizedDescription)；新播放器回退失败：\(error.localizedDescription)") }
            }
            throw restoreError
        }
    }
}
