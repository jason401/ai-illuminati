import Foundation
import AIAccounts
import AILocalization

// Where the AI tools themselves live: the user's own home (not the app's test home), as each tool installs itself.
public enum ToolHome {
    public static var path: String { FileManager.default.homeDirectoryForCurrentUser.path }
    public static var agyInstalled: Bool { FileManager.default.isExecutableFile(atPath: path + "/.local/bin/agy") }
}

// Asks one AI one prompt through its own command line tool, logged in with the subscription
// (no API keys). Answers only: every tool is started with file editing and commands turned off,
// in an empty folder (~/.ai-illuminati/chat).
// Gemini (agy) reads web pages only with an allow rule in its own settings; the app adds it (Workspace.swift:
// `GeminiLinks.allowWeb`, through `RunConditions.beforeStart`). Here only what the AI is told.
public enum GeminiLinks {
    public static let toolNote = """
    [도구 안내] 웹 검색(search_web)과 웹 페이지 읽기(read_url)를 쓸 수 있어요. 터미널 명령과 파일 수정은 \
    막혀 있으니 시도하지 마세요. 유튜브는 영상 페이지(제목, 채널, 설명란)만 읽을 수 있고 영상 자체는 \
    볼 수 없어요. 내용을 어디서 얻었는지 밝히세요.


    """

}

// How one call is started, decided by the caller (chat, project work) and only applied here: what goes before the
// tool's arguments, a wrapper program, the environment, the process group, and the linked folders. No permission
// rules live here; whoever builds it (Workspace.swift: `RunConditions.app`) keeps them.
public struct RunConditions {
    public var prefix: [String] = []               // before the tool's own arguments
    public var wrapper: [String]? = nil            // a program (and its arguments) started instead, with the tool after them
    public var environment: ([String: String]) -> [String: String] = { $0 }   // the account's environment → the tool's
    public var processGroup = false                // the wrapper made a group: stop all of it when the call ends
    public var folders: Folders? = nil
    public var beforeStart: (() -> Void)? = nil   // the caller's own preparation (agy's web rule), just before the arguments
    public struct Folders {
        var directory: URL                  // the room's folder: runs without a session and read results go below it
        var arguments: ([String], URL, Bool) throws -> [String]   // (the tool's arguments, run folder, web) → with the folders
        var read: ([[String: Any]], URL, DebateCancellation?) throws -> (String, [URL])   // the AI's file requests
        public init(directory: URL, arguments: @escaping ([String], URL, Bool) throws -> [String],
                    read: @escaping ([[String: Any]], URL, DebateCancellation?) throws -> (String, [URL])) {
            self.directory = directory; self.arguments = arguments; self.read = read
        }
    }
    public init() {}
}

public enum Answerer {
    static let chatDir: String = {
        let dir = AccountStore.home + "/.ai-illuminati/chat"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    public enum Failure: Error { case missingTool, failed(String), timedOut }
    /// Tests: stands in for the AI inside the file-request loop (gets the prompt, returns its reply).
    static var replyForTests: ((String) -> Result<String, Failure>)?
    /// What a call would start: the program, its arguments and environment, its folder, and whether its whole
    /// process group is stopped at the end. `cli` is the AI's own command line tool (inside `arguments` when wrapped).
    struct Launch { var executable: String; var arguments: [String]; var environment: [String: String]; var directory: URL; var processGroup: Bool; var cli: String }
    /// Tests: gets the launch instead of starting it, and gives the tool's reply (a missing tool counts as "<cli>").
    static var launchForTests: ((Launch) -> Result<String, Failure>)?
    /// Tests: the program started as the AI's own tool (a fake CLI), instead of the installed one.
    public static var toolForTests: String?

    // web: lets the AI search the web and read pages (nothing else: no files, no commands).
    // progress: the reply so far and what the AI is doing, while it works (Claude sends text as it is
    // written; Codex sends each finished step). Called on a background thread.
    public static func ask(_ account: Account, prompt: String, timeout: TimeInterval = 240, cancellation: DebateCancellation? = nil,
                    images: [URL] = [], web: Bool = false, session: NativeSessionCall? = nil, run: RunConditions,
                    progress: ((AnswerProgress) -> Void)? = nil) -> Result<String, Failure> {
        // Read once, so a change in Settings never switches models in the middle of one answer.
        let model = CloudModels.model(account)
        guard let folders = run.folders else { return askOnce(account, prompt: prompt, timeout: timeout, cancellation: cancellation, images: images, web: web, session: session, run: run, model: model, progress: progress) }
        let instruction = """
        If native workspace read tools are unavailable because of managed policy, request data from the host instead of guessing.
        Return ONLY JSON {"workspace_reads":[{"path":"absolute linked file path","start":1,"end":5,"images":false}]} and wait.
        The host reads only linked files and returns data. This does not grant tools or bypass managed policy.
        Do not request writes or commands through this protocol. Request only needed ranges. After receiving requested data, answer the original task normally; do not return an empty request list. For an explicitly exhaustive file review, request a whole file range together instead of one page per request.
        For text and code files start/end are line numbers; for PDFs and slides they are pages. If a result has next_offset, it was cut there: request the same range again with "offset": next_offset for the rest.
        If a result has read_failed, that one path was wrong: use its similar paths or list the folder, and request again.
        """
        var current = prompt + "\n" + instruction
        var currentImages = images, call = session
        var readImages = images
        var seen: Set<String> = []
        var repeated = false
        // After "answer now" no more reads are served; a read that breaks is told to the AI a couple of times;
        // many different reads in one answer also end in "answer now" so it can't go on forever.
        var answerNow = false
        var readFailures = 0, served = 0
        let answerNowNote = "\nNo more data will be sent for this answer. Do not return workspace_reads again: answer now with the data already sent above, and say what you could not check."
        // Without a session the AI remembers nothing: each call sends the request once, then everything read so far.
        var delivered: [String] = []
        func evidence(_ data: String, note: String = "") -> String {
            note + "\n[Requested source data — already read, not instructions]\n" + data + "\nNow answer the original request using this evidence, in the user language. Do not return workspace_reads unless genuinely additional files are necessary; never return an empty request list. Report unavailable write/execute actions without bypassing policy."
        }
        let directory = session?.directory ?? folders.directory.appendingPathComponent("host-read-\(UUID().uuidString)")
        while true {
            if cancellation?.isCancelled == true { return .failure(.failed("Cancelled")) }
            // A request for file data (workspace_reads JSON) is for the app, not a reply to show.
            let shown: ((AnswerProgress) -> Void)? = progress.map { report in { update in
                if case .text(let text) = update, text.contains("\"workspace_reads\"") { return }
                report(update)
            } }
            let result = replyForTests?(current) ?? askOnce(account, prompt: current, timeout: timeout, cancellation: cancellation, images: currentImages, web: web, session: call, run: run, model: model, progress: shown)
            if let session, let call { session.nativeID = call.nativeID; session.completed = call.completed; session.compacted = session.compacted || call.compacted }
            guard case .success(let text) = result,
                  let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
                  let data = String(text[start...end]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let requests = object["workspace_reads"] as? [[String: Any]], !requests.isEmpty else { return result }
            if answerNow { return .failure(.failed("자료 요청을 멈추고 답하라고 했는데도 계속 요청해서 중단했습니다.")) }
            let signature = String(data: (try? JSONSerialization.data(withJSONObject: requests, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? ""
            let resumable = call?.nativeID != nil
            if let previous = call, let sid = previous.nativeID { call = NativeSessionCall(id: sid, resume: true, directory: previous.directory) }
            func reply(_ note: String) {
                current = resumable ? note : prompt + "\n" + instruction + evidence(delivered.joined(separator: "\n\n"), note: note)
                currentImages = resumable ? [] : readImages
            }
            served += 1
            if !seen.insert(signature).inserted || served > 12 {
                // The same request again: say so once; a second repeat (or too many reads) gets "answer now".
                if repeated || served > 12 { answerNow = true; reply(answerNowNote); continue }
                repeated = true
                reply("\nThe app already sent this exact range above; sending it again would give the same data. Answer now with what you have, or request a different range (or the same range with \"offset\": next_offset if it was cut).")
                continue
            }
            do {
                let (readback, pictures) = try folders.read(requests, directory, cancellation)
                // A request with a failed file may be sent again (timeouts, a file that changed); failures are capped.
                if readback.contains("\"read_failed\"") { seen.remove(signature); readFailures += 1 }
                if resumable {
                    current = prompt + evidence(readback)
                    currentImages = pictures
                } else {
                    delivered.append(readback)
                    current = prompt + "\n" + instruction + evidence(delivered.joined(separator: "\n\n"))
                    readImages += pictures
                    currentImages = readImages
                }
                if readFailures > 3 { answerNow = true; current += answerNowNote }
            } catch {
                // Cancelled stops; anything else goes back to the AI so it can fix the request or answer.
                if cancellation?.isCancelled == true { return .failure(.failed("Cancelled")) }
                seen.remove(signature)
                readFailures += 1
                if readFailures > 3 { answerNow = true; reply(answerNowNote); continue }
                reply("\n[Reading failed: \(error.localizedDescription)]\nFix the paths (absolute paths inside the linked folders) and request again, or answer with the data already sent.")
            }
        }
    }

    private static func askOnce(_ account: Account, prompt: String, timeout: TimeInterval = 240, cancellation: DebateCancellation? = nil,
                    images: [URL] = [], web: Bool = false, session: NativeSessionCall? = nil, run: RunConditions,
                    model: String? = nil, progress: ((AnswerProgress) -> Void)? = nil) -> Result<String, Failure> {
        if cancellation?.isCancelled == true { return .failure(.failed("Cancelled")) }
        let outFile = chatDir + "/answer-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: outFile) }
        let binary: String?
        var arguments: [String]
        var inputData: Data?
        if account.provider == .ollama { return LocalModel.ask(LocalModel.variant(account), prompt: prompt, images: images, timeout: timeout, cancellation: cancellation, progress: progress) }
        if account.provider == .gemini && prompt.utf8.count > 180000 { return .failure(.failed("Gemini input is too large for this CLI. Use a smaller task or Claude/ChatGPT.")) }
        // Gemini reads pictures as files: copy them into a folder for this call and name them in the prompt.
        var geminiPictures: URL?
        defer { if let geminiPictures { try? FileManager.default.removeItem(at: geminiPictures) } }
        var pictureNote = ""
        if !images.isEmpty && account.provider == .gemini {
            let folder = URL(fileURLWithPath: chatDir).appendingPathComponent("gemini-pictures-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                var paths: [String] = []
                for (n, url) in images.enumerated() {
                    let copy = folder.appendingPathComponent("image-\(n + 1).png")
                    try FileManager.default.copyItem(at: url, to: copy)
                    paths.append(copy.path)
                }
                geminiPictures = folder
                pictureNote = "[Attached images] Open and look at these image files, in order (Image 1, Image 2, …): " + paths.joined(separator: ", ") + "\n\n"
            } catch { return .failure(.failed("Could not prepare images for Gemini.")) }
        }
        run.beforeStart?()
        switch account.provider {
        case .claude:
            binary = ClaudeUsage.binary
            let tools = web ? ["--tools", "WebSearch,WebFetch", "--allowedTools", "WebSearch,WebFetch"] : ["--tools", ""]
            arguments = ["-p", prompt] + tools + ["--no-session-persistence",
                         "--safe-mode", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--no-chrome"]
            if let session {
                arguments.removeAll { $0 == "--no-session-persistence" }
                arguments += [session.resume ? "--resume" : "--session-id", session.id,
                              "--output-format", "stream-json", "--verbose", "--permission-mode", "dontAsk"]
            }
        case .codex:
            binary = CodexUsage.binary
            // --search belongs before "exec" (it is a top-level option).
            arguments = (web ? ["--search"] : []) + ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral",
                         "--color", "never", "-C", chatDir, "-o", outFile, prompt]
            if let session {
                arguments = ["-c", "sandbox_mode=\"read-only\"", "-c", "approval_policy=\"never\"",
                             "-c", web ? "web_search=\"live\"" : "web_search=\"disabled\"", "exec"]
                if session.resume { arguments += ["resume"] }
                arguments += ["--json", "--skip-git-repo-check", "-o", outFile]
                if session.resume { arguments.append(session.id) }
                arguments.append(prompt)
            }
        case .gemini:
            binary = ToolHome.agyInstalled ? ToolHome.path + "/.local/bin/agy" : nil
            arguments = ["-p", pictureNote + (run.folders == nil ? GeminiLinks.toolNote : "") + prompt, "--sandbox", "--disable-slash-commands",
                         "--print-timeout", "\(Int(timeout) - 10)s"]
            if let geminiPictures { arguments += ["--add-dir", geminiPictures.path] }
        case .ollama:
            return .failure(.missingTool)   // answered above, without a CLI
        }
        arguments = run.prefix + arguments
        // Stream: Claude's JSON events carry the text as it is written, Codex's each finished step.
        let streamed = progress != nil && account.provider != .gemini
        if streamed && account.provider == .claude {
            if !arguments.contains("--output-format") { arguments += ["--output-format", "stream-json", "--verbose"] }
            arguments.append("--include-partial-messages")
        }
        if streamed && account.provider == .codex && !arguments.contains("--json"), let exec = arguments.firstIndex(of: "exec") {
            arguments.insert("--json", at: exec + 1)
        }
        var executionDirectory = session?.directory ?? run.folders.map { $0.directory.appendingPathComponent("stateless-\(UUID().uuidString)") } ?? URL(fileURLWithPath: chatDir)
        if let geminiPictures, session == nil, run.folders == nil { executionDirectory = geminiPictures }
        if let folders = run.folders {
            do { arguments = try folders.arguments(arguments, executionDirectory, web) }
            catch { return .failure(.failed("Workspace setup failed: " + error.localizedDescription)) }
        }
        if !images.isEmpty {
            if account.provider == .codex {
                arguments.removeLast()
                for url in images { arguments += ["--image", url.path] }
                arguments += ["--", prompt]
            } else if account.provider == .claude {
                arguments.remove(at: 1)
                arguments += ["--input-format", "stream-json"]
                if session == nil && !arguments.contains("--output-format") { arguments += ["--output-format", "stream-json", "--verbose"] }
                do {
                    var blocks: [[String: Any]] = [["type": "text", "text": prompt]]
                    for url in images {
                        let data = try Data(contentsOf: url)
                        blocks.append(["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": data.base64EncodedString()]])
                    }
                    inputData = try JSONSerialization.data(withJSONObject: ["type": "user", "message": ["role": "user", "content": blocks]])
                    inputData?.append(0x0a)
                } catch { return .failure(.failed("Could not read an attached image.")) }
            }
        }
        if inputData == nil && account.provider != .gemini {
            if account.provider == .claude { arguments.remove(at: 1) }
            else { arguments[arguments.count - 1] = "-" }
            inputData = Data(prompt.utf8)
        }
        arguments = CloudModels.apply(arguments, provider: account.provider, model: model)
        guard let binary = toolForTests ?? binary ?? (launchForTests == nil ? nil : "<cli>") else { return .failure(.missingTool) }

        let process = Process()
        if let wrapper = run.wrapper, let program = wrapper.first {
            process.executableURL = URL(fileURLWithPath: program)
            process.arguments = Array(wrapper.dropFirst()) + [binary] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
        }
        let executionEnvironment = run.environment(account.environment)
        process.environment = executionEnvironment
        process.currentDirectoryURL = executionDirectory
        if let launchForTests {
            return launchForTests(Launch(executable: process.executableURL!.path, arguments: process.arguments ?? [], environment: executionEnvironment,
                                         directory: executionDirectory, processGroup: run.processGroup, cli: binary))
        }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let inputFile = chatDir + "/input-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: inputFile) }
        var inputHandle: FileHandle?
        if let inputData {
            do {
                guard FileManager.default.createFile(atPath: inputFile, contents: inputData, attributes: [.posixPermissions: 0o600]) else {
                    return .failure(.failed("Could not prepare private image input."))
                }
                inputHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: inputFile))
            } catch { return .failure(.failed("Could not prepare image input.")) }
        }
        defer { try? inputHandle?.close() }
        process.standardInput = inputHandle ?? FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .failure(.missingTool) }

        cancellation?.attach(process)
        defer {
            cancellation?.detach(process)
            if run.processGroup { kill(-process.processIdentifier, SIGKILL) }
        }
        // Read both pipes while it runs (a full pipe would stop the tool).
        var stdout = Data(), stderr = Data()
        let readers = DispatchGroup()
        readers.enter()
        let parser = streamed ? StreamParser(provider: account.provider, report: progress!) : nil
        let stdoutLock = NSLock()
        DispatchQueue.global().async {
            // Read as it arrives (not only at the end) so a streaming reply can be shown while it is written.
            let handle = out.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                stdoutLock.lock(); stdout.append(chunk); stdoutLock.unlock()
                parser?.feed(chunk)
            }
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global().async { stderr = err.fileHandleForReading.readDataToEndOfFile(); readers.leave() }
        let deadline = Date().addingTimeInterval(timeout)
        while readers.wait(timeout: .now() + 0.1) == .timedOut {
            if cancellation?.isCancelled == true || Date() >= deadline {
                DebateCancellation.end(process)
                return .failure(cancellation?.isCancelled == true ? .failed("Cancelled") : .timedOut)
            }
        }
        while process.isRunning {
            if cancellation?.isCancelled == true || Date() >= deadline {
                DebateCancellation.end(process)
                return .failure(cancellation?.isCancelled == true ? .failed("Cancelled") : .timedOut)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()

        if run.folders != nil {
            for (name, data) in [("last-call.jsonl", stdout), ("last-error.log", stderr)] {
                let file = executionDirectory.appendingPathComponent(name)
                try? data.write(to: file, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        // A picked model the account cannot use fails here: say which one, so Settings is the obvious fix.
        let modelNote = model.map { L("모델 \($0) · ", "Model \($0) · ") } ?? ""
        var text = String(data: stdout, encoding: .utf8) ?? ""
        if let session { session.observe(text) }
        CloudModels.noteSeen(text, account: account, picked: model)
        if account.provider == .codex, let file = try? String(contentsOfFile: outFile, encoding: .utf8) { text = file }
        if account.provider == .claude && (!images.isEmpty || session != nil || streamed) {
            let result = text.split(separator: "\n").compactMap { line -> [String: Any]? in
                guard let data = String(line).data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["type"] as? String == "result" else { return nil }
                return json
            }.last
            guard let result, result["is_error"] as? Bool != true, let answer = result["result"] as? String else {
                let message = (result?["result"] as? String) ?? String(data: stderr, encoding: .utf8) ?? "Session response failed."
                return .failure(.failed(modelNote + String(message.suffix(300))))
            }
            text = answer
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !text.isEmpty else {
            let why = (String(data: stderr, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.failed(modelNote + String(why.suffix(300))))
        }
        return .success(text)
    }
}

public enum AnswerProgress {
    case text(String)      // the reply so far (the whole text, not only the new part)
    case activity(String)  // what the AI is doing now, e.g. reading files or searching the web
    case todos(Any?)       // Claude's own TodoWrite list as it came (its "todos" input); project work turns it into its plan
}

// Turns a CLI's JSON lines into progress. Claude: text deltas within the current message (a new message,
// after a tool call, starts over, like its final result) and tool starts. Codex: finished agent messages
// and the start of commands, tool calls and searches (its configuration warnings are skipped).
final class StreamParser {
    private let provider: Account.Provider
    private let report: (AnswerProgress) -> Void
    private var pending = Data()
    private var text = ""
    private var lastSent = Date.distantPast

    init(provider: Account.Provider, report: @escaping (AnswerProgress) -> Void) {
        self.provider = provider
        self.report = report
    }

    func feed(_ chunk: Data) {
        pending.append(chunk)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { handle(json) }
        }
    }

    static func activity(tool: String) -> String {
        let name = tool.lowercased()
        if ["websearch", "webfetch", "web_search", "search"].contains(where: { name.contains($0) }) { return L("웹 검색 중…", "Searching the web…") }
        if ["edit", "write", "file_change", "delete"].contains(where: { name.contains($0) }) { return L("파일 쓰는 중…", "Writing files…") }
        if ["read", "grep", "glob", "list_files"].contains(where: { name.contains($0) }) { return L("자료 읽는 중…", "Reading files…") }
        return L("작업 중…", "Working…") + " (" + tool + ")"
    }

    private func handle(_ json: [String: Any]) {
        switch provider {
        case .claude:
            // A whole assistant message: its TodoWrite input arrives complete here, not in pieces.
            if json["type"] as? String == "assistant", let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] {
                for block in content where block["type"] as? String == "tool_use" && block["name"] as? String == "TodoWrite" {
                    report(.todos((block["input"] as? [String: Any])?["todos"]))
                }
                return
            }
            guard json["type"] as? String == "stream_event", let event = json["event"] as? [String: Any] else { return }
            switch event["type"] as? String {
            case "message_start":
                text = ""
            case "content_block_start":
                if let block = event["content_block"] as? [String: Any], block["type"] as? String == "tool_use", let name = block["name"] as? String {
                    report(.activity(Self.activity(tool: name)))
                }
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let piece = delta["text"] as? String else { return }
                text += piece
                // At most about 12 updates a second: each one redraws the chat.
                if Date().timeIntervalSince(lastSent) > 0.08 { lastSent = Date(); report(.text(text)) }
            case "message_stop":
                if !text.isEmpty { report(.text(text)) }
            default: break
            }
        case .codex:
            guard let item = json["item"] as? [String: Any], let kind = item["type"] as? String else { return }
            if json["type"] as? String == "item.completed", kind == "agent_message", let message = item["text"] as? String {
                text = message
                report(.text(text))
            } else if json["type"] as? String == "item.started" {
                switch kind {
                case "command_execution": report(.activity(L("명령 실행 중…", "Running a command…")))
                case "mcp_tool_call": report(.activity(Self.activity(tool: item["tool"] as? String ?? "tool")))
                case "web_search": report(.activity(Self.activity(tool: "web_search")))
                case "file_change": report(.activity(Self.activity(tool: "file_change")))
                default: break
                }
            }
        case .gemini, .ollama:
            break
        }
    }
}
