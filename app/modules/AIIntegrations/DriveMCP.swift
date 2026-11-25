import Foundation

// Drive through Google's Workspace MCP servers (GoogleAuth.workspaceMCP): the same tools, gate, checks and answers as
// the REST requests in DriveLink.swift; only how each answer is fetched differs. Google's MCP File has one parentId,
// title and viewUrl: restFile gives it REST's names, so the gate and what the models read stay the same.
extension DriveLink {
    static var usesMCP: Bool { GoogleAuth.workspaceMCP }
    // One base64 request (no resumable upload) whose size limit Google does not document.
    static let maxMCPUpload = 30 * 1024 * 1024
    static var userinfoURL = URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!

    // The approval card of the call this thread runs (perform sets it; the picker and the names refresh have none).
    final class Approver {
        let tool: String, ask: (DriveApproval) -> DriveApproval.Answer
        init(tool: String, ask: @escaping (DriveApproval) -> DriveApproval.Answer) { self.tool = tool; self.ask = ask }
    }

    func mcp(_ server: String, _ name: String, _ arguments: [String: Any], limit: Int = MCPHTTP.limit, check: () throws -> Void = {}) throws -> [String: Any] {
        let approver = Thread.current.threadDictionary["illuminatiDriveApprover"] as? Approver
        return try GoogleMCP(auth: auth, tool: approver?.tool ?? name, approve: approver?.ask ?? { _ in .deny })
            .call(server, name, arguments, limit: limit, check: check)
    }
    func mcpData(_ server: String, _ name: String, _ arguments: [String: Any], check: () throws -> Void = {}) throws -> [String: Any] {
        GoogleMCP.structured(try mcp(server, name, arguments, check: check))
    }

    /// Google's MCP File in REST's field names.
    static func restFile(_ file: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        out["id"] = file["id"]; out["name"] = file["title"]; out["mimeType"] = file["mimeType"]; out["modifiedTime"] = file["modifiedTime"]
        out["webViewLink"] = file["viewUrl"]; out["size"] = file["fileSize"]; out["trashed"] = file["trashed"]; out["etag"] = file["etag"]
        if let parent = file["parentId"] as? String, !parent.isEmpty { out["parents"] = [parent] }
        if let owner = file["ownerName"] ?? file["owner"] { out["owners"] = [["displayName": owner]] }
        if let target = (file["shortcutDetails"] as? [String: Any])?["targetFileId"] { out["shortcutDetails"] = ["targetId": target] }
        return out.filter { !($0.value is NSNull) }
    }
    func mcpMetadata(_ id: String) throws -> [String: Any] {
        let file = try mcpData("drivemcp", "get_file_metadata", ["fileId": id, "excludeContentSnippets": true])
        guard file["id"] != nil else { throw GoogleFailure(message: "Google Drive file was not found or this account cannot access it.", status: 404) }
        return Self.restFile(file)
    }
    /// One page of search_files, folders first and by name (Google orders by relevance; REST asked for folder,name).
    func mcpFiles(_ query: String, limit: Int, page: String?) throws -> [String: Any] {
        var arguments: [String: Any] = ["query": query, "pageSize": min(100, max(1, limit)), "excludeContentSnippets": true]
        if let page { arguments["pageToken"] = page }
        let found = try mcpData("drivemcp", "search_files", arguments)
        var seen = Set<String>()
        let files = (found["files"] as? [[String: Any]] ?? []).map(Self.restFile).filter { seen.insert($0["id"] as? String ?? "").inserted }
            .sorted { a, b in
                let folder = "application/vnd.google-apps.folder"
                let (fa, fb) = (a["mimeType"] as? String == folder, b["mimeType"] as? String == folder)
                if fa != fb { return fa }
                return (a["name"] as? String ?? "").localizedStandardCompare(b["name"] as? String ?? "") == .orderedAscending
            }
        var result: [String: Any] = ["files": files]
        if let next = found["nextPageToken"] as? String, !next.isEmpty { result["nextPageToken"] = next }
        return result
    }

    func mcpPresentation(_ id: String, fields: [String]? = nil) throws -> [String: Any] {
        var arguments: [String: Any] = ["presentationId": id]
        if let fields { arguments["fields"] = fields }
        let answer = try mcpData("slidesmcp", "read_presentation", arguments)
        return answer["content"] as? [String: Any] ?? answer
    }
    func mcpDocumentRevision(_ id: String) -> String? {
        guard let answer = try? mcpData("docsmcp", "read_doc", ["documentId": id]) else { return nil }
        return (answer["content"] as? [String: Any])?["revisionId"] as? String ?? answer["revisionId"] as? String
    }

    /// A file's text as Google's read_file_content gives it (Docs, Slides, PDF, Office, text); Sheets by tab.
    func mcpText(_ id: String, mime: String, arguments: [String: Any]) throws -> (text: String, note: String, extra: [String: Any]) {
        if mime == types["sheet"]! {
            let book = try mcpData("sheetsmcp", "get_spreadsheet", ["spreadsheetId": id, "fields": ["sheets.properties.title", "sheets.properties.index"]])
            let content = book["content"] as? [String: Any] ?? book
            let tabs = (content["sheets"] as? [[String: Any]] ?? []).compactMap { $0["properties"] as? [String: Any] }
                .sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }.compactMap { $0["title"] as? String }
            guard let tab = arguments["sheet"] as? String ?? tabs.first, tabs.contains(tab) else { throw GoogleFailure(message: "Sheet tab not found. Read without sheet to list tab names.") }
            let values = try mcpData("sheetsmcp", "get_values", ["spreadsheetId": id, "range": "'" + tab.replacingOccurrences(of: "'", with: "''") + "'"])
            let rows = values["values"] as? [[Any]] ?? ((values["content"] as? [String: Any])?["values"] as? [[Any]] ?? [])
            return (rows.map { $0.map { String(describing: $0) }.joined(separator: "\t") }.joined(separator: "\n"),
                    "Values from this tab only; use sheet to read another listed tab.", ["sheets": tabs, "sheet": tab])
        }
        guard !mime.hasPrefix("application/vnd.google-apps.") || [types["doc"]!, types["slides"]!].contains(mime) else {
            throw GoogleFailure(message: "This file format is not supported for text reading.")
        }
        let file = try mcpData("drivemcp", "read_file_content", ["fileId": id])
        guard let text = file["fileContent"] as? String else { throw GoogleFailure(message: "Google returned no text for this file.") }
        let note = mime == types["doc"]! ? "" : mime == types["slides"]! ? "Text as Google reads it; images, layout and speaker notes are not interpreted."
            : "Text as Google extracts it; layout and embedded images are not interpreted, and very large files may be incomplete."
        return (text, note, [:])
    }

    /// A file's bytes (export: a Google file in that format), bounded like REST's download.
    func mcpDownload(_ id: String, export: String?) throws -> Data {
        var arguments: [String: Any] = ["fileId": id]
        if let export { arguments["exportMimeType"] = export }
        let cap = export == nil ? Self.maxDownload : Self.maxExport
        let result = try mcp("drivemcp", "download_file_content", arguments, limit: cap / 3 * 4 + (1 << 20))
        guard let data = GoogleMCP.bytes(result) else { throw GoogleFailure(message: "Google returned no file content.") }
        guard data.count <= cap else { throw GoogleFailure(message: "Drive file exceeds the \(cap >> 20) MB download limit.") }
        return data
    }

    // Folders for the picker ("root" = My Drive, "shared" = Shared with me), by name.
    func mcpChildFolders(of parent: String) throws -> [DriveFolder] {
        let scope = parent == "shared" ? "sharedWithMe = true" : "parentId = '\(escape(parent))'"
        var result: [DriveFolder] = [], page: String?, seen = Set<String>()
        repeat {
            let found = try mcpFiles(scope + " and mimeType = '\(types["folder"]!)' and trashed = false", limit: 100, page: page)
            for entry in found["files"] as? [[String: Any]] ?? [] {
                guard let id = entry["id"] as? String, let name = entry["name"] as? String, !result.contains(where: { $0.id == id }) else { continue }
                result.append(DriveFolder(id: id, name: name))
            }
            page = found["nextPageToken"] as? String
            if let page, !seen.insert(page).inserted { throw GoogleFailure(message: "Google repeated a folder page. Try again.") }
        } while page != nil && seen.count < 50
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // The signed-in account from OpenID (MCP has no Drive about); shown in the app only.
    func mcpAccountEmail() -> String? {
        guard let token = try? auth.accessToken(), let reply = try? GoogleHTTP.send(Self.userinfoURL, headers: ["Authorization": "Bearer " + token]),
              reply.status == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any])?["email"] as? String
    }
}
