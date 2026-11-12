import Foundation
import AIAccounts
@testable import AIChat

/// Stable and Beta (main) in a throwaway pair of repositories: switching, going back, never downgrading.
/// The fixture "GitHub" commits directly instead of receiving a push, so this also runs where git push is blocked.
func testUpdateChannels() {
    expect(UpdateChannel.valid(nil) == "stable" && UpdateChannel.valid("beta") == "stable" && UpdateChannel.valid("main") == "main",
           "unknown update channels fall back to stable")
    let base = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("illuminati-channels-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let origin = base.appendingPathComponent("origin"), checkout = base.appendingPathComponent("source")
    try! FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
    func run(_ folder: URL, _ arguments: [String]) throws -> String {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false"] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": base.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"]
        process.standardOutput = out; process.standardError = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw Updater.Failure(description: "git \(arguments.first ?? ""): \(text)") }
        return text
    }
    func github(_ arguments: String...) -> String { try! run(origin, arguments) }
    func commit(_ text: String) -> String {
        try! text.write(to: origin.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = github("add", "file.txt"); _ = github("commit", "-q", "-m", text)
        return github("rev-parse", "HEAD")
    }
    let git: ChannelStep.Git = { arguments, _ in try run(checkout, arguments) }
    func branch() -> String { try! git(["rev-parse", "--abbrev-ref", "HEAD"], 60) }
    func look(_ channel: String, _ revision: String) -> ChannelStep { try! ChannelStep.look(branch: channel, revision: revision, git: git) }

    _ = github("init", "-q", "-b", "stable")
    let a = commit("A")
    _ = github("branch", "main")
    _ = github("checkout", "-q", "main")
    let b = commit("B")
    _ = try! run(base, ["clone", "-q", "--branch", "stable", "--single-branch", origin.path, checkout.path])

    expect(look("stable", a).outcome == .current, "stable app on stable: up to date")
    // A local build GitHub does not have is never compared, so never "updated" to an older version.
    expect(look("stable", String(repeating: "0", count: 40)).outcome == .localBuild, "an unpushed local build waits instead of installing stable")
    expect(UpdateChannel.proceeds(started: "main", now: "main") && UpdateChannel.proceeds(started: nil, now: "stable")
           && !UpdateChannel.proceeds(started: "main", now: "stable"), "an install stops when the channel changed before the swap")
    let beta = look("main", a)
    expect(beta.outcome == .newer && beta.new == b && beta.switching, "Beta finds main from a single-branch stable checkout")
    try! beta.advance(git)
    expect(branch() == "main" && (try! git(["rev-parse", "HEAD"], 60)) == b, "the checkout follows the chosen channel")
    beta.restore(git)
    expect(branch() == "stable" && (try! git(["rev-parse", "HEAD"], 60)) == a, "failed tests or build put the checkout back")
    try! beta.advance(git)
    expect(look("main", b).outcome == .current, "beta app on main: up to date")
    expect(look("stable", b).outcome == .ahead, "back to Stable never installs an older version")
    _ = github("checkout", "-q", "stable"); _ = github("merge", "-q", "--ff-only", "main")
    let c = commit("C")
    let caught = look("stable", b)
    expect(caught.outcome == .newer && caught.new == c && caught.switching, "Stable updates once it catches up")
    try! caught.advance(git)
    expect(branch() == "stable" && look("stable", c).outcome == .current, "the checkout is back on stable")
    _ = github("checkout", "-q", "main")
    expect(look("main", c).outcome == .ahead, "Beta behind the running app waits too")
    _ = try! git(["checkout", "-q", "-b", "local"], 60)
    expect(look("stable", c).outcome == .otherBranch, "a checkout on another branch is left alone")
    let now = Date()
    var progress = UpdateProgress()
    progress.move(to: 3, at: now)
    progress.waitForWork(at: now, retry: Updater.retry)
    expect(Updater.retry == 10 && progress.waiting && progress.stage == 3, "prepared updates wait only at the app replacement step")
    expect(progress.waitNextAt!.timeIntervalSince(now) == 10, "waiting publishes a ten-second next check time")
    expect(progress.summary(at: now.addingTimeInterval(2)).contains("8"), "prepared update shows a live countdown")
    progress.waitForWork(at: now.addingTimeInterval(10), retry: Updater.retry)
    expect(progress.waitCheckedAt == now.addingTimeInterval(10) && progress.stage == 3, "rechecking preserves prepared progress")
    print("PASS: update channels (Stable and Beta from a single-branch checkout, switching, restore after failure, never downgrading, unpushed local builds wait, a changed channel stops the install)")
}
