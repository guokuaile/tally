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
    }
    struct Key: Hashable {
        let clip: String
        let index: Int
        let look: Look
    }
    /// 一格的位图比槽宽：光晕、环绕线、「?」都伸出 27pt 的格子，球心在 (24, 19)
    static let box = CGSize(width: 48, height: 32)
    static let anchor = CGPoint(x: 24, y: CrewGeometry.bodyCenterY)

    let art: BloubArt
    private var images: [Key: CGImage] = [:]

    init(art: BloubArt) { self.art = art }

    var count: Int { images.count }

    func image(_ key: Key, scale: CGFloat) -> CGImage? {
        if let hit = images[key] { return hit }
        guard let clip = art.clips[key.clip], key.index >= 0, key.index < clip.frames.count else { return nil }
        let frame = clip.frames[key.index]
        let time = Double(key.index) / clip.fps
        let style = CrewStyle.style(mood: key.look.mood, skin: key.look.skin, tier: key.look.tier)
        let renderer = ImageRenderer(content: Canvas { context, _ in
            context.translateBy(x: Self.anchor.x, y: Self.anchor.y)
            context.scaleBy(x: CrewGeometry.scale, y: CrewGeometry.scale)
            frame.draw(in: context, time: time, style: style)
        }.frame(width: Self.box.width, height: Self.box.height))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        images[key] = image
        return image
    }

    /// 名册变了：不在屏上的那几套扔掉，内存只留当前角色的片段。
    func keep(_ looks: Set<Look>) {
        images = images.filter { looks.contains($0.key.look) }
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
    private var shown: [CrewFrameCache.Key?] = []
    var onHover: ((Int?) -> Void)?
    var onClick: ((Int) -> Void)?
    private var hovered: Int?

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

    func configure(slots: [CrewSlot], skin: BloubArt.Style.Skin, size: CGSize) {
        let identitiesChanged = self.slots.map { $0.project?.id } != slots.map { $0.project?.id }
        self.slots = slots
        self.skin = skin
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
        shown = Array(repeating: nil, count: slots.count)
        for (index, slot) in slots.enumerated() {
            let center = CrewGeometry.slotCenterX(side: side, index: index, slots: slots.count)
            let cell = CALayer()
            cell.frame = CGRect(x: center - CrewFrameCache.anchor.x, y: 0, width: CrewFrameCache.box.width, height: CrewFrameCache.box.height)
            cell.contentsScale = scale
            cell.contentsGravity = .resize
            layer?.addSublayer(cell)
            cells.append(cell)
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
            let elapsed = max(0, now.timeIntervalSince(slot.startedAt)) + slot.phase
            guard let picked = CrewPlayback.pick(mood: project.mood, tier: project.tier, elapsed: elapsed, still: still, art: cache.art) else { continue }
            let key = CrewFrameCache.Key(clip: picked.clip, index: picked.index, look: .init(mood: project.mood, tier: project.tier, skin: skin))
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
        CATransaction.commit()
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
        hovered = slot
        onHover?(slot)
    }

    override func mouseEntered(with event: NSEvent) { report(slot(for: event)) }
    override func mouseMoved(with event: NSEvent) { report(slot(for: event)) }
    override func mouseExited(with event: NSEvent) { report(nil) }
    override func mouseDown(with event: NSEvent) {
        if let slot = slot(for: event) { onClick?(slot) }
    }
    override func rightMouseDown(with event: NSEvent) {}

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? {
        guard let window else { return [] }
        return slots.enumerated().map { index, slot in
            let element = CrewAccessibleSlot()
            element.setAccessibilityRole(.button)
            element.setAccessibilityParent(self)
            element.setAccessibilityLabel(slot.project.map { "\($0.name)，\($0.mood.label)，\($0.sessions.count) 个会话" } ?? "还有 \(slot.overflow) 个项目")
            let rect = CrewGeometry.hitRect(side: side, index: index, slots: slots.count, height: bounds.height)
            element.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil)))
            let projectID = slot.project?.id
            element.activate = { [weak self] in
                guard let self, let current = self.slots.firstIndex(where: { $0.project?.id == projectID }), let onClick = self.onClick else { return false }
                onClick(current)
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
    private var playback: [String: (mood: CrewMood, tier: CrewTier, startedAt: Date)] = [:]
    private var wings: [CrewGeometry.Side: CrewPanel] = [:]
    private var dropdown: CrewDropdownPanel?
    private var avatar: CrewAvatarPanel?
    private var avatarID: String?
    private var avatarTarget: CGRect?
    private var metrics: ScreenMetrics?
    private var enabled = false
    private var perSide = 3
    private var skin: BloubArt.Style.Skin = .glass
    private var sharingType: NSWindow.SharingType = .readOnly
    /// 面板展开或全屏隐藏期间两翼整个不上屏
    private var hidden = false
    /// 屏幕熄灭 / 会话不活跃时时钟停
    private var asleep = false
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var observers: [NSObjectProtocol] = []
    /// cwd → 项目键：解符号链接要走文件系统，每次会话变化都对每条重解在主线程上不值当
    private var canonical: [String: String] = [:]
    private var staleTimer: Timer?
    private var clock: Timer?
    private let cache: CrewFrameCache?

    var frameCache: CrewFrameCache? { cache }
    var clockInterval: Double? { clock?.timeInterval }
    var dropdownWindow: NSPanel? { dropdown }
    var avatarWindow: NSPanel? { avatar }

    init(art: BloubArt? = .bundled) {
        if let art, CrewMood.allCases.map(\.clip).allSatisfy({ art.clips[$0] != nil }) {
            cache = CrewFrameCache(art: art)
        } else {
            // 文件整个解不开和缺片段都要留痕：开关开着却看不到小人，没有这行日志只能猜
            Log.error(art == nil ? "bloub/frames.json 读不到或解不开，刘海两侧不画角色" : "frames.json 里缺小刻片段，刘海两侧不画角色")
            cache = nil
        }
    }

    func wing(_ side: CrewGeometry.Side) -> NSPanel? { wings[side] }

    /// 设置变了：关掉就撤窗口、停时钟、摘观察者。
    func apply(enabled: Bool, perSide: Int, skin: BloubArt.Style.Skin, sharingType: NSWindow.SharingType) {
        self.enabled = enabled && cache != nil
        self.perSide = CrewRoster.perSide(perSide)
        self.skin = skin
        self.sharingType = sharingType
        for wing in wings.values { wing.sharingType = sharingType }
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
            projects.removeAll()
            layout = CrewLayout(right: [], left: [], overflow: 0)
            canonical.removeAll()
            expanded = nil
            cache?.keep([])
        }
        refresh(sessions)
    }

    func relayout(metrics: ScreenMetrics?) {
        if self.metrics != metrics {
            onDismiss?()
            expanded = nil
        }
        self.metrics = metrics
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
    func refresh(_ sessions: [SessionRecord], now: Date = Date()) {
        self.sessions = sessions
        guard enabled else { return }
        let canonicalize = { [self] (cwd: String) -> String in
            if let hit = canonical[cwd] { return hit }
            let key = cwd.isEmpty ? "" : CrewRoster.standardized(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path)
            canonical[cwd] = key
            return key
        }
        projects = CrewRoster.projects(sessions, now: now, canonicalize: canonicalize)
        var next: [String: (mood: CrewMood, tier: CrewTier, startedAt: Date)] = [:]
        for project in projects {
            // 变档和变 mood 一样换片段，从头播
            next[project.id] = playback[project.id].flatMap { $0.mood == project.mood && $0.tier == project.tier ? $0 : nil } ?? (project.mood, project.tier, now)
        }
        playback = next
        layout = CrewRoster.layout(projects, perSide: perSide)
        render()
        rosterChanged?(projects)
    }

    private func slots(_ side: CrewGeometry.Side) -> [CrewSlot] {
        let shown = side == .right ? layout.right : layout.left
        var slots = shown.map { project in
            let startedAt = playback[project.id]?.startedAt ?? Date()
            return CrewSlot(project: project, overflow: 0, startedAt: startedAt, phase: Double(CrewRoster.bucket(project.id + "·phase", of: 6)) * 0.41)
        }
        if side == layout.overflowSide, layout.overflow > 0 {
            slots.append(CrewSlot(project: nil, overflow: layout.overflow, startedAt: .distantPast, phase: 0))
        }
        return slots
    }

    private func render() {
        guard enabled, !hidden, let metrics, let cache else {
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
                    self.onClick?(hover)
                }
                wings[side] = wing
            }
            wing.sharingType = sharingType
            wing.setFrame(frame, display: false)
            wing.strip.configure(slots: slots, skin: skin, size: frame.size)
            for slot in slots { if let project = slot.project { looks.insert(.init(mood: project.mood, tier: project.tier, skin: skin)) } }
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
        let select: (SessionRecord) -> Void = { [weak self] session in self?.onSessionClick?(session) }
        let panel: CrewDropdownPanel
        if let existing = dropdown {
            panel = existing
            panel.update(project: project, side: hover.side, select: select)
        } else {
            panel = CrewDropdownPanel(project: project, side: hover.side, select: select) { [weak self] inside in
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
        let moving = avatar ?? CrewAvatarPanel(mood: project.mood, tier: project.tier)
        avatar = moving
        moving.sharingType = sharingType
        moving.update(mood: project.mood, tier: project.tier)
        if avatarID != project.id || !moving.isVisible {
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

    /// 时钟只在两翼真的在屏上、而且该动的时候走；减少动态效果时停表、只画静态帧。
    private func scheduleClock() {
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
                    self.scheduleClock()
                }
            }
        }
        observers.append(center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self.render()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleClock() }
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
    }
}
