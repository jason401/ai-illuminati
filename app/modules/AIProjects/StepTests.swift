import Foundation
import AIAccounts
import AILocalization
import AIRuntime
import AIWorkspace

// A Step's picked tests (TODO structure 05; off until 16): when the Step's AI is done, the app itself runs
// `AI_ILLUMINATI_TEST_ONLY=<the Step's tests> zsh tools/tests/run_mode2.sh` in the Goal's work tree, the project_run way
// (one run per repository, its "[n/m]" lines and project-timings), and keeps the result on the TODO. Like the plain
// test and the Milestone's full test it runs as the user, not in the Step sandbox: run_mode2's loopback servers, process
// groups, compile cache and Foundation's temp folders all fail inside sandbox-exec. The AI's own project_run stays there.
// Not `--affected`: tools/test_map.txt maps the chat and other wide folders to every test. Only `passed` lets a Step end:
// no tests, a name no runTest in tools/tests/mode2.swift has, uncommitted work, a failure, Stop or a time out do not.
public struct StepTestResult: Codable, Equatable {
    public enum Outcome: String, Codable { case passed, failed, refused, stopped, timeout, error }
    public var outcome: Outcome
    public var tests: [String]
    public var sha: String?             // the Goal branch's HEAD the tests ran on (committed: the tree was clean)
    public var buildSeconds: Double?    // the shared part before the tests: module guards, modules, fixtures, compiling
    public var testSeconds: Double?     // running the picked tests ("Run app tests")
    public var seconds: Double?         // the whole command
    public var exit: Int?
    public var reason: String?          // why it did not pass
    public var at: Date
    public var passed: Bool { outcome == .passed }
    init(outcome: Outcome, tests: [String], reason: String? = nil, at: Date = Date()) {
        self.outcome = outcome; self.tests = tests; self.reason = reason; self.at = at
    }
}

public enum StepTests {
    static let script = "tools/tests/run_mode2.sh", catalog = "tools/tests/mode2.swift"
    // The app's own command, not one of .ai-illuminati.json: nothing is added there, and the space keeps its
    // project-timings key apart from any registered name the AI may choose.
    static let timingKey = "step tests"
    static func command(_ tests: [String]) -> (executable: String, args: [String]) {
        ("/usr/bin/env", ["AI_ILLUMINATI_TEST_ONLY=" + tests.joined(separator: ","), "/bin/zsh", script])
    }
    // The runTest names of the tree's own mode2.swift (a Step may add one): `runTest("name", …)` at a line's start.
    static func known(root: String) -> Set<String>? {
        guard let text = try? String(contentsOfFile: root + "/" + catalog, encoding: .utf8),
              let pattern = try? NSRegularExpression(pattern: #"^runTest\("([A-Za-z0-9_]+)""#, options: .anchorsMatchLines) else { return nil }
        let ns = text as NSString
        return Set(pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
    }
    // Why these tests cannot make a Step pass, before anything is built; nil: they can run.
    static func refusal(_ tests: [String], root: String) -> String? {
        guard !tests.isEmpty else { return L("고른 테스트가 없어요. 빈 목록으로는 Step이 끝나지 않아요.", "No tests picked: an empty list never ends a Step.") }
        if let bad = tests.first(where: { $0.isEmpty || !$0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } }) {
            return L("테스트 이름이 올바르지 않아요: \(bad)", "Not a test name: \(bad)")
        }
        guard FileManager.default.fileExists(atPath: root + "/" + script), let known = known(root: root) else {
            return L("\(script)나 \(catalog)가 없어요.", "\(script) or \(catalog) is missing.")
        }
        let unknown = tests.filter { !known.contains($0) }
        return unknown.isEmpty ? nil : L("\(catalog)에 없는 테스트예요: ", "No such runTest in \(catalog): ") + unknown.joined(separator: ", ")
    }
    // Runs them on a fresh attempt (the AI's are over); a run that moved the Goal branch's HEAD does not pass.
    public static func run(_ tests: [String], in run: ProjectRun) -> StepTestResult {
        guard run.isStep else { return StepTestResult(outcome: .refused, tests: tests, reason: "Not a Step.") }
        let root = run.binding.root
        if let why = refusal(tests, root: root) { return StepTestResult(outcome: .refused, tests: tests, reason: why) }
        run.nextAttempt()
        defer { run.endAttempt() }
        run.operations.lock(); defer { run.operations.unlock() }
        let generation = run.generation
        var result = StepTestResult(outcome: .error, tests: tests)
        do {
            try run.validate(generation)
            // What the Milestone gets is commits: tests of uncommitted work would pass something it never sees.
            let dirty = try ProjectProcess.git(["status", "--porcelain"], root: root, token: run.attempt)
            guard dirty.isEmpty else {
                result.outcome = .refused
                result.reason = L("커밋하지 않은 변경이 있어요. Goal 브랜치에 커밋한 뒤 테스트해요: ", "Uncommitted changes; the tests run on the Goal branch's commits: ") + String(dirty.prefix(300))
                return result
            }
            result.sha = try ProjectProcess.git(["rev-parse", "HEAD"], root: root, token: run.attempt)
        } catch { result.reason = error.localizedDescription; return result }
        let (exe, argv) = command(tests)
        run.note(L("Step 테스트: ", "Step tests: ") + tests.joined(separator: ", "))
        let progress = RunProgress(command: timingKey) { text in if !run.setSub(text) { run.note(text) } }
        defer { run.setSub(nil) }
        let clock = StepClock()
        let deadline = min(run.deadline, Date().addingTimeInterval(2700))
        do {
            let reply = try ProjectWork.oneRun(root, until: deadline, token: run.attempt,
                                               waiting: { run.note(L("Step 테스트: 이 저장소의 다른 명령이 끝나길 기다리는 중", "Step tests: waiting for another command in this repository")) }) { () -> ProjectProcess.Reply in
                try run.validate(generation)
                clock.begin()
                return try ProjectProcess.run(exe, argv, cwd: root, token: run.attempt, deadline: deadline, guarded: true,
                                              onLine: { progress.line($0); clock.line($0) })
            }
            RunTimings.record(root: root, command: timingKey, progress.finish(reply.status == 0 ? "ok" : "failed", exit: reply.status))
            clock.fill(&result)
            result.exit = Int(reply.status)
            let missed = tests.filter { !clock.ran.contains($0) }
            let after = try? ProjectProcess.git(["rev-parse", "HEAD"], root: root)
            if reply.status == 0, clock.passed, missed.isEmpty, after == result.sha { result.outcome = .passed; return result }
            result.outcome = .failed
            if reply.status == 0, after != result.sha {
                result.reason = L("테스트 중에 Goal 브랜치의 HEAD가 바뀌었어요.", "The Goal branch's HEAD moved during the tests."); return result
            }
            let fails = reply.output.split(separator: "\n").filter { $0.contains("FAIL") || $0.contains("Fatal error") }.suffix(5).joined(separator: "\n")
            result.reason = reply.status != 0 ? "exit=\(reply.status)" + (fails.isEmpty ? "\n" + String(reply.output.suffix(800)) : "\n" + fails)
                : L("고른 테스트가 다 돌지 않았어요: ", "Not every picked test ran: ") + (missed.isEmpty ? "no PASS line" : missed.joined(separator: ", "))
        } catch {
            let timedOut = Date() >= deadline || run.activeExpired, stopped = run.outer.isCancelled || run.attempt.isCancelled
            RunTimings.record(root: root, command: timingKey, progress.finish(RunProgress.outcome(timedOut: timedOut, stopped: stopped), exit: nil))
            clock.fill(&result)
            result.outcome = timedOut ? .timeout : stopped ? .stopped : .error
            result.reason = error.localizedDescription
        }
        return result
    }
    // What the TODO's chat says when a Step did not pass (its turn ends with it as the error, so the TODO retries).
    public static func failure(_ result: StepTestResult) -> String {
        L("Step 테스트를 통과하지 못했어요 (\(result.outcome.rawValue)): ", "The Step's tests did not pass (\(result.outcome.rawValue)): ")
            + result.tests.joined(separator: ", ") + (result.reason.map { "\n" + String($0.prefix(1200)) } ?? "")
    }
}

// run_mode2.sh's own lines split its time: from the start to "[n/m] Run app tests" is the shared build, from there to its
// "  [n] Run app tests: x s" (or the end) the picked tests. "▶ name" and "PASS: selected tests only" say what ran.
final class StepClock {
    private let lock = NSLock()
    private var start: Date?, testStart: Date?, testEnd: Date?
    private(set) var ran: Set<String> = [], passed = false
    static let testStage = "Run app tests"
    func begin(at now: Date = Date()) { lock.lock(); start = now; lock.unlock() }
    func line(_ line: String, at now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        if let (_, _, name) = RunProgress.stage(line), name == Self.testStage { testStart = testStart ?? now }
        else if testStart != nil, testEnd == nil, line.range(of: #"^\[[0-9]+\] Run app tests: "#, options: .regularExpression) != nil { testEnd = now }
        else if line.hasPrefix("▶ ") { ran.insert(String(line.dropFirst(2))) }
        else if line.hasPrefix("PASS: selected tests only") { passed = true }
    }
    func fill(_ result: inout StepTestResult, at now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard let start else { return }
        func tenths(_ s: TimeInterval) -> Double { (max(0, s) * 10).rounded() / 10 }
        result.seconds = tenths(now.timeIntervalSince(start))
        if let testStart {
            result.buildSeconds = tenths(testStart.timeIntervalSince(start))
            result.testSeconds = tenths((testEnd ?? now).timeIntervalSince(testStart))
        } else { result.buildSeconds = result.seconds }
    }
}
