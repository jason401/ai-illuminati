import Foundation
import Security
import CryptoKit
import Darwin

struct GoogleFailure: LocalizedError {
    let message: String
    var status: Int? = nil
    var errorDescription: String? { message }
}

// A bounded, non-redirecting client: a document URL or redirect can never redirect a bearer token.
enum GoogleHTTP {
    struct Reply { var status: Int; var data: Data; var headers: [AnyHashable: Any] }
    private final class Reader: NSObject, URLSessionDataDelegate {
        let done = DispatchSemaphore(value: 0)
        let limit: Int
        var data = Data(), response: HTTPURLResponse?, failure: Error?
        init(limit: Int) { self.limit = limit }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            self.response = response as? HTTPURLResponse
            if response.expectedContentLength > Int64(limit) {
                failure = GoogleFailure(message: "Google file is too large.")
                completionHandler(.cancel)
            } else { completionHandler(.allow) }
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            if self.data.count + data.count > limit {
                failure = GoogleFailure(message: "Google file is too large.")
                dataTask.cancel()
            } else { self.data.append(data) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if failure == nil, error != nil { failure = GoogleFailure(message: "Google request failed or timed out. Check the network.") }
            done.signal()
        }
    }
    static func send(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
                     limit: Int = 2_000_000) throws -> Reply {
        let remaining = (Thread.current.threadDictionary["illuminatiGoogleDeadline"] as? Date)?.timeIntervalSinceNow ?? 55
        guard remaining > 0 else { throw GoogleFailure(message: "Google request timed out.") }
        let timeout = min(55, remaining)
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = min(45, timeout)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let reader = Reader(limit: limit), configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: reader, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: request).resume()
        guard reader.done.wait(timeout: .now() + timeout + 1) == .success else { throw GoogleFailure(message: "Google request timed out.") }
        if let error = reader.failure { throw error }
        guard let response = reader.response else { throw GoogleFailure(message: "No response from Google.") }
        return Reply(status: response.statusCode, data: reader.data, headers: response.allHeaderFields)
    }
    static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    static func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: unreserved)! }
    static func form(_ fields: [String: String]) -> Data {
        Data(fields.sorted { $0.key < $1.key }.map { encode($0.key) + "=" + encode($0.value) }.joined(separator: "&").utf8)
    }
}

protocol GoogleTokenStore {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func clear() throws
}

struct GoogleKeychainStore: GoogleTokenStore {
    // Apple's signed security executable owns the ACL, so rebuilding this app does not change its reader.
    // All secret writes go over stdin, never argv, shell interpolation, a file or a log.
    typealias Runner = ([String], Data?) throws -> (Int32, Data)
    private static let lock = NSRecursiveLock()
    private static let prefix = "ai-illuminati-google-v1:"
    private static let service = "AI Illuminati Google"
    private static let backup = "oauth-migration"
    private let run: Runner
    init(run: Runner? = nil) { self.run = run ?? Self.execute }

    static func execute(_ arguments: [String], _ input: Data?) throws -> (Int32, Data) {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let pipe = input == nil ? nil : Pipe()
        process.standardInput = pipe.map { $0.fileHandleForReading } ?? FileHandle.nullDevice
        do { try process.run() } catch { throw GoogleFailure(message: "Could not start macOS Keychain access.") }
        if let input, let pipe {
            pipe.fileHandleForWriting.write(input)
            pipe.fileHandleForWriting.closeFile()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
    private func read(_ account: String) throws -> Data? {
        let (status, output) = try run(["find-generic-password", "-s", Self.service, "-a", account, "-w"], nil)
        if status == 44 { return nil } // errSecItemNotFound, as returned by security(1).
        guard status == 0 else { throw GoogleFailure(message: "Could not read Google login from Keychain.") }
        var data = output
        if data.last == 10 { data.removeLast() } // security adds one newline; do not trim the stored value.
        return data
    }
    private func unpack(_ value: Data) throws -> Data? {
        let prefix = Data(Self.prefix.utf8)
        guard value.starts(with: prefix) else { return nil }
        guard let data = Data(base64Encoded: value.dropFirst(prefix.count)) else {
            throw GoogleFailure(message: "Google Keychain login is damaged. Reconnect Google Drive.")
        }
        return data
    }
    private func write(_ data: Data, account: String) throws {
        let value = Self.prefix + data.base64EncodedString()
        let line = "add-generic-password -U -s \"AI Illuminati Google\" -a " + account + " -w " + value + "\n"
        // security's interactive parser has a bounded input line. Reject before touching existing items.
        guard line.utf8.count < 4000 else { throw GoogleFailure(message: "Google login is too large for macOS Keychain storage.") }
        let (status, _) = try run(["-i"], Data(line.utf8))
        guard status == 0, try read(account) == Data(value.utf8) else {
            throw GoogleFailure(message: "Could not save Google login to Keychain.")
        }
    }
    private func remove(_ account: String) throws {
        let (status, _) = try run(["delete-generic-password", "-s", Self.service, "-a", account], nil)
        guard status == 0 || status == 44 else { throw GoogleFailure(message: "Could not remove Google login from Keychain.") }
    }
    func load() throws -> Data? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if let raw = try read("oauth") {
            if let data = try unpack(raw) {
                try? remove(Self.backup)
                return data
            }
            // Legacy raw JSON item. Read once (macOS may ask once), stage a recoverable CLI-owned copy,
            // then replace the item so its original per-build ACL/partition is not retained by -U.
            guard (try? JSONDecoder().decode(GoogleAuth.Credentials.self, from: raw)) != nil else {
                throw GoogleFailure(message: "Google Keychain login is damaged. Reconnect Google Drive.")
            }
            try write(raw, account: Self.backup)
            try remove("oauth")
            try write(raw, account: "oauth")
            try? remove(Self.backup)
            return raw
        }
        // Recover a migration interrupted between deleting the legacy item and recreating the CLI item.
        if let saved = try read(Self.backup), let data = try unpack(saved) {
            try write(data, account: "oauth")
            try? remove(Self.backup)
            return data
        }
        return nil
    }
    func save(_ data: Data) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        _ = try load() // Migrate an existing legacy ACL before updating it.
        try write(data, account: "oauth")
    }
    func clear() throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try remove("oauth"); try remove(Self.backup)
    }
}

protocol GoogleAuthPresenter: AnyObject {
    func start(_ url: URL, scheme: String, completion: @escaping (Result<URL, Error>) -> Void)
    func cancel()
}

// Backend only: a future UI supplies the Desktop-client JSON and opens the returned URL.
// No browser is opened and no Google login starts without an explicit caller.
final class GoogleAuth {
    static var shared = GoogleAuth(store: GoogleKeychainStore())
    static let builtInClientID = "961717606753-4c5cmpcmegejgqdb39plii50ch7rq88m.apps.googleusercontent.com" // Public iOS OAuth client; no secret.
    static let writeScope = "https://www.googleapis.com/auth/drive"
    static let scope = "https://www.googleapis.com/auth/drive.readonly"
    static var authorizeURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static var tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static var revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!
    struct Credentials: Codable { var clientID: String; var clientSecret: String?; var refreshToken: String?; var writable: Bool? = nil }
    private let store: GoogleTokenStore
    private let lock = NSRecursiveLock()
    private var access: String?, expires = Date.distantPast
    private var presenter: GoogleAuthPresenter?
    private var listener: GoogleLoopback?
    private var authorizationID: UUID?
    private var version = 0
    var connectionVersion: Int { lock.lock(); defer { lock.unlock() }; return version }
    init(store: GoogleTokenStore) { self.store = store }
    var connected: Bool {
        lock.lock(); defer { lock.unlock() }
        return ((try? credentials())?.refreshToken?.isEmpty == false)
    }
    // Google refused the saved login (expired or revoked): sign in again with the saved client.
    var needsReconnect: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let saved = try? credentials() else { return false }
        return saved.refreshToken?.isEmpty != false
    }
    func beginReauthorization(writable: Bool = false, completion: @escaping (Result<Void, Error>) -> Void) throws -> URL {
        let saved: Credentials? = { lock.lock(); defer { lock.unlock() }; return try? credentials() }()
        guard let saved else { throw GoogleFailure(message: "Choose the Google OAuth client file again.") }
        let client = try JSONSerialization.data(withJSONObject: ["installed": ["client_id": saved.clientID, "client_secret": saved.clientSecret ?? ""]])
        return try beginAuthorization(clientJSON: client, writable: writable, completion: completion)
    }
    private func credentials() throws -> Credentials? {
        guard let data = try store.load() else { return nil }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw GoogleFailure(message: "Could not start secure Google sign-in.") }
        return base64(Data(bytes))
    }
    private static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func beginAuthorization(clientJSON: Data, writable: Bool = false, completion: @escaping (Result<Void, Error>) -> Void) throws -> URL {
        guard clientJSON.count <= 64_000,
              let json = try JSONSerialization.jsonObject(with: clientJSON) as? [String: Any],
              let installed = json["installed"] as? [String: Any],
              let client = installed["client_id"] as? String, !client.isEmpty,
              let secret = installed["client_secret"] as? String, !secret.isEmpty else {
            throw GoogleFailure(message: "Choose a Google OAuth Desktop-app client JSON, not an API key.")
        }
        lock.lock(); defer { lock.unlock() }
        presenter?.cancel(); presenter = nil
        listener?.cancel()
        let state = try Self.random(), verifier = try Self.random(), identifier = UUID()
        let callback = try GoogleLoopback()
        listener = callback; authorizationID = identifier
        // Do not overwrite a working account until a successful exchange.
        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = ["client_id": client, "redirect_uri": callback.redirect,
            "response_type": "code", "scope": writable ? Self.writeScope : Self.scope, "access_type": "offline", "prompt": "consent",
            "state": state, "code_challenge_method": "S256",
            "code_challenge": Self.base64(Data(SHA256.hash(data: Data(verifier.utf8))))].map { URLQueryItem(name: $0.key, value: $0.value) }
        callback.start { result in
            self.lock.lock()
            let current = self.authorizationID == identifier
            self.lock.unlock()
            guard current else { completion(.failure(GoogleFailure(message: "Google sign-in was cancelled."))); return }
            do {
                let fields = try result.get()
                guard fields["state"] == state else { throw GoogleFailure(message: "Google sign-in state did not match. Please reconnect.") }
                if let error = fields["error"] {
                    throw GoogleFailure(message: error == "admin_policy_enforced" ? "Your Google administrator blocked this app." : "Google sign-in was denied or cancelled.")
                }
                guard let code = fields["code"], !code.isEmpty else { throw GoogleFailure(message: "Google sign-in returned no authorization code.") }
                let reply = try self.token(["client_id": client, "client_secret": secret, "code": code,
                    "code_verifier": verifier, "redirect_uri": callback.redirect, "grant_type": "authorization_code"])
                if writable, let granted = reply["scope"] as? String, !granted.split(separator: " ").contains(Substring(Self.writeScope)) { throw GoogleFailure(message: "Google Drive write permission was not granted.") }
                guard let refresh = reply["refresh_token"] as? String, !refresh.isEmpty else { throw GoogleFailure(message: "Google did not return offline access. Please reconnect.") }
                try self.finishAuthorization(Credentials(clientID: client, clientSecret: secret, refreshToken: refresh, writable: writable), reply: reply, identifier: identifier)
                completion(.success(()))
            } catch {
                self.lock.lock()
                if self.authorizationID == identifier { self.listener = nil; self.authorizationID = nil }
                self.lock.unlock()
                completion(.failure(error))
            }
        }
        return components.url!
    }
    var canWrite: Bool {
        lock.lock(); defer { lock.unlock() }
        return connected && (try? credentials())?.writable == true
    }
    var publicClientID: String? {
        lock.lock(); defer { lock.unlock() }
        guard let saved = try? credentials(), saved.clientSecret == nil else { return nil }
        return saved.clientID
    }

    func beginBuiltInAuthorization(present: GoogleAuthPresenter, clientID: String = GoogleAuth.builtInClientID, writable: Bool = false,
                                   completion: @escaping (Result<Void, Error>) -> Void) throws {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix), !clientID.dropLast(suffix.count).isEmpty,
              clientID.unicodeScalars.allSatisfy({ GoogleHTTP.unreserved.contains($0) }) else {
            throw GoogleFailure(message: "The app's Google client ID has not been configured.")
        }
        cancelAuthorization()
        let state = try Self.random(), verifier = try Self.random(), identifier = UUID()
        let scheme = "com.googleusercontent.apps." + clientID.dropLast(suffix.count)
        let redirect = scheme + ":/oauth2redirect"
        lock.lock(); authorizationID = identifier; presenter = present; lock.unlock()
        var address = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        address.queryItems = ["client_id": clientID, "redirect_uri": redirect, "response_type": "code",
            "scope": writable ? Self.writeScope : Self.scope, "access_type": "offline", "prompt": "consent", "state": state,
            "code_challenge_method": "S256", "code_challenge": Self.base64(Data(SHA256.hash(data: Data(verifier.utf8))))]
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        present.start(address.url!, scheme: String(scheme)) { result in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let callback = try result.get()
                    guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
                          parts.scheme == scheme, parts.host == nil, parts.path == "/oauth2redirect" else {
                        throw GoogleFailure(message: "Invalid Google sign-in callback.")
                    }
                    var fields: [String: String] = [:]
                    for item in parts.queryItems ?? [] {
                        guard fields[item.name] == nil else { throw GoogleFailure(message: "Invalid Google sign-in callback.") }
                        fields[item.name] = item.value ?? ""
                    }
                    guard fields["state"] == state else { throw GoogleFailure(message: "Google sign-in state did not match.") }
                    if let error = fields["error"] {
                        throw GoogleFailure(message: error == "admin_policy_enforced" ? "Your Google administrator blocked this app." : "Google sign-in was denied or cancelled.")
                    }
                    guard let code = fields["code"], !code.isEmpty else { throw GoogleFailure(message: "Google sign-in returned no authorization code.") }
                    self.lock.lock(); let current = self.authorizationID == identifier; self.lock.unlock()
                    guard current else { throw GoogleFailure(message: "Google sign-in was cancelled.") }
                    let reply = try self.token(["client_id": clientID, "code": code, "code_verifier": verifier,
                        "redirect_uri": redirect, "grant_type": "authorization_code"])
                    if writable, let granted = reply["scope"] as? String, !granted.split(separator: " ").contains(Substring(Self.writeScope)) { throw GoogleFailure(message: "Google Drive write permission was not granted.") }
                guard let refresh = reply["refresh_token"] as? String, !refresh.isEmpty else { throw GoogleFailure(message: "Google did not return offline access. Please reconnect.") }
                    try self.finishAuthorization(Credentials(clientID: clientID, clientSecret: nil, refreshToken: refresh, writable: writable), reply: reply, identifier: identifier)
                    completion(.success(()))
                } catch {
                    self.lock.lock()
                    if self.authorizationID == identifier { self.authorizationID = nil; self.presenter = nil }
                    self.lock.unlock()
                    completion(.failure(error))
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
            self.lock.lock(); let current = self.authorizationID == identifier; self.lock.unlock()
            if current { self.cancelAuthorization() }
        }
    }

    private func finishAuthorization(_ credentials: Credentials, reply: [String: Any], identifier: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard authorizationID == identifier else { throw GoogleFailure(message: "Google sign-in was cancelled.") }
        try store.save(JSONEncoder().encode(credentials))
        remember(reply)
        version += 1
        listener = nil; presenter = nil; authorizationID = nil
    }
    func cancelAuthorization() {
        lock.lock(); defer { lock.unlock() }
        let previous = presenter; presenter = nil
        listener?.cancel(); listener = nil; authorizationID = nil
        previous?.cancel()
    }
    private func token(_ fields: [String: String]) throws -> [String: Any] {
        let reply = try GoogleHTTP.send(Self.tokenURL, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: GoogleHTTP.form(fields))
        let json = (try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any]) ?? [:]
        if json["error"] as? String == "invalid_grant", fields["grant_type"] == "refresh_token" {
            if var previous = try credentials() { previous.refreshToken = nil; try store.save(JSONEncoder().encode(previous)) }
            access = nil; expires = .distantPast; version += 1
            throw GoogleFailure(message: "Google login expired or was revoked. Reconnect Google Drive.")
        }
        guard reply.status == 200, let value = json["access_token"] as? String, !value.isEmpty else {
            throw GoogleFailure(message: "Google sign-in or token refresh failed.", status: reply.status)
        }
        if let granted = json["scope"] as? String, Set(granted.split(separator: " ").map(String.init)).isDisjoint(with: [Self.scope, Self.writeScope]) {
            throw GoogleFailure(message: "Google Drive read-only permission was not granted.")
        }
        return json
    }
    private func remember(_ reply: [String: Any]) {
        access = reply["access_token"] as? String
        expires = Date().addingTimeInterval((reply["expires_in"] as? NSNumber)?.doubleValue ?? 3600)
    }
    func accessToken(forceRefresh: Bool = false) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let saved = try credentials(), let refresh = saved.refreshToken else { throw GoogleFailure(message: "Google Drive is not connected. Sign in first.") }
        if !forceRefresh, let access, expires.timeIntervalSinceNow > 60 { return access }
        var fields = ["client_id": saved.clientID, "refresh_token": refresh, "grant_type": "refresh_token"]
        if let secret = saved.clientSecret { fields["client_secret"] = secret }
        let reply = try token(fields)
        var updated = saved
        if let granted = reply["scope"] as? String, !granted.split(separator: " ").contains(Substring(Self.writeScope)) { updated.writable = false }
        if let rotated = reply["refresh_token"] as? String { updated.refreshToken = rotated }
        try store.save(JSONEncoder().encode(updated))
        remember(reply)
        return access!
    }
    func disconnect() throws {
        cancelAuthorization()
        lock.lock(); defer { lock.unlock() }
        let saved = try credentials(), token = saved?.refreshToken ?? access
        try store.clear(); access = nil; expires = .distantPast; version += 1
        if let token {
            let reply = try GoogleHTTP.send(Self.revokeURL, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: GoogleHTTP.form(["token": token]))
            guard reply.status == 200 else { throw GoogleFailure(message: "Disconnected locally; Google revocation failed. Remove access in your Google account if needed.") }
        }
    }
}

// A one-shot loopback receiver. Binds only IPv4 localhost, on a random OS-assigned port unless one is asked for
// (remote MCP sign-in reuses the port its client was registered with). `label` names the service in messages.
final class GoogleLoopback {
    private let fd: Int32
    private let lock = NSLock()
    private var cancelled = false
    private let label: String
    let redirect: String
    init(port: UInt16 = 0, label: String = "Google") throws {
        signal(SIGPIPE, SIG_IGN)
        self.label = label
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        fd = descriptor
        guard descriptor >= 0 else { throw GoogleFailure(message: "Could not open the \(label) sign-in callback.") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var reuse: Int32 = 1   // a fixed port may still be in TIME_WAIT from the last sign-in
        if port != 0 { _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard bound == 0, named == 0, Darwin.listen(fd, 4) == 0 else { close(fd); throw GoogleFailure(message: "Could not listen for \(label) sign-in.") }
        redirect = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/"
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func start(_ completion: @escaping (Result<[String: String], Error>) -> Void) {
        Thread.detachNewThread {
            var listening = true
            defer { if listening { close(self.fd) } }
            let deadline = Date().addingTimeInterval(300)
            var ready = false
            while Date() < deadline {
                self.lock.lock(); let cancelled = self.cancelled; self.lock.unlock()
                if cancelled { completion(.failure(GoogleFailure(message: "\(self.label) sign-in was cancelled."))); return }
                var descriptor = pollfd(fd: self.fd, events: Int16(POLLIN), revents: 0)
                let result = poll(&descriptor, 1, 100)
                if result > 0 { ready = true; break }
                if result < 0 { break }
            }
            guard ready else { completion(.failure(GoogleFailure(message: "\(self.label) sign-in timed out."))); return }
            let client = accept(self.fd, nil, nil)
            guard client >= 0 else { completion(.failure(GoogleFailure(message: "\(self.label) sign-in was cancelled."))); return }
            defer { close(client) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var bytes = [UInt8](repeating: 0, count: 16384)
            let count = read(client, &bytes, bytes.count)
            guard count > 0, let line = String(decoding: bytes.prefix(count), as: UTF8.self).components(separatedBy: "\r\n").first,
                  line.hasPrefix("GET "), let target = line.split(separator: " ").dropFirst().first,
                  let components = URLComponents(string: "http://127.0.0.1" + target) else {
                completion(.failure(GoogleFailure(message: "Invalid \(self.label) sign-in callback."))); return
            }
            var fields: [String: String] = [:]
            for item in components.queryItems ?? [] {
                guard fields[item.name] == nil else { completion(.failure(GoogleFailure(message: "Invalid \(self.label) sign-in callback."))); return }
                fields[item.name] = item.value ?? ""
            }
            let body = "\(self.label) sign-in response received. You may close this window. / \(self.label) 로그인 응답을 받았습니다. 이 창을 닫아도 됩니다."
            let data = Data(body.utf8)
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
            (Data(response.utf8) + data).withUnsafeBytes { raw in _ = write(client, raw.baseAddress, raw.count) }
            close(self.fd); listening = false
            completion(.success(fields))
        }
    }
}
