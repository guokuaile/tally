import SwiftUI
import ImageIO

/// 角色池里的一员：名字加是否反相。玻璃球是 `ball`，没有位图与轮廓，走 bloub 原来的画法。
struct CastMember: Hashable {
    let name: String
    let inverted: Bool
    static let ball = CastMember(name: "ball", inverted: false)
}

/// 角色素材：`Resources/cast/cast.json` 与位图（字段契约见 docs/crew.md「角色池」）。
/// 读不到、解不开、校验不过都退回只有玻璃球：角色是锦上添花，刘海不能因为素材空着。
struct CastArt {
    enum Gait: String, Decodable { case bounce, sway, bob, float, tick }
    /// `#rrggbb`；反相版逐通道取 255 − c
    struct Tint: Equatable {
        let r: Double, g: Double, b: Double
        init?(hex: String) {
            guard hex.count == 7, hex.first == "#", let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
            r = Double((rgb >> 16) & 255) / 255; g = Double((rgb >> 8) & 255) / 255; b = Double(rgb & 255) / 255
        }
        func color(inverted: Bool) -> Color {
            inverted ? Color(red: 1 - r, green: 1 - g, blue: 1 - b) : Color(red: r, green: g, blue: b)
        }
    }
    struct Eye {
        /// 包围盒中心与大小（角色坐标，bloub 单位）
        let center: CGPoint
        let size: CGSize
        /// 放大系数：抠出来的眼睛统一放大到 bloub 眼的比例
        let scale: Double
        let white: Path
        let pupil: Path?
        let skin: Tint, whiteColor: Tint, pupilColor: Tint
    }
    /// 画在位图之上、眼睛之下的脸色块（羊）
    struct Face { let path: Path; let color: Tint }
    struct Character {
        let gait: Gait
        let whiteBodied: Bool
        let outline: Path
        /// 位图在角色坐标里的位置（230 px 对应 `size`）
        let bitmapRect: CGRect
        let eyes: [Eye]
        let face: Face?
    }
    static let bitmapSide = 230
    /// 文件缺失 / 解不开 / 校验不过时 `[.ball]`
    let pool: [CastMember]
    let characters: [String: Character]
    private let directory: URL
    private let bitmaps = BitmapCache()

    static let bundled = CastArt(directory: (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("cast"))

    init(directory: URL) {
        self.directory = directory
        guard let loaded = Self.load(directory) else {
            pool = [.ball]
            characters = [:]
            return
        }
        pool = loaded.pool
        characters = loaded.characters
    }

    /// 懒加载、进程内缓存；ball 为 nil。解不出来也记成 nil，不每帧重试
    func bitmap(_ member: CastMember) -> CGImage? {
        guard characters[member.name] != nil else { return nil }
        return bitmaps.image(at: directory.appendingPathComponent(Self.file(for: member)))
    }

    static func file(for member: CastMember) -> String { member.inverted ? "\(member.name)-inverted.png" : "\(member.name).png" }

    /// bloub 眼睛的静止位：`crew-run` 片段两只眼的中位数（实测 (−32.1, −7.5)、(32.95, −8.25)、30 × 36）
    static let restEyes: [(center: CGPoint, size: CGSize)] = [
        (CGPoint(x: -32, y: -8), CGSize(width: 30, height: 36)),
        (CGPoint(x: 33, y: -8), CGSize(width: 30, height: 36))
    ]

    /// 步态：按片段相位（帧号 / 帧数）不按墙钟，位图缓存键不变、循环接缝处连续；`amp` 0 恒为单位矩阵。bloub 单位
    static func gait(kind: Gait, phase: Double, amp: Double) -> CGAffineTransform {
        guard amp != 0 else { return .identity }
        switch kind {
        case .bounce:
            let q = (7 * phase).truncatingRemainder(dividingBy: 1), s = sin(.pi * q)
            return CGAffineTransform(translationX: 0, y: -14 * amp * s + 6 * amp * (1 - s)).scaledBy(x: 1 + 0.08 * amp * (1 - s), y: 1 - 0.08 * amp * (1 - s))
        case .sway:
            return CGAffineTransform(translationX: 10 * amp * sin(4 * .pi * phase), y: -6 * amp * sin(8 * .pi * phase)).rotated(by: 7 * .pi / 180 * amp * sin(4 * .pi * phase))
        case .bob:
            let s = sin(6 * .pi * phase)
            return CGAffineTransform(translationX: 0, y: -8 * amp * s).scaledBy(x: 1 + 0.06 * amp * s, y: 1 - 0.06 * amp * s)
        case .float:
            return CGAffineTransform(translationX: 0, y: -10 * amp * sin(4 * .pi * phase)).rotated(by: 5 * .pi / 180 * amp * sin(2 * .pi * phase))
        case .tick:
            let step = Int(floor(12 * phase)) % 2
            return CGAffineTransform(translationX: 0, y: -6 * amp * Double(step)).rotated(by: (step == 1 ? 3 : -3) * .pi / 180 * amp)
        }
    }

    fileprivate struct DataFile: Decodable {
        /// `["cat", false]`：名字加是否反相
        struct PoolEntry: Decodable {
            let name: String, inverted: Bool
            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                name = try c.decode(String.self)
                inverted = try c.decode(Bool.self)
            }
        }
        struct Eye: Decodable { let cx, cy, w, h, scale: Double; let white: [Double]; let pupil: [Double]?; let skin, whiteColor, pupilColor: String }
        struct Face: Decodable { let cx, cy, rx, ry, theta: Double; let color: String }
        struct Bitmap: Decodable { let x, y, size: Double }
        struct Character: Decodable { let gait: Gait; let whiteBodied: Bool; let outline: [Double]; let bitmap: Bitmap; let eyes: [Eye]; let face: Face? }
        let pool: [PoolEntry]
        let characters: [String: Character]
    }

    /// 校验不过整份作废：`pool` 第 0 个是 ball、引用的角色都在、轮廓非空、恰两只眼、位图边长为正、PNG 在且是 230 × 230（只读属性不解码）
    private static func load(_ directory: URL) -> (pool: [CastMember], characters: [String: Character])? {
        func fail(_ reason: String) -> (pool: [CastMember], characters: [String: Character])? {
            Log.error("cast/cast.json \(reason)，小刻只有玻璃球")
            return nil
        }
        let json = directory.appendingPathComponent("cast.json")
        // 公开仓库的构建不带素材（build-app.sh 只在有 cast.json 时复制），没有文件不是错，只有玻璃球
        guard FileManager.default.fileExists(atPath: json.path) else { return nil }
        guard let data = try? Data(contentsOf: json) else { return fail("读不到") }
        let decoded: DataFile
        do { decoded = try JSONDecoder().decode(DataFile.self, from: data) } catch { return fail("解不开：\(error)") }
        guard let first = decoded.pool.first, first.name == CastMember.ball.name, !first.inverted else { return fail("pool 第 0 个不是 ball") }
        var characters: [String: Character] = [:]
        for entry in decoded.pool.dropFirst() {
            if characters[entry.name] == nil {
                guard let raw = decoded.characters[entry.name] else { return fail("pool 里的 \(entry.name) 没有角色数据") }
                guard let character = Character(raw) else { return fail("\(entry.name) 的轮廓 / 眼睛 / 位图字段不合法") }
                characters[entry.name] = character
            }
            let png = directory.appendingPathComponent(file(for: CastMember(name: entry.name, inverted: entry.inverted)))
            guard pngSize(png) == CGSize(width: bitmapSide, height: bitmapSide) else { return fail("\(png.lastPathComponent) 缺失或不是 \(bitmapSide) × \(bitmapSide)") }
        }
        return (decoded.pool.map { CastMember(name: $0.name, inverted: $0.inverted) }, characters)
    }

    private static func pngSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    private final class BitmapCache {
        private var images: [URL: CGImage?] = [:]
        private let lock = NSLock()

        func image(at url: URL) -> CGImage? {
            lock.lock(); defer { lock.unlock() }
            if let hit = images[url] { return hit }
            let image = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            // 校验只读了 PNG 头，坏掉的图到这里才露馅；nil 也缓存（别每帧重试），所以只记一次
            if image == nil { Log.error("cast/\(url.lastPathComponent) 解不出来，这个角色只画轮廓和眼睛") }
            images[url] = image
            return image
        }
    }
}

extension CastArt.Character {
    fileprivate init?(_ raw: CastArt.DataFile.Character) {
        guard let outline = BloubArt.path(raw.outline), !outline.isEmpty, raw.eyes.count == 2, raw.bitmap.size > 0 else { return nil }
        var eyes: [CastArt.Eye] = []
        for eye in raw.eyes {
            guard let white = BloubArt.path(eye.white), !white.isEmpty, eye.w > 0, eye.h > 0, eye.scale > 0,
                  let skin = CastArt.Tint(hex: eye.skin), let whiteColor = CastArt.Tint(hex: eye.whiteColor), let pupilColor = CastArt.Tint(hex: eye.pupilColor) else { return nil }
            var pupil: Path? = nil
            if let ops = eye.pupil {
                guard let path = BloubArt.path(ops) else { return nil }
                pupil = path
            }
            eyes.append(CastArt.Eye(center: CGPoint(x: eye.cx, y: eye.cy), size: CGSize(width: eye.w, height: eye.h), scale: eye.scale,
                                    white: white, pupil: pupil, skin: skin, whiteColor: whiteColor, pupilColor: pupilColor))
        }
        var face: CastArt.Face? = nil
        if let raw = raw.face {
            guard let color = CastArt.Tint(hex: raw.color), raw.rx > 0, raw.ry > 0 else { return nil }
            let ellipse = Path(ellipseIn: CGRect(x: -raw.rx, y: -raw.ry, width: 2 * raw.rx, height: 2 * raw.ry))
            face = CastArt.Face(path: ellipse.applying(CGAffineTransform(translationX: raw.cx, y: raw.cy).rotated(by: raw.theta)), color: color)
        }
        self.init(gait: raw.gait, whiteBodied: raw.whiteBodied, outline: outline,
                  bitmapRect: CGRect(x: raw.bitmap.x, y: raw.bitmap.y, width: raw.bitmap.size, height: raw.bitmap.size), eyes: eyes.sorted { $0.center.x < $1.center.x }, face: face)
    }
}

/// 一帧要画的角色：角色数据 + 位图 + 步态幅度 + 片段里的相位。`BloubArt.Frame.draw(actor:)` 用；ball 造不出来（nil）。
struct CastActor {
    let member: CastMember
    let character: CastArt.Character
    let bitmap: CGImage?
    /// 步态幅度：在跑 1，等审批 / 等输入 / 压缩中 0.5，完成 / 失联 0；定格帧 0
    let amp: Double
    /// 帧号 / 片段帧数
    let phase: Double

    init?(art: CastArt, member: CastMember, amp: Double, frameIndex: Int, frameCount: Int) {
        guard let character = art.characters[member.name] else { return nil }
        self.member = member
        self.character = character
        bitmap = art.bitmap(member)
        self.amp = amp
        phase = frameCount > 0 ? Double(frameIndex) / Double(frameCount) : 0
    }

    static func amp(for mood: CrewMood) -> Double {
        switch mood {
        case .run: 1
        case .permission, .input, .compacting: 0.5
        case .done, .stale: 0
        }
    }

    /// 身体变换：bloub 这一帧的仿射拟合，再叠步态（先步态后拟合，和预览一致）
    func matrix(_ frame: BloubArt.Frame) -> CGAffineTransform {
        let fit = frame.fit
        let body = CGAffineTransform(translationX: fit.cx, y: fit.cy).rotated(by: fit.theta).scaledBy(x: fit.sx, y: fit.sy)
        return CastArt.gait(kind: character.gait, phase: phase, amp: amp).concatenating(body)
    }

    /// 两只眼相对静止位的位移（身体坐标系），给测试看
    func eyeOffsets(_ frame: BloubArt.Frame) -> [CGPoint] {
        let inverse = matrix(frame).inverted()
        return zip(frame.eyeSpecs, CastArt.restEyes).map { spec, rest in
            let p = spec.center.applying(inverse)
            return CGPoint(x: p.x - rest.center.x, y: p.y - rest.center.y)
        }
    }

    /// 黑身（原黑身、白身反相）用 lighten 让玻璃渐变透出来；白身原色正常盖住
    private var usesLighten: Bool { !(character.whiteBodied && !member.inverted) }

    /// 玻璃渐变填完、流光描边之前：位图裁在轮廓里画上去，脸色块跟着
    func paintBody(in base: GraphicsContext, clip: Path, matrix: CGAffineTransform) {
        var paint = base
        paint.clip(to: clip)
        paint.concatenate(matrix)
        if let bitmap {
            var sprite = paint
            if usesLighten { sprite.blendMode = .lighten }
            sprite.draw(Image(decorative: bitmap, scale: 1).resizable(), in: character.bitmapRect)
        }
        if let face = character.face { paint.fill(face.path, with: .color(face.color.color(inverted: member.inverted))) }
    }

    /// 眼睛：bloub 这一帧两只眼相对静止位的位移 / 缩放 / 旋转，换到身体坐标系后套在角色自己的眼睛上。`context` 已裁在身体里
    func drawEyes(in context: GraphicsContext, frame: BloubArt.Frame) {
        guard character.eyes.count == 2, frame.eyeSpecs.count == 2 else { return }
        let m = matrix(frame), inverse = m.inverted(), fit = frame.fit
        for (i, eye) in character.eyes.enumerated() {
            let spec = frame.eyeSpecs[i], rest = CastArt.restEyes[i]
            let p = spec.center.applying(inverse)
            let d = CGPoint(x: p.x - rest.center.x, y: p.y - rest.center.y)
            let sx = (spec.size.width / rest.size.width) / fit.sx, sy = (spec.size.height / rest.size.height) / fit.sy
            // 有瞳孔的眼白只跟一半位移，剩下的给瞳孔，眼珠才像在转；没瞳孔的整只眼跟 0.8
            let gw = eye.pupil == nil ? 0.8 : 0.5
            var layer = context
            layer.opacity *= spec.alpha
            layer.concatenate(m)
            layer.translateBy(x: eye.center.x + d.x * gw, y: eye.center.y + d.y * gw)
            layer.rotate(by: .radians(spec.rotation - fit.theta))
            layer.scaleBy(x: sx * eye.scale, y: sy * eye.scale)
            layer.translateBy(x: -eye.center.x, y: -eye.center.y)
            let white = eye.whiteColor.color(inverted: member.inverted)
            if frame.arcEyes {
                // 笑眼 / 合眼是一道弧：弦在眼睛下三分之一，弓顶顶到上缘
                var arc = Path()
                arc.move(to: CGPoint(x: eye.center.x - 0.55 * eye.size.width, y: eye.center.y + 0.12 * eye.size.height))
                arc.addQuadCurve(to: CGPoint(x: eye.center.x + 0.55 * eye.size.width, y: eye.center.y + 0.12 * eye.size.height),
                                 control: CGPoint(x: eye.center.x, y: eye.center.y - 0.5 * eye.size.height))
                layer.stroke(arc, with: .color(white), style: StrokeStyle(lineWidth: 0.23 * eye.size.width, lineCap: .round))
                continue
            }
            layer.fill(eye.white, with: .color(white))
            if let pupil = eye.pupil {
                var inner = layer
                inner.clip(to: eye.white)
                inner.translateBy(x: d.x * (1 - gw), y: d.y * (1 - gw))
                inner.fill(pupil, with: .color(eye.pupilColor.color(inverted: member.inverted)))
            }
            if frame.lids > 0 {
                var lid = layer
                lid.clip(to: eye.white)
                lid.fill(Path(CGRect(x: eye.center.x - eye.size.width, y: eye.center.y - eye.size.height / 2, width: 2 * eye.size.width, height: eye.size.height * frame.lids)),
                         with: .color(eye.skin.color(inverted: member.inverted)))
            }
        }
    }
}
