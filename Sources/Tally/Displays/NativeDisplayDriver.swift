import AppKit
import CoreGraphics

@MainActor
protocol DisplayDriving {
    func snapshots() throws -> [DisplaySnapshot]
    func commit(uuid: String, mode: DisplayModeSelection) throws
}

@MainActor
struct NativeDisplayDriver: DisplayDriving {
    func snapshots() throws -> [DisplaySnapshot] {
        if DemoMode.isOn { return [] }
        return try NSScreen.screens.map { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
                  let current = CGDisplayCopyDisplayMode(number.uint32Value),
                  let modes = CGDisplayCopyAllDisplayModes(number.uint32Value,
                      [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] else {
                throw DisplayFailure("读取显示器身份或模式失败")
            }
            let id = number.uint32Value
            let values = modes.filter { $0.isUsableForDesktopGUI() }.map(Self.selection)
            var unique: [DisplayModeSelection] = []
            for value in values where !unique.contains(where: { $0.matches(value) }) {
                unique.append(value)
            }
            return DisplaySnapshot(id: CFUUIDCreateString(nil, uuid) as String,
                name: screen.localizedName, vendor: CGDisplayVendorNumber(id),
                product: CGDisplayModelNumber(id), builtin: CGDisplayIsBuiltin(id) != 0,
                mirrored: CGDisplayIsInMirrorSet(id) != 0, current: Self.selection(current),
                modes: unique.sorted { ($0.width, $0.height, $0.pixelWidth, $0.refreshRate) >
                    ($1.width, $1.height, $1.pixelWidth, $1.refreshRate) })
        }
    }

    func commit(uuid: String, mode: DisplayModeSelection) throws {
        guard !DemoMode.isOn else { throw DisplayFailure("演示模式不能切换显示器") }
        guard let screen = try snapshots().first(where: { $0.id == uuid && !$0.builtin && !$0.mirrored }),
              screen.matching(mode) != nil,
              let id = NSScreen.screens.compactMap({ $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber })
                .map(\.uint32Value).first(where: {
                    guard let value = CGDisplayCreateUUIDFromDisplayID($0)?.takeRetainedValue() else { return false }
                    return (CFUUIDCreateString(nil, value) as String) == uuid
                }),
              let modes = CGDisplayCopyAllDisplayModes(id,
                  [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode],
              let native = modes.first(where: { Self.selection($0).matches(mode) }) else {
            throw DisplayFailure("目标显示器或精确模式已不可用")
        }
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else {
            throw DisplayFailure("无法开始显示模式切换")
        }
        let configured = CGConfigureDisplayWithDisplayMode(configuration, id, native, nil)
        guard configured == .success else {
            CGCancelDisplayConfiguration(configuration)
            throw DisplayFailure("系统拒绝显示模式：\(configured.rawValue)")
        }
        let completed = CGCompleteDisplayConfiguration(configuration, .permanently)
        guard completed == .success else { throw DisplayFailure("提交显示配置失败：\(completed.rawValue)") }
    }

    private static func selection(_ mode: CGDisplayMode) -> DisplayModeSelection {
        DisplayModeSelection(width: mode.width, height: mode.height,
            pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
            refreshRate: mode.refreshRate)
    }
}
