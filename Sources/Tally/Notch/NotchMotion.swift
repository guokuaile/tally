import SwiftUI

/// Sample the platform spring while retaining velocity across target changes.
struct NotchMotion {
    private(set) var size: CGSize
    private(set) var velocity: CGSize = .zero
    private(set) var target: CGSize
    private var spring = Spring(response: 0.46, dampingRatio: 0.83)

    init(size: CGSize) {
        self.size = size
        target = size
    }

    var isSettled: Bool {
        abs(size.width - target.width) < 0.1 && abs(size.height - target.height) < 0.1 &&
        abs(velocity.width) < 0.5 && abs(velocity.height) < 0.5
    }

    mutating func retarget(_ size: CGSize, heightOnly: Bool = false) {
        target = size
        spring = Spring(response: heightOnly ? 0.28 : 0.46, dampingRatio: heightOnly ? 1 : 0.83)
    }

    mutating func advance(by elapsed: TimeInterval) {
        guard elapsed.isFinite, elapsed > 0 else { return }
        var value = size.animatableData
        var speed = velocity.animatableData
        spring.update(value: &value, velocity: &speed, target: target.animatableData, deltaTime: elapsed)
        size.animatableData = value
        velocity.animatableData = speed
        if isSettled {
            size = target
            velocity = .zero
        }
    }

    /// The physical camera area must remain covered even during a spring undershoot.
    func visibleSize(minimum: CGSize) -> CGSize {
        CGSize(width: max(minimum.width, size.width), height: max(minimum.height, size.height))
    }
}
