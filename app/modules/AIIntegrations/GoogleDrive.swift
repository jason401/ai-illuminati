import Foundation
import AppKit
import AuthenticationServices
import CryptoKit
import AILocalization

// Google Drive through Google's official Drive MCP server only (docs/GOOGLE_MCP_PLAN.md): one outside MCP server like
// any other (its tools, rules, approval cards and per-AI switches are ExternalMCP's), with its own sign-in. Google's
// MCP servers take only clients marked "AI-powered agent" and offer no automatic registration, and a Desktop client
// needs a secret a public repository cannot hold, so the app carries the project's iOS-type client (no secret) and
// signs in through the Mac's sign-in sheet. Nothing here calls a Drive REST address (testGoogleDrive scans the sources).
public final class GoogleDrive: ObservableObject {
    public static let shared = GoogleDrive()
    public static let server = "gdrive"
    static let url = "https://drivemcp.googleapis.com/mcp/v1"
    static let clientID = "961717606753-4c5cmpcmegejgqdb39plii50ch7rq88m.apps.googleusercontent.com"
    static let scopes = ["https://www.googleapis.com/auth/drive", "openid", "email"]   // openid/email: the account shown in the sidebar
    static let issuer = "https://accounts.google.com"
    static let authorizeURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!
    /// The tools that change Drive (read tools are marked read-only by Google and always run).
    static let writeTools = ["create_file", "copy_file", "upload_file_revision"]

    @Published public private(set) var signingIn = false
    @Published public private(set) var error: String?
    @Published public private(set) var connectedAt: Date?   // the last sign-in that worked, for the sidebar's "Connected"

    static var entry: MCPServerEntry { MCPServerEntry(name: server, url: url, oauthClientID: clientID) }
    static func isGoogle(_ entry: MCPServerEntry) -> Bool { entry.url == url }

    /// The Google account the token belongs to (from the sign-in's ID token), nil before a sign-in.
    public var account: String? { MCPOAuth.saved(Self.entry)?.account }

    /// Shared folders' "Google Drive…": sign in, then add the server. A new connection starts read only, like a new
    /// shared folder; signing in again keeps the pencil and the eye as they were.
    public func connect() {
        guard !signingIn else { return }
        signingIn = true; error = nil
        MCPOAuth.signIn(Self.entry) { result in
            DispatchQueue.main.async {
                self.signingIn = false
                do {
                    try result.get()
                    let added = ExternalMCP.read().servers.contains { $0.name == Self.server }
                    if !added { for tool in Self.writeTools { MCPPermissions.set(Self.server, tool, .block) } }
                    try ExternalMCP.shared.save(Self.entry, replacing: added ? Self.server : nil)
                    self.connectedAt = Date()
                } catch is Cancelled {   // closed or refused by the user: nothing to say
                } catch {
                    self.error = (error as? MCPSession.Failure)?.message ?? error.localizedDescription
                }
            }
        }
    }

    /// Removes the server and its login here, and revokes the login at Google (best effort, off the main thread).
    public func disconnect() {
        let saved = MCPOAuth.saved(Self.entry)
        do { try ExternalMCP.shared.remove(Self.server) } catch {
            self.error = (error as? MCPSession.Failure)?.message ?? error.localizedDescription; return
        }
        error = nil; connectedAt = nil
        if let token = saved?.refresh ?? saved?.access { DispatchQueue.global(qos: .utility).async { Self.revoke(token) } }
    }

    /// The pencil: Drive's write tools run (on) or are not offered at all (off). Read tools are untouched.
    public func setWritable(_ on: Bool) {
        let connected = ExternalMCP.shared.status[Self.server]
        let tools = Set(Self.writeTools).union((connected?.tools ?? []).filter { !(connected?.readOnly.contains($0) ?? false) })
        for tool in tools.sorted() { ExternalMCP.shared.setRule(Self.server, tool, on ? .allow : .block) }
    }
    /// Writable when every write tool may run without asking.
    public static func isWritable(_ status: ExternalMCP.Status?) -> Bool {
        let connected = (status?.tools ?? []).filter { !(status?.readOnly.contains($0) ?? false) }
        return Set(writeTools).union(connected).allSatisfy { status?.rules[$0] ?? MCPPermissions.saved(server, $0) == .allow }
    }

    // MARK: Sign-in (the Mac's sign-in sheet, PKCE S256, no secret)

    struct Cancelled: Error {}

    /// Opens the sign-in sheet (on the main thread) and answers with the address Google sent back. Tests replace it.
    static var present: (URL, String, @escaping (Result<URL, Error>) -> Void) -> Void = { link, scheme, done in
        DispatchQueue.main.async { SignInSheet.start(link, scheme: scheme, done: done) }
    }
    /// The token request (form fields in, status and JSON out). Tests replace it.
    static var post: (URL, [String: String]) throws -> (Int, [String: Any]) = { url, fields in
        let reply = try MCPHTTP.send(url, headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
                                     body: FormEncoding.form(fields), timeout: 30)
        return (reply.status, reply.json ?? [:])
    }
    /// Google's revoke endpoint (OAuth, not Drive). Tests replace it.
    static var revoke: (String) -> Void = { token in
        _ = try? MCPHTTP.send(revokeURL, headers: ["Content-Type": "application/x-www-form-urlencoded"], body: FormEncoding.form(["token": token]), timeout: 10)
    }

    /// The whole sign-in, never on the main thread (it waits for the sheet). MCPOAuth.signIn sends Google's server here.
    static func run(_ entry: MCPServerEntry) throws {
        let scheme = "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        let redirect = scheme + ":/oauth2redirect"
        let verifier = random(), state = random()
        var address = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        address.queryItems = ["client_id": clientID, "redirect_uri": redirect, "response_type": "code", "scope": scopes.joined(separator: " "),
                              "code_challenge": base64url(Data(SHA256.hash(data: Data(verifier.utf8)))), "code_challenge_method": "S256",
                              "state": state, "access_type": "offline", "prompt": "consent"]
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let done = DispatchSemaphore(value: 0)
        var answer: Result<URL, Error> = .failure(Cancelled())
        present(address.url!, scheme) { answer = $0; done.signal() }
        done.wait()
        let back: URL
        do { back = try answer.get() } catch {
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin || error is Cancelled { throw Cancelled() }
            throw MCPSession.Failure(message: L("Google 로그인 창을 열지 못했어요: ", "Could not open Google's sign-in: ") + error.localizedDescription)
        }
        let items = Dictionary((URLComponents(url: back, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { a, _ in a }
        guard items["state"] == state else { throw MCPSession.Failure(message: L("로그인 응답이 이 요청과 맞지 않아요. 다시 시도해 주세요.", "The sign-in answer does not match. Try again.")) }
        if let refused = items["error"] {
            if refused == "access_denied" { throw Cancelled() }
            throw MCPSession.Failure(message: L("Google이 로그인을 거절했어요: ", "Google refused the sign-in: ") + refused)
        }
        guard let code = items["code"], !code.isEmpty else { throw MCPSession.Failure(message: L("로그인 응답에 코드가 없어요.", "The sign-in answer has no code.")) }
        let (status, json) = try post(tokenURL, ["client_id": clientID, "code": code, "code_verifier": verifier,
                                                 "grant_type": "authorization_code", "redirect_uri": redirect])
        guard status == 200, let access = json["access_token"] as? String, !access.isEmpty else {
            throw MCPSession.Failure(message: L("Google에서 로그인을 받지 못했어요", "Google gave no sign-in") + " (HTTP \(status)" + ((json["error"] as? String).map { ", " + $0 } ?? "") + ")")
        }
        // No `resource` and no `scope` on refresh: Google's token endpoint takes neither for this client.
        var saved = MCPOAuth.Saved(serverURL: url, issuer: issuer, tokenEndpoint: tokenURL.absoluteString, resource: "", clientID: clientID,
                                   authMethod: "none", redirect: redirect, registered: false, scope: nil)
        saved.access = access
        saved.refresh = json["refresh_token"] as? String
        saved.expires = (json["expires_in"] as? NSNumber).map { Date().timeIntervalSince1970 + $0.doubleValue }
        saved.account = (json["id_token"] as? String).flatMap(email)
        try MCPOAuth.keep(saved, entry.name)
    }

    /// The e-mail in an ID token's payload, only to show it (the token came straight from Google over TLS).
    static func email(_ idToken: String) -> String? {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var text = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return json["email"] as? String
    }

    private static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }
    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

// The Mac's own sign-in sheet over the app's window (it closes itself when Google answers). One at a time.
final class SignInSheet: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static var current: SignInSheet?
    private var session: ASWebAuthenticationSession?

    static func start(_ link: URL, scheme: String, done: @escaping (Result<URL, Error>) -> Void) {
        current?.session?.cancel()
        let sheet = SignInSheet()
        let session = ASWebAuthenticationSession(url: link, callbackURLScheme: scheme) { url, error in
            current = nil
            if let url { done(.success(url)) } else { done(.failure(error ?? GoogleDrive.Cancelled())) }
        }
        session.presentationContextProvider = sheet
        sheet.session = session
        current = sheet
        NSApp.activate(ignoringOtherApps: true)
        if !session.start() { current = nil; done(.failure(GoogleDrive.Cancelled())) }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey } ?? NSWindow()
    }
}
