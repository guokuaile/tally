import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import Tally

@MainActor
final class CastFeatureTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let art = CastArt(directory: root.appendingPathComponent("Resources/cast"))
    private static let bloub = BloubArt(url: root.appendingPathComponent("Resources/bloub/frames.json"))

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.art.pool.count == 15, "Local character artwork is unavailable")
    }

    private func frame() throws -> (BloubArt.Frame, Int) {
        let clip = try XCTUnwrap(Self.bloub?.clips["crew-run"])
        return (clip.frames[0], clip.frames.count)
    }

    private func actor(_ name: String, motion: CastMotion? = nil, inverted: Bool = false, amp: Double = 0) throws -> CastActor {
        let (_, count) = try frame()
        return try XCTUnwrap(CastActor(art: Self.art, member: CastMember(name: name, inverted: inverted), amp: amp, frameIndex: 0, frameCount: count, motion: motion))
    }

    private func render(_ name: String, motion: CastMotion? = nil, inverted: Bool = false, size: CGFloat = 64) throws -> CGImage {
        let (frame, _) = try frame()
        let cast = try actor(name, motion: motion, inverted: inverted)
        let style = CrewStyle.style(mood: .run, skin: .glass)
        let renderer = ImageRenderer(content: Canvas { context, bounds in
            context.translateBy(x: bounds.width / 2, y: bounds.height / 2)
            context.scaleBy(x: bounds.width / 240, y: bounds.height / 240)
            frame.draw(in: context, time: 0, style: style, actor: cast)
        }.frame(width: size, height: size).background(Color.black))
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    func testTipShapesBendIndependentlyOfBodyTransform() throws {
        let (frame, _) = try frame()
        for name in ["cat", "devil", "soot"] {
            let plain = try actor(name)
            let changed = try actor(name, motion: CastMotion(kind: .surprise, step: 10))
            XCTAssertNotEqual(plain.localShape(frame).cgPath.boundingBoxOfPath,
                              changed.localShape(frame).cgPath.boundingBoxOfPath, name)
            XCTAssertNotEqual(changed.localShape(frame).cgPath.boundingBoxOfPath,
                              changed.character.outline.applying(changed.matrix(frame)).cgPath.boundingBoxOfPath,
                              "\(name) tip needs to move separately from whole-body pose")
            let normal = pixels(try render(name))
            let featured = pixels(try render(name, motion: CastMotion(kind: .surprise, step: 10)))
            XCTAssertTrue(normal != featured, name)
        }
    }

    func testSleepingCatEarsDropWhileLowerFaceKeepsItsOutline() throws {
        let (frame, _) = try frame()
        let sleeping = try actor("cat", motion: CastMotion(kind: .sleep, step: 10))
        let local = sleeping.localShape(frame)
        let rigid = sleeping.character.outline.applying(sleeping.matrix(frame))
        XCTAssertGreaterThan(local.boundingRect.minY, rigid.boundingRect.minY + 8)
        var upperDifference = 0
        var lowerDifference = 0
        for x in stride(from: -110.0, through: 110.0, by: 5) {
            for y in stride(from: -105.0, through: 100.0, by: 5) {
                let point = CGPoint(x: x, y: y)
                if local.contains(point) != rigid.contains(point) {
                    if y < -20 { upperDifference += 1 } else if y > 20 { lowerDifference += 1 }
                }
            }
        }
        XCTAssertGreaterThan(upperDifference, 0)
        XCTAssertEqual(lowerDifference, 0)
    }

    func testThinkingTapsTwiceAndNodOffWakesAbruptly() throws {
        let (frame, _) = try frame()
        func vertical(_ kind: CastMotion.Kind, _ step: Int, variant: Int) throws -> Double {
            try actor("cat", motion: CastMotion(kind: kind, step: step, variant: variant)).matrix(frame).ty
        }
        let tapBefore = try vertical(.think, 5, variant: 1)
        let tapMiddle = try vertical(.think, 10, variant: 1)
        let tapAfter = try vertical(.think, 15, variant: 1)
        XCTAssertGreaterThan(tapBefore, tapMiddle + 3)
        XCTAssertGreaterThan(tapAfter, tapMiddle + 3)
        let nod = try vertical(.unsure, 9, variant: 5)
        let wake = try vertical(.unsure, 10, variant: 5)
        XCTAssertGreaterThan(nod, 0)
        XCTAssertLessThan(wake, 0)
    }

    func testWakeLidsOpenEarlyAndStayOpenWithoutHidingClipLids() throws {
        let (frame, _) = try frame()
        XCTAssertEqual(frame.lids, 0)
        var previous = Double.infinity
        for step in 0..<20 {
            let coverage = try actor("cat", motion: .init(kind: .wake, step: step)).lidCoverage(frame)
            XCTAssertLessThanOrEqual(coverage, previous, "Wake lids closed again at step \(step)")
            previous = coverage
        }
        XCTAssertEqual(try actor("cat", motion: .init(kind: .wake, step: 0)).lidCoverage(frame), 0.4)
        XCTAssertEqual(try actor("cat", motion: .init(kind: .wake, step: 7)).lidCoverage(frame), 0)
        XCTAssertEqual(try actor("cat", motion: .init(kind: .wake, step: 19)).lidCoverage(frame),
                       try actor("cat").lidCoverage(frame))

        var clipWithLids = frame
        clipWithLids.lids = 0.6
        for step in [0, 7, 19] {
            XCTAssertEqual(try actor("cat", motion: .init(kind: .wake, step: step)).lidCoverage(clipWithLids), 0.6)
        }
    }

    func testEachCharacterFeatureChangesRenderedPixels() throws {
        let examples: [(String, CastMotion)] = [
            ("cat", .init(kind: .surprise, step: 10)),
            ("devil", .init(kind: .surprise, step: 10)),
            ("sheep", .init(kind: .sleep, step: 10)),
            ("soot", .init(kind: .surprise, step: 10)),
            ("cloud", .init(kind: .sleep, step: 10)),
            ("mac", .init(kind: .unsure, step: 10)),
            ("monitor", .init(kind: .sleep, step: 10)),
            ("gamepad", .init(kind: .unsure, step: 5)),
            ("folder", .init(kind: .think, step: 10)),
            ("bulb", .init(kind: .surprise, step: 10)),
        ]
        for (name, motion) in examples {
            XCTAssertTrue(pixels(try render(name)) != pixels(try render(name, motion: motion)), name)
            XCTAssertTrue(pixels(try render(name, size: 32)) != pixels(try render(name, motion: motion, size: 32)), "Small \(name)")
        }
        for name in ["cloud", "mac", "folder", "bulb"] {
            XCTAssertTrue(pixels(try render(name, inverted: true)) !=
                          pixels(try render(name, motion: .init(kind: .sleep, step: 10), inverted: true)), "Inverted \(name)")
        }
    }

    func testWaitingVariantsAndWakeClickRenderDistinctFrames() throws {
        let variants: [CastMotion] = [
            .init(kind: .think, step: 5, variant: 1), .init(kind: .think, step: 10, variant: 4),
            .init(kind: .unsure, step: 10, variant: 2), .init(kind: .unsure, step: 10, variant: 5),
            .init(kind: .sleep, step: 10, variant: 1), .init(kind: .sleep, step: 10, variant: 2),
            .init(kind: .hold, step: 3, variant: 1), .init(kind: .hold, step: 10, variant: 3),
            .init(kind: .wake, step: 10), .init(kind: .click, step: 10)
        ]
        let plain = pixels(try render("cat"))
        for motion in variants { XCTAssertTrue(plain != pixels(try render("cat", motion: motion)), "\(motion)") }
    }

    func testGamepadEyesDriftIndependentlyAndFreezeForReducedMotion() throws {
        let (_, count) = try frame()
        let active = try XCTUnwrap(CastActor(art: Self.art, member: CastMember(name: "gamepad", inverted: false), amp: 1,
                                             frameIndex: count / 4, frameCount: count))
        XCTAssertNotEqual(active.gazeDrift(for: 0), active.gazeDrift(for: 1))
        XCTAssertNotEqual(active.gazeDrift(for: 0), .zero)
        let still = try actor("gamepad", amp: 0)
        XCTAssertEqual(still.gazeDrift(for: 0), .zero)
        XCTAssertEqual(still.gazeDrift(for: 1), .zero)
        XCTAssertEqual(try actor("cat", amp: 1).gazeDrift(for: 0), .zero)
    }

    func testCharacterFeatureContactSheet() throws {
        let examples: [(String, CastMotion)] = [
            ("cat", .init(kind: .surprise, step: 10)), ("devil", .init(kind: .surprise, step: 10)),
            ("sheep", .init(kind: .sleep, step: 10)), ("soot", .init(kind: .surprise, step: 10)),
            ("cloud", .init(kind: .sleep, step: 10)), ("mac", .init(kind: .unsure, step: 10)),
            ("monitor", .init(kind: .sleep, step: 10)), ("gamepad", .init(kind: .unsure, step: 10)),
            ("folder", .init(kind: .think, step: 10)), ("bulb", .init(kind: .surprise, step: 10))
        ]
        let (frame, count) = try frame()
        let style = CrewStyle.style(mood: .run, skin: .glass)
        let renderer = ImageRenderer(content: Canvas { context, _ in
            for (index, example) in examples.enumerated() {
                for row in 0..<3 {
                    var cell = context
                    cell.translateBy(x: CGFloat(index) * 80 + 40, y: CGFloat(row) * 80 + 40)
                    cell.scaleBy(x: 64 / 240, y: 64 / 240)
                    let cast = CastActor(art: Self.art, member: CastMember(name: example.0, inverted: false), amp: 0,
                                         frameIndex: 0, frameCount: count,
                                         motion: row == 0 ? nil : row == 1 ? example.1 : CastMotion(kind: .sleep, step: 10))
                    frame.draw(in: cell, time: 0, style: style, actor: cast)
                }
            }
        }.frame(width: 800, height: 240).background(Color.black))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tally-cast-features.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
