import Foundation
import Darwin
import AIAccounts
import AIRuntime
import AIWorkspace
@testable import AIChat

// The Runtime's promises through the app's own way in: `Discussion.requestDebate` builds `RunConditions.app` and the
// folder rules, and a fake command line tool (Answerer.toolForTests) is started as the AI's own. runtime_contract.swift
// checks the same promises with hand-made conditions; the app's other tests skip the process (launchForTests,
// replyForTests, fake sessions), so without this file six of them were caught only by the module's own test:
// Stop (F1), the process group at the end (F2), the time limit (F3), a stopped session (F6), a program that left the
// tool's group (F7) and the tool's error message (F8). Gemini is left out (it would touch agy's real settings).
func testRuntimeThroughApp() {
    let fm = FileManager.default
    let fake = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("runtime-app")
    try? fm.removeItem(at: fake)
    try! fm.createDirectory(at: fake, withIntermediateDirectories: true)
    let script = fake.appendingPathComponent("cli")
    // The app makes the tool's environment, so the fake reads what to do from the file "mode" next to it.
    try! (#"""
    #!/bin/sh
    D='\#(fake.path)'
    printf '%s\n' "$@" > "$D/args"
    cat > "$D/stdin"
    sid=""; prev=""; for a in "$@"; do
      { [ "$prev" = "--session-id" ] || [ "$prev" = "--resume" ]; } && sid="$a"
      prev="$a"
    done
    case "$(cat "$D/mode")" in
      sleep) echo $$ > "$D/pid"; sh -c 'echo $$ > "$1/child"; exec sleep 20' sh "$D" &
             /usr/bin/perl -e 'setpgrp(0, 0); exec @ARGV' sh -c 'echo $$ > "$1/stray"; exec sleep 20' sh "$D" &
             wait ;;
      group) # project_process.py's own watchdog (this tool's child) goes first, so only the app's group stop is left.
             /usr/bin/pgrep -P $$ > "$D/watchdog"; for p in $(cat "$D/watchdog"); do kill -9 "$p"; done
             sh -c 'echo $$ > "$1/child"; exec sleep 20' sh "$D" </dev/null >/dev/null 2>&1 &
             # A new program can take seconds to start on a busy Mac: answering before the child wrote its pid let
             # the app stop it unseen, and the check failed with nothing wrong (RC 133 in the full test).
             n=0; while [ ! -s "$D/child" ] && [ $n -lt 1000 ]; do sleep 0.01; n=$((n+1)); done
             echo 'left one' ;;
      fail) echo "boom from the tool" >&2; exit 3 ;;
      session) printf '{"type":"result","session_id":"%s","is_error":false,"result":"session answer"}\n' "$sid" ;;
      slow) echo $$ > "$D/pid"; exec sleep 20 ;;
    esac
    """#).write(to: script, atomically: true, encoding: .utf8)
    try! fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    // Inside project work the marker is inherited, and with it Stop ends the group first (runtime_contract checks
    // that apart): taken off here, so each layer is the one under test.
    let marker = ProcessInfo.processInfo.environment["AI_ILLUMINATI_PROJECT_PROCESS"]
    unsetenv("AI_ILLUMINATI_PROJECT_PROCESS")
    Answerer.toolForTests = script.path
    defer {
        Answerer.toolForTests = nil
        if let marker { setenv("AI_ILLUMINATI_PROJECT_PROCESS", marker, 1) }
    }

    func mode(_ name: String) {
        for file in ["args", "stdin", "pid", "child", "stray", "watchdog"] { try? fm.removeItem(at: fake.appendingPathComponent(file)) }
        try! name.write(to: fake.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
    }
    func read(_ name: String) -> String { (try? String(contentsOf: fake.appendingPathComponent(name), encoding: .utf8)) ?? "" }
    func pid(_ name: String) -> pid_t? { pid_t(read(name).trimmingCharacters(in: .whitespacesAndNewlines)) }
    func gone(_ name: String, within seconds: Double = 3) -> Bool {
        guard let pid = pid(name) else { return false }   // never started: nothing was checked
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if kill(pid, 0) != 0 { return true }; Thread.sleep(forTimeInterval: 0.05) }
        return false
    }
    // Stop once the fake tool has written these pid files (at most 10 s): a Stop before that would check nothing.
    // Returns when Stop was pressed, so "at once" is measured from there.
    func stop(_ token: DebateCancellation, after names: [String]) -> () -> Date {
        let lock = NSLock(); var at = Date.distantFuture
        DispatchQueue.global().async {
            let end = Date().addingTimeInterval(10)
            while Date() < end && names.contains(where: { pid($0) == nil }) { Thread.sleep(forTimeInterval: 0.05) }
            lock.lock(); at = Date(); lock.unlock()
            token.cancel()
        }
        return { lock.lock(); defer { lock.unlock() }; return at }
    }
    func leftovers() { for name in ["pid", "child", "stray"] { if let pid = pid(name) { kill(pid, SIGKILL) } } }
    func failure(_ result: Result<String, Answerer.Failure>) -> Answerer.Failure? { if case .failure(let f) = result { return f }; return nil }

    let root = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("runtime-app-root")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    let claude = Account(id: "runtime-app-claude", provider: .claude, name: "Claude", dir: AccountStore.accountsDir + "/runtime-app-claude")
    let codex = Account(id: "runtime-app-codex", provider: .codex, name: "ChatGPT", dir: AccountStore.accountsDir + "/runtime-app-codex")
    let model = AppModel()
    model.accounts = [claude, codex]
    model.sharedFolders = []
    let chat = Discussion(model: model)
    let folder = WorkspaceBinding(roots: [WorkspaceRoot(path: root.path, directory: true)])

    for account in [claude, codex] {
        let name = account.provider.rawValue
        // F1, F7: Stop while the tool runs ends the answer at once, the tool, what it started, and a program it
        // started in a group of its own.
        mode("sleep")
        let token = DebateCancellation()
        let pressed = stop(token, after: ["pid", "child", "stray"])
        expect(failure(chat.requestDebate(account, "Say hi.", 60, token, workspace: folder)) != nil, "\(name): Stop fails the answer (app)")
        expect(Date().timeIntervalSince(pressed()) < 4, "\(name): Stop ends the answer at once (app)")
        expect(gone("pid") && gone("child"), "\(name): Stop ends the tool and what it started (app)")
        expect(gone("stray"), "\(name): Stop ends a program the tool started in a group of its own (app)")
        leftovers()

        // F3: the time limit the app asks for is kept; the tool and its programs are ended. A late start (seen: 3 s
        // before the tool ran a line) can use up the limit before the programs exist, which checks nothing: again,
        // at most 3 times.
        for _ in 0..<3 {
            mode("sleep")
            let started = Date()
            if case .timedOut? = failure(chat.requestDebate(account, "Say hi.", 1.5, DebateCancellation(), workspace: folder)) {}
            else { expect(false, "\(name): a slow tool times out (app)") }
            expect(Date().timeIntervalSince(started) < 6, "\(name): the time limit is kept (app)")
            if !["pid", "child", "stray"].contains(where: { pid($0) == nil }) { break }
        }
        expect(gone("pid") && gone("child") && gone("stray"), "\(name): a timed-out tool and its programs are ended (app)")
        leftovers()

        // F8: the tool's own error message reaches the app.
        mode("fail")
        if case .failed(let why)? = failure(chat.requestDebate(account, "Say hi.", 30, DebateCancellation(), workspace: folder)) {
            expect(why.contains("boom from the tool"), "\(name): a failed tool's message reaches the app: \(why)")
        } else { expect(false, "\(name): a tool that exits with an error is a failure (app)") }

        // F2: project work (project_process.py's group); with its watchdog gone, the app's run still stops the
        // whole group when the answer ends. Two layers, each checked: the watchdog was there, the group is stopped.
        mode("group")
        var off = WorkspaceBinding(roots: folder.roots, level: .execute, projectRunID: UUID(), projectGeneration: 1); off.fullAuto = false
        let answer = try? chat.requestDebate(account, "Say hi.", 30, DebateCancellation(), workspace: off).get()
        expect(account.provider == .codex || answer == "left one", "\(name): project work answers (app): \(answer ?? "failure")")
        expect(read("watchdog").split(separator: "\n").count == 1, "\(name): project work runs under project_process.py's watchdog (app)")
        expect(gone("child", within: 2), "\(name): project work's process group is stopped when the answer ends (app)")
        leftovers()
    }

    // F6: a session answer that was stopped is not kept: the next message starts a new session, not a resume.
    let sessions = Discussion(model: model)
    sessions.activeSessionRoom = sessions.currentID   // a room the app does not know is locked (Enterprise)
    let prompt = "source\n[SOLO TURN]\nanswer"
    mode("session")
    let firstAnswer = sessions.requestDebate(claude, prompt, 30, DebateCancellation())
    expect((try? firstAnswer.get()) == "session answer", "a session answer (app): \(firstAnswer)")
    let first = read("args").split(separator: "\n").map(String.init)
    expect(first.contains("--session-id"), "the first message starts a session (app): \(first)")
    mode("session")
    _ = sessions.requestDebate(claude, prompt, 30, DebateCancellation())
    expect(read("args").split(separator: "\n").contains("--resume"), "the next message resumes it (app)")
    mode("slow")
    let stopped = DebateCancellation()
    _ = stop(stopped, after: ["pid"])
    expect(failure(sessions.requestDebate(claude, prompt, 60, stopped)) != nil && gone("pid"), "Stop ends a session answer (app)")
    mode("session")
    _ = sessions.requestDebate(claude, prompt, 30, DebateCancellation())
    let after = read("args").split(separator: "\n").map(String.init)
    expect(after.contains("--session-id") && !after.contains("--resume"), "after a stopped answer the next message starts a new session (app): \(after)")
    leftovers()
    print("PASS: Runtime through the app (Stop, a program in its own group, time limit, the tool's error, project work's group, a stopped session)")
}
