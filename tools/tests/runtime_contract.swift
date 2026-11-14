import Foundation
import Darwin
import AIAccounts
#if canImport(AIRuntime)
import AIRuntime
#endif

// The promises of the Runtime (AIRuntime), checked from outside with only its public API and a fake command line
// tool (a shell script started as the AI's tool): errors, Stop, time out, the process group, stream events in
// order, sessions saved and resumed. Run with AI_ILLUMINATI_TEST_HOME set to an empty folder (run_mode2.sh).
// No real CLI, home, Keychain or account folder is used; Gemini is left out (it would touch agy's real settings).
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
  stream) cat "$FAKE_DIR/stream.jsonl" ;;
  codex) cat "$FAKE_DIR/stream.jsonl"; printf 'codex answer' > "$out" ;;
  session) [ "$sid" = "" ] && sid="$FAKE_SID"
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
        }
    }).get()
    expect(!main, "progress comes on a background thread")
    return (seen, answer)
}
clear()
let (claudeEvents, claudeAnswer) = events(claude, [
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
expect(codexEvents.count == 4 && codexEvents[0].hasPrefix("activity:") && codexEvents[1] == "text:first"
       && codexEvents[2].hasPrefix("activity:") && codexEvents[3] == "text:second", "Codex stream events in order: \(codexEvents)")

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
print("PASS: Runtime promises (errors, Stop, time out, process group, stream order, background thread, sessions saved, resumed and read from older files, steering)")
