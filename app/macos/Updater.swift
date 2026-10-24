import Foundation

// Automatic updates, the same way as AI Face: the app checks the public GitHub repository (the
// project's `origin`, no login needed) one minute after it starts and every 3 hours.
// Safe order: fetch -> fast-forward -> tests -> build and sign the new app next to the running one
// (`tools/build_app.sh --stage`). Only when all of that passes is the app swapped and restarted
// (`--install-staged`, started detached because it quits this app). Anything failing puts the folder
// back where it was and the running app stays. Skipped when this Mac has its own changes or commits,
// and postponed while a chat is answering.
final class Updater: ObservableObject {
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "autoUpdate") }
    }
    @Published private(set) var checking = false
    @Published private(set) var status = ""
    var isBusy: () -> Bool = { false }

    static let every: TimeInterval = 3 * 3600, retry: TimeInterval = 600, first: TimeInterval = 60
    let root = Bundle.main.bundleURL.deletingLastPathComponent()
    private let work = DispatchQueue(label: "updater")
    private var timer: Timer?
    private var stateFile: URL { URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("update.json") }

    init() {
        enabled = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true
        status = Self.describe(loadState())
    }

    func start() {
        schedule(after: Self.first)
        timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { [weak self] _ in
            guard let self, self.enabled else { return }
            self.check(manual: false)
        }
    }

    private func schedule(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.enabled else { return }
            self.check(manual: false)
        }
    }

    func check(manual: Bool) {
        guard !checking else { return }
        if !manual && isBusy() {
            report(["status": "postponed"])
            schedule(after: Self.retry)
            return
        }
        checking = true
        report(["status": "checking"], save: false)
        work.async { self.run(manual: manual) }
    }

    // MARK: Steps

    private func run(manual: Bool) {
        defer { DispatchQueue.main.async { self.checking = false } }
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path),
              (try? git("remote", "get-url", "origin"))?.contains("ai-illuminati") == true else {
            return report(["status": "unavailable"])
        }
        // This Mac's own edits are never overwritten.
        if let changes = try? git("status", "--porcelain", "--untracked-files=no"), !changes.isEmpty {
            return report(["status": "local-changes"])
        }
        do { try git("fetch", "-q", "origin", "main", timeout: 90) } catch {
            return report(["status": "failed", "detail": L("GitHub에 연결하지 못했어요", "Could not reach GitHub")])
        }
        guard let old = try? git("rev-parse", "HEAD"), let new = try? git("rev-parse", "origin/main") else {
            return report(["status": "failed", "detail": "git"])
        }
        if old == new { return report(["status": "current", "current": old]) }
        guard (try? git("merge-base", "--is-ancestor", "HEAD", "origin/main")) != nil else {
            return report(["status": "local-commits"])
        }
        report(["status": "testing", "current": old, "next": new], save: false)
        do {
            try git("merge", "--ff-only", "-q", "origin/main")
            try shell(["zsh", "tools/tests/run_mode2.sh"], timeout: 30 * 60, step: L("시험", "tests"))
            report(["status": "building", "current": old, "next": new], save: false)
            try shell(["zsh", "tools/build_app.sh", "--stage"], timeout: 20 * 60, step: L("빌드", "build"))
        } catch {
            _ = try? git("reset", "-q", "--hard", old)
            try? FileManager.default.removeItem(at: root.appendingPathComponent("AI Illuminati.update.app"))
            return report(["status": "failed", "current": old, "detail": "\(error)"])
        }
        // Do not restart in the middle of an answer: wait (up to 6 hours) for the chat to finish.
        let deadline = Date().addingTimeInterval(6 * 3600)
        while DispatchQueue.main.sync(execute: { isBusy() }) && Date() < deadline {
            report(["status": "waiting", "current": old, "next": new], save: false)
            Thread.sleep(forTimeInterval: 60)
        }
        report(["status": "updated", "previous": old, "current": new])
        let install = Process()
        install.executableURL = URL(fileURLWithPath: "/bin/zsh")
        install.arguments = ["-c", "nohup zsh tools/build_app.sh --install-staged >/dev/null 2>&1 &"]
        install.currentDirectoryURL = root
        install.environment = cleanEnvironment()
        try? install.run()
        install.waitUntilExit()
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    @discardableResult
    private func git(_ arguments: String..., timeout: TimeInterval = 60) throws -> String {
        try execute(["/usr/bin/git", "-C", root.path] + arguments, timeout: timeout, step: "git " + (arguments.first ?? ""))
    }

    private func shell(_ arguments: [String], timeout: TimeInterval, step: String) throws {
        _ = try execute(["/usr/bin/env"] + arguments, timeout: timeout, step: step)
    }

    private func cleanEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["PWD", "OLDPWD", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY"] { env.removeValue(forKey: key) }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }

    private func execute(_ command: [String], timeout: TimeInterval, step: String) throws -> String {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = root
        process.environment = cleanEnvironment()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = FileHandle.nullDevice
        try process.run()
        var data = Data()
        let reader = DispatchQueue(label: "updater-read"), done = DispatchSemaphore(value: 0)
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw Failure(description: L("\(step) 시간 초과", "\(step) timed out"))
        }
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw Failure(description: L("\(step) 실패", "\(step) failed") + (text.isEmpty ? "" : ": " + String(text.suffix(160))))
        }
        return text
    }

    // MARK: State

    private func loadState() -> [String: String] {
        guard let data = try? Data(contentsOf: stateFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return json
    }

    private func report(_ state: [String: String], save: Bool = true) {
        var state = state
        state["at"] = ISO8601DateFormatter().string(from: Date())
        if save {
            try? FileManager.default.createDirectory(atPath: AccountStore.supportDir, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: stateFile, options: .atomic)
            }
        }
        let text = Self.describe(state)
        DispatchQueue.main.async { self.status = text }
    }

    static func describe(_ s: [String: String]) -> String {
        func short(_ rev: String?) -> String { String((rev ?? "").prefix(7)) }
        let when: String = {
            guard let at = s["at"].flatMap({ ISO8601DateFormatter().date(from: $0) }) else { return "" }
            let f = DateFormatter()
            f.locale = Locale(identifier: AppLanguage.current == .korean ? "ko_KR" : "en_US")
            f.dateFormat = Calendar.current.isDateInToday(at) ? "a h:mm" : "M/d a h:mm"
            return " · " + f.string(from: at)
        }()
        switch s["status"] ?? "" {
        case "checking": return L("새 버전 확인 중…", "Checking for a new version…")
        case "testing": return L("새 버전(\(short(s["next"]))) 시험 중…", "Testing new version \(short(s["next"]))…")
        case "building": return L("새 버전(\(short(s["next"]))) 준비 중…", "Preparing new version \(short(s["next"]))…")
        case "waiting": return L("새 버전 준비 완료. 채팅이 끝나면 다시 시작해요", "New version ready. Restarting after the chat finishes")
        case "current": return L("최신 버전이에요 (\(short(s["current"])))", "Up to date (\(short(s["current"])))") + when
        case "updated": return L("업데이트됨: \(short(s["previous"])) → \(short(s["current"]))", "Updated: \(short(s["previous"])) → \(short(s["current"]))") + when
        case "postponed": return L("채팅 중이라 10분 뒤 다시 확인해요", "Busy with a chat; checking again in 10 minutes") + when
        case "local-changes": return L("이 맥에서 고친 코드가 있어 건너뛰었어요", "Skipped: this Mac has its own code changes") + when
        case "local-commits": return L("이 맥에만 있는 커밋이 있어 건너뛰었어요", "Skipped: this Mac has commits not on GitHub") + when
        case "unavailable": return L("프로젝트 폴더(git)가 아니라 자동 업데이트를 쓸 수 없어요", "Not in the project folder (git), so updates are unavailable")
        case "failed": return L("업데이트 실패, 지금 버전을 그대로 써요: ", "Update failed; keeping this version: ") + (s["detail"] ?? "") + when
        default: return ""
        }
    }
}
