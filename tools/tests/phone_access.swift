import Foundation
import AppKit
import CoreImage
import AIAccounts
import AILocalization
import AIRemote
@testable import AIProjects
@testable import AIChat

/// iPhone access (PhoneAccess.swift): `tailscale status`/`serve status` JSON read the way the window shows it; only iOS
/// peers count as phones, an iPhone named "localhost" takes its DNS name, and nothing served means no web access.
func testPhoneAccess() {
    let status = """
    {"BackendState":"Running","CertDomains":["mac.tail1.ts.net"],
     "Self":{"DNSName":"mac.tail1.ts.net.","OS":"macOS"},
     "Peer":{"k1":{"ID":"1","HostName":"localhost","DNSName":"iphone-15-pro.tail1.ts.net.","OS":"iOS","Online":true,"LastSeen":"0001-01-01T00:00:00Z"},
             "k2":{"ID":"2","HostName":"old-phone","DNSName":"","OS":"iOS","Online":false,"LastSeen":"2026-11-15T10:00:00.5Z"},
             "k3":{"ID":"3","HostName":"mini","DNSName":"mini.tail1.ts.net.","OS":"macOS","Online":true}}}
    """
    let serve = """
    {"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8787"}}}}}
    """
    let s = TailnetStatus.parse(status: Data(status.utf8), serve: Data(serve.utf8))
    expect(s.state == .running && s.host == "mac.tail1.ts.net" && s.https, "phone access: host and HTTPS")
    expect(s.url?.absoluteString == "https://mac.tail1.ts.net/", "phone access: the QR's address")
    expect(s.served == "http://127.0.0.1:8787", "phone access: what serve sends the address to")
    expect(s.phones.map(\.name) == ["iphone-15-pro", "old-phone"], "phone access: only iPhones, online first, named by DNS")
    expect(s.phones[0].online && s.phones[0].lastSeen == nil, "phone access: an online phone has no last seen")
    expect(!s.phones[1].online && s.phones[1].lastSeen != nil, "phone access: an offline phone's last seen")
    expect(s.macs == ["mini.tail1.ts.net": true], "phone access: the other Macs on the tailnet, by DNS name, with Online")
    let idle = TailnetStatus.parse(status: Data(#"{"BackendState":"Stopped","Self":{"DNSName":"mac.tail1.ts.net."}}"#.utf8), serve: Data("{}".utf8))
    expect(idle.state == .stopped && idle.served == nil && !idle.https && idle.phones.isEmpty, "phone access: stopped, nothing served")
    expect(TailnetStatus.parse(status: nil, serve: nil).state == .missing, "phone access: no CLI output means not installed")
    expect(TailnetStatus.qr("https://mac.tail1.ts.net/") != nil, "phone access: the QR is drawn")
}

/// The phone page's /api/ (PhoneServer.handle → Discussion.remote*): a message with a photo sent from the phone starts a
/// turn like the message box, the chat and its picture come back, the list has it, and an approval decided on the phone
/// leaves ProjectCenter (so the Mac's card goes too); a second decision and unknown chats are refused.
func testPhoneServer() {
    let model = AppModel()
    model.accounts = [Account(id: "phone-claude", provider: .claude, name: "Phone Claude")]
    let chat = Discussion(model: model)
    chat.configure { $0.mode = 0; $0.soloAccountID = "phone-claude" }
    var asked: [String] = []
    chat.answer = { _, prompt, _ in asked.append(prompt); return .success("phone answer") }
    chat.workspaceAnswer = { _, _, _, _, _ in .success("phone answer") }
    chat.debateAnswer = { _, _, _, _, _ in .success("phone answer") }
    let server = PhoneServer.shared
    let saved = server.discussion
    server.discussion = chat
    defer { server.discussion = saved }
    func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) -> (Int, [String: Any]) {
        let data = body.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let parts = path.split(separator: "?", maxSplits: 1)
        let query = parts.count > 1 ? Dictionary(uniqueKeysWithValues: parts[1].split(separator: "&").map { item -> (String, String) in
            let kv = item.split(separator: "="); return (String(kv[0]), kv.count > 1 ? String(kv[1]) : "") }) : [:]
        let response = server.handle(RemoteRequest(method: method, path: String(parts[0]), query: query, body: data))
        return (response.status, ((try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]) ?? ["raw": response.body])
    }
    func settle() {
        let deadline = Date().addingTimeInterval(5)
        while !chat.runningRooms.isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    let room = chat.currentID
    let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!
    let sent = call("POST", "/api/chat/\(room.uuidString)/send", ["text": "from the phone", "images": [png.base64EncodedString()]])
    expect(sent.0 == 200, "phone server: the message is sent \(sent.1)")
    settle()
    expect(chat.conversation(room).turns.count == 1 && chat.conversation(room).turns[0].question == "from the phone"
           && chat.conversation(room).turns[0].images?.count == 1 && chat.conversation(room).turns[0].final == "phone answer",
           "phone server: one turn with the photo, answered")
    expect(chat.draft.isEmpty, "phone server: the Mac's message box is left alone")
    let opened = call("GET", "/api/chat/\(room.uuidString)?open=1")
    let turns = opened.1["turns"] as? [[String: Any]] ?? []
    expect(opened.0 == 200 && turns.count == 2 && turns[0]["mine"] as? Bool == true && turns[1]["text"] as? String == "phone answer"
           && turns[1]["name"] as? String != nil, "phone server: the chat reads as my message, then the answer")
    let link = (turns[0]["images"] as? [String])?.first ?? ""
    let picture = server.handle(RemoteRequest(method: "GET", path: link))
    expect(picture.status == 200 && picture.type == "image/png" && !picture.body.isEmpty, "phone server: the photo is served")
    let list = call("GET", "/api/chats").1["sections"] as? [[String: Any]] ?? []
    expect(list.contains { ($0["chats"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == room.uuidString } }, "phone server: the list has the chat")

    let request = ProjectApproval(room: room, run: UUID(), title: "git_push", detail: "origin main")
    ProjectCenter.shared.requests.append(request)
    let card = (call("GET", "/api/chat/\(room.uuidString)").1["approvals"] as? [[String: Any]])?.first
    expect(card?["id"] as? String == request.id.uuidString && card?["detail"] as? String == "origin main", "phone server: the approval card with its details")
    expect(call("POST", "/api/approval/\(request.id.uuidString)", ["allow": false]).0 == 200
           && !ProjectCenter.shared.requests.contains { $0.id == request.id }, "phone server: denied from the phone, gone everywhere")
    expect(call("POST", "/api/approval/\(request.id.uuidString)", ["allow": true]).0 == 409, "phone server: decided once only")
    expect(call("POST", "/api/chat/\(UUID().uuidString)/send", ["text": "x"]).0 == 409, "phone server: an unknown chat is refused")
    expect(call("POST", "/api/chat/\(room.uuidString)/send", ["text": "  "]).0 == 409, "phone server: nothing to send is refused")
    expect(call("GET", "/api/nothing").0 == 404, "phone server: unknown paths")
    expect(turns.allSatisfy { ($0["key"] as? String).map { !$0.isEmpty } ?? false } && Set(turns.compactMap { $0["key"] as? String }).count == turns.count,
           "phone server: every message has its own key, so the page redraws only what changed")
    expect(turns[0]["time"] as? String != nil && turns[0]["day"] as? String != nil, "phone server: my message has its time and the day line")

    // Search finds a chat by words in its messages; a new chat is made only with its first message, and the Mac's open chat stays open.
    let found = call("GET", "/api/search?q=phone").1["results"] as? [[String: Any]] ?? []
    expect(found.first?["id"] as? String == room.uuidString && found.first?["turn"] as? String == chat.conversation(room).turns[0].id.uuidString,
           "phone server: search finds the chat and the turn")
    expect((call("GET", "/api/search?q=").1["results"] as? [Any])?.isEmpty == true, "phone server: an empty search finds nothing")
    let before = chat.conversations.count, open = chat.currentID
    expect(call("POST", "/api/chat/new", ["text": " "]).0 == 409 && chat.conversations.count == before, "phone server: an empty new chat is not made")
    expect(call("POST", "/api/chat/new", ["text": "x", "project": "nowhere"]).0 == 409 && chat.conversations.count == before,
           "phone server: an unknown project is refused")
    let made = call("POST", "/api/chat/new", ["text": "a new chat from the phone"])
    let newRoom = (made.1["id"] as? String).flatMap(UUID.init(uuidString:))
    expect(made.0 == 200 && newRoom != nil && newRoom != room, "phone server: a new chat \(made.1)")
    settle()
    if let newRoom {
        expect(chat.conversation(newRoom).turns.first?.question == "a new chat from the phone" && chat.conversation(newRoom).turns.first?.final == "phone answer",
               "phone server: the new chat got the message and its answer")
        expect(chat.currentID == open, "phone server: the Mac's open chat is left as it was")
        let newList = call("GET", "/api/chats").1["sections"] as? [[String: Any]] ?? []
        expect(newList.contains { ($0["chats"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == newRoom.uuidString } }, "phone server: the list has the new chat")
    }
}

/// Updating this Mac from the phone page: /api/update needs the key (401), shows the updater's state, refuses a second
/// start while one runs (409); a remote install's new app acknowledges only once the phone page answers, and never
/// after its deadline, so install_app.py puts the old app back (tools/tests/test_install_app.py covers that side).
func testPhoneUpdates() {
    final class FakeUpdates: PhoneUpdates {
        var busy = false, checks = 0, installs = 0
        func phoneState(at now: Date) -> [String: Any] {
            ["current": "abc1234aaaa", "available": "def5678bbbb", "channel": "stable", "busy": busy, "waiting": false, "work": 2, "status": busy ? "testing" : "available"]
        }
        func phoneCheck() -> String? { if busy { return "busy" }; checks += 1; return nil }
        func phoneInstall() -> String? { if busy { return "busy" }; installs += 1; busy = true; return nil }
    }
    let fake = FakeUpdates(), server = PhoneServer.shared, saved = server.updates
    server.updates = fake
    defer { server.updates = saved }
    let key = RemoteHTTP.newKey()
    var port: UInt16 = 0
    var remote: RemoteServer?
    for candidate in UInt16(47430)...UInt16(47460) {
        let s = RemoteServer(port: candidate, key: key, page: { Data() }) { server.handle($0) }
        if (try? s.start()) != nil { remote = s; port = candidate; break }
    }
    defer { remote?.stop() }
    func call(_ method: String, _ path: String, key: String?) -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let key { request.setValue(key, forHTTPHeaderField: "X-Remote-Key") }
        if method == "POST" { request.httpBody = Data("{}".utf8) }
        var result: (Int, [String: Any])?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0, (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:])
        }.resume()
        let deadline = Date().addingTimeInterval(10)
        while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return result ?? (0, [:])
    }
    var first = call("GET", "/api/update", key: key)
    for _ in 0..<20 where first.0 == 0 { first = call("GET", "/api/update", key: key) }
    expect(first.0 == 200 && first.1["current"] as? String == "abc1234aaaa" && first.1["available"] as? String == "def5678bbbb"
           && first.1["work"] as? Int == 2 && first.1["busy"] as? Bool == false, "phone updates: the state \(first)")
    expect(call("GET", "/api/update", key: nil).0 == 401 && call("POST", "/api/update/install", key: "wrong").0 == 401 && fake.installs == 0,
           "phone updates: no key, no state and no install")
    expect(call("POST", "/api/update/check", key: key).0 == 200 && fake.checks == 1, "phone updates: a check")
    let started = call("POST", "/api/update/install", key: key)
    expect(started.0 == 200 && started.1["busy"] as? Bool == true && fake.installs == 1, "phone updates: the install starts and says so")
    expect(call("POST", "/api/update/install", key: key).0 == 409 && call("POST", "/api/update/check", key: key).0 == 409 && fake.installs == 1,
           "phone updates: a second start while one runs is 409")
    expect(call("GET", "/api/update/elsewhere", key: key).0 == 404 && call("GET", "/api/update/install", key: key).0 == 404,
           "phone updates: unknown update paths; install only by POST")
    server.updates = nil
    expect(call("GET", "/api/update", key: key).0 == 404, "phone updates: no updater, not ready")
    server.updates = fake

    // The new app's readiness check: a 200 from the page with its key; not with a wrong key, not with nothing listening.
    func probe(_ port: UInt16, _ key: String) -> Bool? {
        var ok: Bool?
        PhoneServer.probe(port: port, key: key, timeout: 3) { ok = $0 }
        let deadline = Date().addingTimeInterval(5)
        while ok == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return ok
    }
    expect(probe(port, key) == true, "phone updates: the page answers its key")
    expect(probe(port, "wrong") == false, "phone updates: a wrong key is not ready")
    remote?.stop()
    expect(probe(port, key) == false, "phone updates: no listener is not ready")

    // Acknowledging: right away once ready; never while the page does not come up, nor after the deadline.
    let updates = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("phone-updates-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: updates) }
    let record: [String: Any] = ["phase": "starting", "target": "/Applications/X.app", "revision": "r1", "token": UUID().uuidString, "remote": true]
    expect(InstallAck.token(record, app: "/Applications/X.app", revision: "r1") != nil
           && InstallAck.token(record, app: "/Applications/Y.app", revision: "r1") == nil
           && InstallAck.token(record.merging(["phase": "failed"]) { $1 }, app: "/Applications/X.app", revision: "r1") == nil,
           "phone updates: only the launch the transaction started acknowledges")
    func waitAck(_ answers: [Bool], seconds: TimeInterval) -> (acked: Bool, asked: Int) {
        let token = UUID().uuidString
        var asked = 0, acked = false
        InstallAck.whenReady({ done in
            asked += 1
            DispatchQueue.main.async { done(answers[min(asked - 1, answers.count - 1)]) }
        }, every: 0.05, until: Date().addingTimeInterval(seconds)) {
            InstallAck.write(token: token, revision: "r1", in: updates); acked = true
        }
        let end = Date().addingTimeInterval(seconds + 0.3)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let file = updates.appendingPathComponent(token + ".ack")
        let written = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        expect(acked == (written?["revision"] as? String == "r1"), "phone updates: the ack file is the acknowledgement")
        return (acked, asked)
    }
    let never = waitAck([false], seconds: 0.4)
    expect(!never.acked && never.asked >= 3, "phone updates: a page that never comes up is never acknowledged (\(never.asked) asks)")
    let later = waitAck([false, false, true], seconds: 1)
    expect(later.acked && later.asked == 3, "phone updates: acknowledged once the page answers")
    let late = waitAck([false], seconds: 0)
    expect(!late.acked, "phone updates: nothing after the deadline")

    let page = String(data: RemotePage.html(), encoding: .utf8) ?? ""
    expect(page.contains("'/api/update/'") && page.contains("#update") && page.contains("updTrack"), "phone updates: the page has the update screen")

    // The real updater: only a version a check found is installed from the phone; a rollback reads as one.
    let updater = Updater()
    if updater.available == nil { expect(updater.phoneInstall() != nil, "phone updates: no new version, no install") }
    let state = updater.phoneState()
    expect(state["current"] is String && state["busy"] as? Bool == false && state["channel"] as? String != nil, "phone updates: the updater's state")
    expect(Updater.describe(["status": "failed", "detail": "x", "lastResult": "rolled-back", "lastDetail": "x"]).contains(L("되돌렸어요", "went back")),
           "phone updates: a rollback says so")
}
