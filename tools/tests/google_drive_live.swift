// Hand check (tools/tests/google_drive_live.sh): the real AIIntegrations code against Google. Test home only, never the
// real Keychain; prints no tokens or file names.
import AppKit
@testable import AIIntegrations

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
window.title = "AI Illuminati 시험 — 앱 코드로 Google Drive 연결"
window.center(); window.makeKeyAndOrderFront(nil)
DispatchQueue.global().async {
    let entry = GoogleDrive.entry
    print("store is file (not Keychain):", !(MCPSecrets.store is MCPKeychain))
    let done = DispatchSemaphore(value: 0)
    var result: Result<Void, Error> = .failure(MCPSession.Failure(message: "no answer"))
    MCPOAuth.signIn(entry) { result = $0; done.signal() }
    done.wait()
    switch result {
    case .success: print("[로그인] 성공, 계정 있음:", MCPOAuth.saved(entry)?.account != nil)
    case .failure(let e): print("[로그인] 실패:", (e as? MCPSession.Failure)?.message ?? "\(e)"); exit(1)
    }
    let session = RemoteMCPSession(entry: entry)
    do {
        let tools = try session.open(timeout: 60)
        print("[연결] 방식:", session.isModern ? "modern (2026-07-28)" : "older (initialize)", "/ 도구", tools.count, "개:", tools.compactMap { $0["name"] as? String }.sorted().joined(separator: ", "))
        print("[읽기전용 표시] ", tools.filter { ($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true }.compactMap { $0["name"] as? String }.sorted().joined(separator: ", "))
    } catch { print("[연결] 실패:", (error as? MCPSession.Failure)?.message ?? (error as? RemoteMCPSession.LoginNeeded)?.message ?? "\(error)"); exit(1) }
    let r = session.call("list_recent_files", ["pageSize": 3], timeout: 60)
    let text = ((r["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    print("[읽기] list_recent_files:", r["isError"] as? Bool == true ? "오류: " + String(text.prefix(300)) : "성공 (\(text.count)자 받음)")
    _ = try? MCPOAuth.token(entry, refresh: true).map { _ in print("[갱신] 로그인 유지 갱신 성공 (secret 없이)") }
    exit(0)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 300) { print("시간 초과"); exit(1) }
app.run()
