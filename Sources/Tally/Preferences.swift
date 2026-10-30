import Foundation
import Observation

/// Tally 自己的设置，存 JSON。抄 Watchdog 的 Preferences 骨架。
///
/// 解码一律 `decodeIfPresent` 取默认值：以后加字段时，老文件缺键也能读。
struct Preferences: Codable, Equatable {
    /// 登录时自动启动。
    var launchAtLogin = false
    /// 用量页的四个提供方开关。
    var enableClaude = true
    var enableCodex = true
    var enableAntigravity = true
    var enableCursor = true
    /// 国内几家与 New API 中转站：默认关，打开才查（凭据见 `ProviderCredentialsStore`）。
    var enableDeepSeek = false
    var enableKimi = false
    var enableGLM = false
    var enableNewAPI = false
    /// 面板上次点开的页（rawValue），启动时回到它；`--open` 不写它。
    var lastPage = "ai"
    /// ⌥⇧T 全局快捷键。
    var hotKeyEnabled = true
    /// 下面六个是「功能开关」：关掉的功能不起监听、不占内存。
    /// 鼠标停在刘海上展开。
    var hoverToOpen = true
    /// 标题行的「保持唤醒」按钮。
    var keepAwakeButton = true
    /// 保持唤醒时屏幕也常亮（`caffeinate -d`）；关了只挡系统休眠，屏幕照常黑。
    var keepAwakeDisplay = true
    /// 保持唤醒当前开着；断言随进程死，落盘才能跨重装接回来。
    var keepAwakeActive = false
    /// 保持唤醒的到期时刻（Unix 秒），开着且不限时为 nil。
    var keepAwakeUntil: Double?
    /// 保持唤醒选的时长档（分钟），不限时或没开着为 nil；重启后右键菜单靠它把勾接回原来那档。
    var keepAwakeMinutes: Int?
    /// 自定义时长档（分钟），没设过是 nil；范围与步长见 `KeepAwake.clampCustom(_:)`。
    var keepAwakeCustomMinutes: Int?
    /// 接电、拔电、低电、充满时闭合态弹一下。
    var batteryPeek = true
    /// 提示条停留几秒：AI 会话类（等审批比它多留 `Peek.askExtra`）与电池类各一个，2 到 30 秒。
    var peekSessionSeconds = 5
    var peekBatterySeconds = 3
    /// 点会话提示条时做什么，取值见 `PeekTapAction`。默认跳回对应终端：提示条说的就是那个会话，点它就是要过去。
    var peekTapAction = PeekTapAction.terminal.rawValue
    /// 摄像头 / 麦克风被占用时标题行画点。
    var privacyDots = true
    /// 截屏与共享屏幕时隐藏面板。
    var hideFromCapture = false
    /// 「文件架」页：拖文件到刘海暂存。
    var shelfEnabled = true
    /// 文件架保留多久（分钟），到点删架上那份副本：拖进来的文件默认 1 天，自动收进来的截图默认 30 分钟——截图一天几十张，留久了把文件架塞满。
    var shelfFileRetentionMinutes = 1440
    var shelfScreenshotRetentionMinutes = 30
    /// 面板展开时按 1–9 切到第 N 个页签。
    var pageNumberKeys = true
    /// 面板展开时按 ⌘1–⌘9 / ⌘0 跳到 AI 页第 N 个会话的终端。只在面板展开时归面板，收起后浏览器、终端自己的同名键照常。
    var sessionCommandKeys = true
    /// 会话结束后在会话卡片的「已关闭」那一页留一行，点行尾「接着聊」。
    var keepClosedSessions = true
    /// 已关闭的会话最多留几条，多出来的删最旧的。
    var closedSessionLimit = 10
    /// 配额涨过 80%、用完、重置时闭合态弹一下。
    var quotaPeek = true
    /// 会话跑完、在等你时响一声。
    var sessionSound = true
    /// 全屏 app 里不出现刘海面板（提示条也看不到，提示音照响）。
    var hideInFullScreen = false
    /// 菜单栏小恐龙：跟着 CPU 睡觉 / 跑步 / 冲刺，内存吃紧也冲刺、生气，旁边的蛋显示内存。默认关：刘海屏的菜单栏本来就挤。
    var strideEnabled = false
    /// 恐龙旁边显示内存百分比。
    var strideShowsValue = false
    /// 没有刘海屏（合盖接外接屏）时，会话、配额、文件架提示改发系统通知。
    var notifyWithoutNotch = true
    /// 新截图自动放进文件架；文件夹是用户在选择面板里点过的那个（点过才有读它的授权）。
    var screenshotsToShelf = false
    /// 「音乐」页：系统「正在播放」的那首歌和上一曲 / 播放暂停 / 下一曲（docs/music.md）。关掉不起助手进程。
    var musicEnabled = true
    /// 音乐页签常驻；关着时有「正在播放」的会话才出现。
    var musicResident = false
    /// 收进截图时垂提示条。一天截几十张的人嫌吵，关掉照收不弹；拖进来的、open -a 放进来的不归它管。
    var screenshotPeek = true
    var screenshotFolder: String?
    /// 刘海两侧的项目小人（docs/crew.md）：默认开；每侧最多几个（1–4）；套系 `glass` 黑玻璃 / `gradient` 渐变。
    var crewEnabled = true
    var crewPerSide = 3
    var crewSkin = "glass"
    var badgeEnabled = true
    var badgeSeconds = 8
    var badgePosition = "right"
    var badgeTitle = "员工证"
    var badgeThemes: [String] = []
    /// 每天问一次 GitHub 有没有新版本；只提示不替换。
    var checkUpdates = true
    /// 已经提示过的新版本号：同一个版本只在刘海里说一次。
    var updateNotifiedVersion: String?
    /// 首次启动指引看过没有。新建默认假；老文件缺这个键按真解码——有 preferences.json 就说明用过，升级不弹。
    var guideShown = false

    init() {}

    /// 文件架保留时长夹在 1 分钟到 30 天之间：0 等于放进来就删，太长的话副本堆在磁盘上没人管。
    static func retentionMinutes(_ value: Int) -> Int { min(max(value, 1), 30 * 1440) }

    /// 已关闭的会话条数夹在 1 到 50 之间：手改成 0 等于关掉，关掉有单独的开关。
    static func closedLimit(_ value: Int) -> Int { min(max(value, 1), 50) }

    /// 提示条秒数夹在 2 到 30 之间。
    static func peekSeconds(_ value: Int) -> Int { min(max(value, 2), 30) }

    /// 套系只认两个值，别的回落黑玻璃。
    static func crewSkin(_ raw: String) -> String { raw == "gradient" ? raw : "glass" }
    static func badgeSide(_ raw: String) -> String { raw == "left" ? "left" : "right" }

    /// 只认面板页；老文件或手改成别的都回到 ai。
    static func panelPage(_ raw: String) -> String {
        LaunchOptions.Page.panelPages.map(\.rawValue).contains(raw) ? raw : "ai"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        enableClaude = try c.decodeIfPresent(Bool.self, forKey: .enableClaude) ?? d.enableClaude
        enableCodex = try c.decodeIfPresent(Bool.self, forKey: .enableCodex) ?? d.enableCodex
        enableAntigravity = try c.decodeIfPresent(Bool.self, forKey: .enableAntigravity) ?? d.enableAntigravity
        enableCursor = try c.decodeIfPresent(Bool.self, forKey: .enableCursor) ?? d.enableCursor
        enableDeepSeek = try c.decodeIfPresent(Bool.self, forKey: .enableDeepSeek) ?? d.enableDeepSeek
        enableKimi = try c.decodeIfPresent(Bool.self, forKey: .enableKimi) ?? d.enableKimi
        enableGLM = try c.decodeIfPresent(Bool.self, forKey: .enableGLM) ?? d.enableGLM
        enableNewAPI = try c.decodeIfPresent(Bool.self, forKey: .enableNewAPI) ?? d.enableNewAPI
        lastPage = Self.panelPage(try c.decodeIfPresent(String.self, forKey: .lastPage) ?? d.lastPage)
        hotKeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotKeyEnabled) ?? d.hotKeyEnabled
        hoverToOpen = try c.decodeIfPresent(Bool.self, forKey: .hoverToOpen) ?? d.hoverToOpen
        keepAwakeButton = try c.decodeIfPresent(Bool.self, forKey: .keepAwakeButton) ?? d.keepAwakeButton
        keepAwakeDisplay = try c.decodeIfPresent(Bool.self, forKey: .keepAwakeDisplay) ?? d.keepAwakeDisplay
        keepAwakeActive = try c.decodeIfPresent(Bool.self, forKey: .keepAwakeActive) ?? d.keepAwakeActive
        keepAwakeUntil = try c.decodeIfPresent(Double.self, forKey: .keepAwakeUntil)
        keepAwakeMinutes = try c.decodeIfPresent(Int.self, forKey: .keepAwakeMinutes)
        keepAwakeCustomMinutes = try c.decodeIfPresent(Int.self, forKey: .keepAwakeCustomMinutes)
        batteryPeek = try c.decodeIfPresent(Bool.self, forKey: .batteryPeek) ?? d.batteryPeek
        // 手改成离谱的秒数不至于让提示条永远不收 / 一闪而过
        peekSessionSeconds = Self.peekSeconds(try c.decodeIfPresent(Int.self, forKey: .peekSessionSeconds) ?? d.peekSessionSeconds)
        peekBatterySeconds = Self.peekSeconds(try c.decodeIfPresent(Int.self, forKey: .peekBatterySeconds) ?? d.peekBatterySeconds)
        peekTapAction = PeekTapAction.parse(try c.decodeIfPresent(String.self, forKey: .peekTapAction) ?? d.peekTapAction).rawValue
        privacyDots = try c.decodeIfPresent(Bool.self, forKey: .privacyDots) ?? d.privacyDots
        hideFromCapture = try c.decodeIfPresent(Bool.self, forKey: .hideFromCapture) ?? d.hideFromCapture
        shelfEnabled = try c.decodeIfPresent(Bool.self, forKey: .shelfEnabled) ?? d.shelfEnabled
        shelfFileRetentionMinutes = Self.retentionMinutes(try c.decodeIfPresent(Int.self, forKey: .shelfFileRetentionMinutes) ?? d.shelfFileRetentionMinutes)
        shelfScreenshotRetentionMinutes = Self.retentionMinutes(try c.decodeIfPresent(Int.self, forKey: .shelfScreenshotRetentionMinutes) ?? d.shelfScreenshotRetentionMinutes)
        pageNumberKeys = try c.decodeIfPresent(Bool.self, forKey: .pageNumberKeys) ?? d.pageNumberKeys
        sessionCommandKeys = try c.decodeIfPresent(Bool.self, forKey: .sessionCommandKeys) ?? d.sessionCommandKeys
        keepClosedSessions = try c.decodeIfPresent(Bool.self, forKey: .keepClosedSessions) ?? d.keepClosedSessions
        closedSessionLimit = Self.closedLimit(try c.decodeIfPresent(Int.self, forKey: .closedSessionLimit) ?? d.closedSessionLimit)
        quotaPeek = try c.decodeIfPresent(Bool.self, forKey: .quotaPeek) ?? d.quotaPeek
        sessionSound = try c.decodeIfPresent(Bool.self, forKey: .sessionSound) ?? d.sessionSound
        hideInFullScreen = try c.decodeIfPresent(Bool.self, forKey: .hideInFullScreen) ?? d.hideInFullScreen
        strideEnabled = try c.decodeIfPresent(Bool.self, forKey: .strideEnabled) ?? d.strideEnabled
        strideShowsValue = try c.decodeIfPresent(Bool.self, forKey: .strideShowsValue) ?? d.strideShowsValue
        notifyWithoutNotch = try c.decodeIfPresent(Bool.self, forKey: .notifyWithoutNotch) ?? d.notifyWithoutNotch
        screenshotsToShelf = try c.decodeIfPresent(Bool.self, forKey: .screenshotsToShelf) ?? d.screenshotsToShelf
        screenshotPeek = try c.decodeIfPresent(Bool.self, forKey: .screenshotPeek) ?? d.screenshotPeek
        musicEnabled = try c.decodeIfPresent(Bool.self, forKey: .musicEnabled) ?? d.musicEnabled
        musicResident = try c.decodeIfPresent(Bool.self, forKey: .musicResident) ?? d.musicResident
        screenshotFolder = try c.decodeIfPresent(String.self, forKey: .screenshotFolder)
        crewEnabled = try c.decodeIfPresent(Bool.self, forKey: .crewEnabled) ?? d.crewEnabled
        crewPerSide = CrewRoster.perSide(try c.decodeIfPresent(Int.self, forKey: .crewPerSide) ?? d.crewPerSide)
        crewSkin = Self.crewSkin(try c.decodeIfPresent(String.self, forKey: .crewSkin) ?? d.crewSkin)
        badgeEnabled = try c.decodeIfPresent(Bool.self, forKey: .badgeEnabled) ?? d.badgeEnabled
        badgeSeconds = Self.peekSeconds(try c.decodeIfPresent(Int.self, forKey: .badgeSeconds) ?? d.badgeSeconds)
        badgePosition = Self.badgeSide(try c.decodeIfPresent(String.self, forKey: .badgePosition) ?? d.badgePosition)
        badgeTitle = try c.decodeIfPresent(String.self, forKey: .badgeTitle) ?? d.badgeTitle
        let rawThemes = try c.decodeIfPresent([String].self, forKey: .badgeThemes) ?? d.badgeThemes
        badgeThemes = BadgeTheme.allCases.map(\.rawValue).filter { rawThemes.contains($0) }
        checkUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkUpdates) ?? d.checkUpdates
        updateNotifiedVersion = try c.decodeIfPresent(String.self, forKey: .updateNotifiedVersion)
        // 唯一一个缺键不取新建默认的字段：能走到这里就有文件，用过的机器不弹指引
        guideShown = try c.decodeIfPresent(Bool.self, forKey: .guideShown) ?? true
    }
}

/// 设置的唯一持有者。改 `prefs` 就落盘。
@MainActor
@Observable
final class PreferencesStore {

    static let shared = DemoMode.isOn ? PreferencesStore(inMemory: DemoData.preferences) : PreferencesStore()

    /// Tally 的数据目录，会话状态文件也在这下面。
    nonisolated static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Tally")

    var prefs: Preferences {
        didSet {
            save()
            onChange?()
        }
    }

    /// 每次改完设置都调一次，控制器据此起停各功能；幂等，页签切换写 lastPage 也会触发，无妨。
    var onChange: (() -> Void)?

    /// 最近一次落盘失败的原因，设置页红字显示；成功后清空。内存里的值已经改了，重启会回到磁盘上的旧值。
    private(set) var saveError: String?

    /// nil 是只在内存里（演示模式）：不读也不写 preferences.json，录屏时拨的开关不该改掉真设置。
    private let url: URL?

    init(inMemory prefs: Preferences) {
        url = nil
        self.prefs = prefs
    }

    init(url: URL = PreferencesStore.directory.appendingPathComponent("preferences.json")) {
        self.url = url
        prefs = Preferences()
        // 第一次启动没有文件是正常的；有文件读不出来才值得记一笔
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            prefs = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url))
        } catch {
            Log.error("设置读取失败，按默认值: \(url.path) \(error.localizedDescription)")
        }
    }

    private func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(prefs).write(to: url, options: .atomic)
            saveError = nil
        } catch {
            saveError = "设置没能写进 \(url.lastPathComponent)：\(error.localizedDescription)"
            Log.error("设置写入失败: \(error.localizedDescription)")
        }
    }
}
