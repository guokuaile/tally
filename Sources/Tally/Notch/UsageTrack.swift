import SwiftUI

/// Motion stays inside the used range and never advances the reported quota.
struct UsageTrackLayout {
    let fraction: Double
    init(fraction: Double) { self.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0 }
    var animates: Bool { fraction > 0 && fraction < 1 }
    func usedWidth(_ width: CGFloat) -> CGFloat { max(0, width) * fraction }
    func highlight(width: CGFloat, phase: Double) -> ClosedRange<CGFloat>? {
        guard animates else { return nil }
        let end = usedWidth(width)
        let span = min(24, end)
        let phase = phase.isFinite ? min(1, max(0, phase)) : 0
        let tip = end - span + span * phase
        return max(0, tip - 8)...tip
    }
}

struct UsageTrack: View {
    let fraction: Double
    let elapsed: Double?
    let paused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    var body: some View {
        let layout = UsageTrackLayout(fraction: fraction)
        let still = paused || reduceMotion || !visible || !layout.animates
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: still)) { timeline in
            let phase = (timeline.date.timeIntervalSinceReferenceDate / 2.4).truncatingRemainder(dividingBy: 1)
            Canvas { context, size in
                let rect = CGRect(x: 0, y: 4.5, width: size.width, height: 3)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(.white.opacity(0.12)))
                let used = CGRect(x: 0, y: 4.5, width: layout.usedWidth(size.width), height: 3)
                let fill = Path(roundedRect: used, cornerRadius: 1.5)
                context.fill(fill, with: .color(quotaColor(layout.fraction).opacity(paused ? 0.45 : 0.85)))
                if !still, let highlight = layout.highlight(width: size.width, phase: phase) {
                    var light = context
                    light.clip(to: fill)
                    let rect = CGRect(x: highlight.lowerBound, y: 4.5, width: highlight.upperBound-highlight.lowerBound, height: 3)
                    light.fill(Path(rect), with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0.8)]),
                        startPoint: CGPoint(x: rect.minX, y: 6), endPoint: CGPoint(x: rect.maxX, y: 6)))
                }
                if let elapsed, elapsed.isFinite {
                    let x = min(max(0.5, size.width * elapsed), max(0.5, size.width-0.5))
                    let color: Color = QuotaPace.isAhead(used: layout.fraction, elapsed: elapsed) ? .orange : .white.opacity(0.55)
                    context.fill(Path(CGRect(x: x-0.5, y: 2.5, width: 1, height: 7)), with: .color(color))
                }
            }
        }
        .frame(height: 12)
        .onScrollVisibilityChange(threshold: 0.05) { visible = $0 }
    }
}
