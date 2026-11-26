import Foundation
import CryptoKit

// Override merge, backup format and atomic root write are adapted from mac-hidpi.
// FineDisplay, Crisp and FreeDisplay attribution and MIT terms are in NOTICE.
struct HiDPISize: Equatable {
    let width: Int
    let height: Int
    init(_ text: String) throws {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }),
              let width = Int(parts[0]), let height = Int(parts[1]),
              (1...8192).contains(width), (1...8192).contains(height) else {
            throw DisplayFailure("尺寸必须是 1 到 8192 的 WIDTHxHEIGHT")
        }
        self.width = width
        self.height = height
    }

    func entry(nativeWidth: Int, nativeHeight: Int) throws -> Data {
        guard width >= 800, height >= 600, width <= nativeWidth, height <= nativeHeight,
              abs(Double(width) / Double(height) / (Double(nativeWidth) / Double(nativeHeight)) - 1) <= 0.005 else {
            throw DisplayFailure("尺寸超出面板范围或与原生比例不符")
        }
        var w = UInt32(width * 2).bigEndian
        var h = UInt32(height * 2).bigEndian
        return withUnsafeBytes(of: &w) { Data($0) } + withUnsafeBytes(of: &h) { Data($0) }
    }
}

protocol DisplayOverrideIO: Sendable {
    func read(_ url: URL) throws -> Data?
    func authorize(_ shell: String) throws
}

struct SystemDisplayOverrideIO: DisplayOverrideIO {
    func read(_ url: URL) throws -> Data? {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw DisplayFailure("拒绝操作软链接")
        }
        var isDirectory: ObjCBool = false
        guard !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) || !isDirectory.boolValue else {
            throw DisplayFailure("配置路径是目录")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if attributes?[.type] as? FileAttributeType == .typeSymbolicLink { throw DisplayFailure("拒绝操作软链接") }
        return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }
    func authorize(_ shell: String) throws {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        let result = try Subprocess.run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", source], deadline: 120)
        guard !result.timedOut, result.status == 0 else {
            throw DisplayFailure("管理员操作未完成：\(String(decoding: result.stderr, as: UTF8.self))")
        }
    }
}

@MainActor
final class HiDPIOverrideService {
    static let shared = HiDPIOverrideService()
    let overrides: URL
    let backups: URL
    let io: any DisplayOverrideIO
    let driver: any DisplayDriving

    init(overrides: URL = URL(fileURLWithPath: "/Library/Displays/Contents/Resources/Overrides"),
         backups: URL = URL(fileURLWithPath: "/Library/Application Support/MacHiDPI"),
         io: any DisplayOverrideIO = SystemDisplayOverrideIO(),
         driver: (any DisplayDriving)? = nil) {
        self.overrides = overrides
        self.backups = backups
        self.io = io
        self.driver = driver ?? NativeDisplayDriver()
    }

    func nativeSize(_ screen: DisplaySnapshot) throws -> (Int, Int) {
        guard let mode = screen.modes.filter({ $0.width == $0.pixelWidth && $0.height == $0.pixelHeight })
            .max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            throw DisplayFailure("未找到可信的原生 1× 模式")
        }
        return (mode.width, mode.height)
    }

    func preview(_ screen: DisplaySnapshot, sizes: [HiDPISize]) throws -> [Data] {
        let native = try nativeSize(screen)
        let entries = try sizes.map { try $0.entry(nativeWidth: native.0, nativeHeight: native.1) }
        guard !entries.isEmpty else { throw DisplayFailure("至少指定一个档位") }
        var unique: [Data] = []
        for entry in entries where !unique.contains(entry) { unique.append(entry) }
        return unique
    }

    func install(_ screen: DisplaySnapshot, sizes: [HiDPISize]) async throws {
        guard !DemoMode.isOn else { throw DisplayFailure("演示模式不能写系统配置") }
        try DisplayOperationGate.shared.enter()
        defer { DisplayOperationGate.shared.leave() }
        let currentScreen = try identifiedScreen(screen)
        let entries = try preview(currentScreen, sizes: sizes)
        let (target, backup) = paths(currentScreen)
        let current = try io.read(target)
        let previous = try io.read(backup)
        var state = try backupState(previous, current: current)
        var plist: [String: Any] = [:]
        if let current {
            guard let decoded = try PropertyListSerialization.propertyList(from: current, format: nil) as? [String: Any] else {
                throw DisplayFailure("现有配置不是字典")
            }
            plist = decoded
        }
        let existing = plist["scale-resolutions"] as? [Data] ?? []
        if plist["scale-resolutions"] != nil && !(plist["scale-resolutions"] is [Data]) {
            throw DisplayFailure("现有 scale-resolutions 格式未知")
        }
        var combined = existing
        for entry in entries where !combined.contains(entry) { combined.append(entry) }
        plist["scale-resolutions"] = combined
        let desired = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        if desired == current { return }
        if let current { state["previousInstalled"] = current }
        state["installed"] = desired
        let encoded = try PropertyListSerialization.data(fromPropertyList: state, format: .xml, options: 0)
        let command = writeScript(target: target, current: current, backup: backup, previous: previous,
                                  desired: desired, state: encoded)
        let authorizer = io
        try await Task.detached(priority: .userInitiated) { try authorizer.authorize(command) }.value
        guard try io.read(target) == desired, try io.read(backup) == encoded else {
            throw DisplayFailure("配置写入后核对失败；备份已保留")
        }
    }

    func restore(_ screen: DisplaySnapshot) async throws {
        guard !DemoMode.isOn else { throw DisplayFailure("演示模式不能写系统配置") }
        try DisplayOperationGate.shared.enter()
        defer { DisplayOperationGate.shared.leave() }
        let currentScreen = try identifiedScreen(screen)
        let (target, backup) = paths(currentScreen)
        let current = try io.read(target)
        guard let previous = try io.read(backup) else { throw DisplayFailure("没有原始配置备份") }
        let state = try backupState(previous, current: current)
        let original = state["originalExists"] as? Bool == true ? state["original"] as? Data : nil
        if current == original { return }
        let command = writeScript(target: target, current: current, backup: backup, previous: previous,
                                  desired: original, state: previous)
        let authorizer = io
        try await Task.detached(priority: .userInitiated) { try authorizer.authorize(command) }.value
        guard try io.read(target) == original else { throw DisplayFailure("原始配置恢复核对失败") }
    }

    private func paths(_ screen: DisplaySnapshot) -> (URL, URL) {
        let key = "\(String(screen.vendor, radix: 16))-\(String(screen.product, radix: 16))"
        return (overrides.appendingPathComponent("DisplayVendorID-\(String(screen.vendor, radix: 16))")
            .appendingPathComponent("DisplayProductID-\(String(screen.product, radix: 16))"),
            backups.appendingPathComponent(key).appendingPathComponent("backup.plist"))
    }

    private func identifiedScreen(_ expected: DisplaySnapshot) throws -> DisplaySnapshot {
        guard let fresh = try driver.snapshots().first(where: { $0.id == expected.id }),
              !fresh.builtin, !fresh.mirrored,
              fresh.vendor == expected.vendor, fresh.product == expected.product,
              fresh.vendor != 0, fresh.product != 0 else {
            throw DisplayFailure("外接显示器身份或镜像状态已改变，请刷新")
        }
        return fresh
    }

    private func backupState(_ raw: Data?, current: Data?) throws -> [String: Any] {
        guard let raw else { return ["version": 1, "originalExists": current != nil, "original": current ?? Data()] }
        guard let state = try PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any],
              state["version"] as? Int == 1, state["originalExists"] is Bool,
              let originalBytes = state["original"] as? Data,
              let installed = state["installed"] as? Data,
              state["previousInstalled"] == nil || state["previousInstalled"] is Data else {
            throw DisplayFailure("备份记录格式无效")
        }
        let original = state["originalExists"] as? Bool == true ? originalBytes : nil
        let predecessor = state["previousInstalled"] as? Data ?? original
        guard current == original || current == installed || current == predecessor else {
            throw DisplayFailure("配置已被其他程序修改，拒绝覆盖或恢复")
        }
        return state
    }

    private func writeScript(target: URL, current: Data?, backup: URL, previous: Data?,
                             desired: Data?, state: Data) -> String {
        var script = ["set -eu"]
        for directory in [target.deletingLastPathComponent(), backup.deletingLastPathComponent()] {
            var ancestor = directory
            while ancestor.path != "/" {
                script.append("test ! -L \(quote(ancestor.path))")
                ancestor.deleteLastPathComponent()
            }
        }
        script += [check(target, expected: current), check(backup, expected: previous)]
        script += ["/bin/mkdir -p \(quote(target.deletingLastPathComponent().path))",
                   "/bin/mkdir -p \(quote(backup.deletingLastPathComponent().path))"]
        func stage(_ path: URL, _ data: Data) {
            script += ["stage=$(/usr/bin/mktemp \(quote(path.deletingLastPathComponent().appendingPathComponent(".tally-hidpi.XXXXXXXX").path)))",
                       "trap '/bin/rm -f \"$stage\"' EXIT",
                       "/usr/bin/printf '%s' \(quote(data.base64EncodedString())) | /usr/bin/base64 -D > \"$stage\"",
                       "/usr/bin/plutil -lint -s \"$stage\"", "/bin/chmod 644 \"$stage\"",
                       "/bin/mv -f \"$stage\" \(quote(path.path))", "trap - EXIT"]
        }
        stage(backup, state)
        // A second root-side check protects the target between backup and override renames.
        script += [check(target, expected: current), check(backup, expected: state)]
        if let desired { stage(target, desired) }
        else if current != nil {
            script += ["archive=$(/usr/bin/mktemp \(quote(backup.deletingLastPathComponent().appendingPathComponent("last-installed.XXXXXXXX").path)))",
                       "/bin/mv -f \(quote(target.path)) \"$archive\""]
        }
        return script.joined(separator: "\n")
    }

    private func check(_ path: URL, expected: Data?) -> String {
        guard let expected else { return "test ! -e \(quote(path.path)) && test ! -L \(quote(path.path))" }
        let digest = SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
        return "test -f \(quote(path.path)) && test ! -L \(quote(path.path)) && test \"$(/usr/bin/shasum -a 256 \(quote(path.path)) | /usr/bin/cut -d ' ' -f 1)\" = \(quote(digest))"
    }

    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
