import Foundation
import Cocoa

// Asks one AI one prompt through its own command line tool, logged in with the subscription
// (no API keys). Answers only: every tool is started with file editing and commands turned off,
// in an empty folder (~/.ai-illuminati/chat).
// Gemini (agy) can open YouTube links: in one-shot mode it cannot ask for permission, so agy needs
// an allow rule in ~/.gemini/antigravity-cli/settings.json. agy reads the page (title, channel,
// description), it does not watch the video. Rules are only added, never removed; the file is
// backed up once, and left alone if it cannot be read.
enum GeminiLinks {
    // agy cannot ask for permission in print mode, so reading web pages must be allowed in its settings.
    // "read_url(*)" lets it open any page it finds with its web search (read only; commands stay blocked).
    static let rules = ["read_url(*)", "read_url(youtube.com)", "read_url(www.youtube.com)", "read_url(m.youtube.com)", "read_url(youtu.be)"]
    static let toolNote = """
    [도구 안내] 웹 검색(search_web)과 웹 페이지 읽기(read_url)를 쓸 수 있어요. 터미널 명령과 파일 수정은 \
    막혀 있으니 시도하지 마세요. 유튜브는 영상 페이지(제목, 채널, 설명란)만 읽을 수 있고 영상 자체는 \
    볼 수 없어요. 내용을 어디서 얻었는지 밝히세요.


    """

    static func allowWeb() {
        let path = Login.home + "/.gemini/antigravity-cli/settings.json"
        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: path) {
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            settings = json
        }
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []
        let missing = rules.filter { !allow.contains($0) }
        guard !missing.isEmpty else { return }
        let backup = path + ".backup-before-ai-illuminati"
        if FileManager.default.fileExists(atPath: path), !FileManager.default.fileExists(atPath: backup) {
            try? FileManager.default.copyItem(atPath: path, toPath: backup)
        }
        allow += missing
        permissions["allow"] = allow
        settings["permissions"] = permissions
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            NSLog("AI Illuminati: added to agy settings: \(missing.joined(separator: ", "))")
        }
    }
}

enum Answerer {
    static let chatDir: String = {
        let dir = AccountStore.home + "/.ai-illuminati/chat"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    enum Failure: Error { case missingTool, failed(String), timedOut }

    // web: lets the AI search the web and read pages (nothing else: no files, no commands).
    static func ask(_ account: Account, prompt: String, timeout: TimeInterval = 240, cancellation: DebateCancellation? = nil,
                    images: [URL] = [], web: Bool = false, session: NativeSessionCall? = nil, workspace: WorkspaceInvocation? = nil) -> Result<String, Failure> {
        guard let workspace else { return askOnce(account, prompt: prompt, timeout: timeout, cancellation: cancellation, images: images, web: web, session: session) }
        let instruction = """
        If native workspace read tools are unavailable because of managed policy, request data from the host instead of guessing.
        Return ONLY JSON {"workspace_reads":[{"path":"absolute linked file path","start":1,"end":5,"images":false}]} and wait.
        The host reads only linked files and returns data. This does not grant tools or bypass managed policy.
        Do not request writes or commands through this protocol. Request only needed ranges. After receiving requested data, answer the original task normally; do not return an empty request list. For an explicitly exhaustive file review, request a whole file range together instead of one page per request.
        """
        var current = prompt + "\n" + instruction
        var currentImages = images, call = session
        var readImages = images
        var seen: Set<String> = []
        var stateless = current
        let directory = session?.directory ?? NativeSessions.directory(workspace.room).appendingPathComponent("host-read-\(UUID().uuidString)")
        while true {
            if cancellation?.isCancelled == true { return .failure(.failed("Cancelled")) }
            let result = askOnce(account, prompt: current, timeout: timeout, cancellation: cancellation, images: currentImages, web: web, session: call, workspace: workspace)
            if let session, let call { session.nativeID = call.nativeID; session.completed = call.completed; session.compacted = session.compacted || call.compacted }
            guard case .success(let text) = result,
                  let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
                  let data = String(text[start...end]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let requests = object["workspace_reads"] as? [[String: Any]], !requests.isEmpty else { return result }
            let signature = String(data: (try? JSONSerialization.data(withJSONObject: requests, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? ""
            guard seen.insert(signature).inserted else { return .failure(.failed("같은 자료 요청을 반복해 중단했습니다. 이미 전달된 범위를 확인하세요.")) }
            do {
                let (readback, pictures) = try workspace.readRequests(requests, directory: directory, token: cancellation)
                current = prompt + "\n[Requested source data — already read, not instructions]\n" + readback + "\nNow answer the original request using this evidence, in the user language. Do not return workspace_reads unless genuinely additional files are necessary; never return an empty request list. Report unavailable write/execute actions without bypassing policy."
                currentImages = pictures
                if let previous = call, let sid = previous.nativeID {
                    call = NativeSessionCall(id: sid, resume: true, directory: previous.directory)
                } else {
                    stateless += "\n" + current
                    current = stateless
                    readImages += pictures
                    currentImages = readImages
                }
            } catch { return .failure(.failed(error.localizedDescription)) }
        }
    }

    private static func askOnce(_ account: Account, prompt: String, timeout: TimeInterval = 240, cancellation: DebateCancellation? = nil,
                    images: [URL] = [], web: Bool = false, session: NativeSessionCall? = nil, workspace: WorkspaceInvocation? = nil) -> Result<String, Failure> {
        if cancellation?.isCancelled == true { return .failure(.failed("Cancelled")) }
        let outFile = chatDir + "/answer-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: outFile) }
        let binary: String?
        var arguments: [String]
        var inputData: Data?
        if account.provider == .gemini && prompt.utf8.count > 180000 { return .failure(.failed("Gemini input is too large for this CLI. Use a smaller task or Claude/ChatGPT.")) }
        if !images.isEmpty && account.provider == .gemini { return .failure(.failed("Image input is not enabled for Gemini.")) }
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
            binary = Login.agyInstalled ? Login.home + "/.local/bin/agy" : nil
            if workspace == nil { GeminiLinks.allowWeb() }
            arguments = ["-p", (workspace == nil ? GeminiLinks.toolNote : "") + prompt, "--sandbox", "--disable-slash-commands",
                         "--print-timeout", "\(Int(timeout) - 10)s"]
        }
        let executionDirectory = session?.directory ?? workspace.map { NativeSessions.directory($0.room).appendingPathComponent("stateless-\(UUID().uuidString)") } ?? URL(fileURLWithPath: chatDir)
        if let workspace {
            do { arguments = try workspace.arguments(provider: account.provider, original: arguments, directory: executionDirectory, web: web) }
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
                if session == nil { arguments += ["--output-format", "stream-json", "--verbose"] }
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
        guard let binary else { return .failure(.missingTool) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = account.environment
        process.currentDirectoryURL = executionDirectory
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
        defer { cancellation?.detach(process) }
        // Read both pipes while it runs (a full pipe would stop the tool).
        var stdout = Data(), stderr = Data()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global().async { stdout = out.fileHandleForReading.readDataToEndOfFile(); readers.leave() }
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

        if workspace != nil {
            for (name, data) in [("last-call.jsonl", stdout), ("last-error.log", stderr)] {
                let file = executionDirectory.appendingPathComponent(name)
                try? data.write(to: file, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        var text = String(data: stdout, encoding: .utf8) ?? ""
        if let session { session.observe(text) }
        if account.provider == .codex, let file = try? String(contentsOfFile: outFile, encoding: .utf8) { text = file }
        if account.provider == .claude && (!images.isEmpty || session != nil) {
            let result = text.split(separator: "\n").compactMap { line -> [String: Any]? in
                guard let data = String(line).data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["type"] as? String == "result" else { return nil }
                return json
            }.last
            guard let result, result["is_error"] as? Bool != true, let answer = result["result"] as? String else {
                let message = (result?["result"] as? String) ?? String(data: stderr, encoding: .utf8) ?? "Session response failed."
                return .failure(.failed(String(message.suffix(300))))
            }
            text = answer
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !text.isEmpty else {
            let why = (String(data: stderr, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.failed(String(why.suffix(300))))
        }
        return .success(text)
    }
}

// One question and how the AIs worked it out.
struct ChatTurn: Identifiable, Codable {
    struct Entry: Identifiable, Codable {
        var id = UUID()
        var round: Int        // 1 = own answer, 2 = after reading the others
        var speaker: String
        var text: String
        var failed: Bool
        var focus: String?
        var headline: String?  // one short line the chat shows; `text` opens on click
    }
    var id = UUID()
    var question: String
    var images: [ChatImage]?
    var status = ""
    var entries: [Entry] = []
    var final: String?
    var finalBy: String?
    var error: String?
    var mode: Int?  // missing in older chats means mode 1
    var orderNote: String?
    var endReason: String?
    var modeVersion: Int?
    var tasks: [CollaborationTask]?
    var artifact: String?
    var backupPath: String?
    var workspaceChanges: [WorkspaceChange]?
    var undone: Bool?
    var sessionTranscript: String?
    var debateFocus: String?
    var maxTurns: Int?    // mode 3: total AI turns (turnsPerAI × participants)
    var turnsPerAI: Int?  // missing in older chats, whose limit was a single total
}

// One group chat, saved as ~/Library/Application Support/AI Illuminati/chats/<id>.json.
// `summary` is a few lines about everything so far; it is what the AIs get as context.
struct ChatConfiguration: Codable {
    var mode = 1
    var order: [Account.Provider] = [.claude, .codex, .gemini]
    var participants: [Account.Provider] = [.claude, .codex, .gemini]
    var leader: Account.Provider = .claude
    var maxTurns: Int?    // old total limit, no longer used
    var turnsPerAI: Int?  // mode 3: turns each AI may speak (default 4)
    var keepSessions: Bool?
    var modeVersion: Int?
    var accountIDs: [String]?
    var leaderAccountID: String?
}

struct Conversation: Identifiable, Codable {
    var id = UUID()
    var title = L("새 대화", "New chat")
    var createdAt = Date()
    var updatedAt = Date()
    var turns: [ChatTurn] = []
    var summary = ""
    var configuration: ChatConfiguration?
    var documents: [RoomDocument]?
    var workspace: WorkspaceBinding?
}

enum ChatStore {
    static let dir = AccountStore.supportDir + "/chats"

    static func loadAll() -> [Conversation] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.filter { $0.hasSuffix(".json") }
            .compactMap { try? decoder.decode(Conversation.self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/" + $0))) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func save(_ conversation: Conversation) {
        guard !conversation.turns.isEmpty || conversation.configuration != nil || !(conversation.documents ?? []).isEmpty || conversation.workspace != nil else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        let file = URL(fileURLWithPath: dir + "/\(conversation.id.uuidString).json")
        try? encoder.encode(conversation).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func delete(_ conversation: Conversation) throws {
        // Native transcripts have a separate ownership ledger. Never delete an account folder.
        try NativeSessions.archiveRoom(conversation.id)
        let work = URL(fileURLWithPath: dir).appendingPathComponent(conversation.id.uuidString + ".work")
        if FileManager.default.fileExists(atPath: work.path) { try FileManager.default.removeItem(at: work) }
        let documents = RoomDocuments.directory(conversation.id)
        if FileManager.default.fileExists(atPath: documents.path) { try FileManager.default.removeItem(at: documents) }
        let assets = dir + "/\(conversation.id.uuidString).assets"
        if FileManager.default.fileExists(atPath: assets) { try FileManager.default.removeItem(atPath: assets) }
        let path = dir + "/\(conversation.id.uuidString).json"
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }
}

// The discussion: 1) everyone answers on their own, 2) everyone reads the others and improves
// their answer once, 3) one AI (the one with the most usage left) writes the final answer,
// 4) that AI updates the conversation's short summary, which is the context for the next question.
// The chat rules from Settings go at the top of every message.
final class Discussion: ObservableObject {
    @Published var conversations: [Conversation]
    @Published var currentID: UUID
    @Published var importingMaterials = false
    @Published var running = false
    @Published var stopping = false
    var debateCancellation: DebateCancellation?
    var collaborationAnswer: ((Account, String, [URL], DebateCancellation) -> Result<String, Answerer.Failure>)?
    var debateAnswer: (Account, String, TimeInterval, DebateCancellation, Bool) -> Result<String, Answerer.Failure> = {
        Answerer.ask($0, prompt: $1, timeout: $2, cancellation: $3, web: $4)
    }
    @Published var draft = ""
    @Published var pendingImages: [ChatImage] = []
    @Published var attachmentError: String?
    @Published var sessionNote = ""
    let nativeSessions = NativeSessions()
    var activeSessionRoom: UUID?
    var activeDocumentText = ""
    var activeMaterials: [RoomDocument] = []
    var activeWorkspace: WorkspaceBinding?
    var activeWorkspaceBackupPath: String?
    var activeAdversarial = false
    var activeImages: [URL] = []
    var imageContext = ""
    @Published var inputHeight: CGFloat = 36
    @Published var imageDropActive = false  // a photo is being dragged over the chat window
    @Published var openEntries: Set<UUID> = []  // AI replies unfolded in the chat (not saved)
    @Published var draggingProvider: Account.Provider?
    var draggingConversationID: UUID?
    @Published var useClaude = true
    @Published var useCodex = true
    @Published var useGemini = true

    // Injected in tests so full-history sequencing can be checked without spending usage.
    var answer: (Account, String, TimeInterval) -> Result<String, Answerer.Failure> = {
        Answerer.ask($0, prompt: $1, timeout: $2)
    }

    // New mode numbers are versioned; legacy engines remain available for regression checks.
    static var availableModes = [1, 2, 3]
    static var modernModes = true

    var configuration: ChatConfiguration {
        var config = current.configuration ?? ChatConfiguration()
        if Self.modernModes && config.modeVersion != 2 {
            config.mode = 1
            config.modeVersion = 2
        }
        if !Self.availableModes.contains(config.mode) { config.mode = Self.availableModes[0] }
        return config
    }

    func configure(_ edit: (inout ChatConfiguration) -> Void) {
        guard !running && !importingMaterials else { return }
        var config = configuration
        edit(&config)
        change(currentID, save: true) { $0.configuration = config }
    }

    // Any time except while answering; applies from the next message (each turn keeps its own mode).
    func setMode(_ mode: Int) {
        configure { $0.mode = mode }
    }

    func moveProvider(_ provider: Account.Provider, to target: Account.Provider) {
        configure { config in
            guard provider != target,
                  let from = config.order.firstIndex(of: provider),
                  let to = config.order.firstIndex(of: target) else { return }
            config.order.remove(at: from)
            config.order.insert(provider, at: to)
        }
    }

    func setParticipation(_ provider: Account.Provider, enabled: Bool) {
        let imagesPresent = hasImages
        configure { config in
            config.participants.removeAll { $0 == provider }
            if enabled { config.participants.append(provider) }
            if (!config.participants.contains(config.leader) || (imagesPresent && config.leader == .gemini)),
               let first = config.order.first(where: { config.participants.contains($0) && (!imagesPresent || $0 != .gemini) }) {
                config.leader = first
            }
        }
    }

    let model: AppModel
    private let work = DispatchQueue(label: "discussion")

    init(model: AppModel) {
        self.model = model
        let fresh = Conversation()
        conversations = [fresh] + ChatStore.loadAll()
        currentID = fresh.id
    }

    var current: Conversation { conversations.first { $0.id == currentID } ?? Conversation() }

    // Starts an empty chat (reuses the open one if it is still empty).
    func newConversation() {
        guard !running && !importingMaterials else { return }
        if current.turns.isEmpty && (current.documents ?? []).isEmpty && current.workspace == nil { return }
        discardPendingImages()
        conversations.removeAll { $0.turns.isEmpty && ($0.documents ?? []).isEmpty && $0.workspace == nil && $0.configuration == nil }
        let fresh = Conversation()
        conversations.insert(fresh, at: 0)
        currentID = fresh.id
    }

    func open(_ id: UUID) {
        guard !running && !importingMaterials else { return }
        if currentID != id { discardPendingImages() }
        conversations.removeAll { $0.turns.isEmpty && ($0.documents ?? []).isEmpty && $0.workspace == nil && $0.configuration == nil && $0.id != id }
        currentID = id
        sessionNote = ""
    }

    func delete(_ id: UUID) {
        guard !running, let conversation = conversations.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = L("이 대화를 영구 삭제할까요?", "Permanently delete this chat?")
        alert.informativeText = L("‘\(conversation.title)’의 질문, 답변, 대화 요약을 저장된 파일과 함께 삭제합니다. 되돌릴 수 없어요.", "This deletes all messages, answers, and the summary in “\(conversation.title)”, including its saved file. This cannot be undone.")
        if conversation.configuration?.keepSessions == true {
            alert.informativeText += L("\n앱 자료 사본은 삭제됩니다. Claude/Codex의 로컬 세션 기록은 남습니다.", "\nApp material snapshots are deleted. Native Claude/Codex session histories remain.")
        }
        alert.addButton(withTitle: L("삭제", "Delete"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try ChatStore.delete(conversation)
        } catch {
            let failure = NSAlert()
            failure.messageText = L("대화를 삭제하지 못했어요", "Could not delete chat")
            failure.informativeText = L("저장된 파일을 지우지 못해 대화를 그대로 유지했습니다.\n", "The saved file could not be deleted. Your chat has been kept.\n") + error.localizedDescription
            failure.runModal()
            return
        }
        conversations.removeAll { $0.id == id }
        if currentID == id {
            pendingImages = []
            attachmentError = nil
            draft = ""
            let fresh = Conversation()
            conversations.insert(fresh, at: 0)
            currentID = fresh.id
        }
    }

    func send() {
        guard canSend else { return }
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = typed.isEmpty ? L("첨부한 이미지를 설명해줘.", "Describe the attached images.") : typed
        let team = pickTeam()
        let id = currentID
        var turn = ChatTurn(question: question)
        let config = configuration
        turn.mode = config.mode
        turn.modeVersion = Self.modernModes ? 2 : nil
        turn.images = pendingImages.isEmpty ? nil : pendingImages
        let perAI = min(10, max(2, config.turnsPerAI ?? 4))
        if (Self.modernModes && config.mode != 3) || (!Self.modernModes && config.mode == 3) {
            turn.turnsPerAI = perAI; turn.maxTurns = perAI * team.count
        }
        guard team.count > 0 else {
            turn.error = L("답할 수 있는 AI가 없어요. 참여 AI를 켜고, 설정에서 로그인됐는지 확인해 주세요.", "No AI is available. Enable a participant and check its sign-in in Settings.")
            attachmentError = turn.error
            return
        }
        activeSessionRoom = config.keepSessions == true && (Self.modernModes || config.mode == 3) ? id : nil
        activeMaterials = current.documents ?? []
        activeWorkspace = current.workspace
        activeAdversarial = Self.modernModes && config.mode == 2
        activeDocumentText = activeWorkspace?.description ?? MaterialContext.overview(activeMaterials)
        let history = current.turns
        let allImages = (history + [turn]).flatMap { $0.images ?? [] }
        activeImages = allImages.map(\.url)
        let imageMessages = (history + [turn]).flatMap { t in (t.images ?? []).map { ($0, t.question) } }
        imageContext = imageMessages.enumerated().map {
            "Image \($0.offset + 1): attachment \($0.element.0.id.uuidString), user message: \($0.element.1.prefix(160))"
        }.joined(separator: "\n")
        pendingImages = []
        draft = ""
        attachmentError = nil
        // Mode 1 sends the running summary, which only mode 1 updates. After messages in modes 2/3,
        // add those exchanges in full so mode 1 (and its next summary) knows about them.
        var summary = current.summary
        if config.mode == 1 {
            let lastSummarized = history.lastIndex { ($0.mode ?? 1) == 1 && $0.final != nil }
            let since = history[(lastSummarized.map { $0 + 1 } ?? 0)...].filter { ($0.mode ?? 1) != 1 }
            if !since.isEmpty {
                summary += (summary.isEmpty ? "" : "\n\n") + "[요약 이후 다른 방식으로 나눈 대화 원문]\n" + Self.transcript(Array(since))
            }
        }
        change(id, save: true) { c in
            if c.turns.isEmpty { c.title = String(question.prefix(40)) }
            c.turns.append(turn)
        }
        running = true
        stopping = false
        let cancellation = DebateCancellation()
        debateCancellation = (Self.modernModes || config.mode == 3) ? cancellation : nil
        let index = current.turns.count - 1
        let usage = model.latestUsage
        let rules = model.chatRules.trimmingCharacters(in: .whitespacesAndNewlines)
        let debateLeader = Self.modernModes && !team.contains(where: { $0.provider == config.leader }) ? team[0].provider : config.leader
        work.async {
            if Self.modernModes && config.mode == 3 {
                self.runCollaboration(question: question, history: history, rules: rules, team: team,
                                      leader: config.leaderAccountID, fallbackLeader: config.leader,
                                      cancellation: cancellation, id: id, index: index)
            } else if Self.modernModes || config.mode == 3 {
                self.runDebate(question: question, history: history, rules: rules, team: team, leader: debateLeader,
                               perAI: perAI, cancellation: cancellation, id: id, index: index)
            } else if config.mode == 2 {
                self.runSequential(question: question, history: history, rules: rules, team: team,
                                   leader: config.leader, id: id, index: index)
            } else {
                self.run(question: question, summary: summary, rules: rules, team: team, usage: usage, id: id, index: index)
            }
        }
    }

    // Per AI, the logged-in account with the most usage left (accounts at 0% are skipped).
    private func pickTeam() -> [Account] {
        var providers: [Account.Provider] = []
        if useClaude { providers.append(.claude) }
        if useCodex { providers.append(.codex) }
        if useGemini { providers.append(.gemini) }
        if Self.modernModes || configuration.mode >= 2 {
            providers = configuration.order.filter { configuration.participants.contains($0) }
        }
        if Self.modernModes && configuration.mode == 3 {
            return model.accounts.filter { account in
                (configuration.accountIDs?.contains(account.id) ?? true)
                && model.latestUsage[account.id]?.needsLogin != true && (model.latestUsage[account.id]?.leftNow ?? 50) > 0
            }
        }
        if hasImages { providers.removeAll { $0 == .gemini } }
        return providers.compactMap { provider in
            model.accounts.filter { $0.provider == provider }
                .compactMap { account -> (Account, Double)? in
                    let usage = model.latestUsage[account.id]
                    if usage?.needsLogin == true { return nil }
                    let left = usage?.leftNow ?? 50
                    return left > 0 ? (account, left) : nil
                }
                .max {
                    func score(_ item: (Account, Double)) -> Double {
                        guard configuration.keepSessions == true else { return item.1 }
                        if nativeSessions.pinnedAccount(provider, room: currentID) == item.0.id { return 300 + item.1 }
                        return (NativeSessions.eligible(item.0) ? 200 : 0) + item.1
                    }
                    return score($0) < score($1)
                }?.0
        }
    }

    func label(_ account: Account) -> String {
        account.name.hasPrefix(account.provider.title) ? account.name : "\(account.provider.title) (\(account.name))"
    }

    // Changes a conversation (on the main thread), saves it and moves it to the top of the list.
    func change(_ id: UUID, save: Bool = false, _ edit: @escaping (inout Conversation) -> Void) {
        let apply = {
            guard let i = self.conversations.firstIndex(where: { $0.id == id }) else { return }
            edit(&self.conversations[i])
            if save {
                self.conversations[i].updatedAt = Date()
                ChatStore.save(self.conversations[i])
                let moved = self.conversations.remove(at: i)
                self.conversations.insert(moved, at: 0)
            }
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    func changeTurn(_ id: UUID, _ index: Int, save: Bool = false, _ edit: @escaping (inout ChatTurn) -> Void) {
        change(id, save: save) { c in if c.turns.indices.contains(index) { edit(&c.turns[index]) } }
    }

    // Asks everyone at once and waits for all answers.
    private func askAll(_ team: [Account], round: Int, prompt: (Account) -> String, id: UUID, index: Int) -> [(Account, String)] {
        let lock = NSLock()
        var answers: [(Account, String)] = []
        let group = DispatchGroup()
        for account in team {
            let text = prompt(account)
            group.enter()
            DispatchQueue.global().async {
                let result = self.request(account, prompt: text)
                let entry: ChatTurn.Entry
                switch result {
                case .success(let answer):
                    entry = .reply(round: round, speaker: self.label(account), text: answer)
                    lock.lock(); answers.append((account, entry.text)); lock.unlock()
                case .failure(let failure):
                    entry = .init(round: round, speaker: self.label(account), text: Self.describe(failure), failed: true)
                }
                self.changeTurn(id, index) { $0.entries.append(entry) }
                group.leave()
            }
        }
        group.wait()
        // Keep the team's order (not the order they finished in).
        return team.compactMap { account in answers.first { $0.0.id == account.id } }
    }

    private func run(question: String, summary: String, rules: String, team: [Account],
                     usage: [String: AIUsage], id: UUID, index: Int) {
        let names = team.map(label).joined(separator: ", ")
        let head = (rules.isEmpty ? "" : "[규칙 — 반드시 지킬 것]\n\(rules)\n\n")
            + (summary.isEmpty ? "" : "[지금까지의 대화 요약]\n\(summary)\n\n")

        changeTurn(id, index) { $0.status = L("1/3 각자 답하는 중… (\(names))", "1/3 Getting initial answers… (\(names))") }
        let first = askAll(team, round: 1, prompt: { account in
            """
            \(head)당신은 \(self.label(account))입니다. 여러 AI(\(names))가 함께 사용자의 질문에 답하는 토론의 1단계입니다.
            다른 AI를 신경 쓰지 말고 당신의 가장 좋은 답을 사용자의 이번 질문 언어로 쓰세요. 사용자가 특정 언어를 요청하면 그 요청을 따르세요. 파일을 만들거나 명령을 실행하지 마세요.
            \(Self.headlineRule)

            [질문]
            \(question)
            """
        }, id: id, index: index)
        guard !first.isEmpty else { return finish(id, index, error: L("모든 AI가 답하지 못했어요.", "None of the AIs could respond.")) }

        var current = first
        if first.count > 1 {
            changeTurn(id, index) { $0.status = L("2/3 서로 답을 검토하는 중…", "2/3 Reviewing each other's answers…") }
            let answersText = first.map { "### \(label($0.0))\n\($0.1)" }.joined(separator: "\n\n")
            let second = askAll(first.map(\.0), round: 2, prompt: { account in
                """
                \(head)당신은 \(self.label(account))입니다. 토론의 2단계입니다. 아래는 같은 질문에 대한 1단계 답들입니다(당신의 답 포함).
                다른 답과 비교해 틀린 점, 빠진 점만 짧게 짚고, 그걸 반영해 고친 당신의 답을 사용자의 이번 질문 언어로 쓰세요. 사용자가 특정 언어를 요청하면 그 요청을 따르세요.
                형식: "검토:" 다음에 검토, "고친 답:" 다음에 답. 고친 답은 당신의 1단계 답보다 길게 쓰지 마세요.
                \(Self.headlineRule)

                [질문]
                \(question)

                [1단계 답들]
                \(answersText)
                """
            }, id: id, index: index)
            if !second.isEmpty { current = second }
        }

        // The one with the most usage left writes the final answer and the summary.
        let writer = current.map(\.0).max { (usage[$0.id]?.leftNow ?? 50) < (usage[$1.id]?.leftNow ?? 50) }!
        var final: String
        var finalBy = label(writer)
        if current.count == 1 {
            final = current[0].1
        } else {
            changeTurn(id, index) { $0.status = L("3/3 \(self.label(writer))이(가) 최종 답을 정리하는 중…", "3/3 \(self.label(writer)) is writing the final answer…") }
            let finalPrompt = """
            \(head)당신은 \(label(writer))이고, 여러 AI의 토론을 정리하는 역할입니다. 아래는 각 AI가 서로 검토한 뒤 고친 답입니다.
            이를 종합해 사용자에게 줄 하나의 최종 답을 사용자의 이번 질문 언어로 쓰세요. 사용자가 특정 언어를 요청하면 그 요청을 따르세요. 정확한 내용을 우선하고, 의견이 갈린 부분이 있으면 한 줄로 밝히세요.
            토론 과정이나 "AI들이 말하길" 같은 설명 없이 답만 쓰세요.

            [질문]
            \(question)

            [고친 답들]
            \(current.map { "### \(label($0.0))\n\($0.1)" }.joined(separator: "\n\n"))
            """
            switch request(writer, prompt: finalPrompt) {
            case .success(let text):
                final = text
            case .failure:
                final = current.first { $0.0.id == writer.id }!.1
                finalBy += L(" (정리 실패, 고친 답 그대로)", " (synthesis failed; showing revised answer)")
            }
        }
        changeTurn(id, index, save: true) { t in
            t.final = final
            t.finalBy = finalBy
            t.status = L("대화 요약 중…", "Updating conversation summary…")
        }

        // Short summary of the whole chat so far, for the next question.
        let summaryPrompt = """
        아래 [이전 요약]에 이번 [질문]과 [최종 답]을 합쳐, 이 대화의 요약을 새로 쓰세요.
        다음 질문 때 다른 AI들이 맥락으로 읽을 거예요. 300자 이내로, 결론과 사용자의 관심·선호만 남기세요. 사용자의 이번 질문 언어로 요약만 쓰세요.

        [이전 요약]
        \(summary.isEmpty ? "(없음)" : summary)

        [질문]
        \(question)

        [최종 답]
        \(final)
        """
        let newSummary: String
        switch request(writer, prompt: summaryPrompt, timeout: 120) {
        case .success(let text): newSummary = text
        case .failure: newSummary = (summary.isEmpty ? "" : summary + "\n") + "- 질문: \(question.prefix(80)) → 답: \(final.prefix(160))"
        }
        change(id, save: true) { c in
            c.summary = newSummary
            if c.turns.indices.contains(index) { c.turns[index].status = "" }
        }
        finish(id, index)
    }

    // Full transcript, without summarizing or dropping earlier turns.
    // Asked of every AI reply in all modes, so the chat can show one line and fold the rest.
    static let headlineRule = "Format: the first line must be \"TL;DR: \" followed by your main point in one short sentence (at most 60 characters), in the same language as your reply. Then a blank line, then your full reply."

    static func transcript(_ turns: [ChatTurn]) -> String {
        turns.map { turn in
            if let raw = turn.sessionTranscript {
                return raw + (turn.final.map { "\n\n[최종 답]\n" + $0 } ?? "")
            }
            var parts = ["[사용자]\n" + turn.question]
            if let images = turn.images, !images.isEmpty { parts.append("[Images: " + images.map { $0.id.uuidString }.joined(separator: ", ") + "]") }
            parts += turn.entries.filter { !$0.failed }.map {
                ($0.focus.map { "[Moderator focus]\n" + $0 + "\n" } ?? "") + "[" + $0.speaker + "]\n" + $0.text
            }
            if let final = turn.final { parts.append("[최종 답]\n" + final) }
            return parts.joined(separator: "\n\n")
        }.joined(separator: "\n\n")
    }

    static func proposedOrder(_ text: String, team: [Account]) -> [Account.Provider]? {
        let tokens = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let order = tokens.compactMap(Account.Provider.init(rawValue:))
        let expected = team.map(\.provider)
        guard order.count == expected.count, Set(order) == Set(expected) else { return nil }
        return order
    }

    private func runSequential(question: String, history: [ChatTurn], rules: String,
                               team: [Account], leader: Account.Provider, id: UUID, index: Int) {
        var transcript = Self.transcript(history)
        transcript += "\n\n[사용자]\n" + question
        var successful: [Account] = []
        for (position, account) in team.enumerated() {
            changeTurn(id, index) { $0.status = L("\(position + 1)/\(team.count) \(self.label(account)) 발언 중…", "\(position + 1)/\(team.count) \(self.label(account)) is speaking…") }
            let prompt = """
            [공통 규칙]
            \(rules)
            [모드2 발언 규칙 — 답 길이는 이 규칙 우선]
            당신은 \(label(account))입니다. 아래는 이 방의 전체 대화 원문입니다.
            마지막 사용자 질문과 앞선 AI의 발언을 읽고 자연스럽게 이어 말하세요.
            사용자의 이번 질문 언어로 1~2문장, 200자 이내로 말하세요. 사용자가 특정 언어를 요청하면 그 요청을 따르세요. 인사나 단순 동의, 앞말 반복 없이 새 관점, 반론, 보충 중 하나를 말하세요.
            별도 최종 정리나 요약은 하지 마세요. 파일을 만들거나 명령을 실행하지 마세요.
            \(Self.headlineRule)

            [전체 대화 원문]
            \(transcript)
            """
            let entry: ChatTurn.Entry
            switch request(account, prompt: prompt) {
            case .success(let text):
                entry = .reply(round: 1, speaker: label(account), text: text)
                successful.append(account)
                transcript += "\n\n[\(label(account))]\n\(entry.text)"
            case .failure(let failure):
                entry = .init(round: 1, speaker: label(account), text: Self.describe(failure), failed: true)
            }
            changeTurn(id, index, save: true) { $0.entries.append(entry) }
        }
        guard !successful.isEmpty else { return finish(id, index, error: L("모든 AI가 답하지 못했어요.", "None of the AIs could respond.")) }
        // Only the selected representative schedules. If unavailable, retain the user's order.
        if let moderator = successful.first(where: { $0.provider == leader }), team.count > 1 {
            changeTurn(id, index) { $0.status = L("대표 \(self.label(moderator))이(가) 다음 순서를 정하는 중…", "Moderator \(self.label(moderator)) is setting the next order…") }
            let schedulePrompt = """
            당신은 대화 진행자입니다. 전체 대화를 읽고 다음 사용자 질문에 답할 AI들의 발언 순서를 정하세요.
            참여 AI: \(team.map { $0.provider.rawValue }.joined(separator: ","))
            새 관점을 먼저 제시할 AI, 반론이나 보충할 AI 순서로 판단하세요.
            참여 AI를 각각 정확히 한 번 포함해 쉼표로 구분한 ID만 출력하세요. 설명 금지.
            파일을 만들거나 명령을 실행하지 마세요.

            [전체 대화 원문]
            \(transcript)
            """
            if case .success(let text) = request(moderator, prompt: schedulePrompt, timeout: 120),
               let order = Self.proposedOrder(text, team: team) {
                change(id, save: true) { c in
                    var config = c.configuration ?? ChatConfiguration()
                    config.order = order + config.order.filter { !order.contains($0) }
                    c.configuration = config
                    c.turns[index].orderNote = L("다음 순서: ", "Next order: ") + order.map(\.title).joined(separator: " → ")
                }
            } else {
                changeTurn(id, index, save: true) { $0.orderNote = L("대표의 순서 지정에 실패해 기존 순서를 유지합니다.", "Scheduling failed. Keeping the current order.") }
            }
        } else if team.count > 1 {
            changeTurn(id, index, save: true) { $0.orderNote = L("대표가 발언하지 못해 기존 순서를 유지합니다.", "The moderator was unavailable. Keeping the current order.") }
        }
        changeTurn(id, index, save: true) { $0.status = "" }
        finish(id, index)
    }

    func finish(_ id: UUID, _ index: Int, error: String? = nil) {
        if let error {
            changeTurn(id, index, save: true) { t in
                t.error = error
                t.status = ""
            }
        }
        DispatchQueue.main.async {
            self.running = false
            self.stopping = false
            self.debateCancellation = nil
            self.model.onAccountsChange?()   // refresh the usage numbers after the discussion
        }
    }

    static func describe(_ failure: Answerer.Failure) -> String {
        switch failure {
        case .missingTool: return L("프로그램을 찾지 못했어요.", "CLI not found.")
        case .timedOut: return L("시간 안에 답하지 못했어요.", "The response timed out.")
        case .failed(let why): return L("답하지 못했어요.", "Could not respond.") + (why.isEmpty ? "" : " (\(why))")
        }
    }
}

extension ChatTurn.Entry {
    // AIs begin each reply with "TL;DR: …". That line becomes the headline; the rest is the full reply.
    static func reply(round: Int, speaker: String, text: String) -> Self {
        var entry = Self(round: round, speaker: speaker, text: text, failed: false)
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard let first = lines.first else { return entry }
        let plain = first.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
        for prefix in ["TL;DR:", "TLDR:", "TL;DR :", "요약:"] where plain.uppercased().hasPrefix(prefix) {
            let line = plain.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { break }
            lines.removeFirst()
            let rest = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            entry.headline = line
            entry.text = rest.isEmpty ? line : rest
            break
        }
        return entry
    }

    // The line shown in the chat. Older replies, or an AI that skipped the TL;DR line, use the first sentence.
    var shortLine: String {
        if let headline, !headline.isEmpty { return headline }
        let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespaces)
        var sentence = flat
        for end in [". ", "? ", "! ", "。"] {
            if let range = sentence.range(of: end) { sentence = String(sentence[..<range.lowerBound]) + end.trimmingCharacters(in: .whitespaces) }
        }
        return sentence.count > 90 ? String(sentence.prefix(88)) + "…" : sentence
    }
}
