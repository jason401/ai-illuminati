import Foundation
import Darwin

// MCP servers the user adds in Settings → MCP (stdio only, like Claude desktop's config). They are kept in
// mcp-servers.json, not in mcp.json: AI Face writes that file, and two writers of one file lose each other's
// changes. The app itself runs each server it is switched on for (as the user, outside the CLI sandbox, like
// Claude desktop) and offers its tools through ToolHub to plain chat and project work, never to Enterprise
// chats. A tool is named "<server>__<tool>"; server names have no "_", so the name is unambiguous, and the app
// keeps an explicit map from that name back to the server and its own tool name.
struct MCPServerEntry: Equatable, Identifiable {
    var name: String
    var command: String
    var args: [String] = []
    var env: [String: String] = [:]
    var id: String { name }

    static let reserved: Set<String> = ["ai-face", "illuminati", "google-drive"]
    static let maxName = 16, maxTool = 47   // "mcp__illuminati__" + name stays within 64 characters

    /// A valid server name from what the user typed: lower case, letters, digits and "-".
    static func normalized(_ raw: String) -> String {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mapped = lower.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        var name = String(mapped)
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(name.prefix(maxName)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
    static func validName(_ name: String) -> Bool { !name.isEmpty && normalized(name) == name && !reserved.contains(name) }

    init(name: String, command: String, args: [String] = [], env: [String: String] = [:]) {
        self.name = name; self.command = command; self.args = args; self.env = env
    }
    /// One entry of a Claude-desktop-style "mcpServers" object; nil for remote (url) servers.
    init?(name: String, json: [String: Any]) {
        guard let command = json["command"] as? String, !command.isEmpty else { return nil }
        self.name = name
        self.command = command
        args = (json["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        env = (json["env"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
    }
    var json: [String: Any] { ["command": command, "args": args, "env": env] }

    /// Servers from pasted JSON: {"mcpServers": {...}}, {"name": {...}} or one {"command": ...}.
    static func parse(_ text: String) -> [MCPServerEntry] {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\""), !trimmed.hasPrefix("{") { trimmed = "{" + trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ",")) + "}" }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] else { return [] }
        if object["command"] is String { return MCPServerEntry(name: "", json: object).map { [$0] } ?? [] }
        let servers = object["mcpServers"] as? [String: Any] ?? object
        return servers.keys.sorted().compactMap { key in (servers[key] as? [String: Any]).flatMap { MCPServerEntry(name: normalized(key), json: $0) } }
    }

    /// A typed command line split into words (quotes and backslashes like a shell, nothing run).
    static func words(_ line: String) -> [String] {
        var words: [String] = [], current = "", quote: Character?, escaped = false, started = false
        for c in line {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\" && quote != "'" { escaped = true; started = true; continue }
            if let q = quote { if c == q { quote = nil } else { current.append(c) }; continue }
            if c == "\"" || c == "'" { quote = c; started = true; continue }
            if c.isWhitespace { if started { words.append(current); current = ""; started = false }; continue }
            current.append(c); started = true
        }
        if started { words.append(current) }
        return words
    }
}

// One stdio MCP session: JSON-RPC lines on stdin/stdout. Replies are matched by id, so calls may overlap; a
// request from the server is answered "not supported" (ping is answered), notifications are read and dropped
// except tools/list_changed. stderr keeps its last lines to show why a server failed.
final class MCPSession {
    struct Failure: Error { let message: String }
    let entry: MCPServerEntry
    private let process = Process()
    private var input: FileHandle?
    private let lock = NSLock(), writeLock = NSLock()
    private var buffer = Data(), errors = Data()
    private var waiting: [Int: DispatchSemaphore] = [:]
    private var replies: [Int: [String: Any]] = [:]
    private var nextID = 1
    private(set) var listChanged = false
    static let maxLine = 16 << 20

    init(entry: MCPServerEntry) { self.entry = entry }
    var isRunning: Bool { process.isRunning }
    var errorText: String {
        lock.lock(); defer { lock.unlock() }
        let text = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(separator: "\n").suffix(3).joined(separator: "\n")
    }

    // GUI apps start with a short PATH; npx, uvx and docker usually live in these folders.
    static func searchPath(_ env: [String: String]) -> String {
        let home = AccountStore.home
        let base = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.cargo/bin", home + "/.volta/bin",
                    "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return ([env["PATH"]].compactMap { $0 } + base).joined(separator: ":")
    }
    static func resolve(_ command: String, path: String) -> String? {
        if command.contains("/") {
            let full = (command as NSString).expandingTildeInPath
            return full.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: full) ? full : nil
        }
        return path.split(separator: ":").map { "\($0)/\(command)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    // Only what a command-line tool needs, not the app's whole environment; then the server's own variables.
    static func environment(_ entry: MCPServerEntry) -> [String: String] {
        let own = ProcessInfo.processInfo.environment
        var env: [String: String] = ["HOME": AccountStore.home]
        for key in ["USER", "LOGNAME", "LANG", "TMPDIR", "SHELL"] { if let value = own[key] { env[key] = value } }
        for (key, value) in entry.env { env[key] = value }
        env["PATH"] = searchPath(entry.env)
        return env
    }

    /// Starts the server, says hello and returns its tools. The first start of an npx server may download it.
    func open(timeout: TimeInterval = 60) throws -> [[String: Any]] {
        let env = Self.environment(entry)
        guard let path = Self.resolve(entry.command, path: env["PATH"] ?? "") else {
            throw Failure(message: L("명령을 찾을 수 없어요: ", "Command not found: ") + entry.command)
        }
        let toChild = Pipe(), fromChild = Pipe(), errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = entry.args
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: AccountStore.home)
        process.standardInput = toChild; process.standardOutput = fromChild; process.standardError = errorPipe
        fromChild.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.received(data)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            guard let self else { return }
            self.lock.lock(); self.errors.append(data); if self.errors.count > 4096 { self.errors = self.errors.suffix(4096) }; self.lock.unlock()
        }
        process.terminationHandler = { [weak self] _ in self?.wakeAll() }
        do { try process.run() } catch { throw Failure(message: error.localizedDescription) }
        input = toChild.fileHandleForWriting
        let hello: [String: Any] = ["protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
                                    "clientInfo": ["name": "AI Illuminati", "version": "1"]]
        let reply = request("initialize", hello, timeout: timeout)
        guard reply?["result"] is [String: Any] else { throw failure(reply, L("서버가 응답하지 않았어요", "The server did not answer")) }
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        return try listTools()
    }

    func listTools() throws -> [[String: Any]] {
        lock.lock(); listChanged = false; lock.unlock()
        var tools: [[String: Any]] = [], cursor: String?
        for _ in 0..<20 {
            let reply = request("tools/list", cursor.map { ["cursor": $0] } ?? [:], timeout: 30)
            guard let result = reply?["result"] as? [String: Any] else { throw failure(reply, L("도구 목록을 받지 못했어요", "Could not list the tools")) }
            tools += result["tools"] as? [[String: Any]] ?? []
            cursor = result["nextCursor"] as? String
            if cursor?.isEmpty ?? true { break }
        }
        return tools
    }

    /// One tool call as an MCP tool result ({content, isError}).
    func call(_ tool: String, _ arguments: [String: Any], timeout: TimeInterval) -> [String: Any] {
        let reply = request("tools/call", ["name": tool, "arguments": arguments], timeout: timeout)
        if let result = reply?["result"] as? [String: Any] { return result }
        return ToolHub.failure((failure(reply, "\(entry.name) did not answer in time")).message)
    }

    func close() {
        input.map { try? $0.close() }
        if process.isRunning { process.terminate() }
        wakeAll()
    }

    private func failure(_ reply: [String: Any]?, _ fallback: String) -> Failure {
        if let message = (reply?["error"] as? [String: Any])?["message"] as? String { return Failure(message: message) }
        let tail = errorText
        return Failure(message: tail.isEmpty ? fallback : fallback + "\n" + tail)
    }

    private func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        guard process.isRunning else { return nil }
        let signal = DispatchSemaphore(value: 0)
        lock.lock(); let id = nextID; nextID += 1; waiting[id] = signal; lock.unlock()
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let answered = signal.wait(timeout: .now() + timeout) == .success
        lock.lock(); waiting[id] = nil; let reply = replies.removeValue(forKey: id); lock.unlock()
        if !answered && reply == nil && process.isRunning {
            send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": id, "reason": "timeout"]])
        }
        return reply
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        writeLock.lock(); defer { writeLock.unlock() }
        do { try input?.write(contentsOf: data + Data([0x0A])) } catch { }
    }

    private func received(_ data: Data) {
        var messages: [[String: Any]] = []
        lock.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { messages.append(message) }
        }
        let tooLong = buffer.count > Self.maxLine
        lock.unlock()
        if tooLong { close(); return }   // a runaway line: the server is stopped, not the app's memory
        for message in messages { handle(message) }
    }

    private func handle(_ message: [String: Any]) {
        let method = message["method"] as? String
        if let id = message["id"], !(id is NSNull), let method {
            // A request from the server (sampling, roots, elicitation …): this client offers none of them.
            let answer: [String: Any] = method == "ping" ? ["jsonrpc": "2.0", "id": id, "result": [:] as [String: Any]]
                : ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Not supported by AI Illuminati"]]
            send(answer)
        } else if let id = (message["id"] as? NSNumber)?.intValue {
            lock.lock()
            if let signal = waiting[id] { replies[id] = message; signal.signal() }
            lock.unlock()
        } else if method == "notifications/tools/list_changed" {
            lock.lock(); listChanged = true; lock.unlock()
        }
    }

    private func wakeAll() {
        lock.lock(); let all = waiting.values; lock.unlock()
        all.forEach { $0.signal() }
    }
}

final class ExternalMCP: ObservableObject, ToolProvider {
    enum State: Equatable { case off, connecting, connected, failed }
    struct Status: Equatable {
        var state: State
        var tools: [String] = []
        var skipped: [String] = []
        var message: String? = nil
    }

    static let shared = ExternalMCP()
    static var file: URL { URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("mcp-servers.json") }
    static var claudeDesktopFile: URL { URL(fileURLWithPath: AccountStore.home).appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json") }
    static var callTimeout: TimeInterval = 120
    static var retryAfter: TimeInterval = 30
    // Enterprise chats get no outside servers (their data would leave through tools the user did not pick for them).
    static var isEnterprise: (UUID) -> Bool = { room in
        let look = { ChatLink.shared.conversations().first { $0.id == room }?.isEnterprise ?? false }
        return Thread.isMainThread ? look() : DispatchQueue.main.sync(execute: look)
    }

    @Published private(set) var servers: [MCPServerEntry] = []
    @Published private(set) var status: [String: Status] = [:]
    @Published private(set) var loadError: String?

    private let lock = NSLock()
    private let work = DispatchQueue(label: "external-mcp")
    private var sessions: [String: MCPSession] = [:]
    private var lists: [String: [[String: Any]]] = [:]
    private var connecting: Set<String> = []
    private var failures: [String: (String, Date)] = [:]
    private var known: [MCPServerEntry] = []
    private var offered: [[String: Any]] = []
    private var routes: [String: (server: String, tool: String)] = [:]
    private var timer: Timer?

    // MARK: Settings (mcp-servers.json; the on/off switch is the shared "mcpOff" list)

    static func isOn(_ name: String) -> Bool { !(UserDefaults.app.stringArray(forKey: "mcpOff") ?? []).contains(name) }
    func setOn(_ name: String, _ on: Bool) {
        setOff(name, !on)
        refresh(force: on ? [name] : [])
    }
    private func setOff(_ name: String, _ off: Bool) {
        var list = Set(UserDefaults.app.stringArray(forKey: "mcpOff") ?? [])
        if off { list.insert(name) } else { list.remove(name) }
        UserDefaults.app.set(list.sorted(), forKey: "mcpOff")
    }

    /// The saved servers; a file that cannot be read is an error and is never rewritten.
    static func read() -> (object: [String: Any], servers: [MCPServerEntry], error: String?) {
        guard let data = try? Data(contentsOf: file) else {
            return FileManager.default.fileExists(atPath: file.path) ? ([:], [], L("mcp-servers.json을 읽을 수 없어요.", "Cannot read mcp-servers.json.")) : ([:], [], nil)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["mcpServers"] == nil || object["mcpServers"] is [String: Any] else {
            return ([:], [], L("mcp-servers.json이 깨져 있어요. 고치거나 지우기 전엔 바꾸지 않아요.", "mcp-servers.json is damaged. Nothing is changed until it is fixed or removed."))
        }
        let raw = object["mcpServers"] as? [String: Any] ?? [:]
        let servers = raw.keys.sorted().compactMap { key -> MCPServerEntry? in
            guard MCPServerEntry.validName(key), let json = raw[key] as? [String: Any] else { return nil }
            return MCPServerEntry(name: key, json: json)
        }
        return (object, servers, nil)
    }

    /// Adds or replaces one server (renaming keeps its switch). Other entries and unknown fields stay as they are.
    func save(_ entry: MCPServerEntry, replacing old: String? = nil, on: Bool = true) throws {
        guard MCPServerEntry.validName(entry.name) else { throw MCPSession.Failure(message: L("이름은 영어 소문자·숫자·-만, 16자까지예요.", "Names use lower-case letters, digits and -, up to 16.")) }
        guard !entry.command.trimmingCharacters(in: .whitespaces).isEmpty else { throw MCPSession.Failure(message: L("실행할 명령을 적어 주세요.", "Enter the command to run.")) }
        // An entry saved switched off is marked off before it is written, so no refresh in between starts it.
        let wasOn = old.map(Self.isOn) ?? on
        let markedOff = !wasOn && Self.isOn(entry.name)
        if markedOff { setOff(entry.name, true) }
        do { try lock.locked {
            let current = Self.read()
            if let error = current.error { throw MCPSession.Failure(message: error) }
            var object = current.object, raw = object["mcpServers"] as? [String: Any] ?? [:]
            if entry.name != old, raw[entry.name] != nil { throw MCPSession.Failure(message: L("같은 이름의 서버가 이미 있어요.", "A server with this name already exists.")) }
            var json = (old.flatMap { raw[$0] } ?? raw[entry.name]) as? [String: Any] ?? [:]
            for (key, value) in entry.json { json[key] = value }
            if let old, old != entry.name { raw[old] = nil }
            raw[entry.name] = json
            object["mcpServers"] = raw
            try Self.write(object)
        } } catch { if markedOff { setOff(entry.name, false) }; throw error }
        if let old, old != entry.name { setOn(old, true) }   // no stale "off" left for a name that is gone
        setOn(entry.name, wasOn)
        refresh(force: [entry.name])
    }

    func remove(_ name: String) throws {
        try lock.locked {
            let current = Self.read()
            if let error = current.error { throw MCPSession.Failure(message: error) }
            var object = current.object, raw = object["mcpServers"] as? [String: Any] ?? [:]
            raw[name] = nil
            object["mcpServers"] = raw
            try Self.write(object)
        }
        setOn(name, true)
    }

    /// Claude desktop's stdio servers not added here yet (remote ones cannot run here).
    static func claudeDesktopServers(existing: [MCPServerEntry]) -> [MCPServerEntry] {
        guard let data = try? Data(contentsOf: claudeDesktopFile) else { return [] }
        let names = Set(existing.map(\.name)).union(MCPServerEntry.reserved)
        let commands = Set(existing.map { [$0.command] + $0.args })
        return MCPServerEntry.parse(String(decoding: data, as: UTF8.self)).filter {
            MCPServerEntry.validName($0.name) && !names.contains($0.name) && !commands.contains([$0.command] + $0.args)
        }
    }

    /// Adds them switched off: the user turns on each one after looking at it.
    func importClaudeDesktop() -> Int {
        var added = 0
        for entry in Self.claudeDesktopServers(existing: servers) where (try? save(entry, on: false)) != nil { added += 1 }
        return added
    }

    private static func write(_ object: [String: Any]) throws {
        var object = object
        object["version"] = object["version"] ?? 1
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Environment values may hold tokens: owner-only from the first byte, then swapped in whole.
        let temporary = folder.appendingPathComponent(".mcp-servers-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw MCPSession.Failure(message: L("mcp-servers.json을 저장하지 못했어요.", "Could not save mcp-servers.json."))
        }
        guard Darwin.rename(temporary.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw MCPSession.Failure(message: L("mcp-servers.json을 저장하지 못했어요.", "Could not save mcp-servers.json."))
        }
    }

    // MARK: Connections

    /// Connects the servers that are switched on, now and every 30 seconds (a server that quit comes back).
    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// force: these servers try again at once instead of waiting after a failure.
    func refresh(force: Set<String> = []) { work.async { self.update(force: force) } }
    /// For tests and the Settings button: waits until the current round of connecting is over.
    func refreshAndWait(force: Set<String> = [], timeout: TimeInterval = 30) {
        work.sync { update(force: force) }
        let deadline = Date().addingTimeInterval(timeout)
        while lock.locked({ !connecting.isEmpty }), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    }

    /// Settings → Reconnect: a fresh start of one server, also right after a failure.
    func reconnect(_ name: String) {
        lock.locked { sessions[name]?.close(); sessions[name] = nil; lists[name] = nil; rebuild() }
        refresh(force: [name])
    }

    private func update(force: Set<String>) {
        let current = Self.read()
        let wanted = Dictionary(uniqueKeysWithValues: current.servers.filter { Self.isOn($0.name) }.map { ($0.name, $0) })
        var start: [MCPServerEntry] = [], relist: [MCPSession] = []
        lock.locked {
            known = current.servers
            for (name, session) in sessions where wanted[name] != session.entry || !session.isRunning {
                if !session.isRunning, wanted[name] == session.entry {
                    let text = session.errorText
                    failures[name] = (L("서버가 꺼졌어요", "The server stopped") + (text.isEmpty ? "" : "\n" + text), Date())
                }
                session.close(); sessions[name] = nil; lists[name] = nil
            }
            for name in failures.keys where wanted[name] == nil || force.contains(name) { failures[name] = nil }
            for entry in wanted.values where sessions[entry.name] == nil && !connecting.contains(entry.name) {
                if let failed = failures[entry.name], Date().timeIntervalSince(failed.1) < Self.retryAfter { continue }
                connecting.insert(entry.name); start.append(entry)
            }
            relist = sessions.values.filter { $0.listChanged }
            rebuild()
        }
        publish(error: current.error)
        for entry in start { DispatchQueue.global().async { self.connect(entry) } }
        for session in relist {
            DispatchQueue.global().async {
                guard let tools = try? session.listTools() else { return }
                self.lock.locked { if self.sessions[session.entry.name] === session { self.lists[session.entry.name] = tools; self.rebuild() } }
                self.publish()
            }
        }
    }

    private func connect(_ entry: MCPServerEntry) {
        let session = MCPSession(entry: entry)
        let result = Result { try session.open() }
        lock.locked {
            connecting.remove(entry.name)
            // Switched off, edited or removed while it started: this session is not used.
            let still = Self.isOn(entry.name) && Self.read().servers.contains(entry)
            switch result {
            case .success(let tools) where still && session.isRunning:
                sessions[entry.name] = session; lists[entry.name] = tools; failures[entry.name] = nil
            case .success: session.close()
            case .failure(let error):
                session.close()
                if still { failures[entry.name] = ((error as? MCPSession.Failure)?.message ?? error.localizedDescription, Date()) }
            }
            rebuild()
        }
        publish()
    }

    // Under `lock`. The tools as the models see them, and the map back to each server's own name.
    private var skipped: [String: [String]] = [:]
    private func rebuild() {
        var offered: [[String: Any]] = [], routes: [String: (server: String, tool: String)] = [:]
        skipped = [:]
        for name in lists.keys.sorted() {
            for tool in lists[name] ?? [] {
                guard let own = tool["name"] as? String, !own.isEmpty else { continue }
                let safe = String(own.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
                let full = name + "__" + safe
                guard full.count <= MCPServerEntry.maxTool, routes[full] == nil else { skipped[name, default: []].append(own); continue }
                var copy = tool
                copy["name"] = full
                copy["description"] = "[\(name) MCP server] " + (tool["description"] as? String ?? "")
                if !(copy["inputSchema"] is [String: Any]) { copy["inputSchema"] = ["type": "object"] }
                offered.append(copy)
                routes[full] = (name, own)
            }
        }
        self.offered = offered; self.routes = routes
    }

    private func publish(error: String?? = nil) {
        let (servers, snapshot): ([MCPServerEntry], [String: Status]) = lock.locked {
            var all: [String: Status] = [:]
            for entry in known {
                let name = entry.name
                if !Self.isOn(name) { all[name] = Status(state: .off) }
                else if let session = sessions[name], session.isRunning {
                    all[name] = Status(state: .connected, tools: (lists[name] ?? []).compactMap { $0["name"] as? String }, skipped: skipped[name] ?? [])
                } else if let failed = failures[name] { all[name] = Status(state: .failed, message: failed.0) }
                else { all[name] = Status(state: .connecting) }
            }
            return (known, all)
        }
        DispatchQueue.main.async {
            if self.servers != servers { self.servers = servers }
            if let error { self.loadError = error }
            self.status = snapshot
        }
    }

    // MARK: ToolProvider (reads only the snapshot: never waits on a server that is starting or busy)

    var active: Bool { lock.locked { !offered.isEmpty } }
    func tools() -> [[String: Any]] { lock.locked { offered } }
    func tools(context: ToolContext) -> [[String: Any]] {
        let list = tools()
        return list.isEmpty || Self.isEnterprise(context.room) ? [] : list
    }
    var slowTools: [String] { lock.locked { Array(routes.keys) } }

    func call(_ name: String, _ arguments: [String: Any], context: ToolContext) -> [String: Any] {
        guard !Self.isEnterprise(context.room) else { return ToolHub.failure("Outside MCP servers are not available in Enterprise chats.") }
        let (route, session) = lock.locked { () -> ((server: String, tool: String)?, MCPSession?) in
            let route = routes[name]
            return (route, route.flatMap { sessions[$0.server] })
        }
        guard let route, Self.isOn(route.server), let session, session.isRunning else {
            return ToolHub.failure("This MCP server is switched off or not connected: " + name)
        }
        return session.call(route.tool, arguments, timeout: Self.callTimeout)
    }

    /// Stops every server (tests, app exit).
    func stopAll() {
        lock.locked {
            sessions.values.forEach { $0.close() }
            sessions = [:]; lists = [:]; failures = [:]; rebuild()
        }
    }
}

private extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
