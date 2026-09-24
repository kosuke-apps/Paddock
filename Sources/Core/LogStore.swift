import Darwin
import Foundation

/// The server logs: one file per server start, the newest few kept whole and older ones deleted whole.
struct LogStore: Sendable {
    let directory: URL
    /// How many log files to keep, the current one included.
    let generations: Int

    private static let prefix = "ollama-serve-"
    private static let suffix = ".log"

    /// Creates an empty log file named after the current time, then deletes the files beyond `generations`.
    func createLogFile(now: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stem = Self.prefix + formatter.string(from: now)

        var url = directory.appendingPathComponent(stem + Self.suffix)
        var attempt = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(stem)-\(attempt)\(Self.suffix)")
            attempt += 1
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        prune(keeping: url)
        return url
    }

    /// The server log files, newest first.
    func logFiles() -> [URL] {
        let keys: [URLResourceKey] = [.creationDateKey]
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let logs = urls.filter {
            $0.lastPathComponent.hasPrefix(Self.prefix) && $0.lastPathComponent.hasSuffix(Self.suffix)
        }
        func created(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        }
        return logs.sorted {
            let (a, b) = (created($0), created($1))
            return a != b ? a > b : $0.lastPathComponent > $1.lastPathComponent
        }
    }

    func latest() -> URL? { logFiles().first }

    /// Deletes whole files beyond `generations`. `current` is never deleted.
    func prune(keeping current: URL?) {
        let current = current?.standardizedFileURL
        let others = logFiles().filter { $0.standardizedFileURL != current }
        let room = max(current == nil ? generations : generations - 1, 0)
        for file in others.dropFirst(room) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Appends one line. The file is opened with `O_APPEND`, like the server's own output, so neither overwrites
    /// the other.
    static func append(_ line: String, to url: URL) {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array((line.hasSuffix("\n") ? line : line + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Opens a log file for a child process to write to, in append mode.
    static func openForAppending(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// The last `maxLines` lines of a file, reading at most `maxBytes` from its end. Returns nil when the file
    /// cannot be read.
    static func tail(of url: URL, maxLines: Int, maxBytes: Int = 256 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() ?? Data() else {
            return nil
        }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        // Reading from the middle of the file cuts the first line; drop it rather than show half a line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        if lines.last == "" { lines.removeLast() }
        return lines.suffix(maxLines).joined(separator: "\n")
    }
}
