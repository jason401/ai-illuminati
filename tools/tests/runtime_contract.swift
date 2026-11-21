import Foundation
import Darwin
import AIAccounts
#if canImport(AIRuntime)
import AIRuntime
#endif

// The promises of the Runtime (AIRuntime), checked from outside with only its public API and a fake command line
// tool (a shell script started as the AI's tool): errors, Stop, time out, the process group, stream events in
// order, sessions saved and resumed. Run with AI_ILLUMINATI_TEST_HOME set to an empty folder (run_mode2.sh).
// No real CLI, home, Keychain or account folder is used; Gemini's fake calls use RunConditions(), without app settings.
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("FAIL: " + message) }
}
let fm = FileManager.default
let home = ProcessInfo.processInfo.environment["AI_ILLUMINATI_TEST_HOME"] ?? ""
expect(!home.isEmpty && AccountStore.home == home, "the runtime test needs its own home")
let fake = URL(fileURLWithPath: home).appendingPathComponent("fake")
try! fm.createDirectory(at: fake, withIntermediateDirectories: true)
let script = fake.appendingPathComponent("cli")
// FAKE_MODE picks what the tool does. It writes its arguments and its standard input where the test reads them.
try! #"""
#!/bin/sh
printf '%s\n' "$@" > "$FAKE_DIR/args"
pwd -P > "$FAKE_DIR/cwd"
case "$FAKE_MODE" in steer*) exec /usr/bin/python3 "$FAKE_DIR/steer.py" ;; esac
cat > "$FAKE_DIR/stdin"
out=""; prev=""; sid=""; for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  [ "$prev" = "--session-id" ] || [ "$prev" = "--resume" ] && sid="$a"
  prev="$a"
done
case "$FAKE_MODE" in
  sleep) echo $$ > "$FAKE_DIR/pid"; sh -c 'echo $$ > "$FAKE_DIR/child"; exec sleep 30' &
         /usr/bin/perl -e 'setpgrp(0, 0); exec @ARGV' sh -c 'echo $$ > "$FAKE_DIR/stray"; exec sleep 30' &
         wait ;;
  group) echo $$ > "$FAKE_DIR/pid"; sh -c 'echo $$ > "$FAKE_DIR/child"; exec sleep 30' </dev/null >/dev/null 2>&1 &
         echo 'left one' ;;
  fail) echo "boom from the tool" >&2; exit 3 ;;
  modelcodex|modelgemini) exec /usr/bin/python3 "$FAKE_DIR/models.py" "$out" ;;
  stream) cat "$FAKE_DIR/stream.jsonl" ;;
  codex) cat "$FAKE_DIR/stream.jsonl"; printf 'codex answer' > "$out" ;;
  session) [ "$sid" = "" ] && sid="$FAKE_SID"
           printf '{"type":"result","session_id":"%s","is_error":false,"result":"TL;DR: short\\n\\nanswer %s"}\n' "$sid" "$FAKE_TURN" ;;
  sessioncompact) [ "$sid" = "" ] && sid="$FAKE_SID"; echo '{"type":"system","subtype":"compact_boundary"}'
           printf '{"type":"result","session_id":"%s","is_error":false,"result":"TL;DR: short\\n\\nanswer %s"}\n' "$sid" "$FAKE_TURN" ;;
  codexsession) echo "{\"type\":\"thread.started\",\"thread_id\":\"$FAKE_SID\"}"; echo '{"type":"turn.completed"}'; printf 'codex session answer' > "$out" ;;
esac
"""#.write(to: script, atomically: true, encoding: .utf8)
try! fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
Answerer.toolForTests = script.path

let claude = Account(id: "claude-rt", provider: .claude, name: "Claude", dir: AccountStore.accountsDir + "/claude-rt")
let codex = Account(id: "codex-rt", provider: .codex, name: "Codex", dir: AccountStore.accountsDir + "/codex-rt")
// The project marker is taken off unless asked for: this test may itself run inside project work, and with the
// marker Stop ends the tool's whole group first (checked on its own below).
func run(_ mode: String, sid: String = "", turn: String = "", group: Bool = false, marker: Bool = false) -> RunConditions {
    var run = RunConditions()
    run.environment = { env in
        var env = env; env["FAKE_MODE"] = mode; env["FAKE_DIR"] = fake.path; env["FAKE_SID"] = sid; env["FAKE_TURN"] = turn
        env["HOME"] = home
        env["AI_ILLUMINATI_PROJECT_PROCESS"] = marker ? "1" : nil
        return env
    }
    if group {   // a wrapper that makes the tool lead its own process group (as project_process.py does)
        run.wrapper = ["/usr/bin/perl", "-e", "setpgrp(0, 0); exec @ARGV or die"]
        run.processGroup = true
    }
    return run
}
func read(_ name: String) -> String { (try? String(contentsOf: fake.appendingPathComponent(name), encoding: .utf8)) ?? "" }
func pid(_ name: String) -> pid_t? { pid_t(read(name).trimmingCharacters(in: .whitespacesAndNewlines)) }
func alive(_ pid: pid_t?) -> Bool { pid.map { kill($0, 0) == 0 } ?? false }
func gone(_ name: String, within seconds: Double = 3) -> Bool {
    guard pid(name) != nil else { return false }   // never started: nothing was checked
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if !alive(pid(name)) { return true }; Thread.sleep(forTimeInterval: 0.05) }
    return false
}
func clear() { for name in ["args", "stdin", "pid", "child", "stray", "cwd"] { try? fm.removeItem(at: fake.appendingPathComponent(name)) } }
func failure(_ result: Result<String, Answerer.Failure>) -> Answerer.Failure? { if case .failure(let f) = result { return f }; return nil }

// The caller's preparation runs once per start, before the tool; not at all for a stopped token.
var prepared = 0
var prepare = run("fail"); prepare.beforeStart = { prepared += 1 }
_ = Answerer.ask(claude, prompt: "hi", run: prepare)
expect(prepared == 1, "beforeStart runs once before the tool starts")

// Errors: the tool's own message (its last 300 letters) on a failed exit; a tool that cannot start is "missing".
clear()
if case .failed(let why)? = failure(Answerer.ask(claude, prompt: "hi", run: run("fail"))) { expect(why.contains("boom from the tool"), "a failed tool's message is passed on") }
else { expect(false, "a tool that exits with an error is a failure") }
Answerer.toolForTests = fake.appendingPathComponent("not-there").path
if case .missingTool? = failure(Answerer.ask(claude, prompt: "hi", run: run("fail"))) {} else { expect(false, "a tool that cannot start is missingTool") }
Answerer.toolForTests = script.path

// Stop: a cancelled token starts nothing; Stop while it runs ends the tool and what it started, at once.
clear()
let stopped = DebateCancellation(); stopped.cancel()
if case .failed("Cancelled")? = failure(Answerer.ask(claude, prompt: "hi", cancellation: stopped, run: run("sleep"))) {} else { expect(false, "a stopped token gives Cancelled") }
expect(!fm.fileExists(atPath: fake.appendingPathComponent("args").path), "a stopped token starts no tool")
var stoppedPrepare = run("sleep"); stoppedPrepare.beforeStart = { prepared += 1 }
_ = Answerer.ask(claude, prompt: "hi", cancellation: stopped, run: stoppedPrepare)
expect(prepared == 1, "a stopped token runs no preparation")
clear()
let token = DebateCancellation()
DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { token.cancel() }
var started = Date()
// It fails; "Cancelled" when the runtime sees the Stop first, the tool's own exit when the tool ends first (both
// happen: callers look at the token, not at the message).
expect(failure(Answerer.ask(claude, prompt: "hi", timeout: 60, cancellation: token, run: run("sleep"))) != nil, "Stop fails the answer")
expect(Date().timeIntervalSince(started) < 5, "Stop ends the answer at once")
// Two layers: the tool's own group ends with it (Foundation starts it as a group leader); a program that left
// that group is found by parent and ended on its own. Each is checked apart.
expect(gone("pid") && gone("child"), "Stop ends the tool and the programs it started")
expect(gone("stray"), "Stop also ends a program the tool started in a group of its own")

// The project marker (AI_ILLUMINATI_PROJECT_PROCESS=1, project work's own process group): Stop ends that whole group
// at once, before anything else.
clear()
let marked = DebateCancellation()
DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { marked.cancel() }
started = Date()
expect(failure(Answerer.ask(claude, prompt: "hi", timeout: 60, cancellation: marked, run: run("sleep", marker: true))) != nil, "Stop fails a marked answer")
expect(Date().timeIntervalSince(started) < 5 && gone("pid") && gone("child"), "Stop ends a marked tool's whole group")
if let stray = pid("stray") { kill(stray, SIGKILL) }   // outside the group: the marker's group kill comes first (as before)

// Time out: the tool and its children are ended, the answer is timedOut.
clear()
started = Date()
if case .timedOut? = failure(Answerer.ask(claude, prompt: "hi", timeout: 1.5, run: run("sleep"))) {} else { expect(false, "a slow tool times out") }
expect(Date().timeIntervalSince(started) < 6, "the time limit is kept")
expect(gone("pid") && gone("child"), "a timed-out tool and its children are ended")
expect(gone("stray"), "a timed-out tool's program in a group of its own is ended too")

// Process group: when the conditions say so, everything left in the tool's group is stopped after a good answer;
// without it, a program the tool left behind is not the runtime's to stop.
clear()
expect((try? Answerer.ask(claude, prompt: "hi", run: run("group", group: true)).get()) == "left one", "a grouped call still answers")
expect(gone("child"), "the process group is stopped when the call ends")
clear()
expect((try? Answerer.ask(claude, prompt: "hi", run: run("group")).get()) == "left one", "an ungrouped call answers")
Thread.sleep(forTimeInterval: 0.3)
expect(alive(pid("child")), "without a process group nothing else is stopped")
if let child = pid("child") { kill(child, SIGKILL) }

// Stream events in order, on a background thread: Claude's text within one message (a new message starts over),
// a tool start as activity, the TodoWrite list as it came, the last text of a message always sent; the answer
// is the result line.
func events(_ account: Account, _ lines: [String], mode: String) -> ([String], String?) {
    try! (lines.joined(separator: "\n") + "\n").write(to: fake.appendingPathComponent("stream.jsonl"), atomically: true, encoding: .utf8)
    var seen: [String] = [], main = false
    let lock = NSLock()
    let answer = try? Answerer.ask(account, prompt: "hi", run: run(mode), progress: { update in
        lock.lock(); defer { lock.unlock() }
        if Thread.isMainThread { main = true }
        switch update {
        case .text(let text): seen.append("text:" + text)
        case .activity(let text): seen.append("activity:" + text)
        case .todos(let todos): seen.append("todos:" + String(describing: (todos as? [[String: Any]])?.compactMap { $0["content"] as? String } ?? ["not a list"]))
        case .model(let name): seen.append("model:" + name)
        case .agent: seen.append("agent")
        }
    }).get()
    expect(!main, "progress comes on a background thread")
    return (seen, answer)
}
clear()
let (claudeAll, claudeAnswer) = events(claude, [
    #"{"type":"system","subtype":"init","model":"claude-opus-5-5"}"#,
    #"{"type":"stream_event","event":{"type":"message_start"}}"#,
    #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}}}"#,
    #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"lo"}}}"#,
    #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","name":"TodoWrite"}}}"#,
    #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"one"},{"content":"two"}]}}]}}"#,
    #"{"type":"stream_event","event":{"type":"message_stop"}}"#,
    #"{"type":"stream_event","event":{"type":"message_start"}}"#,
    #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","name":"WebSearch"}}}"#,
    #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":"odd"}}]}}"#,
    #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Done"}}}"#,
    #"{"type":"stream_event","event":{"type":"message_stop"}}"#,
    #"{"type":"result","result":"Done","is_error":false}"#,
], mode: "stream")
expect(claudeAnswer == "Done", "Claude's answer is its result line")
expect(claudeAll.filter { $0.hasPrefix("model:") } == ["model:claude-opus-5-5"] && claudeAll.last == "model:claude-opus-5-5", "the model its stream named comes once, last: \(claudeAll)")
let claudeEvents = claudeAll.filter { !$0.hasPrefix("model:") }
expect(read("args").contains("stream-json") && read("args").contains("--include-partial-messages"), "a streamed Claude call asks for partial messages")
// Repeated text of one message (the ~12-a-second limit) is folded: what is left is the order of events.
var folded: [String] = []
for event in claudeEvents {
    if let last = folded.last, last.hasPrefix("text:"), event.hasPrefix("text:"), event.hasPrefix(last) { folded[folded.count - 1] = event } else { folded.append(event) }
}
let activity = claudeEvents.first { $0.hasPrefix("activity:") } ?? ""
expect(["text:Hel", "text:Hello"].contains(folded.first ?? "") && Array(folded.dropFirst()) == [activity, "todos:[\"one\", \"two\"]", "text:Hello", claudeEvents.filter { $0.hasPrefix("activity:") }.last!,
                  "todos:[\"not a list\"]", "text:Done"], "Claude stream events in order: \(claudeEvents)")
expect(claudeEvents.first == "text:Hel", "the first piece is sent at once")
expect(claudeEvents.filter { $0.hasPrefix("activity:") }.count == 2, "every tool start is activity")
clear()
let (codexEvents, codexAnswer) = events(codex, [
    #"{"type":"thread.started","thread_id":"x"}"#,
    #"{"type":"item.started","item":{"type":"command_execution"}}"#,
    #"{"type":"item.completed","item":{"type":"agent_message","text":"first"}}"#,
    #"{"type":"item.started","item":{"type":"web_search"}}"#,
    #"{"type":"item.completed","item":{"type":"agent_message","text":"second"}}"#,
], mode: "codex")
expect(codexAnswer == "codex answer", "Codex's answer is its -o file")
expect(read("args").contains("--json"), "a streamed Codex call asks for JSON events")
expect(codexEvents.count == 5 && codexEvents[0].hasPrefix("activity:") && codexEvents[1] == "text:first"
       && codexEvents[2].hasPrefix("activity:") && codexEvents[3] == "text:second" && codexEvents[4] == "model:", "Codex stream events in order: \(codexEvents)")

// Real subprocess path for model attribution, entirely under the isolated home. No live CLI or agy settings.
try! #"""
import os, sys, json, uuid, datetime, pathlib
provider = os.environ["FAKE_MODE"]
scenario = os.environ["FAKE_TURN"]
sid = str(uuid.uuid4())
def write(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row) + "\n" for row in rows))
if provider == "modelcodex":
    root = pathlib.Path(os.environ["CODEX_HOME"])
    rows = [
        {"type":"session_meta", "payload":{"id":sid, "cwd":os.getcwd()}},
        {"type":"turn_context", "timestamp":datetime.datetime.now(datetime.timezone.utc).isoformat(),
         "payload":{"model":"gpt-actual-" + (scenario or "first")}}
    ]
    if scenario != "missing":
        write(root / "sessions" / ("rollout-" + sid + ".jsonl"), rows)
    pathlib.Path(sys.argv[1]).write_text("codex model answer")
    print(json.dumps({"type":"thread.started", "thread_id":sid}))
    print(json.dumps({"type":"turn.completed"}))
else:
    root = pathlib.Path(os.environ["HOME"]) / ".gemini/antigravity-cli/brain"
    if scenario != "missing":
        write(root / sid / ".system_generated/logs/transcript.jsonl",
              [{"type":"PLANNER_RESPONSE", "model":"gemini-early"},
               {"type":"PLANNER_RESPONSE", "model":"gemini-actual"}])
    if scenario.startswith("agy"):  # agy's own stream-json: {"event": ...}
        print(json.dumps({"event":"init", "conversation_id":sid, "init":{"cwd":"x"}}))
        ok = scenario == "agy"
        print(json.dumps({"event":"result", "result":{"conversation_id":sid, "status":"SUCCESS" if ok else "ERROR",
                          "response":"gemini model answer" if ok else "", "error":"" if ok else "print timeout after 2s"}}))
    else:
        print(json.dumps({"type":"system", "subtype":"init", "session_id":sid, "model":"selected-alias"}))
        print(json.dumps({"type":"result", "session_id":sid, "is_error":scenario == "fail",
                          "result":"gemini model answer"}))
"""#.write(to: fake.appendingPathComponent("models.py"), atomically: true, encoding: .utf8)
let geminiAccount = Account(id: "gemini-rt", provider: .gemini, name: "Gemini")
func modelAnswer(_ account: Account, scenario: String = "") -> (String?, [String]) {
    var names: [String] = []
    let lock = NSLock()
    let result = Answerer.ask(account, prompt: "hi", run: run(account.provider == .codex ? "modelcodex" : "modelgemini", turn: scenario)) {
        if case .model(let name) = $0 { lock.lock(); names.append(name); lock.unlock() }
    }
    return (try? result.get(), names)
}
let modelC = modelAnswer(codex)
expect(modelC.0 == "codex model answer" && modelC.1 == ["gpt-actual-first"], "Codex model reaches progress from the exact thread log: \(modelC)")
expect(!read("args").contains("--ephemeral"), "a visible Codex answer keeps its model log")
expect(modelAnswer(codex, scenario: "second").1 == ["gpt-actual-second"], "next call uses its own changed model")
expect(modelAnswer(codex, scenario: "missing").1 == [""], "missing Codex log explicitly reports unknown, never the prior call")
let modelG = modelAnswer(geminiAccount)
expect(modelG.0 == "gemini model answer" && modelG.1 == ["gemini-actual"], "Gemini JSON is decoded and its final log model reaches progress")
expect(read("args").contains("--output-format\nstream-json"), "Gemini requests machine-readable output")
expect(modelAnswer(geminiAccount, scenario: "missing").1 == [""], "Gemini init pick never substitutes for a missing actual model")
let failedG = modelAnswer(geminiAccount, scenario: "fail")
expect(failedG.0 == nil && failedG.1.isEmpty, "failed Gemini result emits no successful model")
let agyG = modelAnswer(geminiAccount, scenario: "agy")
expect(agyG.0 == "gemini model answer" && agyG.1 == ["gemini-actual"], "agy's own event stream is decoded with its model: \(agyG)")
let agyFailed = Answerer.ask(geminiAccount, prompt: "hi", run: run("modelgemini", turn: "agyfail")) { _ in }
if case .failure(.failed(let why)) = agyFailed { expect(why.contains("print timeout"), "agy's error reaches the user: \(why)") }
else { expect(false, "agy ERROR status is a failure: \(agyFailed)") }

// Sessions: a new session is saved in the room's ownership.json (the format older app versions wrote and read),
// the next call resumes it with only what is new, and a file from an older version is read as it is.
let sessions = NativeSessions(), room = UUID(), sid = UUID().uuidString
func ask(_ context: String, _ account: Account = claude, sid: String, mode: String = "session", turn: String, appendContext: Bool = false) -> Result<String, Answerer.Failure> {
    sessions.ask(account, room: room, prompt: context + "\n[MODE3 SPEECH]\nanswer", images: [], timeout: 30, token: DebateCancellation(), web: false,
                 speaker: "Claude", appendContext: appendContext, invoke: { text, images, call in
        Answerer.ask(account, prompt: text, timeout: 30, images: images, session: call, run: run(mode, sid: sid, turn: turn))
    }, note: { _ in })
}
clear()
let first = ask("source", sid: sid, turn: "1"); expect((try? first.get()) == "TL;DR: short\n\nanswer 1", "a session answer is the result: \(first)")
let firstArgs = read("args").split(separator: "\n").map(String.init)
expect(firstArgs.contains("--session-id") && !firstArgs.contains("--resume") && !firstArgs.contains("--no-session-persistence"), "a new session starts with its own id: \(firstArgs)")
let given = firstArgs[firstArgs.firstIndex(of: "--session-id")! + 1]
let ledger = NativeSessions.directory(room).appendingPathComponent("ownership.json")
func records() -> [[String: Any]] { (try? JSONSerialization.jsonObject(with: Data(contentsOf: ledger))) as? [[String: Any]] ?? [] }
expect(records().count == 1 && Set(records()[0].keys) == ["id", "accountID", "provider", "role", "nativeID", "context", "ownBlock", "images", "valid"],
       "ownership.json keeps its fields: \(records())")
let saved = records()[0]
expect(saved["nativeID"] as? String == given && saved["accountID"] as? String == "claude-rt" && saved["provider"] as? String == "claude"
       && saved["role"] as? String == "speaker" && saved["context"] as? String == "source" && saved["valid"] as? Bool == true
       && saved["ownBlock"] as? String == "[Claude]\nanswer 1", "the session id and what it holds are saved: \(saved)")
expect((try? fm.attributesOfItem(atPath: ledger.path)[.posixPermissions] as? Int) == 0o600, "ownership.json is private")
expect(sessions.pinnedAccount(.claude, room: room) == "claude-rt", "a speaker's session pins its account")
clear()
expect((try? ask("source\n\nnew part", sid: sid, turn: "2").get()) == "TL;DR: short\n\nanswer 2", "a resumed session answers")
let secondArgs = read("args").split(separator: "\n").map(String.init)
expect(secondArgs.contains("--resume") && secondArgs[secondArgs.firstIndex(of: "--resume")! + 1] == given, "the next call resumes the saved session: \(secondArgs)")
expect(!read("stdin").contains("source") && read("stdin").contains("new part"), "a resumed session gets only what is new")
// An older version's file: the same fields, written by hand; it is read and resumed as it is.
let oldRoom = UUID(), oldID = UUID(), oldSession = UUID().uuidString
try! fm.createDirectory(at: NativeSessions.directory(oldRoom), withIntermediateDirectories: true)
try! """
[{"id":"\(oldID.uuidString)","accountID":"codex-rt","provider":"codex","role":"speaker","nativeID":"\(oldSession)","context":"old","ownBlock":"","images":[],"valid":true}]
""".write(to: NativeSessions.directory(oldRoom).appendingPathComponent("ownership.json"), atomically: true, encoding: .utf8)
expect(sessions.pinnedAccount(.codex, room: oldRoom) == "codex-rt", "an older ownership.json is read")
clear()
let resumed = sessions.ask(codex, room: oldRoom, prompt: "old\n\nmore\n[MODE3 SPEECH]\nspeak", images: [], timeout: 30, token: DebateCancellation(), web: false,
                           speaker: "Codex", invoke: { text, images, call in
    return Answerer.ask(codex, prompt: text, timeout: 30, images: images, session: call, run: run("codexsession", sid: oldSession, turn: ""))
}, note: { _ in })
expect((try? resumed.get()) == "codex session answer", "a resumed Codex session answers")
let codexArgs = read("args").split(separator: "\n").map(String.init)
expect(read("cwd").trimmingCharacters(in: .newlines).hasSuffix("/" + oldID.uuidString), "the old record's session runs in its own folder")
expect(codexArgs.contains("resume") && codexArgs.contains(oldSession) && !read("stdin").contains("old"), "Codex resumes with exec resume <id> and only what is new: \(codexArgs)")
// A stopped answer is not retried and marks the session for a rebuild.
clear()
let stop = DebateCancellation()
var calls = 0
_ = sessions.ask(claude, room: room, prompt: "source\n\nnew part\n\nmore\n[SOLO TURN]\nanswer", images: [], timeout: 30, token: stop, web: false, speaker: "Claude",
                 invoke: { text, images, call in calls += 1; stop.cancel(); return Answerer.ask(claude, prompt: text, cancellation: stop, session: call, run: run("session")) }, note: { _ in })
expect(calls == 1 && records().last?["valid"] as? Bool == false, "a stopped session answer is not retried and the session is rebuilt next time")
// Fixed instructions (before the turn marker) go as the system prompt on every call, never in the text; the CLI's own
// compaction keeps the same session; changed fixed instructions start a new one.
do {
    let fixedRoom = UUID(), fixedSID = UUID().uuidString
    func fixedAsk(_ context: String, fixed: String = "FIXED RULES 9137", turnPart: String, mode: String = "session", provider: Account = claude) -> [String] {
        clear()
        let prompt = context + "\n[SOLO TURN]\n" + fixed + "\n" + NativeSessions.turnMarker + "\n" + turnPart
        _ = sessions.ask(provider, room: fixedRoom, prompt: prompt, images: [], timeout: 30, token: DebateCancellation(), web: false, speaker: "Claude",
                         invoke: { text, images, call in
            expect(!text.contains(fixed) && text.contains("[SOLO TURN]") && text.contains(turnPart), "the session text has the turn part, not the fixed one: \(text)")
            return Answerer.ask(provider, prompt: text, timeout: 30, images: images, session: call, run: run(mode, sid: fixedSID, turn: "f"))
        }, note: { _ in })
        return read("args").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
    func ledger() -> [[String: Any]] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: NativeSessions.directory(fixedRoom).appendingPathComponent("ownership.json")))) as? [[String: Any]] ?? []
    }
    let a1 = fixedAsk("chat", turnPart: "files A", mode: "sessioncompact")
    let started = a1.firstIndex(of: "--session-id").map { a1[$0 + 1] }
    expect(a1.firstIndex(of: "--append-system-prompt").map { a1[$0 + 1] } == "FIXED RULES 9137", "a new session gets the fixed part as its system prompt: \(a1)")
    expect(!read("stdin").contains("FIXED RULES") && !a1.contains { $0.contains("FIXED RULES") && $0 != "FIXED RULES 9137" }, "the fixed part is not in the message")
    expect(ledger().last?["valid"] as? Bool == true && (ledger().last?["system"] as? String)?.count == 64, "a compacted session stays valid and keeps its system digest: \(ledger())")
    let a2 = fixedAsk("chat\n\nmore", turnPart: "files B")
    expect(a2.firstIndex(of: "--resume").map { a2[$0 + 1] } == started && started != nil, "after compaction the same session id is resumed: \(a2)")
    expect(a2.firstIndex(of: "--append-system-prompt").map { a2[$0 + 1] } == "FIXED RULES 9137", "a resumed call passes the system prompt again")
    let a3 = fixedAsk("chat\n\nmore\n\nnext", fixed: "FIXED RULES 2", turnPart: "files C")
    expect(a3.contains("--session-id") && !a3.contains("--resume"), "changed fixed instructions start a new session: \(a3)")
    let c1 = fixedAsk("codex chat", fixed: "FIXED \"R\" /x", turnPart: "files", mode: "codexsession", provider: codex)
    let toml = "developer_instructions=\"FIXED \\\"R\\\" /x\""
    expect(c1.firstIndex(of: toml).map { c1[$0 - 1] == "-c" && $0 < c1.firstIndex(of: "exec")! } == true, "Codex gets the fixed part as developer_instructions: \(c1)")
}
// Steering: a fake Claude that speaks stream-json. Messages go in only while a tool runs; one it reads (replayed) is
// told once and belongs to the answer; one never written, or written but not read before the result, comes back from close().
try! #"""
import json, os, select, sys, time
mode, d = os.environ["FAKE_MODE"], os.environ["FAKE_DIR"]
fd = sys.stdin.fileno(); buf = b""; seen = []
def out(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
def line(wait):
    global buf
    end = time.time() + wait
    while b"\n" not in buf:
        left = end - time.time()
        if left <= 0 or not select.select([fd], [], [], left)[0]: return None
        chunk = os.read(fd, 65536)
        if not chunk: return None
        buf += chunk
    raw, buf = buf.split(b"\n", 1)
    text = "".join(b.get("text", "") for b in json.loads(raw)["message"]["content"])
    seen.append(text); open(d + "/stdin", "w").write("\n".join(seen))
    return text
def replay(t): out({"type": "user", "isReplay": True, "parent_tool_use_id": None, "message": {"role": "user", "content": [{"type": "text", "text": t}]}})
replay(line(5))
read = None
if mode in ("steer-tool", "steer-cutoff"):
    out({"type": "stream_event", "event": {"type": "content_block_start", "content_block": {"type": "tool_use", "name": "Bash"}}})
    out({"type": "assistant", "parent_tool_use_id": None, "message": {"content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {}}]}})
    if mode == "steer-tool": read = line(5)
    else: time.sleep(1)
    out({"type": "user", "parent_tool_use_id": None, "message": {"content": [{"type": "tool_result", "tool_use_id": "t1"}]}})
    if read: replay(read)
elif mode == "steer-background":
    # Claude ends its turn while a background agent runs, then wakes when it ends and writes the real answer.
    out({"type": "assistant", "parent_tool_use_id": None, "message": {"content": [{"type": "tool_use", "id": "a1", "name": "Agent", "input": {"run_in_background": True, "description": "review"}}]}})
    out({"type": "system", "subtype": "background_tasks_changed", "tasks": [{"task_id": "k1"}]})
    out({"type": "user", "parent_tool_use_id": None, "message": {"content": [{"type": "tool_result", "tool_use_id": "a1", "content": "launched"}]}})
    out({"type": "result", "is_error": False, "result": "agents running"})
    time.sleep(1)
    out({"type": "system", "subtype": "task_notification", "task_id": "k1", "tool_use_id": "a1", "status": "completed", "summary": "found 2"})
    out({"type": "system", "subtype": "background_tasks_changed", "tasks": []})
    out({"type": "result", "is_error": False, "result": "final review", "origin": {"kind": "task-notification"}})
    sys.exit(0)
else:
    out({"type": "stream_event", "event": {"type": "message_start"}})
    out({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "wri"}}})
    time.sleep(1)
out({"type": "result", "is_error": False, "result": "first" + (" read: " + read if read else "")})
late = line(30)   # the input closes after the result; a message still written here would be a second answer
if late: replay(late); out({"type": "result", "is_error": False, "result": "second"})
"""#.write(to: fake.appendingPathComponent("steer.py"), atomically: true, encoding: .utf8)
func steered(_ mode: String, offerOn: @escaping (AnswerProgress) -> Bool) -> (String?, [String], [String], TimeInterval) {
    clear()
    let channel = SteerChannel()
    var reads: [String] = []
    let lock = NSLock()
    channel.onRead = { text in lock.lock(); reads.append(text); lock.unlock() }
    expect(!channel.live && !channel.offer("too early"), "nothing is taken before a call runs")
    var conditions = run(mode); conditions.steering = channel
    var offered = false
    let started = Date()
    let result = Answerer.ask(claude, prompt: "first prompt", timeout: 20, run: conditions, progress: { update in
        if !offered && offerOn(update) { offered = true; expect(channel.live && channel.offer("change course"), "a running call takes a message") }
    })
    let took = Date().timeIntervalSince(started)
    let left = channel.close()
    expect(!channel.offer("after"), "a closed channel takes nothing")
    lock.lock(); defer { lock.unlock() }
    return (try? result.get(), reads, left, took)
}
func isTool(_ update: AnswerProgress) -> Bool { if case .activity = update { return true }; return false }
func isText(_ update: AnswerProgress) -> Bool { if case .text = update { return true }; return false }
var (answer, reads, left, took) = steered("steer-tool", offerOn: isTool)
let steerArgs = read("args").split(separator: "\n").map(String.init)
expect(steerArgs.contains("--replay-user-messages") && steerArgs.contains("--input-format") && !steerArgs.contains("first prompt"),
       "steering keeps the input open as stream-json and asks for replays: \(steerArgs)")
expect(answer == "first read: change course" && reads == ["change course"] && left.isEmpty, "a message written while a tool runs is read into the answer, once: \(String(describing: answer)) \(reads) \(left)")
(answer, reads, left, took) = steered("steer-late", offerOn: isText)
expect(answer == "first" && reads.isEmpty && left == ["change course"] && !read("stdin").contains("change course"),
       "a message offered while the AI writes is not written; it comes back: \(String(describing: answer)) \(left)")
expect(took < 10, "after the result the input closes and the call ends")
(answer, reads, left, took) = steered("steer-cutoff", offerOn: isTool)
expect(answer == "first" && reads.isEmpty && left == ["change course"] && took < 10,
       "a message written but not read before the result ends the call (no second answer) and comes back: \(String(describing: answer)) \(left) \(took)")
(answer, reads, left, took) = steered("steer-background", offerOn: { _ in false })
expect(answer == "final review" && left.isEmpty,
       "with a background agent running at the first result, the answer is the result written after it ends: \(String(describing: answer))")

// Token counts from the CLIs' own logs (TokenLedger), everything in the test home: a Claude message counts once with
// each field at its highest (a later line that grew adds only the rise, to the hour of its first line); one seen in
// another file is not counted again; a Codex session counts up to its highest total once, wherever it is (moved to the
// archive, compressed as .zst, copied); reasoning is a part of output; a deleted log keeps its sums; the older format's
// deleted logs stay as day sums and their archived copy adds only what came after; tool folders no account uses are
// outside the app; Gemini's shared log has no account; app calls without a log are recorded from the CLI's reply.
let tokHome = home + "/tokens"
let tokClaude = Account(id: "tok-claude", provider: .claude, name: "C", dir: tokHome + "/claude-a")
let tokCodex = Account(id: "tok-codex", provider: .codex, name: "X", dir: tokHome + "/codex-a")
func tokWrite(_ path: String, _ lines: [String], append: Bool = false) {
    try! fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let text = lines.map { $0 + "\n" }.joined()
    if append, let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try! h.close() }
    else { try! text.write(toFile: path, atomically: true, encoding: .utf8) }
}
func tokHour(_ iso: String) -> Date { let d = ISO8601DateFormatter().date(from: iso)!; return Date(timeIntervalSince1970: floor(d.timeIntervalSince1970 / 3600) * 3600) }
func tokSum(_ r: TokenReport, _ keep: (TokenEntry) -> Bool) -> TokenCounts { r.entries.filter(keep).reduce(TokenCounts()) { $0 + $1.counts } }
func tokClaudeLine(_ id: String, _ at: String, out: Int, model: String = "claude-test") -> String {
    #"{"type":"assistant","timestamp":"\#(at)","sessionId":"sess-c","cwd":"/work/app","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":2,"cache_creation_input_tokens":10,"cache_read_input_tokens":100,"output_tokens":\#(out)}}}"#
}
func tokCodexLine(_ at: String, input: Int, cached: Int, out: Int) -> String {
    #"{"timestamp":"\#(at)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(out)}}}}"#
}
let tokA = "2026-03-10T12:00:00Z", tokA2 = "2026-03-10T23:59:30Z", tokB = "2026-03-11T12:00:00Z"
let claudeLog = tokHome + "/claude-a/projects/p/s.jsonl"
tokWrite(claudeLog, [tokClaudeLine("m1", tokA, out: 5), tokClaudeLine("m1", tokA, out: 5),
                     #"{"type":"user","timestamp":"\#(tokA)","message":{"content":"usage"}}"#, tokClaudeLine("m2", tokB, out: 7)])
tokWrite(tokHome + "/codex-a/sessions/2026/03/10/r.jsonl", [tokCodexLine(tokA, input: 100, cached: 60, out: 3),
                                                           tokCodexLine(tokB, input: 250, cached: 160, out: 8)])
tokWrite(tokHome + "/.claude/projects/q/o.jsonl", [tokClaudeLine("o1", tokA, out: 4)])
var tokens = TokenLedger.read([tokClaude, tokCodex], toolHome: tokHome)
let isC: (TokenEntry) -> Bool = { $0.accountID == "tok-claude" }, isX: (TokenEntry) -> Bool = { $0.accountID == "tok-codex" }
expect(tokSum(tokens) { isC($0) && $0.start == tokHour(tokA) } == TokenCounts(input: 2, cacheWrite: 10, cacheRead: 100, output: 5)
       && tokSum(tokens) { isC($0) && $0.start == tokHour(tokB) }.output == 7, "a Claude message split over lines counts once, by its hour: \(tokens.entries.filter(isC))")
let tokC1 = tokens.entries.first { isC($0) }!
expect(tokC1.model == "claude-test" && tokC1.session == "sess-c" && tokC1.project == "/work/app" && tokC1.hourly && tokC1.source == .log,
       "a Claude sum keeps its model, session and working folder: \(tokC1)")
expect(tokSum(tokens) { isX($0) && $0.start == tokHour(tokA) } == TokenCounts(input: 40, cacheRead: 60, output: 3)
       && tokSum(tokens) { isX($0) && $0.start == tokHour(tokB) } == TokenCounts(input: 50, cacheRead: 100, output: 5),
       "a Codex running total is split by the hour of each rise, cached input taken out: \(tokens.entries.filter(isX))")
expect(Set(tokens.entries.filter { $0.accountID == nil }.map(\.folder)) == [tokHome + "/.claude"] && tokSum(tokens) { $0.accountID == nil }.output == 4,
       "a tool folder no account uses is outside the app: \(tokens.entries.map(\.folder))")
expect(tokens.folders.first { $0.folder == tokHome + "/.codex" }?.exists == false && tokens.folders.first { $0.accountID == "tok-claude" }?.files == 1,
       "each folder says whether it is there and how many logs it has: \(tokens.folders)")
// A later line of the same message with more output (it streamed), past midnight: only the rise, to the first line's hour.
tokWrite(claudeLog, [tokClaudeLine("m2", tokB, out: 7), tokClaudeLine("m3", tokB, out: 1), tokClaudeLine("m1", tokA2, out: 9)], append: true)
tokens = TokenLedger.read([tokClaude, tokCodex], toolHome: tokHome)
expect(tokSum(tokens) { isC($0) && $0.start == tokHour(tokB) }.output == 8 && tokSum(tokens) { isC($0) && $0.start == tokHour(tokA) }.output == 9
       && tokSum(tokens, isC).cacheRead == 300, "a grown message adds only the rise, in its first hour; a repeated one counts once: \(tokens.entries.filter(isC))")
expect(fm.fileExists(atPath: AccountStore.supportDir + "/token-usage.json"), "what was read is kept in the support folder")
// The same message in another file (a copied or forked session) is not counted again.
tokWrite(tokHome + "/claude-a/projects/copy/s2.jsonl", [tokClaudeLine("m2", tokB, out: 7), tokClaudeLine("m4", tokB, out: 2)])
tokens = TokenLedger.read([tokClaude, tokCodex], toolHome: tokHome)
expect(tokSum(tokens, isC).output == 19, "a message already counted in another file is not counted again: \(tokSum(tokens, isC))")
// A deleted log (Claude Code removes them after 30 days) keeps its sums; when it comes back it is not counted twice.
try! fm.moveItem(atPath: claudeLog, toPath: claudeLog + ".bak")
tokens = TokenLedger.read([tokClaude, tokCodex], toolHome: tokHome)
expect(tokSum(tokens, isC).output == 19 && tokens.folders.first { $0.accountID == "tok-claude" }?.deleted == 1, "a deleted log keeps its sums")
try! fm.moveItem(atPath: claudeLog + ".bak", toPath: claudeLog)
tokens = TokenLedger.read([tokClaude, tokCodex], toolHome: tokHome)
expect(tokSum(tokens, isC).output == 19, "a log that comes back is not counted twice")
// A file rewritten shorter is read again from the start, without counting what it had twice.
tokWrite(claudeLog, [tokClaudeLine("m1", tokA, out: 9)])
tokens = TokenLedger.read([tokClaude, tokCodex], toolHome: tokHome)
expect(tokSum(tokens, isC).output == 11, "a rewritten log counts what it has now: \(tokSum(tokens, isC))")
// Codex: a session moved to the archive and compressed (.zst) adds only what came after; a copy adds nothing.
let tokZst = Data(base64Encoded: "KLUv/WSnkKUfADaxgx1QdQ4MpdphHPJ2+5hQOvZmelrmpqQka0rZXTWi15EAjABmABTVmKTJ8iKUw5okruld3mW9S3BRHJLJlXnXRC0SU2W5AJ0OW7zMS2Qeg1owiFXUFU2SQ6ooFmAQqqIMIhWFGWAWLMAUjN0fRYqNhsAbjEiQrzmBY2zBdypG2BjEGBLjQIwRURJNRGEBFl1vkpgoybKexSD2KJqLBZihNag1KLHQUKBN0NmSQYwyiS7rTaSLcQLq/C67UXnTqdvcRG2I/tv+61qbkxv3dRMR0WGOSXqeRHpgnqc9DorxaDaRpHoX6rEoEwvkyVCNZ8JQleKJLCRLBXre43oa1NOeN0kEBrEDxK4puizJsiIJVbGA9SaTd0mJZ00UxXpVp4MJxyRNlBW9igX0slCdYLzHIlqwQGsIMeuyUKbniCxLQhJdAdlu2W0qamYjf3PVb84TnXL38+7iq27uY+Pm/LndpXPvZc7cd8VOVkRs7d/tvi61HblXX9nzkRu/Ort3zc762+qYqejbtr/dER1rY/P7ZupyuqPLptzv3tjtty7j7672pzImtmzuNYBOp9PJdYns/86ulXnf6aI+dlvHT3Vf193OiMuq2PmOmU2X391dOu5O5Ma7r7qJj7st+x+VHRMdNteoysi/mK2ImoiYrqHb33R16L3Nv9uqnNmI3xruozeHvfzbqJzZir/ttx/d1W2BTagxWJuIiKQgKUhpGQMBW5CRJqUOIhgUBEEQgoQAQQgQhCAhSAgSgj9BCMAFROAH1l3pgUDvBwmFQS17Kcsel8yXjAfZeCS64eeVXkbyySiMSZdNlkGaoS5LIoNWtiZTSXaVTClWtUxSBvFkt6Ll3XE1ZFZk0svSZKHKrGIpxtaMqWMqxyrGlMeqOYbSyq7FIsaspUzlyVwiqyRTTrZORk1mucnwFcnykA2DFrsUYxFrLXZpMVnF1sSijK2KUcFWcgyJxoAeWxKDqDLLE1NBbK2YWswSDGVM8li6GNSYtdhKsaVi6mIrLUY1YZTHosdIx6TFRIwtFVMXWxajFKs2thwDPTYdE1ExkzOmSuyymKKYO7G3N8a8xLzFrMRCbozFxagQWyqmLLY0VhkLPTY5Bl0sNaZS7KqYsthqMZXAUP0xSzHQY9MxkWJSxpTFVospxajBVsdIjqWLRcmYtSazFJsco4aYyBuz190w0mHTYZFgU8IoMZh9MZgCmBrYtbKY+oT4tJTPrJ9RRc/Dmc8QoTDifwBMHyDzfcDsV0xLGUD7/KQzo5yX71kP86l6/v7n5tuJzAeA9SGneBaTJcmjP0sEepmOTjqPTveOrlcNJfd1KF/pAV4AViFPaDSlKg1NfRVfujw1")!
let tokSession = "rollout-2026-03-10T12-00-00-01a13269-6157-70e2-adf8-ff13aa96615b"
let tokPlain = tokHome + "/codex-a/sessions/2026/03/10/" + tokSession + ".jsonl"
tokWrite(tokPlain, [#"{"timestamp":"\#(tokA)","type":"session_meta","payload":{"id":"01a13269-6157-70e2-adf8-ff13aa96615b","cwd":"/work/proj","originator":"codex_exec"}}"#,
                    #"{"timestamp":"\#(tokA)","type":"turn_context","payload":{"model":"gpt-test"}}"#,
                    #"{"timestamp":"\#(tokA)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":3,"reasoning_output_tokens":1}}}}"#])
tokens = TokenLedger.read([tokClaude, tokCodex], toolHome: tokHome)
let isS: (TokenEntry) -> Bool = { $0.session == "01a13269-6157-70e2-adf8-ff13aa96615b" }
expect(tokSum(tokens, isS) == TokenCounts(input: 40, cacheRead: 60, output: 3, reasoning: 1) && tokens.entries.first(where: isS)?.model == "gpt-test"
       && tokens.entries.first(where: isS)?.project == "/work/proj", "a Codex session keeps its model, folder and reasoning (part of output): \(tokens.entries.filter(isS))")
try! fm.removeItem(atPath: tokPlain)
try! fm.createDirectory(atPath: tokHome + "/codex-a/archived_sessions", withIntermediateDirectories: true)
try! tokZst.write(to: URL(fileURLWithPath: tokHome + "/codex-a/archived_sessions/" + tokSession + ".jsonl.zst"))
tokens = TokenLedger.read([tokClaude, tokCodex], toolHome: tokHome)
expect(tokSum(tokens, isS) == TokenCounts(input: 50, cacheRead: 70, output: 4, reasoning: 2)
       && tokSum(tokens) { isS($0) && $0.start == tokHour(tokB) } == TokenCounts(input: 10, cacheRead: 10, output: 1, reasoning: 1),
       "the archived .zst copy of a session adds only what came after: \(tokens.entries.filter(isS))")
try! tokZst.write(to: URL(fileURLWithPath: tokHome + "/codex-a/archived_sessions/copy-" + tokSession + ".jsonl.zst"))
tokens = TokenLedger.read([tokClaude, tokCodex], toolHome: tokHome)
expect(tokSum(tokens, isS).total == 124 && tokens.folders.first { $0.accountID == "tok-codex" }?.compressed == 2, "a copy of a session adds nothing")
try! Data("not zstd".utf8).write(to: URL(fileURLWithPath: tokHome + "/codex-a/archived_sessions/rollout-broken.jsonl.zst"))
tokens = TokenLedger.read([tokClaude, tokCodex], toolHome: tokHome)
expect(tokens.folders.first { $0.accountID == "tok-codex" }?.failed == 1 && tokSum(tokens, isS).total == 124, "a broken .zst is counted as unreadable, nothing else changes")
// Gemini (agy) steps: its one folder has no account in it; outside the app split by the program that wrote the logs.
let tokGemini = Account(id: "tok-gemini", provider: .gemini, name: "G")
tokWrite(tokHome + "/.gemini/antigravity-cli/brain/b1/.system_generated/logs/transcript.jsonl", [
    #"{"step_index":0,"type":"USER_INPUT","created_at":"\#(tokA)","content":"output_tokens"}"#,
    #"{"step_index":1,"type":"PLANNER_RESPONSE","created_at":"\#(tokA)","model":"gemini-test","input_tokens":300,"cache_read_tokens":0,"output_tokens":20}"#,
    #"{"step_index":3,"type":"PLANNER_RESPONSE","created_at":"\#(tokA)","input_tokens":40,"cache_read_tokens":300,"output_tokens":6}"#])
tokWrite(tokHome + "/.codex/sessions/2026/03/10/d.jsonl", [
    #"{"timestamp":"\#(tokA)","type":"session_meta","payload":{"originator":"Codex Desktop"}}"#, tokCodexLine(tokA, input: 10, cached: 0, out: 1)])
tokWrite(tokHome + "/.codex/sessions/2026/03/10/t.jsonl", [
    #"{"timestamp":"\#(tokA)","type":"session_meta","payload":{"originator":"codex_cli_rs"}}"#, tokCodexLine(tokA, input: 20, cached: 0, out: 2)])
tokens = TokenLedger.read([tokClaude, tokCodex, tokGemini], toolHome: tokHome)
let tokG = tokens.entries.filter { $0.provider == .gemini }
expect(tokG.reduce(TokenCounts()) { $0 + $1.counts } == TokenCounts(input: 340, cacheRead: 300, output: 26) && tokG.allSatisfy { $0.accountID == nil && $0.session == "b1" },
       "Gemini's model steps are counted with no account (its log has none): \(tokG)")
let tokOut = tokens.entries.filter { $0.accountID == nil && $0.provider == .codex }
expect(tokOut.first { $0.origin == .desktop }?.counts.output == 1 && tokOut.first { $0.origin == .terminal }?.counts.output == 2,
       "outside the app, the desktop app and Terminal are told apart: \(tokOut.map { ($0.origin, $0.counts) })")
// App calls that leave no log: the CLI's own usage, what the call was for; the same call written twice counts once.
let tokResult = #"{"type":"result","session_id":"call-1","is_error":false,"result":"ok","usage":{"input_tokens":5,"cache_creation_input_tokens":7,"cache_read_input_tokens":11,"output_tokens":13},"modelUsage":{"claude-haiku":{}}}"#
TokenLedger.recordApp(tokClaude, output: tokResult, model: nil, kind: "routing", folder: home + "/.ai-illuminati/chat")
TokenLedger.recordApp(tokClaude, output: tokResult, model: nil, kind: "routing", folder: home + "/.ai-illuminati/chat")
TokenLedger.recordApp(tokCodex, output: #"{"type":"thread.started","thread_id":"t-1"}"# + "\n" + #"{"type":"turn.completed","usage":{"input_tokens":30,"cached_input_tokens":10,"output_tokens":4,"reasoning_output_tokens":2}}"#,
                      model: "gpt-test", kind: "meeting", folder: nil)
TokenLedger.recordApp(tokCodex, output: "plain text, no usage", model: nil, kind: "chat", folder: nil)
tokens = TokenLedger.read([tokClaude, tokCodex, tokGemini], toolHome: tokHome)
let tokApp = tokens.entries.filter { $0.source == .app }
expect(tokApp.count == 2 && tokApp.first { $0.kind == "routing" }?.counts == TokenCounts(input: 5, cacheWrite: 7, cacheRead: 11, output: 13)
       && tokApp.first { $0.kind == "routing" }?.model == "claude-haiku" && tokApp.first { $0.kind == "routing" }?.accountID == "tok-claude"
       && tokApp.first { $0.kind == "meeting" }?.counts == TokenCounts(input: 20, cacheRead: 10, output: 4, reasoning: 2),
       "app calls without a log are counted once, with what they were for: \(tokApp)")
// The older format (version 2, daily sums): read again, but its deleted logs stay as day sums (nothing else known), and
// a Codex session among them that is now in the archive adds only what came after its last total.
let tokHome2 = home + "/tokens2"
let tokCodex2 = Account(id: "tok-codex2", provider: .codex, name: "X2", dir: tokHome2 + "/codex-b")
let tokCache = AccountStore.supportDir + "/token-usage.json"
let tokOld: [String: Any] = ["version": 2, "files": [
    tokHome2 + "/codex-b/sessions/2026/03/10/" + tokSession + ".jsonl": ["size": 10, "offset": 10, "gone": true, "last": [100, 60, 0, 3],
        "days": ["2026-03-10": ["input": 40, "cacheWrite": 0, "cacheRead": 60, "output": 3]]],
    tokHome2 + "/codex-b/sessions/2026/01/05/rollout-old.jsonl": ["size": 10, "offset": 10, "gone": true,
        "days": ["2026-01-05": ["input": 1, "cacheWrite": 0, "cacheRead": 0, "output": 50]]],
    tokHome2 + "/codex-b/sessions/2026/03/10/live.jsonl": ["size": 1, "offset": 1, "days": ["2026-03-10": ["input": 999, "cacheWrite": 0, "cacheRead": 0, "output": 999]]]]]
try! JSONSerialization.data(withJSONObject: tokOld).write(to: URL(fileURLWithPath: tokCache))
tokWrite(tokHome2 + "/codex-b/sessions/2026/03/10/live.jsonl", [tokCodexLine(tokA, input: 10, cached: 0, out: 1)])
try! fm.createDirectory(atPath: tokHome2 + "/codex-b/archived_sessions", withIntermediateDirectories: true)
try! tokZst.write(to: URL(fileURLWithPath: tokHome2 + "/codex-b/archived_sessions/" + tokSession + ".jsonl.zst"))
tokens = TokenLedger.read([tokCodex2], toolHome: tokHome2)
let tokLegacy = tokens.entries.filter { $0.source == .legacy }
expect(tokLegacy.count == 2 && tokLegacy.allSatisfy { !$0.hourly && $0.model == nil } && tokLegacy.reduce(0) { $0 + $1.counts.output } == 53,
       "the older format's deleted logs stay as day sums: \(tokLegacy)")
expect(tokSum(tokens, isS) == TokenCounts(input: 10, cacheRead: 10, output: 1, reasoning: 1) && tokSum(tokens) { $0.source == .log && !isS($0) }.output == 1
       && tokens.folders[0].legacy == 2, "an archived copy of an old-format session adds only what came after; a live log is read again, once: \(tokens.entries)")
// Folders: a Git worktree goes with its repository.
try! fm.createDirectory(atPath: home + "/repo/.git/worktrees/wt", withIntermediateDirectories: true)
try! fm.createDirectory(atPath: home + "/wt/sub", withIntermediateDirectories: true)
try! "gitdir: \(home)/repo/.git/worktrees/wt\n".write(toFile: home + "/wt/.git", atomically: true, encoding: .utf8)
expect(TokenLedger.projectRoot(home + "/wt/sub") == home + "/repo" && TokenLedger.projectRoot(home + "/repo") == home + "/repo"
       && TokenLedger.projectRoot("/no/such/folder") == "/no/such/folder", "a worktree's project is its repository")
// Every Mac together: a session found on two Macs (its log copied) counts once; sums without a session never merge.
func tokEntry(_ session: String?, _ out: Int, source: TokenEntry.Source = .log) -> TokenEntry {
    TokenEntry(provider: .claude, accountID: nil, accountName: "C", folder: "", origin: nil, source: source, start: tokHour(tokA), hourly: true,
               model: nil, session: session, project: nil, kind: nil, counts: TokenCounts(output: out))
}
let tokPeer = TokenDevice(id: "mac-b", name: "Mac mini", writtenAt: Date(), revision: 1, entries: [tokEntry("s1", 5), tokEntry("s2", 7), tokEntry(nil, 3), tokEntry(nil, 4, source: .app)])
let tokAll = TokenLedger.together([tokEntry("s1", 5), tokEntry(nil, 3)], [tokPeer])
let tokAllOut: Int = tokAll.reduce(0) { $0 + $1.counts.output }
let tokS1: [String] = tokAll.filter { $0.session == "s1" }.map(\.device)
expect(tokAllOut == 22 && tokS1 == [""], "a session on two Macs counts once (this Mac's); sums without a session add up: \(tokAllOut) \(tokS1)")
// Other Macs (TokenSync): each writes only its own file, whole; syncing again changes nothing; a correction replaces
// the old numbers; a half-written file keeps the last whole copy; an older app's file is read as day sums; a removed one leaves.
let tokSync = URL(fileURLWithPath: home + "/sync-root/AI Illuminati Sync")
try! fm.createDirectory(at: tokSync.deletingLastPathComponent(), withIntermediateDirectories: true)
expect(TokenSync.exchange([tokEntry("s9", 9)], folder: tokSync, deviceID: "mac-b", deviceName: "Mac mini").isEmpty, "no other Mac yet")
var tokPeers = TokenSync.exchange([tokEntry("s1", 2)], folder: tokSync, deviceID: "mac-a", deviceName: "MacBook")
expect(tokPeers.count == 1 && tokPeers[0].name == "Mac mini" && tokPeers[0].entries.map(\.counts.output) == [9] && tokPeers[0].entries[0].accountName == "C"
       && tokPeers[0].entries[0].session == "s9" && tokPeers[0].revision == 1, "another Mac's ledger comes back whole, with account names: \(tokPeers)")
_ = TokenSync.exchange([tokEntry("s9", 9)], folder: tokSync, deviceID: "mac-b", deviceName: "Mac mini")
tokPeers = TokenSync.exchange([tokEntry("s1", 2)], folder: tokSync, deviceID: "mac-a", deviceName: "MacBook")
expect(tokPeers[0].revision == 1 && tokPeers[0].entries.map(\.counts.output) == [9], "syncing again changes nothing")
_ = TokenSync.exchange([tokEntry("s9", 6)], folder: tokSync, deviceID: "mac-b", deviceName: "Mac mini")
tokPeers = TokenSync.exchange([], folder: tokSync, deviceID: "mac-a", deviceName: "MacBook")
expect(tokPeers[0].revision == 2 && tokPeers[0].entries.map(\.counts.output) == [6], "a correction (fewer tokens) replaces the old copy: \(tokPeers)")
try! "{\"version\":2,\"id\":\"mac-b\",\"na".write(to: tokSync.appendingPathComponent("token-usage/mac-b.json"), atomically: true, encoding: .utf8)
tokPeers = TokenSync.exchange([], folder: tokSync, deviceID: "mac-a", deviceName: "MacBook")
expect(tokPeers.first?.entries.map(\.counts.output) == [6], "a half-synced file keeps the last whole copy")
try! #"{"version":1,"id":"mac-c","name":"Old Mac","writtenAt":"2026-03-12T00:00:00Z","shares":[{"provider":"codex","name":"X","outside":false,"days":{"2026-03-10":{"input":1,"cacheWrite":0,"cacheRead":0,"output":2}}}]}"#
    .write(to: tokSync.appendingPathComponent("token-usage/mac-c.json"), atomically: true, encoding: .utf8)
tokPeers = TokenSync.exchange([], folder: tokSync, deviceID: "mac-a", deviceName: "MacBook")
let tokOldMac = tokPeers.first { $0.id == "mac-c" }
expect(tokOldMac?.entries.count == 1 && tokOldMac?.entries[0].source == .legacy && tokOldMac?.entries[0].accountName == "X" && tokOldMac?.entries[0].hourly == false,
       "an older app's daily sums are read as day sums: \(String(describing: tokOldMac))")
TokenSync.removeMine(folder: tokSync, deviceID: "mac-b")
TokenSync.removeMine(folder: tokSync, deviceID: "mac-c")
tokPeers = TokenSync.exchange([], folder: tokSync, deviceID: "mac-a", deviceName: "MacBook")
expect(tokPeers.isEmpty && TokenSync.cached().isEmpty, "a Mac that removed its copy leaves")
expect(TokenSync.exchange([tokEntry("s1", 1)], folder: URL(fileURLWithPath: home + "/no-icloud/AI Illuminati Sync"), deviceID: "mac-a", deviceName: "MacBook").isEmpty
       && !fm.fileExists(atPath: home + "/no-icloud"), "no folder is made when iCloud Drive is off")
print("PASS: Runtime promises (errors, Stop, time out, process group, stream order, background thread, sessions saved, resumed and read from older files, steering, token logs by hour/model/session, Claude usage updates, Codex .zst and archive once, deleted and older-format logs, Gemini, app calls, other Macs' ledgers)")
