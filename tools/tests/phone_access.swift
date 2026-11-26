import Foundation
import AppKit
import CoreImage
import AIAccounts
import AIChatRecords
import AILocalization
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
    // AI pictures go where the answer put them, as on the Mac: a [Picture N] line gets its picture ("places"), a marker
    // inside a sentence and a picture with no marker are listed under the answer ("images").
    if let at = chat.conversations.firstIndex(where: { $0.id == room }) {
        let drawn = (1...3).compactMap { try? ImageStore.importImage(png, name: "picture-\($0).png", conversationID: room) }
        chat.conversations[at].turns[0].final = "Before\n\n[Picture 1]\n\nThe second, [Picture 2], is named in a sentence.\n\nAfter"
        chat.conversations[at].turns[0].finalImages = drawn
        let answer = (call("GET", "/api/chat/\(room.uuidString)").1["turns"] as? [[String: Any]] ?? []).last ?? [:]
        let places = answer["places"] as? [String: String] ?? [:], loose = answer["images"] as? [String] ?? []
        let url = { (image: ChatImage) in "/api/image/\(room.uuidString)/\(image.id.uuidString)" }
        expect(drawn.count == 3 && places == ["1": url(drawn[0])] && loose == [url(drawn[1]), url(drawn[2])],
               "phone server: a picture's place in the answer comes with it: \(places) \(loose)")
        chat.conversations[at].turns[0].final = "phone answer"
        chat.conversations[at].turns[0].finalImages = nil
    }
    let markdown = String(decoding: RemotePage.html(), as: UTF8.self)
    expect(markdown.contains("function pictureLine(l, places)") && markdown.contains("markdown(t.text, t.places)") && markdown.contains("PICS.test(l)"),
           "phone page: [Picture N] lines are drawn as their pictures, in place")
    // Which Mac the page is: its nickname comes with the list and with each chat, and the page shows it after the title.
    let savedName = server.deviceName
    server.deviceName = { "Pro" }
    expect(call("GET", "/api/chats").1["device"] as? String == "Pro" && call("GET", "/api/chat/\(room.uuidString)").1["device"] as? String == "Pro",
           "phone server: the Mac's nickname comes with the list and the chat")
    server.deviceName = savedName
    let titled = String(decoding: RemotePage.html(), as: UTF8.self)
    expect(titled.contains("<b>AI Illuminati</b><small class=\"mac\"></small>") && titled.contains("<h1>AI Illuminati</h1>") && titled.contains("showMac(data.device)") && titled.contains("chatSub(data.project"),
           "phone page: the nickname in the list's bar and in the chat's small line")
    let list = call("GET", "/api/chats").1["sections"] as? [[String: Any]] ?? []
    expect(list.contains { ($0["chats"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == room.uuidString } }, "phone server: the list has the chat")

    let request = ProjectApproval(room: room, run: UUID(), title: "git_push", detail: "origin main")
    ProjectCenter.shared.requests.append(request)
    let card = (call("GET", "/api/chat/\(room.uuidString)").1["approvals"] as? [[String: Any]])?.first
    expect(card?["id"] as? String == request.id.uuidString && card?["detail"] as? String == "origin main", "phone server: the approval card with its details")
    // The inbox atop the list (the Mac panel's 🔴/🟡): the chat's approval with its detail and chat, an outside tool counting down
    // with no buttons and no chat, a timed-out one; Allow/Deny there is the same POST /api/approval.
    let outside = ProjectApproval(room: UUID(), run: UUID(), title: "fake__echo", detail: "{}", deadline: Date().addingTimeInterval(42), alwaysAllow: {})
    let late = ProjectApproval(room: room, run: UUID(), title: "git_push", detail: "origin main")
    ProjectCenter.shared.requests.append(outside)
    ProjectCenter.shared.expired.append(late)
    let inbox = call("GET", "/api/chats").1["inbox"] as? [[String: Any]] ?? []
    let mine = inbox.first { $0["id"] as? String == request.id.uuidString }, tool = inbox.first { $0["id"] as? String == outside.id.uuidString }
    let ran = inbox.first { $0["id"] as? String == late.id.uuidString }
    expect(mine?["level"] as? String == "red" && mine?["approval"] as? String == request.id.uuidString && mine?["detail"] as? String == "origin main"
           && mine?["room"] as? String == room.uuidString, "phone server: the inbox has the chat's approval with its detail and chat \(inbox)")
    expect(tool?["kind"] as? String == "outside" && tool?["approval"] == nil && tool?["room"] == nil && (tool?["time"] as? String)?.contains("4") == true,
           "phone server: an outside tool only counts down in seconds")
    expect(ran?["kind"] as? String == "expired" && ran?["approval"] == nil && ran?["room"] as? String == room.uuidString, "phone server: a timed-out approval opens its chat")
    ProjectCenter.shared.requests.removeAll { $0.id == outside.id }
    ProjectCenter.shared.expired.removeAll { $0.id == late.id }
    expect(call("POST", "/api/approval/\(request.id.uuidString)", ["allow": false]).0 == 200
           && !ProjectCenter.shared.requests.contains { $0.id == request.id }, "phone server: denied from the phone, gone everywhere")
    expect(!(call("GET", "/api/chats").1["inbox"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == request.id.uuidString },
           "phone server: a decided approval leaves the inbox")
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

    // Long lists start at the sidebar's page, "Show more" (?n.<key>=) lengthens one; pinned chats are never cut.
    for i in 0..<14 { var c = Conversation(); c.title = "older \(i)"; c.turns = [ChatTurn(question: "q")]; chat.conversations.append(c) }
    var pinned = Conversation(); pinned.title = "pinned"; pinned.turns = [ChatTurn(question: "q")]; pinned.pinned = true
    chat.conversations.append(pinned)
    func recents(_ path: String) -> (rows: Int, more: [String: Any]?, pinned: Bool) {
        let sections = call("GET", path).1["sections"] as? [[String: Any]] ?? []
        let section = sections.first { $0["title"] as? String == L("최근", "Recents") }
        let pins = sections.contains { ($0["chats"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == pinned.id.uuidString } }
        return ((section?["chats"] as? [Any])?.count ?? 0, section?["more"] as? [String: Any], pins)
    }
    let total = chat.listedConversations.filter { $0.pinned != true && $0.hasContent }.count
    let short = recents("/api/chats"), long = recents("/api/chats?n.recents=20"), all = recents("/api/chats?n.recents=1000")
    expect(total > 15 && short.rows == SidebarFold.recentsPage && short.more?["hidden"] as? Int == total - SidebarFold.recentsPage
           && short.more?["key"] as? String == "recents" && short.pinned, "phone server: recents start at one page, the rest counted, pinned kept \(short)")
    expect(long.rows == min(total, 20) && long.more?["hidden"] as? Int == total - min(total, 20), "phone server: show more lengthens the list \(long)")
    expect(all.rows == total && all.more?["hidden"] as? Int == 0, "phone server: everything shown, show less still offered \(all)")
    expect(recents("/api/chats?n.recents=1").rows == SidebarFold.recentsPage, "phone server: never shorter than one page")
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
    expect(personalRow["plan"] as? String == "plus"
           && personalRow["checkedAt"] as? Double == (now.timeIntervalSince1970 - 30) * 1000
           && five?["left"] as? Double == 100
           && five?["resetsAt"] as? Double == (now.timeIntervalSince1970 - 1) * 1000
           && week?["left"] as? Double == 21 && week?["resetsAt"] as? Double == (now.timeIntervalSince1970 + 3600) * 1000,
           "phone usage: plan and raw reset dates, expired limits display 100%")
    expect(schoolRow["fiveHour"] is NSNull && schoolRow["weekly"] is NSNull && schoolRow["plan"] is NSNull
           && schoolRow["needsLogin"] as? Bool == true
           && schoolRow["note"] as? String == "Sign in as … to continue"
           && schoolRow["extras"] as? [String] == ["Extra limit", "Account: …"]
           && schoolRow["checkedAt"] as? Double == data["checkedAt"] as? Double
           && codex.last?["weekly"] is NSNull && codex.last?["checkedAt"] is NSNull,
           "phone usage: checked accounts without limits are distinct from accounts without a reading")
    expect(localRow["fiveHour"] is NSNull && localRow["weekly"] is NSNull
           && localRow["extras"] as? [String] == [L("한도 없음", "No limit")],
           "phone usage: Ollama has no limits even when the status icon uses synthetic full bars")
    expect(!String(decoding: initial.body, as: UTF8.self).contains("@"), "phone usage: no email anywhere in the response")
    expect(call("GET", "/api/usage/refresh").status == 404 && call("POST", "/api/usage").status == 404 && fake.refreshes == 0,
           "phone usage: only POST refresh can start a measurement")
    let started = call("POST", "/api/usage/refresh"), startedData = object(started)
    expect(started.status == 200 && startedData["refreshStarted"] as? Bool == true
           && startedData["checkedAt"] as? Double == data["checkedAt"] as? Double && fake.refreshes == 1,
           "phone usage: the first refresh confirms it started and returns the cached snapshot immediately")
    let throttled = call("POST", "/api/usage/refresh", uptime: 159.99), throttledData = object(throttled)
    expect(throttled.status == 200 && throttledData["refreshStarted"] as? Bool == false
           && throttledData["checkedAt"] is NSNull && fake.refreshes == 1,
           "phone usage: an early repeat returns the latest snapshot and says it did not start")
    let allowed = call("POST", "/api/usage/refresh", uptime: 160)
    expect(allowed.status == 200 && object(allowed)["refreshStarted"] as? Bool == true && fake.refreshes == 2,
           "phone usage: refresh is accepted at the 60-second boundary")
    expect(data["refreshStarted"] == nil, "phone usage: a GET does not report a refresh decision")

    let page = String(decoding: RemotePage.html(), as: UTF8.self)
    expect(page.contains("id=\"usagePanel\"") && page.contains("'/api/usage/refresh'") && page.contains("45000"),
           "phone usage: the page has the usage panel, refresh route and polling timer")
    expect(page.contains("class=\"usageCols\"") && page.contains("class=\"usageRow\"") && page.contains("function usageShort(")
           && page.contains("aria-expanded") && !page.contains("function usageLimit("),
           "phone usage: like the menu bar, one row per account under a 5h/Week header, tapped open for details")
    expect(page.contains("$('box').classList.remove('hidden');\n    grow();"),
           "phone page: the message box is sized after it shows again, so leaving the update screen does not shrink it to nothing")
    // Photos: picked, dropped anywhere on the chat screen or pasted all take one way in (thumbnails, sent only with Send);
    // a drop elsewhere never opens the file in place of the page. (Checked by hand in a WKWebView with synthetic events.)
    expect(page.contains("id=\"dropZone\"") && page.contains("$('chatView').addEventListener('drop'")
           && page.contains("document.addEventListener('paste'") && page.contains("for (const type of ['dragover', 'drop'])")
           && page.components(separatedBy: "addPhotos(").count >= 4 && !page.contains("photos.push(await shrink(f))"),
           "phone page: photos dropped on the whole chat screen or pasted go where + puts them")
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
