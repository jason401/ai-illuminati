import Foundation
import AppKit

// Spaces (Space.swift): the hidden <space-build> block, the checks before saving, manifest and schedule, drafts,
// the 1 MB data limit, versions and Undo, the old per-chat space.json moved to templates, and the Space request rule.
// Everything lives in the test home (AI_ILLUMINATI_TEST_HOME).
func testSpace() {
    let page = "<!doctype html><html><body><div id=a></div><script>document.getElementById('a').textContent=space.state.get('n')||0</script></body></html>"
    func block(_ html: String, manifest: String = #"{"name":"실험 트래커","icon":"flask","color":"green"}"#, state: String = #"{"n":1}"#, migrate: String? = nil) -> String {
        "답이에요.\n<space-build>\n<space-manifest>\(manifest)</space-manifest>\n<space-html>\n\(html)\n</space-html>\n<space-state>\(state)</space-state>"
            + (migrate.map { "<space-migrate>\($0)</space-migrate>" } ?? "") + "\n</space-build>"
    }

    // Extraction: hidden from the shown reply, also while it is still being written; old patches stay hidden.
    let split = SpaceBuilder.split(block(page))
    expect(split.reply == "답이에요." && split.found && split.body?.contains("<space-html>") == true, "the build block is taken out of the reply")
    expect(SpaceBuilder.split("답 <space-bu").reply == "답", "a tag still arriving is not shown")
    expect(SpaceBuilder.split("답 <space-build><space-html><b>").reply == "답" && SpaceBuilder.split("답 <space-build><space-html>").body == nil, "an unclosed block is hidden and has no body")
    expect(SpaceBuilder.split("a < b").reply == "a < b" && !SpaceBuilder.split("plain").found, "other text stays as it is")
    expect(SpaceBuilder.split("예전 답\n<space-patch base=1>{\"ops\":[]}</space-patch>").reply == "예전 답", "old <space-patch> blocks stay hidden")
    expect(Discussion.extractState(block(page) + "\n<chat-state>s</chat-state>").reply == "답이에요.", "the chat state cut also hides the build")
    expect(Discussion.extractState("답 <space-build><space-html><div>").reply == "답", "streamed replies hide a build being written")

    // Parsing: manifest, first data; refused with a reason otherwise.
    func parse(_ reply: String, new: Bool = true) -> Result<SpaceBuild, SpaceBad> { SpaceBuilder.parse(SpaceBuilder.split(reply).body, new: new) }
    func reason(_ reply: String, new: Bool = true) -> String? { if case .failure(let bad) = parse(reply, new: new) { return bad.reason }; return nil }
    guard case .success(let built) = parse(block(page)) else { fatalError("a good build parses") }
    expect(built.name == "실험 트래커" && built.icon == "flask" && built.color == "green" && built.state != nil && built.migrate == nil, "manifest and first data are read")
    guard case .success(let odd) = parse(block(page, manifest: #"{"name":"x","icon":"../etc","color":"chartreuse"}"#)) else { fatalError("odd manifest values are dropped, not fatal") }
    expect(odd.icon == nil && odd.color == nil, "unknown icons and colors are left out")
    expect(reason("<space-build><space-manifest>{}</space-manifest></space-build>") != nil, "a build without a page is refused")
    expect(reason("<space-build><space-html>") != nil, "an unclosed build is refused")
    expect(reason(block(page, state: "[1,2]")) != nil, "first data must be a JSON object")
    expect(reason(block(page, migrate: "function migrate(o){return o}"), new: false) == nil, "a change may carry migrate")
    if case .success(let change) = parse(block(page, migrate: "function migrate(o){return {count:o.n}}"), new: false) {
        expect(change.state == nil && change.migrate != nil, "a change never carries data, only migrate")
    } else { fatalError("a change parses") }
    expect(reason(block(page, migrate: "return 1"), new: false) != nil, "migrate must be a migrate function")

    // The checks: external addresses, eval, iframes, form actions, the network and size are refused.
    let refused = [
        "<img src=\"https://example.com/a.png\">", "<script src=//cdn.example.com/x.js></script>", "<link href='http://x.y/s.css'>",
        "<style>body{background:url(//x.y/a.png)}</style>", "<script>eval('1')</script>", "<script>new Function('return 1')()</script>",
        "<script>const f=Function('x')</script>", "<iframe srcdoc='x'></iframe>", "<object data=x></object>", "<embed src=x>",
        "<form action=\"/go\"><button>go</button></form>", "<script>fetch('/a')</script>", "<script>new WebSocket('ws://x')</script>",
        "<script>setTimeout('alert(1)', 10)</script>", "<meta http-equiv=\"refresh\" content=\"0;url=x\">", "<a href=\"file:///etc/passwd\">x</a>",
        "<base href=\"x\">",
    ]
    for html in refused { expect(SpaceCheck.problem(html) != nil, "refused: " + html) }
    expect(SpaceCheck.problem(String(repeating: "a", count: SpaceLimits.html + 1)) != nil, "over 300 KB is refused")
    expect(SpaceCheck.problem("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg><script>document.createElementNS('http://www.w3.org/2000/svg','circle');setTimeout(()=>1,5)</script>") == nil,
           "SVG namespaces and function timers are fine")
    expect(SpaceCheck.problem("<script>const fetched=1; prefetchList=[]</script><img src=\"data:image/png;base64,AAAA\">") == nil, "words that only contain fetch, and data: images, are fine")
    expect(reason(block("<script>eval(1)</script>"))?.contains("eval") == true, "the reason names what was refused")
    for template in SpaceTemplate.allCases { expect(SpaceCheck.problem(template.html) == nil, "the \(template.rawValue) template passes the checks") }
    let doc = SpaceCheck.document("\n<!DOCTYPE html><html><head><script>1</script>")
    expect(doc.hasPrefix("<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\"") && doc.contains("default-src 'none'")
           && doc.components(separatedBy: "<!DOCTYPE").count == 1, "the CSP comes first, before the page's own markup")

    // Manifest: missing keys keep their defaults.
    let minimal = try! JSONDecoder().decode(SpaceManifest.self, from: Data(#"{"id":"a","name":"b"}"#.utf8))
    expect(minimal.icon == "square.grid.2x2" && minimal.color == "blue" && minimal.version == 1 && minimal.schedule == nil, "a minimal manifest opens")
    expect(minimal.worker == nil, "no worker picked: automatic")
    var picked = minimal; picked.worker = "codex-1"
    expect((try? JSONDecoder().decode(SpaceManifest.self, from: JSONEncoder().encode(picked)))?.worker == "codex-1", "the picked worker is saved")

    // Pictures: those in the page reach the AI as markers, new ones from ChatGPT go in for space-image:N.
    let pixel = "data:image/png;base64," + String(repeating: "QUJD", count: 400)
    let drawn = "<img src=\"\(pixel)\"><p>x</p><div style=\"background:url(\(pixel))\"></div>"
    let hidden = SpacePictures.hide(drawn)
    expect(hidden.kept.count == 2 && hidden.text == "<img src=\"space-kept:1\"><p>x</p><div style=\"background:url(space-kept:2)\"></div>", "pictures are hidden: " + hidden.text)
    expect(SpacePictures.hide("<img src=\"data:image/png;base64,AAAA\">").kept.isEmpty, "a tiny data: URL stays in the code")
    expect(try! SpacePictures.embed(hidden.text, made: [], kept: hidden.kept).get() == drawn, "kept pictures come back as they were")
    let fresh = "data:image/jpeg;base64,BBBB"
    expect(try! SpacePictures.embed("<img src=space-image:1><img src='space-kept:2'>", made: [fresh], kept: hidden.kept).get() == "<img src=\(fresh)><img src='\(pixel)'>",
           "new and kept pictures go in for their markers")
    if case .success = SpacePictures.embed("<img src=space-image:2>", made: [fresh], kept: []) { fatalError("a marker without its picture is refused") }
    if case .success = SpacePictures.embed("<img src=space-kept:1>", made: [], kept: []) { fatalError("a kept marker without its picture is refused") }
    let big = "data:image/png;base64," + String(repeating: "A", count: 200_000)
    expect(SpaceCheck.problem("<p>x</p>" + String(repeating: "<img src=\"\(big)\">", count: 3)) == nil, "pictures do not count toward the code's 300 KB")
    expect(SpaceCheck.problem(String(repeating: "<img src=\"\(big)\">", count: 16)) != nil, "over 3 MB with pictures is refused")
    expect(SpaceBuilder.rule.contains("data: URLs") && SpacePictures.rule(draws: true, kept: 0).contains("space-image:1")
           && !SpacePictures.rule(draws: false, kept: 0).contains("space-image") && SpacePictures.rule(draws: false, kept: 2).contains("space-kept:2"),
           "only an AI that can draw is told about space-image")
    // A chat's picture requests: numbered in order, a redraw names the kept picture, at most four.
    let asks = try! SpacePictures.requests(in: "<space-html>x</space-html><space-picture n=\"1\">고양이</space-picture>\n<space-picture n='2' from='3'>\n밤으로\n</space-picture>").get()
    expect(asks == [.init(n: 1, from: nil, text: "고양이"), .init(n: 2, from: 3, text: "밤으로")], "picture requests are read in order")
    expect((try? SpacePictures.requests(in: "<space-picture>a</space-picture><space-picture>b</space-picture>").get())?.map(\.n) == [1, 2], "unnumbered requests count in order")
    if case .success = SpacePictures.requests(in: "<space-picture n=\"2\">a</space-picture>") { fatalError("requests out of order are refused") }
    if case .success = SpacePictures.requests(in: String(repeating: "<space-picture>a</space-picture>", count: 5)) { fatalError("over four pictures is refused") }
    expect(SpacePictures.drawPrompt(asks[1]).contains("[Attached image]") && !SpacePictures.drawPrompt(asks[0]).contains("[Attached image]"), "only a redraw mentions its picture")
    let reference = SpacePictures.referenceFile("data:image/jpeg;base64," + Data("JPEG".utf8).base64EncodedString())!
    expect(reference.pathExtension == "jpg" && (try? Data(contentsOf: reference)) == Data("JPEG".utf8), "a kept picture becomes a file to attach")
    try? FileManager.default.removeItem(at: reference)
    expect(SpacePictures.chatRule(draws: true).contains("from=\"K\"") && !SpacePictures.chatRule(draws: false).contains("<space-picture"), "only a chat with a drawer is told about picture requests")
    let imageDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("space-pic-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
    func picture(_ name: String, opaque: Bool) -> URL {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 800, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if opaque { NSColor.orange.setFill(); NSRect(x: 0, y: 0, width: 1600, height: 800).fill() } else { NSColor.orange.setFill(); NSRect(x: 0, y: 0, width: 400, height: 400).fill() }
        NSGraphicsContext.restoreGraphicsState()
        let url = imageDir.appendingPathComponent(name)
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }
    let photo = Pictures.spaceDataURL(picture("a.png", opaque: true)), cutout = Pictures.spaceDataURL(picture("b.png", opaque: false))
    let photoSize = photo.flatMap { Data(base64Encoded: String($0.split(separator: ",")[1])) }.flatMap { NSBitmapImageRep(data: $0) }
    expect(photo?.hasPrefix("data:image/jpeg;base64,") == true && photoSize?.pixelsWide == 768 && photoSize?.pixelsHigh == 384, "an opaque picture becomes a 768 px JPEG")
    expect(cutout?.hasPrefix("data:image/png;base64,") == true, "a picture with transparency stays PNG")
    try? FileManager.default.removeItem(at: imageDir)

    // Schedule: weekdays, hours, overnight, and what the sidebar menu reads.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))! }
    // 2026-11-09 is a Monday, 11-14 a Saturday, 11-15 a Sunday.
    let work = SpaceSchedule(days: [1, 2, 3, 4, 5], from: "09:00", to: "18:00")
    expect(work.shows(at: at(9, 10), calendar: calendar) && !work.shows(at: at(9, 8, 59), calendar: calendar) && !work.shows(at: at(9, 18), calendar: calendar), "hours on a weekday")
    expect(!work.shows(at: at(14, 10), calendar: calendar), "not on the weekend")
    let night = SpaceSchedule(days: [5], from: "22:00", to: "02:00")
    expect(night.shows(at: at(13, 23), calendar: calendar) && night.shows(at: at(14, 1), calendar: calendar) && !night.shows(at: at(14, 23), calendar: calendar),
           "overnight hours belong to the day they start")
    expect(SpaceSchedule(days: [7]).shows(at: at(15, 3), calendar: calendar) && !SpaceSchedule(days: [7]).shows(at: at(14, 3), calendar: calendar), "days only")
    expect(SpaceSchedule.parse("1-5 09:00-18:00") == work && SpaceSchedule.parse("6,7")?.days == [6, 7] && SpaceSchedule.parse("9-10") == nil
           && SpaceSchedule.parse("25:00-26:00") == nil, "the schedule the user types")
    var later = SpaceManifest(id: "x", name: "x")
    later.schedule = work
    expect(later.shown(at: at(9, 10)) == work.shows(at: at(9, 10)) && { var h = later; h.hidden = true; return !h.shown(at: at(9, 10)) }(), "hidden Spaces never show")

    // Drafts: saved by an answer, played with in the preview, added to the sidebar with that data.
    let store = SpaceStore.shared
    store.reload()
    expect(SpaceStore.root.path.hasPrefix(AccountStore.supportDir) && !store.spaces.contains { !$0.id.hasPrefix("legacy-") && $0.originChat == "test" }, "Spaces live in the test home")
    let draft = try! SpaceStore.saveDraft(built)
    let draftFolder = SpaceStore.draftFolder(draft)
    if case .failure = SpaceStore.setState(draftFolder, key: "n", json: "5") { fatalError("the preview saves its data") }
    let stale = try! SpaceStore.saveDraft(built)
    SpaceStore.pruneDrafts(olderThan: 30, now: Date().addingTimeInterval(31 * 86400))
    expect(!FileManager.default.fileExists(atPath: SpaceStore.draftFolder(stale).path) && !FileManager.default.fileExists(atPath: draftFolder.path),
           "old previews are cleaned up")
    let draftAgain = try! SpaceStore.saveDraft(built)
    _ = SpaceStore.setState(SpaceStore.draftFolder(draftAgain), key: "n", json: "5")
    let origin = UUID()
    let made = try! store.adopt(draft: draftAgain, origin: origin)
    let folder = SpaceStore.folder(made.id)
    expect(!FileManager.default.fileExists(atPath: SpaceStore.draftFolder(draftAgain).path) && draft != draftAgain && store.manifest(made.id)?.name == "실험 트래커" && made.originChat == origin.uuidString,
           "adding moves the draft into the sidebar's Spaces")
    expect((try? JSONSerialization.jsonObject(with: SpaceStore.state(folder)) as? [String: Any])?["n"] as? Int == 5, "what was checked in the preview comes along")

    // Data: only JSON, at most 1 MB; a refused write changes nothing.
    if case .failure = SpaceStore.setState(folder, key: "done", json: #"{"a":true}"#) { fatalError("a JSON value is saved") }
    let before = SpaceStore.state(folder)
    if case .success = SpaceStore.setState(folder, key: "big", json: "\"" + String(repeating: "x", count: SpaceLimits.state) + "\"") { fatalError("over 1 MB is refused") }
    if case .success = SpaceStore.setState(folder, key: "", json: "1") { fatalError("an empty key is refused") }
    if case .success = SpaceStore.setState(folder, key: "x", json: "not json") { fatalError("non-JSON is refused") }
    expect(SpaceStore.state(folder) == before, "a refused write leaves the data as it was")
    if case .failure = SpaceStore.setState(folder, key: "done", json: nil) { fatalError("nil removes a key") }
    expect((try? JSONSerialization.jsonObject(with: SpaceStore.state(folder)) as? [String: Any])?["done"] == nil, "the key is gone")

    // The AI sees the data's shape, never its values.
    _ = SpaceStore.setState(folder, key: "items", json: #"[{"id":"i1","text":"비밀 실험 A","done":true}]"#)
    let shape = SpaceStore.shape(SpaceStore.state(folder))
    expect(shape.contains("items: [{done: bool, id: string, text: string}] (1)") && shape.contains("n: number") && !shape.contains("비밀"), "only keys and types: " + shape)
    let prompt = SpaceBuilder.refinePrompt(manifest: store.manifest(made.id)!, html: SpaceStore.html(folder), state: SpaceStore.state(folder), history: [], request: "색 바꿔 줘")
    expect(!prompt.contains("비밀 실험") && prompt.contains("색 바꿔 줘") && prompt.contains("[Current app.html]"), "the change prompt has the code and the shape only")

    // Versions: a change keeps the code before; Undo brings it back and keeps what was checked since.
    try! store.apply(made.id, html: page.replacingOccurrences(of: "<body>", with: "<body style=\"color:green\">"), note: "색 바꿔 줘", color: "teal")
    expect(store.manifest(made.id)?.version == 2 && store.manifest(made.id)?.color == "teal" && SpaceStore.versions(made.id).map(\.version) == [1], "the old version is kept")
    _ = SpaceStore.setState(folder, key: "n", json: "9")
    try! store.undo(made.id)
    expect(SpaceStore.html(folder) == page && store.manifest(made.id)?.version == 1 && SpaceStore.versions(made.id).isEmpty, "Undo brings the old page back")
    expect(store.manifest(made.id)?.color == "green", "Undo brings the old color back too")
    expect((try? JSONSerialization.jsonObject(with: SpaceStore.state(folder)) as? [String: Any])?["n"] as? Int == 9, "Undo after a code change keeps the data")
    // A change that moved the data: Undo brings the data from before it back too.
    try! store.apply(made.id, html: page, state: Data(#"{"count":9}"#.utf8), note: "키 바꿈")
    expect(SpaceStore.versions(made.id).last?.migrated == true && (try? JSONSerialization.jsonObject(with: SpaceStore.state(folder)) as? [String: Any])?["count"] as? Int == 9, "the migrated data is saved")
    try! store.undo(made.id)
    expect((try? JSONSerialization.jsonObject(with: SpaceStore.state(folder)) as? [String: Any])?["n"] as? Int == 9, "Undo of a migration restores the data")
    expect((try? store.apply(made.id, html: "<script>eval(1)</script>", note: "x")) == nil && SpaceStore.html(folder) == page, "a refused page is never saved")
    for n in 0..<(SpaceLimits.versions + 3) { try! store.apply(made.id, html: page + "<!-- \(n) -->", note: "\(n)") }
    expect(SpaceStore.versions(made.id).count == SpaceLimits.versions, "only the newest versions stay")
    let oldest = SpaceStore.versions(made.id).first!.version
    let oldPage = SpaceStore.html(folder.appendingPathComponent("versions/\(oldest)"))
    try! store.restore(made.id, to: oldest)
    expect(!oldPage.isEmpty && SpaceStore.html(folder) == oldPage, "an old version comes back as a new change")
    expect((try? JSONSerialization.jsonObject(with: SpaceStore.state(folder)) as? [String: Any])?["n"] as? Int == 9, "a version with the same data shape keeps the data")
    // Back across a data move: that version's data comes back with its code, and Undo puts the newer data back.
    try! store.apply(made.id, html: "<p>tasks</p>", state: Data(#"{"tasks":[1]}"#.utf8), note: "items → tasks", color: "red")
    let beforeMove = store.manifest(made.id)!.version - 1
    _ = SpaceStore.setState(folder, key: "tasks", json: "[1,2]")
    try! store.restore(made.id, to: beforeMove)
    let back = (try? JSONSerialization.jsonObject(with: SpaceStore.state(folder)) as? [String: Any]) ?? [:]
    expect(back["tasks"] == nil && back["n"] as? Int == 9 && store.manifest(made.id)?.color != "red", "restoring across a data move brings that version's data and look")
    try! store.undo(made.id)
    expect(((try? JSONSerialization.jsonObject(with: SpaceStore.state(folder)) as? [String: Any])?["tasks"] as? [Int]) == [1, 2] && store.manifest(made.id)?.color == "red",
           "Undo of that restore brings the newer data back")

    // Refine log, bounded.
    for n in 0..<(SpaceLimits.refine + 5) { SpaceStore.addRefine(made.id, SpaceRefineEntry(role: "user", text: "\(n)")) }
    expect(SpaceStore.refineLog(made.id).count == SpaceLimits.refine && SpaceStore.refineLog(made.id).last?.text == "\(SpaceLimits.refine + 4)", "the change talk keeps its newest entries")

    // Sidebar: rename, pin, order.
    store.update(made.id) { $0.name = "  새 이름  "; $0.pinned = true }
    expect(store.manifest(made.id)?.name == "새 이름" && store.manifest(made.id)?.pinned == true, "rename and pin")
    let second = try! store.makeFromTemplate(.checklist)
    let listed = store.spaces.map(\.id)
    store.move(second.id, by: -1, among: listed)
    expect(store.spaces.map(\.id).firstIndex(of: second.id)! < store.spaces.map(\.id).firstIndex(of: made.id)!, "moving up changes the order")

    // A chat that names a Space: it gets that Space's code and data shape, and its block changes it or makes one from it.
    let asked = "새이름 Space에 완료 버튼 추가해 줘"
    expect(SpaceStore.named(in: asked).map(\.id) == [made.id] && SpaceStore.named(in: "새 이름 뭐였지?").isEmpty
           && SpaceStore.named(in: "> 새 이름 고쳐 줘\n이게 뭐야?").isEmpty, "a Space is named with a change word, outside quotes")
    expect(Route.rule(question: asked, previous: nil) == .one, "a change to a named Space is answered by one AI, not project work")
    let context = Discussion.spaceRule(asked, draws: true)
    expect(context.contains("for=\"its id\"") && context.contains("id \(made.id)") && context.contains("[Current app.html]") && !context.contains("비밀 실험"),
           "the chat gets the code and the shape, never the values")
    expect(context.contains("<space-picture n=\"1\">") && !Discussion.spaceRule(asked).contains("<space-picture"), "a chat with a drawer may ask for Space pictures")
    expect(Discussion.spaceRule("오늘 날씨 어때?").isEmpty, "other messages get no Space rule")
    let change = "고쳤어요.\n<space-build for=\"\(made.id)\"><space-html><p>new</p></space-html><space-migrate>function migrate(o){return o}</space-migrate></space-build>"
    let changeSplit = SpaceBuilder.split(change)
    expect(changeSplit.reply == "고쳤어요." && changeSplit.target == made.id && changeSplit.base == nil && changeSplit.body?.contains("<p>new</p>") == true, "for= names the Space to change")
    expect(SpaceBuilder.split("x <space-build from='\(made.id)'><space-html>a</space-html></space-build>").base == made.id, "from= names the Space to start from")
    expect(SpaceBuilder.split("답 <space-build for=\"ab").reply == "답" && SpaceBuilder.split("답 <space-build for=\"ab").found, "an opening tag still arriving is hidden")
    expect(SpaceBuilder.split("x <space-build for=\"../etc\"><space-html>a</space-html></space-build>").target == nil, "an odd id is dropped")
    guard case .success(let changed) = SpaceBuilder.parse(changeSplit.body, new: false) else { fatalError("a chat's change parses") }
    let changeDraft = try! SpaceStore.saveDraft(changed, over: store.manifest(made.id))
    let back2 = SpaceStore.draftBuild(changeDraft)
    expect(back2?.html == "<p>new</p>" && back2?.migrate?.contains("migrate") == true && back2?.name == "새 이름" && back2?.color == store.manifest(made.id)?.color,
           "a change draft keeps its migrate and the Space's look")
    SpaceStore.discardDraft(changeDraft)

    // Old per-chat Spaces: every block kind into a template, the original kept as space.json.migrated.
    let room = UUID()
    let work2 = URL(fileURLWithPath: ChatStore.dir).appendingPathComponent("\(room.uuidString).work")
    try! FileManager.default.createDirectory(at: work2, withIntermediateDirectories: true)
    let legacy: [String: Any] = ["version": 3, "title": "논문", "goal": "11월 제출", "updatedAt": 0, "blocks": [
        ["id": "b1", "kind": "decisionLog", "title": "결정", "items": [
            ["id": "i1", "text": "저널 A", "open": false, "pro": ["Claude"], "con": ["Gemini"], "status": "confirmed", "source": "회의 · 1"],
            ["id": "i2", "text": "그림 수", "open": true, "status": "proposed"]]],
        ["id": "b2", "kind": "checklist", "title": "할 일", "items": [["id": "i3", "text": "초록", "done": true]]],
        ["id": "b3", "kind": "table", "title": "후보", "columns": ["저널", "IF"], "items": [["id": "i4", "cells": ["A", "5.1"]]]],
        ["id": "b4", "kind": "kanban", "title": "진행", "columns": ["할 일", "하는 중", "끝"], "items": [["id": "i5", "text": "그림 3", "lane": "끝"], ["id": "i6", "text": "표 2", "lane": "하는 중"]]]]]
    try! JSONSerialization.data(withJSONObject: legacy).write(to: work2.appendingPathComponent("space.json"))
    let broken = UUID()
    let brokenWork = URL(fileURLWithPath: ChatStore.dir).appendingPathComponent("\(broken.uuidString).work")
    try! FileManager.default.createDirectory(at: brokenWork, withIntermediateDirectories: true)
    try! Data("{not json".utf8).write(to: brokenWork.appendingPathComponent("space.json"))
    let moved = SpaceStore.migrateLegacy()
    store.reload()
    func data(_ id: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: SpaceStore.state(SpaceStore.folder(id)))) as? [String: Any] ?? [:] }
    let prefix = "legacy-" + room.uuidString
    expect(moved.filter { $0.hasPrefix(prefix) }.count == 3, "a decision log (with the checklist), a table and a kanban: \(moved)")
    let log = data(prefix + "-0"), decisions = log["decisions"] as? [[String: Any]] ?? []
    expect(store.manifest(prefix + "-0")?.template == "decisions" && decisions.count == 2 && decisions[0]["confirmed"] as? Bool == true
           && decisions[0]["pro"] as? [String] == ["Claude"] && decisions[1]["open"] as? Bool == true, "decisions keep open, confirmed and who was for and against")
    expect((log["next"] as? [[String: Any]])?.first?["done"] as? Bool == true, "the checklist becomes next steps, checks kept")
    let table = data(prefix + "-3")
    expect(store.manifest(prefix + "-3")?.template == "compare" && table["columns"] as? [String] == ["저널", "IF"]
           && (table["rows"] as? [[String: Any]])?.first?["cells"] as? [String] == ["A", "5.1"], "the table becomes a comparison")
    let board = data(prefix + "-4"), cards = board["items"] as? [[String: Any]] ?? []
    expect(cards.count == 2 && cards[0]["done"] as? Bool == true && cards[1]["done"] as? Bool == false && cards[1]["lane"] as? String == "하는 중", "kanban lanes are kept, the last one is done")
    expect(store.manifest(prefix + "-0")?.originChat == room.uuidString, "the Space remembers its chat")
    expect(!FileManager.default.fileExists(atPath: work2.appendingPathComponent("space.json").path)
           && FileManager.default.fileExists(atPath: work2.appendingPathComponent("space.json.migrated").path), "the original is renamed, not deleted")
    expect(FileManager.default.fileExists(atPath: brokenWork.appendingPathComponent("space.json").path) && !moved.contains { $0.contains(broken.uuidString) },
           "a file that cannot be read stays as it is")
    // A run cut short before the rename makes no copies.
    try! FileManager.default.moveItem(at: work2.appendingPathComponent("space.json.migrated"), to: work2.appendingPathComponent("space.json"))
    let count = store.spaces.count
    SpaceStore.migrateLegacy(); store.reload()
    expect(store.spaces.count == count, "running again makes no duplicates")

    // A meeting's result as the decision log's data.
    let meeting = SpacePatch.meetingState("## 결론\n- 저널 A로 낸다\n## 이견\n- 그림 수\n## 네 결정이 필요한 것\n- 마감일\n## 다음 행동\n1. 초록 쓰기", title: "회의", source: "회의 · 1", chat: room)
    let items = meeting["decisions"] as? [[String: Any]] ?? []
    expect(items.count == 3 && items[0]["open"] as? Bool == false && items[1]["open"] as? Bool == true && items[2]["text"] as? String == "마감일"
           && items.allSatisfy { $0["confirmed"] as? Bool == false && $0["chat"] as? String == room.uuidString }, "meeting decisions are AI proposals linked to the meeting")
    expect((meeting["next"] as? [[String: Any]])?.first?["text"] as? String == "초록 쓰기", "next steps")

    // Who asks for a Space.
    for ask in ["이번 주 실험 트래커 만들어 줘", "단어 퀴즈 게임 만들자", "진행률 대시보드 하나 만들어줘", "Space 만들어 줘: 물 마시기", "make me a habit tracker", "Build a kanban board"] {
        expect(Route.asksSpace(ask), "asks for a Space: " + ask)
    }
    for not in ["앱 만들어 줘", "이 게임은 누가 만들어진 거야?", "트래커 만들지 마", "> 트래커 만들어 줘\n이거 무슨 뜻이야?", "보드게임 추천해 줘", "make it faster"] {
        expect(!Route.asksSpace(not), "not a Space request: " + not)
    }
    expect(Route.rule(question: "이번 주 실험 트래커 만들어 줘", previous: nil) == .one, "a Space request in a project chat is answered by one AI, not work")

    print("PASS: Spaces — build block, checks, schedule, drafts, data limit, versions and Undo, migration")
}

// The Spaces folder as a chat's AI edits it (SpaceLibrary.swift): pictures as files, direct changes checked and
// versioned, a bad page put back, new folders added or set aside, the data guarded, the rule and the export.
func testSpaceLibrary() {
    let store = SpaceStore.shared, fm = FileManager.default
    _ = store.syncLibrary()   // the first run accepts every Space as it is
    func json(_ folder: URL) -> [String: Any] { (try? JSONSerialization.jsonObject(with: SpaceStore.state(folder))) as? [String: Any] ?? [:] }
    let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 1500)
    let picture = "data:image/png;base64," + bytes.base64EncodedString()
    let page = "<!doctype html><body><img src=\"\(picture)\"><p id=t>hi</p><script>document.getElementById('t').textContent=space.state.get('n')</script></body>"
    let made = try! SpaceStore.make(name: "그림 노트", icon: "photo", color: "pink", html: page, state: Data(#"{"n":1}"#.utf8), origin: nil, order: store.nextOrder())
    store.reload()
    let folder = SpaceStore.folder(made.id), stored = SpaceStore.html(folder)
    let file = "picture-\(SpaceAssets.hash(bytes)).png"
    expect(!stored.contains("base64") && stored.contains("assets/\(file)") && fm.fileExists(atPath: folder.appendingPathComponent("assets/\(file)").path), "pictures are kept as files")
    expect(SpaceStore.page(folder) == page && SpacePictures.hide(SpaceStore.page(folder)).kept == [picture], "and go back in when the page loads")
    expect(store.syncLibrary().isEmpty, "nothing changed, nothing to say")

    // A good edit becomes a version (Undo works); a bad one is put back.
    try! Data(stored.replacingOccurrences(of: "hi", with: "안녕").utf8).write(to: folder.appendingPathComponent("app.html"))
    var notes = store.syncLibrary()
    expect(notes == [SpaceSyncNote(space: made.id, name: "그림 노트", kind: "changed", version: 2)] && store.manifest(made.id)?.version == 2
           && SpaceStore.versions(made.id).map(\.version) == [1] && SpaceStore.versions(made.id).first?.migrated == false, "a direct edit becomes version 2: \(notes)")
    try! store.undo(made.id)
    expect(SpaceStore.html(folder) == stored && store.manifest(made.id)?.version == 1 && store.syncLibrary().isEmpty, "Undo of a direct edit")
    try! Data("<script>fetch('x')</script>".utf8).write(to: folder.appendingPathComponent("app.html"))
    notes = store.syncLibrary()
    expect(notes.first?.kind == "refused" && notes.first?.reason?.isEmpty == false && SpaceStore.html(folder) == stored && store.manifest(made.id)?.version == 1, "a page that fails is put back")

    // A manifest written by hand: no id or version, an odd color.
    try! Data(#"{"name":"새 노트","icon":"star","color":"chartreuse","version":99}"#.utf8).write(to: folder.appendingPathComponent("manifest.json"))
    notes = store.syncLibrary()
    let look = store.manifest(made.id)
    expect(look?.name == "새 노트" && look?.icon == "star" && look?.color == "pink" && look?.version == 1 && abs((look?.createdAt ?? .distantPast).timeIntervalSince(made.createdAt)) < 0.01 && notes.first?.kind == "changed",
           "name and icon change, the app's own keys stay")

    // The data: changed during an answer it becomes a version Undo can take back; broken it is put back.
    SpaceLibrary.beginAnswer()
    try! Data(#"{"n":5}"#.utf8).write(to: folder.appendingPathComponent("state.json"))
    SpaceLibrary.endAnswer()
    notes = store.syncLibrary()
    expect(json(folder)["n"] as? Int == 5 && SpaceStore.versions(made.id).last?.migrated == true && notes.first?.kind == "changed", "a data edit is a version")
    try! store.undo(made.id)
    expect(json(folder)["n"] as? Int == 1, "Undo brings the data back")
    SpaceLibrary.beginAnswer()
    try! Data("{oops".utf8).write(to: folder.appendingPathComponent("state.json"))
    SpaceLibrary.endAnswer()
    notes = store.syncLibrary()
    expect(notes.first?.kind == "refused" && json(folder)["n"] as? Int == 1 && fm.fileExists(atPath: folder.appendingPathComponent("state.broken.json").path), "broken data is put back, kept aside")
    if case .failure = SpaceStore.setState(folder, key: "n", json: "2") { fatalError("the bridge still saves") }
    expect(store.syncLibrary().isEmpty, "the bridge's own writes are not edits")

    // Pictures an AI puts in assets/ go in when the page loads.
    try! SpaceStore.write(bytes, to: folder.appendingPathComponent("assets/cat.png"))
    try! Data((stored + "<img src='assets/cat.png'>").utf8).write(to: folder.appendingPathComponent("app.html"))
    notes = store.syncLibrary()
    expect(notes.first?.kind == "changed" && SpaceStore.page(folder).hasSuffix("<img src='\(picture)'>"), "assets/cat.png is put in")
    expect(fm.fileExists(atPath: folder.appendingPathComponent("assets/\(file)").path), "pictures a kept version uses stay")

    // New folders: one named in words is added with that name; one with a bad page is set aside.
    let words = SpaceStore.root.appendingPathComponent("커피 트래커")
    try! SpaceStore.write(Data("<p>coffee</p>".utf8), to: words.appendingPathComponent("app.html"))
    let bad = SpaceStore.root.appendingPathComponent("bad-one")
    try! SpaceStore.write(Data("<script>eval('1')</script>".utf8), to: bad.appendingPathComponent("app.html"))
    try! SpaceStore.write(Data(#"{"name":"나쁜 것"}"#.utf8), to: bad.appendingPathComponent("manifest.json"))
    notes = store.syncLibrary()
    let coffee = store.spaces.first { $0.name == "커피 트래커" }
    expect(notes.contains { $0.kind == "added" && $0.name == "커피 트래커" } && coffee != nil && SpaceStore.validID(coffee!.id) && !fm.fileExists(atPath: words.path)
           && json(SpaceStore.folder(coffee!.id)).isEmpty, "a new folder becomes a Space: \(notes)")
    expect(notes.contains { $0.kind == "set-aside" && $0.name == "나쁜 것" } && !fm.fileExists(atPath: bad.path)
           && fm.fileExists(atPath: SpaceLibrary.rejected.appendingPathComponent("bad-one/app.html").path) && !store.spaces.contains { $0.id == "bad-one" }, "a bad new one is set aside")
    try! fm.removeItem(at: SpaceStore.folder(coffee!.id))
    notes = store.syncLibrary()
    expect(notes == [SpaceSyncNote(space: coffee!.id, name: "커피 트래커", kind: "removed")] && store.manifest(coffee!.id) == nil, "a Space taken out of the folder is gone")

    // What a chat's AI is told: the folder, its Spaces by name, no code pasted; a redraw may name a file.
    let rule = Discussion.spaceRule("새 노트 Space에 버튼 추가해 줘", draws: true, folder: true)
    expect(rule.contains("[Spaces folder] " + SpaceStore.root.path) && rule.contains("새 노트 — \(made.id)") && !rule.contains("[Current app.html]")
           && rule.contains("from=\"assets/name.png\""), "the folder rule")
    let binding = WorkspaceBinding(roots: [WorkspaceRoot(path: "/chat", directory: true, writable: true), WorkspaceRoot(path: SpaceStore.root.path, directory: true, writable: true)])
    let folders = Discussion.soloFolders(binding, shared: [])
    expect(folders.contains(SpaceStore.root.path + " (Spaces folder") && folders.contains("- 새 노트 — " + folder.path) && !folders.contains("/versions/"), "the folder list names Spaces, not their files")
    if case .success(let asked) = SpacePictures.requests(in: "<space-picture n=\"1\" from=\"assets/cat.png\">밤으로</space-picture>") {
        expect(asked.first?.file == "cat.png" && asked.first?.from == nil, "a redraw named by file")
    } else { fatalError("a redraw by file parses") }

    // Export: one file, pictures inside, the bridge stood in for, the data it has now.
    let exported = SpaceExport.document(made.id) ?? ""
    expect(exported.hasPrefix("<!doctype html>") && exported.contains("Object.defineProperty(window, 'space'") && exported.contains(picture)
           && !exported.contains("assets/") && exported.contains(#""n":2"#) && exported.contains("<title>새 노트</title>"), "the export stands alone")
    try! store.delete(made.id)
    expect(store.syncLibrary().isEmpty, "the app's own Delete says nothing more")
    print("PASS: Spaces folder — pictures as files, direct edits versioned or put back, new folders, data guarded, rule, export")
}
