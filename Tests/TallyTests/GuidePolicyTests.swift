import XCTest
@testable import Tally

final class GuidePolicyTests: XCTestCase {

    func testFreshInstallWithPlainLaunchPresents() {
        XCTAssertTrue(GuidePolicy.shouldPresent(options: LaunchOptions.parse(["Tally"]), prefs: Preferences()))
    }

    func testSeenGuideNeverPresentsAgain() {
        var prefs = Preferences()
        prefs.guideShown = true
        XCTAssertFalse(GuidePolicy.shouldPresent(options: LaunchOptions.parse(["Tally"]), prefs: prefs))
    }

    /// 带参数的启动都是截图验证或装 hook，弹指引会盖住要截的东西。
    func testVerificationLaunchArgumentsSkipTheGuide() {
        for arguments in [["Tally", "--open", "ai"], ["Tally", "--open", "settings"], ["Tally", "--demo"], ["Tally", "--install-hooks"]] {
            XCTAssertFalse(GuidePolicy.shouldPresent(options: LaunchOptions.parse(arguments), prefs: Preferences()), arguments.joined(separator: " "))
        }
    }

    /// 有 preferences.json 就是用过的机器：缺键按看过解码，升级不弹；只有全新安装的默认值才是没看过。
    func testExistingPreferencesFileCountsAsSeen() throws {
        XCTAssertFalse(Preferences().guideShown)
        let upgraded = try JSONDecoder().decode(Preferences.self, from: Data(#"{"launchAtLogin":true}"#.utf8))
        XCTAssertTrue(upgraded.guideShown)
        let explicit = try JSONDecoder().decode(Preferences.self, from: Data(#"{"guideShown":false}"#.utf8))
        XCTAssertFalse(explicit.guideShown)
    }
}
