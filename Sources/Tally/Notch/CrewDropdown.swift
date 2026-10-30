import AppKit
import SwiftUI

struct CrewDropdownView: View {
    let project: CrewProject
    let side: CrewGeometry.Side
    let select: (SessionRecord) -> Void
    private var avatar: some View {
        Color.clear.frame(width: 38, height: 38).accessibilityHidden(true)
    }

    private var heading: some View {
        VStack(alignment: side == .right ? .leading : .trailing, spacing: 2) {
            Text("\(project.name)项目组").font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text("\(project.provider == "codex" ? "Codex" : "Claude") · \(project.sessions.count) 个会话")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
        }
    }

    private var headerContent: some View {
        HStack(spacing: 8) {
            if side == .right { avatar; heading; Spacer(minLength: 0) }
            else { Spacer(minLength: 0); heading; avatar }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func statusSymbol(_ session: SessionRecord) -> String {
        if session.isProvisional { return "link" }
        switch CrewRoster.mood(of: session, now: Date()) {
        case .permission: return "exclamationmark.shield.fill"
        case .input: return "questionmark.bubble.fill"
        case .compacting: return "arrow.down.right.and.arrow.up.left"
        case .run: return "bolt.fill"
        case .done: return "checkmark.circle.fill"
        case .stale: return "clock.badge.exclamationmark"
        case nil: return "circle"
        }
    }

    private func detail(for session: SessionRecord) -> String? {
        switch CrewRoster.mood(of: session, now: Date()) {
        case .permission, .input: return session.waitingDetail
        case .run: return session.recentActivity
        case .done: return session.recentActivity ?? session.message
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if project.sessions.count == 1, let session = project.sessions.first, !session.isProvisional {
                Button { select(session) } label: { headerContent }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开\(session.displayTitle)所在终端")
            } else {
                headerContent
            }
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 12)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(project.sessions) { session in
                        Button { select(session) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: statusSymbol(session))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(CrewStyle.palette(for: CrewRoster.mood(of: session, now: Date()) ?? .done).lid)
                                    .frame(width: 24, height: 24)
                                    .background(Circle().fill(.white.opacity(0.07)))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.displayTitle).font(.system(size: 11, weight: .medium))
                                        .lineLimit(1).truncationMode(.middle)
                                    Text(session.isProvisional ? "待关联" : "\(CrewRoster.mood(of: session, now: Date())?.label ?? "完成") · \(session.modelLabel ?? session.providerLabel)")
                                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                                    if let detail = detail(for: session) {
                                        Text(detail.replacingOccurrences(of: "\n", with: " "))
                                            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                            }
                            .padding(.horizontal, 9)
                            .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(CrewDropdownButtonStyle())
                        .disabled(session.isProvisional)
                    }
                }.padding(.horizontal, 5).padding(.vertical, 4)
            }
        }
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: 13).fill(Color(red: 0.035, green: 0.037, blue: 0.045)))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.12), lineWidth: 0.7) }
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }
}

private struct CrewMovingAvatar: View {
    let mood: CrewMood
    var tier: CrewTier = .fresh
    var body: some View {
        GeometryReader { geometry in
            CrewBadgeIcon(mood: mood, tier: tier, size: min(geometry.size.width, geometry.size.height), inset: 0.12)
        }.accessibilityHidden(true)
    }
}

final class CrewAvatarPanel: NSPanel {
    private let host: NSHostingView<CrewMovingAvatar>

    init(mood: CrewMood, tier: CrewTier = .fresh) {
        host = NSHostingView(rootView: CrewMovingAvatar(mood: mood, tier: tier))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        level = .mainMenu + 6
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    func update(mood: CrewMood, tier: CrewTier = .fresh) { host.rootView = CrewMovingAvatar(mood: mood, tier: tier) }
}

private struct CrewDropdownButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(configuration.isPressed ? 0.14 : 0.035)))
    }
}

private final class CrewDropdownHost: NSHostingView<CrewDropdownView> {
    var hoverChanged: ((Bool) -> Void)?
    private var hoverTracking: NSTrackingArea?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { hoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { hoverChanged?(false) }
}

final class CrewDropdownPanel: NSPanel {
    static let width: CGFloat = 250
    static let wingGap: CGFloat = 4
    private let host: CrewDropdownHost

    init(project: CrewProject, side: CrewGeometry.Side, select: @escaping (SessionRecord) -> Void, hover: @escaping (Bool) -> Void) {
        host = CrewDropdownHost(rootView: CrewDropdownView(project: project, side: side, select: select))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        level = .mainMenu + 5
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        host.hoverChanged = hover
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(project: CrewProject, side: CrewGeometry.Side, select: @escaping (SessionRecord) -> Void) {
        host.rootView = CrewDropdownView(project: project, side: side, select: select)
    }

    static func frame(anchorX: CGFloat, top: CGFloat, screen: CGRect, count: Int, side: CrewGeometry.Side = .right) -> CGRect {
        let width = min(Self.width, screen.width - 16)
        let height = min(240, 57 + CGFloat(max(count, 1)) * 58)
        let proposed = side == .right ? anchorX - 29 : anchorX - width + 29
        let x = min(max(proposed, screen.minX + 8), screen.maxX - width - 8)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }
}
