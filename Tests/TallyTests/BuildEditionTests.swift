import XCTest
@testable import Tally

final class BuildEditionTests: XCTestCase {
    @MainActor func testAccountSettingsNavigationMatchesBuildEdition() {
        let sections = SettingsSection.groups.flatMap(\.sections)
        XCTAssertTrue(sections.contains(.ai))
        let accountSection = SettingsSection(rawValue: "claudeAccounts")
        XCTAssertNil(accountSection)
        XCTAssertFalse(sections.contains { $0.rawValue == "claudeAccounts" })
    }
}
