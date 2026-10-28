import AppKit
import SwiftUI

/// A notification occupies only its own visible capsule, leaving the gaps between pills clickable.
struct PillNotificationView: View {
    let peek: Peek
    let isInteractive: Bool
    let onTap: () -> Void

    private var isSession: Bool { peek.sessionId != nil && peek.provider != nil }

    @ViewBuilder
    var body: some View {
        if isInteractive {
            pillBody.accessibilityAction(named: "打开提示", onTap)
        } else {
            pillBody
        }
    }

    private var pillBody: some View {
        HStack(spacing: 9) {
            PeekIcon(peek: peek, appeared: true)
                .frame(width: 29, height: 29)

            if isSession {
                sessionContent
            } else {
                genericContent
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            Capsule().fill(Color.black)
                .overlay { Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.7) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var sessionContent: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                ProviderLogo(name: peek.provider == "codex" ? "openai" : "claude", size: 10)
                Text(peek.modelLabel.flatMap { $0.isEmpty ? nil : $0 } ?? providerName)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("·")
                    .foregroundStyle(.white.opacity(0.4))
                Text(statusText)
                    .foregroundStyle(peek.tint)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(.system(size: 11, weight: .semibold))

            GeometryReader { geometry in
                HStack(spacing: 5) {
                    Text(peek.cwdLabel ?? "")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: min(104, geometry.size.width * 0.4), alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    Text("·")
                        .foregroundStyle(.white.opacity(0.35))
                    Text(peek.failureMessage ?? peek.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 12)
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var genericContent: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(peek.label)
                    .foregroundStyle(peek.tint)
                Text(peek.title)
                    .foregroundStyle(.white)
            }
            .font(.system(size: 11, weight: .semibold))
            if let subtitle = peek.subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }

    private var providerName: String {
        peek.provider == "codex" ? "Codex" : "Claude"
    }

    private var statusText: String {
        if peek.failureMessage != nil { return "无法跳转" }
        return switch peek.sessionState {
        case .waitingPermission: "等审批"
        case .waitingInput: "等输入"
        case .ended: "已关闭"
        default: "完成"
        }
    }

    private var accessibilityText: String {
        if isSession {
            return [providerName, peek.modelLabel ?? providerName, statusText, peek.cwdLabel ?? "", peek.failureMessage ?? peek.title]
                .filter { !$0.isEmpty }.joined(separator: "，")
        }
        return [peek.label, peek.title, peek.subtitle ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "，")
    }
}

private final class PillHostingView: NSHostingView<PillNotificationView> {
    var onTap: () -> Void

    required init(rootView: PillNotificationView) {
        onTap = rootView.onTap
        super.init(rootView: rootView)
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onTap()
    }
}

final class PillNotificationPanel: NSPanel {
    static let maxWidth: CGFloat = 320
    static let height: CGFloat = 44
    static let gap: CGFloat = 6

    private let pillHost: PillHostingView

    init(peek: Peek, isInteractive: Bool, onTap: @escaping () -> Void) {
        pillHost = PillHostingView(rootView: PillNotificationView(peek: peek, isInteractive: isInteractive, onTap: onTap))
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: Self.maxWidth, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = .mainMenu + 4
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = !isInteractive
        contentView = pillHost
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(peek: Peek, isInteractive: Bool, onTap: @escaping () -> Void) {
        ignoresMouseEvents = !isInteractive
        pillHost.onTap = onTap
        pillHost.rootView = PillNotificationView(peek: peek, isInteractive: isInteractive, onTap: onTap)
    }

    /// AppKit coordinates start at the bottom of the screen; the first pill starts below the notch.
    func place(on screen: NSScreen, index: Int) {
        setFrame(Self.placementFrame(in: screen.frame, safeAreaTop: screen.safeAreaInsets.top, index: index), display: true)
    }

    static func placementFrame(in screenFrame: CGRect, safeAreaTop: CGFloat, index: Int) -> CGRect {
        let width = min(maxWidth, max(1, screenFrame.width - 32))
        let top = screenFrame.maxY - safeAreaTop - gap
        let origin = CGPoint(
            x: screenFrame.midX - width / 2,
            y: top - height - CGFloat(index) * (height + gap)
        )
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }
}
