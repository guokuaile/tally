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

        var symbolAnchor: CGPoint { CGPoint(x: 104, y: -73 + symbolY) }

        func draw(in supplied: GraphicsContext, time: Double = 0, style: Style = Style()) {
            var context = supplied
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
            func glass(_ path: Path, center: CGPoint, radius: Double, in base: GraphicsContext) {
                // 光晕和改之前一样是模糊的描边：AI 页和药丸的画法不变；翅膀一帧只画一次存成位图，模糊的开销不在每 tick 上
                base.drawLayer { glow in
                    glow.opacity *= 0.5
                    glow.addFilter(.blur(radius: haloBlur))
                    glow.stroke(path, with: rim, style: StrokeStyle(lineWidth: haloWidth, lineJoin: .round))
                }
                base.fill(path, with: BloubArt.bodyShading(style, center: center, radius: radius))
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
            glass(body, center: .zero, radius: 100, in: face)
            if ring > 0 {
                // 绿环和描边同一套粗细：模糊的宽描边打底（预览 0.6），再压一道实线
                var green = face
                green.opacity *= ring
                green.drawLayer { halo in
                    halo.opacity *= 0.6
                    halo.addFilter(.blur(radius: haloBlur))
                    halo.stroke(body, with: .color(BloubArt.ringColor), style: StrokeStyle(lineWidth: haloWidth, lineJoin: .round))
                }
                green.stroke(body, with: .color(BloubArt.ringColor), style: StrokeStyle(lineWidth: rimWidth, lineJoin: .round))
            }
            face.clip(to: body)
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

    /// 文件里有什么片段就解什么；只有会话六个片段是硬要求，小刻片段缺了翅膀不画、AI 页照旧
    init?(url: URL) {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(DataFile.self, from: data) else { return nil }
        var clips: [String: Clip] = [:]
        for (name, clip) in file.clips {
            let required = SessionEyes.Mood(rawValue: name).map { $0 != .sleeping } ?? false
            guard clip.fps > 0, clip.fps.isFinite, !clip.frames.isEmpty, let frames = Self.decodeFrames(clip.frames) else {
                // 坏掉的会话片段整份作废；坏掉的小刻片段只是没有那段（翅膀自己发现缺片段后不画），AI 页照旧
                if required { return nil }
                continue
            }
            clips[name] = Clip(fps: clip.fps, frames: frames)
        }
        for mood in SessionEyes.Mood.allCases where mood != .sleeping {
            guard clips[mood.rawValue] != nil else { return nil }
        }
        self.clips = clips
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
        return Frame(body: body, alpha: frame.bodyAlpha, eyes: eyes, dots: dots, dotsBehind: frame.dotsBehind, arcs: arcs, notch: frame.notch?.path, notif: frame.notif?.path, symbol: frame.symbol, symbolY: symbolY,
                     glow: glow, ring: ring, lids: lids, arcEyes: frame.arcEyes ?? false)
    }

    static func color(_ hex: String) -> Color? {
        guard hex.count == 7, hex.first == "#", let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return Color(red: Double((rgb >> 16) & 255)/255, green: Double((rgb >> 8) & 255)/255, blue: Double(rgb & 255)/255)
    }

    private static func path(_ values: [Double]) -> Path? {
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

    func frame(mood: SessionEyes.Mood, time: Double, still: Bool = false) -> Frame? {
        guard let clip = clips[mood.rawValue] else { return nil }
        return clip.frame(at: still ? (mood == .permission || mood == .input ? 2.4 : 0.9) : time, loop: true)
    }
}

struct SessionEyes: View {
    enum Mood: String, CaseIterable { case working, permission, input, compacting, happy, sleeping, stale }
    let mood: Mood
    var identity = ""
    var active = true
    var size: CGFloat = 34
    var art: BloubArt? = .bundled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appearedAt = Date()

    var body: some View {
        Group {
            if mood == .sleeping {
                HStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        Circle().fill(.white.opacity(index == 1 ? 0.75 : 0.35))
                            .frame(width: index == 1 ? 6 : 5, height: index == 1 ? 6 : 5)
                    }
                }
            } else {
                animatedBody
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onChange(of: mood) { _, _ in appearedAt = Date() }
    }

    private var animatedBody: some View {
        let still = !active || reduceMotion || mood == .stale
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { timeline in
            let phase = Double(identity.utf8.reduce(0) { ($0 * 31 + Int($1)) % 997 }) / 997
            let time = still ? 0.9 : max(0, timeline.date.timeIntervalSince(appearedAt)) + phase
            if let art, let frame = art.frame(mood: mood, time: time, still: still) {
                Canvas { context, canvas in
                    context.translateBy(x: canvas.width/2, y: canvas.height/2)
                    context.scaleBy(x: canvas.width/316, y: canvas.height/316)
                    frame.draw(in: context, time: time)
                }
                .opacity(mood == .stale ? 0.55 : 1)
            } else {
                Image(systemName: "exclamationmark.triangle").help("会话动画素材未加载")
            }
        }
    }
}
