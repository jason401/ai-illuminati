import Foundation

// AI Face (a separate menu bar app) shows a face for each AI reply. When the user connects AI Illuminati
// in AI Face, AI Face writes its MCP server into mcp.json in our data folder (the same shape as Claude
// desktop's config) and removes it on Disconnect. Plain chat then gives the answering AI that server with
// the name "illuminati", so AI Face sees AI Illuminati as its own AI app whichever model answers.
// Only set_expression is allowed. The agreement between the two apps is docs/AI_FACE.md.
enum FaceLink {
    struct Server: Equatable { var command: String; var args: [String] }

    static let name = "ai-face", agent = "illuminati", tool = "set_expression"
    static var file = URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("mcp.json")
    // The server must be AI Face's own file; anything else in mcp.json is ignored.
    static var faceFolder = AccountStore.home + "/Library/Application Support/AI Face"

    static func server() -> Server? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = (json["mcpServers"] as? [String: Any])?[name] as? [String: Any],
              let command = entry["command"] as? String, command.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: command),
              let args = entry["args"] as? [String], let script = args.first else { return nil }
        let folder = URL(fileURLWithPath: faceFolder).standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = URL(fileURLWithPath: script).standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(folder), FileManager.default.fileExists(atPath: path) else { return nil }
        return Server(command: command, args: args)
    }

    // Called before the reply: the chat shows the AI's last message, and text written before a tool call
    // would end up in an earlier one.
    static let rule = """
        [Face] AI Face shows a small animated face for this chat. Before writing your reply, call the
        \(name) tool \(tool) once, its `emotion` set to the mood your reply will have (vary it), then write the whole reply.
        Use only a mood the tool lists, e.g. happy, talking, thinking, curious, agree, sympathy, proud, apologetic, shrug.
        Do not mention the call. If the tool is missing or fails, carry on without it.
        """
}
