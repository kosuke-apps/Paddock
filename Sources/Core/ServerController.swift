import Darwin
import Foundation

/// A server Paddock started, in this run or in an earlier one.
struct OwnedServer: Equatable, Sendable {
    let pid: pid_t
    let startedAt: Date
    let logURL: URL
    let keepAlive: KeepAlive
    /// Started by an earlier run of Paddock that ended without stopping it (a crash or a force quit).
    let adopted: Bool
}

/// Something serving the port that Paddock did not start.
struct ExternalServer: Equatable, Sendable {
    /// nil when the listening process belongs to another user or to the system.
    let pid: pid_t?
    let processName: String?
    let startedAt: Date?

    var isOllama: Bool { processName == "ollama" }
}

enum ServerStatus: Equatable, Sendable {
    case stopped
    case starting(OwnedServer)
    case running(OwnedServer)
    case stopping(OwnedServer)
    case external(ExternalServer)
    case stoppingExternal(ExternalServer)
}

/// Something that went wrong, kept until the next start so the menu can say what happened.
enum ServerNotice: Equatable, Sendable {
    case launchFailed(String)
    case exitedWhileStarting
    case exitedUnexpectedly
    case startTimedOut(seconds: Int)
    case notPermittedToStop(pid: pid_t)
}

/// Starts, stops, and watches the one ollama server on the port.
///
/// It learns about changes from events wherever the system offers one: the exit of a process it started, or a
/// kernel exit notification for a process it did not. The port is only probed on a timer while nothing Paddock can
/// watch is serving it (no server, or a listener that is not ollama), and briefly while a server is starting.
@MainActor
final class ServerController {
    struct Configuration {
        var binaryCandidates: [String]
        var port: UInt16
        var logStore: LogStore
        var defaults: UserDefaults
        var baseEnvironment: [String: String]
        var idleProbeInterval: TimeInterval = 10
        var startProbeInterval: TimeInterval = 0.25
        var startTimeout: TimeInterval = 60
        var stopTimeout: TimeInterval = 10

        static func standard() -> Configuration {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Configuration(
                binaryCandidates: OllamaBinary.standardCandidates(home: home),
                port: 11434,
                logStore: LogStore(
                    directory: home.appendingPathComponent("Library/Logs/Paddock", isDirectory: true),
                    generations: 5),
                defaults: .standard,
                baseEnvironment: ProcessInfo.processInfo.environment)
        }
    }

    static let host = "127.0.0.1"

    let configuration: Configuration
    private(set) var status: ServerStatus = .stopped
    private(set) var binary: URL?
    private(set) var notice: ServerNotice?
    /// Called on the main thread whenever `status`, `binary`, or `notice` may have changed.
    var onChange: (() -> Void)?

    var address: String { "http://\(Self.host):\(configuration.port)" }

    var ownedServer: OwnedServer? {
        switch status {
        case .starting(let server), .running(let server), .stopping(let server): server
        default: nil
        }
    }

    private var child: Process?
    private var exitWatch: DispatchSourceProcess?
    private var probeTimer: DispatchSourceTimer?
    private var probeInterval: TimeInterval?
    private var escalation: DispatchWorkItem?
    private var startDeadline: Date?
    private var stopCompletions: [() -> Void] = []

    init(configuration: Configuration) {
        self.configuration = configuration
        if let record = loadRecord(), !isAlive(record) { clearRecord() }
        refresh()
        configureProbeTimer()
    }

    isolated deinit {
        probeTimer?.cancel()
        exitWatch?.cancel()
        escalation?.cancel()
    }

    // MARK: - Commands

    /// Looks for the ollama binary again and, when no server is known, checks who serves the port.
    func refresh() {
        let located = OllamaBinary.locate(in: configuration.binaryCandidates)
        let binaryChanged = located != binary
        binary = located
        switch status {
        case .stopped:
            detectServer()
        case .external(let server) where needsProbing(server):
            if !PortProbe.isListening(port: configuration.port) { transition(to: .stopped) }
        default:
            break
        }
        if binaryChanged { onChange?() }
    }

    /// Starts `ollama serve` bound to the loopback address with cloud features off.
    func start(keepAlive: KeepAlive) {
        refresh()
        guard case .stopped = status, let binary else { return }
        notice = nil

        let logURL: URL
        let output: FileHandle
        do {
            logURL = try configuration.logStore.createLogFile()
            output = try LogStore.openForAppending(logURL)
        } catch {
            fail(.launchFailed(error.localizedDescription))
            return
        }

        let environment = ServerEnvironment.make(
            base: configuration.baseEnvironment, host: Self.host, port: configuration.port, keepAlive: keepAlive)
        LogStore.append("# \(Self.timestamp()) Paddock starts \(binary.path) serve", to: logURL)
        LogStore.append("# \(ServerEnvironment.summary(of: environment))", to: logURL)

        let process = Process()
        process.executableURL = binary
        process.arguments = ["serve"]
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { [weak self] process in
            let pid = process.processIdentifier
            let ending = Self.describeEnding(process)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.serverExited(pid: pid, ending: ending) }
            }
        }
        do {
            try process.run()
        } catch {
            try? output.close()
            LogStore.append("# Could not start: \(error.localizedDescription)", to: logURL)
            fail(.launchFailed(error.localizedDescription))
            return
        }
        // The server has its own copy of the descriptor now.
        try? output.close()
        child = process

        let pid = process.processIdentifier
        if let details = ProcessInspector.details(of: pid) {
            saveRecord(Record(pid: pid, startTime: details.startTime, logPath: logURL.path, keepAlive: keepAlive))
        }
        startDeadline = Date().addingTimeInterval(configuration.startTimeout)
        transition(
            to: .starting(
                OwnedServer(pid: pid, startedAt: Date(), logURL: logURL, keepAlive: keepAlive, adopted: false)))
    }

    /// Stops the server Paddock started, or an ollama server started elsewhere (the caller asks the user first).
    /// `completion` runs once no server Paddock stopped is left, or at once when there is nothing it may stop.
    func stop(completion: (() -> Void)? = nil) {
        switch status {
        case .starting(let server), .running(let server):
            if let completion { stopCompletions.append(completion) }
            transition(to: .stopping(server))
            if let child, child.processIdentifier == server.pid {
                child.terminate()
            } else {
                kill(server.pid, SIGTERM)
            }
            scheduleEscalation(pid: server.pid, log: server.logURL)
        case .external(let server):
            guard let pid = server.pid, server.isOllama else {
                completion?()
                return
            }
            guard kill(pid, SIGTERM) == 0 else {
                if errno == EPERM { fail(.notPermittedToStop(pid: pid)) }
                completion?()
                return
            }
            if let completion { stopCompletions.append(completion) }
            transition(to: .stoppingExternal(server))
            scheduleEscalation(pid: pid, log: nil)
        case .stopping, .stoppingExternal:
            if let completion { stopCompletions.append(completion) }
        case .stopped:
            completion?()
        }
    }

    // MARK: - Detection

    /// Finds out who serves the port while Paddock believes nobody does.
    private func detectServer() {
        let record = loadRecord()
        guard PortProbe.isListening(port: configuration.port) else {
            // A server from an earlier run that is alive but not listening yet: it is still starting.
            if let record, isAlive(record) { adopt(record, as: { .starting($0) }) }
            return
        }
        let pid = ProcessInspector.pidListening(onPort: configuration.port)
        let details = pid.flatMap(ProcessInspector.details(of:))
        if let record, let details, record.pid == details.pid, record.startTime == details.startTime {
            adopt(record, as: { .running($0) })
            return
        }
        let server = ExternalServer(pid: details?.pid, processName: details?.name, startedAt: details?.startTime.date)
        transition(to: .external(server))
        if let pid = server.pid, server.isOllama { watchExit(of: pid) }
    }

    private func adopt(_ record: Record, as state: (OwnedServer) -> ServerStatus) {
        let server = OwnedServer(
            pid: record.pid, startedAt: record.startTime.date, logURL: URL(fileURLWithPath: record.logPath),
            keepAlive: KeepAlive(rawValue: record.keepAlive) ?? .standard, adopted: true)
        if case .starting = state(server) {
            startDeadline = Date().addingTimeInterval(configuration.startTimeout)
        }
        transition(to: state(server))
        watchExit(of: record.pid)
    }

    /// External ollama servers are watched through their exit; anything else is probed.
    private func needsProbing(_ server: ExternalServer) -> Bool {
        server.pid == nil || !server.isOllama
    }

    private func probeTick() {
        switch status {
        case .stopped:
            detectServer()
        case .external(let server) where needsProbing(server):
            if !PortProbe.isListening(port: configuration.port) { transition(to: .stopped) }
        case .starting(let server):
            if PortProbe.isListening(port: configuration.port),
                ProcessInspector.pidListening(onPort: configuration.port) == server.pid
            {
                startDeadline = nil
                transition(to: .running(server))
            } else if let deadline = startDeadline, Date() > deadline {
                startDeadline = nil
                LogStore.append(
                    "# The server did not listen within \(Int(configuration.startTimeout)) s", to: server.logURL)
                notice = .startTimedOut(seconds: Int(configuration.startTimeout))
                stop()
            }
        default:
            break
        }
    }

    private func configureProbeTimer() {
        let interval: TimeInterval? =
            switch status {
            case .stopped: configuration.idleProbeInterval
            case .external(let server) where needsProbing(server): configuration.idleProbeInterval
            case .starting: configuration.startProbeInterval
            default: nil
            }
        guard interval != probeInterval else { return }
        probeTimer?.cancel()
        probeTimer = nil
        probeInterval = interval
        guard let interval else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        // A generous leeway lets the system batch this wake-up with others.
        timer.schedule(
            deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 200)))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.probeTick() }
        }
        timer.resume()
        probeTimer = timer
    }

    // MARK: - Exit

    private func watchExit(of pid: pid_t) {
        exitWatch?.cancel()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.serverExited(pid: pid, ending: nil) }
        }
        source.resume()
        exitWatch = source
        // The process may have ended before the watch was in place.
        if !ProcessInspector.isRunning(pid) {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.serverExited(pid: pid, ending: nil) }
            }
        }
    }

    /// `ending` describes how a child process ended; it is nil for processes Paddock only watches.
    private func serverExited(pid: pid_t, ending: String?) {
        let owned: OwnedServer?
        switch status {
        case .starting(let server) where server.pid == pid:
            owned = server
            notice = .exitedWhileStarting
        case .running(let server) where server.pid == pid:
            owned = server
            notice = .exitedUnexpectedly
        case .stopping(let server) where server.pid == pid:
            owned = server
        case .external(let server) where server.pid == pid, .stoppingExternal(let server) where server.pid == pid:
            owned = nil
        default:
            return  // A late event for a process already dealt with.
        }
        if let owned {
            LogStore.append("# \(Self.timestamp()) ollama serve (pid \(pid)) \(ending ?? "exited")", to: owned.logURL)
            clearRecord()
        }
        if child?.processIdentifier == pid { child = nil }
        exitWatch?.cancel()
        exitWatch = nil
        escalation?.cancel()
        escalation = nil
        startDeadline = nil
        transition(to: .stopped)
        // Something may have taken over the port already, such as a launchd job restarting ollama.
        if case .stopped = status { detectServer() }
    }

    /// Kills a server that has not exited `stopTimeout` seconds after SIGTERM, and its model runners with it.
    private func scheduleEscalation(pid: pid_t, log: URL?) {
        escalation?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, ProcessInspector.isRunning(pid) else { return }
                if let log {
                    LogStore.append(
                        "# Still running \(Int(self.configuration.stopTimeout)) s after SIGTERM; sending SIGKILL",
                        to: log)
                }
                for runner in ProcessInspector.childPIDs(of: pid) { kill(runner, SIGKILL) }
                kill(pid, SIGKILL)
            }
        }
        escalation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.stopTimeout, execute: work)
    }

    // MARK: - State

    private func transition(to new: ServerStatus) {
        let old = status
        status = new
        switch new {
        case .running, .external: notice = nil
        default: break
        }
        configureProbeTimer()
        if case .stopped = new {
            let completions = stopCompletions
            stopCompletions = []
            completions.forEach { $0() }
        }
        if old != new { onChange?() }
    }

    private func fail(_ notice: ServerNotice) {
        self.notice = notice
        onChange?()
    }

    private nonisolated static func describeEnding(_ process: Process) -> String {
        switch process.terminationReason {
        case .uncaughtSignal: "was ended by signal \(process.terminationStatus)"
        default: "exited with status \(process.terminationStatus)"
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }

    // MARK: - Record of the server Paddock started

    /// Kept in the defaults so that a server survives a crash of Paddock as Paddock's own: the next run finds the
    /// same pid with the same start time listening on the port and takes it back.
    private struct Record: Codable {
        var pid: pid_t
        var startTime: ProcessStartTime
        var logPath: String
        var keepAlive: String

        init(pid: pid_t, startTime: ProcessStartTime, logPath: String, keepAlive: KeepAlive) {
            self.pid = pid
            self.startTime = startTime
            self.logPath = logPath
            self.keepAlive = keepAlive.rawValue
        }
    }

    private static let recordKey = "ownedServer"

    private func loadRecord() -> Record? {
        configuration.defaults.data(forKey: Self.recordKey).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
    }

    private func saveRecord(_ record: Record) {
        configuration.defaults.set(try? JSONEncoder().encode(record), forKey: Self.recordKey)
    }

    private func clearRecord() {
        configuration.defaults.removeObject(forKey: Self.recordKey)
    }

    private func isAlive(_ record: Record) -> Bool {
        ProcessInspector.details(of: record.pid)?.startTime == record.startTime
    }
}
