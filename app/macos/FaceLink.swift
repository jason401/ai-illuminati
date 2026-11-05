import Foundation
import Darwin

// AI Face (a separate menu bar app) shows a face for each AI reply. AI Illuminati connects to it the way
// Claude desktop and ChatGPT desktop do: the app itself is AI Face's MCP client and keeps one connection
// open while it runs, as "illuminati". AI Face writes its server into mcp.json here when the user clicks
// Connect (and removes it on Disconnect). Which model answers stays inside AI Illuminati: the per-answer
// workspace bridge (workspace_mcp.py) offers the allowed AI Face tools to whichever model it serves and
// hands each call to the app over a local socket. The agreement between the two apps is docs/AI_FACE.md.
final class FaceLink {
    struct Server: Equatable { var command: String; var args: [String] }

    static let shared = FaceLink()
    static let name = "ai-face", agent = "illuminati"
    // Tools the models in AI Illuminati may use. Widen here, and in AI Face's permissions for Illuminati.
    static let allowed: Set<String> = ["set_expression"]
    static var file = URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("mcp.json")
    // The server must be AI Face's own file; anything else in mcp.json is ignored.
    static var faceFolder = AccountStore.home + "/Library/Application Support/AI Face"
    static var socketPath = AccountStore.supportDir + "/face.sock"

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

    // Asked before the reply: the chat shows the AI's last message, and text written before a tool call
    // would end up in an earlier one. Codex needs the argument name and example moods.
    static let rule = """
        [Face] AI Face shows a small animated face for this chat. Before writing your reply, call the tool
        set_expression once, its `emotion` set to the mood your reply will have (vary it), then write the whole reply.
        Use only a mood the tool lists, e.g. happy, talking, thinking, curious, agree, sympathy, proud, apologetic, shrug.
        Do not mention the call. If the tool is missing or fails, carry on without it.
        """

    // MARK: Connection to AI Face (one MCP session while the app runs)

    private let queue = DispatchQueue(label: "face-link")
    private var process: Process?, input: FileHandle?, connected: Server?
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
        listen()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() { queue.async { _ = self.ensure() } }

    /// The AI Face tools models may use now (empty when AI Face is not connected).
    func tools() -> [[String: Any]] { queue.sync { ensure() ? faceTools : [] } }

    /// One tool call, answered as an MCP tool result ({content, isError}).
    func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        func failure(_ text: String) -> [String: Any] { ["content": [["type": "text", "text": text]], "isError": true] }
        guard Self.allowed.contains(name) else { return failure("Tool not allowed in AI Illuminati: \(name)") }
        return queue.sync {
            guard ensure() else { return failure("AI Face is not connected") }
            let reply = request("tools/call", ["name": name, "arguments": arguments])
            if let result = reply?["result"] as? [String: Any] { return result }
            let message = (reply?["error"] as? [String: Any])?["message"] as? String
            if reply == nil { disconnect() }
            return failure(message ?? "AI Face did not answer")
        }
    }

    private func ensure() -> Bool {
        let wanted = Self.server()
        if wanted != connected || process?.isRunning != true {
            disconnect()
            if let wanted { connect(wanted) }
        }
        return process?.isRunning == true
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
        connected = server
        let hello: [String: Any] = ["protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
                                    "clientInfo": ["name": "AI Illuminati", "version": "1"]]
        guard request("initialize", hello)?["result"] != nil else { return disconnect() }
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let listed = (request("tools/list", [:])?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        faceTools = listed.filter { Self.allowed.contains($0["name"] as? String ?? "") }
    }

    private func disconnect() {
        if let process, process.isRunning { process.terminate() }
        try? input?.close()
        process = nil; input = nil; connected = nil; faceTools = []
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

    // MARK: Local socket for the workspace bridge: one JSON line in ({op: tools} or {op: call, name, arguments}), one out.

    private func listen() {
        let path = Self.socketPath
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 8) == 0 else { close(fd); return }
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                DispatchQueue.global().async { self?.serve(client) }
            }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var data = Data(), chunk = [UInt8](repeating: 0, count: 4096)
        while !data.contains(0x0A) && data.count < 1_000_000 {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { break }
            data.append(contentsOf: chunk[0..<n])
        }
        guard let line = data.split(separator: 0x0A).first,
              let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return }
        let reply: [String: Any]
        switch message["op"] as? String {
        case "tools": reply = ["tools": tools()]
        case "call": reply = call(message["name"] as? String ?? "", message["arguments"] as? [String: Any] ?? [:])
        default: reply = ["error": "unknown op"]
        }
        guard let out = try? JSONSerialization.data(withJSONObject: reply) else { return }
        (out + Data([0x0A])).withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
    }
}
