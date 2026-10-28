import Cocoa
import Darwin
import ServiceManagement

// stable is a deployment channel. Only the app-owned checkout is ever changed.
// Each Mac builds with its existing local identity; developer repositories are never touched.
final class Updater: ObservableObject {
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "autoUpdate") }
    }
    @Published private(set) var checking = false
    @Published private(set) var status = ""
    var isBusy: () -> Bool = { false }

    static let every: TimeInterval = 3 * 3600, retry: TimeInterval = 600, first: TimeInterval = 60
    static let repository = "https://github.com/jason401/ai-illuminati.git"
    static let channel = "stable"
    let root = URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("source")
    private var installing = false
    private var revision: String { Bundle.main.object(forInfoDictionaryKey: "AISourceRevision") as? String ?? "" }
    private var updates: URL { URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("updates") }
    private var target: URL {
        // The user may explicitly choose the per-user Applications folder.
        let personal = UserDefaults.standard.bool(forKey: "installInUserApplications")
        let base = personal ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications") : URL(fileURLWithPath: "/Applications")
        return base.appendingPathComponent("AI Illuminati.app")
    }
    private let work = DispatchQueue(label: "updater")
    private var timer: Timer?
    private var stateFile: URL { URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("update.json") }

    init() {
        enabled = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true
        status = Self.describe(loadState())
    }

    func start() {
        acknowledgeInstallation()
        schedule(after: Bundle.main.bundleURL.standardizedFileURL == target.standardizedFileURL ? Self.first : 2)
        timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { [weak self] _ in
            guard let self, self.enabled else { return }
            self.check(manual: false)
        }
    }

    private func schedule(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            let migrating = Bundle.main.bundleURL.standardizedFileURL != self.target.standardizedFileURL
            guard self.enabled || migrating else { return }
            self.check(manual: migrating)
        }
    }

    func check(manual: Bool) {
        guard !checking, !installing else { return }
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
        // A developer build is installed once before it checks for source updates.
        if Bundle.main.bundleURL.standardizedFileURL != target.standardizedFileURL {
            return handoff(staged: Bundle.main.bundleURL, next: revision)
        }
        do {
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            let lockPath = root.deletingLastPathComponent().appendingPathComponent("source.lock").path
            let lockFD = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard lockFD >= 0 else { throw Failure(description: "Cannot open update lock") }
            defer { close(lockFD) }
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { return report(["status": "postponed"]) }
            defer { flock(lockFD, LOCK_UN) }
            guard root.resolvingSymlinksInPath().path == root.path else {
                throw Failure(description: "Update source must not be a symbolic link")
            }
            if !FileManager.default.fileExists(atPath: root.path) {
                let temporary = root.deletingLastPathComponent().appendingPathComponent("source-clone-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temporary) }
                _ = try execute(["/usr/bin/git", "clone", "--branch", Self.channel, "--single-branch", Self.repository, temporary.path],
                            timeout: 180, step: "clone", directory: root.deletingLastPathComponent())
                try FileManager.default.moveItem(at: temporary, to: root)
            }
            guard try git("remote", "get-url", "origin") == Self.repository else {
                throw Failure(description: "Unexpected update repository")
            }
            guard try git("status", "--porcelain", "--untracked-files=normal").isEmpty else {
                return report(["status": "local-changes"])
            }
            try git("fetch", "-q", "origin", Self.channel, timeout: 90)
            let old = try git("rev-parse", "HEAD"), new = try git("rev-parse", "origin/" + Self.channel)
            // Compare against the running binary, not only the checkout (a failed build may
            // leave the checkout newer than the installed app).
            if revision == new { return report(["status": "current", "current": revision]) }
            guard (try? git("merge-base", "--is-ancestor", "HEAD", new)) != nil else {
                return report(["status": "local-commits"])
            }
            // Refuse a stable rewind relative to the running app when its commit is available.
            if !revision.isEmpty, (try? git("cat-file", "-e", revision + "^{commit}")) != nil,
               (try? git("merge-base", "--is-ancestor", revision, new)) == nil {
                throw Failure(description: "Stable channel is older than the running app")
            }
            do {
                try git("merge", "--ff-only", "-q", new)
                report(["status": "testing", "current": revision, "next": new], save: false)
                try shell(["zsh", "tools/tests/run_mode2.sh"], timeout: 30 * 60, step: "tests")
                report(["status": "building", "current": revision, "next": new], save: false)
                try shell(["zsh", "tools/build_app.sh", "--stage"], timeout: 20 * 60, step: "build")
            } catch {
                // Only this private, clean checkout can be reset; never a developer folder.
                _ = try? git("reset", "-q", "--hard", old)
                throw error
            }
            handoff(staged: root.appendingPathComponent("AI Illuminati.update.app"), next: new)
        } catch {
            report(["status": "failed", "current": revision, "detail": String(describing: error)])
        }
    }

    private func handoff(staged: URL, next: String) {
        DispatchQueue.main.sync {
            guard !isBusy() else {
                report(["status": "waiting", "current": revision, "next": next])
                schedule(after: Self.retry)
                return
            }
            do {
                // Avoid migrating a second app while a legacy copy is still running.
                let others = NSRunningApplication.runningApplications(withBundleIdentifier: "local.aiilluminati")
                    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
                guard others.isEmpty else { throw Failure(description: L("다른 AI Illuminati 앱을 먼저 종료해 주세요", "Quit the other AI Illuminati copy first")) }
                try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let token = UUID().uuidString
                let helper = staged.appendingPathComponent("Contents/Resources/install_app.py")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                var args = [helper.path, "--staged", staged.path, "--current", Bundle.main.bundleURL.path,
                            "--target", target.path, "--support", AccountStore.supportDir,
                            "--pid", String(ProcessInfo.processInfo.processIdentifier), "--token", token]
                if SMAppService.mainApp.status == .enabled { args.append("--restore-login") }
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: "/")
                process.environment = cleanEnvironment()
                process.standardInput = FileHandle.nullDevice
                let log = updates.appendingPathComponent("install.log")
                if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                let output = try FileHandle(forWritingTo: log)
                try output.seekToEnd()
                process.standardOutput = output
                process.standardError = output
                try process.run()
                installing = true
                waitForInstaller(process, token: token, deadline: Date().addingTimeInterval(120))
            } catch { report(["status": "failed", "detail": String(describing: error)]) }
        }
    }

    private func waitForInstaller(_ process: Process, token: String, deadline: Date) {
        // Poll without blocking the UI. Recheck busy immediately before graceful termination.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let ready = self.updates.appendingPathComponent(token + ".ready")
            if FileManager.default.fileExists(atPath: ready.path) {
                guard !self.isBusy() else {
                    process.terminate()
                    self.installing = false
                    self.report(["status": "postponed"])
                    self.schedule(after: Self.retry)
                    return
                }
                if SMAppService.mainApp.status == .enabled {
                    do { try SMAppService.mainApp.unregister() }
                    catch {
                        process.terminate()
                        self.installing = false
                        self.report(["status": "failed", "detail": "Could not unregister old login item: \(error)"])
                        return
                    }
                }
                NSApp.terminate(nil)
            } else if !process.isRunning || Date() > deadline {
                if process.isRunning { process.terminate() }
                self.installing = false
                self.report(["status": "failed", "detail": L("설치 준비 실패: updates/install.log를 확인해 주세요", "Installer preparation failed; see updates/install.log")])
            } else { self.waitForInstaller(process, token: token, deadline: deadline) }
        }
    }

    private func acknowledgeInstallation() {
        let journal = updates.appendingPathComponent("transaction.json")
        guard let data = try? Data(contentsOf: journal),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if record["phase"] as? String == "starting",
           record["target"] as? String == Bundle.main.bundleURL.path,
           record["revision"] as? String == revision, let token = record["token"] as? String,
           UUID(uuidString: token) != nil {
            if record["restoreLogin"] as? Bool == true {
                do { try SMAppService.mainApp.register() }
                catch { report(["status": "failed", "detail": "Login item registration failed: \(error)"]) }
            }
            let confirmation: [String: Any] = ["revision": revision, "pid": ProcessInfo.processInfo.processIdentifier]
            if let ack = try? JSONSerialization.data(withJSONObject: confirmation) {
                try? ack.write(to: updates.appendingPathComponent(token + ".ack"), options: .atomic)
            }
        } else if record["phase"] as? String == "failed", record["restoreLogin"] as? Bool == true {
            try? SMAppService.mainApp.register()
        }
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
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        return env
    }

    private func execute(_ command: [String], timeout: TimeInterval, step: String, directory: URL? = nil) throws -> String {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = directory ?? root
        process.environment = cleanEnvironment()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = FileHandle.nullDevice
        try process.run()
        var data = Data()
        let reader = DispatchQueue(label: "updater-read"), done = DispatchSemaphore(value: 0)
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            DebateCancellation.end(process)
            process.waitUntilExit()
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
        case "waiting": return L("새 버전 준비 완료. 작업이 끝나면 다시 시작해요", "New version ready. Restarting after active work finishes")
        case "current": return L("최신 버전이에요 (\(short(s["current"])))", "Up to date (\(short(s["current"])))") + when
        case "updated":
            if s["previous"] == nil || s["previous"] == s["current"] {
                return L("설치됨: \(short(s["current"]))", "Installed: \(short(s["current"]))") + when
            }
            return L("업데이트됨: \(short(s["previous"])) → \(short(s["current"]))", "Updated: \(short(s["previous"])) → \(short(s["current"]))") + when
        case "postponed": return L("작업 중이라 10분 뒤 다시 확인해요", "Busy; checking again in 10 minutes") + when
        case "local-changes": return L("이 맥에서 고친 코드가 있어 건너뛰었어요", "Skipped: this Mac has its own code changes") + when
        case "local-commits": return L("이 맥에만 있는 커밋이 있어 건너뛰었어요", "Skipped: this Mac has commits not on GitHub") + when
        case "unavailable": return L("업데이트 소스를 준비하지 못했어요", "Update source is unavailable")
        case "failed": return L("업데이트 실패, 지금 버전을 그대로 써요: ", "Update failed; keeping this version: ") + (s["detail"] ?? "") + when
        default: return ""
        }
    }
}
