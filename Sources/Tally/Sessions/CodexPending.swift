import Foundation
import Darwin
import TallyKit

struct CodexPendingProcess: Equatable {
    let pid: Int32
    let started: UInt64
    let tty: String
    let cwd: String

    var id: String { "pending-codex-\(pid)-\(started)" }

    func record() -> SessionRecord {
        var result = SessionRecord(sessionId: id, provider: "codex", pid: Int(pid), tty: tty,
                                   state: .running, cwd: cwd, title: "Codex 终端",
                                   transcriptPath: "", message: nil, updatedAt: Double(started / 1000))
        result.isProvisional = true
        result.provisionalStart = started
        return result
    }
}

enum CodexPending {
    static func scan() -> [CodexPendingProcess]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 32
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let table = SysctlProcessTable()
        var result: [CodexPendingProcess] = []
        for var item in buffer.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            let name = withUnsafePointer(to: &item.kp_proc.p_comm) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) } }
            guard name == "codex", item.kp_eproc.e_tdev != -1, item.kp_eproc.e_ucred.cr_uid == getuid() else { continue }
            let pid = item.kp_proc.p_pid
            let args = table.arguments(of: pid)
            guard !args.isEmpty else { continue }
            let excluded = ["exec", "app-server", "login", "logout", "mcp", "plugin", "doctor", "features", "completion", "help", "update"]
            if args.dropFirst().contains(where: { excluded.contains($0) }) { continue }
            guard let tty = AgentLocator.ttyName(item.kp_eproc.e_tdev),
                  let cwd = SysctlProcessTable.workingDirectory(of: pid) else { continue }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { continue }
            let started = UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
            result.append(CodexPendingProcess(pid: pid, started: started, tty: tty, cwd: cwd))
        }
        return result.sorted { $0.id < $1.id }
    }

    static func matches(_ pending: CodexPendingProcess, _ record: SessionRecord) -> Bool {
        record.provider == "codex" && record.state != .ended && record.pid == Int(pending.pid) && record.tty == pending.tty
            && record.updatedAt >= Double(pending.started) / 1000
    }

    static func confirmedGone(_ record: SessionRecord) -> Bool {
        guard let pid = record.pid, let originalStart = record.provisionalStart else { return false }
        var info = proc_bsdinfo()
        if proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size {
            let started = UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
            return started != originalStart
        }
        return kill(Int32(pid), 0) == -1 && errno == ESRCH
    }

    static func confirmedAlive(_ process: CodexPendingProcess) -> Bool {
        var info = proc_bsdinfo()
        guard proc_pidinfo(process.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return false }
        return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec) == process.started
    }
}
