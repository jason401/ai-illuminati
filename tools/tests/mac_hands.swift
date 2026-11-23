import Foundation
import ApplicationServices
import AIAccounts
import AIProjects
@testable import AIChat
@testable import AIIntegrations

// Mac hands (MacControl stage 4): the rules for one action, image pixels to screen points, the one-answer lock, which
// tools each setting offers, and the "ask" card going through the chat's approvals (so the chat, the 🔴 strip and the
// inbox show it) with no answer in time counted as no. Real clicks and typing need Accessibility: checked by hand.
func testMacHands() {
    // Image pixels of the newest screenshot → screen points; without one, the numbers are screen points.
    let mapping = MacControl.Mapping(origin: CGPoint(x: 100, y: 50), scale: CGSize(width: 2, height: 1.5), size: CGSize(width: 640, height: 400))
    expect(MacControl.screenPoint(10, 20, mapping) == CGPoint(x: 120, y: 80), "image pixels map to screen points")
    expect(MacControl.screenPoint(640, 400, mapping) == CGPoint(x: 1380, y: 650), "the image's far corner maps too")
    expect(MacControl.screenPoint(641, 20, mapping) == nil && MacControl.screenPoint(5, 401, mapping) == nil, "a point outside the screenshot is refused")
    expect(MacControl.screenPoint(-1, 0, mapping) == nil && MacControl.screenPoint(.nan, 1, nil) == nil, "negative or broken numbers are refused")
    expect(MacControl.screenPoint(30, 40, nil) == CGPoint(x: 30, y: 40), "without a screenshot the numbers are screen points")

    // The rules: off and own windows and password fields always refused; settings, keychain, terminals and IDEs asked even when on.
    func verdict(_ rule: CapabilityRule, _ bundle: String, own: Bool = false, secure: Bool = false, allowed: Set<String> = [], refused: Set<String> = []) -> MacControl.Verdict {
        MacControl.verdict(rule: rule, bundle: bundle, own: own, secure: secure, allowed: allowed, refused: refused)
    }
    func blocked(_ v: MacControl.Verdict) -> Bool { if case .block = v { return true }; return false }
    expect(blocked(verdict(.off, "com.apple.TextEdit")), "off refuses")
    expect(verdict(.on, "com.apple.TextEdit") == .allow && verdict(.ask, "com.apple.TextEdit") == .ask, "on allows, ask asks")
    expect(verdict(.ask, "com.apple.TextEdit", allowed: ["com.apple.TextEdit"]) == .allow, "an app allowed on a card is not asked again in the answer")
    expect(verdict(.ask, "com.apple.finder", allowed: ["com.apple.TextEdit"]) == .ask, "each app is asked once")
    expect(blocked(verdict(.on, "com.apple.TextEdit", refused: ["com.apple.TextEdit"])), "a refused app is not asked again in the answer")
    expect(blocked(verdict(.on, "local.aiilluminati", own: true)) && blocked(verdict(.on, "local.aiilluminati", own: true, allowed: ["local.aiilluminati"])),
           "AI Illuminati's own windows are refused even when on or allowed")
    expect(blocked(verdict(.on, "com.apple.Safari", secure: true)) && blocked(verdict(.on, "com.apple.Safari", secure: true, allowed: ["com.apple.Safari"])),
           "a password field is refused even when on or allowed")
    for bundle in ["com.apple.systempreferences", "com.apple.keychainaccess", "com.apple.Terminal", "com.googlecode.iterm2",
                   "com.microsoft.VSCode", "com.apple.dt.Xcode", "com.jetbrains.intellij"] {
        expect(verdict(.on, bundle) == .ask, "\(bundle) is always asked")
        expect(verdict(.on, bundle, allowed: [bundle]) == .allow, "\(bundle) allowed on its card goes on in the answer")
    }

    // One answer at a time.
    let account = Account(id: "mac-hands-\(UUID())", provider: .claude, name: "Claude (개인)")
    let first = MacControl.Session(account: account, room: UUID(), speaker: "Claude (개인)")
    let second = MacControl.Session(account: account, room: UUID(), speaker: "ChatGPT (학교)")
    let lock = MacControl.InputLock()
    expect(lock.claim(first) == nil && lock.claim(first) == nil, "the first answer takes the lock and keeps it")
    expect(lock.claim(second) === first, "another answer is told who holds the screen")
    lock.release(second)
    expect(lock.holder === first, "only the holder releases the lock")
    lock.release(first)
    expect(lock.claim(second) == nil, "the lock is free once the answer ends")
    expect(MacControl.subject("Claude (개인)") == "Claude (개인)이" && MacControl.subject("ChatGPT (학교)") == "ChatGPT (학교)가",
           "the card says 이/가 after the name")

    // Keys.
    let shortcut = Hands.combo("cmd+shift+t")
    expect(shortcut?.key == 17 && shortcut?.flags == [.maskCommand, .maskShift], "cmd+shift+t is T with command and shift")
    expect(Hands.combo("Return")?.key == 36 && Hands.combo("f12")?.key == 111 && Hands.combo("hyper+x") == nil && Hands.combo("") == nil,
           "named keys, function keys and unknown modifiers")

    // Which tools each setting offers (Gemini never: agy gets no app bridge here).
    func names(_ a: Account) -> Set<String> { Set(MacControl.tools(a).compactMap { $0["name"] as? String }) }
    for capability in [AICapability.screen, .input, .apps] { AICapabilities.set(.off, for: account, capability) }
    expect(!MacControl.enabled(account) && names(account).isEmpty, "everything off: no Mac tools")
    AICapabilities.set(.ask, for: account, .input)
    expect(MacControl.enabled(account) && names(account) == ["mac_click", "mac_drag", "mac_scroll", "mac_type", "mac_key"], "mouse and keyboard on ask")
    AICapabilities.set(.on, for: account, .apps)
    AICapabilities.set(.on, for: account, .screen)
    expect(names(account) == MacControl.handNames.union(["mac_screenshot", "mac_windows"]), "every Mac tool")
    AICapabilities.set(.ask, for: account, .screen)
    expect(!names(account).contains("mac_screenshot"), "screen viewing has no ask yet: ask offers no screenshot")
    let gemini = Account(id: "mac-hands-gemini-\(UUID())", provider: .gemini, name: "Gemini")
    AICapabilities.set(.on, for: gemini, .input)
    expect(!MacControl.enabled(gemini) && names(gemini).isEmpty, "Gemini gets no Mac tools")

    // A call outside a live answer, or after Esc, does nothing.
    func run(_ name: String, _ arguments: [String: Any], scope: UUID?) -> [String: Any] {
        var result: [String: Any]?
        Task { @MainActor in result = await MacControl.perform(name, arguments, scope: scope) }
        let until = Date().addingTimeInterval(10)
        while result == nil && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return result ?? [:]
    }
    func text(_ result: [String: Any]) -> String { ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "" }
    expect(run("mac_click", ["x": 1, "y": 1], scope: nil)["isError"] as? Bool == true, "no answer, no click")
    let scope = UUID()
    let session = MacControl.Session(account: account, room: UUID(), speaker: "Claude (개인)")
    MacControl.begin(scope, session)
    MacControl.end(scope)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    expect(session.stopped && run("mac_type", ["text": "hi"], scope: scope)["isError"] as? Bool == true, "an ended answer types nothing")
    if !AXIsProcessTrusted() {
        let live = UUID()
        MacControl.begin(live, MacControl.Session(account: account, room: UUID(), speaker: "Claude (개인)"))
        let refused = run("mac_click", ["x": 1, "y": 1], scope: live)
        expect(refused["isError"] as? Bool == true && (text(refused).contains("손쉬운 사용") || text(refused).contains("Accessibility")),
               "without Accessibility the AI is told to turn it on")
        MacControl.end(live)
    }

    // "Ask": the chat's approval card with "Allow for this answer", in the 🔴 list; no answer in time = no, kept as timed out.
    _ = ToolHub.shared
    ProjectCenter.shared.resume()
    let wait = MacControl.approvalWait
    defer { MacControl.approvalWait = wait }
    MacControl.approvalWait = 1.5
    let room = UUID()
    func ask() -> () -> Bool? {
        var answer: Bool?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            answer = MacControl.approve(MacControl.Approval(room: room, title: "Claude (개인)이 TextEdit에서 클릭하려고 해요", detail: "Click (1, 1)"))
            done.signal()
        }
        return {
            let until = Date().addingTimeInterval(10)
            while done.wait(timeout: .now()) == .timedOut && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            return answer
        }
    }
    let allowed = ask()
    var card: ProjectApproval?
    let until = Date().addingTimeInterval(5)
    while card == nil && Date() < until {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        card = ProjectCenter.shared.requests.first { $0.room == room }
    }
    expect(card?.allowLabel == "이번 답에서 허용" || card?.allowLabel == "Allow for this answer", "the card offers Allow for this answer")
    expect(Blocked.count(requests: ProjectCenter.shared.requests, expired: [], todos: TodoData()) >= 1, "the card counts in the inbox's 🔴")
    if let card { ProjectCenter.shared.decide(card.id, allow: true) }
    expect(allowed() == true, "Allow lets the action go on")
    let unanswered = ask()
    expect(unanswered() == false, "no answer in time counts as no")
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    expect(ProjectCenter.shared.expired.contains { $0.room == room }, "an unanswered card stays as timed out")
    ProjectCenter.shared.cancel(room: room)
    print("PASS: Mac hands (rules, coordinates, lock, keys, tools per setting, the ask card)")
}
