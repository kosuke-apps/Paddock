import Darwin
import Foundation

// Tests for Paddock's core: environment, logs, port and process inspection, and the server controller driven
// against a fake `ollama` (tests/support/fake-ollama.swift). Usage: paddock-tests <path to fake ollama>

guard CommandLine.arguments.count == 2 else {
    print("usage: paddock-tests <fake ollama>")
    exit(2)
}
let fakeOllama = CommandLine.arguments[1]
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("paddock-tests-\(getpid())")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

var failures = 0
var current = ""
/// Defaults suites the tests created, removed again at the end.
var suites: Set<String> = []

@MainActor
func check(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    if !condition {
        failures += 1
        print("  FAIL \(current) (line \(line)): \(message())")
    }
}

@MainActor
func test(_ name: String, _ body: () throws -> Void) {
    current = name
    let before = failures
    do { try body() } catch {
        failures += 1
        print("  FAIL \(name): threw \(error)")
    }
    print("\(failures == before ? "ok  " : "FAIL") \(name)")
}

/// Runs the main run loop until `condition` holds, so dispatch sources and process handlers can fire.
@MainActor
func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return true
}

@MainActor
func makeController(
    port: UInt16, name: String, binary: String = fakeOllama, environment: [String: String] = [:],
    defaults: UserDefaults? = nil, adjust: (inout ServerController.Configuration) -> Void = { _ in }
) -> ServerController {
    let suite = "paddock.tests.\(name)"
    suites.insert(suite)
    let store = defaults ?? UserDefaults(suiteName: suite)!
    if defaults == nil { store.removePersistentDomain(forName: suite) }
    var base = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
    base.merge(environment) { $1 }
    var configuration = ServerController.Configuration(
        binaryCandidates: [binary], port: port,
        logStore: LogStore(directory: scratch.appendingPathComponent(name), generations: 5),
        defaults: store, baseEnvironment: base)
    configuration.idleProbeInterval = 0.2
    configuration.stopTimeout = 2
    adjust(&configuration)
    return ServerController(configuration: configuration)
}

/// A listening socket held by this test process, standing in for a server that is not ollama.
final class Listener {
    let fd: Int32

    init?(port: UInt16) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            Darwin.close(fd)
            return nil
        }
    }

    func close() { Darwin.close(fd) }
}

func contents(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

// MARK: - Environment

test("environment drops inherited OLLAMA_ variables and sets Paddock's") {
    let base = ["HOME": "/Users/x", "OLLAMA_HOST": "0.0.0.0:11434", "OLLAMA_ORIGINS": "*", "PATH": "/bin"]
    let environment = ServerEnvironment.make(base: base, host: "127.0.0.1", port: 11434, keepAlive: .thirtyMinutes)
    check(environment["OLLAMA_HOST"] == "127.0.0.1:11434", "host \(environment["OLLAMA_HOST"] ?? "nil")")
    check(environment["OLLAMA_NO_CLOUD"] == "1", "no cloud")
    check(environment["OLLAMA_KEEP_ALIVE"] == "30m", "keep alive")
    check(environment["OLLAMA_ORIGINS"] == nil, "origins kept")
    check(environment["HOME"] == "/Users/x" && environment["PATH"] == "/bin", "other variables lost")
    check(
        ServerEnvironment.summary(of: environment)
            == "OLLAMA_HOST=127.0.0.1:11434 OLLAMA_KEEP_ALIVE=30m OLLAMA_NO_CLOUD=1",
        ServerEnvironment.summary(of: environment))
    check(KeepAlive.standard.rawValue == "5m", "standard keep alive")
}

// MARK: - Logs

test("log store keeps the newest generations whole") {
    let store = LogStore(directory: scratch.appendingPathComponent("rotation"), generations: 3)
    var created: [URL] = []
    for index in 0..<5 {
        let url = try store.createLogFile(now: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)))
        LogStore.append("line \(index)", to: url)
        created.append(url)
        usleep(20_000)  // distinct creation times
    }
    let files = store.logFiles()
    check(files.count == 3, "count \(files.count)")
    check(files.map(\.lastPathComponent) == created.suffix(3).reversed().map(\.lastPathComponent), "\(files)")
    check(contents(files[0]) == "line 4\n", "newest file content")

    // Two starts within one second get distinct names.
    let same = Date(timeIntervalSince1970: 1_900_000_000)
    let first = try store.createLogFile(now: same)
    let second = try store.createLogFile(now: same)
    check(first != second, "same name twice")
    check(
        store.latest()?.lastPathComponent == second.lastPathComponent,
        "latest is \(store.latest()?.lastPathComponent ?? "nil")")

    // The current file survives pruning even when it is the oldest.
    guard let oldest = store.logFiles().last else { return check(false, "no files") }
    store.prune(keeping: oldest)
    check(FileManager.default.fileExists(atPath: oldest.path), "current file deleted")
    check(store.logFiles().count == 3, "count after pruning \(store.logFiles().count)")
}

test("tail returns whole last lines") {
    let url = scratch.appendingPathComponent("tail.log")
    let text = (1...1000).map { "line \($0)" }.joined(separator: "\n") + "\n"
    try text.write(to: url, atomically: true, encoding: .utf8)
    check(LogStore.tail(of: url, maxLines: 3) == "line 998\nline 999\nline 1000", "last three")
    let cut = LogStore.tail(of: url, maxLines: 1000, maxBytes: 20) ?? ""
    check(cut == "line 999\nline 1000", "cut read drops the partial line: \(cut.debugDescription)")
    check(LogStore.tail(of: scratch.appendingPathComponent("missing.log"), maxLines: 3) == nil, "missing file")
}

// MARK: - Port and process inspection

test("port probe and listener lookup find this process") {
    let port: UInt16 = 11490
    check(!PortProbe.isListening(port: port), "port \(port) is busy before the test")
    guard let listener = Listener(port: port) else { return check(false, "could not listen on \(port)") }
    check(PortProbe.isListening(port: port), "not listening")
    check(ProcessInspector.pidListening(onPort: port) == getpid(), "listener pid")
    listener.close()
    check(!PortProbe.isListening(port: port), "still listening after close")
    check(ProcessInspector.pidListening(onPort: port) == nil, "listener after close")

    let me = ProcessInspector.details(of: getpid())
    check(me?.name == "paddock-tests", "name \(me?.name ?? "nil")")
    check(abs((me?.startTime.date ?? .distantPast).timeIntervalSinceNow) < 600, "start time")
    check(ProcessInspector.details(of: 999_999) == nil, "details of a missing pid")
}

// MARK: - Server controller

test("start, run, and stop a server") {
    let port: UInt16 = 11491
    let controller = makeController(
        port: port, name: "startstop", environment: ["OLLAMA_ORIGINS": "*", "OLLAMA_HOST": "0.0.0.0:1"])
    check(controller.status == .stopped, "initial \(controller.status)")
    check(controller.binary?.path == fakeOllama, "binary")
    check(controller.address == "http://127.0.0.1:\(port)", controller.address)

    controller.start(keepAlive: .oneMinute)
    guard case .starting(let server) = controller.status else { return check(false, "\(controller.status)") }
    check(waitUntil { controller.status == .running(server) }, "never running: \(controller.status)")
    check(ProcessInspector.pidListening(onPort: port) == server.pid, "listener is not the server")

    let log = contents(server.logURL)
    check(log.contains("OLLAMA_NO_CLOUD=1"), "no cloud missing in log:\n\(log)")
    check(log.contains("OLLAMA_HOST=127.0.0.1:\(port)"), "host missing in log")
    check(log.contains("OLLAMA_KEEP_ALIVE=1m"), "keep alive missing in log")
    check(!log.contains("OLLAMA_ORIGINS"), "inherited variable reached the server")
    check(log.contains("Listening on 127.0.0.1:\(port)"), "server output not in log")

    var stopped = false
    controller.stop { stopped = true }
    check(controller.status == .stopping(server), "\(controller.status)")
    check(waitUntil { stopped }, "stop completion never ran")
    check(controller.status == .stopped, "\(controller.status)")
    check(controller.notice == nil, "notice \(String(describing: controller.notice))")
    check(!ProcessInspector.isRunning(server.pid), "server still running")
    check(!PortProbe.isListening(port: port), "port still open")
    check(
        contents(server.logURL).contains("ollama serve (pid \(server.pid)) was ended by signal 15")
            || contents(server.logURL).contains("ollama serve (pid \(server.pid)) exited"), "footer missing")
}

test("a server that exits while starting leaves a notice") {
    let controller = makeController(port: 11492, name: "exits", environment: ["FAKE_OLLAMA_EXIT": "3"])
    controller.start(keepAlive: .standard)
    check(waitUntil { controller.status == .stopped }, "\(controller.status)")
    check(controller.notice == .exitedWhileStarting, "notice \(String(describing: controller.notice))")
    let log = controller.configuration.logStore.latest().map(contents) ?? ""
    check(log.contains("exited with status 3"), "footer:\n\(log)")
}

test("a server that never listens is stopped after the start timeout") {
    let controller = makeController(
        port: 11493, name: "timeout", environment: ["FAKE_OLLAMA_LISTEN_DELAY": "30"],
        adjust: { $0.startTimeout = 0.6 })
    controller.start(keepAlive: .standard)
    check(waitUntil { controller.status == .stopped }, "\(controller.status)")
    check(controller.notice == .startTimedOut(seconds: 0), "notice \(String(describing: controller.notice))")
}

test("a server that ignores SIGTERM is killed after the stop timeout") {
    let controller = makeController(
        port: 11494, name: "kill", environment: ["FAKE_OLLAMA_IGNORE_TERM": "1"], adjust: { $0.stopTimeout = 0.5 })
    controller.start(keepAlive: .standard)
    guard waitUntil({ if case .running = controller.status { true } else { false } }),
        let server = controller.ownedServer
    else { return check(false, "never running: \(controller.status)") }
    controller.stop()
    check(waitUntil { controller.status == .stopped }, "\(controller.status)")
    check(!ProcessInspector.isRunning(server.pid), "still running")
    check(contents(server.logURL).contains("sending SIGKILL"), "escalation not logged")
}

test("an ollama started elsewhere is external, watched, and stoppable") {
    let port: UInt16 = 11495
    let controller = makeController(port: port, name: "external")
    let outside = Process()
    outside.executableURL = URL(fileURLWithPath: fakeOllama)
    outside.environment = ["OLLAMA_HOST": "127.0.0.1:\(port)"]
    outside.standardOutput = FileHandle.nullDevice
    try outside.run()
    defer { if outside.isRunning { outside.terminate() } }

    check(waitUntil { if case .external = controller.status { true } else { false } }, "\(controller.status)")
    guard case .external(let server) = controller.status else { return }
    check(server.pid == outside.processIdentifier, "pid \(String(describing: server.pid))")
    check(server.isOllama, "not recognised as ollama: \(server.processName ?? "nil")")
    check(server.startedAt != nil, "start time")

    // Starting is refused while the port is taken.
    controller.start(keepAlive: .standard)
    check(controller.status == .external(server), "\(controller.status)")

    controller.stop()
    check(waitUntil { controller.status == .stopped }, "\(controller.status)")
    check(!outside.isRunning || waitUntil { !outside.isRunning }, "outside server still running")
}

test("an external server that exits by itself is noticed without probing") {
    let port: UInt16 = 11496
    let controller = makeController(port: port, name: "external-exit") { $0.idleProbeInterval = 0.2 }
    let outside = Process()
    outside.executableURL = URL(fileURLWithPath: fakeOllama)
    outside.environment = ["OLLAMA_HOST": "127.0.0.1:\(port)"]
    outside.standardOutput = FileHandle.nullDevice
    try outside.run()
    check(waitUntil { if case .external = controller.status { true } else { false } }, "\(controller.status)")
    outside.terminate()
    check(waitUntil(timeout: 2) { controller.status == .stopped }, "\(controller.status)")
}

test("a listener that is not ollama is reported and never stopped") {
    let port: UInt16 = 11497
    guard let listener = Listener(port: port) else { return check(false, "could not listen on \(port)") }
    let controller = makeController(port: port, name: "foreign")
    guard case .external(let server) = controller.status else {
        listener.close()
        return check(false, "\(controller.status)")
    }
    check(!server.isOllama && server.pid == getpid(), "\(server)")
    var completed = false
    controller.stop { completed = true }
    check(completed && controller.status == .external(server), "stop acted on a foreign listener")
    listener.close()
    check(waitUntil(timeout: 2) { controller.status == .stopped }, "port freed but \(controller.status)")
}

test("a server from an earlier run is taken back as Paddock's own") {
    let port: UInt16 = 11498
    let suite = "paddock.tests.adopt"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    var first: ServerController? = makeController(port: port, name: "adopt", defaults: defaults)
    first?.start(keepAlive: .thirtyMinutes)
    guard waitUntil({ if case .running = first?.status { true } else { false } }), let original = first?.ownedServer
    else { return check(false, "never running") }
    first = nil  // Paddock "crashes": the server keeps running.
    check(ProcessInspector.isRunning(original.pid), "server died with its controller")

    let second = makeController(port: port, name: "adopt", defaults: defaults)
    guard case .running(let adopted) = second.status else { return check(false, "\(second.status)") }
    check(adopted.pid == original.pid && adopted.adopted, "\(adopted)")
    check(adopted.logURL == original.logURL && adopted.keepAlive == .thirtyMinutes, "\(adopted)")

    second.stop()
    check(waitUntil { second.status == .stopped }, "\(second.status)")
    check(
        !ProcessInspector.isRunning(original.pid) || waitUntil { !ProcessInspector.isRunning(original.pid) },
        "adopted server still running")

    // A record whose process is gone is dropped instead of adopted.
    let third = makeController(port: port, name: "adopt", defaults: defaults)
    check(third.status == .stopped && defaults.data(forKey: "ownedServer") == nil, "\(third.status)")
}

test("nothing starts without ollama") {
    let controller = makeController(port: 11499, name: "missing", binary: "/nonexistent/ollama")
    check(controller.binary == nil, "binary found")
    controller.start(keepAlive: .standard)
    check(controller.status == .stopped && controller.configuration.logStore.latest() == nil, "\(controller.status)")
}

for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
print(failures == 0 ? "all tests passed" : "\(failures) failures")
exit(failures == 0 ? 0 : 1)
