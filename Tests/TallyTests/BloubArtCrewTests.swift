import XCTest
import SwiftUI
@testable import Tally

/// 小刻六个片段的采样契约：帧数、循环接缝、圆眼、光晕 / 绿环 / 眼皮 / 弧线眼的包络，以及碎片材质。
final class BloubArtCrewTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let url = root.appendingPathComponent("Resources/bloub/frames.json")
    static let crewDurations: [String: Double] = [
        "crew-run": 4.3, "crew-permission": 4, "crew-input": 4, "crew-compacting": 3.8,
        "crew-done": 6, "crew-stale": 5
    ]

    private func art() throws -> BloubArt { try XCTUnwrap(BloubArt(url: Self.url)) }

    /// 任一小刻片段坏了或缺了整份作废：翅膀和 AI 页都靠这六段
    func testBrokenOrMissingCrewClipVoidsTheWholeFile() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.url)) as? [String: Any])
        let clips = try XCTUnwrap(json["clips"] as? [String: Any])
        func write(_ mutate: (inout [String: Any]) -> Void) throws -> URL {
            var copy = clips
            mutate(&copy)
            json["clips"] = copy
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("frames-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: json).write(to: url)
            return url
        }
        let broken = try write { $0["crew-run"] = ["fps": 20, "frames": []] }
        defer { try? FileManager.default.removeItem(at: broken) }
        XCTAssertNil(BloubArt(url: broken))
        let missing = try write { $0.removeValue(forKey: "crew-done") }
        defer { try? FileManager.default.removeItem(at: missing) }
        XCTAssertNil(BloubArt(url: missing))
        XCTAssertNotNil(BloubArt(url: Self.url))
    }
    private func clip(_ name: String) throws -> BloubArt.Clip { try XCTUnwrap(art().clips[name], name) }
    private func rawClips() throws -> [String: [String: Any]] {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.url)) as? [String: Any]
        return try XCTUnwrap(json?["clips"] as? [String: [String: Any]])
    }
    private func points(_ path: Path) -> [CGPoint] {
        var out: [CGPoint] = []
        path.forEach { element in
            switch element {
            case .move(let p), .line(let p): out.append(p)
            case .quadCurve(let p, let c): out += [c, p]
            case .curve(let p, let c1, let c2): out += [c1, c2, p]
            case .closeSubpath: break
            }
        }
        return out
    }
    private func gap(_ a: Path, _ b: Path) -> Double {
        let pa = points(a), pb = points(b)
        guard pa.count == pb.count, !pa.isEmpty else { return .infinity }
        return zip(pa, pb).map { hypot($0.x - $1.x, $0.y - $1.y) }.max()!
    }
    private func frames(_ clip: BloubArt.Clip, from: Double = 0, to: Double = .infinity) -> ArraySlice<BloubArt.Frame> {
        let lower = Int(from * clip.fps), upper = to.isFinite ? min(clip.frames.count, Int(to * clip.fps)) : clip.frames.count
        return clip.frames[lower..<upper]
    }

    func testSevenCrewClipsSampledAtTwentyFPS() throws {
        let art = try art()
        for (name, duration) in Self.crewDurations {
            let clip = try XCTUnwrap(art.clips[name], name)
            XCTAssertEqual(clip.fps, 20, name)
            XCTAssertEqual(clip.frames.count, Int(duration * 20), name)
            XCTAssertTrue(clip.frames.allSatisfy { !$0.body.isEmpty }, name)
        }
    }

    func testLoopingCrewClipsCloseWithoutSeam() throws {
        for name in Self.crewDurations.keys {
            let frames = try clip(name).frames
            XCTAssertLessThan(gap(frames[0].body, frames.last!.body), 6, name)
        }
    }

    /// 两圈光环之间眼睛往右瞟一下再回正（0.7 秒起看过去，2.1 秒起回来）：眼睛矩阵的平移烘在帧里
    func testRunGlancesSidewaysBetweenSwirls() throws {
        let frames = try XCTUnwrap(rawClips()["crew-run"]?["frames"] as? [[String: Any]])
        func gaze(_ index: Int) throws -> Double {
            let eyes = try XCTUnwrap(frames[index]["eyes"] as? [[String: Any]])
            XCTAssertEqual(eyes.count, 2)
            return try eyes.map { try XCTUnwrap($0["matrix"] as? [Double])[4] }.reduce(0, +) / 2
        }
        XCTAssertLessThan(abs(try gaze(4)), 10, "0.2 秒平视")
        XCTAssertGreaterThan(try gaze(28), 20, "1.4 秒看向右")
        XCTAssertLessThan(abs(try gaze(56)), 10, "2.8 秒已回正")
    }

    /// 「!」回球后是瞪眼（上游 `wide`）：眼睛比在跑的圆眼宽、也高
    func testPermissionWidensItsEyesAfterTheExclamation() throws {
        let clips = try rawClips()
        func eye(_ name: String, _ index: Int) throws -> (width: Double, height: Double) {
            let frames = try XCTUnwrap(clips[name]?["frames"] as? [[String: Any]])
            let eyes = try XCTUnwrap(frames[index]["eyes"] as? [[String: Any]])
            XCTAssertEqual(eyes.count, 2, name)
            return (try XCTUnwrap(eyes[0]["width"] as? Double), try XCTUnwrap(eyes[0]["height"] as? Double))
        }
        let wide = try eye("crew-permission", 64), idle = try eye("crew-run", 4)
        XCTAssertGreaterThan(wide.width, idle.width * 1.1)
        XCTAssertGreaterThan(wide.height, idle.height * 1.1)
    }

    func testCrewEyesStayRound() throws {
        let clips = try rawClips()
        for name in Self.crewDurations.keys {
            let frames = try XCTUnwrap(clips[name]?["frames"] as? [[String: Any]], name)
            for frame in frames {
                for eye in try XCTUnwrap(frame["eyes"] as? [[String: Any]]) {
                    let width = try XCTUnwrap(eye["width"] as? Double), height = try XCTUnwrap(eye["height"] as? Double)
                    XCTAssertLessThanOrEqual(height, 1.3 * width + 0.0001, name)
                }
            }
        }
    }

    func testDoneRingFlashesOnceAfterTheCometReturns() throws {
        let done = try clip("crew-done")
        let comet = frames(done, to: 2.4), ball = frames(done, from: 2.4)
        XCTAssertTrue(comet.allSatisfy { $0.ring == 0 && !$0.arcEyes })
        XCTAssertGreaterThanOrEqual(ball.map(\.ring).max()!, 0.9)
        XCTAssertEqual(done.frames.last!.ring, 0, accuracy: 0.001)
        XCTAssertTrue(ball.allSatisfy(\.arcEyes))
        XCTAssertTrue(ball.suffix(10).allSatisfy { $0.eyes.count == 2 && $0.eyes.allSatisfy { $0.opacity > 0.9 } })
    }

    /// 等输入去掉了快闪和抖动：光晕和等审批一样 4 秒一次慢呼吸，「?」全程挂着
    func testInputGlowBreathesSlowlyUnderTheQuestionMark() throws {
        let input = try clip("crew-input")
        let glow = input.frames.map(\.glow)
        XCTAssertEqual(glow.min()!, 0.25, accuracy: 0.001)
        XCTAssertGreaterThan(glow.max()!, 0.65)
        XCTAssertLessThan(abs(glow.first! - glow.last!), 0.01)
        XCTAssertTrue(zip(glow, glow.dropFirst()).allSatisfy { abs($1 - $0) < 0.05 }, "慢呼吸不能跳")
        XCTAssertTrue(input.frames.allSatisfy { $0.symbol == .question })
    }

    func testPermissionGlowBreathesSlowly() throws {
        let glow = try clip("crew-permission").frames.map(\.glow)
        XCTAssertEqual(glow.min()!, 0.25, accuracy: 0.001)
        XCTAssertGreaterThan(glow.max()!, 0.65)
        XCTAssertLessThan(abs(glow.first! - glow.last!), 0.01)
        XCTAssertTrue(zip(glow, glow.dropFirst()).allSatisfy { abs($1 - $0) < 0.05 }, "慢呼吸不能跳")
    }

    /// 失联半眼皮，每轮 3 秒附近慢而重地合一次眼，其余时间眼皮停在一半
    func testStaleHalfLidsBlinkHeavilyOnceALoop() throws {
        let stale = try clip("crew-stale")
        XCTAssertTrue(stale.frames.allSatisfy { $0.lids >= 0.5 && $0.glow == 0 && $0.ring == 0 && !$0.arcEyes && $0.eyes.count == 2 })
        XCTAssertTrue(frames(stale, to: 2.75).allSatisfy { $0.lids == 0.5 }, "前半程半眼皮")
        XCTAssertTrue(frames(stale, from: 3.05, to: 3.4).allSatisfy { $0.lids > 0.99 }, "3.05 到 3.35 秒合上")
        XCTAssertEqual(stale.frames.last!.lids, 0.5, accuracy: 0.001)
    }

    func testDoneSmilesOnlyAfterTheComet() throws {
        let done = try clip("crew-done")
        let frames = done.frames
        let comet = frames.prefix(Int(2.4 * done.fps)), ball = frames.dropFirst(Int(2.4 * done.fps))
        XCTAssertTrue(comet.allSatisfy { !$0.arcEyes }, "彗星段平视")
        XCTAssertTrue(ball.allSatisfy { $0.arcEyes && $0.eyes.count == 2 && $0.lids == 0 }, "回球后笑眼")
        XCTAssertTrue(frames.allSatisfy { $0.symbol == nil && $0.glow == 0 })
    }

    func testBodyPiecesDecodeAsBodyMaterial() throws {
        let compacting = try clip("crew-compacting")
        let thinking = compacting.frame(at: 3.3, loop: true)
        XCTAssertEqual(thinking.dots.count, 2)
        XCTAssertTrue(thinking.dots.allSatisfy { $0.material == .body })
        let burst = compacting.frame(at: 0.5, loop: true)
        XCTAssertFalse(burst.dots.isEmpty)
        XCTAssertTrue(burst.dots.allSatisfy { $0.material == .solid })
        let alert = try clip("crew-permission").frame(at: 1, loop: true)
        XCTAssertEqual(alert.dots.count, 1)
        XCTAssertEqual(alert.dots.first?.material, .body)
        XCTAssertTrue(alert.eyes.isEmpty, "整个身体变成「!」时没有眼睛")
    }

    /// 六段小刻片段一段都不能少：删光的文件整份作废
    func testFileWithoutCrewClipsIsVoid() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.url)) as? [String: Any])
        var clips = try XCTUnwrap(json["clips"] as? [String: Any])
        for name in Self.crewDurations.keys { clips[name] = nil }
        json["clips"] = clips
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bloub-session-only-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(BloubArt(url: url))
    }

    /// 包络越界的帧解不出来：那段算坏了，整份作废
    func testEnvelopeOutOfRangeVoidsTheFile() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.url)) as? [String: Any])
        var clips = try XCTUnwrap(json["clips"] as? [String: Any])
        var run = try XCTUnwrap(clips["crew-run"] as? [String: Any])
        var frames = try XCTUnwrap(run["frames"] as? [[String: Any]])
        frames[0]["glow"] = 2
        run["frames"] = frames
        clips["crew-run"] = run
        json["clips"] = clips
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bloub-bad-glow-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(BloubArt(url: url))
    }

    func testOneShotClipHoldsItsLastFrameAndLoopWraps() throws {
        let done = try clip("crew-done")
        XCTAssertEqual(done.frame(at: 99, loop: false).body, done.frames.last!.body)
        XCTAssertEqual(done.frame(at: done.duration, loop: true).body, done.frames[0].body)
        XCTAssertEqual(done.frame(at: -1, loop: true).body, done.frames[0].body)
        XCTAssertEqual(done.frame(at: .nan, loop: false).body, done.frames[0].body)
        XCTAssertEqual(done.duration, 6, accuracy: 0.001)
    }

    func testRunKeepsSwirlRingsInsideTheSlot() throws {
        let run = try clip("crew-run").frames
        let ringed = run.filter { !$0.arcs.isEmpty }
        XCTAssertFalse(ringed.isEmpty)
        // 环绕线和预览一样不缩（曾按 0.86 挤进半槽 122.7 单位，线条太细）：伸出半槽但不出 48pt 位图的半宽 218 单位
        var reach = 0.0
        for frame in ringed {
            for arc in frame.arcs {
                reach = max(reach, abs(arc.front.boundingRect.minX), abs(arc.front.boundingRect.maxX), abs(arc.back.boundingRect.minX), abs(arc.back.boundingRect.maxX))
            }
        }
        XCTAssertGreaterThan(reach, 122, "缩过的旧导出")
        XCTAssertLessThan(reach, 218)
    }

    func testDefaultStyleMatchesSessionConstants() {
        let style = BloubArt.Style()
        XCTAssertEqual(style.skin, .glass)
        XCTAssertEqual(style.rim, BloubArt.rimColors)
        XCTAssertNil(style.fill)
        XCTAssertEqual(style.lid, Color(white: 0.11))
        XCTAssertNil(style.glow)
        XCTAssertEqual(style.opacity, 1)
        XCTAssertFalse(style.compactSymbol)
        XCTAssertFalse(style.small, "AI 页保持大档描边")
    }

    func testPalettesFollowTheMoodLikeThePreviewStatesTable() throws {
        let hex = { (value: String) in try XCTUnwrap(BloubArt.color(value), value) }
        XCTAssertEqual(CrewStyle.warmRim, try ["#FF7A3C", "#FF487A", "#FFB05C", "#FFE078", "#FF6C54", "#FF7A3C"].map(hex))
        XCTAssertEqual(CrewStyle.coolRim, BloubArt.rimColors)
        XCTAssertEqual(CrewStyle.ashRim, try ["#787E8C", "#969CAA", "#787E8C"].map(hex))
        let table: [(CrewMood, [Color], (String, String), String)] = [
            (.run, CrewStyle.warmRim, ("#FFB36B", "#FF6A5B"), "#FF8E63"),
            (.permission, CrewStyle.warmRim, ("#FFD66B", "#FF8A4B"), "#FFAE58"),
            (.input, CrewStyle.warmRim, ("#FFA36B", "#FF5C8A"), "#FF7E79"),
            (.compacting, CrewStyle.coolRim, ("#8CF5D2", "#2BC48A"), "#5EDDAE"),
            (.done, CrewStyle.coolRim, ("#8FE8FF", "#3B9CF5"), "#63C2FA"),
            (.stale, CrewStyle.ashRim, ("#9AA1AE", "#5B6270"), "#7A8290")
        ]
        for (mood, rim, fill, lid) in table {
            let palette = CrewStyle.palette(for: mood)
            XCTAssertEqual(palette.rim, rim, "\(mood)")
            XCTAssertEqual(palette.fill.top, try hex(fill.0), "\(mood)")
            XCTAssertEqual(palette.fill.bottom, try hex(fill.1), "\(mood)")
            XCTAssertEqual(palette.lid, try hex(lid), "\(mood)")
            XCTAssertEqual(palette.rim.first, palette.rim.last, "锥形渐变首尾同色才不留缝")
            XCTAssertEqual(CrewStyle.style(mood: mood, skin: .glass).rim, rim, "玻璃套系描边只看冷暖 \(mood)")
            XCTAssertEqual(CrewStyle.style(mood: mood, skin: .gradient).rim, rim, "渐变套系只换填色 \(mood)")
        }
    }

    func testStaleStyleIsAshAndOpaque() {
        let style = CrewStyle.style(mood: .stale, skin: .glass)
        XCTAssertEqual(style.opacity, 1, "第 7 版预览的失联不半透明")
        XCTAssertEqual(style.rim, CrewStyle.ashRim)
        XCTAssertNil(style.glow)
        let gradient = CrewStyle.style(mood: .stale, skin: .gradient)
        XCTAssertEqual(gradient.fill?.top, CrewStyle.ash.fill.top)
        XCTAssertEqual(gradient.lid, CrewStyle.ash.lid)
    }

    func testWaitTiersChangeGlowAndDustyBorrowsTheStaleClip() {
        XCTAssertEqual(CrewStyle.style(mood: .permission, skin: .glass, tier: .lingering).glow, CrewStyle.orange)
        XCTAssertEqual(CrewStyle.style(mood: .input, skin: .glass, tier: .lingering).glow, CrewStyle.orange)
        XCTAssertEqual(CrewStyle.style(mood: .permission, skin: .glass, tier: .lingering).rim, CrewStyle.warmRim, "满 3 分钟只换光晕")
        let dusty = CrewStyle.style(mood: .input, skin: .glass, tier: .dusty)
        XCTAssertEqual(dusty.glow, CrewStyle.red)
        XCTAssertEqual(dusty.rim, CrewStyle.ashRim, "落灰：灰身")
        XCTAssertEqual(dusty.glowAmount, 0.5, "失联片段没有光晕帧，量由样式给")
        XCTAssertNil(CrewStyle.style(mood: .permission, skin: .glass, tier: .lingering).glowAmount, "橙档还用片段自己的呼吸")
        XCTAssertNil(CrewStyle.style(mood: .run, skin: .glass, tier: .dusty).glow, "不在等的没有档")
        XCTAssertEqual(CrewStyle.style(mood: .run, skin: .glass, tier: .dusty).rim, CrewStyle.warmRim)
        XCTAssertEqual(CrewMood.permission.clip(tier: .dusty), "crew-stale")
        XCTAssertEqual(CrewMood.permission.clip(tier: .lingering), "crew-permission")
        XCTAssertEqual(CrewMood.input.still(tier: .dusty).clip, "crew-stale")
        XCTAssertEqual(CrewMood.done.clip(tier: .dusty), "crew-done")
        XCTAssertEqual(CrewPlayback.clip(mood: .permission, tier: .dusty, elapsed: 1, still: false).clip, "crew-stale")
        XCTAssertEqual(CrewPlayback.clip(mood: .permission, tier: .dusty, elapsed: 1, still: true).time, CrewMood.stale.still.time)
    }

    func testWaitingMoodsGetTheirGlowColors() throws {
        XCTAssertEqual(CrewStyle.style(mood: .permission, skin: .glass).glow, try XCTUnwrap(BloubArt.color("#FFC53D")))
        XCTAssertEqual(CrewStyle.style(mood: .input, skin: .glass).glow, try XCTUnwrap(BloubArt.color("#7DE3F7")))
        for mood in [CrewMood.compacting, .run, .done] {
            let style = CrewStyle.style(mood: mood, skin: .glass)
            XCTAssertNil(style.glow, "\(mood)")
            XCTAssertEqual(style.opacity, 1, "\(mood)")
        }
    }

    func testSkinSelectsFillAndLid() {
        let glass = CrewStyle.style(mood: .run, skin: .glass)
        XCTAssertEqual(glass.skin, .glass)
        XCTAssertNil(glass.fill)
        XCTAssertEqual(glass.lid, CrewStyle.glassLid)
        XCTAssertTrue(glass.compactSymbol)
        XCTAssertTrue(glass.small, "小刻一律小尺寸档")
        let gradient = CrewStyle.style(mood: .run, skin: .gradient)
        XCTAssertEqual(gradient.skin, .gradient)
        XCTAssertEqual(gradient.fill?.top, CrewStyle.coral.fill.top)
        XCTAssertEqual(gradient.fill?.bottom, CrewStyle.coral.fill.bottom)
        XCTAssertEqual(gradient.lid, CrewStyle.coral.lid)
    }

    func testMoodOrderClipsAndStillFrames() {
        XCTAssertEqual(CrewMood.allCases.sorted(), [.permission, .input, .compacting, .run, .done, .stale])
        XCTAssertEqual(CrewMood.allCases.map(\.clip), ["crew-permission", "crew-input", "crew-compacting", "crew-run", "crew-done", "crew-stale"])
        XCTAssertEqual(CrewMood.done.still.clip, "crew-done")
        XCTAssertEqual(CrewMood.done.still.time, 3.0)
        XCTAssertEqual(CrewMood.compacting.still.time, 3.2)
        XCTAssertEqual(CrewMood.permission.still.time, 1.6)
        XCTAssertEqual(CrewMood.stale.still.clip, "crew-stale")
    }

    /// 等待两段的符号与眼睛（原来按会话片段验）：等输入全程带「?」和眼睛，等审批前 2.4 秒身体就是「!」没有眼睛、回球后才有
    func testWaitingClipsKeepSymbolsAndEyes() throws {
        let input = try clip("crew-input")
        XCTAssertTrue(input.frames.allSatisfy { $0.symbol == .question && !$0.eyes.isEmpty && !$0.body.isEmpty && $0.alpha == 1 })
        for (current, next) in zip(input.frames, input.frames.dropFirst() + [input.frames[0]]) {
            XCTAssertLessThan(abs(current.body.boundingRect.width - next.body.boundingRect.width), 12)
        }
        let permission = try clip("crew-permission")
        XCTAssertTrue(permission.frames.allSatisfy { $0.symbol == nil && !$0.body.isEmpty })
        XCTAssertTrue(permission.frames[6...48].allSatisfy { $0.eyes.isEmpty }, "「!」那段没有眼睛")
        XCTAssertTrue(permission.frames[49...].allSatisfy { !$0.eyes.isEmpty }, "回球后有眼睛")
        XCTAssertTrue(permission.frame(at: CrewMood.permission.still.time, loop: false).eyes.isEmpty, "定格帧就是「!」")
        XCTAssertNotEqual(permission.frames[20].body, input.frames[20].body)
    }

    /// 在跑的环绕线、压缩中的粒子、六段的循环接缝（原来按会话片段验）
    func testRunKeepsOrbitsAndCompactingKeepsParticles() throws {
        let run = try clip("crew-run")
        let orbit = try XCTUnwrap(run.frames.first { !$0.arcs.isEmpty })
        XCTAssertTrue(orbit.arcs.allSatisfy { !$0.front.isEmpty && !$0.back.isEmpty })
        let burst = try clip("crew-compacting").frame(at: 0.5, loop: true)
        XCTAssertFalse(burst.dots.isEmpty)
        XCTAssertTrue(burst.dotsBehind)
        for name in Self.crewDurations.keys {
            let loop = try clip(name)
            XCTAssertEqual(loop.frame(at: loop.duration, loop: true).body, loop.frames[0].body, name)
        }
        XCTAssertNil(BloubArt(url: Self.root.appendingPathComponent("Resources/missing-bloub.json")))
    }
}
