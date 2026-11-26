// swift-tools-version: 6.0
import Foundation
import PackageDescription

let localAccounts = ProcessInfo.processInfo.environment["TALLY_BUILD_EDITION"] == "local"
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let files = FileManager.default
let privateSources = ["Accounts", "Settings/ClaudeAccountsSettings.swift", "Usage/Providers/ClaudeQuotaReadOnly.swift"]
let testRoot = root.appendingPathComponent("Tests/TallyTests")
let privateTests = try files.contentsOfDirectory(atPath: testRoot.path).filter {
    $0.hasPrefix("ClaudeAccount") || $0 == "ClaudeReauthorizationTests.swift" || $0 == "ClaudeQuotaReadOnlyTests.swift"
}
let sources = root.appendingPathComponent("Sources/Tally")
if localAccounts && !files.fileExists(atPath: sources.appendingPathComponent("Accounts").path) {
    fatalError("Local account sources are unavailable in the public distribution.")
}
let appSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)] + (localAccounts ? [.define("TALLY_LOCAL_ACCOUNTS")] : [])

let package = Package(
    name: "Tally",
    // 15 是为了 @Observable + Scene.defaultLaunchBehavior 这一代 API，
    // 也和 Watchdog 保持同一基线。
    platforms: [.macOS(.v15)],
    // 零第三方依赖：壳、hook、定位全靠系统框架。
    targets: [
        // app 与 hook 共用的模型和判定
        .target(
            name: "TallyKit",
            path: "Sources/TallyKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "TallyWallpaperKit",
            path: "Sources/TallyWallpaperKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Tally",
            dependencies: ["TallyKit", "TallyWallpaperKit"],
            path: "Sources/Tally",
            exclude: localAccounts ? [] : privateSources.filter { files.fileExists(atPath: sources.appendingPathComponent($0).path) },
            swiftSettings: appSettings
        ),
        // 装进 Tally.app/Contents/MacOS/tally-hook，由 Claude Code / Codex 的 hook 调用
        .executableTarget(
            name: "TallyHook",
            dependencies: ["TallyKit"],
            path: "Sources/TallyHook",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TallyWallpaper",
            dependencies: ["TallyWallpaperKit"],
            path: "Sources/TallyWallpaper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TallyTests",
            dependencies: ["Tally", "TallyKit", "TallyWallpaperKit"],
            path: "Tests/TallyTests",
            exclude: localAccounts ? [] : privateTests,
            swiftSettings: appSettings
        ),
        .testTarget(
            name: "TallyWallpaperKitTests",
            dependencies: ["TallyWallpaperKit"],
            path: "Tests/TallyWallpaperKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
