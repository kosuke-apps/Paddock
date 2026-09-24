import Darwin
import Foundation

/// When a process started, as the kernel records it. Together with the pid it identifies one process: pids are
/// reused, start times are not.
struct ProcessStartTime: Codable, Equatable, Sendable {
    var seconds: UInt64
    var microseconds: UInt64

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(microseconds) / 1_000_000)
    }
}

struct ProcessDetails: Equatable, Sendable {
    let pid: pid_t
    let name: String
    let startTime: ProcessStartTime
}

/// Reads process information from the kernel (libproc). Only processes of the same user can be inspected; the
/// others are skipped.
enum ProcessInspector {
    static func details(of pid: pid_t) -> ProcessDetails? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessDetails(
            pid: pid,
            name: name(of: pid) ?? "",
            startTime: ProcessStartTime(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec))
    }

    /// True while the process exists, including processes of other users.
    static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// The process that holds a listening TCP socket on `port`, or nil when none of this user's processes does.
    /// Runs only when the port's owner has changed, never on a timer: it walks every process's descriptors.
    static func pidListening(onPort port: UInt16) -> pid_t? {
        let pids = allPIDs()
        // ollama is nearly always the one listening, so its processes are checked first.
        let likely = pids.filter { name(of: $0) == "ollama" }
        return (likely + pids).first { $0 > 0 && hasListeningSocket(pid: $0, port: port) }
    }

    static func childPIDs(of pid: pid_t) -> [pid_t] {
        let estimate = proc_listchildpids(pid, nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 16)
        let count = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        return Array(pids.prefix(Int(max(count, 0))))
    }

    private static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        return Array(pids.prefix(Int(max(count, 0))))
    }

    private static func hasListeningSocket(pid: pid_t, port: UInt16) -> Bool {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return false }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard filled > 0 else { return false }

        for descriptor in descriptors.prefix(Int(filled) / stride)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.stride)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                info.psi.soi_kind == Int32(SOCKINFO_TCP)
            else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            // The local port is kept in network byte order in the low 16 bits.
            let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            if tcp.tcpsi_state == TSI_S_LISTEN && localPort == port { return true }
        }
        return false
    }
}
