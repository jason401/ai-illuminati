import Foundation
import CryptoKit

final class MemoryGoogleStore: GoogleTokenStore {
    var data: Data?
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
    func clear() throws { data = nil }
}

func testGoogleDrive() {
    let root = URL(fileURLWithPath: AccountStore.home)
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["tools/tests/fake_google.py", root.path]
    server.standardError = FileHandle.nullDevice
    server.standardOutput = FileHandle.nullDevice
    try! server.run()
    defer { server.terminate(); server.waitUntilExit() }
    let portFile = root.appendingPathComponent("google-port")
    for _ in 0..<50 where !FileManager.default.fileExists(atPath: portFile.path) { Thread.sleep(forTimeInterval: 0.05) }
    let port = try! String(contentsOf: portFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let base = URL(string: "http://127.0.0.1:\(port)")!
    let original = (GoogleAuth.authorizeURL, GoogleAuth.tokenURL, GoogleAuth.revokeURL, DriveLink.api, DriveLink.sheetsAPI)
    let previousDrive = DriveLink.shared
    defer {
        GoogleAuth.authorizeURL = original.0; GoogleAuth.tokenURL = original.1; GoogleAuth.revokeURL = original.2
        DriveLink.api = original.3; DriveLink.sheetsAPI = original.4; DriveLink.shared = previousDrive
    }
    GoogleAuth.authorizeURL = base.appendingPathComponent("authorize")
    GoogleAuth.tokenURL = base.appendingPathComponent("token")
    GoogleAuth.revokeURL = base.appendingPathComponent("revoke")
    DriveLink.api = base.appendingPathComponent("drive")
    DriveLink.sheetsAPI = base.appendingPathComponent("sheets")
    let store = MemoryGoogleStore(), auth = GoogleAuth(store: MemoryGoogleStore())
    let loggedIn = GoogleAuth(store: store)
    let client = Data(#"{"installed":{"client_id":"fixture-client","client_secret":"fixture-secret"}}"#.utf8)
    var challenges: [String] = []
    func authorize(_ service: GoogleAuth, wrongState: Bool = false, code: String = "fixture-code") -> Bool {
        let done = DispatchSemaphore(value: 0)
        var success = false
        let address = try! service.beginAuthorization(clientJSON: client) { result in
            if case .success = result { success = true }
            done.signal()
        }
        let items = URLComponents(url: address, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ name: String) -> String { items.first { $0.name == name }!.value! }
        challenges.append(value("code_challenge"))
        expect(value("scope") == GoogleAuth.scope && value("code_challenge_method") == "S256", "read-only scope and PKCE S256")
        expect(value("code_challenge").count == 43 && value("access_type") == "offline", "random PKCE challenge and offline access")
        var callback = URLComponents(string: value("redirect_uri"))!
        expect(callback.host == "127.0.0.1" && callback.port != nil, "localhost-only random-port callback")
        callback.queryItems = [URLQueryItem(name: "code", value: code), URLQueryItem(name: "state", value: wrongState ? "wrong" : value("state"))]
        _ = try! GoogleHTTP.send(callback.url!)
        expect(done.wait(timeout: .now() + 5) == .success, "OAuth callback finishes")
        return success
    }
    expect(!authorize(auth, wrongState: true) && !auth.connected, "wrong state never creates credentials")
    expect(authorize(loggedIn) && loggedIn.connected, "successful loopback sign-in stores offline credentials")
    expect(!authorize(loggedIn, code: "bad-code") && loggedIn.connected, "a failed new sign-in preserves existing login")
    let drive = DriveLink(auth: loggedIn)
    DriveLink.shared = drive
    drive.enabled = true
    defer { drive.enabled = true }
    let context = ToolContext(room: UUID(), roots: [WorkspaceRoot(path: root.path, directory: true)])
    func call(_ tool: String, _ args: [String: Any]) -> [String: Any] {
        let result = drive.call(tool, args, context: context)
        expect(result["isError"] as? Bool == false, "Drive tool succeeds: \(tool) \(args)")
        let text = ((result["content"] as! [[String: Any]])[0]["text"] as! String)
        return try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }
    _ = call("drive_search", ["query": "O'Brien\\lab", "type": "doc"])
    _ = call("drive_list", ["folder": "https://drive.google.com/drive/folders/folder", "page": "fixture-next"])
    let doc = call("drive_read", ["file": "https://docs.google.com/document/d/doc/edit", "start": 2, "end": 9])
    expect(doc["text"] as? String == "Fixture" && doc["start"] as? Int == 2 && doc["end"] as? Int == 9, "character range and metadata")
    expect((call("drive_read", ["file": "fallback"])["text"] as? String)?.contains("한글") == true, "Markdown fallback preserves Unicode")
    expect((call("drive_read", ["file": "slides"])["note"] as? String)?.contains("layout") == true, "Slides explicitly text only")
    let sheet = call("drive_read", ["file": "sheet", "sheet": "O'Brien/2026"])
    expect(sheet["sheets"] as? [String] == ["Main", "O'Brien/2026"] && (sheet["text"] as? String)?.contains("Second tab") == true, "Sheets named tabs and escaped A1/path")
    expect((call("drive_read", ["file": "pdf"])["text"] as? String)?.contains("Drive PDF fixture") == true, "downloaded PDF text")
    expect((call("drive_read", ["file": "office"])["text"] as? String)?.contains("247 kPa") == true, "downloaded DOCX through MaterialReader")
    expect((call("drive_read", ["file": "download"])["text"] as? String) == "Fixture download", "ordinary text download")
    expect(call("drive_read", ["file": "shortcut"])["id"] as? String == "doc", "Drive shortcut resolution")
    let pointer = root.appendingPathComponent("fixture.gdoc")
    try! Data(#"{"doc_id":"doc","email":"FIXTURE_PRIVATE_EMAIL"}"#.utf8).write(to: pointer)
    expect(call("drive_read", ["file": pointer.path])["id"] as? String == "doc", "linked pointer reads actual document without returning pointer metadata")
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gdoc")
    try! Data(#"{"doc_id":"doc"}"#.utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }
    expect(drive.call("drive_read", ["file": outside.path], context: context)["isError"] as? Bool == true, "pointer outside linked roots refused")
    for id in ["huge", "forbidden", "missing", "redirect", "large-response"] {
        expect(drive.call("drive_read", ["file": id], context: context)["isError"] as? Bool == true, "bounded error: \(id)")
    }
    expect(drive.call("drive_read", ["file": "doc", "start": -1], context: context)["isError"] as? Bool == true, "invalid range refused")
    _ = call("drive_read", ["file": "unauthorized"])
    _ = call("drive_read", ["file": "rate"])
    let recordsData = try! GoogleHTTP.send(base.appendingPathComponent("records")).data
    let records = try! JSONSerialization.jsonObject(with: recordsData) as! [[String: Any]]
    let grants = records.filter { $0["path"] as? String == "/token" }
    expect(grants.count == 3, "authorization attempts plus exactly one 401 refresh")
    let verifier = ((grants[0]["fields"] as! [String: [String]])["code_verifier"]!.first!)
    let digest = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    expect(verifier.count == 43 && digest == challenges[1], "token exchange sends the verifier matching the original S256 challenge")
    expect(records.contains { record in
        guard let q = record["query"] as? [String: [String]], let value = q["q"]?.first else { return false }
        return value.contains("O\\'Brien\\\\lab") && value.contains("trashed = false")
    }, "Drive query escapes apostrophe and backslash")
    expect(records.contains { ($0["query"] as? [String: [String]])?["pageToken"] == ["fixture-next"] }, "pagination forwarded")
    let expired = GoogleAuth(store: store)
    expect((try! expired.accessToken()) == "fixture-access", "fresh app refreshes saved login")
    let revokedStore = MemoryGoogleStore()
    revokedStore.data = try! JSONEncoder().encode(GoogleAuth.Credentials(clientID: "fixture-client", clientSecret: "fixture-secret", refreshToken: "revoked-fixture"))
    let revoked = GoogleAuth(store: revokedStore)
    do { _ = try revoked.accessToken(); expect(false, "revoked login must fail") } catch { expect(!revoked.connected, "invalid_grant requires reconnect") }

    // Real MCP stdio bridge -> capability-bound app socket -> fake Google API, without CLI networking.
    let manifestDir = root.appendingPathComponent("drive-manifests")
    let binding = WorkspaceBinding(roots: context.roots, level: .view, face: true)
    let prepared = try! WorkspaceInvocation(binding: binding, room: context.room).prepare(in: manifestDir)
    let manifest = try! String(contentsOfFile: prepared.1[1], encoding: .utf8)
    expect(manifest.contains("toolSession") && !manifest.contains("fixture-secret") && !manifest.contains("fixture-refresh") && !manifest.contains("fixture-access"), "manifest has only local capability, never Google credentials")
    let bridge = Process(), input = Pipe(), output = Pipe()
    bridge.executableURL = URL(fileURLWithPath: prepared.0); bridge.arguments = prepared.1
    bridge.standardInput = input; bridge.standardOutput = output; bridge.standardError = FileHandle.nullDevice
    try! bridge.run()
    input.fileHandleForWriting.write(Data((#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"# + "\n" + #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"drive_read","arguments":{"file":"doc"}}}"# + "\n").utf8))
    try! input.fileHandleForWriting.close()
    let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    bridge.waitUntilExit()
    expect(result.contains("drive_read") && result.contains("Fixture") && !result.contains("fixture-access"), "real bridge forwards Drive tool without credentials")
    var debate = binding; debate.face = nil
    let debateManifest = try! WorkspaceInvocation(binding: debate, room: context.room).prepare(in: manifestDir)
    expect(!(try! String(contentsOfFile: debateManifest.1[1], encoding: .utf8)).contains("toolSession"), "other modes have no Drive capability")
    expect(ToolHub.shared.handle(["op": "call", "name": "drive_read", "arguments": ["file": "doc"]])["isError"] as? Bool == true, "missing capability refused")
    drive.enabled = false
    expect(drive.tools().isEmpty && drive.call("drive_read", ["file": "doc"], context: context)["isError"] as? Bool == true, "off switch removes tools and rejects stale calls")
    drive.enabled = true
    let log = try! String(contentsOf: root.appendingPathComponent("Library/Application Support/AI Illuminati/drive.log"), encoding: .utf8)
    expect(!["fixture-secret", "fixture-refresh", "fixture-access", "Read-only", "FIXTURE_PRIVATE_EMAIL"].contains(where: log.contains), "logs contain no credentials, document text or email")
    // Turning off during a read withholds its result, even if switched back on immediately.
    let pending = DispatchSemaphore(value: 0)
    var withheld: [String: Any] = [:]
    DispatchQueue.global().async {
        withheld = drive.call("drive_read", ["file": "slow"], context: context)
        pending.signal()
    }
    for _ in 0..<50 {
        let counts = try! JSONSerialization.jsonObject(with: GoogleHTTP.send(base.appendingPathComponent("counts")).data) as! [String: Int]
        if counts["/drive/files/slow/export"] != nil { break }
        Thread.sleep(forTimeInterval: 0.02)
    }
    drive.enabled = false; drive.enabled = true
    expect(pending.wait(timeout: .now() + 5) == .success && withheld["isError"] as? Bool == true, "in-flight result withheld after switch changes")

    let slowStore = MemoryGoogleStore(), slowAuth = GoogleAuth(store: slowStore)
    let cancelledExchange = DispatchSemaphore(value: 0)
    var exchangeSucceeded = false
    let slowURL = try! slowAuth.beginAuthorization(clientJSON: client) { result in
        if case .success = result { exchangeSucceeded = true }
        cancelledExchange.signal()
    }
    let slowItems = URLComponents(url: slowURL, resolvingAgainstBaseURL: false)!.queryItems!
    var slowCallback = URLComponents(string: slowItems.first { $0.name == "redirect_uri" }!.value!)!
    slowCallback.queryItems = [URLQueryItem(name: "code", value: "slow-code"), slowItems.first { $0.name == "state" }!]
    _ = try! GoogleHTTP.send(slowCallback.url!)
    slowAuth.cancelAuthorization()
    expect(cancelledExchange.wait(timeout: .now() + 5) == .success && !exchangeSucceeded && !slowAuth.connected,
           "cancel during token exchange cannot save a login later")

    try! loggedIn.disconnect()
    expect(store.data == nil && !loggedIn.connected, "disconnect revokes and clears local store")
    let cancelled = DispatchSemaphore(value: 0)
    _ = try! auth.beginAuthorization(clientJSON: client) { _ in cancelled.signal() }
    auth.cancelAuthorization()
    expect(cancelled.wait(timeout: .now() + 5) == .success, "sign-in cancellation closes callback")
    print("PASS: Google Drive backend (PKCE, state, refresh/revoke, read-only search/list/read, named sheet tabs, PDF/DOCX, bounds, pointer scope, real MCP bridge, modes/off, no credentials in results/logs)")
}
