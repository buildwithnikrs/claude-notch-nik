import Foundation
import Darwin

/// Minimal process-table helpers (no shelling out).
public enum ProcessTree {
    public static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    public static func name(of pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// nil when we can't tell; EPERM still means the process exists.
    public static func isAlive(_ pid: pid_t) -> Bool? {
        guard pid > 0 else { return nil }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM ? true : false
    }

    /// The Claude Code process that ran this hook: our parent, skipping a wrapping shell.
    public static func claudeProcess(from hookPid: pid_t = getpid()) -> pid_t? {
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env"]
        var pid = parent(of: hookPid)
        var hops = 0
        while let p = pid, hops < 3, let n = name(of: p), shells.contains(n) {
            pid = parent(of: p)
            hops += 1
        }
        return pid
    }

    /// Ancestors of a pid, nearest first (bounded).
    public static func ancestors(of pid: pid_t, limit: Int = 12) -> [pid_t] {
        var out: [pid_t] = []
        var cur = parent(of: pid)
        while let p = cur, p > 1, out.count < limit {
            out.append(p)
            cur = parent(of: p)
        }
        return out
    }
}
