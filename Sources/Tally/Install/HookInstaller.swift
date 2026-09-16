import CryptoKit
import Foundation

/// 两侧 hook 的注册器：改 `~/.claude/settings.json` 与 `~/.codex/hooks.json`，给 Codex 写信任哈希，报状态。
///
/// 只在用户点「安装」时动这些文件；每次改前留 `<原名>.tally-backup`。
enum HookSide: CaseIterable {
    case claude, codex

    var title: String {
        switch self {
        case .claude: return "Claude Code hook"
        case .codex: return "Codex hook"
        }
    }

    /// 写进状态文件和心跳文件名里的提供方。
    var provider: String {
        self == .codex ? "codex" : "claude"
    }

    var events: [String] {
        switch self {
        case .claude: return ["SessionStart", "UserPromptSubmit", "Notification", "PostToolUse", "PreCompact", "Stop", "SessionEnd"]
        case .codex: return ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "SessionEnd"]
        }
    }
}

enum HookStatus: Equatable {
    /// 每个事件下都恰好有一个 Tally 匹配组且命令等于期望值。
    case installed
    /// 至少一个事件下有 Tally 匹配组，但不满足 installed；关联值是人话说明。
    case pointsElsewhere(String)
    /// 哪个事件下都没有 Tally 匹配组。
    case missing
}

enum HookInstallError: LocalizedError, Equatable {
    case invalidJSON(String)
    /// app 不在固定位置（磁盘映像里、或被 Gatekeeper 搬到 AppTranslocation 的临时副本）。
    case unstableLocation(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let path): return "\(path) 不是合法的 JSON 对象，没有改动它"
        case .unstableLocation:
            return "先把 Tally 拖进「应用程序」再装 hook：现在跑的这份是系统给的临时副本（从磁盘映像或下载目录直接打开会这样），它的路径重启就没了，写进配置的 hook 会失效"
        }
    }
}

/// app 现在跑在哪儿——装 hook 前要判一下：hook 路径会被写进 `~/.claude/settings.json` 与 `~/.codex/hooks.json`，
/// 写进去一个临时路径，重启后两边的 agent 都会去调一个不存在的文件。
enum BundleLocation {
    /// Gatekeeper 的路径随机化：从 DMG 或下载目录直接打开时，app 被搬到
    /// `/private/var/folders/…/AppTranslocation/<UUID>/d/Tally.app` 跑，重启即失效。
    static func isUnstable(_ path: String) -> Bool {
        path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/")
    }
}

struct HookInstaller {

    let claudeSettings: URL
    let codexHooks: URL
    let codexConfig: URL
    /// tally-hook 可执行文件的绝对路径。
    let hookBinary: String

    /// 真实路径。
    static func live() -> HookInstaller {
        let binary = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("tally-hook").path
            ?? "/Applications/Tally.app/Contents/MacOS/tally-hook"
        return HookInstaller(
            claudeSettings: ClaudeHome.url.appendingPathComponent("settings.json"),
            codexHooks: CodexHome.url.appendingPathComponent("hooks.json"),
            codexConfig: CodexHome.url.appendingPathComponent("config.toml"),
            hookBinary: binary
        )
    }

    /// 写进配置的超时秒数；Codex 的信任哈希也要用它算。
    static let timeout = 5

    // MARK: 期望值

    /// 路径带双引号，防以后 app 被放到带空格的目录。
    func expectedCommand(_ side: HookSide) -> String {
        let quoted = "\"\(hookBinary)\""
        return side == .codex ? quoted + " --provider codex" : quoted
    }

    private func file(for side: HookSide) -> URL {
        side == .claude ? claudeSettings : codexHooks
    }

    /// 「Tally 匹配组」= 只含一个 hook 且该 hook 的 command 含 claude-event.js 或 tally-hook 的匹配组。
    static func isTallyGroup(_ group: [String: Any]) -> Bool {
        guard let hooks = group["hooks"] as? [[String: Any]], hooks.count == 1,
              let command = hooks[0]["command"] as? String else { return false }
        return command.contains("claude-event.js") || command.contains("tally-hook")
    }

    private func expectedGroup(_ side: HookSide) -> [String: Any] {
        ["hooks": [["type": "command", "command": expectedCommand(side), "timeout": Self.timeout]]]
    }

    // MARK: 状态

    func status(_ side: HookSide) -> HookStatus {
        guard let root = try? Self.load(file(for: side)) else { return .missing }
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        let expected = expectedCommand(side)
        var anyTally = false
        var missingEvents: [String] = []
        var elsewhere: String?
        for event in side.events {
            let groups = hooks[event] as? [[String: Any]] ?? []
            let tally = groups.filter(Self.isTallyGroup)
            if tally.isEmpty {
                missingEvents.append(event)
                continue
            }
            anyTally = true
            let commands = tally.compactMap { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String }
            if tally.count != 1 || commands.first != expected {
                elsewhere = commands.first(where: { $0 != expected }) ?? "重复注册"
            }
        }
        if !anyTally { return .missing }
        if missingEvents.isEmpty, elsewhere == nil { return .installed }
        var reasons: [String] = []
        if !missingEvents.isEmpty { reasons.append("\(missingEvents.joined(separator: "、")) 未注册") }
        if let elsewhere { reasons.append("命令指向 \(elsewhere)") }
        return .pointsElsewhere(reasons.joined(separator: "；"))
    }

    // MARK: 安装

    /// 幂等。旧 Tally 匹配组原位替换（多个时第一个原位、其余删掉），没有就追加到事件数组末尾。
    func install(_ side: HookSide) throws {
        // 临时副本的路径写进配置就是坏的，宁可不写
        guard !BundleLocation.isUnstable(hookBinary) else { throw HookInstallError.unstableLocation(hookBinary) }
        let url = file(for: side)
        var root = try Self.load(url)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in side.events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            var replaced = false
            groups = groups.compactMap { group in
                guard Self.isTallyGroup(group) else { return group }
                if replaced { return nil }
                replaced = true
                return expectedGroup(side)
            }
            if !replaced { groups.append(expectedGroup(side)) }
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try Self.backup(url)
        try Self.save(root, to: url)
        if side == .codex {
            do {
                try trustCodexEntries(hooks)
            } catch {
                // 哈希写不进去就等于没装：留一半会让状态页说「已安装」而 Codex 不跑它
                try Self.restore(url)
                throw error
            }
        }
    }

    // MARK: 移除

    /// 把各事件下的 Tally 匹配组删掉，别的 hook 不动；事件数组空了就连键一起删。
    /// Codex 侧删掉后别的 hook 序号前移，信任状态要跟着挪（`shiftCodexTrust`）。
    func uninstall(_ side: HookSide) throws {
        let url = file(for: side)
        var root = try Self.load(url)
        let before = root["hooks"] as? [String: Any] ?? [:]
        var hooks = before
        for event in side.events {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            groups.removeAll(where: Self.isTallyGroup)
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try Self.backup(url)
        try Self.save(root, to: url)
        if side == .codex {
            do {
                try shiftCodexTrust(before)
            } catch {
                try Self.restore(url)
                throw error
            }
        }
    }

    /// 信任状态按序号记，删掉 Tally 组后同一事件里后面的 hook 序号前移：先删 Tally 组自己的块，
    /// 再从小到大把后面的块改名到新序号。哈希不含序号，挪过去照样对得上；没信任过的本来就没有块，挪完也没有。
    /// Tally 的块不删的话，后面的 hook 挪到这个序号上会和它重名，`config.toml` 出现两个同名表，Codex 整份读不进去。
    private func shiftCodexTrust(_ before: [String: Any]) throws {
        guard FileManager.default.fileExists(atPath: codexConfig.path) else { return }
        let original = try String(contentsOf: codexConfig, encoding: .utf8)
        var text = original
        for event in HookSide.codex.events {
            var removed = 0
            for (index, group) in (before[event] as? [[String: Any]] ?? []).enumerated() {
                if Self.isTallyGroup(group) {
                    text = Self.removeTrust(in: text, key: CodexTrust.key(hooksFile: codexHooks.path, event: event, group: index))
                    removed += 1
                    continue
                }
                guard removed > 0 else { continue }
                for handler in 0..<((group["hooks"] as? [Any])?.count ?? 0) {
                    text = Self.renameTrust(in: text,
                                            from: CodexTrust.key(hooksFile: codexHooks.path, event: event, group: index, handler: handler),
                                            to: CodexTrust.key(hooksFile: codexHooks.path, event: event, group: index - removed, handler: handler))
                }
            }
        }
        guard text != original else { return }
        try Self.backup(codexConfig)
        try text.write(to: codexConfig, atomically: true, encoding: .utf8)
    }

    /// 每个事件下 Tally 组的信任哈希：同键已存在就就地改写 trusted_hash，没有才追加整块。
    private func trustCodexEntries(_ hooks: [String: Any]) throws {
        // 文件在但读不出来（比如夹着非 UTF-8 字节）要报错：当成空文件的话，写回去只剩 Tally 这几块，用户别的配置全没了
        var text = FileManager.default.fileExists(atPath: codexConfig.path) ? try String(contentsOf: codexConfig, encoding: .utf8) : ""
        for event in HookSide.codex.events {
            guard let index = (hooks[event] as? [[String: Any]])?.firstIndex(where: Self.isTallyGroup) else { continue }
            let hash = try CodexTrust.hash(event: event, command: expectedCommand(.codex), timeout: Self.timeout)
            text = Self.patchTrust(in: text, key: CodexTrust.key(hooksFile: codexHooks.path, event: event, group: index), hash: hash)
        }
        try Self.backup(codexConfig)
        try text.write(to: codexConfig, atomically: true, encoding: .utf8)
    }

    private static func trustHeader(_ key: String) -> String {
        "[hooks.state.\"\(key)\"]"
    }

    private static func trustHeaderIndex(_ lines: [String], _ key: String) -> Int? {
        lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == trustHeader(key) }
    }

    /// 删掉整块：表头到下一个表头之前。
    static func removeTrust(in text: String, key: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let start = trustHeaderIndex(lines, key) else { return text }
        var end = start + 1
        while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
        lines.removeSubrange(start..<end)
        return lines.joined(separator: "\n")
    }

    /// 只改表头，块里的 trusted_hash、enabled 原样跟着走。
    static func renameTrust(in text: String, from old: String, to new: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let index = trustHeaderIndex(lines, old) else { return text }
        lines[index] = trustHeader(new)
        return lines.joined(separator: "\n")
    }

    static func patchTrust(in text: String, key: String, hash: String) -> String {
        let header = trustHeader(key)
        var lines = text.components(separatedBy: "\n")
        if let index = trustHeaderIndex(lines, key) {
            var cursor = index + 1
            while cursor < lines.count {
                let line = lines[cursor].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { break }
                if line.hasPrefix("trusted_hash") {
                    lines[cursor] = "trusted_hash = \"\(hash)\""
                    return lines.joined(separator: "\n")
                }
                cursor += 1
            }
            lines.insert("trusted_hash = \"\(hash)\"", at: index + 1)
            return lines.joined(separator: "\n")
        }
        var result = text
        if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        result += "\n\(header)\ntrusted_hash = \"\(hash)\"\n"
        return result
    }

    // MARK: 文件

    /// 不存在或 0 字节按 `{}`；存在但不是 JSON 对象就抛错，不覆盖。
    static func load(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        if data.isEmpty || String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [:]
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInstallError.invalidJSON(url.path)
        }
        return object
    }

    static func save(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    static func backupURL(_ url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension(url.pathExtension + ".tally-backup")
    }

    static func backup(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let backup = backupURL(url)
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: url, to: backup)
    }

    /// 后半步失败时把刚改的文件退回备份；原来没有文件就删掉新写的。
    static func restore(_ url: URL) throws {
        let backup = backupURL(url)
        if FileManager.default.fileExists(atPath: backup.path) {
            try Data(contentsOf: backup).write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: 手工步骤

    static func manualSteps(_ side: HookSide, hookBinary: String) -> String {
        let command = side == .codex ? "\"\(hookBinary)\" --provider codex" : "\"\(hookBinary)\""
        let file = side == .claude ? ClaudeHome.url.appendingPathComponent("settings.json").path : CodexHome.url.appendingPathComponent("hooks.json").path
        var text = "在 \(file) 的 hooks 下，给 \(side.events.joined(separator: "、")) 各加一条：\n"
        text += "{ \"hooks\": [ { \"type\": \"command\", \"command\": \"\(command.replacingOccurrences(of: "\"", with: "\\\""))\", \"timeout\": \(timeout) } ] }\n"
        if side == .codex {
            text += "然后在 \(CodexHome.url.appendingPathComponent("config.toml").path) 里给每条写信任哈希，<序号> 是这条在该事件数组里的位置（从 0 数）：\n"
            for event in side.events {
                let hash = (try? CodexTrust.hash(event: event, command: command, timeout: timeout)) ?? "<哈希>"
                text += "[hooks.state.\"\(file):\(CodexTrust.label(event)):<序号>:0\"]\ntrusted_hash = \"\(hash)\"\n"
            }
        }
        return text
    }
}

/// Codex 给每条 hook 记的信任键与哈希，照 Codex 源码自己算，不跑 `codex app-server`（docs/hooks.md「安装」）：
/// 有人把 codex 包进隐私检查脚本，`app-server` 子命令直接被拒。
enum CodexTrust {

    /// `config.toml` 里 `[hooks.state."<键>"]` 的键。
    static func key(hooksFile: String, event: String, group: Int, handler: Int = 0) -> String {
        "\(hooksFile):\(label(event)):\(group):\(handler)"
    }

    /// `UserPromptSubmit` → `user_prompt_submit`。
    static func label(_ event: String) -> String {
        event.reduce(into: "") { result, character in
            if character.isUppercase, !result.isEmpty { result += "_" }
            result += character.lowercased()
        }
    }

    /// `sha256:` 加按键排序的紧凑 JSON 的 sha256。只算 Tally 这种 hook：没有 matcher 和 statusMessage（空值不进 JSON）、不异步。
    /// 超时按 Codex 归一化之后的值算：SessionEnd 被压到 1–3 秒。哈希不含 hooks.json 路径与序号。
    static func hash(event: String, command: String, timeout: Int) throws -> String {
        let seconds = event == "SessionEnd" ? min(max(timeout, 1), 3) : max(timeout, 1)
        let identity: [String: Any] = [
            "event_name": label(event),
            "hooks": [["type": "command", "command": command, "timeout": seconds, "async": false]],
        ]
        let data = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys, .withoutEscapingSlashes])
        return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
