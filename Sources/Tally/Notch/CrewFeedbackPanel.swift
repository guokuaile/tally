import AppKit

/// A short portrait response survives its source closing, without retaining any hit target.
final class CrewFeedbackPanel: NSPanel {
    enum Kind { case departure, click }
    static let duration = 0.32

    init(frame: CGRect, image: CGImage, sharingType: NSWindow.SharingType) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        animationBehavior = .none
        level = .mainMenu + 2
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.sharingType = sharingType
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.contents = image
        view.layer?.contentsScale = 2
        contentView = view
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func animate(_ kind: Kind, completion: @escaping @MainActor () -> Void) {
        if kind == .click { level = .mainMenu + 6 }
        orderFrontRegardless()
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = kind == .departure ? [1, 0.96, 0.3] : [1, 0.84, 1.12, 1]
        let drop = CAKeyframeAnimation(keyPath: "transform.translation.y")
        drop.values = [0, -1, -5]
        let bow = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        bow.values = [0, -0.1, -0.12]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 0.9, 0]
        let group = CAAnimationGroup()
        group.animations = kind == .departure ? [scale, drop, bow, fade] : [scale]
        group.duration = Self.duration
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        contentView?.layer?.add(group, forKey: "response")
        CATransaction.commit()
    }
}
