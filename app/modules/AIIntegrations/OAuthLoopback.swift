import Foundation
import Darwin

// Pieces the remote MCP sign-in (RemoteMCP.swift) and its Keychain items share.

// /usr/bin/security runs every Keychain read and write: Apple's signed executable owns the ACL, so rebuilding this
// app does not change its reader. Secrets go over stdin, never argv, shell interpolation, a file or a log.
enum SecurityTool {
    typealias Runner = ([String], Data?) throws -> (Int32, Data)
    static func execute(_ arguments: [String], _ input: Data?) throws -> (Int32, Data) {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let pipe = input == nil ? nil : Pipe()
        process.standardInput = pipe.map { $0.fileHandleForReading } ?? FileHandle.nullDevice
        // Wait with a semaphore, never waitUntilExit: that runs the main run loop, and SwiftUI may then draw a view
        // again while a shared object is still being made (crash "_dispatch_once_wait", 2026-11-16/18).
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { throw MCPSession.Failure(message: "Could not start macOS Keychain access.") }
        if let input, let pipe {
            pipe.fileHandleForWriting.write(input)
            pipe.fileHandleForWriting.closeFile()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        return (process.terminationStatus, data)
    }
}

// application/x-www-form-urlencoded, for token requests.
enum FormEncoding {
    static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    static func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: unreserved)! }
    static func form(_ fields: [String: String]) -> Data {
        Data(fields.sorted { $0.key < $1.key }.map { encode($0.key) + "=" + encode($0.value) }.joined(separator: "&").utf8)
    }
}

/// The browser's way back after a sign-in: one request to `redirect`, its query fields to `start`'s completion.
protocol OAuthCallback: AnyObject {
    var redirect: String { get }
    func start(_ completion: @escaping (Result<[String: String], Error>) -> Void)
    func cancel()
}

// A one-shot loopback receiver. Binds only IPv4 localhost, on a random OS-assigned port unless one is asked for
// (remote MCP sign-in reuses the port its client was registered with). `label` names the service in messages.
final class OAuthLoopback: OAuthCallback {
    /// How a sign-in listens (port 0: any free one; label: the service in messages).
    static var make: (UInt16, String) throws -> OAuthCallback = { try OAuthLoopback(port: $0, label: $1) }
    private let fd: Int32
    private let lock = NSLock()
    private var cancelled = false
    private let label: String
    let redirect: String
    init(port: UInt16 = 0, label: String) throws {
        signal(SIGPIPE, SIG_IGN)
        self.label = label
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        fd = descriptor
        guard descriptor >= 0 else { throw MCPSession.Failure(message: "Could not open the \(label) sign-in callback.") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var reuse: Int32 = 1   // a fixed port may still be in TIME_WAIT from the last sign-in
        if port != 0 { _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard bound == 0, named == 0, Darwin.listen(fd, 4) == 0 else { close(fd); throw MCPSession.Failure(message: "Could not listen for \(label) sign-in.") }
        redirect = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/"
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func start(_ completion: @escaping (Result<[String: String], Error>) -> Void) {
        Thread.detachNewThread {
            var listening = true
            defer { if listening { close(self.fd) } }
            let deadline = Date().addingTimeInterval(300)
            var ready = false
            while Date() < deadline {
                self.lock.lock(); let cancelled = self.cancelled; self.lock.unlock()
                if cancelled { completion(.failure(MCPSession.Failure(message: "\(self.label) sign-in was cancelled."))); return }
                var descriptor = pollfd(fd: self.fd, events: Int16(POLLIN), revents: 0)
                let result = poll(&descriptor, 1, 100)
                if result > 0 { ready = true; break }
                if result < 0 { break }
            }
            guard ready else { completion(.failure(MCPSession.Failure(message: "\(self.label) sign-in timed out."))); return }
            let client = accept(self.fd, nil, nil)
            guard client >= 0 else { completion(.failure(MCPSession.Failure(message: "\(self.label) sign-in was cancelled."))); return }
            defer { close(client) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var bytes = [UInt8](repeating: 0, count: 16384)
            let count = read(client, &bytes, bytes.count)
            guard count > 0, let line = String(decoding: bytes.prefix(count), as: UTF8.self).components(separatedBy: "\r\n").first,
                  line.hasPrefix("GET "), let target = line.split(separator: " ").dropFirst().first,
                  let components = URLComponents(string: "http://127.0.0.1" + target) else {
                completion(.failure(MCPSession.Failure(message: "Invalid \(self.label) sign-in callback."))); return
            }
            var fields: [String: String] = [:]
            for item in components.queryItems ?? [] {
                guard fields[item.name] == nil else { completion(.failure(MCPSession.Failure(message: "Invalid \(self.label) sign-in callback."))); return }
                fields[item.name] = item.value ?? ""
            }
            let body = "\(self.label) sign-in response received. You may close this window. / \(self.label) 로그인 응답을 받았습니다. 이 창을 닫아도 됩니다."
            let data = Data(body.utf8)
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
            (Data(response.utf8) + data).withUnsafeBytes { raw in _ = write(client, raw.baseAddress, raw.count) }
            close(self.fd); listening = false
            completion(.success(fields))
        }
    }
}
