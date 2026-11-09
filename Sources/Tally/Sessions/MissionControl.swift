import AppKit
import CoreGraphics

@MainActor
final class MissionControl {
    static let shared = MissionControl()

    private let inspect: () -> Bool?
    private let launch: () async -> Bool
    private let pause: () async -> Bool
    private var pending: Task<Bool, Never>?

    init(inspect: @escaping () -> Bool? = MissionControl.currentVisibility,
         launch: @escaping () async -> Bool = MissionControl.openLauncher,
         pause: @escaping () async -> Bool = MissionControl.waitForAnimation) {
        self.inspect = inspect
        self.launch = launch
        self.pause = pause
    }

    static func isVisible(windows: [FullScreenDetector.Window], display: CGRect, dockPID: pid_t, managerPID: pid_t) -> Bool {
        // shortcut: These layers are observed on macOS 27.2. Recheck them when a supported system uses different overview windows.
        return windows.contains { covers($0, display: display, pid: dockPID, layer: 20) }
            && windows.contains { covers($0, display: display, pid: managerPID, layer: 19) }
    }

    private static func covers(_ window: FullScreenDetector.Window, display: CGRect, pid: pid_t, layer: Int) -> Bool {
        window.pid == pid && window.layer == layer
            && abs(window.bounds.minX - display.minX) <= 2 && abs(window.bounds.minY - display.minY) <= 2
            && abs(window.bounds.width - display.width) <= 2 && abs(window.bounds.height - display.height) <= 2
    }

    func dismissIfVisible() async -> Bool {
        if let pending { return await pending.value }
        guard let visible = inspect() else { return false }
        guard visible else { return true }
        let task = Task { @MainActor in
            guard let visible = inspect() else { return false }
            guard visible else { return true }
            guard await launch() else { return false }
            for _ in 0..<20 {
                if inspect() == false { return true }
                guard await pause() else { return false }
            }
            return inspect() == false
        }
        pending = task
        defer { pending = nil }
        return await task.value
    }

    private static func currentVisibility() -> Bool? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let windows = list.compactMap { info -> FullScreenDetector.Window? in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let raw = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return nil }
            return FullScreenDetector.Window(pid: pid, layer: layer, bounds: bounds)
        }
        let displays = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(id.uint32Value)
        }
        guard !displays.isEmpty else { return nil }
        guard displays.contains(where: { display in windows.contains { covers($0, display: display, pid: dock.processIdentifier, layer: 20) } }) else { return false }
        guard let manager = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first else { return nil }
        return displays.contains { isVisible(windows: windows, display: $0, dockPID: dock.processIdentifier, managerPID: manager.processIdentifier) } ? true : nil
    }

    private static func openLauncher() async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.exposelauncher") else { return false }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return true
        } catch {
            Log.error("Failed to dismiss Mission Control: \(error)")
            return false
        }
    }

    private static func waitForAnimation() async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(50))
            return true
        } catch {
            return false
        }
    }
}
