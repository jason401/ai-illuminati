import Foundation
import AIAccounts
import AIIntegrations

// The promises of Integrations (AIIntegrations), checked from outside with only its public API: the Google login is
// read from and saved to the Keychain item it always used (service, account, "ai-illuminati-google-v1:" + base64 of the
// same JSON), an older raw item and a half-done migration still load; tokens refresh, expire and are revoked through
// the injected transport; both sign-ins finish without a browser or a socket; MCP secrets keep their chunked items; an
// outside MCP tool that is not connected is refused without asking; AI Face's link works through a fake connection and
// a missing, switched-off or dying AI Face leaves the rest working. Run with AI_ILLUMINATI_TEST_HOME set to an empty
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

// MARK: A fake network: every Google request comes here

var requests: [URLRequest] = []
var answer: (URLRequest) -> (Int, [String: Any]) = { _ in (500, [:]) }
GoogleHTTP.transport = { request, _, _ in
    requests.append(request)
    let (status, json) = answer(request)
    return GoogleHTTP.Reply(status: status, data: try JSONSerialization.data(withJSONObject: json), headers: [:])
}
func form(_ request: URLRequest) -> [String: String] {
    var fields: [String: String] = [:]
    for pair in String(decoding: request.httpBody ?? Data(), as: UTF8.self).split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
        if kv.count == 2 { fields[kv[0]] = kv[1] }
    }
    return fields
}
let service = "AI Illuminati Google", prefix = "ai-illuminati-google-v1:"
let drive = "https://www.googleapis.com/auth/drive"
func stored(_ json: [String: Any]) -> Data { Data((prefix + (try! JSONSerialization.data(withJSONObject: json)).base64EncodedString()).utf8) }
func saved(_ security: FakeSecurity, _ account: String = "oauth") -> [String: Any]? {
    guard let value = security.items[security.key(service, account)], value.starts(with: Data(prefix.utf8)),
          let data = Data(base64Encoded: value.dropFirst(prefix.count)) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

// MARK: The login saved by earlier versions is read as it is

do {
    let security = FakeSecurity()
    security.items[security.key(service, "oauth")] = stored(["clientID": "cid.apps.googleusercontent.com", "refreshToken": "r1", "writable": true])
    let auth = GoogleAuth(store: GoogleKeychainStore(run: security.run))
    expect(auth.connected && auth.canWrite && !auth.needsReconnect, "a saved login is connected, writable as saved")
    expect(auth.publicClientID == "cid.apps.googleusercontent.com", "a login without a client secret is the app's public client")
    answer = { _ in (200, ["access_token": "a1", "expires_in": 3600, "scope": drive]) }
    requests = []
    expect((try? auth.accessToken()) == "a1", "the saved refresh token gets an access token")
    let refresh = form(requests[0])
    expect(requests.count == 1 && requests[0].url?.host == "oauth2.googleapis.com" && requests[0].httpMethod == "POST"
           && refresh == ["client_id": "cid.apps.googleusercontent.com", "refresh_token": "r1", "grant_type": "refresh_token"],
           "a refresh sends the saved client and token, no secret")
    expect((try? auth.accessToken()) == "a1" && requests.count == 1, "a fresh access token is kept in memory")
    expect(saved(security)?["refreshToken"] as? String == "r1" && saved(security)?["clientID"] as? String == "cid.apps.googleusercontent.com",
           "the item keeps its format after a refresh")
    // Google rotates the refresh token: the same item, written with the same input line.
    answer = { _ in (200, ["access_token": "a2", "refresh_token": "r2", "expires_in": 3600, "scope": drive]) }
    security.lines = []
    expect((try? auth.accessToken(forceRefresh: true)) == "a2" && saved(security)?["refreshToken"] as? String == "r2", "a rotated token is saved")
    let value = String(decoding: security.items[security.key(service, "oauth")]!, as: UTF8.self)
    expect(security.lines == ["add-generic-password -U -s \"AI Illuminati Google\" -a oauth -w " + value + "\n"],
           "saved through security's stdin, same service and account")
    // Google refuses the token: the client stays, the token goes, a reconnect is asked for.
    answer = { _ in (400, ["error": "invalid_grant"]) }
    var refused: String?
    do { _ = try auth.accessToken(forceRefresh: true) } catch { refused = (error as? GoogleFailure)?.message }
    expect(refused?.contains("expired or was revoked") == true && auth.needsReconnect && !auth.connected
           && saved(security)?["clientID"] as? String == "cid.apps.googleusercontent.com" && saved(security)?["refreshToken"] == nil,
           "an expired login keeps the client and asks to reconnect")
}

do {
    // An item from before the prefix (raw JSON) is moved to the prefixed form once; the JSON bytes stay the same.
    let security = FakeSecurity()
    let raw = Data(#"{"clientID":"desk","clientSecret":"s","refreshToken":"old"}"#.utf8)
    security.items[security.key(service, "oauth")] = raw
    let auth = GoogleAuth(store: GoogleKeychainStore(run: security.run))
    expect(auth.connected && auth.publicClientID == nil, "a raw item from older versions still loads")
    expect(security.items[security.key(service, "oauth")] == Data((prefix + raw.base64EncodedString()).utf8)
           && security.items[security.key(service, "oauth-migration")] == nil, "it is rewritten once in the prefixed form, no copy left")
    // A migration cut off after the old item was removed comes back from its copy.
    let cut = FakeSecurity()
    cut.items[cut.key(service, "oauth-migration")] = Data((prefix + raw.base64EncodedString()).utf8)
    let resumed = GoogleAuth(store: GoogleKeychainStore(run: cut.run))
    expect(resumed.connected && cut.items[cut.key(service, "oauth")] != nil && cut.items[cut.key(service, "oauth-migration")] == nil,
           "a half-done migration is finished from its copy")
    // A damaged item is not taken for a login.
    let damaged = FakeSecurity()
    damaged.items[damaged.key(service, "oauth")] = Data((prefix + "!!!").utf8)
    expect(!GoogleAuth(store: GoogleKeychainStore(run: damaged.run)).connected, "a damaged item is not connected")
    // Disconnect removes the item and revokes the token at Google.
    answer = { _ in (200, [:]) }
    requests = []
    expect((try? auth.disconnect()) != nil && !auth.connected && security.items.isEmpty, "disconnect clears the Keychain item")
    expect(requests.count == 1 && requests[0].url?.host == "oauth2.googleapis.com" && form(requests[0]) == ["token": "old"], "and revokes the token")
}

// MARK: Both sign-ins finish with no browser and no socket

final class FakePresenter: GoogleAuthPresenter {
    var url: URL?, scheme = "", completion: ((Result<URL, Error>) -> Void)?
    func start(_ url: URL, scheme: String, completion: @escaping (Result<URL, Error>) -> Void) { self.url = url; self.scheme = scheme; self.completion = completion }
    func cancel() {}
}
final class FakeCallback: OAuthCallback {
    let redirect = "http://127.0.0.1:5555/"
    var completion: ((Result<[String: String], Error>) -> Void)?
    var cancelled = false
    func start(_ completion: @escaping (Result<[String: String], Error>) -> Void) { self.completion = completion }
    func cancel() { cancelled = true }
}
func query(_ url: URL?) -> [String: String] {
    var fields: [String: String] = [:]
    for item in URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] { fields[item.name] = item.value }
    return fields
}
answer = { request in
    form(request)["grant_type"] == "authorization_code" ? (200, ["access_token": "a", "refresh_token": "new", "expires_in": 3600, "scope": drive]) : (500, [:])
}
do {
    let security = FakeSecurity(), presenter = FakePresenter(), done = DispatchSemaphore(value: 0)
    let auth = GoogleAuth(store: GoogleKeychainStore(run: security.run))
    var result: Result<Void, Error>?
    try! auth.beginBuiltInAuthorization(present: presenter, clientID: "app.apps.googleusercontent.com", writable: true) { result = $0; done.signal() }
    let asked = query(presenter.url)
    expect(presenter.scheme == "com.googleusercontent.apps.app" && asked["redirect_uri"] == "com.googleusercontent.apps.app:/oauth2redirect"
           && asked["scope"] == drive && asked["code_challenge_method"] == "S256", "the app's client signs in through the presenter")
    presenter.completion?(.success(URL(string: "com.googleusercontent.apps.app:/oauth2redirect?state=\(asked["state"]!)&code=c1")!))
    expect(done.wait(timeout: .now() + 10) == .success, "the sign-in finishes")
    if case .success = result {} else { expect(false, "the built-in sign-in succeeds") }
    expect(saved(security)?["clientID"] as? String == "app.apps.googleusercontent.com" && saved(security)?["clientSecret"] == nil
           && saved(security)?["refreshToken"] as? String == "new" && saved(security)?["writable"] as? Bool == true, "and is saved in the same format")
}
do {
    let security = FakeSecurity(), callback = FakeCallback(), done = DispatchSemaphore(value: 0)
    var ports: [UInt16] = []
    let make = GoogleLoopback.make
    GoogleLoopback.make = { port, _ in ports.append(port); return callback }
    defer { GoogleLoopback.make = make }
    let auth = GoogleAuth(store: GoogleKeychainStore(run: security.run))
    var result: Result<Void, Error>?
    let client = try! JSONSerialization.data(withJSONObject: ["installed": ["client_id": "desk", "client_secret": "sec"]])
    let url = try! auth.beginAuthorization(clientJSON: client) { result = $0; done.signal() }
    let asked = query(url)
    expect(ports == [0] && asked["redirect_uri"] == callback.redirect && asked["scope"] == "https://www.googleapis.com/auth/drive.readonly",
           "a desktop client signs in through the callback the app is given (any port)")
    callback.completion?(.success(["state": "wrong", "code": "c"]))
    expect(done.wait(timeout: .now() + 10) == .success, "a wrong state ends the sign-in")
    if case .failure = result {} else { expect(false, "a callback with another state is refused") }
    expect(security.items.isEmpty, "a refused sign-in saves nothing")
    let again = query(try! auth.beginAuthorization(clientJSON: client) { result = $0; done.signal() })
    callback.completion?(.success(["state": again["state"]!, "code": "c"]))
    expect(done.wait(timeout: .now() + 10) == .success, "the desktop sign-in finishes")
    if case .success = result {} else { expect(false, "the desktop sign-in succeeds with its own state") }
    expect(saved(security)?["clientSecret"] as? String == "sec" && saved(security)?["refreshToken"] as? String == "new", "the desktop client is saved with its secret")
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
