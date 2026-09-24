import Darwin
import Foundation

// Stands in for `ollama serve` in the tests. It prints its OLLAMA_* environment, listens where OLLAMA_HOST says,
// and accepts and closes connections until it is terminated. Built as a binary named `ollama`, so the process is
// recognised as ollama exactly like the real one.
//
// FAKE_OLLAMA_EXIT=<n>         exit with status n before listening
// FAKE_OLLAMA_LISTEN_DELAY=<s> wait s seconds before listening
// FAKE_OLLAMA_IGNORE_TERM=1    ignore SIGTERM, so only SIGKILL ends it

setvbuf(stdout, nil, _IONBF, 0)
let environment = ProcessInfo.processInfo.environment
for (key, value) in environment.sorted(by: { $0.key < $1.key }) where key.hasPrefix("OLLAMA_") {
    print("\(key)=\(value)")
}
if let code = environment["FAKE_OLLAMA_EXIT"].flatMap(Int32.init) {
    print("exiting with \(code)")
    exit(code)
}
if environment["FAKE_OLLAMA_IGNORE_TERM"] != nil {
    signal(SIGTERM, SIG_IGN)
}
if let delay = environment["FAKE_OLLAMA_LISTEN_DELAY"].flatMap(Double.init) {
    usleep(useconds_t(delay * 1_000_000))
}

let host = environment["OLLAMA_HOST"] ?? "127.0.0.1:11434"
guard let port = host.split(separator: ":").last.flatMap({ UInt16($0) }) else { exit(64) }

let fd = socket(AF_INET, SOCK_STREAM, 0)
var reuse: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
var address = sockaddr_in()
address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
address.sin_family = sa_family_t(AF_INET)
address.sin_port = port.bigEndian
address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
}
guard bound == 0, listen(fd, 16) == 0 else {
    print("Error: listen tcp 127.0.0.1:\(port): bind: address already in use")
    exit(1)
}
print("Listening on 127.0.0.1:\(port)")
while true {
    let connection = accept(fd, nil, nil)
    if connection >= 0 { close(connection) }
}
