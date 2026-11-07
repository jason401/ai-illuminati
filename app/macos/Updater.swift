import Cocoa
import Darwin
import ServiceManagement

// stable is a deployment channel; main is the beta channel, where changes arrive first.
// Only the app-owned checkout is ever changed.
// Each Mac builds with its existing local identity; developer repositories are never touched.
final class Updater: ObservableObject {
    // Only checks run on their own; installing a new version always waits for the button.
    // The key keeps its old name so an existing on/off choice carries over.
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "autoUpdate") }
    }
    @Published private(set) var checking = false
    @Published private(set) var status = ""
    @Published private(set) var available: String?
    /// The branch updates come from: "stable" (default) or "main" (beta).
    @Published private(set) var channel = UpdateChannel.current
    var isBusy: () -> Bool = { false }
    var onAvailableChange: () -> Void = {}

    static let every: TimeInterval = 3 * 3600, retry: TimeInterval = 600, first: TimeInterval = 60
    static let repository = "https://github.com/jason401/ai-illuminati.git"
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
    private var migrating: Bool { Bundle.main.bundleURL.standardizedFileURL != target.standardizedFileURL }
    private var staged: URL { root.appendingPathComponent("AI Illuminati.update.app") }
    private let work = DispatchQueue(label: "updater")
    private var timer: Timer?
    private var stateFile: URL { URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("update.json") }

    init() {
        enabled = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true
        let state = loadState()
        status = Self.describe(state)
        if state["status"] == "available", let next = state["next"], next != revision { available = next }
    }

    func start() {
        acknowledgeInstallation()
        // A developer build is moved to its install location once, without waiting for the button.
        if migrating { return schedule(after: 2) { $0.install() } }
        schedule(after: Self.first) { if $0.enabled { $0.check() } }
        timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { [weak self] _ in
            guard let self, self.enabled else { return }
            self.check()
        }
    }

    private func schedule(after seconds: TimeInterval, _ step: @escaping (Updater) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if let self { step(self) }
        }
    }

    /// Switches between Stable and Beta, then looks right away. What the other channel found no longer applies.
    func setChannel(_ name: String) {
        guard UpdateChannel.all.contains(name), name != channel else { return }
        channel = name
        UserDefaults.standard.set(name, forKey: UpdateChannel.key)
        setAvailable(nil)
        report(["status": ""])
        if !checking && !installing { check() }   // a running check looks again when it ends
    }

    /// True while `branch` is still the chosen channel (asked from the update queue).
    private func still(_ branch: String) -> Bool { DispatchQueue.main.sync { channel == branch } }

    /// Looks for a new version on the chosen channel. Changes nothing on this Mac's app.
    func check() {
        guard !checking, !installing else { return }
        checking = true
        let branch = channel
        report(["status": "checking"], save: false)
        work.async {
            defer { DispatchQueue.main.async { self.finished(branch) } }
            do {
                try self.withSource(branch) { step in
                    // The channel changed while this ran: its result belongs to the other channel.
                    guard self.still(branch) else { return }
                    self.report(["status": "available", "current": self.revision, "next": step.new])
                    self.setAvailable(step.new)
                }
            } catch {
                if self.still(branch) { self.report(["status": "failed", "current": self.revision, "detail": String(describing: error)]) }
            }
        }
    }

    /// Ends a check or install; if the channel changed meanwhile, looks again (without installing).
    private func finished(_ branch: String) {
        checking = false
        if channel != branch { check() }
    }

    /// Runs only after the user asks: tests, builds and installs the chosen channel's version.
    func install() {
        guard !checking, !installing else { return }
        let branch = channel
        if isBusy() {
            report(["status": "waiting", "current": revision])
            return schedule(after: Self.retry) { if $0.channel == branch { $0.install() } }
        }
        checking = true
        report(["status": "checking"], save: false)
        work.async {
            defer { DispatchQueue.main.async { self.finished(branch) } }
            if self.migrating { return self.handoff(staged: Bundle.main.bundleURL, next: self.revision) }
            do {
                try self.withSource(branch) { step in
                    // A build made earlier for this version (e.g. while waiting for a chat) is reused.
                    let ready = (try? self.git("rev-parse", "HEAD")) == step.new && !step.switching
                        && (NSDictionary(contentsOf: self.staged.appendingPathComponent("Contents/Info.plist"))?["AISourceRevision"] as? String) == step.new
                    if !ready {
                        do {
                            try step.advance(self.gitStep)
                            self.report(["status": "testing", "current": self.revision, "next": step.new], save: false)
                            try self.shell(["zsh", "tools/tests/run_mode2.sh"], timeout: 30 * 60, step: "tests")
                            self.report(["status": "building", "current": self.revision, "next": step.new], save: false)
                            try self.shell(["zsh", "tools/build_app.sh", "--stage"], timeout: 20 * 60, step: "build")
                        } catch {
                            // Only this private, clean checkout can be reset; never a developer folder.
                            step.restore(self.gitStep)
                            throw error
                        }
                    }
                    // Testing and building take minutes: a channel picked meanwhile waits for a new Update Now.
                    guard self.still(branch) else { return }
                    self.handoff(staged: self.staged, next: step.new, channel: branch)
                }
            } catch {
                if self.still(branch) { self.report(["status": "failed", "current": self.revision, "detail": String(describing: error)]) }
            }
        }
    }

    private func setAvailable(_ next: String?) {
        DispatchQueue.main.async {
            guard self.available != next else { return }
            self.available = next
            self.onAvailableChange()
        }
    }

    // MARK: Steps

    /// Holds the source lock, fetches `branch` and calls `body` only when it is newer than the
    /// running app. Other outcomes are reported here.
    private func withSource(_ branch: String, _ body: (ChannelStep) throws -> Void) throws {
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
            _ = try execute(["/usr/bin/git", "clone", "--branch", branch, "--single-branch", Self.repository, temporary.path],
                        timeout: 180, step: "clone", directory: root.deletingLastPathComponent())
            try FileManager.default.moveItem(at: temporary, to: root)
        }
        guard try git("remote", "get-url", "origin") == Self.repository else {
            throw Failure(description: "Unexpected update repository")
        }
        guard try git("status", "--porcelain", "--untracked-files=normal").isEmpty else {
            return report(["status": "local-changes"])
        }
        let step = try ChannelStep.look(branch: branch, revision: revision, git: gitStep)
        switch step.outcome {
        case .newer: try body(step)
        case .current:
            setAvailable(nil)
            report(["status": "current", "current": revision])
        case .localCommits: report(["status": "local-commits"])
        case .otherBranch: report(["status": "other-branch", "detail": step.head])
        case .ahead:
            setAvailable(nil)
            report(["status": "ahead", "current": revision, "channel": branch])
        }
    }

    /// `channel` is the update channel this install came from; nil for moving a development build.
    private func handoff(staged: URL, next: String, channel: String? = nil) {
        DispatchQueue.main.sync {
            guard !isBusy() else {
                report(["status": "waiting", "current": revision, "next": next])
                schedule(after: Self.retry) { $0.retryInstall(channel) }
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
                waitForInstaller(process, token: token, next: next, channel: channel, deadline: Date().addingTimeInterval(120))
            } catch { report(["status": "failed", "detail": String(describing: error)]) }
        }
    }

    private func waitForInstaller(_ process: Process, token: String, next: String, channel: String?, deadline: Date) {
        // Poll without blocking the UI. Recheck busy immediately before graceful termination.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let ready = self.updates.appendingPathComponent(token + ".ready")
            if FileManager.default.fileExists(atPath: ready.path) {
                guard !self.isBusy() else {
                    process.terminate()
                    self.installing = false
                    self.report(["status": "waiting", "current": self.revision, "next": next])
                    self.schedule(after: Self.retry) { $0.retryInstall(channel) }
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
            } else { self.waitForInstaller(process, token: token, next: next, channel: channel, deadline: deadline) }
        }
    }

    /// Tries a postponed install again, unless the user picked another channel meanwhile.
    private func retryInstall(_ channel: String?) {
        if channel == nil || channel == self.channel { install() }
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
        try gitStep(arguments, timeout)
    }

    /// Git in the update checkout, for ChannelStep.
    private var gitStep: ChannelStep.Git {
        { [unowned self] arguments, timeout in
            try self.execute(["/usr/bin/git", "-C", self.root.path] + arguments, timeout: timeout, step: "git " + (arguments.first ?? ""))
        }
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
        case "available": return L("새 버전(\(short(s["next"])))이 있어요. '지금 업데이트'를 눌러 설치해요", "New version \(short(s["next"])) is available. Click Update Now to install") + when
        case "waiting": return L("채팅·게임이 끝나면 업데이트해요", "Updating after the chat or game finishes")
        case "current": return L("최신 버전이에요 (\(short(s["current"])))", "Up to date (\(short(s["current"])))") + when
        case "updated":
            if s["previous"] == nil || s["previous"] == s["current"] {
                return L("설치됨: \(short(s["current"]))", "Installed: \(short(s["current"]))") + when
            }
            return L("업데이트됨: \(short(s["previous"])) → \(short(s["current"]))", "Updated: \(short(s["previous"])) → \(short(s["current"]))") + when
        case "postponed": return L("다른 업데이트 작업 중이에요", "Another update step is running") + when
        case "local-changes": return L("이 맥에서 고친 코드가 있어 건너뛰었어요", "Skipped: this Mac has its own code changes") + when
        case "local-commits": return L("이 맥에만 있는 커밋이 있어 건너뛰었어요", "Skipped: this Mac has commits not on GitHub") + when
        case "other-branch":
            let head = s["detail"] ?? "?"
            return L("업데이트 소스가 stable·main이 아닌 \(head) 브랜치에 있어 건너뛰었어요", "Skipped: the update source is on \(head), not stable or main") + when
        case "ahead":
            let label = UpdateChannel.label(s["channel"] ?? "stable")
            return L("이 맥의 앱이 \(label)보다 새 버전이에요. \(label)이 따라잡으면 업데이트돼요",
                     "This Mac already runs a newer version than \(label); it updates once \(label) catches up") + when
        case "unavailable": return L("업데이트 소스를 준비하지 못했어요", "Update source is unavailable")
        case "failed": return L("업데이트 실패, 지금 버전을 그대로 써요: ", "Update failed; keeping this version: ") + (s["detail"] ?? "") + when
        default: return ""
        }
    }
}

/// The update channels: stable (default) and main, the beta channel where new changes arrive first.
enum UpdateChannel {
    static let all = ["stable", "main"]
    static let key = "updateChannel"
    static var current: String { valid(UserDefaults.standard.string(forKey: key)) }
    static func valid(_ name: String?) -> String { name.flatMap { all.contains($0) ? $0 : nil } ?? "stable" }
    static func label(_ name: String) -> String { name == "main" ? L("베타(main)", "beta (main)") : name }
    /// The branch this app was built from (written by build_app.sh); "main" shows as Beta.
    static var built: String { Bundle.main.object(forInfoDictionaryKey: "AIUpdateChannel") as? String ?? "" }
}

/// One look at an update channel from the app's private checkout: what it found, and how to move there.
struct ChannelStep {
    enum Outcome: Equatable { case current, newer, ahead, localCommits, otherBranch }
    typealias Git = (_ arguments: [String], _ timeout: TimeInterval) throws -> String
    let branch: String, head: String, old: String, new: String, outcome: Outcome
    /// The user picked the other channel: the checkout follows it.
    var switching: Bool { head != branch }

    /// Fetches `branch` and compares it with the checkout and with `revision`, the running app's commit.
    /// The checkout is cloned with one branch only, so the fetched commit is read from FETCH_HEAD.
    static func look(branch: String, revision: String, git: Git) throws -> ChannelStep {
        let head = try git(["rev-parse", "--abbrev-ref", "HEAD"], 60), old = try git(["rev-parse", "HEAD"], 60)
        func step(_ new: String, _ outcome: Outcome) -> ChannelStep {
            ChannelStep(branch: branch, head: head, old: old, new: new, outcome: outcome)
        }
        guard UpdateChannel.all.contains(head) else { return step(old, .otherBranch) }
        _ = try git(["fetch", "-q", "origin", branch], 90)
        let new = try git(["rev-parse", "FETCH_HEAD"], 60)
        func ancestor(_ a: String, _ b: String) -> Bool { (try? git(["merge-base", "--is-ancestor", a, b], 60)) != nil }
        func known(_ commit: String) -> Bool { (try? git(["cat-file", "-e", commit + "^{commit}"], 60)) != nil }
        // Compare against the running app, not only the checkout (a failed build may leave the checkout newer).
        if revision == new {
            if head != branch { _ = try git(["checkout", "-q", "-B", branch, new], 60) }
            return step(new, .current)
        }
        if head == branch && !ancestor(old, new) { return step(new, .localCommits) }
        if !revision.isEmpty {
            // A build from the other channel may be ahead of this one: never go back.
            for other in UpdateChannel.all where other != branch && !known(revision) {
                _ = try? git(["fetch", "-q", "origin", other], 90)
            }
            if known(revision) && !ancestor(revision, new) { return step(new, .ahead) }
        }
        return step(new, .newer)
    }

    /// Moves the checkout to the new commit: a fast-forward, or onto the other channel's branch.
    func advance(_ git: Git) throws {
        if switching { _ = try git(["checkout", "-q", "-B", branch, new], 60) }
        else { _ = try git(["merge", "--ff-only", "-q", new], 60) }
    }

    /// After failed tests or build: back to the branch and commit the running app came from.
    func restore(_ git: Git) {
        if switching { _ = try? git(["checkout", "-q", "--force", "-B", head, old], 60) }
        else { _ = try? git(["reset", "-q", "--hard", old], 60) }
    }
}
