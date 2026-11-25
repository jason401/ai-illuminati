import Foundation
import AIAccounts
import AIIntegrations

// The promises of Integrations (AIIntegrations), checked from outside with only its public API: MCP secrets keep their
// chunked Keychain items; an outside MCP tool that is not connected is refused without asking; AI Face's link works
// through a fake connection and a missing, switched-off or dying AI Face leaves the rest working. Run with AI_ILLUMINATI_TEST_HOME set to an empty
// folder (run_mode2.sh). No real Keychain, network, socket or AI Face is used: every one of them is a fake here.
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("FAIL: " + message) }
}
let home = ProcessInfo.processInfo.environment["AI_ILLUMINATI_TEST_HOME"] ?? ""
expect(!home.isEmpty && AccountStore.home == home, "the integrations test needs its own home")
let fm = FileManager.default

// MARK: A fake /usr/bin/security (the same commands and input line the real one gets)

final class FakeSecurity {
    var items: [String: Data] = [:]   // "service|account" → stored value
    var lines: [String] = []
    func key(_ service: String, _ account: String) -> String { service + "|" + account }
    func run(_ args: [String], _ input: Data?) throws -> (Int32, Data) {
        switch args.first {
        case "find-generic-password":
            guard let value = items[key(args[2], args[4])] else { return (44, Data()) }
            return (0, value + Data([10]))
        case "delete-generic-password":
            items[key(args[2], args[4])] = nil
            return (0, Data())
        case "-i":
            let line = String(decoding: input ?? Data(), as: UTF8.self)
            lines.append(line)
            let pattern = try! NSRegularExpression(pattern: #"^add-generic-password -U -s "([^"]+)" -a "?([^" ]+?)"? -w (\S+)\n$"#)
            guard let m = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return (1, Data()) }
            let part = { (i: Int) in String(line[Range(m.range(at: i), in: line)!]) }
            items[key(part(1), part(2))] = Data(part(3).utf8)
            return (0, Data())
        default: return (1, Data())
        }
    }
}

// MARK: MCP secrets keep their Keychain items (numbered chunks, item 0 last)

do {
    let security = FakeSecurity()
    let long = String(repeating: "token-", count: 1200)
    try! MCPKeychain(run: security.run).set("oauth.srv", long)
    let head = String(decoding: security.items[security.key("AI Illuminati MCP", "oauth.srv#0")] ?? Data(), as: UTF8.self)
    expect(head.hasPrefix("v1:4:") && security.items.count == 4 && security.lines.last?.contains("-a \"oauth.srv#0\"") == true,
           "a long secret is split over numbered items, the first written last")
    expect(MCPKeychain(run: security.run).get("oauth.srv") == long, "and read back whole")
    try! MCPKeychain(run: security.run).set("oauth.srv", nil)
    expect(security.items.isEmpty, "removing it removes every chunk")
}

// MARK: Outside MCP: a tool that is not connected is refused, nothing is asked

do {
    var asked = false
    let reply = ExternalMCP.shared.call("nothing__tool", [:]) { _, _ in asked = true; return true }
    expect(reply["isError"] as? Bool == true && !asked && ExternalMCP.shared.tools().isEmpty && !ExternalMCP.shared.active,
           "an unknown outside tool is refused without asking")
}

// MARK: AI Face through a fake connection; a missing, switched-off or dying AI Face

final class FakeFace: FacePipe {
    var isRunning = true
    var answersCalls = true
    var calls: [[String: Any]] = []
    var notes: [String] = []
    func send(_ message: [String: Any]) { notes.append(message["method"] as? String ?? "") }
    func request(_ method: String, _ params: [String: Any]) -> [String: Any]? {
        guard isRunning else { return nil }
        switch method {
        case "initialize": return ["result": ["protocolVersion": "2025-06-18"]]
        case "tools/list":
            let schema: [String: Any] = ["type": "object", "properties": ["emotion": ["type": "string", "enum": ["happy", "sad"]]]]
            return ["result": ["tools": [["name": "set_expression", "inputSchema": schema], ["name": "calendar_events", "inputSchema": ["type": "object"]]]]]
        default:
            guard answersCalls else { isRunning = false; return nil }   // AI Face quits in the middle of a call
            calls.append(params)
            return ["result": ["content": [["type": "text", "text": "ok"]], "isError": false]]
        }
    }
    func close() { isRunning = false }
}
let faceFolder = URL(fileURLWithPath: home).appendingPathComponent("AI Face")
try! fm.createDirectory(at: faceFolder, withIntermediateDirectories: true)
let script = faceFolder.appendingPathComponent("ai_face_mcp.py")
try! Data("# AI Face's server (never started here)".utf8).write(to: script)
FaceLink.faceFolder = faceFolder.path
FaceLink.file = URL(fileURLWithPath: home).appendingPathComponent("mcp.json")
func connectFace() {
    let entry: [String: Any] = ["mcpServers": ["ai-face": ["command": "/bin/sh", "args": [script.path]]]]
    try! JSONSerialization.data(withJSONObject: entry).write(to: FaceLink.file)
}
do {
    var opened: [FaceLink.Server] = []
    var pipes: [FakeFace] = []
    var reachable = true
    let face = FaceLink(open: { server in
        opened.append(server)
        guard reachable else { return nil }
        let pipe = FakeFace(); pipes.append(pipe); return pipe
    })
    // Not set up: nothing is started, and the reply text is still handled.
    expect(FaceLink.active() == nil && face.tools().isEmpty && opened.isEmpty, "no AI Face before it is connected")
    expect(face.call("set_expression", ["emotion": "happy"])["isError"] as? Bool == true, "a call without AI Face is an error reply, not a wait")
    expect(face.moods().isEmpty && FaceLink.rule(face.moods()).contains("happy, talking, thinking"), "the rule falls back to the usual moods")
    expect(FaceLink.extract("Done.\n<face>happy</face>") == ("Done.", "happy"), "the tag is read without AI Face")
    connectFace()
    expect(FaceLink.active()?.command == "/bin/sh" && FaceLink.active()?.args == [script.path], "AI Face's own server is found")
    expect(face.tools().compactMap { $0["name"] as? String } == ["set_expression", "calendar_events"] && opened.count == 1,
           "AI Face's tools come through one connection")
    expect(pipes[0].notes == ["notifications/initialized"], "the connection is initialized the MCP way")
    expect(face.moods() == ["happy", "sad"], "the moods come from set_expression")
    face.show("sad"); face.show("furious")
    _ = face.tools()   // same queue: the calls above are done
    expect(pipes[0].calls.count == 1 && (pipes[0].calls[0]["arguments"] as? [String: String]) == ["emotion": "sad"], "a mood AI Face does not offer is dropped")
    expect(face.call("no_such_tool", [:])["isError"] as? Bool == true && pipes[0].calls.count == 1, "a tool AI Face does not list is refused")
    // AI Face quits in the middle of a call: an error reply, the link drops, and the next use connects again.
    pipes[0].answersCalls = false
    let dropped = face.call("calendar_events", [:])
    expect(dropped["isError"] as? Bool == true && ((dropped["content"] as? [[String: Any]])?.first?["text"] as? String) == "AI Face did not answer",
           "a call to a dying AI Face ends with an error reply")
    expect(face.tools().count == 2 && opened.count == 2 && pipes.count == 2, "the next use connects again")
    // AI Face gone for good (the server cannot start): every use returns at once and nothing is shown.
    pipes[1].isRunning = false
    reachable = false
    let started = Date()
    face.show("happy")
    expect(face.tools().isEmpty && face.moods().isEmpty && face.call("set_expression", ["emotion": "happy"])["isError"] as? Bool == true,
           "with AI Face gone the link offers nothing and refuses calls")
    expect(Date().timeIntervalSince(started) < 5, "and nothing waits on it")
    // Switched off in Settings: not even tried.
    reachable = true
    let tries = opened.count
    UserDefaults.app.set(["ai-face"], forKey: "mcpOff")
    expect(FaceLink.active() == nil && face.tools().isEmpty && opened.count == tries, "switched off: no connection is tried")
    UserDefaults.app.removeObject(forKey: "mcpOff")
    expect(FaceLink.active() != nil && face.tools().count == 2, "switched on again")
    try! fm.removeItem(at: FaceLink.file)
    expect(face.tools().isEmpty && pipes.last?.isRunning == false, "Disconnect in AI Face ends the connection")
}

print("PASS: integrations contract")
