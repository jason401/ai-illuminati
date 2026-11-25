import Foundation
import AIAccounts

// Google Drive was removed on 2026-11-25, to be made again from a clean start. An app updated from a version that had
// it clears, once, what Drive left: its settings, drive.log, and the Google login in the Keychain (revoked at Google
// first, so the account's list of connected apps is clean too). Files Drive downloaded into chat folders stay: they
// are the user's.
public enum DriveCleanup {
    static let keys = ["driveFolders", "pausedDriveFolders", "driveWriteRules", "driveRuleRoots", "driveWorkspaceMCP"]
    static let service = "AI Illuminati Google", items = ["oauth", "oauth-migration"]
    static let doneKey = "driveCleanupDone"

    /// The app's start calls it first, before anything loads SidebarFold; the Keychain work runs off the main thread.
    /// Only the app itself (real settings) touches the real Keychain, like MCPSecrets.store.
    public static func start() {
        guard UserDefaults.app === UserDefaults.standard else { return }
        // Every start, not only once: the first cleaned version ran after the sidebar had read its folded rows, and the
        // sidebar wrote "drive" back. Removing what is not there costs nothing.
        clearSettings(UserDefaults.app)
        guard !UserDefaults.app.bool(forKey: doneKey) else { return }
        DispatchQueue.global(qos: .utility).async { run() }
    }

    /// True when nothing is left; a Keychain that could not be read or changed is tried again at the next start.
    @discardableResult
    static func run(defaults: UserDefaults = .app, folder: URL = URL(fileURLWithPath: AccountStore.supportDir),
                    security: SecurityTool.Runner = SecurityTool.execute, revoke: (String) -> Void = revokeAtGoogle) -> Bool {
        clearSettings(defaults)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("drive.log"))
        var clean = true
        for item in items {
            guard let (found, value) = try? security(["find-generic-password", "-s", service, "-a", item, "-w"], nil) else { clean = false; continue }
            if found == 44 { continue }   // errSecItemNotFound: nothing saved
            guard found == 0 else { clean = false; continue }
            if let token = refreshToken(value) { revoke(token) }
            guard let (removed, _) = try? security(["delete-generic-password", "-s", service, "-a", item], nil), removed == 0 || removed == 44 else {
                clean = false; continue
            }
        }
        if clean { defaults.set(true, forKey: doneKey) }
        return clean
    }

    static func clearSettings(_ defaults: UserDefaults) {
        for key in keys { defaults.removeObject(forKey: key) }
        // The MCP switch of the "google-drive" row, and the sidebar's folded Drive section.
        for (key, gone) in [("mcpOff", "google-drive"), ("sidebar.folded", "drive")] {
            if let list = defaults.stringArray(forKey: key), list.contains(gone) { defaults.set(list.filter { $0 != gone }, forKey: key) }
        }
    }

    // The saved login: "ai-illuminati-google-v1:" + base64 of its JSON, or the raw JSON of older versions.
    static func refreshToken(_ value: Data) -> String? {
        var data = value
        if data.last == 10 { data.removeLast() }   // security adds one newline
        let prefix = Data("ai-illuminati-google-v1:".utf8)
        if data.starts(with: prefix), let decoded = Data(base64Encoded: data.dropFirst(prefix.count)) { data = decoded }
        guard let token = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["refreshToken"] as? String, !token.isEmpty else { return nil }
        return token
    }

    // Best effort, at most about 12 seconds: no network, or a token Google already dropped, leaves only the local copy to delete.
    static func revokeAtGoogle(_ token: String) {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormEncoding.form(["token": token])
        let session = URLSession(configuration: .ephemeral), done = DispatchSemaphore(value: 0)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 12)
    }
}
