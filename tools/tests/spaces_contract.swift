import Foundation
import AIAccounts
import AISpaces

// The promises of the AISpaces module on disk, checked from outside it with only its public API: a spaces/ folder as
// an older build left it opens as it is, and what the module writes keeps that shape. Isolation of the web view is
// space_web.swift; building, checks and versions are space_build.swift (docs/MODULES.md).
// Run with AI_ILLUMINATI_TEST_HOME set to an empty folder (run_mode2.sh).
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("FAIL: " + message) }
}
let fm = FileManager.default
let home = ProcessInfo.processInfo.environment["AI_ILLUMINATI_TEST_HOME"] ?? ""
expect(!home.isEmpty && SpaceStore.root.path == home + "/Library/Application Support/AI Illuminati/spaces", "Spaces live in the test home")
func put(_ path: String, _ text: String) {
    let url = SpaceStore.root.appendingPathComponent(path)
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: url)
}
func read(_ path: String) -> String { (try? String(contentsOf: SpaceStore.root.appendingPathComponent(path), encoding: .utf8)) ?? "" }

// A Spaces folder written by an earlier build (before worker and schedule existed), byte for byte.
let oldManifest = """
    {
      "color" : "teal",
      "createdAt" : 700000000,
      "icon" : "drop",
      "id" : "old-1",
      "name" : "물 마시기",
      "order" : 1,
      "originChat" : "C0FFEE00-0000-4000-8000-000000000000",
      "updatedAt" : 700000100,
      "version" : 2
    }
    """
put("old-1/manifest.json", oldManifest)
put("old-1/app.html", "<p>v2</p>")
put("old-1/state.json", #"{"count":3}"#)
put("old-1/refine.json", #"[{"at":700000060,"role":"user","text":"색 바꿔 줘"}]"#)
put("old-1/versions/1/app.html", "<p>v1</p>")
put("old-1/versions/1/state.json", #"{"count":1}"#)
put("old-1/versions/1/info.json", #"{"at":700000050,"migrated":false,"note":"첫 판","version":1}"#)
put("old-1/versions/1/manifest.json", #"{"color":"blue","icon":"drop","id":"old-1","name":"물","version":1}"#)
// A manifest copied from another Space, one from a newer build (a key this one does not know), odd values, a broken one.
put("copied/manifest.json", #"{"id":"other","name":"복사본","createdAt":690000000,"futureKey":{"x":1}}"#)
put("copied/app.html", "<p>c</p>")
put("odd/manifest.json", #"{"name":5,"order":"first"}"#)
put("odd/app.html", "<p>o</p>")
put("odd/state.json", "[1,2]")
put("broken/manifest.json", "not json")
put(".drafts/x/manifest.json", #"{"name":"draft"}"#)

let store = SpaceStore.shared
store.reload()
expect(store.spaces.map(\.id) == ["copied", "odd", "old-1"], "the old folder lists its Spaces by order, hidden and broken ones left out: \(store.spaces.map(\.id))")
let old = store.manifest("old-1")
expect(old?.name == "물 마시기" && old?.icon == "drop" && old?.color == "teal" && old?.version == 2 && old?.order == 1
       && old?.originChat == "C0FFEE00-0000-4000-8000-000000000000" && old?.worker == nil && old?.schedule == nil
       && old?.createdAt == Date(timeIntervalSinceReferenceDate: 700000000), "an old manifest opens with every value")
expect(store.manifest("copied")?.name == "복사본", "the id comes from the folder, an unknown key is skipped")
expect(store.manifest("odd")?.name == "Space" && store.manifest("odd")?.order == 0, "odd values fall back to their defaults")
expect(SpaceStore.state(SpaceStore.folder("odd")) == Data("{}".utf8) && SpaceStore.state(SpaceStore.folder("copied")) == Data("{}".utf8),
       "data that is not one object, or missing, reads as {}")
expect(SpaceStore.html(SpaceStore.folder("old-1")) == "<p>v2</p>" && SpaceStore.state(SpaceStore.folder("old-1")) == Data(#"{"count":3}"#.utf8), "page and data read as they are")
expect(SpaceStore.versions("old-1").map(\.version) == [1] && SpaceStore.versions("old-1").first?.note == "첫 판", "old versions are read")
expect(SpaceStore.refineLog("old-1") == [SpaceRefineEntry(role: "user", text: "색 바꿔 줘", at: Date(timeIntervalSinceReferenceDate: 700000060))], "the change talk is read")

// The first sync of a build accepts every Space as it is: nothing reported, nothing rewritten.
expect(SpaceLibrary.sync().notes.isEmpty && SpaceLibrary.sync().notes.isEmpty, "an existing folder is accepted as it is")
expect(read("old-1/manifest.json") == oldManifest && read("old-1/app.html") == "<p>v2</p>" && fm.fileExists(atPath: SpaceStore.root.appendingPathComponent("broken").path),
       "the first sync rewrites nothing of the old folder")

// Save format: pretty, sorted keys, absent fields left out (older builds read it); data compact with sorted keys.
store.update("old-1") { $0.pinned = true }
expect(read("old-1/manifest.json") == oldManifest.replacingOccurrences(of: "  \"updatedAt\"", with: "  \"pinned\" : true,\n  \"updatedAt\""),
       "a change keeps the manifest's shape: " + read("old-1/manifest.json"))
expect(SpaceFolderHost(SpaceStore.folder("old-1")).set(key: "b", json: #"{"z":1,"a":[true]}"#).isSuccess, "the bridge saves a value")
expect(read("old-1/state.json") == #"{"b":{"a":[true],"z":1},"count":3}"#, "data is one compact object with sorted keys: " + read("old-1/state.json"))
expect(!SpaceFolderHost(SpaceStore.folder("old-1")).set(key: "big", json: "\"" + String(repeating: "x", count: 10_000_001) + "\"").isSuccess
       && read("old-1/state.json") == #"{"b":{"a":[true],"z":1},"count":3}"#, "data over 10 MB is refused and nothing is written")
let mode = (try? fm.attributesOfItem(atPath: SpaceStore.folder("old-1").appendingPathComponent("state.json").path))?[.posixPermissions] as? Int
expect(mode == 0o600, "data files are private (0600)")

// Undo of a change an older build saved: its page, look and version come back; its data stays (no migrate).
expect((try? store.undo("old-1")) == true, "an old version can be undone to")
expect(SpaceStore.html(SpaceStore.folder("old-1")) == "<p>v1</p>" && store.manifest("old-1")?.version == 1 && store.manifest("old-1")?.name == "물"
       && store.manifest("old-1")?.color == "blue" && SpaceStore.versions("old-1").isEmpty, "Undo brings the old version back")
expect(SpaceStore.state(SpaceStore.folder("old-1")).count > 12, "Undo of a code change keeps the data")

// A change asked in a Space's box (C0, moved down from the chat): a refused block goes back once with its reason, a
// second refusal is the outcome; no block is a failure with what the AI said; pictures are asked only once a block came.
do {
    let page = "<!doctype html><html><body><p>v2</p></body></html>"
    let good = "새 판이에요.\n<space-build>\n<space-html>\n\(page)\n</space-html>\n</space-build>"
    let bad = "<space-build><space-manifest>{}</space-manifest></space-build>"
    var prompts: [String] = [], madeAsked = 0
    func refine(_ answers: [String]) -> Result<(build: SpaceBuild, said: String), SpaceBad> {
        var left = answers
        prompts = []; madeAsked = 0
        return SpaceBuilder.refine(prompt: "P", kept: [], ask: { prompts.append($0); return .success(left.removeFirst()) },
                                   made: { madeAsked += 1; return [] }, said: { $0.uppercased() })
    }
    if case .success(let done) = refine([good]) {
        expect(done.build.html.contains("v2") && done.said == "새 판이에요." && prompts == ["P"] && madeAsked == 1, "a good block is the new version: \(prompts)")
    } else { expect(false, "a good block is the new version") }
    if case .success = refine([bad, good]) {
        expect(prompts.count == 2 && prompts[1].hasPrefix("P\n[The app refused your block: ") && prompts[1].hasSuffix("Send the whole fixed block again.]"), "a refused block goes back once with the reason")
    } else { expect(false, "the fixed block after a refusal is taken") }
    if case .failure = refine([bad, bad]) { expect(prompts.count == 2, "a second refusal is not sent back again") } else { expect(false, "two refusals fail") }
    if case .failure(let none) = refine(["just words"]) {
        expect(none.reason == "JUST WORDS" && prompts.count == 1 && madeAsked == 0, "no block: what the AI said, no retry, no pictures asked")
    } else { expect(false, "no block fails") }
    let failed = SpaceBuilder.refine(prompt: "P", kept: [], ask: { _ in .failure(SpaceBad(reason: "usage")) }, made: { [] }, said: { $0 })
    if case .failure(let why) = failed { expect(why.reason == "usage", "a failed request is the outcome, not retried") } else { expect(false, "a failed request fails") }
}

extension Result { var isSuccess: Bool { if case .success = self { return true }; return false } }
print("PASS: AISpaces module promises (old spaces folder, save format) from outside")
