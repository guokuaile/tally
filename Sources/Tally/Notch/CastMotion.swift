import Foundation

/// Quantized overlays keep the wing's image cache independent of wall-clock age.
struct CastMotion: Hashable {
    enum Kind: Hashable { case think, unsure, sleep, hold, surprise, happy, farewell, greet, wake, click }
    let kind: Kind
    let step: Int
    let variant: Int

    init(kind: Kind, step: Int, variant: Int = 0) {
        self.kind = kind
        self.step = step
        self.variant = variant
    }

    var strength: Double { sin(.pi * Double(step) / 20) }

    private static func window(_ kind: Kind, time: Double, start: Double, duration: Double, variant: Int = 0) -> CastMotion? {
        guard time.isFinite, start.isFinite, time >= start, time < start + duration else { return nil }
        return CastMotion(kind: kind, step: min(19, Int((time - start) / duration * 20)), variant: variant)
    }

    /// One variant per cycle, with a rest gap. Incrementing the cycle rotates every
    /// variant exactly once before repeating, so neighboring actions never match.
    private static func idle(_ kind: Kind, elapsed: Double, phase: Double, seed: Int, cycle: Double, start: Double, duration: Double, variants: Int) -> CastMotion? {
        let time = elapsed + phase
        guard time.isFinite, time >= 0 else { return nil }
        let cycleIndex = Int(floor(time / cycle).truncatingRemainder(dividingBy: Double(variants)))
        let variant = (cycleIndex + seed % variants + variants) % variants
        return window(kind, time: time.truncatingRemainder(dividingBy: cycle), start: start, duration: duration, variant: variant)
    }

    static func forCrew(mood: CrewMood, tier: CrewTier, elapsed: Double, phase: Double, still: Bool, seed: Int = 0) -> CastMotion? {
        guard !still, elapsed.isFinite, phase.isFinite, elapsed >= 0 else { return nil }
        if tier == .dusty && mood.isWaiting {
            return idle(.sleep, elapsed: elapsed, phase: phase, seed: seed, cycle: 5, start: 1, duration: 2.5, variants: 3)
        }
        switch mood {
        case .run: return idle(.think, elapsed: elapsed, phase: phase, seed: seed, cycle: 4.3, start: 2.4, duration: 1.5, variants: 5)
        case .input: return idle(.unsure, elapsed: elapsed, phase: phase, seed: seed, cycle: 4, start: 0.4, duration: 2.2, variants: 6)
        case .stale: return idle(.sleep, elapsed: elapsed, phase: phase, seed: seed, cycle: 5, start: 1, duration: 2.5, variants: 3)
        case .permission:
            let start = (2.5 - phase).truncatingRemainder(dividingBy: 4)
            if let surprise = window(.surprise, time: elapsed, start: start < 0 ? start + 4 : start, duration: 1) { return surprise }
            guard elapsed > 10 else { return nil }
            return idle(.hold, elapsed: elapsed, phase: phase, seed: seed, cycle: 4, start: 2.5, duration: 1, variants: 4)
        case .done:
            let start = (2.15 - phase).truncatingRemainder(dividingBy: 6)
            if let happy = window(.happy, time: elapsed, start: start < 0 ? start + 6 : start, duration: 1) { return happy }
            guard elapsed > 10 else { return nil }
            return idle(.hold, elapsed: elapsed, phase: phase, seed: seed, cycle: 6, start: 2.15, duration: 1, variants: 4)
        case .compacting: return nil
        }
    }

    static func shouldWake(from oldMood: CrewMood, tier oldTier: CrewTier, to newMood: CrewMood, tier newTier: CrewTier) -> Bool {
        let wasAsleep = oldMood == .stale || (oldMood.isWaiting && oldTier == .dusty)
        let isAsleep = newMood == .stale || (newMood.isWaiting && newTier == .dusty)
        return wasAsleep && !isAsleep
    }

    static func forWake(elapsed: Double, still: Bool = false) -> CastMotion? {
        guard !still else { return nil }
        return window(.wake, time: elapsed, start: 0, duration: 0.8)
    }

    static func forClick(elapsed: Double, still: Bool = false) -> CastMotion? {
        guard !still else { return nil }
        return window(.click, time: elapsed, start: 0, duration: 0.42)
    }

    static func forBadge(_ kind: BadgeLifecycle.Kind, elapsed: Double?) -> CastMotion? {
        guard let elapsed else { return nil }
        return window(kind == .departed ? .farewell : .happy, time: elapsed, start: 0.9, duration: 1)
    }

    static func forHover(elapsed: Double) -> CastMotion? {
        window(.greet, time: elapsed, start: 0, duration: 0.8)
    }
}
