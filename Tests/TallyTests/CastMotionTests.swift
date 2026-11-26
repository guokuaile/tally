import XCTest
@testable import Tally

final class CastMotionTests: XCTestCase {
    func testIdleVariantsCycleWithoutImmediateRepetitionAndLeaveRestGaps() {
        let cases: [(CrewMood, CrewTier, Double, Double, Int, CastMotion.Kind)] = [
            (.run, .fresh, 4.3, 3, 5, .think),
            (.input, .fresh, 4, 1, 6, .unsure),
            (.stale, .fresh, 5, 2, 3, .sleep),
            (.permission, .dusty, 5, 2, 3, .sleep),
            (.permission, .fresh, 4, 3, 4, .hold),
            (.done, .fresh, 6, 2.65, 4, .hold),
        ]
        for (mood, tier, period, offset, count, kind) in cases {
            let firstCycle = kind == .hold ? 4 : 0
            let variants = (firstCycle..<(firstCycle + count * 2)).compactMap { cycle -> Int? in
                let elapsed = Double(cycle) * period + offset
                let motion = CastMotion.forCrew(mood: mood, tier: tier, elapsed: elapsed, phase: 0, still: false, seed: 7)
                XCTAssertEqual(motion?.kind, kind)
                XCTAssertTrue((0..<20).contains(motion?.step ?? -1))
                XCTAssertNil(CastMotion.forCrew(mood: mood, tier: tier, elapsed: Double(cycle) * period + period - 0.05,
                                               phase: 0, still: false, seed: 7), "Each cycle has a visible rest gap")
                return motion?.variant
            }
            XCTAssertEqual(Set(variants), Set(0..<count), "Every variant must be reached for \(kind)")
            XCTAssertTrue(zip(variants, variants.dropFirst()).allSatisfy { $0 != $1 }, "Adjacent actions repeated for \(kind)")
            XCTAssertEqual(variants.prefix(count), variants.suffix(count), "Ordering should be stable for \(kind)")
        }
    }

    func testIdleSeedChangesFirstVariantWithoutChangingTiming() {
        let base = CastMotion.forCrew(mood: .input, tier: .fresh, elapsed: 1, phase: 0, still: false, seed: 0)
        let shifted = CastMotion.forCrew(mood: .input, tier: .fresh, elapsed: 1, phase: 0, still: false, seed: 1)
        XCTAssertEqual(base?.kind, shifted?.kind)
        XCTAssertEqual(base?.step, shifted?.step)
        XCTAssertNotEqual(base?.variant, shifted?.variant)
        XCTAssertEqual(shifted, CastMotion.forCrew(mood: .input, tier: .fresh, elapsed: 1, phase: 0, still: false, seed: 1))
    }

    func testWakeOnlyAfterAsleepStateAndAllEventWindowsEnd() {
        XCTAssertTrue(CastMotion.shouldWake(from: .stale, tier: .fresh, to: .run, tier: .fresh))
        XCTAssertTrue(CastMotion.shouldWake(from: .permission, tier: .dusty, to: .permission, tier: .fresh))
        XCTAssertTrue(CastMotion.shouldWake(from: .input, tier: .dusty, to: .run, tier: .fresh))
        XCTAssertFalse(CastMotion.shouldWake(from: .permission, tier: .dusty, to: .stale, tier: .fresh))
        XCTAssertFalse(CastMotion.shouldWake(from: .stale, tier: .fresh, to: .input, tier: .dusty))
        XCTAssertFalse(CastMotion.shouldWake(from: .run, tier: .fresh, to: .done, tier: .fresh))
        XCTAssertEqual(CastMotion.forWake(elapsed: 0.4)?.kind, .wake)
        XCTAssertEqual(CastMotion.forClick(elapsed: 0.2)?.kind, .click)
        XCTAssertNil(CastMotion.forWake(elapsed: 0.8))
        XCTAssertNil(CastMotion.forClick(elapsed: 0.42))
        XCTAssertNil(CastMotion.forWake(elapsed: 0.4, still: true))
        XCTAssertNil(CastMotion.forClick(elapsed: 0.2, still: true))
    }

    func testInvalidTimesDoNotCreateAnimationOrOverflow() {
        for value in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertNil(CastMotion.forWake(elapsed: value))
            XCTAssertNil(CastMotion.forClick(elapsed: value))
            XCTAssertNil(CastMotion.forCrew(mood: .run, tier: .fresh, elapsed: value, phase: 0, still: false))
        }
        XCTAssertNil(CastMotion.forCrew(mood: .run, tier: .fresh, elapsed: 3, phase: .nan, still: false))
        XCTAssertNil(CastMotion.forCrew(mood: .run, tier: .fresh, elapsed: .greatestFiniteMagnitude, phase: .greatestFiniteMagnitude, still: false))
    }
}
