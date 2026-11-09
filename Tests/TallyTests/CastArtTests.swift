import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import Tally

/// 角色素材的契约：池子与字段、身体拟合、眼睛驱动、步态、带角色的渲染、素材缺失时的退化。
/// `Resources/cast/`（付费素材，公开快照不带）不在时整组跳过。
@MainActor
final class CastArtTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let castDirectory = root.appendingPathComponent("Resources/cast")
    static let framesURL = root.appendingPathComponent("Resources/bloub/frames.json")
    static let art = CastArt(directory: castDirectory)
    static let bloub = BloubArt(url: framesURL)

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.castDirectory.appendingPathComponent("cast.json").path), "Resources/cast/cast.json 不在，角色素材用例跳过")
    }

    private func clip(_ mood: CrewMood) throws -> BloubArt.Clip { try XCTUnwrap(XCTUnwrap(Self.bloub).clips[mood.clip], mood.clip) }
    private func actor(_ name: String, inverted: Bool = false, amp: Double, frame: Int, of clip: BloubArt.Clip) throws -> CastActor {
        try XCTUnwrap(CastActor(art: Self.art, member: CastMember(name: name, inverted: inverted), amp: amp, frameIndex: frame, frameCount: clip.frames.count), name)
    }

    /// 翅膀那一格的位图：48 × 32pt @2x、球心 (24, 19)，和 `CrewFrameCache` 同一套映射
    private func wingImage(_ frame: BloubArt.Frame, mood: CrewMood, actor: CastActor?) throws -> CGImage {
        let style = CrewStyle.style(mood: mood, skin: .glass)
        let renderer = ImageRenderer(content: Canvas { context, _ in
            context.translateBy(x: 24, y: 19)
            context.scaleBy(x: CrewGeometry.scale, y: CrewGeometry.scale)
            frame.draw(in: context, time: 0, style: style, actor: actor)
        }.frame(width: 48, height: 32))
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    private func hasWhitePixel(_ image: CGImage) -> Bool {
        let px = pixels(image)
        return stride(from: 0, to: px.count, by: 4).contains { px[$0] >= 200 && px[$0 + 1] >= 200 && px[$0 + 2] >= 200 && px[$0 + 3] >= 200 }
    }

    func testPoolHasFifteenMembersWithBallFirst() {
        XCTAssertEqual(Self.art.pool.count, 15)
        XCTAssertEqual(Self.art.pool.first, .ball)
        XCTAssertEqual(Self.art.characters.count, 10)
        XCTAssertEqual(Set(Self.art.pool).count, 15, "池子里没有重复的角色")
    }

    func testEveryCharacterHasTwoEyesAndNormalizedOutline() {
        for (name, character) in Self.art.characters {
            XCTAssertEqual(character.eyes.count, 2, name)
            let box = character.outline.boundingRect
            XCTAssertTrue((196...204).contains(max(box.width, box.height)), "\(name) 轮廓长边 \(max(box.width, box.height))")
            XCTAssertGreaterThan(character.bitmapRect.width, 0, name)
            XCTAssertLessThan(character.eyes[0].center.x, character.eyes[1].center.x, "\(name) 左眼在前")
        }
        XCTAssertNotNil(Self.art.characters["sheep"]?.face, "羊有脸色块")
        XCTAssertNotNil(Self.art.bitmap(CastMember(name: "cloud", inverted: true)))
        XCTAssertNil(Self.art.bitmap(.ball))
    }

    func testRunFrameZeroFitsAsUnitCircle() throws {
        let fit = try clip(.run).frames[0].fit
        XCTAssertTrue((0.98...1.02).contains(fit.sx), "sx \(fit.sx)")
        XCTAssertTrue((0.98...1.02).contains(fit.sy), "sy \(fit.sy)")
        XCTAssertLessThanOrEqual(abs(fit.theta), 0.01)
    }

    func testStaleBodyLeans() throws {
        XCTAssertGreaterThanOrEqual(abs(try clip(.stale).frames[0].fit.theta), 0.03)
    }

    func testInputBodySlidesSideways() throws {
        XCTAssertTrue(try clip(.input).frames.contains { $0.fit.cx >= 10 }, "等输入时头往旁边滑")
    }

    func testDoneShrinksBeforeCollapsingToDot() throws {
        XCTAssertTrue(try clip(.done).frames.contains { !$0.eyeSpecs.isEmpty && $0.fit.sx <= 0.3 }, "缩点前有眼的过渡帧")
    }

    func testRestEyesMatchRunMedians() throws {
        let frames = try clip(.run).frames.filter { $0.eyeSpecs.count == 2 }
        func median(_ values: [Double]) -> Double { let sorted = values.sorted(); return sorted[sorted.count / 2] }
        for i in 0..<2 {
            let rest = CastArt.restEyes[i]
            XCTAssertLessThanOrEqual(abs(median(frames.map { $0.eyeSpecs[i].center.x }) - rest.center.x), 3)
            XCTAssertLessThanOrEqual(abs(median(frames.map { $0.eyeSpecs[i].center.y }) - rest.center.y), 3)
            XCTAssertLessThanOrEqual(abs(median(frames.map { $0.eyeSpecs[i].size.width }) - rest.size.width), 3)
            XCTAssertLessThanOrEqual(abs(median(frames.map { $0.eyeSpecs[i].size.height }) - rest.size.height), 3)
        }
    }

    func testEyeOffsetsFollowGaze() throws {
        let run = try clip(.run)
        let rest = try actor("cat", amp: 0, frame: 0, of: run).eyeOffsets(run.frames[0])
        XCTAssertEqual(rest.count, 2)
        XCTAssertTrue(rest.allSatisfy { hypot($0.x, $0.y) <= 3 }, "第 0 帧眼睛在静止位 \(rest)")
        let glance = try actor("cat", amp: 0, frame: 30, of: run).eyeOffsets(run.frames[30])
        XCTAssertTrue(glance.allSatisfy { $0.x >= 20 }, "第 30 帧瞟右 \(glance)")
    }

    func testGaitIsIdentityAtZeroAmpAndSeamless() {
        for kind in [CastArt.Gait.bounce, .sway, .bob, .float, .tick] {
            XCTAssertEqual(CastArt.gait(kind: kind, phase: 0.37, amp: 0), .identity, "\(kind)")
            let start = CastArt.gait(kind: kind, phase: 0, amp: 1), end = CastArt.gait(kind: kind, phase: 1, amp: 1)
            for (a, b) in [(start.a, end.a), (start.b, end.b), (start.c, end.c), (start.d, end.d), (start.tx, end.tx), (start.ty, end.ty)] {
                XCTAssertEqual(a, b, accuracy: 1e-9, "\(kind) 接缝")
            }
        }
        XCTAssertEqual(CastArt.gait(kind: .bounce, phase: 0, amp: 1).ty, 6, accuracy: 1e-9)
    }

    func testStaleLidsCoverEyes() throws {
        let stale = try clip(.stale)
        let shut = try XCTUnwrap(stale.frames.firstIndex { $0.lids == 1 }, "失联片段有合眼帧")
        let open = try wingImage(stale.frames[0], mood: .stale, actor: actor("cat", amp: 0, frame: 0, of: stale))
        let closed = try wingImage(stale.frames[shut], mood: .stale, actor: actor("cat", amp: 0, frame: shut, of: stale))
        XCTAssertNotEqual(pixels(open), pixels(closed))
        XCTAssertTrue(hasWhitePixel(open), "第 0 帧眼睛半睁，有眼白")
    }

    func testPermissionMorphBoundary() throws {
        let permission = try clip(.permission)
        XCTAssertFalse(permission.frames[5].eyeSpecs.isEmpty)
        XCTAssertTrue(permission.frames[6].eyeSpecs.isEmpty)
        let eyed = try wingImage(permission.frames[5], mood: .permission, actor: actor("cat", amp: 0.5, frame: 5, of: permission))
        let glass = try wingImage(permission.frames[6], mood: .permission, actor: actor("cat", amp: 0.5, frame: 6, of: permission))
        XCTAssertNotEqual(pixels(eyed), pixels(glass))
    }

    func testGaitChangesTheRenderedFrame() throws {
        let run = try clip(.run)
        let moving = try wingImage(run.frames[18], mood: .run, actor: actor("cat", amp: 1, frame: 18, of: run))
        let still = try wingImage(run.frames[18], mood: .run, actor: actor("cat", amp: 0, frame: 18, of: run))
        XCTAssertNotEqual(pixels(moving), pixels(still))
    }

    /// 翅膀的位图缓存：定格帧（步态 0）和同一帧号的动态帧是两张图
    func testFrameCacheKeepsStillAndMovingFramesApart() throws {
        let cache = CrewFrameCache(art: try XCTUnwrap(Self.bloub), cast: Self.art)
        let look = CrewFrameCache.Look(mood: .run, skin: .glass, cast: CastMember(name: "cat", inverted: false))
        let moving = try XCTUnwrap(cache.image(CrewFrameCache.Key(clip: "crew-run", index: 18, look: look, still: false), scale: 2))
        let still = try XCTUnwrap(cache.image(CrewFrameCache.Key(clip: "crew-run", index: 18, look: look, still: true), scale: 2))
        XCTAssertNotEqual(pixels(moving), pixels(still))
        XCTAssertEqual(cache.count, 2)
    }

    func testExtraMotionRendersAndCacheKeepsItSeparate() throws {
        let cache = CrewFrameCache(art: try XCTUnwrap(Self.bloub), cast: Self.art)
        for (mood, index, kind) in [(CrewMood.run, 60, CastMotion.Kind.think), (.input, 30, .unsure), (.stale, 40, .sleep), (.permission, 60, .surprise), (.done, 60, .happy)] {
            for name in ["cat", "folder", "bulb"] {
                let look = CrewFrameCache.Look(mood: mood, skin: .glass, cast: CastMember(name: name, inverted: false))
                let normal = try XCTUnwrap(cache.image(CrewFrameCache.Key(clip: mood.clip, index: index, look: look, still: false), scale: 2))
                let step = kind == .unsure ? 5 : 10
                let changed = try XCTUnwrap(cache.image(CrewFrameCache.Key(clip: mood.clip, index: index, look: look, still: false,
                                                                            motion: CastMotion(kind: kind, step: step)), scale: 2))
                XCTAssertTrue(pixels(normal) != pixels(changed), "\(name) \(kind)")
            }
        }
    }

    func testMissingDirectoryDegradesToBall() {
        let art = CastArt(directory: FileManager.default.temporaryDirectory.appendingPathComponent("cast-\(UUID().uuidString)"))
        XCTAssertEqual(art.pool, [.ball])
        XCTAssertTrue(art.characters.isEmpty)
        XCTAssertNil(CastActor(art: art, member: CastMember(name: "cat", inverted: false), amp: 1, frameIndex: 0, frameCount: 10))
    }

    private func copyCast(_ mutate: (URL) throws -> Void) throws -> URL {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("cast-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: Self.castDirectory, to: copy)
        try mutate(copy)
        return copy
    }

    func testMissingBitmapDegradesToBall() throws {
        let copy = try copyCast { try FileManager.default.removeItem(at: $0.appendingPathComponent("cat.png")) }
        defer { try? FileManager.default.removeItem(at: copy) }
        XCTAssertEqual(CastArt(directory: copy).pool, [.ball])
    }

    func testUnknownPoolEntryDegradesToBall() throws {
        let copy = try copyCast { directory in
            let url = directory.appendingPathComponent("cast.json")
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            var pool = try XCTUnwrap(json["pool"] as? [[Any]])
            pool.append(["ghost", false])
            json["pool"] = pool
            try JSONSerialization.data(withJSONObject: json).write(to: url)
        }
        defer { try? FileManager.default.removeItem(at: copy) }
        XCTAssertEqual(CastArt(directory: copy).pool, [.ball])
    }

    /// 15 个角色各一帧（在跑第 0 帧、静止位）画成一条 68pt 的条带，肉眼核对每个角色切对了格、眼睛在脸上
    func testStripOfEveryMemberForEyeballing() throws {
        let run = try clip(.run)
        let cell: CGFloat = 100
        let style = CrewStyle.style(mood: .run, skin: .glass)
        let renderer = ImageRenderer(content: Canvas { context, _ in
            for (index, member) in Self.art.pool.enumerated() {
                var cellContext = context
                cellContext.translateBy(x: cell * (CGFloat(index) + 0.5), y: cell * 0.5)
                cellContext.scaleBy(x: 68 / 200, y: 68 / 200)
                let actor = CastActor(art: Self.art, member: member, amp: 0, frameIndex: 0, frameCount: run.frames.count)
                run.frames[0].draw(in: cellContext, time: 0, style: style, actor: actor)
            }
        }.frame(width: cell * CGFloat(Self.art.pool.count), height: cell).background(Color(white: 0.12)))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cast-strip.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
    }
}
