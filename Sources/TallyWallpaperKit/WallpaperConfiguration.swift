import Foundation
import Darwin

public struct WallpaperConfiguration: Codable, Equatable {
    public var sources: [String]
    public var slotSeconds: Double
    public var launchAtLogin: Bool

    public init(sources: [String], slotSeconds: Double = 300, launchAtLogin: Bool = false) {
        self.sources = sources
        self.slotSeconds = slotSeconds
        self.launchAtLogin = launchAtLogin
    }

    public func validate(checkExistence: Bool = true) throws {
        guard slotSeconds.isFinite, (10...86400).contains(slotSeconds) else { throw WallpaperError.invalidConfiguration("轮播间隔须为 10～86400 秒") }
        guard !sources.isEmpty, sources.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else {
            throw WallpaperError.invalidConfiguration("请选择本机绝对路径的素材目录或文件")
        }
        guard !checkExistence || sources.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
            throw WallpaperError.invalidConfiguration("素材目录或文件不存在")
        }
    }
}

public enum WallpaperError: Error, LocalizedError {
    case invalidConfiguration(String)
    case unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let value), .unavailable(let value): return value
        }
    }
}

public struct WallpaperPaths {
    public let root: URL
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tally/Wallpaper", isDirectory: true)) {
        self.root = root
    }
    public var configuration: URL { root.appendingPathComponent("config.json") }
    public var seen: URL { root.appendingPathComponent("seen.txt") }
    public var log: URL { root.appendingPathComponent("wallpaper.log") }
    public var socket: URL { root.appendingPathComponent("control.sock") }
    public var lock: URL { root.appendingPathComponent("player.lock") }
    public var sessionAgent: URL { root.appendingPathComponent("player-agent.plist") }
    public var playbackState: URL { root.appendingPathComponent("playback-state.json") }
    public var migration: URL { root.appendingPathComponent("migration.json") }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    public func load() throws -> WallpaperConfiguration {
        let config = try JSONDecoder().decode(WallpaperConfiguration.self, from: Data(contentsOf: configuration))
        try config.validate(checkExistence: false)
        return config
    }

    public func loadPaused() throws -> Bool {
        struct Playback: Decodable { var paused: Bool }
        var metadata = stat()
        if lstat(playbackState.path, &metadata) != 0 {
            if errno == ENOENT { return false }
            throw WallpaperError.unavailable("暂停状态无法检查：\(String(cString: strerror(errno)))")
        }
        return try JSONDecoder().decode(Playback.self, from: Data(contentsOf: playbackState)).paused
    }

    public func save(_ config: WallpaperConfiguration) throws {
        try config.validate()
        try prepare()
        let data = try JSONEncoder().encode(config)
        let temp = root.appendingPathComponent(UUID().uuidString + ".tmp")
        try data.write(to: temp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        // rename replaces the whole record; a partial config is never visible.
        guard rename(temp.path, configuration.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw WallpaperError.unavailable("无法保存壁纸配置")
        }
    }
}
