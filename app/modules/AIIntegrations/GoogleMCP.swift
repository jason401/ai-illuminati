import Foundation

/// A question Google's Workspace MCP server asks before it runs a tool (form elicitation), as the app's approval
/// card shows it: Allow is Google's one-time choice, Always allow its lasting one when it offers one.
public struct DriveApproval {
    public enum Answer { case once, always, deny }
    public let tool: String          // the app's tool, e.g. drive_upload
    public let message: String       // Google's words
    public let choices: [String]     // every choice Google offered, for the card's detail
    public let offersAlways: Bool
}

// Google's Workspace MCP servers (drivemcp, docsmcp, slidesmcp, sheetsmcp; protocol 2026-07-28, no session): the app is
// the client with the Google login's token, so the CLIs never see these servers or the token. A tool that needs the
// user's yes comes back input_required; the same call is sent again with the user's answer and Google's requestState.
struct GoogleMCP {
    static var address: (String) -> URL = { URL(string: "https://\($0).googleapis.com/mcp/v1")! }
    static let version = "2026-07-28"
    static let meta: [String: Any] = ["io.modelcontextprotocol/protocolVersion": version,
                                      "io.modelcontextprotocol/clientInfo": RemoteMCPSession.clientInfo,
                                      "io.modelcontextprotocol/clientCapabilities": ["elicitation": ["form": [:] as [String: Any]]]]
    let auth: GoogleAuth
    let tool: String
    let approve: (DriveApproval) -> DriveApproval.Answer

    /// One tools/call; its result, or GoogleFailure (Google's own error text, bounded). `check` runs right before
    /// every send, the resend after an approval too, so a permission changed meanwhile stops it.
    func call(_ server: String, _ name: String, _ arguments: [String: Any], limit: Int = MCPHTTP.limit, check: () throws -> Void = {}) throws -> [String: Any] {
        var extra: [String: Any] = [:], refreshed = false, rounds = 0
        while true {
            try check()
            let token = try auth.accessToken(forceRefresh: refreshed)
            var params: [String: Any] = ["name": name, "arguments": arguments, "_meta": Self.meta]
            params.merge(extra) { $1 }
            let id = Int.random(in: 1...Int(Int32.max))
            let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": params])
            let headers = ["Content-Type": "application/json", "Accept": "application/json, text/event-stream", "Authorization": "Bearer " + token,
                           "MCP-Protocol-Version": Self.version, "Mcp-Method": "tools/call", "Mcp-Name": RemoteMCPSession.headerValue(name)]
            let reply: MCPHTTP.Reply
            do { reply = try MCPHTTP.send(Self.address(server), headers: headers, body: body, wanted: id, timeout: try Self.remaining(), limit: limit) }
            catch let error as MCPSession.Failure { throw GoogleFailure(message: "Google \(server): " + error.message) }
            if reply.status == 401 && !refreshed { refreshed = true; continue }
            guard (200..<300).contains(reply.status) else {
                switch reply.status {
                case 401: throw GoogleFailure(message: "Google rejected this login. Reconnect Google Drive.", status: 401)
                case 429: throw GoogleFailure(message: "Google's MCP quota or rate limit was reached. Try again later.", status: 429)
                default: throw GoogleFailure(message: "Google \(server) failed (HTTP \(reply.status)).", status: reply.status)
                }
            }
            guard let message = reply.messages.first(where: { ($0["id"] as? NSNumber)?.intValue == id && $0["method"] == nil }) else {
                throw GoogleFailure(message: "Google \(server) returned no answer.")
            }
            if let error = message["error"] as? [String: Any] { throw GoogleFailure(message: Self.explain(error["message"] as? String ?? "error", server)) }
            guard let result = message["result"] as? [String: Any] else { throw GoogleFailure(message: "Google \(server) returned an invalid answer.") }
            if result["resultType"] as? String == "input_required" {
                rounds += 1
                guard rounds <= 3 else { throw GoogleFailure(message: "Google kept asking for approval; nothing more was sent.") }
                extra = try answer(result)
                continue
            }
            if result["isError"] as? Bool == true { throw GoogleFailure(message: Self.explain(Self.text(result), server)) }
            return result
        }
    }

    // The user's answers to Google's questions: one approval card each. Declined means the request is not sent again.
    private func answer(_ result: [String: Any]) throws -> [String: Any] {
        guard let requests = result["inputRequests"] as? [String: Any], !requests.isEmpty else {
            throw GoogleFailure(message: "Google asked for input without a question; nothing more was sent.")
        }
        let unsupported = GoogleFailure(message: "Google asked a question this app cannot show; nothing more was sent.")
        var responses: [String: Any] = [:]
        for (key, value) in requests.sorted(by: { $0.key < $1.key }) {
            guard let request = value as? [String: Any], (request["method"] as? String ?? "elicitation/create") == "elicitation/create",
                  let params = request["params"] as? [String: Any], (params["mode"] as? String ?? "form") == "form",
                  let properties = (params["requestedSchema"] as? [String: Any])?["properties"] as? [String: Any], properties.count == 1,
                  let (field, raw) = properties.first, let property = raw as? [String: Any] else { throw unsupported }
            var options: [(value: String, label: String)] = []
            if let values = property["enum"] as? [String] {
                let names = property["enumNames"] as? [String] ?? []
                options = values.enumerated().map { ($0.element, $0.offset < names.count ? names[$0.offset] : $0.element) }
            } else if let list = (property["oneOf"] ?? property["anyOf"]) as? [[String: Any]] {
                options = list.compactMap { item in (item["const"] as? String).map { ($0, item["title"] as? String ?? $0) } }
            }
            let refusing = ["DENY", "REJECT", "DECLINE", "CANCEL", "NEVER"]
            let allowing = options.filter { option in !refusing.contains { option.value.uppercased().contains($0) } }
            let always = allowing.first { $0.value.uppercased().contains("ALWAYS") }
            guard let once = allowing.first(where: { $0.value.uppercased().contains("ONCE") }) ?? allowing.first(where: { !$0.value.uppercased().contains("ALWAYS") }) ?? always else { throw unsupported }
            let started = Date()
            let decision = approve(DriveApproval(tool: tool, message: String((params["message"] as? String ?? "").prefix(2000)),
                                                 choices: options.map(\.label), offersAlways: always != nil && always?.value != once.value))
            // Waiting for the user is not the request's time.
            if let deadline = Thread.current.threadDictionary["illuminatiGoogleDeadline"] as? Date {
                Thread.current.threadDictionary["illuminatiGoogleDeadline"] = deadline.addingTimeInterval(Date().timeIntervalSince(started))
            }
            let chosen: String
            switch decision {
            case .deny: throw GoogleFailure(message: "The user did not approve this Google Drive action (denied or no answer); Google did not run it. Do not retry unless the user asks.")
            case .once: chosen = once.value
            case .always: chosen = always?.value ?? once.value
            }
            responses[key] = ["action": "accept", "content": [field: chosen]]
        }
        var extra: [String: Any] = ["inputResponses": responses]
        if let state = result["requestState"] { extra["requestState"] = state }
        return extra
    }

    // Time left for one request: the call's deadline (DriveLink.perform sets 50 s), never more than a minute.
    static func remaining() throws -> TimeInterval {
        guard let deadline = Thread.current.threadDictionary["illuminatiGoogleDeadline"] as? Date else { return 50 }
        let left = deadline.timeIntervalSinceNow
        guard left > 0.5 else { throw GoogleFailure(message: "Google Drive did not answer in time. A write may still complete; check Drive before retrying.") }
        return min(60, left)
    }

    static func text(_ result: [String: Any]) -> String {
        (result["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
    }
    // Google's words, bounded, with what they usually mean for this app.
    static func explain(_ text: String, _ server: String) -> String {
        let said = String(text.prefix(300))
        if said.contains("Developer Preview") {
            return "Google has not opened its \(server) server for this Cloud project yet (it says: \(said)). Switch Google MCP off in the Drive menu until it does."
        }
        if said.lowercased().contains("does not have permission") || said.lowercased().contains("not marked as agentic") {
            return "Google refused (\(said)). The file may be inaccessible to this account, or Google's MCP server is not open yet for this account or its OAuth client (it must be marked as an AI-powered agent)."
        }
        return "Google: " + said
    }

    /// The tool's structured answer: structuredContent, else JSON in its text.
    static func structured(_ result: [String: Any]) -> [String: Any] {
        if let value = result["structuredContent"] as? [String: Any] { return value }
        for item in result["content"] as? [[String: Any]] ?? [] where item["type"] as? String == "text" {
            if let text = item["text"] as? String, let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { return value }
        }
        return [:]
    }

    /// A download's bytes: an embedded resource's blob, or base64 in the structured answer or the text.
    static func bytes(_ result: [String: Any]) -> Data? {
        let items = result["content"] as? [[String: Any]] ?? []
        for item in items {
            if let blob = (item["resource"] as? [String: Any])?["blob"] as? String, let data = Data(base64Encoded: blob) { return data }
            if ["image", "audio"].contains(item["type"] as? String ?? ""), let blob = item["data"] as? String, let data = Data(base64Encoded: blob) { return data }
        }
        let value = structured(result)
        for key in ["base64Content", "content", "data", "fileContent"] {
            if let text = value[key] as? String, let data = Data(base64Encoded: text) { return data }
        }
        for item in items where item["type"] as? String == "text" {
            if let text = item["text"] as? String, let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) { return data }
        }
        return nil
    }
}
