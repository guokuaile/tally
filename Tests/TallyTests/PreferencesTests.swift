import XCTest
@testable import Tally

final class PreferencesTests: XCTestCase {

    func testOldFileWithoutProviderKeysDecodesToDefaults() throws {
        let old = Data(#"{"launchAtLogin":true}"#.utf8)
        let prefs = try JSONDecoder().decode(Preferences.self, from: old)
        XCTAssertTrue(prefs.launchAtLogin)
        XCTAssertTrue(prefs.enableClaude)
        XCTAssertTrue(prefs.enableCodex)
        XCTAssertTrue(prefs.enableAntigravity)
        XCTAssertTrue(prefs.enableCursor)
    }

    @MainActor
    func testStoreRoundTrips() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-prefs-\(UUID().uuidString)")
            .appendingPathComponent("preferences.json")
        let store = PreferencesStore(url: url)
        store.prefs.enableCursor = false
        store.prefs.launchAtLogin = true
        let reloaded = PreferencesStore(url: url)
        XCTAssertFalse(reloaded.prefs.enableCursor)
        XCTAssertTrue(reloaded.prefs.launchAtLogin)
        XCTAssertTrue(reloaded.prefs.enableClaude)
    }

    func testOldFileWithoutPageKeysDecodesToDefaults() throws {
        let old = Data(#"{"launchAtLogin":true}"#.utf8)
        let prefs = try JSONDecoder().decode(Preferences.self, from: old)
        XCTAssertEqual(prefs.lastPage, "ai")
        XCTAssertTrue(prefs.hotKeyEnabled)
    }

    func testOldFileWithoutFeatureKeysDecodesToDefaults() throws {
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(#"{"launchAtLogin":true}"#.utf8))
        XCTAssertTrue(prefs.hoverToOpen)
        XCTAssertTrue(prefs.keepAwakeButton)
        XCTAssertTrue(prefs.keepAwakeDisplay, "默认连屏幕一起保持，和 caffeinate -dims 的习惯一致")
        XCTAssertTrue(prefs.batteryPeek)
        XCTAssertTrue(prefs.privacyDots)
        XCTAssertFalse(prefs.hideFromCapture, "截屏隐藏默认关：截图验证流程要能拍到面板")
        XCTAssertNil(prefs.keepAwakeCustomMinutes, "自定义时长没设过就是没有这一档")
        XCTAssertEqual(prefs.peekSessionSeconds, 5)
        XCTAssertEqual(prefs.peekBatterySeconds, 3)
        XCTAssertEqual(prefs.peekTapAction, "terminal", "默认跳回对应终端")
        XCTAssertTrue(prefs.pageNumberKeys, "数字键切页签默认开")
        XCTAssertTrue(prefs.sessionCommandKeys, "⌘1–⌘5 跳会话默认开：只在面板展开时归面板")
        XCTAssertTrue(prefs.keepClosedSessions, "已关闭的会话默认留着接着聊")
        XCTAssertEqual(prefs.closedSessionLimit, 10, "已关闭默认留 10 条")
        let limits = try JSONDecoder().decode(Preferences.self, from: Data(#"{"closedSessionLimit":0}"#.utf8))
        XCTAssertEqual(limits.closedSessionLimit, 1, "手改成 0 夹回 1，关掉有单独的开关")
        XCTAssertEqual(Preferences.closedLimit(999), 50)
        XCTAssertEqual(prefs.shelfFileRetentionMinutes, 1440, "拖进来的文件默认留 1 天")
        XCTAssertEqual(prefs.shelfScreenshotRetentionMinutes, 30, "截图默认留 30 分钟")
        XCTAssertFalse(prefs.strideEnabled, "菜单栏小恐龙默认关：刘海屏的菜单栏本来就挤")
        XCTAssertFalse(prefs.strideShowsValue, "默认不显示内存百分比，只看恐龙和蛋")
        let retired = try JSONDecoder().decode(Preferences.self, from: Data(#"{"strideMetric":"cpu","strideEnabled":true}"#.utf8))
        XCTAssertTrue(retired.strideEnabled, "旧版「看 CPU / 内存」的键留在文件里也照常读")
        XCTAssertEqual(Preferences.retentionMinutes(0), 1)
        XCTAssertEqual(Preferences.retentionMinutes(99_999_999), 30 * 1440, "最长 30 天")
        XCTAssertTrue(prefs.quotaPeek, "配额提醒默认开")
        XCTAssertTrue(prefs.sessionSound, "提示音默认开")
        XCTAssertFalse(prefs.hideInFullScreen, "全屏隐藏默认关：升级后行为不变")
        XCTAssertTrue(prefs.notifyWithoutNotch, "没有刘海屏时改发通知默认开：合盖接外接屏的人不然只剩一声响")
        XCTAssertFalse(prefs.screenshotsToShelf, "截图进文件架默认关：要用户点选文件夹才有授权")
        XCTAssertNil(prefs.screenshotFolder)
        XCTAssertTrue(prefs.screenshotPeek, "收进截图时提示默认开：升级后行为不变")
        XCTAssertTrue(prefs.musicEnabled, "音乐页默认开")
        XCTAssertFalse(prefs.musicResident, "页签默认不常驻：有东西在播才出现")
        let music = try JSONDecoder().decode(Preferences.self, from: Data(#"{"musicEnabled":false,"musicResident":true,"lastPage":"music"}"#.utf8))
        XCTAssertFalse(music.musicEnabled)
        XCTAssertTrue(music.musicResident)
        XCTAssertEqual(music.lastPage, "music", "音乐是面板页，记得住")
        let quiet = try JSONDecoder().decode(Preferences.self, from: Data(#"{"screenshotPeek":false}"#.utf8))
        XCTAssertFalse(quiet.screenshotPeek, "关掉能落盘读回来")
        // 手改成离谱的秒数要夹回来，不然提示条要么永不收要么一闪而过
        let wild = try JSONDecoder().decode(Preferences.self, from: Data(#"{"peekSessionSeconds":999,"peekBatterySeconds":0,"peekTapAction":"乱写的"}"#.utf8))
        XCTAssertEqual(wild.peekSessionSeconds, 30)
        XCTAssertEqual(wild.peekBatterySeconds, 2)
        XCTAssertEqual(wild.peekTapAction, "terminal", "认不出的回落到默认")
        let off = try JSONDecoder().decode(Preferences.self, from: Data(#"{"privacyDots":false,"hideFromCapture":true}"#.utf8))
        XCTAssertFalse(off.privacyDots)
        XCTAssertTrue(off.hideFromCapture)
    }

    func testLastPageOnlyAcceptsPanelPages() throws {
        let system = try JSONDecoder().decode(Preferences.self, from: Data(#"{"lastPage":"system"}"#.utf8))
        XCTAssertEqual(system.lastPage, "system")
        let settings = try JSONDecoder().decode(Preferences.self, from: Data(#"{"lastPage":"settings"}"#.utf8))
        XCTAssertEqual(settings.lastPage, "ai")
        let bogus = try JSONDecoder().decode(Preferences.self, from: Data(#"{"lastPage":"bogus","hotKeyEnabled":false}"#.utf8))
        XCTAssertEqual(bogus.lastPage, "ai")
        XCTAssertFalse(bogus.hotKeyEnabled)
        let removed = try JSONDecoder().decode(Preferences.self, from: Data(#"{"lastPage":"tasks"}"#.utf8))
        XCTAssertEqual(removed.lastPage, "ai", "任务页删掉后存过它的文件回落 ai")
        XCTAssertEqual(LaunchOptions.Page.panelPages, [.ai, .network, .system, .apps, .shelf, .music])
        XCTAssertEqual(LaunchOptions.Page.visible(shelf: false, music: false), [.ai, .network, .system, .apps])
        XCTAssertEqual(LaunchOptions.Page.visible(shelf: true, music: true), LaunchOptions.Page.panelPages)
        XCTAssertEqual(LaunchOptions.Page.visible(shelf: false, music: true).last, .music, "音乐排最后：它出现、消失不挪别的页签")
    }

    func testCrewKeysDefaultOnThreePerSideGlass() throws {
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(#"{"launchAtLogin":true}"#.utf8))
        XCTAssertTrue(prefs.crewEnabled, "刘海小人默认开")
        XCTAssertEqual(prefs.crewPerSide, 3)
        XCTAssertEqual(prefs.crewSkin, "glass")
        XCTAssertTrue(prefs.badgeEnabled)
        XCTAssertEqual(prefs.badgeSeconds, 8)
        XCTAssertEqual(prefs.badgePosition, "right")
        XCTAssertEqual(prefs.badgeTitle, "员工证")
        let custom = try JSONDecoder().decode(Preferences.self, from: Data(#"{"badgeEnabled":false,"badgeSeconds":99,"badgePosition":"bad","badgeTitle":"研发组"}"#.utf8))
        XCTAssertFalse(custom.badgeEnabled)
        XCTAssertEqual(custom.badgeSeconds, 30)
        XCTAssertEqual(custom.badgePosition, "right")
        XCTAssertEqual(custom.badgeTitle, "研发组")
    }

    func testBadgeThemesOldDefaultsNormalizationAndRoundTrip() throws {
        let old = try JSONDecoder().decode(Preferences.self, from: Data(#"{}"#.utf8))
        XCTAssertEqual(old.badgeThemes, [])
        let selected = try JSONDecoder().decode(Preferences.self, from: Data(#"{"badgeThemes":["design","writing","design","unknown"]}"#.utf8))
        XCTAssertEqual(selected.badgeThemes, ["writing", "design"])
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(selected))
        XCTAssertEqual(decoded.badgeThemes, ["writing", "design"])
    }

    func testCrewPerSideIsClampedOneToFour() throws {
        let zero = try JSONDecoder().decode(Preferences.self, from: Data(#"{"crewPerSide":0}"#.utf8))
        XCTAssertEqual(zero.crewPerSide, 1, "0 等于关掉，关掉有单独的开关")
        let many = try JSONDecoder().decode(Preferences.self, from: Data(#"{"crewPerSide":9}"#.utf8))
        XCTAssertEqual(many.crewPerSide, 4, "再多就压到菜单栏项目了")
        let two = try JSONDecoder().decode(Preferences.self, from: Data(#"{"crewPerSide":2}"#.utf8))
        XCTAssertEqual(two.crewPerSide, 2)
    }

    func testCrewSkinFallsBackToGlass() throws {
        let bogus = try JSONDecoder().decode(Preferences.self, from: Data(#"{"crewSkin":"neon"}"#.utf8))
        XCTAssertEqual(bogus.crewSkin, "glass")
        let gradient = try JSONDecoder().decode(Preferences.self, from: Data(#"{"crewSkin":"gradient","crewEnabled":false}"#.utf8))
        XCTAssertEqual(gradient.crewSkin, "gradient")
        XCTAssertFalse(gradient.crewEnabled)
        XCTAssertEqual(Preferences.crewSkin("GLASS"), "glass", "大小写也不认，只认两个字面值")
    }

    @MainActor
    func testCrewKeysRoundTripThroughTheStore() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-prefs-crew-\(UUID().uuidString)")
            .appendingPathComponent("preferences.json")
        let store = PreferencesStore(url: url)
        store.prefs.crewEnabled = false
        store.prefs.crewPerSide = 2
        store.prefs.crewSkin = "gradient"
        store.prefs.badgeThemes = ["writing", "data"]
        let reloaded = PreferencesStore(url: url)
        XCTAssertFalse(reloaded.prefs.crewEnabled)
        XCTAssertEqual(reloaded.prefs.crewPerSide, 2)
        XCTAssertEqual(reloaded.prefs.crewSkin, "gradient")
        XCTAssertEqual(reloaded.prefs.badgeThemes, ["writing", "data"])
    }

    func testEnabledKeyPathsWrite() {
        var prefs = Preferences()
        prefs[keyPath: ProviderID.antigravity.enabledKey] = false
        XCTAssertFalse(prefs.enableAntigravity)
        XCTAssertTrue(prefs[keyPath: ProviderID.claude.enabledKey])
    }
}
