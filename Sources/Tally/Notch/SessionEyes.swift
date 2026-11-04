import SwiftUI

/// Decode complete upstream geometry once; animation only selects a cached frame.
struct BloubArt {
    enum ExpressionSymbol: String, Decodable { case approval = "!", question = "?" }
    /// 身体分出去的碎片（「!」的点、思考的侧点）要和身体一个材质，不能是实心色点
    enum Material { case solid, body }
    struct Fill { let path: Path; let shading: GraphicsContext.Shading; let opacity: Double; var material: Material = .solid; var lid: Path? = nil }
    /// 套系与配色：AI 页和药丸用默认值，画法不变；小刻按状态配色（`CrewStyle.palette(for:)`）、等待态另给光晕
    struct Style {
        enum Skin { case glass, gradient }
        var skin: Skin = .glass
        var rim: [Color] = BloubArt.rimColors
        var fill: (top: Color, bottom: Color)? = nil
        var lid: Color = Color(white: 0.11)
        var glow: Color? = nil
        /// 光晕量默认取帧自带的（等待片段 0.25 到 0.7 慢呼吸）；借了没有光晕帧的片段（落灰档借失联）时由样式给定值
        var glowAmount: Double? = nil
        var opacity: Double = 1
        /// 小刻的符号不缩身体、字号 115 挂在右上 (95, −105)；AI 页保持 148.4 与 90% 缩身
        var compactSymbol = false
        /// 小尺寸档（球身不到 60pt：翅膀上 22pt、工牌上 28pt）：描边和光晕按第 7 版预览的 small 档加粗（描边 9、光晕 26 模糊 9，
        /// 大档 5 / 12 / 4），轨道线和实心点按 `rim` 流光取色而不是固定的冷色。球身只有 22pt 时细描边看着像一根发丝，这是和预览最大的差。AI 页 34pt 保持原画法
        var small = false
    }
    struct Arc { let front: Path; let back: Path; let shading: GraphicsContext.Shading; let start: CGPoint; let end: CGPoint; let width: Double; let opacity: Double }
    /// 身体轮廓的仿射拟合：质心、主轴角、两个主方差开根 ÷ 参考（`crew-run` 第 0 帧）；角色照它平移、歪、缩、压扁
    struct Fit {
        var cx: Double, cy: Double, theta: Double, sx: Double, sy: Double
        static let identity = Fit(cx: 0, cy: 0, theta: 0, sx: 1, sy: 1)
    }
    /// 一只 bloub 眼睛的矩阵拆出来的位置、大小、旋转、透明度；角色的眼睛照它动
    struct EyeSpec { let center: CGPoint; let size: CGSize; let rotation: Double; let alpha: Double }
    struct Frame {
        let body: Path
        let alpha: Double
        let eyes: [Fill]
        let dots: [Fill]
        let dotsBehind: Bool
        let arcs: [Arc]
        let notch: Path?
        let notif: Path?
        let symbol: ExpressionSymbol?
        let symbolY: Double
        var glow: Double = 0
        var ring: Double = 0
        var lids: Double = 0
        var arcEyes = false
        var fit = Fit.identity
        /// 按 x 排：角色的左眼跟 bloub 的左眼。玻璃球仍画 `eyes`
        var eyeSpecs: [EyeSpec] = []

        var symbolAnchor: CGPoint { CGPoint(x: 104, y: -73 + symbolY) }

        func draw(in supplied: GraphicsContext, time: Double = 0, style: Style = Style(), actor: CastActor? = nil) {
            var context = supplied
            // 有角色且这一帧有眼睛：身体换成「角色轮廓 × 这一帧的拟合 × 步态」；没眼睛的帧（等审批的「!」、压缩炸开、完成的彗星）角色变回玻璃球
            let cast = eyeSpecs.isEmpty ? nil : actor
            let castMatrix = cast.map { $0.matrix(self) } ?? .identity
            let shape = cast.map { $0.character.outline.applying(castMatrix) } ?? body
            context.opacity *= style.opacity
            if symbol != nil && !style.compactSymbol {
                context.translateBy(x: -8, y: 8)
                context.scaleBy(x: 0.90, y: 0.90)
            }
            let rim = GraphicsContext.Shading.conicGradient(Gradient(colors: style.rim), center: .zero, angle: .radians(time * 0.45))
            let rimWidth: Double = style.small ? 9 : 5, haloWidth: Double = style.small ? 26 : 12, haloBlur: Double = style.small ? 9 : 4
            // 预览里轨道线是流光第 4 色到第 2 色的渐变、实心点取第 4 色（不够长就取第 1 色）
            let family = (style.rim.count > 3 ? style.rim[3] : style.rim[0], style.rim.count > 1 ? style.rim[1] : style.rim[0])
            func arcShading(_ arc: Arc) -> GraphicsContext.Shading {
                style.small ? .linearGradient(Gradient(colors: [family.0, family.1]), startPoint: arc.start, endPoint: arc.end) : arc.shading
            }
            let glowAmount = style.glowAmount ?? glow
            if glowAmount > 0, let color = style.glow {
                context.fill(Path(CGRect(x: -200, y: -220, width: 400, height: 440)), with: .radialGradient(
                    Gradient(colors: [color.opacity(glowAmount), color.opacity(0)]), center: CGPoint(x: 0, y: -10), startRadius: 0, endRadius: 190))
            }
            // 身体和它分出去的碎片一个材质：模糊光晕描边 → 近黑玻璃或套系渐变 → 描边 → 裁在轮廓里、锚在自己中心的高光
            func glass(_ path: Path, center: CGPoint, radius: Double, in base: GraphicsContext, sprite: CastActor? = nil) {
                // 光晕和改之前一样是模糊的描边：AI 页和药丸的画法不变；翅膀一帧只画一次存成位图，模糊的开销不在每 tick 上
                base.drawLayer { glow in
                    glow.opacity *= 0.5
                    glow.addFilter(.blur(radius: haloBlur))
                    glow.stroke(path, with: rim, style: StrokeStyle(lineWidth: haloWidth, lineJoin: .round))
                }
                base.fill(path, with: BloubArt.bodyShading(style, center: center, radius: radius))
                // 玻璃渐变填完、流光描边之前把角色位图裁在轮廓里画上去，描边和高光照旧压在上面
                if let sprite { sprite.paintBody(in: base, clip: path, matrix: castMatrix) }
                base.stroke(path, with: rim, style: StrokeStyle(lineWidth: rimWidth, lineJoin: .round))
                var inner = base
                inner.clip(to: path)
                inner.fill(path, with: .radialGradient(Gradient(colors: [.white.opacity(0.25), .clear]),
                    center: CGPoint(x: center.x - 0.45 * radius, y: center.y - 1.05 * radius), startRadius: 0, endRadius: 1.15 * radius))
            }
            func drawDots() {
                for dot in dots {
                    var layer = context
                    layer.opacity *= dot.opacity
                    if dot.material == .body {
                        let box = dot.path.boundingRect
                        glass(dot.path, center: CGPoint(x: box.midX, y: box.midY), radius: max(box.width, box.height) / 2, in: layer)
                    } else {
                        layer.fill(dot.path, with: style.small ? .color(family.0) : dot.shading)
                    }
                }
            }
            // 在跑的环绕线在 22pt 球上只有 0.6pt，像一根发丝：小尺寸档线宽翻倍、下面垫一层模糊的同色光（第 8 版预览的 C 档）；AI 页照旧
            func strokeArc(_ path: Path, _ arc: Arc) {
                var layer = context
                layer.opacity *= arc.opacity
                let width = style.small ? arc.width * 2 : arc.width
                if style.small {
                    var halo = layer
                    halo.opacity *= 0.7
                    halo.addFilter(.blur(radius: 6))
                    halo.stroke(path, with: arcShading(arc), style: StrokeStyle(lineWidth: width * 2.6, lineCap: .round))
                }
                layer.stroke(path, with: arcShading(arc), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            for arc in arcs { strokeArc(arc.back, arc) }
            if dotsBehind { drawDots() }
            var face = context
            face.opacity *= alpha
            glass(shape, center: .zero, radius: 100, in: face, sprite: cast)
            if ring > 0 {
                // 绿环和描边同一套粗细：模糊的宽描边打底（预览 0.6），再压一道实线
                var green = face
                green.opacity *= ring
                green.drawLayer { halo in
                    halo.opacity *= 0.6
                    halo.addFilter(.blur(radius: haloBlur))
                    halo.stroke(shape, with: .color(BloubArt.ringColor), style: StrokeStyle(lineWidth: haloWidth, lineJoin: .round))
                }
                green.stroke(shape, with: .color(BloubArt.ringColor), style: StrokeStyle(lineWidth: rimWidth, lineJoin: .round))
            }
            face.clip(to: shape)
            if let cast {
                // bloub 的眼睛和缺口不画，角色自己的眼睛按 bloub 眼睛的位移 / 缩放 / 旋转动
                cast.drawEyes(in: face, frame: self)
            } else {
                for eye in eyes {
                    var layer = face
                    layer.opacity *= eye.opacity
                    if arcEyes {
                        layer.stroke(eye.path, with: eye.shading, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        continue
                    }
                    layer.fill(eye.path, with: eye.shading)
                    if let lid = eye.lid {
                        layer.clip(to: eye.path)
                        layer.fill(lid, with: .color(style.lid))
                    }
                }
                if let notch { face.fill(notch, with: BloubArt.bodyShading(style)) }
            }
            if !dotsBehind { drawDots() }
            if let notif {
                let bounds = notif.boundingRect
                context.fill(notif, with: .linearGradient(Gradient(colors: BloubArt.approvalColors),
                    startPoint: CGPoint(x: bounds.minX, y: bounds.minY), endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)))
            }
            if let symbol {
                var expression = supplied
                expression.opacity *= style.opacity
                let anchor = style.compactSymbol ? CGPoint(x: 95, y: -105) : symbolAnchor
                let size: CGFloat = style.compactSymbol ? 115 : 148.4
                expression.translateBy(x: anchor.x, y: anchor.y)
                expression.rotate(by: .degrees(18 + 3 * sin(time * .pi / 2)))
                // 预览的「?」是 900 字重；AI 页保持原来的 heavy
                var glyph = expression.resolve(Text(symbol.rawValue).font(.system(size: size, weight: style.compactSymbol ? .black : .heavy, design: .rounded)))
                glyph.shading = .linearGradient(Gradient(colors: [
                    Color(red: 0.48, green: 0.95, blue: 1),
                    Color(red: 1, green: 0.76, blue: 0.95),
                    Color(red: 0.77, green: 0.72, blue: 1)
                ]),
                    startPoint: CGPoint(x: 0, y: -0.37 * size), endPoint: CGPoint(x: 0, y: 0.37 * size))
                expression.draw(glyph, at: .zero)
            }
            for arc in arcs { strokeArc(arc.front, arc) }
        }
    }
    static let approvalColors = [Color(red: 0.58, green: 0.94, blue: 1), Color(red: 0.24, green: 0.65, blue: 1)]
    static let paper = Color(white: 0.96)
    static let rimColors: [Color] = [
        Color(red: 0.24, green: 0.32, blue: 1),
        Color(red: 0.62, green: 0.28, blue: 1),
        Color(red: 0.94, green: 0.62, blue: 1),
        Color(red: 0.30, green: 0.92, blue: 1),
        Color(red: 0.18, green: 0.56, blue: 1),
        Color(red: 0.24, green: 0.32, blue: 1)
    ]
    static let ringColor = Color(red: 0x60/255, green: 0xD8/255, blue: 0x80/255)
    /// 近黑玻璃的渐变锚在碎片自己的中心和半径上，整个身体就是 (0, 0)、100
    static func bodyShading(_ style: Style = Style(), center: CGPoint = .zero, radius: Double = 100) -> GraphicsContext.Shading {
        if style.skin == .gradient, let fill = style.fill {
            return .linearGradient(Gradient(colors: [fill.top, fill.bottom]),
                startPoint: CGPoint(x: center.x, y: center.y - radius), endPoint: CGPoint(x: center.x, y: center.y + radius))
        }
        return .linearGradient(Gradient(stops: [
            .init(color: Color(white: 0.15), location: 0),
            .init(color: Color(white: 0.025), location: 0.3),
            .init(color: Color(white: 0.008), location: 0.6),
            .init(color: Color(red: 0.055, green: 0.075, blue: 0.085), location: 0.82),
            .init(color: Color(white: 0.24), location: 1)
        ]), startPoint: CGPoint(x: center.x - 0.9 * radius, y: center.y - 0.85 * radius), endPoint: CGPoint(x: center.x + 0.9 * radius, y: center.y + 0.9 * radius))
    }
    /// 每个片段自带采样率：会话片段 30 fps，小刻片段 20 fps
    struct Clip {
        let fps: Double
        let frames: [Frame]
        var duration: Double { Double(frames.count) / fps }

        func index(at time: Double, loop: Bool) -> Int {
            let elapsed = time.isFinite ? max(0, time) : 0
            let local = loop ? elapsed.truncatingRemainder(dividingBy: duration) : min(elapsed, duration)
            return min(frames.count - 1, Int(local * fps))
        }

        func frame(at time: Double, loop: Bool) -> Frame { frames[index(at: time, loop: loop)] }
    }
    let clips: [String: Clip]
    static let bundled = Bundle.main.url(forResource: "frames", withExtension: "json", subdirectory: "bloub").flatMap(BloubArt.init)

    private struct DataFile: Decodable {
        struct Eye: Decodable { let width: Double; let height: Double; let matrix: [Double]; let alpha: Double }
        struct Dot: Decodable { let x: Double; let y: Double; let r: Double; let opacity: Double; let depth: Double?; let color: String?; let path: [Double]?; let rot: Double?; let piece: Bool? }
        struct Circle: Decodable {
            let x: Double; let y: Double; let r: Double
            var path: Path { Path(ellipseIn: CGRect(x: x-r, y: y-r, width: r*2, height: r*2)) }
        }
        struct Arc: Decodable {
            struct Gradient: Decodable { let x1: Double; let y1: Double; let x2: Double; let y2: Double; let stops: [String] }
            let front: [Double]; let back: [Double]; let width: Double; let opacity: Double; let grad: Gradient
        }
        struct Frame: Decodable {
            let body: [Double]; let bodyAlpha: Double; let eyes: [Eye]; let dots: [Dot]; let dotsBehind: Bool
            let arcs: [Arc]; let notch: Circle?; let notif: Circle?
            let symbol: ExpressionSymbol?; let symbolY: Double?
            let glow: Double?; let ring: Double?; let lids: Double?; let arcEyes: Bool?
        }
        struct Clip: Decodable { let fps: Double; let frames: [Frame] }
        let clips: [String: Clip]
    }

    /// 六个小刻片段是硬要求：任一缺失或坏掉整份作废（翅膀和 AI 页都靠它们），作废前点名是哪段；多余的片段坏了只是没有那段
    init?(url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            Log.error("bloub/frames.json 读不到：\(url.path)")
            return nil
        }
        let file: DataFile
        do { file = try JSONDecoder().decode(DataFile.self, from: data) } catch {
            Log.error("bloub/frames.json 解不开：\(error)")
            return nil
        }
        let required = CrewMood.allCases.map(\.clip)
        var clips: [String: Clip] = [:]
        for (name, clip) in file.clips {
            guard clip.fps > 0, clip.fps.isFinite, !clip.frames.isEmpty, let frames = Self.decodeFrames(clip.frames) else {
                if required.contains(name) {
                    Log.error("bloub/frames.json 的 \(name) 片段坏了，整份作废")
                    return nil
                }
                continue
            }
            clips[name] = Clip(fps: clip.fps, frames: frames)
        }
        for name in required where clips[name] == nil {
            Log.error("bloub/frames.json 缺 \(name) 片段，整份作废")
            return nil
        }
        // 拟合的参考方差取 crew-run 第 0 帧（接近正圆）：正圆帧拟合出 sx = sy = 1。解码时存的是方差开根，这里统一除掉
        let base = clips[CrewMood.run.clip]!.frames[0].fit
        let ref = sqrt((base.sx * base.sx + base.sy * base.sy) / 2)
        self.clips = clips.mapValues { clip in
            Clip(fps: clip.fps, frames: clip.frames.map { frame in
                var normalized = frame
                normalized.fit.sx /= ref
                normalized.fit.sy /= ref
                return normalized
            })
        }
    }

    private static func decodeFrames(_ frames: [DataFile.Frame]) -> [Frame]? {
        var decoded: [Frame] = []
        for frame in frames {
            guard let one = Self.decode(frame) else { return nil }
            decoded.append(one)
        }
        return decoded
    }

    private static func decode(_ frame: DataFile.Frame) -> Frame? {
        guard let body = Self.path(frame.body) else { return nil }
        var eyes: [Fill] = []
        for eye in frame.eyes {
            guard eye.matrix.count == 6, eye.width > 0, eye.height > 0 else { return nil }
            let m = eye.matrix
            let transform = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
            let rect = CGRect(x: -eye.width/2, y: -eye.height/2, width: eye.width, height: eye.height)
            var outline = Path(roundedRect: rect, cornerRadius: min(eye.width, eye.height)/2)
            if frame.arcEyes == true {
                // 笑眼 / 合眼是一道弧：弦在眼睛下三分之一，弓顶顶到上缘
                outline = Path()
                outline.move(to: CGPoint(x: -eye.width * 0.55, y: eye.height * 0.12))
                outline.addQuadCurve(to: CGPoint(x: eye.width * 0.55, y: eye.height * 0.12), control: CGPoint(x: 0, y: -eye.height * 0.5))
            }
            let lids = frame.lids ?? 0
            let lid = lids > 0 ? Path(CGRect(x: -eye.width, y: -eye.height/2, width: eye.width * 2, height: eye.height * lids)).applying(transform) : nil
            eyes.append(Fill(path: outline.applying(transform), shading: .color(Self.paper), opacity: eye.alpha, lid: lid))
        }
        var dots: [Fill] = []
        for (index, dot) in frame.dots.enumerated() {
            let path: Path
            if let source = dot.path {
                guard let outline = Self.path(source) else { return nil }
                let theta = (dot.rot ?? 0) * .pi / 180
                path = outline.applying(CGAffineTransform(a: cos(theta)*100, b: sin(theta)*100, c: -sin(theta)*100, d: cos(theta)*100, tx: dot.x, ty: dot.y))
            } else {
                path = Path(ellipseIn: CGRect(x: dot.x-dot.r, y: dot.y-dot.r, width: dot.r*2, height: dot.r*2))
            }
            let depth = dot.depth ?? 1
            let shading = GraphicsContext.Shading.color(Self.rimColors[index % (Self.rimColors.count - 1)])
            dots.append(Fill(path: path, shading: shading, opacity: dot.opacity * depth, material: dot.piece == true ? .body : .solid))
        }
        var arcs: [Arc] = []
        for (index, arc) in frame.arcs.enumerated() {
            let sourceColors = arc.grad.stops.compactMap(Self.color)
            guard let front = Self.path(arc.front), let back = Self.path(arc.back), sourceColors.count == arc.grad.stops.count, !sourceColors.isEmpty else { return nil }
            let colors = arc.grad.stops.indices.map { Self.rimColors[(index + $0) % (Self.rimColors.count - 1)] }
            let start = CGPoint(x: arc.grad.x1, y: arc.grad.y1), end = CGPoint(x: arc.grad.x2, y: arc.grad.y2)
            arcs.append(Arc(front: front, back: back, shading: .linearGradient(Gradient(colors: colors), startPoint: start, endPoint: end),
                            start: start, end: end, width: arc.width, opacity: arc.opacity))
        }
        let symbolY = frame.symbolY ?? 0
        let glow = frame.glow ?? 0, ring = frame.ring ?? 0, lids = frame.lids ?? 0
        guard symbolY.isFinite, (0...1).contains(glow), (0...1).contains(ring), (0...1).contains(lids) else { return nil }
        // 眼睛矩阵拆成位置 / 大小 / 旋转，按 x 排：角色的左眼跟 bloub 的左眼
        let specs = frame.eyes.map { eye -> EyeSpec in
            let m = eye.matrix
            return EyeSpec(center: CGPoint(x: m[4], y: m[5]), size: CGSize(width: eye.width * hypot(m[0], m[1]), height: eye.height * hypot(m[2], m[3])),
                           rotation: atan2(m[1], m[0]), alpha: eye.alpha)
        }.sorted { $0.center.x < $1.center.x }
        return Frame(body: body, alpha: frame.bodyAlpha, eyes: eyes, dots: dots, dotsBehind: frame.dotsBehind, arcs: arcs, notch: frame.notch?.path, notif: frame.notif?.path, symbol: frame.symbol, symbolY: symbolY,
                     glow: glow, ring: ring, lids: lids, arcEyes: frame.arcEyes ?? false, fit: Self.moments(frame.body), eyeSpecs: specs)
    }

    /// 身体轮廓按曲线细分（三次曲线 12 份）、等弧长重采样 240 点后的质心与二阶矩；`sx` / `sy` 先存方差开根，`init` 再按参考归一。
    /// 主轴角折到 (−45°, 45°]，接近正圆时主轴方向是噪声，按各向异性压下去
    static func moments(_ values: [Double]) -> Fit {
        var pts: [CGPoint] = [], cur = CGPoint.zero
        var i = 0
        while i < values.count {
            let op = values[i]
            i += 1
            switch op {
            case 0, 1:
                cur = CGPoint(x: values[i], y: values[i + 1])
                pts.append(cur)
                i += 2
            case 2:
                let p0 = cur, p1 = CGPoint(x: values[i], y: values[i + 1]), p2 = CGPoint(x: values[i + 2], y: values[i + 3]), p3 = CGPoint(x: values[i + 4], y: values[i + 5])
                for k in 1...12 {
                    let t = Double(k) / 12, u = 1 - t
                    pts.append(CGPoint(x: u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
                                       y: u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y))
                }
                cur = p3
                i += 6
            default: break
            }
        }
        let n = pts.count
        guard n >= 3 else { return .identity }
        let seg = (0..<n).map { hypot(pts[($0 + 1) % n].x - pts[$0].x, pts[($0 + 1) % n].y - pts[$0].y) }
        let total = seg.reduce(0, +)
        guard total > 0 else { return .identity }
        let step = total / 240
        var samples: [CGPoint] = [], acc = 0.0, k = 0
        for s in 0..<240 {
            let target = Double(s) * step
            while acc + seg[k] < target { acc += seg[k]; k = (k + 1) % n }
            let a = pts[k], b = pts[(k + 1) % n], f = seg[k] > 0 ? (target - acc) / seg[k] : 0
            samples.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
        }
        let count = Double(samples.count)
        let cx = samples.map(\.x).reduce(0, +) / count, cy = samples.map(\.y).reduce(0, +) / count
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in samples { let dx = p.x - cx, dy = p.y - cy; sxx += dx * dx; syy += dy * dy; sxy += dx * dy }
        sxx /= count; syy /= count; sxy /= count
        var theta = 0.5 * atan2(2 * sxy, sxx - syy)
        let c = cos(theta), s = sin(theta)
        var v1 = sxx * c * c + syy * s * s + 2 * sxy * s * c, v2 = sxx * s * s + syy * c * c - 2 * sxy * s * c
        if theta > .pi / 4 { theta -= .pi / 2; swap(&v1, &v2) } else if theta < -.pi / 4 { theta += .pi / 2; swap(&v1, &v2) }
        let aniso = abs(v1 - v2) / (v1 + v2), weight = min(1, max(0, (aniso - 0.02) / 0.06))
        return Fit(cx: cx, cy: cy, theta: theta * weight, sx: sqrt(max(v1, 1)), sy: sqrt(max(v2, 1)))
    }

    static func color(_ hex: String) -> Color? {
        guard hex.count == 7, hex.first == "#", let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return Color(red: Double((rgb >> 16) & 255)/255, green: Double((rgb >> 8) & 255)/255, blue: Double(rgb & 255)/255)
    }

    static func path(_ values: [Double]) -> Path? {
        guard values.allSatisfy(\.isFinite) else { return nil }
        var path = Path()
        var i = 0
        while i < values.count {
            let op = values[i]
            let count: Int
            switch op { case 0, 1: count = 2; case 2: count = 6; case 3: count = 0; default: return nil }
            i += 1
            guard i + count <= values.count else { return nil }
            switch op {
            case 0: path.move(to: CGPoint(x: values[i], y: values[i+1]))
            case 1: path.addLine(to: CGPoint(x: values[i], y: values[i+1]))
            case 2: path.addCurve(to: CGPoint(x: values[i+4], y: values[i+5]), control1: CGPoint(x: values[i], y: values[i+1]), control2: CGPoint(x: values[i+2], y: values[i+3]))
            default: path.closeSubpath()
            }
            i += count
        }
        return path
    }
}
