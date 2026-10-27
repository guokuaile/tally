import SwiftUI

/// Decode complete upstream geometry once; animation only selects a cached frame.
struct BloubArt {
    enum ExpressionSymbol: String, Decodable { case approval = "!", question = "?" }
    struct Fill { let path: Path; let shading: GraphicsContext.Shading; let opacity: Double }
    struct Arc { let front: Path; let back: Path; let shading: GraphicsContext.Shading; let width: Double; let opacity: Double }
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

        var symbolAnchor: CGPoint { CGPoint(x: 104, y: -73 + symbolY) }

        func draw(in supplied: GraphicsContext, time: Double = 0) {
            var context = supplied
            if symbol != nil {
                context.translateBy(x: -8, y: 8)
                context.scaleBy(x: 0.90, y: 0.90)
            }
            for arc in arcs {
                var layer = context
                layer.opacity *= arc.opacity
                layer.stroke(arc.back, with: arc.shading, style: StrokeStyle(lineWidth: arc.width, lineCap: .round))
            }
            if dotsBehind {
                for dot in dots {
                    var layer = context
                    layer.opacity *= dot.opacity
                    layer.fill(dot.path, with: dot.shading)
                }
            }
            var face = context
            face.opacity *= alpha
            let rim = GraphicsContext.Shading.conicGradient(Gradient(colors: BloubArt.rimColors),
                center: .zero, angle: .radians(time * 0.45))
            face.drawLayer { glow in
                glow.opacity *= 0.5
                glow.addFilter(.blur(radius: 4))
                glow.stroke(body, with: rim, style: StrokeStyle(lineWidth: 12, lineJoin: .round))
            }
            face.fill(body, with: BloubArt.bodyShading)
            face.stroke(body, with: rim, style: StrokeStyle(lineWidth: 5, lineJoin: .round))
            face.clip(to: body)
            face.fill(body, with: .radialGradient(Gradient(colors: [.white.opacity(0.25), .clear]),
                center: CGPoint(x: -45, y: -105), startRadius: 0, endRadius: 115))
            for eye in eyes {
                var layer = face
                layer.opacity *= eye.opacity
                layer.fill(eye.path, with: eye.shading)
            }
            if let notch { face.fill(notch, with: BloubArt.bodyShading) }
            if !dotsBehind {
                for dot in dots {
                    var layer = context
                    layer.opacity *= dot.opacity
                    layer.fill(dot.path, with: dot.shading)
                }
            }
            if let notif {
                let bounds = notif.boundingRect
                context.fill(notif, with: .linearGradient(Gradient(colors: BloubArt.approvalColors),
                    startPoint: CGPoint(x: bounds.minX, y: bounds.minY), endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)))
            }
            if let symbol {
                var expression = supplied
                expression.translateBy(x: symbolAnchor.x, y: symbolAnchor.y)
                expression.rotate(by: .degrees(18 + 3 * sin(time * .pi / 2)))
                var glyph = expression.resolve(Text(symbol.rawValue).font(.system(size: 148.4, weight: .heavy, design: .rounded)))
                glyph.shading = .linearGradient(Gradient(colors: [
                    Color(red: 0.48, green: 0.95, blue: 1),
                    Color(red: 1, green: 0.76, blue: 0.95),
                    Color(red: 0.77, green: 0.72, blue: 1)
                ]),
                    startPoint: CGPoint(x: 0, y: -55), endPoint: CGPoint(x: 0, y: 55))
                expression.draw(glyph, at: .zero)
            }
            for arc in arcs {
                var layer = context
                layer.opacity *= arc.opacity
                layer.stroke(arc.front, with: arc.shading, style: StrokeStyle(lineWidth: arc.width, lineCap: .round))
            }
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
    static let bodyShading = GraphicsContext.Shading.linearGradient(Gradient(stops: [
        .init(color: Color(white: 0.15), location: 0),
        .init(color: Color(white: 0.025), location: 0.3),
        .init(color: Color(white: 0.008), location: 0.6),
        .init(color: Color(red: 0.055, green: 0.075, blue: 0.085), location: 0.82),
        .init(color: Color(white: 0.24), location: 1)
    ]), startPoint: CGPoint(x: -90, y: -85), endPoint: CGPoint(x: 90, y: 90))
    let fps: Double
    let clips: [String: [Frame]]
    static let bundled = Bundle.main.url(forResource: "frames", withExtension: "json", subdirectory: "bloub").flatMap(BloubArt.init)

    private struct DataFile: Decodable {
        struct Eye: Decodable { let width: Double; let height: Double; let matrix: [Double]; let alpha: Double }
        struct Dot: Decodable { let x: Double; let y: Double; let r: Double; let opacity: Double; let depth: Double?; let color: String?; let path: [Double]?; let rot: Double? }
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
        }
        let fps: Double
        let clips: [String: [Frame]]
    }

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(DataFile.self, from: data),
              file.fps > 0, file.fps.isFinite else { return nil }
        var clips: [String: [Frame]] = [:]
        for mood in SessionEyes.Mood.allCases where mood != .sleeping {
            guard let sequence = file.clips[mood.rawValue], !sequence.isEmpty else { return nil }
            var frames: [Frame] = []
            for frame in sequence {
                guard let body = Self.path(frame.body) else { return nil }
                var eyes: [Fill] = []
                for eye in frame.eyes {
                    guard eye.matrix.count == 6, eye.width > 0, eye.height > 0 else { return nil }
                    let m = eye.matrix
                    let transform = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
                    let rect = CGRect(x: -eye.width/2, y: -eye.height/2, width: eye.width, height: eye.height)
                    eyes.append(Fill(path: Path(roundedRect: rect, cornerRadius: min(eye.width, eye.height)/2).applying(transform), shading: .color(Self.paper), opacity: eye.alpha))
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
                    dots.append(Fill(path: path, shading: shading, opacity: dot.opacity * depth))
                }
                var arcs: [Arc] = []
                for (index, arc) in frame.arcs.enumerated() {
                    let sourceColors = arc.grad.stops.compactMap(Self.color)
                    guard let front = Self.path(arc.front), let back = Self.path(arc.back), sourceColors.count == arc.grad.stops.count, !sourceColors.isEmpty else { return nil }
                    let colors = arc.grad.stops.indices.map { Self.rimColors[(index + $0) % (Self.rimColors.count - 1)] }
                    arcs.append(Arc(front: front, back: back, shading: .linearGradient(Gradient(colors: colors),
                        startPoint: CGPoint(x: arc.grad.x1, y: arc.grad.y1), endPoint: CGPoint(x: arc.grad.x2, y: arc.grad.y2)), width: arc.width, opacity: arc.opacity))
                }
                let symbolY = frame.symbolY ?? 0
                guard symbolY.isFinite else { return nil }
                frames.append(Frame(body: body, alpha: frame.bodyAlpha, eyes: eyes, dots: dots, dotsBehind: frame.dotsBehind, arcs: arcs, notch: frame.notch?.path, notif: frame.notif?.path, symbol: frame.symbol, symbolY: symbolY))
            }
            clips[mood.rawValue] = frames
        }
        self.fps = file.fps
        self.clips = clips
    }

    private static func color(_ hex: String) -> Color? {
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
        guard let frames = clips[mood.rawValue] else { return nil }
        let time = still ? (mood == .permission || mood == .input ? 2.4 : 0.9) : time
        let duration = Double(frames.count) / fps
        let local = time.isFinite ? max(0, time).truncatingRemainder(dividingBy: duration) : 0
        return frames[min(frames.count-1, Int(local*fps))]
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
