import Foundation
import Darwin

struct ToolContext {
    var room: UUID
    var roots: [WorkspaceRoot]
}

protocol ToolProvider: AnyObject {
    var active: Bool { get }
    func tools() -> [[String: Any]]
    func call(_ name: String, _ arguments: [String: Any], context: ToolContext) -> [String: Any]
}

extension FaceLink: ToolProvider {
    var active: Bool { Self.active() != nil }
    func call(_ name: String, _ arguments: [String: Any], context: ToolContext) -> [String: Any] { call(name, arguments) }
}

// One app-side gateway. Per-answer capabilities keep other chat modes and arbitrary local
// pointer paths out; these are not Google credentials and grant no network access to the CLI.
final class ToolHub {
    static let shared = ToolHub()
    static var socketPath = AccountStore.supportDir + "/tools.sock"
    private var providers: [ToolProvider] { [FaceLink.shared, DriveLink.shared] }
    var active: Bool { providers.contains { $0.active } }
    private let lock = NSLock()
    private var sockets: Set<String> = []
    private var sessions: [String: (ToolContext, Date)] = [:]

    func register(room: UUID, roots: [WorkspaceRoot]) -> String {
        start()
        lock.lock(); defer { lock.unlock() }
        sessions = sessions.filter { $0.value.1 > Date() }
        let key = UUID().uuidString
        sessions[key] = (ToolContext(room: room, roots: roots), Date().addingTimeInterval(7200))
        return key
    }

    func start() { listen(at: Self.socketPath, legacy: false) }
    // One release of compatibility for already prepared face-only manifests.
    func startLegacyFaceSocket(at path: String) { listen(at: path, legacy: true) }

    static func failure(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": true]
    }

    func handle(_ message: [String: Any], legacy: Bool = false) -> [String: Any] {
        let context: ToolContext
        if legacy {
            context = ToolContext(room: UUID(), roots: [])
        } else {
            lock.lock()
            let session = sessions[message["session"] as? String ?? ""]
            lock.unlock()
            guard let session, session.1 > Date() else { return Self.failure("This tool session has expired or is unavailable.") }
            context = session.0
        }
        let available: [ToolProvider] = legacy ? [FaceLink.shared] : providers
        switch message["op"] as? String {
        case "tools":
            return ["tools": available.filter { $0.active }.flatMap { $0.tools() }]
        case "call":
            let name = message["name"] as? String ?? ""
            guard let provider = available.first(where: { $0.active && $0.tools().contains { $0["name"] as? String == name } }) else {
                return Self.failure("Tool is disconnected, switched off or unavailable: " + name)
            }
            return provider.call(name, message["arguments"] as? [String: Any] ?? [:], context: context)
        default: return Self.failure("Unknown tool request")
        }
    }

    private func listen(at path: String, legacy: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !sockets.contains(path) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
        unlink(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 8) == 0 else { close(fd); return }
        sockets.insert(path)
        signal(SIGPIPE, SIG_IGN)
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { Thread.sleep(forTimeInterval: 0.05); continue }   // one failed accept must not stop the socket
                DispatchQueue.global().async { self?.serve(client, legacy: legacy) }
            }
        }
    }

    private func serve(_ client: Int32, legacy: Bool) {
        defer { close(client) }
        var timeout = timeval(tv_sec: 65, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data(), chunk = [UInt8](repeating: 0, count: 4096)
        while !data.contains(10) && data.count < 1_000_000 {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { return }
            data.append(contentsOf: chunk.prefix(n))
        }
        guard let line = data.split(separator: 10).first,
              let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let output = try? JSONSerialization.data(withJSONObject: handle(message, legacy: legacy)) else { return }
        (output + Data([10])).withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(client, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}
