import Foundation

/// How long ollama keeps a model in memory after its last request (`OLLAMA_KEEP_ALIVE`).
/// A request's own `keep_alive` field takes precedence, so apps can still unload a model at once.
enum KeepAlive: String, CaseIterable, Sendable {
    case immediately = "0"
    case oneMinute = "1m"
    case fiveMinutes = "5m"
    case thirtyMinutes = "30m"

    /// ollama's own default. Passed explicitly, so the menu stays true if ollama changes its default.
    static let standard: KeepAlive = .fiveMinutes
}

/// The environment `ollama serve` runs with when Paddock starts it.
enum ServerEnvironment {
    /// Starts from `base` (Paddock's own environment), drops every inherited `OLLAMA_*` variable so nothing set
    /// elsewhere (for example with `launchctl setenv`) can widen access, then sets Paddock's values.
    static func make(base: [String: String], host: String, port: UInt16, keepAlive: KeepAlive) -> [String: String] {
        var environment = base.filter { !$0.key.hasPrefix("OLLAMA_") }
        environment["OLLAMA_HOST"] = "\(host):\(port)"
        environment["OLLAMA_NO_CLOUD"] = "1"
        environment["OLLAMA_KEEP_ALIVE"] = keepAlive.rawValue
        return environment
    }

    /// The `OLLAMA_*` part of an environment, one `NAME=value` per entry, sorted. Written to the log.
    static func summary(of environment: [String: String]) -> String {
        environment.filter { $0.key.hasPrefix("OLLAMA_") }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }
}

/// Where the `ollama` command is looked for. An app opened from Finder does not get the shell's `PATH`, so the
/// usual install locations are listed explicitly.
enum OllamaBinary {
    static func standardCandidates(home: URL) -> [String] {
        [
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama",
            home.appendingPathComponent("Applications/Ollama.app/Contents/Resources/ollama").path,
        ]
    }

    static func locate(in candidates: [String]) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}
