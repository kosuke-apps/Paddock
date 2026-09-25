import Darwin
import Foundation

// Records every network socket of one process and its descendants, to check that an ollama server talks to
// nothing but 127.0.0.1. It reads the sockets from the kernel (libproc) every --interval-ms milliseconds, writes
// each distinct socket the first time it appears, notes processes as they start and exit, and notes changes to
// the modification time of --watch-file paths. A socket that opens and closes between two samples is missed, so
// the report states the sampling interval and the longest gap between samples actually achieved. Time the Mac
// spends asleep appears as GAP lines. Files given with --watch-file are checked every 5 seconds.
//
// Usage:
//   swiftc -O -o build/netwatch tools/netwatch.swift
//   build/netwatch --pid <pid> --out <new file> [--interval-ms 50] [--duration-s <seconds>] [--watch-file <path>]...
//
// It stops when the process exits or the duration has passed; a record cut short by a signal has no END line.
// Lines marked FLAG are sockets that are not
// loopback-only: a remote or local address other than 127.0.0.0/8 or ::1, or a listener on every address.

struct Options {
    var pid: pid_t = 0
    var out = ""
    var intervalMs = 50
    var duration: TimeInterval = .infinity
    var watchFiles: [String] = []
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    while let flag = arguments.next() {
        guard let value = arguments.next() else { usage() }
        switch flag {
        case "--pid": options.pid = pid_t(value) ?? 0
        case "--out": options.out = value
        case "--interval-ms": options.intervalMs = Int(value) ?? 50
        case "--duration-s": options.duration = TimeInterval(value) ?? .infinity
        case "--watch-file": options.watchFiles.append(value)
        default: usage()
        }
    }
    if options.pid <= 0 || options.out.isEmpty { usage() }
    return options
}

func usage() -> Never {
    FileHandle.standardError.write(
        Data(
            "usage: netwatch --pid <pid> --out <file> [--interval-ms 50] [--duration-s N] [--watch-file <path>]...\n"
                .utf8))
    exit(2)
}

// MARK: - Output

let options = parseOptions()
guard !FileManager.default.fileExists(atPath: options.out) else {
    FileHandle.standardError.write(Data("error: \(options.out) exists; netwatch never overwrites a record\n".utf8))
    exit(1)
}
guard FileManager.default.createFile(atPath: options.out, contents: nil),
    let output = FileHandle(forWritingAtPath: options.out)
else {
    FileHandle.standardError.write(Data("error: cannot create \(options.out)\n".utf8))
    exit(1)
}

let clockFormatter = ISO8601DateFormatter()
clockFormatter.timeZone = .current
clockFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

@MainActor
func record(_ line: String) {
    output.write(Data("\(clockFormatter.string(from: Date())) \(line)\n".utf8))
}

// MARK: - Processes

func lookUpProcessName(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "?" }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func children(of pid: pid_t) -> [pid_t] {
    let estimate = proc_listchildpids(pid, nil, 0)
    guard estimate > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(estimate) + 16)
    let count = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
    return Array(pids.prefix(Int(max(count, 0))))
}

/// Names are looked up once per process; a pid is not reused while its process is in the tree.
nonisolated(unsafe) var processNames: [pid_t: String] = [:]

func processName(_ pid: pid_t) -> String {
    if let name = processNames[pid] { return name }
    let name = lookUpProcessName(pid)
    processNames[pid] = name
    return name
}

/// The process and all its descendants.
func tree(of root: pid_t) -> [pid_t] {
    var result: [pid_t] = []
    var queue = [root]
    while let pid = queue.popLast() {
        result.append(pid)
        queue.append(contentsOf: children(of: pid))
    }
    return result
}

// MARK: - Sockets

func text(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func describe(_ address: in_sockinfo, local: Bool) -> String {
    let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: local ? address.insi_lport : address.insi_fport)))
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    if address.insi_vflag & UInt8(INI_IPV4) != 0 {
        var ipv4 = local ? address.insi_laddr.ina_46.i46a_addr4 : address.insi_faddr.ina_46.i46a_addr4
        inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count))
        return "\(text(buffer)):\(port)"
    }
    var ipv6 = local ? address.insi_laddr.ina_6 : address.insi_faddr.ina_6
    inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(buffer.count))
    return "[\(text(buffer))]:\(port)"
}

func isLoopback(_ endpoint: String) -> Bool {
    endpoint.hasPrefix("127.") || endpoint.hasPrefix("[::1]") || endpoint.hasPrefix("[::ffff:127.")
}

func isUnspecified(_ endpoint: String) -> Bool {
    endpoint.hasPrefix("0.0.0.0:") || endpoint.hasPrefix("[::]:")
}

let tcpStates = [
    "CLOSED", "LISTEN", "SYN_SENT", "SYN_RECEIVED", "ESTABLISHED", "CLOSE_WAIT", "FIN_WAIT_1", "CLOSING",
    "LAST_ACK", "FIN_WAIT_2", "TIME_WAIT",
]

struct Socket: Hashable {
    let process: String
    let pid: pid_t
    let proto: String
    let local: String
    let remote: String
    let state: String

    /// Not loopback-only: something other than 127.0.0.0/8 or ::1 at either end, or a listener on every address.
    var flagged: Bool {
        let remoteOutside = !isUnspecified(remote) && !isLoopback(remote)
        let localOutside = !isUnspecified(local) && !isLoopback(local)
        return remoteOutside || localOutside || isUnspecified(local)
    }
}

func sockets(of pid: pid_t) -> [Socket] {
    let stride = MemoryLayout<proc_fdinfo>.stride
    let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard bytes > 0 else { return [] }
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
    let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
    guard filled > 0 else { return [] }
    let name = processName(pid)
    var result: [Socket] = []
    for descriptor in descriptors.prefix(Int(filled) / stride)
    where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.stride)
        guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
        switch info.psi.soi_kind {
        case Int32(SOCKINFO_TCP):
            let tcp = info.psi.soi_proto.pri_tcp
            let state = Int(tcp.tcpsi_state)
            result.append(
                Socket(
                    process: name, pid: pid, proto: "tcp", local: describe(tcp.tcpsi_ini, local: true),
                    remote: describe(tcp.tcpsi_ini, local: false),
                    state: state < tcpStates.count ? tcpStates[state] : "\(state)"))
        case Int32(SOCKINFO_IN):
            let inet = info.psi.soi_proto.pri_in
            result.append(
                Socket(
                    process: name, pid: pid, proto: info.psi.soi_protocol == IPPROTO_UDP ? "udp" : "ip",
                    local: describe(inet, local: true), remote: describe(inet, local: false), state: "-"))
        default:
            continue  // Unix-domain and other local sockets.
        }
    }
    return result
}

// MARK: - Loop

@MainActor
func modificationTime(_ path: String) -> String {
    guard let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else {
        return "missing"
    }
    return clockFormatter.string(from: date)
}

record(
    "START root=\(options.pid) (\(processName(options.pid))) interval=\(options.intervalMs)ms "
        + "duration=\(options.duration.isFinite ? "\(Int(options.duration))s" : "until exit")")
var seen: [Socket: (first: Date, last: Date, samples: Int)] = [:]
var knownPIDs: Set<pid_t> = []
var fileTimes = Dictionary(uniqueKeysWithValues: options.watchFiles.map { ($0, modificationTime($0)) })
for (path, time) in fileTimes { record("FILE \(path) mtime=\(time)") }

let started = Date()
var samples = 0
var maxGapMs = 0.0
var lastSample = DispatchTime.now()
var lastWall = Date()
var lastFileCheck = Date.distantPast
var lastHeartbeat = Date()
var endReason = "duration reached"

while true {
    if Date().timeIntervalSince(started) >= options.duration { break }
    guard kill(options.pid, 0) == 0 || errno == EPERM else {
        endReason = "root process exited"
        break
    }

    let now = DispatchTime.now()
    let wall = Date()
    if samples > 0 {
        let gapMs = Double(now.uptimeNanoseconds - lastSample.uptimeNanoseconds) / 1_000_000
        maxGapMs = max(maxGapMs, gapMs)
        // The uptime clock stops while the Mac sleeps; the wall clock does not. A long wall-clock gap is sleep:
        // the server was suspended too, but nothing was sampled, so the record says so.
        let wallGap = wall.timeIntervalSince(lastWall)
        if wallGap > 2 { record("GAP \(Int(wallGap)) s without samples (uptime advanced \(Int(gapMs)) ms)") }
    }
    lastWall = wall
    lastSample = now
    samples += 1

    let pids = tree(of: options.pid)
    for pid in pids where !knownPIDs.contains(pid) { record("PROC START pid=\(pid) name=\(processName(pid))") }
    for pid in knownPIDs.subtracting(pids) {
        record("PROC EXIT pid=\(pid)")
        processNames[pid] = nil
    }
    knownPIDs = Set(pids)

    let date = Date()
    for socket in pids.flatMap(sockets(of:)) {
        if let entry = seen[socket] {
            seen[socket] = (entry.first, date, entry.samples + 1)
        } else {
            seen[socket] = (date, date, 1)
            record(
                "\(socket.flagged ? "FLAG" : "SOCKET") \(socket.process)[\(socket.pid)] \(socket.proto) "
                    + "\(socket.local) -> \(socket.remote) \(socket.state)")
        }
    }

    for path in options.watchFiles where date.timeIntervalSince(lastFileCheck) >= 5 {
        let time = modificationTime(path)
        if time != fileTimes[path] {
            record("FILE CHANGED \(path) mtime=\(time)")
            fileTimes[path] = time
        }
    }

    if date.timeIntervalSince(lastFileCheck) >= 5 { lastFileCheck = date }
    if date.timeIntervalSince(lastHeartbeat) >= 600 {
        record(
            "HEARTBEAT samples=\(samples) max_gap_ms=\(Int(maxGapMs)) processes=\(pids.count) "
                + "distinct_sockets=\(seen.count) flagged=\(seen.keys.filter(\.flagged).count)")
        lastHeartbeat = date
    }
    usleep(useconds_t(options.intervalMs * 1000))
}

let flagged = seen.keys.filter(\.flagged)
record(
    "END reason=\"\(endReason)\" elapsed_s=\(Int(Date().timeIntervalSince(started))) samples=\(samples) "
        + "max_gap_ms=\(Int(maxGapMs)) distinct_sockets=\(seen.count) flagged=\(flagged.count)")
for (socket, entry) in seen.sorted(by: { $0.value.first < $1.value.first }) {
    record(
        "SUMMARY \(socket.flagged ? "FLAG" : "ok  ") \(socket.process)[\(socket.pid)] \(socket.proto) "
            + "\(socket.local) -> \(socket.remote) \(socket.state) first=\(clockFormatter.string(from: entry.first)) "
            + "last=\(clockFormatter.string(from: entry.last)) samples=\(entry.samples)")
}
try? output.close()
