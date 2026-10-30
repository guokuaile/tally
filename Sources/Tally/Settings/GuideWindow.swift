import AppKit
import SwiftUI

/// 首次启动弹不弹：启动参数为空（`--open` / `--demo` / `--install-hooks` 都是验证入口）且还没看过。纯函数，有单测。
enum GuidePolicy {
    static func shouldPresent(options: LaunchOptions, prefs: Preferences) -> Bool {
        options == LaunchOptions() && !prefs.guideShown
    }
}

/// 「认识刘海」：全新安装的第一次启动弹一次，设置「通用」里可重开（docs/panel.md「首次启动指引」）。
///
/// 和设置窗口同一套激活策略：打开切常规（按钮才接得到点击），关窗切回附件；
/// 设置窗口还开着就不切回去，否则它失去键盘。关窗丢掉窗口与 SwiftUI 宿主，常驻态不多留东西。
@MainActor
final class GuideWindowController: NSObject, NSWindowDelegate {

    static let shared = GuideWindowController()

    private var window: NSWindow?

    /// 打开前先收面板：面板浮在所有窗口之上，展开着会盖住指引的上半截。
    var willShow: (() -> Void)?

    var isOpen: Bool { window != nil }

    func show() {
        willShow?()
        if window == nil {
            let hosting = NSHostingView(rootView: GuideView(stills: GuideView.stills(), close: { [weak self] in self?.window?.close() }))
            hosting.setFrameSize(hosting.fittingSize)
            let created = NSWindow(
                contentRect: NSRect(origin: .zero, size: hosting.frame.size),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            created.title = "认识刘海"
            created.isReleasedWhenClosed = false
            created.contentView = hosting
            created.delegate = self
            created.center()
            window = created
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
        if SettingsWindowController.shared.window?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// 指引内容：上面一张用面板自己的渲染件拼的图，下面三行解释；点图或点行都选中同一部分。
struct GuideView: View {

    enum Part: CaseIterable, Identifiable {
        case notch, pill, crew

        var id: Self { self }

        var symbol: String {
            switch self {
            case .notch: "rectangle.topthird.inset.filled"
            case .pill: "bell.badge.fill"
            case .crew: "face.smiling"
            }
        }

        var title: String {
            switch self {
            case .notch: "刘海就是 Tally"
            case .pill: "有事才垂一条提示"
            case .crew: "两侧的小人是你的项目"
            }
        }

        @MainActor var detail: String {
            switch self {
            case .notch: "鼠标停上去就展开面板，按 \(HotKeyCenter.label) 也行。展开后左边是 AI、网络、系统、应用、文件架、音乐的页签，右上角齿轮进设置。"
            case .pill: "会话跑完、等你审批或输入、配额过线时从刘海垂下来，几秒后自己收；点它跳回那个终端。"
            case .crew: "一个项目一个，表情就是状态：悬停看会话；单会话点小人跳终端，多会话点小人打开 AI 页。"
            }
        }
    }

    /// 一个 mood 的定格帧。
    struct Still: Identifiable {
        let mood: CrewMood
        let image: CGImage
        var id: CrewMood { mood }
    }

    /// 六个 mood 的定格帧，按当前套系画；`frames.json` 读不到（`swift run`、测试）就是空的，图里不画小人。
    let stills: [Still]
    let close: () -> Void
    @State private var selected: Part = .notch

    @MainActor static func stills() -> [Still] {
        guard let art = BloubArt.bundled else { return [] }
        let cache = CrewFrameCache(art: art)
        let skin: BloubArt.Style.Skin = PreferencesStore.shared.prefs.crewSkin == "gradient" ? .gradient : .glass
        return CrewMood.allCases.compactMap { mood in
            guard let pick = CrewPlayback.pick(mood: mood, elapsed: 0, still: true, art: art),
                  let image = cache.image(CrewFrameCache.Key(clip: pick.clip, index: pick.index, look: CrewFrameCache.Look(mood: mood, skin: skin)), scale: 2)
            else { return nil }
            return Still(mood: mood, image: image)
        }
    }

    /// 编一条跑完的 Claude 会话给提示条用。
    private static let samplePeek = Peek.session(SessionRecord(
        sessionId: "guide", provider: "claude", state: .done, cwd: "/Users/you/code/shop-web", title: "给订单列表加分页",
        transcriptPath: "", message: nil, updatedAt: Date().timeIntervalSince1970 * 1000, model: "claude-opus-5"))

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            illustration
            VStack(spacing: 2) {
                ForEach(Part.allCases) { part in
                    row(part)
                }
            }
            HStack {
                Text("会话靠 hook 上报，还没装的话面板里只有用量。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("去装 hook") {
                    close()
                    SettingsWindowController.shared.show(section: .hooks)
                }
                Button("完成") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    // MARK: 图

    /// 闭合态的刘海、两翼和垂下来的提示条，尺寸照真机：刘海 189 × 32、翅膀每格 27、提示条 320 × 44。
    private var illustration: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                wing(Array(stills.prefix(3)), leading: true)
                partButton(.notch) {
                    NotchShape(top: 0, bottom: NotchGeometry.closedBottomRadius)
                        .fill(.black)
                        .frame(width: 189, height: 32)
                }
                wing(Array(stills.dropFirst(3)), leading: false)
            }
            partButton(.pill) {
                PillNotificationView(peek: Self.samplePeek, isInteractive: false, onTap: {})
                    .frame(width: 320, height: 44)
            }
            .padding(.top, 8)
        }
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.55, green: 0.70, blue: 0.95), Color(red: 0.80, green: 0.70, blue: 0.92)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Rectangle().fill(.bar).frame(height: 32)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// 一侧翅膀：黑底、外侧底角圆角 12，和真的 `CrewPanel` 一个形状。没有帧就不画。
    @ViewBuilder
    private func wing(_ moods: [Still], leading: Bool) -> some View {
        if !moods.isEmpty {
            partButton(.crew) {
                HStack(spacing: 0) {
                    ForEach(moods) { still in
                        Image(decorative: still.image, scale: 2)
                            .frame(width: 27, height: 32)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 32)
                .background(
                    UnevenRoundedRectangle(bottomLeadingRadius: leading ? 12 : 0, bottomTrailingRadius: leading ? 0 : 12)
                        .fill(.black)
                )
            }
        }
    }

    /// 图上的一个部分：点了选中，选中的描一圈强调色。
    private func partButton<Content: View>(_ part: Part, @ViewBuilder content: () -> Content) -> some View {
        Button { selected = part } label: {
            content()
                .overlay {
                    if selected == part {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.accentColor, lineWidth: 2)
                            .padding(-5)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(part.title)
    }

    // MARK: 行

    private func row(_ part: Part) -> some View {
        Button { selected = part } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: part.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(part.title)
                        .font(.headline)
                    Text(part.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if part == .crew, !stills.isEmpty {
                        moodStrip
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected == part ? Color.accentColor.opacity(0.12) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 六种表情铺在黑底上，和真翅膀一个看法。
    private var moodStrip: some View {
        HStack(spacing: 6) {
            ForEach(stills) { still in
                VStack(spacing: 0) {
                    Image(decorative: still.image, scale: 2)
                        .frame(width: 48, height: 32)
                    Text(still.mood.label)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black))
        .padding(.top, 4)
    }
}
