import Foundation
import CryptoKit

final class MemoryGoogleStore: GoogleTokenStore {
    var data: Data?
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
    func clear() throws { data = nil }
}

final class FakeGooglePresenter: GoogleAuthPresenter {
    var url: URL?, scheme = ""
    var callback: ((Result<URL, Error>) -> Void)?
    func start(_ url: URL, scheme: String, completion: @escaping (Result<URL, Error>) -> Void) {
        self.url = url; self.scheme = scheme; callback = completion
    }
    func cancel() { callback?(.failure(GoogleFailure(message: "Google sign-in was cancelled."))); callback = nil }
    func respond(state: String? = nil, code: String = "fixture-code", error: String? = nil, wrongScheme: Bool = false) {
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)!.queryItems!
        var result = URLComponents(string: scheme + ":/oauth2redirect")!
        result.queryItems = [URLQueryItem(name: "state", value: state ?? items.first { $0.name == "state" }!.value!), URLQueryItem(name: "code", value: code)]
        if let error { result.queryItems!.append(URLQueryItem(name: "error", value: error)) }
        if wrongScheme { result.scheme = "unrelated" }
        let finished = callback; callback = nil
        finished?(.success(result.url!))
    }
}

func testGoogleKeychainCLI() {
    let legacy = Data(#"{"clientID":"fixture","clientSecret":null,"refreshToken":"fixture-token","writable":true}"#.utf8)
    var items = ["oauth": legacy], calls: [([String], Data?)] = []
    var failPrimaryWrite = false, denyRead = false
    let store = GoogleKeychainStore { args, input in
        calls.append((args, input))
        if args == ["-i"] {
            let line = String(decoding: input!, as: UTF8.self)
            let account = line.contains("-a oauth-migration ") ? "oauth-migration" : "oauth"
            if failPrimaryWrite && account == "oauth" { return (1, Data()) }
            let value = line.components(separatedBy: " -w ")[1].dropLast()
            items[account] = Data(value.utf8)
            return (0, Data())
        }
        let account = args[args.firstIndex(of: "-a")! + 1]
        if args.first == "find-generic-password" {
            if denyRead { return (128, Data()) }
            guard let value = items[account] else { return (44, Data()) }
            return (0, value + Data([10]))
        }
        return (items.removeValue(forKey: account) == nil ? 44 : 0, Data())
    }
    expect(try! store.load() == legacy, "legacy Google item migrates without changing credentials or write grant")
    expect(items["oauth-migration"] == nil && items["oauth"] != legacy, "migration recreates primary item and removes recovery copy")
    let deletes = calls.filter { $0.0.first == "delete-generic-password" && $0.0.contains("oauth") }.count
    expect(try! store.load() == legacy, "new-format item reads after rebuild without repeating migration")
    expect(calls.filter { $0.0.first == "delete-generic-password" && $0.0.contains("oauth") }.count == deletes, "modern item is not deleted on every read")
    let replacement = Data([0, 10, 34, 92, 255])
    try! store.save(replacement)
    expect(try! store.load() == replacement, "stdin storage round-trips binary data, quotes and newlines")
    expect(calls.allSatisfy { !$0.0.joined(separator: " ").contains("fixture-token") && ($0.1 == nil || $0.0 == ["-i"]) }, "secret commands are stdin-only, never argv")
    try! store.clear(); expect(try! store.load() == nil, "clear removes primary and recovery entries")
    items = ["oauth": legacy]; failPrimaryWrite = true
    do { _ = try store.load(); expect(false, "migration recreation failure must fail") } catch {}
    expect(items["oauth"] == nil && items["oauth-migration"] != nil, "failed recreation keeps a recoverable CLI-owned login")
    failPrimaryWrite = false
    expect(try! store.load() == legacy && items["oauth-migration"] == nil, "interrupted migration recovers on next read")
    denyRead = true; let before = items
    do { _ = try store.load(); expect(false, "cancelled Keychain read must fail") } catch {}
    expect(items == before, "cancelled read never deletes stored login")
    denyRead = false
    do { try store.save(Data(repeating: 65, count: 5000)); expect(false, "overlong security command refused") } catch {}
    expect(items == before, "overlong write leaves working login unchanged")
    print("PASS: Google Keychain CLI (stdin-only secrets, one-time migration, interrupted migration recovery, read cancellation and size bounds)")
}

func testGoogleDrive() {
    testGoogleKeychainCLI()
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
    let publicStore = MemoryGoogleStore(), publicAuth = GoogleAuth(store: publicStore)
    let publicID = "fixture.apps.googleusercontent.com"
    func publicAttempt(state: String? = nil, cancel: Bool = false, error: String? = nil, wrongScheme: Bool = false) -> Bool {
        let present = FakeGooglePresenter(), done = DispatchSemaphore(value: 0)
        var success = false
        try! publicAuth.beginBuiltInAuthorization(present: present, clientID: publicID) { result in
            if case .success = result { success = true }; done.signal()
        }
        let items = URLComponents(url: present.url!, resolvingAgainstBaseURL: false)!.queryItems!
        expect(present.scheme == "com.googleusercontent.apps.fixture" && !items.contains { $0.name == "client_secret" }, "public client uses reversed scheme without secret")
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        expect(values["scope"] == GoogleAuth.scope && values["code_challenge_method"] == "S256" && values["access_type"] == "offline", "public client consent uses read-only scope, PKCE and offline access")
        expect(values["redirect_uri"] == "com.googleusercontent.apps.fixture:/oauth2redirect", "public client redirect matches callback scheme")
        if cancel { publicAuth.cancelAuthorization() } else { present.respond(state: state, error: error, wrongScheme: wrongScheme) }
        expect(done.wait(timeout: .now() + 5) == .success, "public client callback finishes")
        return success
    }
    expect(!publicAttempt(state: "wrong") && !publicAuth.connected, "public client rejects wrong state")
    expect(publicAttempt() && publicAuth.connected, "public client stores offline login")
    expect(!publicAttempt(cancel: true) && publicAuth.connected, "public client cancellation preserves working login")
    expect(!publicAttempt(error: "access_denied") && publicAuth.connected, "denied consent preserves working public login")
    expect(!publicAttempt(error: "admin_policy_enforced") && publicAuth.connected, "administrator denial preserves working public login")
    expect(!publicAttempt(wrongScheme: true) && publicAuth.connected, "wrong callback scheme rejected")
    expect(publicAuth.publicClientID == publicID && loggedIn.publicClientID == nil, "saved public and Desktop clients select different reconnect flows")
    let stagedStore = MemoryGoogleStore(), stagedAuth = GoogleAuth(store: stagedStore), stagedPresenter = FakeGooglePresenter()
    let stagedDone = DispatchSemaphore(value: 0)
    var stagedSuccess = false
    try! stagedAuth.beginBuiltInAuthorization(present: stagedPresenter) { result in
        if case .success = result { stagedSuccess = true }; stagedDone.signal()
    }
    let configuredItems = URLComponents(url: stagedPresenter.url!, resolvingAgainstBaseURL: false)!.queryItems!
    expect(configuredItems.contains { $0.name == "client_id" && $0.value == GoogleAuth.builtInClientID } && !GoogleAuth.builtInClientID.isEmpty, "default authorization uses configured public client")
    let beforeSlow = try! JSONSerialization.jsonObject(with: GoogleHTTP.send(base.appendingPathComponent("records")).data) as! [[String: Any]]
    stagedPresenter.respond(code: "slow-code")
    var exchangeStarted = false
    for _ in 0..<100 {
        let current = try! JSONSerialization.jsonObject(with: GoogleHTTP.send(base.appendingPathComponent("records")).data) as! [[String: Any]]
        if current.count > beforeSlow.count { exchangeStarted = true; break }
        Thread.sleep(forTimeInterval: 0.01)
    }
    expect(exchangeStarted, "public token exchange began before cancellation")
    stagedAuth.cancelAuthorization()
    expect(stagedDone.wait(timeout: .now() + 5) == .success && !stagedSuccess && !stagedAuth.connected, "cancel during public token exchange cannot save credentials")
    _ = try! publicAuth.accessToken(forceRefresh: true)
    let publicRecords = try! JSONSerialization.jsonObject(with: GoogleHTTP.send(base.appendingPathComponent("records")).data) as! [[String: Any]]
    let publicRequests = publicRecords.filter { ($0["fields"] as? [String: Any])?["client_id"] as? [String] == [publicID] }
    expect(!publicRequests.isEmpty && publicRequests.allSatisfy { ($0["fields"] as? [String: Any])?["client_secret"] == nil }, "public exchange and refresh omit client secret")
    let drive = DriveLink(auth: loggedIn)
    DriveLink.shared = drive
    drive.enabled = true
    defer { drive.enabled = true; DriveLink.folders = []; DriveLink.pausedFolders = [] }
    // The app is the gate: no shared Drive folder means no Drive tools at all.
    DriveLink.folders = []; DriveLink.pausedFolders = []
    expect(!drive.active && drive.tools().isEmpty, "connected but no folders: no Drive tools")
    DriveLink.folders = [DriveFolder(id: "allowed", name: "Allowed")]
    expect(drive.active && drive.rule().contains("\"Allowed\""), "a shared folder turns the tools on and is named to the model")
    let context = ToolContext(room: UUID(), roots: [WorkspaceRoot(path: root.path, directory: true)])
    func call(_ tool: String, _ args: [String: Any]) -> [String: Any] {
        let result = drive.call(tool, args, context: context)
        expect(result["isError"] as? Bool == false, "Drive tool succeeds: \(tool) \(args)")
        let text = ((result["content"] as! [[String: Any]])[0]["text"] as! String)
        return try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }
    let paged = call("drive_search", ["query": "O'Brien\\lab", "type": "doc"])
    expect((paged["files"] as? [[String: Any]])?.contains { $0["id"] as? String == "later" } == true, "search includes allowed matches beyond first page")
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
    expect(drive.call("drive_read", ["file": "escape-shortcut"], context: context)["isError"] as? Bool == true, "shortcut target outside shared folders refused")
    // Outside the shared folders: refused; the search drops it; the plain list shows the shared folders.
    expect(drive.call("drive_read", ["file": "outside"], context: context)["isError"] as? Bool == true, "file outside the shared folders refused")
    expect(drive.call("drive_list", ["folder": "other"], context: context)["isError"] as? Bool == true, "folder outside the shared folders refused")
    let found = (call("drive_search", ["query": "fixture"])["files"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
    expect(Set(found ?? []) == Set(["doc", "later"]), "search keeps only files inside the shared folders")
    expect((call("drive_list", [:])["files"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["allowed"], "list without a folder shows the shared folders")
    expect(call("drive_list", ["folder": "Allowed"])["files"] != nil, "a shared folder by its name")
    let farPointer = root.appendingPathComponent("far.gdoc")
    try! Data(#"{"doc_id":"outside"}"#.utf8).write(to: farPointer)
    expect(drive.call("drive_read", ["file": farPointer.path], context: context)["isError"] as? Bool == true, "local pointer cannot bypass shared Drive folders")
    DriveLink.pausedFolders = ["allowed"]
    expect(!drive.active, "the eye off on the only folder: no Drive tools")
    DriveLink.pausedFolders = []
    // The folder picker (the user's own choices): subfolders, a pasted link, the account shown in the app.
    expect((try? drive.childFolders(of: "root"))?.isEmpty == false, "picker lists folders")
    expect((try? drive.folder(from: "https://drive.google.com/drive/folders/allowed"))?.id == "allowed", "a pasted folder link")
    expect((try? drive.folder(from: "doc")) == nil, "a document link is not a folder")
    expect(drive.accountEmail() == "fixture@example.invalid", "the signed-in account for the sidebar")
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
    let grants = records.filter { $0["path"] as? String == "/token" && ($0["fields"] as? [String: [String]])?["client_id"] == ["fixture-client"] }
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
    do { _ = try revoked.accessToken(); expect(false, "revoked login must fail") } catch { expect(!revoked.connected && revoked.needsReconnect, "invalid_grant requires reconnect") }
    let again = try! revoked.beginReauthorization { _ in }
    expect(URLComponents(url: again, resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.name == "client_id" && $0.value == "fixture-client" }, "reconnect reuses the saved client")
    revoked.cancelAuthorization()
    expect(!loggedIn.needsReconnect, "a working login needs no reconnect")

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
    DriveLink.folders.append(DriveFolder(id: "other", name: "Other"))
    DriveLink.pausedFolders = ["allowed"]
    DriveLink.pausedFolders = []
    expect(pending.wait(timeout: .now() + 5) == .success && withheld["isError"] as? Bool == true, "in-flight result withheld after folder pause with another folder active")

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
    // Write access is opt-in twice: a Google grant and an explicit folder rule.
    let oldDocs = DriveLink.docsAPI, oldUpload = DriveLink.uploadAPI, oldSlides = DriveLink.slidesAPI
    DriveLink.docsAPI = base.appendingPathComponent("docs"); DriveLink.uploadAPI = base.appendingPathComponent("upload"); DriveLink.slidesAPI = base.appendingPathComponent("slides")
    defer { DriveLink.docsAPI = oldDocs; DriveLink.uploadAPI = oldUpload; DriveLink.slidesAPI = oldSlides; DriveLink.writeRules = [:] }
    let writeStore = MemoryGoogleStore(), writeAuth = GoogleAuth(store: writeStore), presenter = FakeGooglePresenter()
    let writeDone = DispatchSemaphore(value: 0)
    var writeLogin = false
    try! writeAuth.beginBuiltInAuthorization(present: presenter, clientID: "writer.apps.googleusercontent.com", writable: true) { result in
        if case .success = result { writeLogin = true }; writeDone.signal()
    }
    expect(URLComponents(url: presenter.url!, resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.name == "scope" && $0.value == GoogleAuth.writeScope }, "write consent explicitly requests write scope")
    presenter.respond(code: "write-code")
    expect(writeDone.wait(timeout: .now() + 5) == .success && writeLogin && writeAuth.canWrite, "write grant stored separately from legacy read login")
    _ = try! writeAuth.accessToken(forceRefresh: true)
    let writer = DriveLink(auth: writeAuth)
    DriveLink.folders = [DriveFolder(id: "allowed", name: "Old name"), DriveFolder(id: "child", name: "Child")]
    DriveLink.pausedFolders = []; DriveLink.writeRules = [:]
    expect(!writer.tools().contains { $0["name"] as? String == "drive_create" }, "write OAuth without writable folder offers no write tools")
    DriveLink.writeRules = ["allowed": true, "child": false]
    expect((try! writer.isWritable("doc")) && !(try! writer.isWritable("nested-doc")), "child read-only override wins over writable parent")
    expect(writer.call("drive_create", ["folder": "child", "name": "Blocked", "kind": "text"], context: context)["isError"] as? Bool == true, "read-only child rejects creation")
    expect(writer.call("drive_create", ["folder": "other", "name": "Blocked", "kind": "text"], context: context)["isError"] as? Bool == true, "outside shared folders rejects creation")
    for kind in ["folder", "text", "doc"] {
        expect(writer.call("drive_create", ["folder": "allowed", "name": "Fixture " + kind, "kind": kind, "text": "한글 content"], context: context)["isError"] as? Bool == false, "create permitted " + kind)
    }
    expect(writer.call("drive_read", ["file": "doc"], context: context)["isError"] as? Bool == false, "writable Doc read supplies revision")
    let edit: [String: Any] = ["file": "doc", "old": "Fixture", "new": "Edited", "revision": "revision-1"]
    expect(writer.call("drive_edit_doc", edit, context: context)["isError"] as? Bool == false, "revision-bound Doc edit succeeds")
    var stale = edit; stale["revision"] = "old-revision"
    expect(writer.call("drive_edit_doc", stale, context: context)["isError"] as? Bool == true, "stale revision rejected without blind retry")
    func slideCall(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        let result = writer.call(name, arguments, context: context)
        expect(result["isError"] as? Bool == false, "Slides tool succeeds: " + name)
        let content = (result["content"] as! [[String: Any]])[0]["text"] as! String
        return try! JSONSerialization.jsonObject(with: Data(content.utf8)) as! [String: Any]
    }
    let structured = slideCall("drive_slides_get", ["file": "slides", "start": 1, "limit": 1])
    expect(structured["revision"] as? String == "slides-revision-1" && structured["slideCount"] as? Int == 2 && (structured["slides"] as? [[String: Any]])?.first?["objectId"] as? String == "page-two", "Slides structure paginates with revision and stable IDs")
    expect(writer.call("drive_slides_get", ["file": "outside"], context: context)["isError"] as? Bool == true, "Slides structure cannot bypass folder gate")
    _ = slideCall("drive_create", ["folder": "allowed", "name": "New slides", "kind": "slides"])
    expect(writer.call("drive_create", ["folder": "allowed", "name": "New slides", "kind": "slides", "text": "not imported"], context: context)["isError"] as? Bool == true, "Slides creation does not silently drop supplied text")
    let slideEdit: [String: Any] = ["file": "slides", "action": "replace_text", "old": "Fixture", "new": "Edited", "slide": "page-one", "revision": "slides-revision-1"]
    _ = slideCall("drive_edit_slides", slideEdit)
    _ = slideCall("drive_edit_slides", ["file": "slides", "action": "add_slide", "title": "New title", "text": "New body", "index": 1, "revision": "slides-revision-1"])
    _ = slideCall("drive_edit_slides", ["file": "slides", "action": "delete_slide", "slide": "page-two", "revision": "slides-revision-1"])
    var wrongRevision = slideEdit; wrongRevision["revision"] = "old-revision"
    expect(writer.call("drive_edit_slides", wrongRevision, context: context)["isError"] as? Bool == true, "Slides edit rejects changed revision")
    var wrongSlide = slideEdit; wrongSlide["slide"] = "unrelated-page"
    expect(writer.call("drive_edit_slides", wrongSlide, context: context)["isError"] as? Bool == true, "Slides edits reject page IDs outside the presentation")
    expect(writer.call("drive_edit_slides", ["file": "nested-doc", "action": "delete_slide", "slide": "page-one", "revision": "slides-revision-1"], context: context)["isError"] as? Bool == true, "read-only child blocks Slides mutation")
    expect(writer.call("drive_trash", ["file": "allowed", "confirm_name": "Fixture allowed"], context: context)["isError"] as? Bool == true, "folder trash is not offered")
    expect(writer.call("drive_trash", ["file": "doc", "confirm_name": "Wrong name"], context: context)["isError"] as? Bool == true, "trash requires current exact filename")
    expect(writer.call("drive_trash", ["file": "outside", "confirm_name": "Fixture outside"], context: context)["isError"] as? Bool == true, "trash outside writable folder refused")
    _ = slideCall("drive_trash", ["file": "doc", "confirm_name": "Fixture doc"])
    _ = slideCall("drive_trash", ["file": "slides", "confirm_name": "Fixture slides"])
    let mutationRecords = try! JSONSerialization.jsonObject(with: GoogleHTTP.send(base.appendingPathComponent("records")).data) as! [[String: Any]]
    let batches = mutationRecords.filter { $0["path"] as? String == "/slides/presentations/slides:batchUpdate" }
    expect(batches.count == 3, "failed Slides preconditions never send mutation requests")
    let replace = ((batches[0]["body"] as! [String: Any])["requests"] as! [[String: Any]])[0]["replaceAllText"] as! [String: Any]
    expect(replace["pageObjectIds"] as? [String] == ["page-one"], "text replacement targets only requested page")
    let creation = (batches[1]["body"] as! [String: Any])["requests"] as! [[String: Any]]
    expect(creation.count == 7 && creation[0]["createSlide"] != nil, "new page includes two text boxes, content and text styling")
    let trashed = mutationRecords.filter { $0["method"] as? String == "PATCH" }
    expect(trashed.count == 2 && trashed.allSatisfy { ($0["body"] as? [String: Bool]) == ["trashed": true] }, "deletion only sets trash, never permanently deletes")
    print("PASS: Slides structure/create/text/page edits, revision conflicts, scoped trash and invalid-target protection")
    DriveLink.writeRules["child"] = true
    expect(try! writer.isWritable("nested-doc"), "explicit writable child override works")
    DriveLink.pausedFolders = ["child"]
    expect(!(try! writer.isWritable("nested-doc")), "paused child cannot inherit access from shared parent")
    DriveLink.pausedFolders = []
    let renamed = try! writer.folder(from: "allowed")
    expect(renamed.id == "allowed" && renamed.name != "Old name", "folder metadata refresh preserves ID and gets current name")
    expect(!drive.canWrite, "legacy read-only login stays read only")
    let treeRoot = DriveFolder(id: "allowed", name: "Research"), child = DriveFolder(id: "child", name: "Drafts"), grandchild = DriveFolder(id: "grand", name: "Figures")
    let branches = ["allowed": [child], "child": [grandchild], "grand": [treeRoot]]
    expect(DriveTree.rows(roots: [treeRoot], children: branches, expanded: []).count == 1, "collapsed tree never reveals descendants")
    let rows = DriveTree.rows(roots: [treeRoot], children: branches, expanded: ["allowed", "child", "grand"])
    expect(rows.map { $0.folder.id } == ["allowed", "child", "grand"] && rows[2].depth == 2 && rows[2].rootID == "allowed", "tree expands with stable IDs, indentation and cycle protection")
    expect(DriveTree.writable(rows[2], rules: ["allowed": true]) && !DriveTree.writable(rows[2], rules: ["allowed": true, "child": false]), "tree icons follow nearest ancestor permission")
    expect((try! writer.childFolders(of: "allowed")).contains { $0.id == "later" }, "folder browsing follows next pages")
    let center = DriveCenter(startRefreshing: false)
    center.folders = [treeRoot]; center.children = branches; center.expanded = ["allowed", "child"]
    center.writeRules = ["allowed": true]
    center.setWritable(child, false, rootID: "allowed")
    center.folders = [DriveFolder(id: "allowed", name: "Renamed Research")]
    expect(center.writeRules["child"] == false, "automatic root rename preserves subtree write override")
    center.folders = []
    expect(center.writeRules["child"] == nil && center.writeRules["allowed"] == nil, "removing shared root clears associated subtree overrides")
    print("PASS: Drive folder tree (lazy rows, cycles, inherited permissions, pagination, rename preservation and root cleanup)")
    print("PASS: Drive writes (explicit OAuth, folder inheritance/override/pause, create folder/text/Doc, revision conflict, refresh compatibility)")
    print("PASS: Google Drive backend (PKCE, state, refresh/revoke/reconnect, shared Drive folders only, read-only search/list/read, named sheet tabs, PDF/DOCX, bounds, pointer scope, picker folders, real MCP bridge, modes/off, no credentials in results/logs)")
}
