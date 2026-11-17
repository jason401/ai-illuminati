import Foundation
import Network
import Security
import AILocalization

// AIRemote: the small web server the iPhone page talks to. It listens on 127.0.0.1 only; `tailscale serve` brings
// https://<mac>.ts.net/ to it, so only the user's tailnet reaches it. It knows no chat: the App answers each request.
// Every /api/ call needs the key from the QR (header or `k`), because any program on this Mac, the AI CLIs included,
// can reach 127.0.0.1 and must not send messages or allow its own approvals.

public struct RemoteRequest {
    public var method: String
    public var path: String                 // without the query, percent-decoded
    public var query: [String: String]
    public var headers: [String: String]    // lowercased names
    public var body: Data
    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method; self.path = path; self.query = query; self.headers = headers; self.body = body
    }
    public var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
}

public struct RemoteResponse {
    public var status: Int
    public var type: String
    public var body: Data
    public init(status: Int = 200, type: String, body: Data) { self.status = status; self.type = type; self.body = body }
    public static func json(_ object: Any, status: Int = 200) -> RemoteResponse {
        RemoteResponse(status: status, type: "application/json; charset=utf-8",
                       body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
    }
    public static func error(_ status: Int, _ message: String) -> RemoteResponse { json(["error": message], status: status) }

    var bytes: Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 409: "Conflict", 413: "Payload Too Large"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

public enum RemoteHTTP {
    public static let maxBody = 48 << 20     // a few phone photos as base64

    public enum Parsed { case more, bad(Int), done(RemoteRequest) }

    // One HTTP/1.1 request from the bytes read so far: `.more` until the head and Content-Length bytes are in.
    public static func parse(_ data: Data) -> Parsed {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return data.count > 64 << 10 ? .bad(400) : .more }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .bad(400) }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count == 3, first[2].hasPrefix("HTTP/1.") else { return .bad(400) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .bad(400) }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .bad(400) }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .bad(400) }
        guard length <= maxBody else { return .bad(413) }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .more }
        let target = String(first[1])
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var query: [String: String] = [:]
        if parts.count == 2 {
            for item in URLComponents(string: "?" + parts[1])?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        }
        let path = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        return .done(RemoteRequest(method: String(first[0]), path: path, query: query, headers: headers,
                                   body: data.subdata(in: bodyStart..<(bodyStart + length))))
    }

    // The QR's key, compared in constant time.
    public static func authorized(_ request: RemoteRequest, key: String) -> Bool {
        guard !key.isEmpty else { return false }
        let given = Array((request.headers["x-remote-key"] ?? request.query["k"] ?? "").utf8), want = Array(key.utf8)
        guard given.count == want.count else { return false }
        return zip(given, want).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    public static func newKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public final class RemoteServer {
    // The App's answer for an /api/ request that passed the key check; called on the main queue.
    public typealias Handler = (RemoteRequest) -> RemoteResponse
    public let port: UInt16
    private let key: String
    private let handler: Handler
    private let page: () -> Data
    private let icon: Data?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "AIRemote.server")

    public init(port: UInt16, key: String, page: @escaping () -> Data, icon: Data? = nil, handler: @escaping Handler) {
        self.port = port; self.key = key; self.page = page; self.icon = icon; self.handler = handler
    }

    public var running: Bool { listener != nil }

    public func start() throws {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { DispatchQueue.main.async { self?.stop() } }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() { listener?.cancel(); listener = nil }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
        // A phone that stops mid-upload must not hold the connection forever.
        queue.asyncAfter(deadline: .now() + 120) { connection.cancel() }
    }

    private func read(_ connection: NWConnection, _ sofar: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] chunk, _, finished, error in
            guard let self else { connection.cancel(); return }
            var data = sofar
            if let chunk { data.append(chunk) }
            switch RemoteHTTP.parse(data) {
            case .more:
                if finished || error != nil { connection.cancel() } else { self.read(connection, data) }
            case .bad(let status):
                self.send(connection, .error(status, "bad request"))
            case .done(let request):
                DispatchQueue.main.async { self.send(connection, self.respond(request)) }
            }
        }
    }

    func respond(_ request: RemoteRequest) -> RemoteResponse {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return RemoteResponse(type: "text/html; charset=utf-8", body: page())
        case ("GET", "/apple-touch-icon.png"), ("GET", "/apple-touch-icon-precomposed.png"), ("GET", "/favicon.ico"):
            return icon.map { RemoteResponse(type: "image/png", body: $0) } ?? .error(404, "no icon")
        default:
            guard request.path.hasPrefix("/api/") else { return .error(404, "not found") }
            guard RemoteHTTP.authorized(request, key: key) else { return .error(401, L("QR을 다시 찍어 주세요.", "Scan the QR again.")) }
            return handler(request)
        }
    }

    private func send(_ connection: NWConnection, _ response: RemoteResponse) {
        connection.send(content: response.bytes, completion: .contentProcessed { _ in connection.cancel() })
    }
}
