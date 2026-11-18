import Foundation
import AppKit
import CoreImage
import AIAccounts
import AIRemote
@testable import AIRuntime
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

func testPhoneUsage() {
    final class FakeUsage: PhoneUsage {
        var snapshot: PhoneUsageSnapshot
        var refreshes = 0
        init(_ snapshot: PhoneUsageSnapshot) { self.snapshot = snapshot }
        func phoneUsageSnapshot() -> PhoneUsageSnapshot { snapshot }
        func phoneRefreshUsage() {
            refreshes += 1
            // Replace immediately to prove POST returns the snapshot that was already available.
            snapshot = PhoneUsageSnapshot(device: snapshot.device, accounts: [], readings: [:], colors: [:])
        }
    }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let first = Account(id: "personal", provider: .codex, name: "Personal")
    let second = Account(id: "school", provider: .claude, name: "School school@example.test")
    let third = Account(id: "work", provider: .codex, name: "Work")
    let local = Account(id: "local", provider: .ollama, name: "Local")
    var personal = AIUsage(name: first.name, account: first)
    personal.fiveHour = UsageWindow(usedPercent: 90, resetsAt: now.addingTimeInterval(-1))
    personal.weekly = UsageWindow(usedPercent: 79, resetsAt: now.addingTimeInterval(3600))
    personal.detail = "private@example.test · plus"
    personal.checkedAt = now.addingTimeInterval(-30)
    var school = AIUsage(name: second.name, account: second)
    school.detail = "school@example.test"
    school.note = "Sign in as school@example.test to continue"
    school.extras = ["Extra limit", "Account: school@example.test"]
    school.needsLogin = true
    school.checkedAt = now.addingTimeInterval(-120)
    var ollama = AIUsage(name: local.name, account: local)
    ollama.fiveHour = UsageWindow(usedPercent: 0, resetsAt: nil)
    ollama.weekly = ollama.fiveHour
    var removed = AIUsage(name: "Removed")
    removed.checkedAt = now.addingTimeInterval(-600)
    let fake = FakeUsage(PhoneUsageSnapshot(device: "Mini", accounts: [first, second, third, local],
                                            readings: [first.id: personal, second.id: school, local.id: ollama, "removed": removed],
                                            colors: [.codex: ["#008850", "#00bb80"]]))
    let server = PhoneServer(enabled: false)
    func call(_ method: String, _ path: String, uptime: TimeInterval = 100) -> RemoteResponse {
        server.handle(RemoteRequest(method: method, path: path), now: now, uptime: uptime)
    }
    func object(_ response: RemoteResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }
    expect(call("GET", "/api/usage").status == 404, "phone usage: no provider, not ready")
    server.usage = fake

    let initial = call("GET", "/api/usage"), data = object(initial)
    let groups = data["groups"] as? [[String: Any]] ?? []
    let codex = groups.first?["accounts"] as? [[String: Any]] ?? []
    let personalRow = codex.first ?? [:]
    let schoolRows = groups.first { $0["provider"] as? String == "claude" }?["accounts"] as? [[String: Any]] ?? []
    let schoolRow = schoolRows.first ?? [:]
    let localRows = groups.last?["accounts"] as? [[String: Any]] ?? []
    let localRow = localRows.first ?? [:]
    let five = personalRow["fiveHour"] as? [String: Any]
    let week = personalRow["weekly"] as? [String: Any]
    expect(initial.status == 200 && data["device"] as? String == "Mini"
           && data["checkedAt"] as? Double == (now.timeIntervalSince1970 - 120) * 1000,
           "phone usage: oldest reading for a current account, ignoring removed accounts")
    expect(groups.compactMap { $0["provider"] as? String } == ["codex", "claude", "ollama"]
           && groups.first?["color"] as? [String] == ["#008850", "#00bb80"]
           && codex.compactMap { $0["name"] as? String } == ["Personal", "Work"],
           "phone usage: groups ordered by first appearance, accounts in settings order")
    expect(personalRow["plan"] as? String == "plus" && five?["left"] as? Double == 100
           && five?["resetsAt"] as? Double == (now.timeIntervalSince1970 - 1) * 1000
           && week?["left"] as? Double == 21 && week?["resetsAt"] as? Double == (now.timeIntervalSince1970 + 3600) * 1000,
           "phone usage: plan and raw reset dates, expired limits display 100%")
    expect(schoolRow["fiveHour"] is NSNull && schoolRow["weekly"] is NSNull && schoolRow["plan"] is NSNull
           && schoolRow["needsLogin"] as? Bool == true
           && schoolRow["note"] as? String == "Sign in as … to continue"
           && schoolRow["extras"] as? [String] == ["Extra limit", "Account: …"]
           && codex.last?["weekly"] is NSNull,
           "phone usage: missing limits and readings are null; note, extras and login state are retained")
    expect(localRow["fiveHour"] is NSNull && localRow["weekly"] is NSNull
           && localRow["extras"] as? [String] == [L("한도 없음", "No limit")],
           "phone usage: Ollama has no limits even when the status icon uses synthetic full bars")
    expect(!String(decoding: initial.body, as: UTF8.self).contains("@"), "phone usage: no email anywhere in the response")
    expect(call("GET", "/api/usage/refresh").status == 404 && call("POST", "/api/usage").status == 404 && fake.refreshes == 0,
           "phone usage: only POST refresh can start a measurement")
    let started = call("POST", "/api/usage/refresh")
    expect(started.status == 200 && object(started)["checkedAt"] as? Double == data["checkedAt"] as? Double && fake.refreshes == 1,
           "phone usage: the first refresh returns the cached snapshot immediately")
    let throttled = call("POST", "/api/usage/refresh", uptime: 159.99)
    expect(throttled.status == 200 && object(throttled)["checkedAt"] is NSNull && fake.refreshes == 1,
           "phone usage: an early repeat returns the latest snapshot without starting another measurement")
    expect(call("POST", "/api/usage/refresh", uptime: 160).status == 200 && fake.refreshes == 2,
           "phone usage: refresh is accepted at the 60-second boundary")

    let page = String(decoding: RemotePage.html(), as: UTF8.self)
    expect(page.contains("id=\"usagePanel\"") && page.contains("'/api/usage/refresh'") && page.contains("45000"),
           "phone usage: the page has the usage panel, refresh route and polling timer")
}
