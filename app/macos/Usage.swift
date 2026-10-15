import Foundation
import Security

// One usage window (5 hours or 7 days) as the AI's own service reports it.
struct UsageWindow {
    var usedPercent: Double
    var resetsAt: Date?

    // If the reset time has already passed, the window started over: nothing is used.
    func used(now: Date = Date()) -> Double {
        if let r = resetsAt, r <= now { return 0 }
        return min(max(usedPercent, 0), 100)
    }
    func left(now: Date = Date()) -> Double { 100 - used(now: now) }
}

struct AIUsage {
    let name: String
    var account: Account?
    var fiveHour: UsageWindow?
    var weekly: UsageWindow?
    var checkedAt: Date?      // when the numbers were measured
    var detail: String?       // e.g. "me@example.com · plus"
    var note: String?         // why there are no numbers, shown in the menu
    var extras: [String] = [] // more limits, already worded for the menu
    var needsLogin = false

    init(name: String, account: Account? = nil) {
        self.name = name
        self.account = account
    }

    // What actually limits you right now: the smaller of the two "left" values.
    var leftNow: Double? {
        let values = [fiveHour, weekly].compactMap { $0?.left() }
        return values.min()
    }
}

// MARK: - Codex

// Asks Codex itself: `codex app-server` (the same local protocol the ChatGPT app uses) answers
// account/rateLimits/read (5 hours = primary, 7 days = secondary) and account/read (email, plan).
// Runs once per account with CODEX_HOME set to that account's folder.
enum CodexUsage {
    private static var cache: [String: (AIUsage, Date)] = [:]

    static var binary: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func forget(_ account: Account) { cache[account.id] = nil }

    static func read(_ account: Account) -> AIUsage {
        if let (cached, at) = cache[account.id], Date().timeIntervalSince(at) < 120 { return cached }
        var result = AIUsage(name: account.name, account: account)
        guard FileManager.default.fileExists(atPath: account.codexHome + "/auth.json") else {
            result.needsLogin = true
            result.note = "로그인이 필요해요"
            return result
        }
        guard let binary else {
            result.note = "Codex 프로그램을 찾지 못했어요 (ChatGPT 앱이 필요해요)"
            return result
        }
        guard let replies = askAppServer(binary: binary, account: account) else {
            result.note = "Codex에서 답이 없어요"
            return result
        }
        if let accountInfo = replies[3] as? [String: Any] {
            if let info = accountInfo["account"] as? [String: Any] {
                result.detail = [info["email"] as? String, info["planType"] as? String]
                    .compactMap { $0 }.joined(separator: " · ")
            } else {
                result.needsLogin = true
                result.note = "로그인이 풀렸어요"
                return result
            }
        }
        if let limits = (replies[2] as? [String: Any])?["rateLimits"] as? [String: Any] {
            result.fiveHour = window(limits["primary"])
            result.weekly = window(limits["secondary"])
            result.checkedAt = Date()
        }
        if result.fiveHour == nil && result.weekly == nil { result.note = "사용량을 가져오지 못했어요" }
        cache[account.id] = (result, Date())
        return result
    }

    private static func window(_ value: Any?) -> UsageWindow? {
        guard let dict = value as? [String: Any], let used = dict["usedPercent"] as? NSNumber else { return nil }
        let reset = (dict["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return UsageWindow(usedPercent: used.doubleValue, resetsAt: reset)
    }

    // Sends the requests, waits up to 20 s for answers 2 and 3, then stops the server.
    // Returns each answer's "result" by request id.
    private static func askAppServer(binary: String, account: Account) -> [Int: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server"]
        process.environment = account.environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let lock = NSLock()
        var buffer = Data()
        var results: [Int: Any] = [:]
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); defer { lock.unlock() }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   let id = json["id"] as? Int {
                    results[id] = json["result"] ?? NSNull()
                }
            }
        }
        do { try process.run() } catch { return nil }
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"ai-illuminati","version":"0.1"}}}"#,
            #"{"jsonrpc":"2.0","method":"initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"account/read","params":{}}"#,
        ]
        input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))

        let deadline = Date().addingTimeInterval(20)
        var done = false
        while !done && Date() < deadline && process.isRunning {
            Thread.sleep(forTimeInterval: 0.1)
            lock.lock(); done = results[2] != nil && results[3] != nil; lock.unlock()
        }
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        lock.lock(); defer { lock.unlock() }
        return results.isEmpty ? nil : results
    }
}

// MARK: - Claude

// Claude Code keeps each account's login in the Keychain (see Account.claudeKeychainService).
// We read it (read only, never change it) and ask Anthropic's usage page. That page is not
// documented and may change; any failure just shows "?". When the saved login has expired we let
// Claude Code renew it itself (`claude auth status`) instead of touching it.
enum ClaudeUsage {
    private static var cache: [String: (AIUsage, Date)] = [:]
    private static var waitUntil: [String: Date] = [:]
    private static var lastRenew: [String: Date] = [:]

    static var binary: String? {
        let path = FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/claude"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static func forget(_ account: Account) { cache[account.id] = nil }

    static func read(_ account: Account) -> AIUsage {
        var result = AIUsage(name: account.name, account: account)
        if let (cached, at) = cache[account.id], Date().timeIntervalSince(at) < 120 { return cached }
        if let wait = waitUntil[account.id], wait > Date() {
            result.note = "잠시 후 다시 확인해요"
            return cache[account.id]?.0 ?? result
        }
        guard loginExists(account) else {
            result.needsLogin = true
            result.note = "로그인이 필요해요"
            return result
        }
        var token = accessToken(account)
        if token == nil, let binary, Date().timeIntervalSince(lastRenew[account.id] ?? .distantPast) > 600 {
            lastRenew[account.id] = Date()
            renew(binary: binary, account: account)
            token = accessToken(account)
        }
        guard let token else {
            result.note = "로그인이 만료됐어요 (다시 로그인하면 돌아와요)"
            return result
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (data, status) = syncFetch(request) else {
            result.note = "사용량을 가져오지 못했어요"
            return result
        }
        if status == 429 {
            waitUntil[account.id] = Date().addingTimeInterval(600)
            result.note = "잠시 후 다시 확인해요"
            return cache[account.id]?.0 ?? result
        }
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            result.note = "사용량을 가져오지 못했어요 (\(status))"
            return result
        }
        // Keep the last reply (usage numbers only, no login data) for checking what a plan reports.
        try? data.write(to: URL(fileURLWithPath: AccountStore.supportDir + "/last-usage-\(account.id).json"))
        result.fiveHour = window(json["five_hour"])
        result.weekly = window(json["seven_day"])
        // "limits" is the list Claude shows on its own usage screen, and differs by plan (a school
        // plan has no overall weekly limit but a weekly one for Cowork). Use it when present.
        if let limits = json["limits"] as? [[String: Any]], !limits.isEmpty {
            result.fiveHour = nil
            result.weekly = nil
            for limit in limits {
                guard let used = limit["percent"] as? NSNumber else { continue }
                let w = UsageWindow(usedPercent: used.doubleValue,
                                    resetsAt: (limit["resets_at"] as? String).flatMap(parseISODate))
                let kind = limit["kind"] as? String ?? ""
                let scope = limit["scope"] as? [String: Any]
                let scopeName = ((scope?["surface"] as? [String: Any])?["display_name"] as? String)
                    ?? ((scope?["model"] as? [String: Any])?["display_name"] as? String)
                    ?? (scope?["model"] as? String)
                if kind == "session" {
                    result.fiveHour = w
                } else if kind == "weekly_all" {
                    result.weekly = w
                } else if limit["group"] as? String == "weekly" {
                    result.extras.append("주간(\(scopeName ?? kind)): " + describeLeft(w))
                }
            }
        }
        result.checkedAt = Date()
        if result.fiveHour == nil && result.weekly == nil { result.note = "사용량 형식을 읽지 못했어요" }
        cache[account.id] = (result, Date())
        return result
    }

    // Asking only for the item's attributes does not show a Keychain prompt.
    static func loginExists(_ account: Account) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: account.claudeKeychainService,
                                    kSecReturnAttributes as String: true]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    // Reading the secret itself asks once per account ("Always Allow").
    private static func accessToken(_ account: Account) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: account.claudeKeychainService,
                                    kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        if let expires = oauth["expiresAt"] as? Double, expires / 1000 < Date().timeIntervalSince1970 + 60 { return nil }
        return token
    }

    // Claude Code checks (and, if needed, renews) its own login. Waits up to 30 s.
    private static func renew(binary: String, account: Account) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["auth", "status", "--json"]
        process.environment = account.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if process.isRunning { process.terminate() }
    }

    private static func window(_ value: Any?) -> UsageWindow? {
        guard let dict = value as? [String: Any], let used = dict["utilization"] as? Double else { return nil }
        return UsageWindow(usedPercent: used, resetsAt: (dict["resets_at"] as? String).flatMap(parseISODate))
    }

    private static func syncFetch(_ request: URLRequest) -> (Data, Int)? {
        let done = DispatchSemaphore(value: 0)
        var result: (Data, Int)?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, let http = response as? HTTPURLResponse { result = (data, http.statusCode) }
            done.signal()
        }.resume()
        done.wait()
        return result
    }
}

// MARK: - Gemini

// Antigravity CLI (agy): `agy -p /usage` prints one tab-separated line per limit, e.g.
//   Gemini Models <TAB> Weekly Limit Remaining <TAB> 97% <TAB> 2026-10-22T04:05:05Z
// The "Gemini Models" lines are this row's gauge; other model groups are listed underneath.
// The login email comes from agy's logs ("applyAuthResult: email=..." each start).
enum GeminiUsage {
    private static var cache: (AIUsage, Date)?

    static func read() -> AIUsage {
        if let (cached, at) = cache, Date().timeIntervalSince(at) < 300 { return cached }
        var result = AIUsage(name: "Gemini")
        guard Login.agyInstalled else {
            result.needsLogin = true
            result.note = "Antigravity CLI(agy)가 설치돼 있지 않아요"
            return result
        }
        guard let email = loggedInEmail() else {
            result.needsLogin = true
            result.note = "로그인이 필요해요"
            return result
        }
        result.detail = email
        guard let output = runUsage() else {
            result.note = "agy에서 사용량을 가져오지 못했어요"
            return result
        }
        for line in output.split(separator: "\n") {
            let cols = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 3, let left = Double(cols[2].replacingOccurrences(of: "%", with: "")) else { continue }
            let reset = cols.count >= 4 ? parseISODate(cols[3]) : nil
            let window = UsageWindow(usedPercent: 100 - left, resetsAt: reset)
            let weekly = cols[1].localizedCaseInsensitiveContains("week")
            if cols[0].localizedCaseInsensitiveContains("gemini") {
                if weekly { result.weekly = window } else { result.fiveHour = window }
            } else {
                let group = cols[0].replacingOccurrences(of: " and ", with: "·")
                result.extras.append("\(group) \(weekly ? "주간" : "5시간"): " + describeLeft(window))
            }
        }
        if result.fiveHour == nil && result.weekly == nil {
            result.note = "사용량 형식을 읽지 못했어요"
            return result
        }
        result.checkedAt = Date()
        cache = (result, Date())
        return result
    }

    // Runs `agy -p /usage` (answered by agy itself, not by a model) with a 40 s limit.
    private static func runUsage() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Login.home + "/.local/bin/agy")
        process.arguments = ["-p", "/usage", "--print-timeout", "40s"]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "GEMINI_API_KEY")
        env.removeValue(forKey: "GOOGLE_API_KEY")
        process.environment = env
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(45)
        var data = Data()
        let reader = DispatchQueue(label: "agy-usage")
        let done = DispatchSemaphore(value: 0)
        reader.async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func loggedInEmail() -> String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.path + "/.gemini/antigravity-cli/log"
        let logs = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasPrefix("cli-") && $0.hasSuffix(".log") }
            .sorted(by: >)
        for log in logs {
            guard let text = try? String(contentsOfFile: dir + "/" + log, encoding: .utf8) else { continue }
            if let range = text.range(of: "applyAuthResult: email=", options: .backwards) {
                let email = text[range.upperBound...].prefix { $0 != "," && !$0.isWhitespace }
                if !email.isEmpty { return String(email) }
            }
        }
        return nil
    }
}

// "62% 남음 · 10/20 (화) 오전 8:59 리셋"
func describeLeft(_ w: UsageWindow) -> String {
    var text = "\(Int(w.left().rounded()))% 남음"
    if let r = w.resetsAt {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = Calendar.current.isDateInToday(r) ? "a h:mm" : "M/d (E) a h:mm"
        text += r <= Date() ? " · 이미 리셋됨" : " · \(f.string(from: r)) 리셋"
    } else if w.usedPercent == 0 {
        text += " · 아직 안 씀"
    }
    return text
}

func parseISODate(_ text: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
}
