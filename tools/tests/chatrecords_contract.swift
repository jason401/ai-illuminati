import Foundation
import AIAccounts
import AIChatRecords

// The promises of the AIChatRecords module, checked from outside it with only its public API: chats/ in the data
// folder, pictures at chats/<id>.assets/<picture>.png (bad data refused), dropped files under chats/<id>.documents,
// collab-log.jsonl lines read and written as before the module existed, the log cut in half past its size, the
// summary line, and the disk report counting a hard-linked file once.
// Run with AI_ILLUMINATI_TEST_HOME set to an empty folder (run_mode2.sh).
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("FAIL: " + message) }
}
let fm = FileManager.default
let home = ProcessInfo.processInfo.environment["AI_ILLUMINATI_TEST_HOME"] ?? ""
expect(!home.isEmpty && AccountStore.home == home, "the records test needs its own home")
let support = home + "/Library/Application Support/AI Illuminati"
expect(ChatPaths.dir == support + "/chats", "chats live in the data folder's chats/")

// Pictures: a PNG under <chat>.assets named by the picture's id; data that is no picture is refused and leaves nothing.
let room = UUID(uuidString: "C0FFEE00-0000-4000-8000-000000000001")!, pic = UUID(uuidString: "C0FFEE00-0000-4000-8000-000000000002")!
let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
let image = try! ImageStore.importImage(png, name: "dot.png", conversationID: room, id: pic)
expect(image.url.path == ChatPaths.dir + "/\(room.uuidString).assets/\(pic.uuidString).png", "picture path: \(image.url.path)")
expect(fm.fileExists(atPath: image.url.path), "the picture is written")
let saved = try! JSONEncoder().encode(image)
expect(try! JSONDecoder().decode(ChatImage.self, from: saved) == image, "a picture's record reads back")
let bad = UUID()
expect((try? ImageStore.importImage(Data("not a picture".utf8), name: "x.png", conversationID: room, id: bad)) == nil, "bad picture refused")
expect(!fm.fileExists(atPath: ChatPaths.dir + "/\(room.uuidString).assets/\(bad.uuidString).png"), "a refused picture leaves no file")
try! ImageStore.remove(image)
expect(!fm.fileExists(atPath: image.url.path), "remove deletes the picture")

// Dropped files: kept in the chat's documents folder; the readable kinds are fixed.
expect(RoomDocuments.directory(room).path == ChatPaths.dir + "/\(room.uuidString).documents", "documents folder")
expect(RoomDocuments.extensions.isSuperset(of: ["pdf", "txt", "md", "csv"]), "readable document kinds")
let temp = URL(fileURLWithPath: home).appendingPathComponent("drop.txt")
try! Data("hello".utf8).write(to: temp)
let kept = try! RoomDocuments.keepDropped([temp], room: room)
expect(kept.count == 1 && kept[0].path.hasPrefix(RoomDocuments.directory(room).path + "/Dropped ") && kept[0].lastPathComponent == "drop.txt",
       "a dropped file is copied into the chat's documents: \(kept)")

// The collab log: a line from before the module reads as it was and is written again byte for byte.
let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .sortedKeys
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
let oldLine = #"{"at":"2026-11-01T10:00:00Z","call":1,"chat":"C0FFEE00-0000-4000-8000-000000000001","failed":0,"from":"claude-1","fromKind":"claude","kind":"ask","mode":"notify","purpose":"review","smallTalk":false,"to":["codex-1"],"toKinds":["codex"]}"#
let old = try! decoder.decode(CollabEvent.self, from: Data(oldLine.utf8))
expect(String(decoding: try! encoder.encode(old), as: UTF8.self) == oldLine, "an old collab line is written back the same")
let made = CollabEvent(at: ISO8601DateFormatter().date(from: "2026-11-01T10:00:00Z")!, kind: .ask, chat: room,
                       mode: "notify", from: "claude-1", fromKind: "claude", to: ["codex-1"], toKinds: ["codex"], purpose: "review",
                       call: 1, failed: 0, smallTalk: false)
expect(made == old, "the public init builds the same event")

// add appends one line; past 2 MB the older half of the lines goes.
let log = URL(fileURLWithPath: support + "/collab-log.jsonl")
CollabLog.add(made)
CollabLog.add(CollabEvent(kind: .outcome, chat: room, outcome: "yes"))
expect(CollabLog.events().count == 2, "two events logged")
expect(CollabLog.line(CollabLog.summary(CollabLog.events())) != CollabLog.line(CollabLog.summary([])), "the summary line counts them")
let filler = String(repeating: oldLine + "\n", count: 2_000_000 / oldLine.utf8.count + 10)
try! Data(filler.utf8).write(to: log)
CollabLog.add(made)
let size = (try! fm.attributesOfItem(atPath: log.path)[.size] as! Int)
expect(size > 900_000 && size < 1_200_000, "a full log keeps its newer half: \(size)")
expect(CollabLog.smallTalk("고마워요!") && !CollabLog.smallTalk("이거 고쳐 줘"), "small talk is greetings and thanks only")
expect(CollabLog.asksOthers("다른 AI한테 물어봐") && !CollabLog.asksOthers("이 코드 봐 줘"), "asking for other AIs is seen")

// Disk report: a chat's work folder with a file and a hard link to it counts the file once.
let work = URL(fileURLWithPath: ChatPaths.dir).appendingPathComponent(room.uuidString + ".work")
try! fm.createDirectory(at: work, withIntermediateDirectories: true)
try! Data(repeating: 7, count: 10_000).write(to: work.appendingPathComponent("a.bin"))
try! fm.linkItem(at: work.appendingPathComponent("a.bin"), to: work.appendingPathComponent("b.bin"))
let report = ChatStorage.report([(id: room, title: "Room", meetingOf: nil)])
let mine = report.rooms.first { $0.id == room }
expect(mine?.parts[.work]?.files == 1 && mine?.parts[.work]?.logical == 10_000, "a hard-linked file counts once: \(String(describing: mine?.parts[.work]))")
expect(ChatStorage.describe(mine!).contains("work "), "the report line names the parts")

print("PASS: AIChatRecords contract")
