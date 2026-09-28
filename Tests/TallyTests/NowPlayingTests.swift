import XCTest
@testable import Tally

final class NowPlayingTests: XCTestCase {

    private func line(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func track(_ line: Data, previous: NowPlaying? = nil) -> NowPlaying? {
        guard case .track(let track)? = NowPlayingFeed.parse(line, previous: previous) else { return nil }
        return track
    }

    func testParsesATrackLine() throws {
        let cover = Data([1, 2, 3])
        let parsed = track(try line(["playing": true, "title": "回到过去", "artist": "周杰伦", "album": "八度空间",
                                     "pid": 48653, "artworkId": "a1", "artwork": cover.base64EncodedString()]))
        XCTAssertEqual(parsed, NowPlaying(title: "回到过去", artist: "周杰伦", album: "八度空间", isPlaying: true,
                                          pid: 48653, artworkId: "a1", artwork: cover))
        XCTAssertEqual(parsed?.subtitle, "周杰伦 · 八度空间")
    }

    func testSubtitleSkipsEmptyParts() {
        let noAlbum = NowPlaying(title: "t", artist: "歌手", album: "", isPlaying: false, pid: nil, artworkId: "", artwork: nil)
        XCTAssertEqual(noAlbum.subtitle, "歌手", "酷狗不报专辑，不能画成「歌手 · 」")
    }

    func testEmptyTitleMeansNoSessionAndPidZeroIsUnknown() throws {
        XCTAssertEqual(NowPlayingFeed.parse(try line(["playing": false, "title": "", "pid": 0]), previous: nil), .track(nil))
        XCTAssertNil(track(try line(["title": "x", "pid": 0]))?.pid, "助手头一行还没问到是哪个进程")
    }

    func testErrorLineAndGarbage() throws {
        XCTAssertEqual(NowPlayingFeed.parse(try line(["error": "mediaremote-unavailable"]), previous: nil), .failed("mediaremote-unavailable"))
        XCTAssertNil(NowPlayingFeed.parse(Data("perl: warning".utf8), previous: nil), "不是 JSON 的行忽略")
        XCTAssertNil(NowPlayingFeed.parse(Data("[1,2]".utf8), previous: nil))
    }

    func testArtworkCarriesOverOnlyForTheSameId() throws {
        let cover = Data([9, 9])
        let first = track(try line(["title": "A", "artworkId": "a1", "artwork": cover.base64EncodedString()]))
        // 封面只在换了的那一行带：同一张的后续行不带，得留着
        let paused = track(try line(["title": "A", "artworkId": "a1", "playing": false]), previous: first)
        XCTAssertEqual(paused?.artwork, cover)
        // 换歌了、新封面还没到：宁可先空着，不挂上一首的
        let next = track(try line(["title": "B", "artworkId": "b2"]), previous: paused)
        XCTAssertNil(next?.artwork)
        // 新封面随后到，id 和上一行一样，也得换上
        let late = Data([7])
        let arrived = track(try line(["title": "B", "artworkId": "b2", "artwork": late.base64EncodedString()]), previous: next)
        XCTAssertEqual(arrived?.artwork, late)
    }

    func testLineBufferSplitsChunksIntoLines() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("{\"a\"".utf8)), [], "半行攒着")
        XCTAssertEqual(buffer.append(Data(":1}\n{\"b\":2}\n{\"c\"".utf8)), [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)], "一块里多行")
        // 带封面的那一行十几万字符，分很多块到
        let big = String(repeating: "x", count: 130_000)
        XCTAssertEqual(buffer.append(Data((":\"" + big).utf8)), [])
        XCTAssertEqual(buffer.append(Data("\"}\n\n".utf8)), [Data(("{\"c\":\"" + big + "\"}").utf8)], "空行不交")
    }

    func testPageShowsByToggleResidencyAndSession() {
        let shows = NowPlayingMonitor.showsPage
        XCTAssertFalse(shows(false, true, true, false), "关着不出")
        XCTAssertTrue(shows(true, true, false, false), "常驻：没在播也在")
        XCTAssertFalse(shows(true, false, false, false), "不常驻：没有会话不出")
        XCTAssertTrue(shows(true, false, true, false), "不常驻：有会话（暂停着也算）才出")
        XCTAssertFalse(shows(true, true, true, true), "助手起不来：整页藏起来")
    }

    func testSummary() {
        let playing = NowPlaying(title: "t", artist: "", album: "", isPlaying: true, pid: nil, artworkId: "", artwork: nil)
        var paused = playing
        paused.isPlaying = false
        XCTAssertEqual(NowPlayingFeed.summary(playing, player: "酷狗音乐"), "酷狗音乐 · 正在播放")
        XCTAssertEqual(NowPlayingFeed.summary(paused, player: nil), "已暂停")
        XCTAssertEqual(NowPlayingFeed.summary(nil, player: nil), "没有在播放的内容")
    }

    func testMusicIsALaunchPage() {
        XCTAssertEqual(LaunchOptions.Page(argument: "music"), .music)
        XCTAssertEqual(LaunchOptions.parse(["Tally", "--open", "music"]).openPage, .music)
    }
}
