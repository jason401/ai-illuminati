import Foundation
import Darwin
import AIAccounts

// AI Face (a separate menu bar app) shows a face for each AI reply. AI Illuminati connects to it the way
// Claude desktop and ChatGPT desktop do: the app itself is AI Face's MCP client and keeps one connection
// open while it runs, as "illuminati". AI Face writes its server into mcp.json here when the user clicks
// Connect (and removes it on Disconnect). The face for each plain-chat reply is chosen by the model that
// wrote it, as a hidden <face>mood</face> tag at the end; the app removes the tag and sets the face itself
// (no tool call: cheaper, and models skipped the call in long chats). Which model answers stays inside AI Illuminati: the per-answer
// workspace bridge (workspace_mcp.py) offers AI Face's tools to whichever model it serves and hands each
// call to the app over a local socket. Like the ChatGPT app, AI Illuminati passes every tool on and only
// turns the whole server on or off (Settings → Chat); AI Face decides per AI which tools work (calendar,
// mail, folders). The agreement between the two apps is docs/AI_FACE.md.
final class FaceLink: ObservableObject {
    struct Server: Equatable { var command: String; var args: [String] }

    static let shared = FaceLink()
    static let name = "ai-face", agent = "illuminati"
    static var file = URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("mcp.json")
    // The server must be AI Face's own file; anything else in mcp.json is ignored.
    static var faceFolder = AccountStore.home + "/Library/Application Support/AI Face"
    static var socketPath = AccountStore.supportDir + "/face.sock"

    // The on/off switch per server (only AI Face for now). Off servers are listed in UserDefaults "mcpOff".
    static var isOn: Bool { !(UserDefaults.app.stringArray(forKey: "mcpOff") ?? []).contains(name) }
    static func active() -> Server? { isOn ? server() : nil }

    @Published private(set) var configured = false
    @Published private(set) var connected = false
    @Published var on = FaceLink.isOn {
        didSet {
            var off = Set(UserDefaults.app.stringArray(forKey: "mcpOff") ?? [])
            if on { off.remove(Self.name) } else { off.insert(Self.name) }
            UserDefaults.app.set(off.sorted(), forKey: "mcpOff")
            refresh()
        }
    }

    static func server() -> Server? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = (json["mcpServers"] as? [String: Any])?[name] as? [String: Any],
              let command = entry["command"] as? String, command.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: command),
              let args = entry["args"] as? [String], let script = args.first else { return nil }
        let folder = URL(fileURLWithPath: faceFolder).standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = URL(fileURLWithPath: script).standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(folder), FileManager.default.fileExists(atPath: path) else { return nil }
        return Server(command: command, args: args)
    }

    // MARK: AI Face servers of the CLIs

    /// AI Face servers in a Codex config.toml (AI Face's Codex Connect adds one as "gpt"). Codex loads them in
    /// AI Illuminati's runs too, so a model could set the face past the app and AI Face would show GPT; each
    /// run switches them off. Only configured names: switching off an unknown name makes Codex fail to start.
    static func codexServers(config path: String) -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var found: [String] = [], current: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = nil
                guard line.hasPrefix("[mcp_servers."), let close = line.firstIndex(of: "]") else { continue }
                // A quoted key ("ai-face" or 'ai-face') names the same server as the bare one.
                let key = line[line.index(line.startIndex, offsetBy: 13)..<close]
                let name: String
                if let quote = key.first, quote == "\"" || quote == "'" {
                    name = key.dropFirst().prefix { $0 != quote }.description
                } else { name = key.split(separator: ".").first.map(String.init) ?? "" }
                if !name.isEmpty, name != "illuminati", name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) { current = name }
            } else if let current, !found.contains(current),
                      line.contains("ai_face_mcp.py") || line.contains("AIFACE_AGENT") || line.contains("ESP32_AGENT") {
                found.append(current)
            }
        }
        return found
    }

    /// Codex options that switch those servers off for one run of this account.
    static func codexOff(_ account: Account) -> [String] {
        let home = account.dir ?? AccountStore.home + "/.codex"
        return codexServers(config: home + "/config.toml").flatMap { ["-c", "mcp_servers.\($0).enabled=false"] }
    }

    // MARK: The face tag

    static let fallbackMoods = ["happy", "talking", "thinking", "curious", "agree", "sympathy", "proud", "apologetic", "shrug"]

    /// The moods AI Face offers (from its set_expression tool), for the rule and to check a tag.
    func moods() -> [String] {
        queue.sync {
            _ = ensure()
            let tool = faceTools.first { $0["name"] as? String == "set_expression" }
            let properties = ((tool?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
            return (properties["emotion"] as? [String: Any])?["enum"] as? [String] ?? []
        }
    }

    static func rule(_ moods: [String]) -> String {
        """
        [Face] AI Face shows a small face for this chat. End your reply with one more line, hidden from the user:
        <face>MOOD</face> — the mood of your reply (vary it), one of: \((moods.isEmpty ? fallbackMoods : moods).joined(separator: ", ")).
        Nothing after it. Do not mention it.
        """
    }

    /// The text without the <face>…</face> tag at its end (also a tag still arriving there), and the mood. Only a
    /// tag with one English word that ends the reply counts (a hidden <chat-state> block may follow it, kept for its
    /// own reader); a tag written inside the reply, e.g. explaining it, stays text and sets no face.
    static func extract(_ text: String) -> (text: String, mood: String?) {
        var ends = [text.endIndex]
        if let state = text.range(of: "<chat-state>", options: .backwards) { ends.append(state.lowerBound) }
        else if let partial = text.range(of: "<chat", options: .backwards), "<chat-state>".hasPrefix(String(text[partial.lowerBound...])) { ends.append(partial.lowerBound) }
        for end in ends {
            var last = end
            while last > text.startIndex, text[text.index(before: last)].isWhitespace { last = text.index(before: last) }
            let body = text[..<last]
            guard body.hasSuffix("</face>"), let open = body.range(of: "<face>", options: .backwards) else { continue }
            let mood = body[open.upperBound..<body.index(last, offsetBy: -7)].trimmingCharacters(in: .whitespaces)
            guard isMood(mood) else { continue }
            let cleaned = String(text[..<open.lowerBound]) + String(text[last...])
            return (cleaned.trimmingCharacters(in: .whitespacesAndNewlines), mood.lowercased())
        }
        if let open = text.range(of: "<face>", options: .backwards), arriving(text[open.lowerBound...]) {
            return (String(text[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        if let partial = text.range(of: "<", options: .backwards), "<face>".hasPrefix(String(text[partial.lowerBound...])) {
            return (String(text[..<partial.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        return (text, nil)
    }

    private static func isMood<S: StringProtocol>(_ word: S) -> Bool {
        (1...32).contains(word.count) && word.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "_" || $0 == "-") }
    }

    /// The end of a streamed reply that can still become <face>mood</face>.
    private static func arriving(_ tail: Substring) -> Bool {
        var rest = tail.dropFirst("<face>".count).drop { $0 == " " }
        let word = rest.prefix { $0.isASCII && ($0.isLetter || $0 == "_" || $0 == "-") }
        guard word.count <= 32 else { return false }
        rest = rest.dropFirst(word.count).drop { $0 == " " }
        return "</face>".hasPrefix(rest)
    }

    /// Sets the face for a finished reply. A mood AI Face does not offer is dropped.
    func show(_ mood: String) {
        queue.async {
            guard self.ensure(), let tool = self.faceTools.first(where: { $0["name"] as? String == "set_expression" }) else { return }
            let properties = ((tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
            let offered = (properties["emotion"] as? [String: Any])?["enum"] as? [String] ?? []
            guard offered.isEmpty || offered.contains(mood) else { return }
            _ = self.request("tools/call", ["name": "set_expression", "arguments": ["emotion": mood]])
        }
    }

    // MARK: Connection to AI Face (one MCP session while the app runs)

    private let queue = DispatchQueue(label: "face-link")
    private var process: Process?, input: FileHandle?, server: Server?
    private var faceTools: [[String: Any]] = []
    private var nextID = 1
    private let lock = NSLock(), arrived = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var timer: Timer?

    /// Opens the local socket for the bridge and connects to AI Face when it is set up. Checked again
    /// every 30 seconds (Connect or Disconnect in AI Face, AI Face restarted) and before each call.
    func start() {
        // Writing to AI Face's server after it quit must fail quietly, not end the app.
        signal(SIGPIPE, SIG_IGN)
        ToolHub.shared.start()
        ToolHub.shared.startLegacyFaceSocket(at: Self.socketPath)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() { queue.async { _ = self.ensure() } }

    /// AI Face's tools, for the models (empty when AI Face is not connected or switched off).
    func tools() -> [[String: Any]] { queue.sync { ensure() ? faceTools : [] } }

    /// One tool call, answered as an MCP tool result ({content, isError}).
    func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        func failure(_ text: String) -> [String: Any] { ["content": [["type": "text", "text": text]], "isError": true] }
        return queue.sync {
            guard ensure() else { return failure("AI Face is not connected") }
            guard faceTools.contains(where: { $0["name"] as? String == name }) else { return failure("Unknown AI Face tool: \(name)") }
            let reply = request("tools/call", ["name": name, "arguments": arguments])
            if let result = reply?["result"] as? [String: Any] { return result }
            let message = (reply?["error"] as? [String: Any])?["message"] as? String
            if reply == nil { disconnect() }
            return failure(message ?? "AI Face did not answer")
        }
    }

    private func ensure() -> Bool {
        let found = Self.server()
        let wanted = Self.isOn ? found : nil
        if wanted != server || process?.isRunning != true {
            disconnect()
            if let wanted { connect(wanted) }
        }
        let running = process?.isRunning == true
        DispatchQueue.main.async { self.configured = found != nil; self.connected = running }
        return running
    }

    private func connect(_ server: Server) {
        let child = Process(), toChild = Pipe(), fromChild = Pipe()
        child.executableURL = URL(fileURLWithPath: server.command)
        child.arguments = server.args
        var environment = ProcessInfo.processInfo.environment
        environment["AIFACE_AGENT"] = Self.agent
        child.environment = environment
        child.currentDirectoryURL = URL(fileURLWithPath: "/")
        child.standardInput = toChild
        child.standardOutput = fromChild
        child.standardError = FileHandle.nullDevice
        lock.lock(); buffer = Data(); lock.unlock()
        fromChild.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil }
            self.lock.lock(); self.buffer.append(data); self.lock.unlock()
            self.arrived.signal()
        }
        do { try child.run() } catch { return }
        process = child
        input = toChild.fileHandleForWriting
        self.server = server
        let hello: [String: Any] = ["protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
                                    "clientInfo": ["name": "AI Illuminati", "version": "1"]]
        guard request("initialize", hello)?["result"] != nil else { return disconnect() }
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let listed = (request("tools/list", [:])?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        faceTools = listed
    }

    private func disconnect() {
        if let process, process.isRunning { process.terminate() }
        try? input?.close()
        process = nil; input = nil; server = nil; faceTools = []
    }

    private func send(_ message: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        do { try input.write(contentsOf: data + Data([0x0A])) } catch { }
    }

    // On `queue`. Waits up to 10 seconds for the answer with the same id.
    private func request(_ method: String, _ params: [String: Any]) -> [String: Any]? {
        let id = nextID
        nextID += 1
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(10)
        while true {
            lock.lock()
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any], reply["id"] as? Int == id {
                    lock.unlock()
                    return reply
                }
            }
            lock.unlock()
            let left = deadline.timeIntervalSinceNow
            guard left > 0, process?.isRunning == true else { return nil }
            _ = arrived.wait(timeout: .now() + min(left, 0.5))
        }
    }

}
