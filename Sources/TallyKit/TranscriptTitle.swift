import Foundation

/// 从 Claude Code 的 transcript（JSONL）找会话标题。hook 和 app 共用同一份规则。
///
/// 三个来源，按可靠程度排：
/// 1. `/rename` 留下的边车 `<transcript 目录>/<session_id>/custom-title.json`
/// 2. 文件末尾 64 KB 里最后一条 `ai-title` 或 `custom-title` 记录
/// 3. 整个文件扫一遍（只有 app 会做，且每个会话只做一次）
public enum TranscriptTitle {

    public static let tailBytes = 64 * 1024

    /// 边车优先，其次文件尾。
    public static func read(from url: URL, sessionId: String?) -> String? {
        if let sessionId, let sidecar = sidecarTitle(transcript: url, sessionId: sessionId) {
            return sidecar
        }
        return readTail(from: url)
    }

    public static func sidecarTitle(transcript: URL, sessionId: String) -> String? {
        let file = transcript.deletingLastPathComponent()
            .appendingPathComponent(sessionId)
            .appendingPathComponent("custom-title.json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = (object["customTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }
        return title
    }

    public static func readTail(from url: URL) -> String? {
        guard let tail = tail(of: url) else { return nil }
        return parse(tail.text, truncated: tail.truncated)
    }

    /// 文件尾 64 KB 里最后一条带模型名的记录：Claude 回复的 `message.model`（跳过它自己报错时写的 `<synthetic>`），
    /// Codex 的 `turn_context.payload.model`。Codex 一轮很长时尾巴里没有 `turn_context`，它得靠 hook 入参的 `model`。
    public static func latestModel(in url: URL) -> String? {
        guard let tail = tail(of: url) else { return nil }
        var lines = tail.text.split(separator: "\n", omittingEmptySubsequences: false)
        if tail.truncated, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() where line.contains("\"model\"") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let model = (object["message"] as? [String: Any])?["model"] as? String, !model.isEmpty, model != "<synthetic>" {
                return model
            }
            if object["type"] as? String == "turn_context",
               let model = (object["payload"] as? [String: Any])?["model"] as? String, !model.isEmpty {
                return model
            }
        }
        return nil
    }

    /// 仅认末尾主链尚未回答的问题；后面有新的 user 记录就不展示旧问题。
    public static func pendingQuestion(in url: URL) -> String? {
        guard let tail = tail(of: url) else { return nil }
        var lines = tail.text.split(separator: "\n", omittingEmptySubsequences: false)
        if tail.truncated, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
                  let type = object["type"] as? String, type == "user" || type == "assistant"
            else { continue }
            guard type == "assistant",
                  let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]]
            else { return nil }
            for block in content.reversed() where block["type"] as? String == "tool_use" && block["name"] as? String == "AskUserQuestion" {
                guard let input = block["input"] as? [String: Any],
                      let questions = input["questions"] as? [[String: Any]],
                      let question = questions.first?["question"] as? String,
                      !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return HookDecision.clip("问题：" + question.replacingOccurrences(of: "\n", with: " "))
            }
            return nil
        }
        return nil
    }

    /// 回合是怎么结束的。打断和 API 报错都不发 Stop，只能看 transcript，规则见 docs/ai.md「打断与 API 报错」。
    public enum TurnEnd: Equatable {
        case interrupted
        /// 关联值是界面上那句报错，如「You've hit your session limit · resets 3pm」。
        case apiError(String?)
    }

    public static func turnEnd(in url: URL, provider: String = "claude") -> TurnEnd? {
        guard let tail = tail(of: url) else { return nil }
        return provider == "codex"
            ? parseCodexTurnEnd(tail.text, truncated: tail.truncated)
            : parseTurnEnd(tail.text, truncated: tail.truncated)
    }

    /// Codex 的 rollout：Stop 只在回合成功时发，打断和出错都不发。从后往前找最后一条回合生命周期事件
    /// （`event_msg` 的 `task_started` / `task_complete` / `turn_aborted`）：`turn_aborted` 是打断；`task_complete` 带 `error` 是报错
    /// （0.128 及以前先单独写一条 `error` 事件、`task_complete` 的 error 为 null，这一回合里有它也算）；
    /// `task_started`、正常完成（交给 Stop）、最后一条是 `error` 还没完成（可能在重试）都按没结束。
    public static func parseCodexTurnEnd(_ text: String, truncated: Bool) -> TurnEnd? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if truncated, !lines.isEmpty { lines.removeFirst() }
        var completedWithoutError = false
        for line in lines.reversed() where line.contains("\"event_msg\"") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any]
            else { continue }
            let kind = payload["type"] as? String
            if completedWithoutError {
                // 往回找这一回合里有没有老版本单独写的 error 事件，碰到回合开头或上一回合就停
                if kind == "error" { return .apiError(payload["message"] as? String) }
                if kind == "task_started" || kind == "task_complete" || kind == "turn_aborted" { return nil }
                continue
            }
            switch kind {
            case "turn_aborted":
                return .interrupted
            case "task_started", "error":
                return nil
            case "task_complete":
                if let error = payload["error"] as? [String: Any] { return .apiError(error["message"] as? String) }
                completedWithoutError = true
            default:
                continue
            }
        }
        return nil
    }

    /// 从后往前找第一条主链对话记录：子 agent 的（`isSidechain`）和 Claude Code 注入的提示（`isMeta`）不算，
    /// 回合结束后追加的快照、模式、system 记录也不算。它是打断标记或 API 报错才算结束；尾巴里没有对话记录按没结束算。
    public static func parseTurnEnd(_ text: String, truncated: Bool) -> TurnEnd? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if truncated, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() where line.contains("\"user\"") || line.contains("\"assistant\"") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String, type == "user" || type == "assistant",
                  object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true
            else { continue }
            let content = (object["message"] as? [String: Any])?["content"]
            let texts = (content as? String).map { [$0] }
                ?? (content as? [[String: Any]])?.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                ?? []
            if type == "user" {
                return texts.contains { $0.hasPrefix("[Request interrupted by user") } ? .interrupted : nil
            }
            return object["isApiErrorMessage"] as? Bool == true ? .apiError(texts.first) : nil
        }
        return nil
    }

    /// 是不是在终端里开的交互会话：只有这种结束后才留一行「已关闭」给人接着聊。认的是反面，确认是脚本跑的才算不是：
    /// Claude 的 transcript 尾巴里只有 `"entrypoint":"sdk-cli"`（`claude -p` 和 SDK），Codex 的 rollout 第一行 `session_meta`
    /// 的 `source` 是 `"exec"`（`codex exec`）或一个对象（子 agent）。文件在但判不出来按是算：多留一行最多占个位置（已关闭的条数有上限），
    /// 误删了就再也接不回去。文件不存在按不是算：没有 transcript 就没有能接着聊的东西。
    public static func isInteractive(transcript url: URL, provider: String) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if provider == "codex" {
            return !(head(of: url).map(isScriptedCodexHead) ?? false)
        }
        guard let tail = tail(of: url) else { return true }
        return tail.text.contains("\"entrypoint\":\"cli\"") || !tail.text.contains("\"entrypoint\":\"sdk-cli\"")
    }

    /// rollout 第一行带着整段系统提示（实测两万字节上下），`source` 在前几百字节；只找子串不整行解析，第一行被 64 KB 截断也认得出。
    public static func isScriptedCodexHead(_ head: String) -> Bool {
        let firstLine = head.prefix { $0 != "\n" }
        return firstLine.contains("\"type\":\"session_meta\"")
            && (firstLine.contains("\"source\":\"exec\"") || firstLine.contains("\"source\":{"))
    }

    /// rollout 第一行 `session_meta` 里的 `originator`：终端是 `codex-tui`、`codex_exec`，ChatGPT 桌面版是 `Codex Desktop`。
    /// 找 codex 的家时靠它排除桌面版那个（`CodexHome`）；同 `isScriptedCodexHead` 只找子串。它在前几百字节（前面只有 id、时间、cwd），
    /// 只读 4 KB：找家时要翻几百个文件。读不到或不是 rollout 为 nil。
    public static func codexOriginator(rollout url: URL) -> String? {
        guard let head = head(of: url, bytes: 4096) else { return nil }
        let firstLine = head.prefix { $0 != "\n" }
        guard firstLine.contains("\"type\":\"session_meta\""),
              let start = firstLine.range(of: "\"originator\":\"")?.upperBound,
              let end = firstLine[start...].firstIndex(of: "\"")
        else { return nil }
        return String(firstLine[start..<end])
    }

    /// 没有标题时顶上的「第一句话」：用户在会话里敲的第一条提示。Codex 从不设标题，Claude 的 ai-title 要等第一回合结束才写，
    /// 这之前列表里只剩目录名，同一目录下的几个会话分不清。读文件头 1 MB：Claude 的第一条 user 记录在 10 KB 上下，
    /// Codex 的 rollout 前面排着系统提示、工具表、AGENTS.md、world_state，用户那句在 180 KB 上下（本机实测）。
    public static let headBytes = 1024 * 1024
    /// 第一句话最多留这么多字：行里只显示得下一行，弹出的提示也只要个由头。
    public static let promptCharacters = 80

    public static func firstPrompt(in url: URL, provider: String) -> String? {
        guard let head = head(of: url, bytes: headBytes) else { return nil }
        return parseFirstPrompt(head, provider: provider)
    }

    /// Claude：第一条主链、非 isMeta、非压缩摘要（`isCompactSummary`，续接时那段「This session is continued…」）的 user 记录里的文字；斜杠命令存成 `<command-message>` / `<command-name>` / `<command-args>` 三段，
    /// 取成「/名字 参数」。Codex：第一条 role 为 user 的 message（`response_item`；老版本另有 `event_msg` 的 `user_message`，新版没有，不认它）。
    /// 两家都跳过以 `<` 起头的：Codex 把 `<environment_context>`、`<user_instructions>` 这类也记成 user 消息（`# AGENTS.md instructions` 同理），
    /// Claude 的 `<local-command-stdout>` 没标 isMeta。用户自己以 `<` 开头的提示会被一起跳过，退回目录名。
    /// 最后一行可能被 1 MB 切断，解析失败就跳过。
    public static func parseFirstPrompt(_ text: String, provider: String) -> String? {
        let codex = provider == "codex"
        let marker = codex ? "\"role\":\"user\"" : "\"type\":\"user\""
        for line in text.split(separator: "\n") where line.contains(marker) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let raw: String
            if codex {
                guard object["type"] as? String == "response_item",
                      let payload = object["payload"] as? [String: Any],
                      payload["type"] as? String == "message", payload["role"] as? String == "user"
                else { continue }
                raw = joinedText(payload["content"])
            } else {
                guard object["type"] as? String == "user",
                      object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
                      object["isCompactSummary"] as? Bool != true
                else { continue }
                raw = joinedText((object["message"] as? [String: Any])?["content"])
            }
            if let command = slashCommand(raw) { return clipPrompt(command) }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("# AGENTS.md") else { continue }
            return clipPrompt(trimmed)
        }
        return nil
    }

    /// 字符串原样；内容块数组取每块的 `text`（Claude 的 `text`、Codex 的 `input_text`），`tool_result` 没有这个键，自然落空。
    private static func joinedText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        return ((content as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: " ")
    }

    private static func slashCommand(_ text: String) -> String? {
        guard let name = tagged(text, "command-name") else { return nil }
        guard let args = tagged(text, "command-args") else { return name }
        return "\(name) \(args)"
    }

    private static func tagged(_ text: String, _ tag: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text[open.upperBound...].range(of: "</\(tag)>")
        else { return nil }
        let value = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// 空白（含换行）折成一个空格，再截到 `promptCharacters` 个字。
    private static func clipPrompt(_ text: String) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(promptCharacters))
    }

    /// 文件头 `bytes` 字节。
    private static func head(of url: URL, bytes: Int = tailBytes) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 文件尾 `tailBytes` 字节；`truncated` 为真时第一行是被截断的半行。
    private static func tail(of url: URL) -> (text: String, truncated: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let length = min(Int(size), tailBytes)
        guard length > 0 else { return nil }
        do {
            try handle.seek(toOffset: size - UInt64(length))
            guard let data = try handle.read(upToCount: length) else { return nil }
            return (String(decoding: data, as: UTF8.self), Int(size) > tailBytes)
        } catch {
            return nil
        }
    }

    /// 整个文件扫一遍。大 transcript 有几 MB，调用方要缓存结果。
    public static func readFull(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(String(decoding: data, as: UTF8.self), truncated: false)
    }

    public static func parse(_ text: String, truncated: Bool) -> String? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if truncated, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() where line.contains("\"ai-title\"") || line.contains("\"custom-title\"") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String
            else { continue }
            let raw: String?
            switch type {
            case "ai-title": raw = object["aiTitle"] as? String
            case "custom-title": raw = object["customTitle"] as? String
            default: raw = nil
            }
            guard let title = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { continue }
            return title
        }
        return nil
    }
}
