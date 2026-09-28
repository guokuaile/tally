import Foundation

/// 系统「正在播放」的一条记录：哪个播放器、哪首歌、在不在放。数据来自 perl 里跑的助手（docs/music.md）。
struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    /// 播放器进程，拿来取名字和图标。助手头一行可能还没问到。
    var pid: Int32?
    var artworkId: String
    var artwork: Data?

    /// 「歌手 · 专辑」，空的那段不要。
    var subtitle: String {
        [artist, album].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// 助手 stdout 的解析，纯函数。
enum NowPlayingFeed {
    enum Line: Equatable {
        /// nil 是没有在播放的会话（`title` 为空）。
        case track(NowPlaying?)
        /// 助手说它干不了（MediaRemote 加载不了、符号没了）。
        case failed(String)
    }

    /// 不是 JSON 对象的行返回 nil，调用方忽略。
    /// 封面只在换了的那一行带：带了用新的；没带而 `artworkId` 和手里那张一样就留着；不一样就清掉——
    /// 换歌了、新封面还没到，宁可先空着也不挂上一首的。
    static func parse(_ line: Data, previous: NowPlaying?) -> Line? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        if let error = object["error"] as? String { return .failed(error) }
        guard let title = object["title"] as? String, !title.isEmpty else { return .track(nil) }
        let artworkId = object["artworkId"] as? String ?? ""
        let fresh = (object["artwork"] as? String).flatMap { Data(base64Encoded: $0) }
        let pid = (object["pid"] as? NSNumber)?.int32Value
        return .track(NowPlaying(
            title: title,
            artist: object["artist"] as? String ?? "",
            album: object["album"] as? String ?? "",
            isPlaying: object["playing"] as? Bool ?? false,
            pid: pid == 0 ? nil : pid,
            artworkId: artworkId,
            artwork: fresh ?? (artworkId == previous?.artworkId ? previous?.artwork : nil)
        ))
    }

    /// 页标题右边那句摘要。
    static func summary(_ track: NowPlaying?, player: String?) -> String {
        guard let track else { return "没有在播放的内容" }
        let state = track.isPlaying ? "正在播放" : "已暂停"
        return player.map { "\($0) · \(state)" } ?? state
    }
}

/// 管道里的输出是一块一块到的，和行对不上：半行攒着，一块里有几行就交几行。带封面的那一行十几万字符，会分好多块。
struct LineBuffer {
    private var pending = Data()

    mutating func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            pending = Data(pending[pending.index(after: newline)...])
        }
        return lines
    }
}
