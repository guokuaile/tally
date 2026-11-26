import AppKit
import SwiftUI

/// 一格里画什么：一个项目，或某一翼最外那格的「+N」胶囊。
struct CrewSlot: Equatable {
    let project: CrewProject?
    let overflow: Int
    /// 片段的时间原点：mood 一变就重置，片段从头播
    let startedAt: Date
    /// 同一时刻进场的几个角色错开相位，不然齐刷刷同步眨眼
    let phase: Double
    /// 这个项目分到的角色（`CrewCastStore`）；「+N」胶囊是球
    var cast: CastMember = .ball
    var hasNewCompletion = false
    var wokeAt: Date? = nil
}

/// 光标停在或点在哪一格。
struct CrewHover: Equatable {
    let side: CrewGeometry.Side
    let index: Int
    let slot: CrewSlot

    /// 同一格、同一个项目（会话刷新过也算同一格）；「+N」胶囊按格算
    func sameSlot(as other: CrewHover) -> Bool {
        side == other.side && index == other.index && slot.project?.id == other.slot.project?.id
    }
}

/// 状态 + 经过的时间 → 该取哪个片段的哪一刻。纯函数，翅膀和工牌都按它取帧。
enum CrewPlayback {
    /// 六个状态都循环自己的片段（完成也和预览一样一遍遍拖彗尾、闪绿环）；减少动态时取定格帧
    static func clip(mood: CrewMood, tier: CrewTier = .fresh, elapsed: Double, still: Bool) -> (clip: String, time: Double, loop: Bool) {
        if still {
            let frame = mood.still(tier: tier)
            return (frame.clip, frame.time, false)
        }
        return (mood.clip(tier: tier), elapsed, true)
    }

    static func pick(mood: CrewMood, tier: CrewTier = .fresh, elapsed: Double, still: Bool, art: BloubArt) -> (clip: String, index: Int)? {
        let choice = clip(mood: mood, tier: tier, elapsed: elapsed, still: still)
        guard let clip = art.clips[choice.clip] else { return nil }
        return (choice.clip, clip.index(at: choice.time, loop: choice.loop))
    }

    /// A wake gesture needs a whole visible face, even when the new clip starts as a symbol.
    static func wakeMotion(mood: CrewMood, tier: CrewTier, elapsed: Double, phase: Double, still: Bool, art: BloubArt) -> CastMotion? {
        guard !still, elapsed.isFinite, phase.isFinite, elapsed >= 0,
              let clip = art.clips[mood.clip(tier: tier)], elapsed <= clip.duration + 0.8 else { return nil }
        let span = Int(ceil(0.8 * clip.fps))
        for offset in 0..<clip.frames.count {
            let start = Double(offset) / clip.fps
            let visibleCount = (0...span).prefix { step in
                let frame = clip.frames[clip.index(at: phase + start + Double(step) / clip.fps, loop: true)]
                return frame.eyeSpecs.count == 2 && frame.fit.sx > 0.6 && frame.fit.sy > 0.6
            }.count
            // Compacting only exposes a whole face briefly; finish before it splits again.
            if visibleCount >= 6 {
                let duration = Double(visibleCount - 1) / clip.fps
                return CastMotion.forWake(elapsed: (elapsed - start) * 0.8 / duration)
            }
        }
        return nil
    }

}

/// 一帧一张位图：画一次存起来，之后每个时钟 tick 只换图层内容。
/// SwiftUI Canvas 每 tick 重画六个角色实测 13% CPU（AttributeGraph 占大头），换成位图后只剩换 `contents`。
@MainActor
final class CrewFrameCache {
    struct Look: Hashable {
        let mood: CrewMood
        /// 等久了的档和 mood 一样决定片段和颜色，所以进缓存键
        var tier: CrewTier = .fresh
        let skin: BloubArt.Style.Skin
        /// 项目分到的角色；换角色就是另一套图
        let cast: CastMember
    }
    struct Key: Hashable {
        let clip: String
        let index: Int
        let look: Look
        /// 定格帧步态为 0，和同一帧号的动态帧是两张图
        let still: Bool
        var motion: CastMotion? = nil
    }
    /// 一格的位图比槽宽：光晕、环绕线、「?」都伸出 27pt 的格子，球心在 (24, 19)
    static let box = CGSize(width: 48, height: 32)
    static let anchor = CGPoint(x: 24, y: CrewGeometry.bodyCenterY)

    let art: BloubArt
    let cast: CastArt
    private var images: [Key: CGImage] = [:]
    static let capacity = 1024
    private var insertionOrder: [Key] = []
    private var evictionIndex = 0

    /// `cast` 不传就用进程内那份分配表的素材（默认参数在隔离外求值会报警，所以在体内兜底）
    init(art: BloubArt, cast: CastArt? = nil) {
        self.art = art
        self.cast = cast ?? CrewCastStore.shared.art
    }

    var count: Int { images.count }

    func image(_ key: Key, scale: CGFloat) -> CGImage? {
        if let hit = images[key] { return hit }
        guard let clip = art.clips[key.clip], key.index >= 0, key.index < clip.frames.count else { return nil }
        let frame = clip.frames[key.index]
        let time = Double(key.index) / clip.fps
        let style = CrewStyle.style(mood: key.look.mood, skin: key.look.skin, tier: key.look.tier)
        // 球造不出角色（nil），走 bloub 原来的画法；定格帧步态 0
        let actor = CastActor(art: cast, member: key.look.cast, amp: key.still ? 0 : CastActor.amp(for: key.look.mood), frameIndex: key.index, frameCount: clip.frames.count, motion: key.motion)
        let renderer = ImageRenderer(content: Canvas { context, _ in
            context.translateBy(x: Self.anchor.x, y: Self.anchor.y)
            context.scaleBy(x: CrewGeometry.scale, y: CrewGeometry.scale)
            frame.draw(in: context, time: time, style: style, actor: actor)
        }.frame(width: Self.box.width, height: Self.box.height))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        if insertionOrder.count == Self.capacity {
            images.removeValue(forKey: insertionOrder[evictionIndex])
            insertionOrder[evictionIndex] = key
            evictionIndex = (evictionIndex + 1) % Self.capacity
        } else {
            insertionOrder.append(key)
        }
        images[key] = image
        return image
    }

    /// 名册变了：不在屏上的那几套扔掉，内存只留当前角色的片段。
    func keep(_ looks: Set<Look>) {
        images = images.filter { looks.contains($0.key.look) }
        insertionOrder = insertionOrder.filter { images[$0] != nil }
        evictionIndex = 0
    }
}

/// A wing renders one cached image per slot and tracks hover and clicks.
/// 右键不弹 Tally 菜单（那是刘海的）。
private final class CrewAccessibleSlot: NSAccessibilityElement {
    var activate: (() -> Bool)?
    override func accessibilityPerformPress() -> Bool {
        activate?() ?? false
    }
}

final class CrewStripView: NSView {
    let side: CrewGeometry.Side
    private(set) var slots: [CrewSlot] = []
    private var skin: BloubArt.Style.Skin = .glass
    private let background = CAShapeLayer()
    private var cells: [CALayer] = []
    private var extras: [CALayer] = []
    private var completionDots: [CALayer?] = []
    private var shown: [CrewFrameCache.Key?] = []
    var onHover: ((Int?) -> Void)?
    var onClick: ((Int) -> Void)?
    private var hovered: Int?
    private var reduceMotion = false
    private var clickedAt: [String: Date] = [:]

    init(side: CrewGeometry.Side) {
        self.side = side
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: CrewGeometry.wingWidth(slots: 1), height: 32)))
        wantsLayer = true
        background.fillColor = NSColor.black.cgColor
        layer?.addSublayer(background)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(slots: [CrewSlot], skin: BloubArt.Style.Skin, size: CGSize, reduceMotion: Bool = false, entering: Set<String> = []) {
        let oldCells = Dictionary(uniqueKeysWithValues: zip(self.slots, cells).compactMap { slot, cell in slot.project.map { ($0.id, cell) } })
        let identitiesChanged = self.slots.map { $0.project?.id } != slots.map { $0.project?.id }
        self.slots = slots
        self.skin = skin
        self.reduceMotion = reduceMotion
        let activeIDs = Set(slots.compactMap { $0.project?.id })
        clickedAt = clickedAt.filter { activeIDs.contains($0.key) }
        // 翼撤下再回来 AppKit 不补 mouseExited，槽重排后旧编号也不作数：忘掉上次报过的格，下一次移动照常报
        hovered = nil
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = CGRect(origin: .zero, size: size)
        background.frame = bounds
        background.path = CrewGeometry.outline(side: side, size: size).cgPath
        for layer in cells + extras { layer.removeFromSuperlayer() }
        cells = []
        extras = []
        completionDots = []
        shown = Array(repeating: nil, count: slots.count)
        for (index, slot) in slots.enumerated() {
            let center = CrewGeometry.slotCenterX(side: side, index: index, slots: slots.count)
            let cell = slot.project.flatMap { oldCells[$0.id] } ?? CALayer()
            if reduceMotion { cell.removeAllAnimations() }
            cell.frame = CGRect(x: center - CrewFrameCache.anchor.x, y: 0, width: CrewFrameCache.box.width, height: CrewFrameCache.box.height)
            cell.contentsScale = scale
            cell.contentsGravity = .resize
            layer?.addSublayer(cell)
            cells.append(cell)
            if let id = slot.project?.id, entering.contains(id), !reduceMotion {
                let lift = CAKeyframeAnimation(keyPath: "transform.translation.y")
                lift.values = [8, -1.5, 0]
                lift.keyTimes = [0, 0.7, 1]
                let scale = CAKeyframeAnimation(keyPath: "transform.scale")
                scale.values = [0.65, 1.06, 1]
                scale.keyTimes = [0, 0.7, 1]
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0; fade.toValue = 1
                let group = CAAnimationGroup()
                group.animations = [lift, scale, fade]
                group.duration = 0.35
                group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                cell.add(group, forKey: "arrival")
            }
            if slot.hasNewCompletion {
                let dot = CAShapeLayer()
                dot.frame = CGRect(x: center + 7, y: 4, width: 6, height: 6)
                dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
                dot.fillColor = NSColor.systemGreen.cgColor
                extras.append(dot)
                completionDots.append(dot)
            } else {
                completionDots.append(nil)
            }
            // 球上不画会话数：22pt 的玻璃球贴个白底角标像通知红点，数目在撑开的第二行看
            guard slot.project == nil else { continue }
            let text = "+\(slot.overflow)"
            let width = CGFloat(text.count) * 6 + 8
            extras += Self.label(text, size: 9, weight: .bold, color: .white, background: NSColor.white.withAlphaComponent(0.22),
                                 frame: CGRect(x: center - width / 2, y: CrewGeometry.bodyCenterY - 7, width: width, height: 14), scale: scale)
        }
        for layer in extras { self.layer?.addSublayer(layer) }
        CATransaction.commit()
        updateTrackingAreas()
        if identitiesChanged { NSAccessibility.post(element: self, notification: .layoutChanged) }
    }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, background: NSColor, frame: CGRect, scale: CGFloat) -> [CALayer] {
        let pill = CAShapeLayer()
        pill.frame = frame
        pill.path = CGPath(roundedRect: CGRect(origin: .zero, size: frame.size), cornerWidth: frame.height / 2, cornerHeight: frame.height / 2, transform: nil)
        pill.fillColor = background.cgColor
        let label = CATextLayer()
        label.string = text
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.fontSize = size
        label.foregroundColor = color.cgColor
        label.alignmentMode = .center
        label.contentsScale = scale
        label.frame = CGRect(x: frame.minX, y: frame.midY - size * 0.62, width: frame.width, height: size * 1.3)
        return [pill, label]
    }

    /// 每个时钟 tick：算每格该是哪一帧，变了才换图。
    func tick(now: Date, still: Bool, cache: CrewFrameCache) {
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, slot) in slots.enumerated() {
            guard let project = slot.project else { continue }
            let age = max(0, now.timeIntervalSince(slot.startedAt))
            let elapsed = age + slot.phase
            guard let picked = CrewPlayback.pick(mood: project.mood, tier: project.tier, elapsed: elapsed, still: still, art: cache.art) else { continue }
            let wake = slot.wokeAt.flatMap { CrewPlayback.wakeMotion(mood: project.mood, tier: project.tier,
                elapsed: now.timeIntervalSince($0), phase: slot.phase, still: still, art: cache.art) }
            let click = clickedAt[project.id].flatMap { CastMotion.forClick(elapsed: now.timeIntervalSince($0), still: still) }
            let motion = click ?? wake ?? CastMotion.forCrew(mood: project.mood, tier: project.tier, elapsed: age, phase: slot.phase, still: still,
                seed: CrewRoster.bucket(project.id, of: 997))
            let key = CrewFrameCache.Key(clip: picked.clip, index: picked.index, look: .init(mood: project.mood, tier: project.tier, skin: skin, cast: slot.cast), still: still, motion: motion)
            guard shown[index] != key, let image = cache.image(key, scale: scale) else { continue }
            cells[index].contents = image
            shown[index] = key
        }
        CATransaction.commit()
    }

    func setHighlighted(_ index: Int?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (position, cell) in cells.enumerated() { cell.opacity = position == index ? 0 : 1 }
        for (position, dot) in completionDots.enumerated() { dot?.opacity = position == index ? 0 : 1 }
        CATransaction.commit()
    }

    func image(at index: Int) -> CGImage? {
        guard cells.indices.contains(index) else { return nil }
        return cells[index].contents as! CGImage?
    }

    func coverForClick(_ index: Int) {
        guard cells.indices.contains(index), !reduceMotion else { return }
        let cover = CABasicAnimation(keyPath: "opacity")
        cover.fromValue = 0; cover.toValue = 0
        cover.duration = CrewFeedbackPanel.duration
        cells[index].add(cover, forKey: "click-cover")
    }

    func clickFeedback(_ index: Int) {
        guard slots.indices.contains(index) else { return }
        if let id = slots[index].project?.id { clickedAt[id] = Date() }
        if !reduceMotion {
            let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
            bounce.values = [1, 0.84, 1.12, 1]
            bounce.keyTimes = [0, 0.2, 0.55, 1]
            bounce.duration = 0.32
            cells[index].add(bounce, forKey: "click")
        }
    }

    func click(_ index: Int) {
        guard slots.indices.contains(index) else { return }
        clickFeedback(index)
        onClick?(index)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    private func slot(for event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return CrewGeometry.slot(atX: point.x, side: side, slots: slots.count)
    }

    private func report(_ slot: Int?) {
        guard slot != hovered else { return }
        if let previous = hovered, cells.indices.contains(previous) { cells[previous].removeAnimation(forKey: "attention") }
        hovered = slot
        if let slot, cells.indices.contains(slot), !reduceMotion {
            let lift = CAKeyframeAnimation(keyPath: "transform.translation.y")
            lift.values = [0, -1.5, 0]
            lift.duration = 0.35
            cells[slot].add(lift, forKey: "attention")
        }
        onHover?(slot)
    }

    override func mouseEntered(with event: NSEvent) { report(slot(for: event)) }
    override func mouseMoved(with event: NSEvent) { report(slot(for: event)) }
    override func mouseExited(with event: NSEvent) { report(nil) }
    override func mouseDown(with event: NSEvent) {
        if let slot = slot(for: event) { click(slot) }
    }
    override func rightMouseDown(with event: NSEvent) {}

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? {
        guard let window else { return [] }
        return slots.enumerated().map { index, slot in
            let element = CrewAccessibleSlot()
            element.setAccessibilityRole(.button)
            element.setAccessibilityParent(self)
            let label = slot.project.map { "\($0.name)，\($0.mood.label)，\($0.sessions.count) 个会话" } ?? "还有 \(slot.overflow) 个项目"
            element.setAccessibilityLabel(label + (slot.hasNewCompletion ? "，有新完成，尚未跳回终端" : ""))
            let rect = CrewGeometry.hitRect(side: side, index: index, slots: slots.count, height: bounds.height)
            element.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil)))
            let projectID = slot.project?.id
            element.activate = { [weak self] in
                guard let self, let current = self.slots.firstIndex(where: { $0.project?.id == projectID }), self.onClick != nil else { return false }
                self.click(current)
                return true
            }
            return element
        }
    }
}

/// 翅膀窗口：属性照提示药丸，级别比刘海面板低一级、比菜单栏和状态项高。
final class CrewPanel: NSPanel {
    let strip: CrewStripView

    init(side: CrewGeometry.Side) {
        strip = CrewStripView(side: side)
        super.init(contentRect: strip.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = .mainMenu + 2
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = strip
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 两翼的协调者：`NotchController` 持有一个，在五个接入点调它；它不反向引用面板，要展开面板走注入的闭包。
@MainActor
final class CrewController {
    /// 名册每次重算后调（crew-badge 在这里发工牌）
    var rosterChanged: (([CrewProject]) -> Void)?
    /// 光标进出哪一格（`CrewExpandController` 据此撑开）；离开翼是 nil
    var onHover: ((CrewHover?) -> Void)?
    var onClick: ((CrewHover) -> Void)?
    var onSessionClick: ((SessionRecord) -> Void)?
    var onDismiss: (() -> Void)?
    /// 撑开着的那格：悬停控制器定，这里只按它排两翼
    private(set) var expanded: CrewHover?

    private(set) var projects: [CrewProject] = []
    private(set) var layout = CrewLayout(right: [], left: [], overflow: 0)
    private var sessions: [SessionRecord] = []
    private var completionIDs: Set<String> = []
    private var playback: [String: (mood: CrewMood, tier: CrewTier, startedAt: Date, wokeAt: Date?)] = [:]
    private var arrivals: Set<String> = []
    private var departures: [String: CrewFeedbackPanel] = [:]
    private var clickPanel: CrewFeedbackPanel?
    private var confirmedClosures: Set<String> = []
    private var missingProjects: [String: Set<String>] = [:]
    private var wings: [CrewGeometry.Side: CrewPanel] = [:]
    private var dropdown: CrewDropdownPanel?
    private var avatar: CrewAvatarPanel?
    private var avatarID: String?
    private var avatarTarget: CGRect?
    private var metrics: ScreenMetrics?
    private var enabled = false
    private var perSide = 3
    private var spillRight = false
    private var skin: BloubArt.Style.Skin = .glass
    private var sharingType: NSWindow.SharingType = .readOnly
    /// 面板展开或全屏隐藏期间两翼整个不上屏
    private var hidden = false
    /// 屏幕熄灭 / 会话不活跃时时钟停
    private var asleep = false
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var observers: [NSObjectProtocol] = []
    private var staleTimer: Timer?
    private var clock: Timer?
    /// 量到的菜单右缘（相对菜单栏左缘）和它是哪个 app 的；nil 是还没量到或读不到
    private var menuBarEnd: CGFloat?
    private var menuBarPid: pid_t?
    private var roomTimer: Timer?
    private var roomReading = false
    /// 量一个 app 的菜单排到哪儿。测试不注入就不量：xctest 从授权过辅助功能的终端里跑时，量到的是当时前台那个 app 的菜单
    private let readMenuEnd: (@Sendable (pid_t) -> CGFloat?)?
    private let cache: CrewFrameCache?
    /// 角色分配表和目录规范化缓存都在它那儿，AI 页、药丸、工牌查的是同一张表
    private let cast: CrewCastStore

    var frameCache: CrewFrameCache? { cache }
    /// 菜单栏给两翼留的格数（docs/crew.md「让开菜单」）：按量到的菜单右缘和当前屏幕现算，屏幕变了不用重量；nil 照 perSide 排
    var room: CrewRoom? {
        guard let menuBarEnd, let metrics else { return nil }
        return MenuBarRoom.room(menuEnd: menuBarEnd, on: metrics)
    }
    var clockInterval: Double? { clock?.timeInterval }
    var dropdownWindow: NSPanel? { dropdown }
    var avatarWindow: NSPanel? { avatar }
    var departureWindows: [NSPanel] { Array(departures.values) }
    var clickWindow: NSPanel? { clickPanel }

    init(art: BloubArt? = .bundled, cast: CrewCastStore? = nil, menuEnd: (@Sendable (pid_t) -> CGFloat?)? = nil, motionReduced: Bool? = nil) {
        let cast = cast ?? .shared
        self.cast = cast
        if let motionReduced { reduceMotion = motionReduced }
        readMenuEnd = menuEnd
        if let art {
            cache = CrewFrameCache(art: art, cast: cast.art)
        } else {
            // 开关开着却看不到小人，没有这行日志只能猜；缺哪段、坏哪段 BloubArt 自己已经记了
            Log.error("bloub/frames.json 读不到或片段不全（原因见上一条日志），刘海两侧不画角色")
            cache = nil
        }
    }

    func wing(_ side: CrewGeometry.Side) -> NSPanel? { wings[side] }

    /// 设置变了：关掉就撤窗口、停时钟、摘观察者。
    func apply(enabled: Bool, perSide: Int, skin: BloubArt.Style.Skin, sharingType: NSWindow.SharingType, spillRight: Bool = false) {
        self.enabled = enabled && cache != nil
        self.perSide = CrewRoster.perSide(perSide)
        self.spillRight = spillRight
        self.skin = skin
        self.sharingType = sharingType
        for wing in wings.values { wing.sharingType = sharingType }
        for panel in departures.values { panel.sharingType = sharingType }
        clickPanel?.sharingType = sharingType
        dropdown?.sharingType = sharingType
        avatar?.sharingType = sharingType
        if self.enabled {
            installObservers()
        } else {
            removeObservers()
            onHover?(nil)
            for wing in wings.values { wing.close() }
            wings.removeAll()
            dropdown?.close()
            dropdown = nil
            avatar?.close()
            avatar = nil
            avatarID = nil
            avatarTarget = nil
            playback.removeAll()
            confirmedClosures.removeAll()
            missingProjects.removeAll()
            arrivals.removeAll()
            clearFeedback()
            projects.removeAll()
            layout = CrewLayout(right: [], left: [], overflow: 0)
            expanded = nil
            menuBarEnd = nil
            menuBarPid = nil
            cache?.keep([])
        }
        refresh(sessions)
    }

    func relayout(metrics: ScreenMetrics?) {
        if self.metrics != metrics {
            clearFeedback()
            onDismiss?()
            expanded = nil
        }
        self.metrics = metrics
        // 每侧能放几格是按刘海位置算的：屏幕变了当场按新的重排，不等下一次量
        if enabled { layout = CrewRoster.layout(projects, perSide: perSide, room: room, spillRight: spillRight) }
        render()
    }

    /// 悬停控制器说该撑开哪格（nil 全收）：翼宽随之变，刘海那头不动。
    func setExpanded(_ hover: CrewHover?) {
        guard hover != expanded else { return }
        expanded = hover
        render()
    }

    func setHidden(_ hidden: Bool) {
        guard hidden != self.hidden else { return }
        self.hidden = hidden
        // 翼撤下时追踪区不会再报离开，悬停方自己也收不掉
        if hidden { onHover?(nil) }
        render()
    }

    /// 名册刷新后同一个项目（或「+N」胶囊）现在在哪一格；不在翼上返回 nil。
    func hover(matching old: CrewHover) -> CrewHover? {
        for side in CrewGeometry.Side.allCases {
            for (index, slot) in slots(side).enumerated() where slot.project?.id == old.slot.project?.id {
                return hover(side: side, index: index)
            }
        }
        return nil
    }

    /// 会话变了（或过了一分钟，失联要按时间翻）：重算名册，mood 变了的槽重置时间原点。
    func observeClosures(_ records: [SessionRecord]) {
        confirmedClosures = Set(records.filter { $0.state == .ended }.map { "\(CrewRoster.tool(of: $0)):\($0.sessionId)" })
    }

    func refresh(_ sessions: [SessionRecord], now: Date = Date(), completionIDs: Set<String>? = nil) {
        self.sessions = sessions
        if let completionIDs { self.completionIDs = completionIDs }
        guard enabled else { return }
        let previous = projects
        let previousIDs = Set(previous.map(\.id))
        projects = CrewRoster.projects(sessions, now: now, canonicalize: cast.canonicalize)
        let currentIDs = Set(projects.map(\.id))
        for id in currentIDs { departures.removeValue(forKey: id)?.close() }
        // Missing files are not evidence of a closed session; the loader also supplies one-shot end records.
        let ended = confirmedClosures.union(sessions.filter { $0.state == .ended }.map { "\(CrewRoster.tool(of: $0)):\($0.sessionId)" })
        let hasEnded: (CrewProject) -> Bool = { project in
            project.sessions.allSatisfy { ended.contains("\(CrewRoster.tool(of: $0)):\($0.sessionId)") }
        }
        let retired = Set(previous.filter { !currentIDs.contains($0.id) && hasEnded($0) }.map(\.id))
        // A recovered snapshot is not a new hire. Keep bounded identity memory, like badge lifecycle tracking.
        missingProjects = missingProjects.compactMapValues { identities in
            let remaining = identities.subtracting(ended)
            return remaining.isEmpty ? nil : remaining
        }
        arrivals = currentIDs.subtracting(previousIDs).subtracting(missingProjects.keys)
        missingProjects = missingProjects.filter { !currentIDs.contains($0.key) }
        for project in previous where !currentIDs.contains(project.id) && !retired.contains(project.id) {
            if missingProjects.count >= 500, let evicted = missingProjects.keys.first { missingProjects.removeValue(forKey: evicted) }
            missingProjects[project.id] = Set(project.sessions.map { "\(CrewRoster.tool(of: $0)):\($0.sessionId)" }).subtracting(ended)
        }
        confirmedClosures.removeAll()
        retire(retired)
        var next: [String: (mood: CrewMood, tier: CrewTier, startedAt: Date, wokeAt: Date?)] = [:]
        for project in projects {
            // 变档和变 mood 一样换片段，从头播
            if let old = playback[project.id], old.mood == project.mood && old.tier == project.tier {
                next[project.id] = old
            } else {
                let wake = playback[project.id].map { CastMotion.shouldWake(from: $0.mood, tier: $0.tier, to: project.mood, tier: project.tier) } ?? false
                next[project.id] = (project.mood, project.tier, now, wake ? now : nil)
            }
        }
        playback = next
        layout = CrewRoster.layout(projects, perSide: perSide, room: room, spillRight: spillRight)
        render()
        arrivals.removeAll()
        rosterChanged?(projects)
    }

    private func slots(_ side: CrewGeometry.Side) -> [CrewSlot] {
        let shown = side == .right ? layout.right : layout.left
        var slots = shown.map { project in
            let startedAt = playback[project.id]?.startedAt ?? Date()
            return CrewSlot(project: project, overflow: 0, startedAt: startedAt, phase: Double(CrewRoster.bucket(project.id + "·phase", of: 6)) * 0.41,
                            cast: cast.member(forKey: project.id), hasNewCompletion: project.sessions.contains { completionIDs.contains($0.sessionId) },
                            wokeAt: playback[project.id]?.wokeAt)
        }
        if side == layout.overflowSide, layout.overflow > 0 {
            let visibleIDs = Set((layout.left + layout.right).map(\.id))
            let hiddenHasCompletion = projects.contains { !visibleIDs.contains($0.id) && $0.sessions.contains { completionIDs.contains($0.sessionId) } }
            slots.append(CrewSlot(project: nil, overflow: layout.overflow, startedAt: .distantPast, phase: 0, hasNewCompletion: hiddenHasCompletion))
        }
        return slots
    }

    private func clearFeedback() {
        clickPanel?.close()
        clickPanel = nil
        for panel in departures.values { panel.close() }
        departures.removeAll()
    }

    private func retire(_ ids: Set<String>) {
        guard enabled, !hidden, !asleep, !reduceMotion, metrics != nil, let cache else { return }
        for wing in wings.values where wing.isVisible {
            for (index, slot) in wing.strip.slots.enumerated() {
                guard let project = slot.project, ids.contains(project.id) else { continue }
                let clipName = project.mood.clip(tier: project.tier)
                let portrait = cache.art.clips[clipName].flatMap { clip -> CGImage? in
                    guard let frame = clip.frames.firstIndex(where: { $0.eyeSpecs.count == 2 && $0.fit.sx > 0.8 && $0.fit.sy > 0.8 }) else { return nil }
                    return cache.image(.init(clip: clipName, index: frame,
                        look: .init(mood: project.mood, tier: project.tier, skin: skin, cast: slot.cast), still: true,
                        motion: CastMotion(kind: .farewell, step: 10)), scale: wing.backingScaleFactor)
                } ?? wing.strip.image(at: index)
                guard let portrait else { continue }
                let center = CrewGeometry.slotCenterX(side: wing.strip.side, index: index, slots: wing.strip.slots.count)
                let rect = CGRect(x: center - CrewFrameCache.anchor.x, y: 0, width: CrewFrameCache.box.width, height: CrewFrameCache.box.height)
                let frame = wing.convertToScreen(wing.strip.convert(rect, to: nil))
                departures.removeValue(forKey: project.id)?.close()
                if departures.count >= 8, let oldest = departures.keys.first { departures.removeValue(forKey: oldest)?.close() }
                let panel = CrewFeedbackPanel(frame: frame, image: portrait, sharingType: sharingType)
                departures[project.id] = panel
                panel.animate(.departure) { [weak self, weak panel] in
                    panel?.close()
                    if self?.departures[project.id] === panel { self?.departures.removeValue(forKey: project.id) }
                }
            }
        }
    }

    func select(_ session: SessionRecord, from hover: CrewHover) {
        respondToClick(hover) { onSessionClick?(session) }
    }

    private func respondToClick(_ hover: CrewHover, action: () -> Void) {
        // Capture before navigation dismisses the source, then let the response outlive that dismissal.
        let response: CrewFeedbackPanel? = {
            guard enabled, !hidden, !asleep, !reduceMotion, let wing = wings[hover.side], wing.isVisible else { return nil }
            if expanded?.sameSlot(as: hover) == true, let avatar, avatar.isVisible,
               let view = avatar.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let image = bitmap.cgImage { return CrewFeedbackPanel(frame: avatar.frame, image: image, sharingType: sharingType) }
            }
            let center = CrewGeometry.slotCenterX(side: hover.side, index: hover.index, slots: wing.strip.slots.count)
            let rect = CGRect(x: center - CrewFrameCache.anchor.x, y: 0, width: CrewFrameCache.box.width, height: CrewFrameCache.box.height)
            var image = wing.strip.image(at: hover.index)
            if image == nil, let bitmap = wing.strip.bitmapImageRepForCachingDisplay(in: rect) {
                wing.strip.cacheDisplay(in: rect, to: bitmap)
                image = bitmap.cgImage
            }
            guard let image else { return nil }
            return CrewFeedbackPanel(frame: wing.convertToScreen(wing.strip.convert(rect, to: nil)), image: image, sharingType: sharingType)
        }()
        action()
        guard let response, enabled, !asleep, !reduceMotion, metrics != nil else { return }
        wings[hover.side]?.strip.coverForClick(hover.index)
        clickPanel?.close()
        clickPanel = response
        response.animate(.click) { [weak self, weak response] in
            response?.close()
            if self?.clickPanel === response { self?.clickPanel = nil }
        }
    }

    private func render() {
        guard enabled, !hidden, let metrics, let cache else {
            clearFeedback()
            for wing in wings.values { wing.orderOut(nil) }
            dropdown?.orderOut(nil)
            avatar?.orderOut(nil)
            avatarID = nil
            avatarTarget = nil
            scheduleClock()
            return
        }
        var looks: Set<CrewFrameCache.Look> = []
        for side in CrewGeometry.Side.allCases {
            let slots = slots(side)
            guard let frame = CrewGeometry.wingFrame(side: side, slots: slots.count, on: metrics) else {
                wings[side]?.orderOut(nil)
                continue
            }
            let wing: CrewPanel
            if let existing = wings[side] {
                wing = existing
            } else {
                wing = CrewPanel(side: side)
                wing.strip.onHover = { [weak self] index in self?.hovered(side: side, index: index) }
                wing.strip.onClick = { [weak self] index in
                    guard let self, let hover = self.hover(side: side, index: index) else { return }
                    self.respondToClick(hover) { self.onClick?(hover) }
                }
                wings[side] = wing
            }
            wing.sharingType = sharingType
            wing.setFrame(frame, display: false)
            wing.strip.configure(slots: slots, skin: skin, size: frame.size, reduceMotion: reduceMotion, entering: arrivals)
            for slot in slots { if let project = slot.project { looks.insert(.init(mood: project.mood, tier: project.tier, skin: skin, cast: slot.cast)) } }
            if !wing.isVisible { wing.orderFrontRegardless() }
        }
        renderDropdown(on: metrics)
        cache.keep(looks)
        tick()
        scheduleClock()
    }

    private func renderDropdown(on metrics: ScreenMetrics) {
        for wing in wings.values { wing.strip.setHighlighted(nil) }
        guard let hover = expanded, let project = hover.slot.project, let wing = wings[hover.side], wing.isVisible,
              wing.strip.slots.indices.contains(hover.index), wing.strip.slots[hover.index].project?.id == project.id else {
            dropdown?.orderOut(nil)
            avatar?.orderOut(nil)
            avatarID = nil
            avatarTarget = nil
            return
        }
        let select: (SessionRecord) -> Void = { [weak self] session in
            self?.select(session, from: hover)
        }
        let panel: CrewDropdownPanel
        if let existing = dropdown {
            panel = existing
            panel.update(project: project, side: hover.side, completionIDs: completionIDs, select: select)
        } else {
            panel = CrewDropdownPanel(project: project, side: hover.side, completionIDs: completionIDs, select: select) { [weak self] inside in
                guard let self else { return }
                self.onHover?(inside ? self.expanded : nil)
            }
            dropdown = panel
        }
        let count = slots(hover.side).count
        let anchorX = wing.frame.minX + CrewGeometry.slotCenterX(side: hover.side, index: hover.index, slots: count)
        panel.sharingType = sharingType
        let dropdownFrame = CrewDropdownPanel.frame(anchorX: anchorX, top: wing.frame.minY - CrewDropdownPanel.wingGap, screen: metrics.frame, count: project.sessions.count, side: hover.side)
        panel.setFrame(dropdownFrame, display: true)
        wing.strip.setHighlighted(hover.index)
        if !panel.isVisible { panel.orderFrontRegardless() }
        let targetX = hover.side == .right ? dropdownFrame.minX + 29 : dropdownFrame.maxX - 29
        let target = CGRect(x: targetX - 19, y: dropdownFrame.maxY - 6 - 38, width: 38, height: 38)
        let portrait = cast.member(forKey: project.id)
        let moving = avatar ?? CrewAvatarPanel(mood: project.mood, tier: project.tier, cast: portrait)
        avatar = moving
        moving.sharingType = sharingType
        let restart = avatarID != project.id || !moving.isVisible
        moving.update(mood: project.mood, tier: project.tier, cast: portrait, restart: restart,
                      startedAt: hover.slot.startedAt, phase: hover.slot.phase, seed: CrewRoster.bucket(project.id, of: 997), wokeAt: hover.slot.wokeAt,
                      animating: !asleep)
        if restart {
            let start = CGRect(x: anchorX - 11, y: wing.frame.maxY - CrewGeometry.bodyCenterY - 11, width: 22, height: 22)
            moving.setFrame(reduceMotion ? target : start, display: true)
            moving.orderFrontRegardless()
            if !reduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.35
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    moving.animator().setFrame(target, display: true)
                }
            }
        } else if avatarTarget != target {
            moving.setFrame(target, display: true)
        }
        avatarID = project.id
        avatarTarget = target
    }

    /// 读了一次 `pid` 的菜单：`end` 是菜单右缘（相对菜单栏左缘），nil 是没读到。每侧能放几格变了就重排。
    /// 没读到时，同一个 app 沿用上一次的（对方一时没响应，这一轮不算）；换了 app 就不能接着用上一个 app 的——
    /// 它要是把两翼挤没了，小人会一直不见——回到不限。关掉开关后才回来的那一次不算。
    func menuBarRead(pid: pid_t, end: CGFloat?) {
        guard enabled, end != nil || pid != menuBarPid else { return }
        let before = room
        menuBarPid = pid
        menuBarEnd = end
        // 「小人怎么少了 / 怎么又压菜单了」只能靠这两行查：容量是跟着前台 app 变的，事后看不出来
        if end == nil { Log.debug("读不到 pid \(pid) 的菜单排到哪儿（没给辅助功能权限、对方没响应或没有菜单栏），两翼不让") }
        guard room != before else { return }
        clearFeedback()
        if let end, let room { Log.debug("菜单排到 \(Int(end))pt：两翼容量 左 \(room.left) 右 \(room.right == .max ? "不限" : String(room.right))") }
        // 走 refresh：悬停着的那格可能挪了位，跟名册变了是同一套收尾
        refresh(sessions)
    }

    /// 问一次菜单栏属主的菜单排到哪儿。在后台队列问：对方卡住时要等满超时，不能堵主线程；上一次还没回来就不再问。
    private func measureRoom() {
        guard let readMenuEnd, enabled, metrics != nil, !roomReading,
              let pid = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier else { return }
        roomReading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let end = readMenuEnd(pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.roomReading = false
                    // 问的这会儿菜单栏换了属主：这个结果是上一个 app 的，丢掉重问
                    guard NSWorkspace.shared.menuBarOwningApplication?.processIdentifier == pid else { return self.measureRoom() }
                    self.menuBarRead(pid: pid, end: end)
                }
            }
        }
    }

    /// 有项目可画、两翼没被藏起时每 2 秒量一次：切 app 有通知，但 app 刚启动时菜单晚几秒才齐、有的 app 运行中增减菜单，没有通知可听。
    /// 不看翼在不在屏上：被菜单挤到一格不剩时也得接着量，不然菜单变短了回不来。
    private func scheduleRoomPoll() {
        guard readMenuEnd != nil, enabled, !hidden, !asleep, metrics != nil, !projects.isEmpty else {
            roomTimer?.invalidate()
            roomTimer = nil
            return
        }
        guard roomTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.measureRoom() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        roomTimer = timer
        measureRoom()
    }

    /// 时钟只在两翼真的在屏上、而且该动的时候走；减少动态效果时停表、只画静态帧。量菜单的定时器跟它同一批时机起停。
    private func scheduleClock() {
        scheduleRoomPoll()
        let running = enabled && !hidden && !asleep && !reduceMotion && wings.values.contains { $0.isVisible }
        guard running else {
            clock?.invalidate()
            clock = nil
            return
        }
        let interval = ProcessInfo.processInfo.isLowPowerModeEnabled ? 0.1 : 0.05
        if let clock, abs(clock.timeInterval - interval) < 0.001 { return }
        clock?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func tick() {
        guard let cache else { return }
        let now = Date()
        for wing in wings.values where wing.isVisible {
            wing.strip.tick(now: now, still: reduceMotion, cache: cache)
        }
    }

    private func hover(side: CrewGeometry.Side, index: Int) -> CrewHover? {
        guard wings[side] != nil else { return nil }
        let slots = slots(side)
        guard index >= 0, index < slots.count else { return nil }
        return CrewHover(side: side, index: index, slot: slots[index])
    }

    private func hovered(side: CrewGeometry.Side, index: Int?) {
        onHover?(index.flatMap { hover(side: side, index: $0) })
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let pausing: [(Notification.Name, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.sessionDidResignActiveNotification, true),
            (NSWorkspace.screensDidWakeNotification, false), (NSWorkspace.sessionDidBecomeActiveNotification, false),
        ]
        observers = pausing.map { name, pause in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.asleep != pause else { return }
                    self.asleep = pause
                    if pause { self.clearFeedback() }
                    self.avatar?.setAnimating(!pause && self.avatar?.isVisible == true)
                    self.scheduleClock()
                }
            }
        }
        observers.append(center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                if self.reduceMotion { self.clearFeedback() }
                self.render()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleClock() }
        })
        // 切 app 菜单栏当场换，不等 2 秒那一轮；两翼藏着（面板展开）时也量，收起回来就是准的。
        // 通知到的那一刻菜单栏可能还没换属主、刚启动的 app 也可能还答不上来（实测切过去 1.4 秒翼还是上一个 app 的排法），半秒后补量一次
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.measureRoom()
                try? await Task.sleep(for: .seconds(0.5))
                self?.measureRoom()
            }
        })
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(self?.sessions ?? []) }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        staleTimer = timer
    }

    private func removeObservers() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        // 没人再听醒来的通知：关着的时候睡过一觉，再开时不能还当它睡着
        asleep = false
        staleTimer?.invalidate()
        staleTimer = nil
        clock?.invalidate()
        clock = nil
        roomTimer?.invalidate()
        roomTimer = nil
    }
}
