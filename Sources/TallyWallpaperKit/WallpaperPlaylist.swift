import Foundation

public struct WallpaperPlaylist {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp"]
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    public static let supportedExtensions = imageExtensions.union(videoExtensions)

    private(set) public var queue: [URL] = []
    private(set) public var last: URL?
    private(set) public var count = 0
    private var seen: Set<String>?
    private let seenURL: URL

    public init(seenURL: URL) {
        self.seenURL = seenURL
        seen = (try? String(contentsOf: seenURL, encoding: .utf8)).map { Set($0.split(separator: "\n").map(String.init)) }
    }

    public static func collect(_ sources: [String], enumerate: (URL) throws -> [URL] = {
        try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
    }) throws -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        for source in sources {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: source, isDirectory: &isDirectory) else {
                throw WallpaperError.unavailable("素材路径不可读取：\(source)")
            }
            let base = URL(fileURLWithPath: source)
            let items = try isDirectory.boolValue ? enumerate(base) : [base]
            result += items.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
        }
        return Array(Set(result)).sorted { $0.path < $1.path }
    }

    public mutating func next(sources: [String], enumerate: (URL) throws -> [URL] = {
        try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
    }) throws -> URL? {
        let all = try Self.collect(sources, enumerate: enumerate)
        count = all.count
        let present = Set(all.map(\.path))
        queue.removeAll { !present.contains($0.path) }
        let fresh = seen.map { prior in all.filter { !prior.contains($0.path) } } ?? []
        if queue.isEmpty {
            queue = all.shuffled()
            if queue.count > 1, queue.first == last { queue.swapAt(0, queue.count - 1) }
        }
        if !fresh.isEmpty {
            let newPaths = Set(fresh.map(\.path))
            queue.removeAll { newPaths.contains($0.path) }
            queue.insert(contentsOf: fresh, at: 0)
        }
        if seen != present {
            seen = present
            try? present.sorted().joined(separator: "\n").write(to: seenURL, atomically: true, encoding: .utf8)
        }
        guard !queue.isEmpty else { last = nil; return nil }
        let item = queue.removeFirst()
        last = item
        return item
    }
}
