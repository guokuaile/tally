import os

/// 统一日志出口。看日志：`/usr/bin/log stream --predicate 'subsystem == "com.aiden.tally"' --level debug`（zsh 里 `log` 是内建命令，不带路径会静默空输出）
enum Log {
    private static let logger = Logger(subsystem: "com.aiden.tally", category: "app")

    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
