import Foundation
import AppKit
import CryptoKit
import Security
import AIAccounts
import AILocalization

// Remote (URL) MCP servers, like Claude's custom connectors: the app is the MCP client over Streamable HTTP, so the
// CLIs still see only the illuminati server and no token ever reaches them. Header values and OAuth tokens live in
// their own Keychain service; mcp-servers.json keeps only the URL and header names.

// MARK: Secrets

public protocol MCPSecretStore: AnyObject {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String?) throws
}

// Through /usr/bin/security like the Google login (its ACL survives rebuilds). Its input line is bounded, so a
// long value (a JWT, a token blob) is split over numbered items; item 0 says how many and is written last.
public final class MCPKeychain: MCPSecretStore {
    private static let service = "AI Illuminati MCP", chunk = 2800
    private let lock = NSLock()
    private let run: GoogleKeychainStore.Runner
    public init(run: GoogleKeychainStore.Runner? = nil) { self.run = run ?? GoogleKeychainStore.execute }
    private var cache: [String: String?] = [:]

    private func read(_ account: String) -> String? {
        guard let (status, output) = try? run(["find-generic-password", "-s", Self.service, "-a", account, "-w"], nil),
              status == 0 else { return nil }
        var data = output
        if data.last == 10 { data.removeLast() }
        return String(data: data, encoding: .utf8)
    }
    private func write(_ account: String, _ value: String) throws {
        let line = "add-generic-password -U -s \"\(Self.service)\" -a \"\(account)\" -w \(value)\n"
        let (status, _) = try run(["-i"], Data(line.utf8))
        guard status == 0 else { throw MCPSession.Failure(message: L("키체인에 저장하지 못했어요.", "Could not save to the Keychain.")) }
    }
    private func remove(_ account: String) { _ = try? run(["delete-generic-password", "-s", Self.service, "-a", account], nil) }
    private func count(_ key: String) -> Int? {
        guard let head = read(key + "#0"), head.hasPrefix("v1:"), let colon = head.dropFirst(3).firstIndex(of: ":") else { return nil }
        return Int(head[head.index(head.startIndex, offsetBy: 3)..<colon])
    }

    public func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        var value: String?
        if let head = read(key + "#0"), head.hasPrefix("v1:"), let n = count(key) {
            var text = String(head.split(separator: ":", maxSplits: 2).dropFirst(2).first ?? "")
            for i in 1..<max(n, 1) { text += read(key + "#\(i)") ?? "" }
            value = Data(base64Encoded: text).flatMap { String(data: $0, encoding: .utf8) }
        }
        cache[key] = value
        return value
    }

    public func set(_ key: String, _ value: String?) throws {
        lock.lock(); defer { lock.unlock() }
        let old = count(key) ?? 0
        guard let value, !value.isEmpty else {
            for i in 0..<max(old, 1) { remove(key + "#\(i)") }
            cache[key] = .some(nil); return
        }
        let text = Data(value.utf8).base64EncodedString()
        var parts: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty { parts.append(String(rest.prefix(Self.chunk))); rest = rest.dropFirst(Self.chunk) }
        for i in stride(from: parts.count - 1, through: 1, by: -1) { try write(key + "#\(i)", parts[i]) }
        try write(key + "#0", "v1:\(parts.count):" + parts[0])
        for i in parts.count..<max(old, parts.count) { remove(key + "#\(i)") }
        cache[key] = value
    }
}

// Tests and previews: an owner-only file in their throwaway home, never the real Keychain.
final class MCPFileSecrets: MCPSecretStore {
    private let lock = NSLock()
    private var file: URL { URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("mcp-secrets-test.json") }
    private func all() -> [String: String] { (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: String] ?? [:] }
    func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return all()[key] }
    func set(_ key: String, _ value: String?) throws {
        lock.lock(); defer { lock.unlock() }
        var values = all(); values[key] = value?.isEmpty == false ? value : nil
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: values, options: .sortedKeys).write(to: file)
        chmod(file.path, 0o600)
    }
}

public enum MCPSecrets {
    public static var store: MCPSecretStore = UserDefaults.app === UserDefaults.standard ? MCPKeychain() : MCPFileSecrets()
    public static func header(_ server: String, _ name: String) -> String { "header.\(server).\(name)" }
    static func oauth(_ server: String) -> String { "oauth.\(server)" }
    public static func clientSecret(_ server: String) -> String { "client-secret.\(server)" }
    static func keys(_ entry: MCPServerEntry) -> [String] { entry.headers.keys.map { header(entry.name, $0) } + [oauth(entry.name), clientSecret(entry.name)] }
}

// MARK: Pasted setups

extension MCPServerEntry {
    /// https only, plus http to this Mac. Nil when fine, else why not.
    public static func urlProblem(_ text: String) -> String? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            return L("주소가 올바르지 않아요.", "This is not a valid address.")
        }
        if url.user != nil || url.password != nil || url.fragment != nil { return L("주소에 계정 정보나 #이 있으면 안 돼요.", "The address may not hold a user name or #.") }
        if scheme == "https" || (scheme == "http" && isLocal(host)) { return nil }
        return L("https 주소만 돼요 (이 Mac의 localhost는 http도 돼요).", "Only https addresses (http only for localhost on this Mac).")
    }
    static func isLocal(_ host: String) -> Bool { ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) }

    /// A name from the address: mcp.notion.com → notion, api.githubcopilot.com → githubcopilot.
    public static func name(fromURL text: String) -> String {
        guard let host = URL(string: text)?.host?.lowercased() else { return "" }
        var parts = host.split(separator: ".").map(String.init)
        if parts.count > 1, Int(parts.last!) == nil { parts.removeLast() }
        while parts.count > 1, ["mcp", "www", "api", "server", "app"].contains(parts[0]) { parts.removeFirst() }
        return normalized(parts.first ?? host)
    }

    /// "Name: value" lines into headers; nil names a line that is not one.
    public static func headerLines(_ text: String) -> Result<[String: String], MCPSession.Failure> {
        var headers: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let colon = trimmed.firstIndex(of: ":"), case let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces), validHeader(key) else {
                return .failure(.init(message: L("헤더는 이름: 값 모양으로 적어 주세요: ", "Write headers as Name: value: ") + trimmed))
            }
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else {
                return .failure(.init(message: L("헤더 값에는 영문·숫자·기호만 돼요: ", "Header values must be plain ASCII: ") + key))
            }
            headers[key] = value
        }
        return .success(headers)
    }
    static func validHeader(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
            && !["host", "content-length", "content-type", "accept", "mcp-protocol-version", "mcp-session-id", "mcp-method", "mcp-name"].contains(name.lowercased())
    }

    /// What READMEs show, pasted as is: a bare URL, `claude mcp add …`, `claude mcp add-json …`, `codex mcp add …`.
    /// JSON goes through parse(); nil when the text is none of these.
    static func command(_ text: String) -> MCPServerEntry? {
        let line = text.replacingOccurrences(of: "\\\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.contains(" "), urlProblem(line) == nil || line.lowercased().hasPrefix("http") {
            return MCPServerEntry(name: name(fromURL: line), url: line)
        }
        var words = words(line)
        guard words.count >= 3, ["claude", "codex"].contains(words[0]), words[1] == "mcp" else { return nil }
        let tool = words[0]
        if words[2] == "add-json", words.count >= 5, var entry = parse("{\"\(words[3])\": \(words[4])}").first {
            entry.name = normalized(words[3]); return entry
        }
        guard words[2] == "add" else { return nil }
        words.removeFirst(3)
        var positional: [String] = [], headers: [String: String] = [:], env: [String: String] = [:], url = "", rest: [String] = []
        var i = 0
        while i < words.count {
            let word = words[i]
            let value = i + 1 < words.count ? words[i + 1] : ""
            if word == "--" { rest = Array(words[(i + 1)...]); break }
            switch word {
            case "--transport", "-t", "--scope", "-s", "--bearer-token-env-var", "--callback-port", "--client-id": i += 2
            case "--header", "-H":
                if case .success(let h) = headerLines(value) { headers.merge(h) { $1 } }
                i += 2
            case "--env", "-e": if let eq = value.firstIndex(of: "=") { env[String(value[..<eq])] = String(value[value.index(after: eq)...]) }; i += 2
            case "--url": url = value; i += 2
            default:
                if word.hasPrefix("--transport=") || word.hasPrefix("--scope=") { i += 1; continue }
                if word.hasPrefix("--url=") { url = String(word.dropFirst(6)); i += 1; continue }
                positional.append(word); i += 1
            }
        }
        if url.isEmpty, positional.count >= 2, positional[1].lowercased().hasPrefix("http") { url = positional[1] }
        let given = positional.first.map(normalized) ?? ""
        if !url.isEmpty { return MCPServerEntry(name: given.isEmpty ? name(fromURL: url) : given, url: url, headers: headers) }
        let program = rest.isEmpty ? Array(positional.dropFirst()) : rest
        guard tool == "claude" || tool == "codex", let first = program.first else { return nil }
        return MCPServerEntry(name: given, command: first, args: Array(program.dropFirst()), env: env)
    }
}

// MARK: Tool permissions (per server and tool: always allow, ask, block)

public enum MCPToolRule: String, CaseIterable { case allow, ask, block }

enum MCPPermissions {
    private static let rulesKey = "mcpToolRules", seenKey = "mcpToolSeen", changedKey = "mcpToolChanged"
    private static var rules: [String: [String: String]] { UserDefaults.app.dictionary(forKey: rulesKey) as? [String: [String: String]] ?? [:] }

    /// The default: remote tools marked read-only run, other remote tools ask; local servers keep running every tool.
    static func defaultRule(_ tool: [String: Any], remote: Bool) -> MCPToolRule {
        guard remote else { return .allow }
        return (tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true ? .allow : .ask
    }
    static func rule(_ server: String, _ tool: [String: Any], remote: Bool) -> MCPToolRule {
        let name = tool["name"] as? String ?? ""
        return rules[server]?[name].flatMap(MCPToolRule.init) ?? defaultRule(tool, remote: remote)
    }
    static func set(_ server: String, _ tool: String, _ rule: MCPToolRule?) {
        var all = rules
        all[server, default: [:]][tool] = rule?.rawValue
        UserDefaults.app.set(all, forKey: rulesKey)
    }
    static func changed(_ server: String) -> [String] { (UserDefaults.app.dictionary(forKey: changedKey) as? [String: [String]])?[server] ?? [] }
    static func acknowledge(_ server: String) {
        var all = UserDefaults.app.dictionary(forKey: changedKey) as? [String: [String]] ?? [:]
        all[server] = nil
        UserDefaults.app.set(all, forKey: changedKey)
    }
    /// Everything about a tool the model reads: a server that changes it after it was allowed is asked about again.
    static func hash(_ tool: [String: Any]) -> String {
        var copy = tool
        copy["_meta"] = nil
        let data = (try? JSONSerialization.data(withJSONObject: copy, options: .sortedKeys)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
    /// A new list from a server: a tool that changed loses its saved rule (back to the default) and is shown as changed.
    static func review(_ server: String, _ tools: [[String: Any]]) {
        var seen = UserDefaults.app.dictionary(forKey: seenKey) as? [String: [String: String]] ?? [:]
        let before = seen[server]
        var now: [String: String] = [:], differs: [String] = []
        for tool in tools {
            guard let name = tool["name"] as? String else { continue }
            now[name] = hash(tool)
            if let old = before?[name], old != now[name] { differs.append(name); set(server, name, nil) }
        }
        seen[server] = now
        UserDefaults.app.set(seen, forKey: seenKey)
        if !differs.isEmpty {
            var all = UserDefaults.app.dictionary(forKey: changedKey) as? [String: [String]] ?? [:]
            all[server] = Array(Set((all[server] ?? []) + differs)).sorted()
            UserDefaults.app.set(all, forKey: changedKey)
        }
    }
    static func forget(_ server: String) {
        for key in [rulesKey, seenKey, changedKey] {
            var all = UserDefaults.app.dictionary(forKey: key) ?? [:]
            all[server] = nil
            UserDefaults.app.set(all, forKey: key)
        }
    }
    static func rename(_ old: String, _ new: String) {
        for key in [rulesKey, seenKey, changedKey] {
            var all = UserDefaults.app.dictionary(forKey: key) ?? [:]
            all[new] = all[old]; all[old] = nil
            UserDefaults.app.set(all, forKey: key)
        }
    }
}

// MARK: HTTP

// POST and GET with no redirects (a redirect never carries a token elsewhere), JSON or SSE replies. An SSE reply
// is read as it comes and closed as soon as the answer to `id` is in (closing it is the cancel signal).
enum MCPHTTP {
    struct Reply {
        var status: Int
        var headers: [String: String]   // lower-case names
        var body: Data
        var messages: [[String: Any]]
        func header(_ name: String) -> String? { headers[name.lowercased()] }
        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
    }
    static let limit = 16 << 20

    private final class Reader: NSObject, URLSessionDataDelegate {
        let done = DispatchSemaphore(value: 0)
        let wanted: Int?, onMessage: ([String: Any]) -> Void
        var data = Data(), pending = Data(), response: HTTPURLResponse?, failure: Error?, messages: [[String: Any]] = []
        var sse = false, answered = false
        init(wanted: Int?, onMessage: @escaping ([String: Any]) -> Void) { self.wanted = wanted; self.onMessage = onMessage }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            self.response = response as? HTTPURLResponse
            sse = (self.response?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().hasPrefix("text/event-stream")
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard self.data.count + data.count <= MCPHTTP.limit else {
                failure = MCPSession.Failure(message: "The server's answer is too large."); dataTask.cancel(); return
            }
            self.data.append(data)
            guard sse else { return }
            pending.append(contentsOf: data.filter { $0 != 13 })
            while let end = pending.range(of: Data([10, 10])) {
                let event = pending[pending.startIndex..<end.lowerBound]
                pending.removeSubrange(pending.startIndex..<end.upperBound)
                let lines = event.split(separator: 10, omittingEmptySubsequences: false).compactMap { line -> Data? in
                    guard line.starts(with: Data("data:".utf8)) else { return nil }
                    var rest = line.dropFirst(5)
                    if rest.first == 32 { rest = rest.dropFirst() }
                    return Data(rest)
                }
                guard !lines.isEmpty, let message = try? JSONSerialization.jsonObject(with: Data(lines.joined(separator: [10]))) as? [String: Any] else { continue }
                messages.append(message)
                if message["method"] != nil { onMessage(message) }
                if let wanted, (message["id"] as? NSNumber)?.intValue == wanted, message["method"] == nil {
                    answered = true; dataTask.cancel()
                }
            }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if failure == nil, error != nil, !answered {
                failure = MCPSession.Failure(message: (error as? URLError)?.code == .timedOut ? "The server did not answer in time." : "Could not reach the server: " + (error?.localizedDescription ?? ""))
            }
            done.signal()
        }
    }

    /// Every request to a remote MCP server or its sign-in goes through here (tests give a fake: no network).
    static var transport: (URLRequest, _ wanted: Int?, _ timeout: TimeInterval, _ onMessage: @escaping ([String: Any]) -> Void) throws -> Reply = live
    static func send(_ url: URL, method: String = "POST", headers: [String: String] = [:], body: Data? = nil, wanted: Int? = nil,
                     timeout: TimeInterval = 30, onMessage: @escaping ([String: Any]) -> Void = { _ in }) throws -> Reply {
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = min(timeout, 60)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try transport(request, wanted, timeout, onMessage)
    }
    /// The real one: no redirects, nothing kept, an SSE reply read as it comes and closed once `wanted` is answered.
    static func live(_ request: URLRequest, wanted: Int?, timeout: TimeInterval, onMessage: @escaping ([String: Any]) -> Void) throws -> Reply {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        let reader = Reader(wanted: wanted, onMessage: onMessage)
        let session = URLSession(configuration: configuration, delegate: reader, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        task.resume()
        guard reader.done.wait(timeout: .now() + timeout + 1) == .success else {
            task.cancel()
            throw MCPSession.Failure(message: "The server did not answer in time.")
        }
        if let failure = reader.failure { throw failure }
        guard let response = reader.response else { throw MCPSession.Failure(message: "No answer from the server.") }
        var names: [String: String] = [:]
        for (key, value) in response.allHeaderFields { if let key = key as? String { names[key.lowercased()] = "\(value)" } }
        var messages = reader.messages
        if !reader.sse, let one = try? JSONSerialization.jsonObject(with: reader.data) {
            messages = one as? [[String: Any]] ?? [one as? [String: Any]].compactMap { $0 }
        }
        return Reply(status: response.statusCode, headers: names, body: reader.data, messages: messages)
    }

    static func getJSON(_ url: URL, timeout: TimeInterval = 20) -> [String: Any]? {
        guard let reply = try? send(url, method: "GET", headers: ["Accept": "application/json"], timeout: timeout), reply.status == 200 else { return nil }
        return reply.json
    }

    /// `Bearer resource_metadata="…", scope="a b"` → its parameters, names in lower case.
    static func challenge(_ header: String?) -> [String: String] {
        guard let header, let space = header.firstIndex(of: " "), header[..<space].lowercased() == "bearer" else { return [:] }
        var fields: [String: String] = [:]
        var rest = Substring(header[header.index(after: space)...])
        while !rest.isEmpty {
            rest = rest.drop { $0 == " " || $0 == "," }
            guard let eq = rest.firstIndex(of: "=") else { break }
            let key = rest[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            rest = rest[rest.index(after: eq)...]
            var value = ""
            if rest.first == "\"" {
                rest = rest.dropFirst()
                var escaped = false
                while let c = rest.first {
                    rest = rest.dropFirst()
                    if escaped { value.append(c); escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { break } else { value.append(c) }
                }
            } else {
                let end = rest.firstIndex(of: ",") ?? rest.endIndex
                value = rest[..<end].trimmingCharacters(in: .whitespaces); rest = rest[end...]
            }
            fields[key] = value
        }
        return fields
    }
}

// MARK: Streamable HTTP session

// Modern servers (2026-07-28): every request carries its version in _meta and headers, no handshake, no session.
// Older Streamable HTTP servers (2025-03-26 … 2025-11-25): initialize, then Mcp-Session-Id. Which one is found by
// sending server/discover: a modern error (-32022 unsupported version) means modern, any other 4xx means older.
final class RemoteMCPSession: MCPConnection {
    struct LoginNeeded: Error { let message: String; let oauth: Bool }
    static var modern = ["2026-07-28"]          // newest first
    static let legacy = "2025-11-25"
    static let clientInfo: [String: Any] = ["name": "AI Illuminati", "version": "1"]

    let entry: MCPServerEntry
    private let url: URL
    private let lock = NSLock()
    private var version: String?                   // modern version in use
    private var legacyVersion: String?             // older servers: the negotiated version
    private var sessionID: String?
    private var closed = false
    private var nextID = 1
    private var headerParams: [String: [(path: [String], header: String)]] = [:]
    private(set) var loginNeeded: Bool?
    private var lastError = ""
    let listChanged = false

    init(entry: MCPServerEntry) {
        self.entry = entry
        url = URL(string: entry.url) ?? URL(string: "https://invalid.invalid")!
    }
    var isRunning: Bool { lock.locked { !closed } }
    var errorText: String { lock.locked { lastError } }
    var isModern: Bool { lock.locked { version != nil } }
    func close() { lock.locked { closed = true } }

    private func id() -> Int { lock.locked { defer { nextID += 1 }; return nextID } }

    // Fixed headers: the user's, then the OAuth token unless the user set Authorization themselves.
    private func fixedHeaders(refresh: Bool) throws -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in entry.headers {
            let real = value.isEmpty ? MCPSecrets.store.get(MCPSecrets.header(entry.name, name)) ?? "" : value
            if !real.isEmpty { headers[name] = real }
        }
        if !headers.keys.contains(where: { $0.lowercased() == "authorization" }), let token = try MCPOAuth.token(entry, refresh: refresh) {
            headers["Authorization"] = "Bearer " + token
        }
        return headers
    }

    private static func meta(_ version: String) -> [String: Any] {
        ["io.modelcontextprotocol/protocolVersion": version, "io.modelcontextprotocol/clientInfo": clientInfo,
         "io.modelcontextprotocol/clientCapabilities": [:] as [String: Any]]
    }

    /// One header value as the spec wants it: plain ASCII as is, anything else in the base64 sentinel.
    static func headerValue(_ text: String) -> String {
        let plain = text.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F } && text.trimmingCharacters(in: .whitespaces) == text
            && !(text.hasPrefix("=?base64?") && text.hasSuffix("?="))
        return plain ? text : "=?base64?" + Data(text.utf8).base64EncodedString() + "?="
    }

    /// One POST. `name` is the tool for tools/call. A 401 tries a fresh token once.
    private func post(_ method: String, _ params: [String: Any], name: String? = nil, extra: [String: String] = [:],
                      notification: Bool = false, timeout: TimeInterval, initialize: Bool = false) throws -> (MCPHTTP.Reply, Int?) {
        var refresh = false
        for _ in 0..<2 {
            let (modern, negotiated, session) = lock.locked { (version, legacyVersion, sessionID) }
            var params = params
            var headers = try fixedHeaders(refresh: refresh)
            headers["Content-Type"] = "application/json"
            headers["Accept"] = "application/json, text/event-stream"
            if let modern {
                params["_meta"] = (params["_meta"] as? [String: Any] ?? [:]).merging(Self.meta(modern)) { $1 }
                headers["MCP-Protocol-Version"] = modern
                headers["Mcp-Method"] = method
                if let name { headers["Mcp-Name"] = Self.headerValue(name) }
                for (key, value) in extra { headers[key] = value }
            } else if !initialize {
                if let negotiated { headers["MCP-Protocol-Version"] = negotiated }
                if let session { headers["Mcp-Session-Id"] = session }
            }
            let number = notification ? nil : id()
            var message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
            if let number { message["id"] = number }
            let body = try JSONSerialization.data(withJSONObject: message)
            let reply = try MCPHTTP.send(url, headers: headers, body: body, wanted: number, timeout: timeout) { [weak self] incoming in
                self?.answerServer(incoming)
            }
            if reply.status == 401, !refresh, MCPOAuth.signedIn(entry) { refresh = true; continue }
            if reply.status == 401 { throw login(reply) }
            return (reply, number)
        }
        throw MCPSession.Failure(message: "unreachable")
    }

    // Older servers may ask the client things on an SSE stream; this client offers none of them (ping is answered).
    private func answerServer(_ message: [String: Any]) {
        guard let id = message["id"], !(id is NSNull), let method = message["method"] as? String, !isModern else { return }
        let answer: [String: Any] = method == "ping" ? ["jsonrpc": "2.0", "id": id, "result": [:] as [String: Any]]
            : ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Not supported by AI Illuminati"]]
        DispatchQueue.global().async {
            var headers = (try? self.fixedHeaders(refresh: false)) ?? [:]
            headers["Content-Type"] = "application/json"; headers["Accept"] = "application/json, text/event-stream"
            let (negotiated, session) = self.lock.locked { (self.legacyVersion, self.sessionID) }
            if let negotiated { headers["MCP-Protocol-Version"] = negotiated }
            if let session { headers["Mcp-Session-Id"] = session }
            _ = try? MCPHTTP.send(self.url, headers: headers, body: try? JSONSerialization.data(withJSONObject: answer), timeout: 10)
        }
    }

    private func login(_ reply: MCPHTTP.Reply) -> LoginNeeded {
        let challenge = MCPHTTP.challenge(reply.header("WWW-Authenticate"))
        let oauth = challenge["resource_metadata"] != nil || MCPOAuth.protectedResource(entry, challenge: challenge) != nil
        lock.locked { loginNeeded = oauth; closed = true }
        return LoginNeeded(message: oauth ? L("로그인이 필요해요.", "Sign-in needed.")
                                          : L("이 서버는 API 키가 필요해요. 편집에서 Authorization 헤더를 넣어 주세요.", "This server needs an API key. Add an Authorization header under Edit."),
                           oauth: oauth)
    }

    private static func answer(_ reply: MCPHTTP.Reply, _ id: Int?) -> [String: Any]? {
        reply.messages.first { ($0["id"] as? NSNumber)?.intValue == id && $0["method"] == nil }
    }
    private static func errorCode(_ message: [String: Any]?) -> Int? { ((message?["error"] as? [String: Any])?["code"] as? NSNumber)?.intValue }

    private func failure(_ reply: MCPHTTP.Reply, _ message: [String: Any]?, _ fallback: String) -> MCPSession.Failure {
        if let text = (message?["error"] as? [String: Any])?["message"] as? String { return .init(message: text) }
        if (300...399).contains(reply.status), let location = reply.header("Location") {
            return .init(message: L("서버가 다른 주소로 보내요. 이 주소로 바꿔 주세요: ", "The server points elsewhere. Use this address: ") + location)
        }
        if reply.status == 403 { return .init(message: L("서버가 거절했어요 (403, 권한 부족).", "The server refused (403, not allowed).")) }
        return .init(message: fallback + " (HTTP \(reply.status))")
    }

    func open(timeout: TimeInterval) throws -> [[String: Any]] {
        do {
            if let problem = MCPServerEntry.urlProblem(entry.url) { throw MCPSession.Failure(message: problem) }
            try negotiate(timeout: timeout)
            return try listTools()
        } catch {
            lock.locked { lastError = (error as? MCPSession.Failure)?.message ?? (error as? LoginNeeded)?.message ?? error.localizedDescription }
            throw error
        }
    }

    private func negotiate(timeout: TimeInterval) throws {
        var offers = Self.modern
        while let offer = offers.first {
            offers.removeFirst()
            lock.locked { version = offer }
            let (reply, number) = try post("server/discover", [:], timeout: min(timeout, 30))
            let message = Self.answer(reply, number)
            if (200...299).contains(reply.status), let result = message?["result"] as? [String: Any] {
                let supported = result["supportedVersions"] as? [String] ?? [offer]
                if supported.contains(offer) { return }
                if let other = Self.modern.first(where: supported.contains) { lock.locked { version = other }; return }
                break   // only older versions: the handshake below
            }
            switch Self.errorCode(message) {
            case -32022:
                let supported = ((message?["error"] as? [String: Any])?["data"] as? [String: Any])?["supported"] as? [String] ?? []
                if let other = Self.modern.first(where: { supported.contains($0) && $0 != offer }) { offers = [other] + offers.filter { $0 != other }; continue }
                if supported.isEmpty || !supported.contains(where: { $0 <= Self.legacy }) {
                    throw MCPSession.Failure(message: L("서버가 이 앱의 MCP 버전을 지원하지 않아요: ", "The server does not support this app's MCP versions: ") + supported.joined(separator: ", "))
                }
            case -32020: throw failure(reply, message, "Header mismatch")
            default:
                if (300...399).contains(reply.status) || reply.status == 403 || reply.status >= 500 { throw failure(reply, message, L("서버 오류", "Server error")) }
            }
            break
        }
        lock.locked { version = nil }
        try initialize(timeout: timeout)
    }

    private func initialize(timeout: TimeInterval) throws {
        lock.locked { sessionID = nil; legacyVersion = nil }
        let hello: [String: Any] = ["protocolVersion": Self.legacy, "capabilities": [:] as [String: Any], "clientInfo": Self.clientInfo]
        let (reply, number) = try post("initialize", hello, timeout: min(timeout, 30), initialize: true)
        let message = Self.answer(reply, number)
        guard (200...299).contains(reply.status), let result = message?["result"] as? [String: Any] else {
            if [400, 404, 405].contains(reply.status) && message == nil {
                throw MCPSession.Failure(message: L("이 주소는 MCP 요청을 받지 않아요. 주소를 확인해 주세요 (옛 HTTP+SSE 서버는 아직 안 돼요).",
                                                    "This address takes no MCP requests. Check it (old HTTP+SSE servers are not supported yet).") + " (HTTP \(reply.status))")
            }
            throw failure(reply, message, L("서버가 응답하지 않았어요", "The server did not answer"))
        }
        lock.locked { legacyVersion = result["protocolVersion"] as? String ?? Self.legacy; sessionID = reply.header("Mcp-Session-Id") }
        _ = try? post("notifications/initialized", [:], notification: true, timeout: 10)
    }

    /// A request; an older server's session that expired (404) is started again once.
    private func request(_ method: String, _ params: [String: Any], name: String? = nil, extra: [String: String] = [:], timeout: TimeInterval) throws -> [String: Any] {
        for attempt in 0..<2 {
            let (reply, number) = try post(method, params, name: name, extra: extra, timeout: timeout)
            let message = Self.answer(reply, number)
            if reply.status == 404, attempt == 0, !isModern, lock.locked({ sessionID != nil }) {
                try initialize(timeout: 30); continue
            }
            if let result = message?["result"] as? [String: Any] {
                if result["resultType"] as? String == "input_required" {
                    throw MCPSession.Failure(message: "The server asked for user input (elicitation, sampling or roots), which AI Illuminati does not offer yet.")
                }
                return result
            }
            throw failure(reply, message, L("서버가 응답하지 않았어요", "The server did not answer"))
        }
        throw MCPSession.Failure(message: "unreachable")
    }

    func listTools() throws -> [[String: Any]] {
        var tools: [[String: Any]] = [], cursor: String?
        for _ in 0..<20 {
            let result = try request("tools/list", cursor.map { ["cursor": $0] } ?? [:], timeout: 30)
            tools += result["tools"] as? [[String: Any]] ?? []
            cursor = result["nextCursor"] as? String
            if cursor?.isEmpty ?? true { break }
        }
        // A tool whose x-mcp-header marks break the rules is left out (the spec says so for HTTP clients).
        var params: [String: [(path: [String], header: String)]] = [:]
        tools = tools.filter { tool in
            guard let name = tool["name"] as? String, let found = Self.headerParams(tool["inputSchema"]) else { return false }
            params[name] = found; return true
        }
        lock.locked { headerParams = params }
        return tools
    }

    /// The x-mcp-header marks of a schema, reachable through "properties" only; nil when one breaks the rules.
    static func headerParams(_ schema: Any?) -> [(path: [String], header: String)]? {
        var found: [(path: [String], header: String)] = [], total = 0
        func count(_ value: Any) {
            if let object = value as? [String: Any] {
                if object["x-mcp-header"] != nil { total += 1 }
                object.values.forEach(count)
            } else if let list = value as? [Any] { list.forEach(count) }
        }
        var valid = true
        func walk(_ schema: [String: Any], _ path: [String]) {
            for (key, value) in schema["properties"] as? [String: Any] ?? [:] {
                guard let property = value as? [String: Any] else { continue }
                if let header = property["x-mcp-header"] {
                    let type = property["type"] as? String
                    let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~").union(.alphanumerics)
                    if let header = header as? String, !header.isEmpty, header.unicodeScalars.allSatisfy({ $0.isASCII && token.contains($0) }),
                       ["string", "integer", "boolean"].contains(type ?? "") {
                        found.append((path + [key], header))
                    } else { valid = false }
                }
                walk(property, path + [key])
            }
        }
        guard let schema else { return [] }
        count(schema)
        if let object = schema as? [String: Any] { walk(object, []) }
        let names = found.map { $0.header.lowercased() }
        guard valid, total == found.count, Set(names).count == names.count else { return nil }
        return found
    }

    func call(_ tool: String, _ arguments: [String: Any], timeout: TimeInterval) -> [String: Any] {
        var extra: [String: String] = [:]
        for param in lock.locked({ headerParams[tool] ?? [] }) {
            var value: Any? = arguments
            for key in param.path { value = (value as? [String: Any])?[key] }
            guard let value, !(value is NSNull) else { continue }
            let text: String
            if let number = value as? NSNumber { text = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue }
            else { text = "\(value)" }
            extra["Mcp-Param-" + param.header] = Self.headerValue(text)
        }
        do { return try request("tools/call", ["name": tool, "arguments": arguments], name: tool, extra: extra, timeout: timeout) }
        catch let error as LoginNeeded { return mcpFailure("\(entry.name): " + error.message) }
        catch { return mcpFailure("\(entry.name): " + ((error as? MCPSession.Failure)?.message ?? error.localizedDescription)) }
    }
}

// MARK: OAuth 2.1 (PKCE S256, RFC 9728 → RFC 8414 / OIDC discovery, RFC 8707 resource, RFC 9207 iss)

// No domain of our own, so no client ID metadata document yet: like VS Code, register by DCR with a loopback
// redirect, or use a client ID the user typed. Tokens are bound to the server URL they were made for.
enum MCPOAuth {
    struct Saved: Codable {
        var serverURL: String
        var issuer: String
        var tokenEndpoint: String
        var resource: String
        var clientID: String
        var authMethod: String = "none"
        var redirect: String
        var registered: Bool = false
        var scope: String?
        var access: String?
        var refresh: String?
        var expires: Double?
    }
    static var openBrowser: (URL) -> Void = { url in DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
    static var preferredPort: UInt16 = 33421
    private static let lock = NSLock()

    static func saved(_ entry: MCPServerEntry) -> Saved? {
        guard let text = MCPSecrets.store.get(MCPSecrets.oauth(entry.name)), let saved = try? JSONDecoder().decode(Saved.self, from: Data(text.utf8)),
              saved.serverURL == entry.url else { return nil }   // a token is never sent to another address
        return saved
    }
    private static func store(_ saved: Saved, _ server: String) throws {
        try MCPSecrets.store.set(MCPSecrets.oauth(server), String(decoding: try JSONEncoder().encode(saved), as: UTF8.self))
    }
    static func signedIn(_ entry: MCPServerEntry) -> Bool { saved(entry)?.access != nil }

    /// The access token for a request (refreshed when it is about to run out); nil when not signed in.
    static func token(_ entry: MCPServerEntry, refresh force: Bool) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        guard var saved = saved(entry), let access = saved.access else { return nil }
        let fresh = (saved.expires ?? .infinity) - Date().timeIntervalSince1970 > 60
        if fresh && !force { return access }
        guard let refresh = saved.refresh, let endpoint = URL(string: saved.tokenEndpoint) else { return force ? nil : access }
        var fields = ["grant_type": "refresh_token", "refresh_token": refresh, "resource": saved.resource]
        if let scope = saved.scope { fields["scope"] = scope }
        let (status, json) = try tokenRequest(endpoint, fields, saved, server: entry.name)
        if status == 400 || status == 401 {   // refresh token gone: sign in again
            saved.access = nil; saved.refresh = nil; try? store(saved, entry.name)
            return nil
        }
        guard status == 200, let value = json["access_token"] as? String else { return access }
        saved.access = value
        if let rotated = json["refresh_token"] as? String { saved.refresh = rotated }
        saved.expires = (json["expires_in"] as? NSNumber).map { Date().timeIntervalSince1970 + $0.doubleValue }
        try store(saved, entry.name)
        return value
    }

    static func signOut(_ entry: MCPServerEntry) {
        lock.lock(); defer { lock.unlock() }
        guard var saved = saved(entry) else { return }
        saved.access = nil; saved.refresh = nil; saved.expires = nil
        try? store(saved, entry.name)
    }

    private static func tokenRequest(_ endpoint: URL, _ fields: [String: String], _ saved: Saved, server: String) throws -> (Int, [String: Any]) {
        var fields = fields
        fields["client_id"] = saved.clientID
        var headers = ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"]
        if saved.authMethod != "none", let secret = MCPSecrets.store.get(MCPSecrets.clientSecret(server)), !secret.isEmpty {
            if saved.authMethod == "client_secret_basic" {
                let pair = GoogleHTTP.encode(saved.clientID) + ":" + GoogleHTTP.encode(secret)
                headers["Authorization"] = "Basic " + Data(pair.utf8).base64EncodedString()
            } else { fields["client_secret"] = secret }
        }
        let reply = try MCPHTTP.send(endpoint, headers: headers, body: GoogleHTTP.form(fields), timeout: 30)
        return (reply.status, reply.json ?? [:])
    }

    /// The server's canonical URI for `resource`: no fragment, no trailing slash.
    static func canonical(_ text: String) -> String {
        var value = text
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
    private static func origin(_ url: URL) -> String {
        "\(url.scheme!.lowercased())://\(url.host!.lowercased())" + (url.port.map { ":\($0)" } ?? "")
    }
    private static func secure(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), MCPServerEntry.urlProblem(text) == nil else { return nil }
        return url
    }

    /// RFC 9728 metadata: the header's address, else the well-known path for the endpoint, then the root.
    static func protectedResource(_ entry: MCPServerEntry, challenge: [String: String]) -> [String: Any]? {
        guard let server = URL(string: entry.url), server.host != nil else { return nil }
        var candidates: [URL] = []
        if let given = secure(challenge["resource_metadata"]) { candidates = [given] }
        else {
            let path = server.path == "/" ? "" : server.path
            if !path.isEmpty, let url = URL(string: origin(server) + "/.well-known/oauth-protected-resource" + path) { candidates.append(url) }
            candidates.append(URL(string: origin(server) + "/.well-known/oauth-protected-resource")!)
        }
        for url in candidates {
            guard let json = MCPHTTP.getJSON(url), json["authorization_servers"] is [String] else { continue }
            // The document must be about this server.
            if let resource = json["resource"] as? String, let target = URL(string: resource), target.host != nil, origin(target) != origin(server) { continue }
            return json
        }
        return nil
    }

    /// RFC 8414 / OIDC metadata in the spec's order; its issuer must be exactly the one asked for.
    static func authorizationServer(_ issuer: String) -> [String: Any]? {
        guard let url = URL(string: issuer), url.host != nil else { return nil }
        let base = origin(url), path = url.path == "/" ? "" : canonical(url.path)
        let candidates = path.isEmpty
            ? [base + "/.well-known/oauth-authorization-server", base + "/.well-known/openid-configuration"]
            : [base + "/.well-known/oauth-authorization-server" + path, base + "/.well-known/openid-configuration" + path, base + path + "/.well-known/openid-configuration"]
        for candidate in candidates {
            guard let address = URL(string: candidate), let json = MCPHTTP.getJSON(address), json["issuer"] as? String == issuer else { continue }
            return json
        }
        return nil
    }

    private static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }
    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func fail(_ text: String) -> MCPSession.Failure { .init(message: text) }
    // The usual port first, so a registered redirect stays the same; any free port if it is taken.
    private static func newLoopback() throws -> OAuthCallback {
        if let fixed = try? GoogleLoopback.make(preferredPort, "MCP") { return fixed }
        return try GoogleLoopback.make(0, "MCP")
    }

    /// The whole sign-in, off the main thread: find the servers, get a client, open the browser, wait for the
    /// loopback, trade the code. `completion` runs once, on any thread.
    static func signIn(_ entry: MCPServerEntry, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do { try run(entry); completion(.success(())) } catch { completion(.failure(error)) }
        }
    }

    private static func run(_ entry: MCPServerEntry) throws {
        guard let server = URL(string: entry.url), MCPServerEntry.urlProblem(entry.url) == nil else { throw fail(L("주소가 올바르지 않아요.", "The address is not valid.")) }
        // The challenge from an unauthenticated request says where the metadata is and which scope is needed.
        let probe = try? MCPHTTP.send(server, headers: ["Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                                                         "MCP-Protocol-Version": RemoteMCPSession.modern[0], "Mcp-Method": "server/discover"],
                                      body: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "server/discover", "params": ["_meta": [
                                        "io.modelcontextprotocol/protocolVersion": RemoteMCPSession.modern[0],
                                        "io.modelcontextprotocol/clientInfo": RemoteMCPSession.clientInfo,
                                        "io.modelcontextprotocol/clientCapabilities": [:] as [String: Any]]]]), timeout: 20)
        let challenge = MCPHTTP.challenge(probe?.header("WWW-Authenticate"))
        guard let resourceMeta = protectedResource(entry, challenge: challenge),
              let issuer = (resourceMeta["authorization_servers"] as? [String])?.first(where: { secure($0) != nil }) else {
            throw fail(L("이 서버의 로그인 정보를 찾지 못했어요. API 키가 필요한 서버면 편집에서 헤더를 넣어 주세요.",
                         "Could not find how this server signs in. If it needs an API key, add a header under Edit."))
        }
        guard let meta = authorizationServer(issuer),
              let authorize = secure(meta["authorization_endpoint"] as? String), let tokenURL = secure(meta["token_endpoint"] as? String) else {
            throw fail(L("로그인 서버 정보를 읽지 못했어요: ", "Could not read the sign-in server's metadata: ") + issuer)
        }
        if let methods = meta["code_challenge_methods_supported"] as? [String], !methods.contains("S256") {
            throw fail(L("로그인 서버가 PKCE(S256)를 지원하지 않아 연결하지 않아요.", "The sign-in server does not support PKCE (S256), so it is not used."))
        }
        let resource = canonical(resourceMeta["resource"] as? String ?? entry.url)
        let previous: Saved? = {
            guard let text = MCPSecrets.store.get(MCPSecrets.oauth(entry.name)) else { return nil }
            return try? JSONDecoder().decode(Saved.self, from: Data(text.utf8))
        }()

        // The client: one the user typed, the one registered before with this issuer, or a new DCR registration.
        var client: (id: String, method: String, redirectPort: UInt16, registered: Bool)
        var loopback: OAuthCallback
        if !entry.oauthClientID.isEmpty {
            loopback = try newLoopback()
            let secret = MCPSecrets.store.get(MCPSecrets.clientSecret(entry.name)) ?? ""
            let methods = meta["token_endpoint_auth_methods_supported"] as? [String] ?? []
            client = (entry.oauthClientID, secret.isEmpty ? "none" : methods.contains("client_secret_post") || methods.isEmpty ? "client_secret_post" : "client_secret_basic", 0, false)
        } else if let previous, previous.registered, previous.issuer == issuer, let port = URL(string: previous.redirect)?.port,
                  let reused = try? GoogleLoopback.make(UInt16(port), "MCP") {
            loopback = reused
            client = (previous.clientID, previous.authMethod, UInt16(port), true)
        } else {
            guard let register = secure(meta["registration_endpoint"] as? String) else {
                throw fail(L("이 서버는 자동 등록(DCR)을 지원하지 않아요. 서버에서 받은 client ID를 편집 → 고급에 넣어 주세요.",
                             "This server has no automatic registration (DCR). Put the client ID it gave you under Edit → Advanced."))
            }
            loopback = try newLoopback()
            let body: [String: Any] = ["client_name": "AI Illuminati", "redirect_uris": [loopback.redirect], "application_type": "native",
                                       "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"], "token_endpoint_auth_method": "none"]
            let reply = try MCPHTTP.send(register, headers: ["Content-Type": "application/json", "Accept": "application/json"],
                                         body: try JSONSerialization.data(withJSONObject: body), timeout: 30)
            guard (200...299).contains(reply.status), let json = reply.json, let id = json["client_id"] as? String, !id.isEmpty else {
                loopback.cancel()
                throw fail(L("자동 등록(DCR)이 실패했어요. 서버에서 받은 client ID를 편집 → 고급에 넣어 주세요.", "Automatic registration (DCR) failed. Put a client ID under Edit → Advanced.") + " (HTTP \(reply.status))")
            }
            if let secret = json["client_secret"] as? String { try MCPSecrets.store.set(MCPSecrets.clientSecret(entry.name), secret) }
            client = (id, json["client_secret"] == nil ? "none" : json["token_endpoint_auth_method"] as? String ?? "client_secret_basic", 0, true)
        }

        // Scope: the challenge's, else what the resource lists (plus offline_access when the server knows it).
        var scopes = (challenge["scope"] ?? (resourceMeta["scopes_supported"] as? [String])?.joined(separator: " ") ?? "").split(separator: " ").map(String.init)
        if !scopes.isEmpty, (meta["scopes_supported"] as? [String])?.contains("offline_access") == true, !scopes.contains("offline_access") { scopes.append("offline_access") }
        let scope = scopes.isEmpty ? nil : scopes.joined(separator: " ")
        let state = random(), verifier = random()
        var address = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!
        var query = address.queryItems ?? []
        var items = ["response_type": "code", "client_id": client.id, "redirect_uri": loopback.redirect, "state": state,
                     "code_challenge": base64url(Data(SHA256.hash(data: Data(verifier.utf8)))), "code_challenge_method": "S256", "resource": resource]
        if let scope { items["scope"] = scope }
        query += items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        address.queryItems = query
        guard let link = address.url else { loopback.cancel(); throw fail("Could not build the sign-in address.") }

        let done = DispatchSemaphore(value: 0)
        var fields: Result<[String: String], Error> = .failure(fail("MCP sign-in was cancelled."))
        loopback.start { fields = $0; done.signal() }
        openBrowser(link)
        done.wait()
        let answer = try fields.get()
        // RFC 9207: a present iss must be this issuer; a server that promises iss must send it.
        if let iss = answer["iss"], iss != issuer { throw fail(L("로그인 응답의 발급자가 달라요. 연결하지 않았어요.", "The sign-in answer came from another issuer. Not connected.")) }
        if answer["iss"] == nil, meta["authorization_response_iss_parameter_supported"] as? Bool == true { throw fail(L("로그인 응답에 발급자(iss)가 없어요.", "The sign-in answer has no issuer (iss).")) }
        guard answer["state"] == state else { throw fail(L("로그인 응답이 이 요청과 맞지 않아요. 다시 시도해 주세요.", "The sign-in answer does not match. Try again.")) }
        if let error = answer["error"] { throw fail(L("로그인이 거절되었어요: ", "Sign-in was refused: ") + error) }
        guard let code = answer["code"], !code.isEmpty else { throw fail(L("로그인 응답에 코드가 없어요.", "The sign-in answer has no code.")) }

        var saved = Saved(serverURL: entry.url, issuer: issuer, tokenEndpoint: tokenURL.absoluteString, resource: resource, clientID: client.id,
                          authMethod: client.method, redirect: loopback.redirect, registered: client.registered, scope: scope)
        let (status, json) = try tokenRequest(tokenURL, ["grant_type": "authorization_code", "code": code, "redirect_uri": loopback.redirect,
                                                          "code_verifier": verifier, "resource": resource], saved, server: entry.name)
        guard status == 200, let access = json["access_token"] as? String, !access.isEmpty else {
            throw fail(L("토큰을 받지 못했어요", "Could not get a token") + " (HTTP \(status)" + ((json["error"] as? String).map { ", " + $0 } ?? "") + ")")
        }
        saved.access = access
        saved.refresh = json["refresh_token"] as? String
        saved.expires = (json["expires_in"] as? NSNumber).map { Date().timeIntervalSince1970 + $0.doubleValue }
        if let granted = json["scope"] as? String { saved.scope = granted }
        lock.lock(); defer { lock.unlock() }
        try store(saved, entry.name)
    }
}

extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
