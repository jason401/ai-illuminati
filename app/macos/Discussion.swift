import Foundation
import Cocoa
import AIAccounts
import AILocalization
import AISpaces
import AIRuntime
import AIWorkspace
import AIProjects

// One question and how the AIs worked it out.
struct ChatTurn: Identifiable, Codable, Equatable {
    struct Entry: Identifiable, Codable, Equatable {
        var id = UUID()
        var round: Int        // 1 = own answer, 2 = after reading the others
        var speaker: String
        var text: String
        var failed: Bool
        var focus: String?
        var headline: String?  // one short line the chat shows; `text` opens on click
        var images: [ChatImage]?  // pictures this AI made in this reply (Pictures.swift)
        var accountID: String?    // mode 0, several AIs at once: whose reply this is (labels can repeat)
        var meeting: UUID?        // a meeting an AI convened (convene_meeting): its hidden chat, shown as "Show the meeting"
    }
    var id = UUID()
    var question: String
    var images: [ChatImage]?
    var status = ""
    var entries: [Entry] = []
    var final: String?
    var finalImages: [ChatImage]?
    var finalBy: String?
    var error: String?
    var mode: Int?  // missing in older chats means mode 1
    var orderNote: String?
    var endReason: String?
    var modeVersion: Int?
    var tasks: [CollaborationTask]?
    var artifact: String?
    var projectCommitted: Bool?
    var projectPushed: Bool?
    var backupPath: String?
    var workspaceChanges: [WorkspaceChange]?
    var projectLog: [String]?   // project tools this turn used, e.g. "git_push → …", newest last
    var undone: Bool?
    var sessionTranscript: String?
    var debateFocus: String?
    var maxTurns: Int?    // mode 3: total AI turns (turnsPerAI × participants)
    var turnsPerAI: Int?  // missing in older chats, whose limit was a single total
    var mentions: [String]?     // mode 0: accounts called with @ for this message, in order (nil = automatic)
    var moreAnswers: [Entry]?   // mode 0: replies after the first when several AIs were called with @
    var partial: String?        // mode 0: the reply so far while it is being written (cleared when done)
    var partialBy: String?      // mode 0: who is writing it
    // Mode 0, several AIs answering at once (shown side by side, ChatWindow.swift): the accounts called, in order,
    // their names then, each one's reply so far while it is written, and the account of `final`.
    var answerOrder: [String]?
    var answerNames: [String]?
    var partials: [String: String]?
    var finalAccountID: String?
    var activity: String?       // mode 0: what that AI is doing now (reading files, searching…)
    var voteOptions: [String]?  // mode 4: the choices voted on
    var votes: [VoteBallot]?    // mode 4: one ballot per AI, in the team's order
    var askedAt: Date?          // when the message was sent (missing in older chats)
    var answeredAt: Date?       // when the answer finished
    var peerNotes: [Entry]?     // mode 0: opinions the AI asked for and reviews of the work (Peer.swift)
    var peerFolded: Bool?       // collaboration "on its own" (CollabLog.swift): those cards folded into one line
    var route: ChatRoute?       // project chat with members: how this message was answered (Route.swift)
    var routeNote: String?      // "Opinion · 3 AIs · judged by Gemma 4 E4B", shown above the answer
    var routeOne: Bool?         // with route opinion: only the lead answered (nil: everyone did)
    var meetingRoom: UUID?      // with route opinion: the members met in this hidden chat and `final` is their result (Meeting.swift)
    // Project work: the step list (the AI's, then the app's review steps), why it last changed, when the AI last
    // did something (the chat says "last activity 4 min ago", never "stuck") and whether an approval card waits.
    var plan: [WorkStep]?
    var planNote: String?
    var lastActivityAt: Date?
    var waitingApproval: Bool?
    var spaceDraft: SpaceDraftNote?   // the Space this answer made: a preview card under it (SpaceView.swift)
    var spaceEdits: [SpaceSyncNote]?  // Spaces this answer changed in the Spaces folder, as checked after it (SpaceLibrary.sync)
}

// Times under the messages and the day lines between them, like the desktop apps.
enum ChatTime {
    static func calendar(_ language: AppLanguage) -> Calendar {
        var calendar = Calendar.current
        calendar.locale = language.locale
        return calendar
    }

    private static func format(_ template: String, _ date: Date, _ language: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    // "오후 3:12" today, "어제 오후 3:12", then "10월 24일 오후 3:12" (with the year when not this year).
    static func stamp(_ date: Date, now: Date = Date(), language: AppLanguage = .current) -> String {
        let calendar = calendar(language)
        let time = format("jmm", date, language)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return (language == .korean ? "어제 " : "Yesterday ") + time
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return format(sameYear ? "MMMdjmm" : "yMMMdjmm", date, language)
    }

    // The line above the first message of each day: "10월 24일 (토)" / "Sat, Oct 24".
    static func day(_ date: Date, now: Date = Date(), language: AppLanguage = .current) -> String {
        let calendar = calendar(language)
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        if language == .korean {
            return format(sameYear ? "MMMd" : "yMMMd", date, language) + " (" + format("EEE", date, language) + ")"
        }
        return format(sameYear ? "EEEMMMd" : "EEEyMMMd", date, language)
    }

    // When the turn happened, for the day lines: older turns have no time of their own,
    // except the chat's last turn, which ended about when the chat was last changed.
    static func when(_ turn: ChatTurn, last: Bool, updatedAt: Date) -> Date? {
        turn.askedAt ?? (last ? updatedAt : nil)
    }
}

// How much each AI may say per turn in the discussion modes. The user mostly reads the one-line
// headlines and the final answer, so turns can be longer; longer turns cost more usage because every
// later turn re-reads the whole transcript.
enum SpeechLength {
    // 0 = no limit (the default): the AI says what its point needs. The user mostly reads the one-line
    // headlines and the final answer, and sessions send each AI only what is new, so longer turns cost less
    // than they seem.
    static let unlimited = 0, short = 400, standard = 800, long = 1500
    static let all = [unlimited, short, standard, long]

    static func clamp(_ value: Int?) -> Int { all.contains(value ?? -1) ? value! : unlimited }

    static func name(_ value: Int) -> String {
        switch value {
        case short: return L("짧게 · 400자", "Short · 400 chars")
        case standard: return L("보통 · 800자", "Medium · 800 chars")
        case long: return L("길게 · 1500자", "Long · 1500 chars")
        default: return L("제한 없음", "No limit")
        }
    }

    static func rule(_ value: Int) -> String {
        switch value {
        case short: return "Use 2–4 sentences, at most 400 characters"
        case standard: return "Use up to about 8 sentences or a short list with your evidence, at most 800 characters"
        case long: return "Be thorough: up to about 15 sentences or a structured list with evidence, examples and sources, at most 1500 characters"
        default: return "Take the length your point needs: full reasoning, evidence, numbers and examples, with no padding, repetition or restating of others"
        }
    }
}

// One group chat, saved as ~/Library/Application Support/AI Illuminati/chats/<id>.json.
// `summary` is a few lines about everything so far; it is what the AIs get as context.
struct ChatConfiguration: Codable {
    var mode = 1
    var order: [Account.Provider] = [.claude, .codex, .gemini]
    // Gemini is off by default in every mode (turn it on per chat); chats that saved a list keep it.
    var participants: [Account.Provider] = [.claude, .codex]
    var leader: Account.Provider = .claude
    var maxTurns: Int?    // old total limit, no longer used
    var turnsPerAI: Int?  // mode 3: turns each AI may speak (default 4)
    var speechLength: Int? // discussion modes: characters per AI turn (no limit by default, or 400 / 800 / 1500)
    var keepSessions: Bool?   // no longer used: sessions are always kept (older chats may have saved false)
    var sessionsOn: Bool { true }
    var modeVersion: Int?
    var accountIDs: [String]?
    var leaderAccountID: String?
    var voteSkippedIDs: [String]?  // mode 4: accounts turned off; every other account votes
    var soloAccountID: String?      // mode 0: the account picked by hand (nil = automatic)
    var lastSoloAccountID: String?  // mode 0: who answered last; it keeps going while it has usage left
    // mode 0: the chat's members (Solo.swift). Two or more: in a plain chat they all answer every message at the
    // same time; in a project chat the lead works and the others review (Peer.swift). One member is the same as
    // soloAccountID; nil or empty = automatic. Not synced: account IDs differ per Mac.
    var memberIDs: [String]?
    var leadID: String?             // the member picked by hand to do the work (nil = the app picks and keeps one)
    var school: Bool?               // older: the side the first answer picked (no longer used; Enterprise.swift)
    // Older review settings, read once to make the reviewer a member (Discussion.migratedMembers).
    var peerReview: Bool?
    var peerAccountID: String?
    var lastReviewSHA: String?
    var lastReviewAt: Date?
    var nextReviewAt: Date?
    var pendingReview: String?
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
    var pinned: Bool?   // kept at the top of the list
    var origin: SyncOrigin?       // continued on this Mac from another Mac's copy (DeviceSync.swift)
    var shareToDevices: Bool?     // shown on your other Macs (when only chosen chats are shared)
    // Locked by the user as an Enterprise chat (Enterprise.swift); never removed. nil = an open chat.
    var enterpriseLock: EnterpriseLock?
    // A meeting's own chat (Meeting.swift): the message it was held for. Not listed, searched or synced; deleted with that chat.
    var meetingOf: MeetingLink?

    // Something worth keeping: messages, materials or a linked folder. A chat with only settings is
    // "blank": it is not kept in the list once you leave it.
    var hasContent: Bool { !turns.isEmpty || !(documents ?? []).isEmpty || workspace != nil }
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
        DeviceSync.shared.noteSaved(conversation)
    }

    static func delete(_ conversation: Conversation) throws {
        // Remove this chat's session transcripts (exact IDs only, never an account folder) and its backups.
        try NativeSessions.purgeRoom(conversation.id, accounts: AccountStore.load())
        try WorkspaceBackup.purgeRoom(conversation.id)
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
        DeviceSync.shared.noteDeleted(conversation.id)
    }
}

// The discussion: 1) everyone answers on their own, 2) everyone reads the others and improves
// their answer once, 3) one AI (the one with the most usage left) writes the final answer,
// 4) that AI updates the conversation's short summary, which is the context for the next question.
// The chat rules from Settings go at the top of every message.
final class Discussion: ObservableObject {
    @Published var conversations: [Conversation]
    @Published var currentID: UUID {
        // Coming back to a chat starts again from its latest turns.
        didSet { if currentID != oldValue { closeFind(); showLatestTurns(); pickedRoute = nil } }
    }
    func showLatestTurns() {
        shownTurns = Self.turnPage; reachedBottom = false; loadingEarlier = false; earlierRowInView = false
        jumpTurn = nil
        transcriptGeneration += 1
    }
    @Published var importingMaterials = false
    @Published var viewingRemote: RemoteViewing?   // a chat from another Mac, shown read only
    @Published var viewingBoard = false            // the TODO board in place of the chat (Todo.swift)
    @Published var viewingSpace: String?           // a Space in place of the chat (SpaceView.swift)
    @Published var boardProject: String?           // the board shows only this project (SidebarProjects.key); nil = all
    @Published var boardTab: BoardTab = .todo       // a project's board: its Project info or its TODOs (ProjectInfoView.swift)
    // Several chats can work at once. Each sent message runs on its own worker (a Discussion with `host`
    // set and only that chat), so the run state below (active…, pictures, cancellation) is per chat; the
    // worker hands every change back to the host, which the window shows.
    static let maxRunning = 3
    @Published var runningRooms: Set<UUID> = []
    @Published var stoppingRooms: Set<UUID> = []
    weak var host: Discussion?
    private var workers: [UUID: Discussion] = [:]
    // For the open chat (a worker: always its own chat).
    var running: Bool {
        get { host != nil || runningRooms.contains(currentID) }
        set { if newValue { runningRooms.insert(currentID) } else { runningRooms.remove(currentID) } }
    }
    var stopping: Bool {
        get { stoppingRooms.contains(currentID) }
        set { if newValue { stoppingRooms.insert(currentID) } else { stoppingRooms.remove(currentID) } }
    }
    var anyRunning: Bool { !runningRooms.isEmpty }
    var runCancellation: DebateCancellation?
    var debateCancellation: DebateCancellation? { host == nil ? workers[currentID]?.runCancellation : runCancellation }
    var collaborationAnswer: ((Account, String, [URL], DebateCancellation) -> Result<String, Answerer.Failure>)?
    var debateAnswer: (Account, String, TimeInterval, DebateCancellation, Bool) -> Result<String, Answerer.Failure> = {
        Answerer.ask($0, prompt: $1, timeout: $2, cancellation: $3, web: $4, run: .app($0))
    }
    @Published var draft = ""
    @Published var pendingImages: [ChatImage] = []
    @Published var attachmentError: String?
    @Published var sessionNote = "" {
        // A worker's notes show only while its chat is the open one.
        didSet { if let host, host.currentID == currentID { host.sessionNote = sessionNote } }
    }
    let nativeSessions: NativeSessions
    var activeSessionRoom: UUID?
    var activeDocumentText = ""
    var activeMaterials: [RoomDocument] = []
    var activeWorkspace: WorkspaceBinding?
    var activePeerSession: PeerLink.Session?   // mode 0: this message's ask_ai (Peer.swift)
    var activeWorkspaceBackupPath: String?
    var activeAdversarial = false
    var activeMeeting = false   // this answer is a meeting (Meeting.swift): the AIs may read the folders
    var activeHeldBy: String?   // a meeting an answering AI convened (convene_meeting): its name; quick format, result for it
    var activeHeld: Bool { activeHeldBy != nil }
    var activeSpeechLength = SpeechLength.unlimited
    var activeImages: [URL] = []
    // Tests only: answers requests that have folders attached (mode 0 always does) without calling the real tools.
    var workspaceAnswer: ((Account, String, WorkspaceBinding, DebateCancellation, ((AnswerProgress) -> Void)?) -> Result<String, Answerer.Failure>)?
    // Tests only: sorts a project chat's message (Route.swift) without calling Gemma or an AI.
    var routeJudge: ((String) -> (route: RouteChoice, by: String?))?
    var forcedRoute: RouteChoice?   // "Run as work / opinion" under the last answer, for the next send only
    @Published var pickedRoute: RouteChoice?   // the way picked in the message box for the next message (nil: the app decides)
    // Tests only: answers requests that carry pictures without calling the real tools.
    var pictureAnswer: ((Account, String, [URL], TimeInterval, DebateCancellation, Bool) -> Result<String, Answerer.Failure>)?
    var imageContext = ""
    var imageNumber = 0   // pictures in the numbered list (activeImages holds only the ones sent)
    // Pictures made during a turn are added to activeImages/imageContext while other calls may be
    // reading them, so both go through this lock; nextPicture numbers pictures across the chat.
    let pictureLock = NSLock()
    var nextPicture = 1

    // The ChatGPT accounts that draw for `account` (Settings → Chat → Picture makers), best first. Empty when
    // none is checked or `account` is one of them (it draws itself). In an Enterprise chat only makers of its organization.
    func pictureMakers(for account: Account, chat id: UUID, excluded: Set<String> = []) -> [Account] {
        let makers = model.pictureMakers
        guard !makers.contains(where: { $0.id == account.id }) else { return [] }
        let chatLock = lock(of: id)
        var left = makers.filter { !excluded.contains($0.id) && Enterprise.permits($0, lock: chatLock) }, ordered: [Account] = []
        while let best = AutoPick.choose(left, usage: model.latestUsage, lock: nil, current: nil) {
            ordered.append(best); left.removeAll { $0.id == best.id }
        }
        return ordered
    }

    // How `account` makes pictures in this chat (draws itself, or asks a picture maker).
    func pictureRule(_ account: Account, chat id: UUID? = nil) -> String {
        Pictures.rule(for: account.provider, delegate: !pictureMakers(for: account, chat: id ?? currentID).isEmpty)
    }

    // Collects the pictures in one AI reply (numbered in order, stored with the chat). Each ```picture request
    // goes to a picture maker first; one out of usage hands it to the next.
    func collectPictures(_ text: String, account: Account, since: Date, id: UUID, index: Int? = nil,
                         cancellation: DebateCancellation? = nil) -> Pictures.Harvest {
        let requests = Pictures.requestBlocks(in: text)
        var drawn: [[Data]?] = []
        if !requests.isEmpty, !pictureMakers(for: account, chat: id).isEmpty {
            let token = cancellation ?? DebateCancellation()
            var excluded: Set<String> = []
            for block in requests {
                var files: [Data]?
                while files == nil, !token.isCancelled, let maker = pictureMakers(for: account, chat: id, excluded: excluded).first {
                    if let index { changeTurn(id, index) { $0.status = L("\(self.label(maker))가 그림 그리는 중…", "\(self.label(maker)) is drawing…") } }
                    let started = Date()
                    guard permits(maker, room: id) else { excluded.insert(maker.id); continue }
                    switch debateAnswer(maker, Pictures.makerPrompt(block.request), 600, token, false) {
                    case .success:
                        let made = Pictures.newCodexImages(maker, since: started).compactMap { try? Data(contentsOf: $0) }
                        if made.isEmpty { excluded.insert(maker.id) } else { files = made }
                    case .failure:
                        excluded.insert(maker.id)
                    }
                }
                drawn.append(files)
            }
        }
        pictureLock.lock(); defer { pictureLock.unlock() }
        let harvest = Pictures.harvest(text, account: account, since: since, conversationID: id, number: nextPicture, drawn: drawn)
        nextPicture += harvest.images.count
        return harvest
    }

    // Every AI that speaks after this sees these pictures.
    func sharePictures(_ images: [ChatImage], by speaker: String) {
        guard !images.isEmpty else { return }
        pictureLock.lock(); defer { pictureLock.unlock() }
        for image in images {
            activeImages.append(image.url)
            imageNumber += 1
            imageContext += (imageContext.isEmpty ? "" : "\n") + "Image \(imageNumber): \(image.name.replacingOccurrences(of: ".png", with: "")) drawn by \(speaker)"
        }
    }

    // Earlier pictures sent again with each message besides the ones attached to it. Older ones stay in the
    // chat and in the numbered list, as a line only, unless the message names them ("Image 3", "사진 3").
    static let recentImages = 6
    // Indexes of `pictures` (every picture in the chat, in order; the last `current` belong to this message) to attach.
    static func picturesToSend(_ pictures: [String], current: Int, question: String) -> Set<Int> {
        let earlier = max(0, pictures.count - current)
        var sent = Set(earlier..<pictures.count).union(max(0, earlier - recentImages)..<earlier)
        let pattern = try! NSRegularExpression(pattern: #"(?i)(?:image|picture|photo|사진|그림|이미지)\s*(\d{1,4})"#)
        for match in pattern.matches(in: question, range: NSRange(question.startIndex..., in: question)) {
            if let range = Range(match.range(at: 1), in: question), let n = Int(question[range]), n >= 1, n <= pictures.count { sent.insert(n - 1) }
        }
        return sent
    }
    @Published var inputHeight: CGFloat = 40
    // Chat window only (not saved): sidebar search and which row the pointer is over.
    @Published var sidebarSearching = false
    @Published var sidebarSearch = ""
    @Published var searchSide = ChatSearch.SideFilter.all
    @Published var searchKind = ChatSearch.KindFilter.all
    // Sidebar: hidden by the button in a wide window; in a narrow window it slides over the chat instead.
    @Published var sidebarHidden = false
    @Published var sidebarOverlay = false
    // The transcript's end is out of view: the chat shows a jump-to-bottom button above the message box.
    @Published var awayFromBottom = false
    // Long chats draw only the latest turns; scrolling to the top adds earlier ones. Display only:
    // the saved history and what the AIs receive are untouched.
    @Published var shownTurns = Discussion.turnPage
    // Turns drawn when a chat opens, and how many each scroll to the top adds.
    static let turnPage = 20
    // Earlier turns are added only after the chat has opened at its latest turn, so opening it does not load them all.
    var reachedBottom = false
    var loadingEarlier = false
    var earlierRowInView = false
    @Published var transcriptGeneration = 0   // bumped to open the transcript afresh
    // ⌘F in the open chat (ChatFind.swift), and a turn the transcript is asked to scroll to (also from search results).
    @Published var findOpen = false
    @Published var findText = ""
    @Published var findPosition = 0
    @Published var findFocus = 0
    var findFresh = true
    @Published var jumpTurn: UUID?
    @Published var jumpCount = 0
    @Published var hoverKey: String?
    // The notes panel on the right of the chat window, open or folded (the same for every chat).
    @Published var notesShown = UserDefaults.standard.bool(forKey: "notesShown") {
        didSet { UserDefaults.standard.set(notesShown, forKey: "notesShown") }
    }
    @Published var teamSettingsOpen = false   // the team mode settings popover in the message box
    // @ in the message box: the accounts picked so far, and the list while it is open.
    @Published var draftMentions: [String] = []
    @Published var mentionQuery: String?      // what was typed after @ (the list is open while this is set)
    @Published var mentionIndex = 0
    var mentionLocation = 0
    weak var mentionEditor: NSTextView?      // the message box, for picking from the list with the mouse
    @Published var slashMenu: (location: Int, query: String, choices: [RouteChoice])?   // "/" typed first: the ways to pick
    @Published var slashIndex = 0
    func hover(_ key: String, _ inside: Bool) {
        if inside { hoverKey = key } else if hoverKey == key { hoverKey = nil }
    }
    @Published var imageDropActive = false  // a photo is being dragged over the chat window
    @Published var openEntries: Set<UUID> = []  // AI replies unfolded in the chat (not saved)
    // The meetings under a chat in the sidebar (Meeting.swift), unfolded or folded by the user, and those showing all (not saved).
    @Published var meetingsOpen: Set<UUID> = []
    @Published var meetingsClosed: Set<UUID> = []
    @Published var meetingsAll: Set<UUID> = []
    @Published var draggingProvider: Account.Provider?
    var draggingConversationID: UUID?
    @Published var useClaude = true
    @Published var useCodex = true
    @Published var useGemini = false

    // Injected in tests so full-history sequencing can be checked without spending usage.
    var answer: (Account, String, TimeInterval) -> Result<String, Answerer.Failure> = {
        Answerer.ask($0, prompt: $1, timeout: $2, run: .app($0))
    }

    // Only plain chat is offered; chats saved in a team mode open as plain chat (their old turns still show
    // as they were). The team engines remain for regression checks, which turn them on explicitly.
    static var availableModes = [0]
    static var modernModes = true

    var configuration: ChatConfiguration { configuration(of: currentID) }
    func configuration(of room: UUID) -> ChatConfiguration {
        // A new chat starts as a plain chat with one AI (mode 0).
        var config = conversation(room).configuration ?? ChatConfiguration(mode: Self.availableModes.contains(0) ? 0 : 1, modeVersion: Self.modernModes ? 2 : nil)
        if Self.modernModes && config.modeVersion != 2 {
            config.mode = 1
            config.modeVersion = 2
        }
        if !Self.availableModes.contains(config.mode) { config.mode = Self.availableModes[0] }
        return config
    }

    func configure(_ edit: (inout ChatConfiguration) -> Void) { configure(room: currentID, edit) }
    func configure(room: UUID, _ edit: (inout ChatConfiguration) -> Void) {
        guard host == nil, !runningRooms.contains(room), !importingMaterials else { return }
        var config = configuration(of: room)
        edit(&config)
        change(room, save: true) { $0.configuration = config }
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
        configure { config in
            config.participants.removeAll { $0 == provider }
            if enabled { config.participants.append(provider) }
            if !config.participants.contains(config.leader),
               let first = config.order.first(where: { config.participants.contains($0) }) {
                config.leader = first
            }
        }
    }

    let model: AppModel
    fileprivate let work = DispatchQueue(label: "discussion")

    init(model: AppModel) {
        self.model = model
        nativeSessions = NativeSessions()
        // The newest blank chat (settings only) becomes the new chat, so its settings are kept;
        // older blank ones hold nothing and are removed.
        let loaded = ChatStore.loadAll()
        let blanks = loaded.filter { !$0.hasContent }
        for old in blanks.dropFirst() { try? ChatStore.delete(old) }
        let fresh = blanks.first ?? Conversation()
        conversations = [fresh] + loaded.filter(\.hasContent)
        currentID = fresh.id
        linkChatTools()
        SidebarFold.shared.adoptPins(conversations)
    }

    // A worker for one message in one chat: same accounts, sessions and test hooks, only that chat.
    init(workerFor host: Discussion, room: UUID) {
        model = host.model
        nativeSessions = host.nativeSessions
        conversations = host.conversations.filter { $0.id == room }
        currentID = room
        self.host = host
        answer = host.answer
        debateAnswer = host.debateAnswer
        collaborationAnswer = host.collaborationAnswer
        workspaceAnswer = host.workspaceAnswer
        routeJudge = host.routeJudge
        pictureAnswer = host.pictureAnswer
        useClaude = host.useClaude; useCodex = host.useCodex; useGemini = host.useGemini
    }

    // A worker finished (called on the main thread).
    private func runFinished(_ room: UUID) {
        runningRooms.remove(room)
        stoppingRooms.remove(room)
        workers[room] = nil
        model.onAccountsChange?()   // refresh the usage numbers after the answer
        DeviceSync.shared.noteFinished(conversations.first { $0.id == room })
    }

    /// Stops every chat that is working (quitting the app).
    func cancelAll() { for worker in workers.values { worker.runCancellation?.cancel() } }
    // The stop button of the chat that is answering now (create_project waits on it).
    func runToken(_ room: UUID) -> DebateCancellation? { workers[room]?.runCancellation }

    // Leaving a blank chat: drop it from the list and remove its settings-only file.
    func dropBlanks(except keep: UUID?) {
        for blank in conversations where !blank.hasContent && blank.id != keep { try? ChatStore.delete(blank) }
        conversations.removeAll { !$0.hasContent && $0.id != keep }
    }

    var current: Conversation { conversation(currentID) }
    func conversation(_ room: UUID) -> Conversation { conversations.first { $0.id == room } ?? Conversation() }

    // Starts an empty chat (reuses the open one if it is still empty).
    func newConversation() {
        guard !importingMaterials else { return }
        viewingBoard = false
        viewingSpace = nil
        if viewingRemote != nil && current.turns.isEmpty { viewingRemote = nil; return }
        if current.turns.isEmpty && (current.documents ?? []).isEmpty && current.workspace == nil { return }
        discardPendingImages()
        viewingRemote = nil
        dropBlanks(except: nil)
        let fresh = Conversation()
        conversations.insert(fresh, at: 0)
        currentID = fresh.id
    }

    func open(_ id: UUID) {
        guard !importingMaterials else { return }
        if currentID != id { discardPendingImages() }
        viewingRemote = nil
        viewingBoard = false
        viewingSpace = nil
        dropBlanks(except: id)
        currentID = id
        sessionNote = ""
    }

    // Pinned chats first (in their usual order), then the rest.
    var listedConversations: [Conversation] {
        let listed = conversations.filter { $0.meetingOf == nil }
        return listed.filter { $0.pinned == true } + listed.filter { $0.pinned != true }
    }

    // Asks for a new name; the list keeps its order (renaming is not new activity).
    func rename(_ id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = L("대화 이름 바꾸기", "Rename chat")
        let field = NSTextField(string: conversations[i].title)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L("바꾸기", "Rename"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].title = String(name.prefix(80))
        ChatStore.save(conversations[index])
    }

    func togglePin(_ id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }), conversations[i].hasContent else { return }
        conversations[i].pinned = conversations[i].pinned == true ? nil : true
        ChatStore.save(conversations[i])
    }

    // Deletes every saved chat (or all but the pinned ones), each the same way as deleting one.
    func deleteAll() {
        guard !anyRunning, !importingMaterials else { return }
        let saved = conversations.filter { $0.hasContent && $0.meetingOf == nil }
        guard !saved.isEmpty else { return }
        let pinnedCount = saved.filter { $0.pinned == true }.count
        let alert = NSAlert()
        alert.messageText = L("대화 \(saved.count)개를 모두 지울까요?", "Delete all \(saved.count) chats?")
        alert.informativeText = L("각 대화의 질문·답변·그림·첨부 사본·작업 결과, 그 대화들이 만든 세션 기록과 파일 백업까지 지워져요. 되돌릴 수 없어요. 연결한 원본 폴더와 Gemini 자체 기록은 그대로예요.",
                                  "Each chat's messages, pictures, attachment copies, results, and the sessions and file backups they created are deleted. This cannot be undone. Linked original folders and Gemini's own history stay.")
        alert.addButton(withTitle: L("모두 삭제", "Delete all"))
        if pinnedCount > 0 { alert.addButton(withTitle: L("고정한 \(pinnedCount)개는 남기기", "Keep \(pinnedCount) pinned")) }
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        let answer = alert.runModal()
        let keepPinned: Bool
        switch answer {
        case .alertFirstButtonReturn: keepPinned = false
        case .alertSecondButtonReturn where pinnedCount > 0: keepPinned = true
        default: return
        }
        let failed = removeChats(saved.filter { !(keepPinned && $0.pinned == true) })
        if failed > 0 {
            let failure = NSAlert()
            failure.messageText = L("\(failed)개 대화를 지우지 못했어요", "Could not delete \(failed) chats")
            failure.informativeText = L("저장된 파일을 지우지 못한 대화는 그대로 남겨뒀어요.", "Chats whose files could not be deleted were kept.")
            failure.runModal()
        }
    }

    // Removes these chats (files, sessions, backups) and their list rows; returns how many failed.
    @discardableResult
    func removeChats(_ chats: [Conversation]) -> Int {
        var failed = 0
        for conversation in chats {
            // Its meetings first: a chat whose meeting could not be deleted is kept, so no meeting is left without its chat.
            guard removeMeetings(of: conversation.id) == 0 else { failed += 1; continue }
            do {
                try ChatStore.delete(conversation)
                conversations.removeAll { $0.id == conversation.id }
            } catch { failed += 1 }
        }
        // Leave exactly one empty "new chat": the open one if it is empty, else a fresh one.
        dropBlanks(except: currentID)
        if !conversations.contains(where: { $0.id == currentID }) {
            pendingImages = []; attachmentError = nil; draft = ""
            let fresh = Conversation()
            conversations.insert(fresh, at: 0)
            currentID = fresh.id
        }
        return failed
    }

    // Permanently deletes a project's finished TODO chats (all, or those quiet for `days`), after asking. Their TODOs
    // stay on the board (title, result, files, time); the chats' messages, sessions, results and Undo backups go.
    func deleteFinishedTodoChats(_ rooms: [Conversation], olderThan days: Int?) {
        guard !importingMaterials else { return }
        // Checked again now: a TODO may have been sent back, a chat pinned or opened since the menu was drawn.
        var protected = runningRooms.union([currentID])
        if let parent = current.meetingOf?.room { protected.insert(parent) }
        let ids = Set(rooms.map(\.id))
        let cutoff = days.map { Date().addingTimeInterval(-Double($0) * 86400) }
        let chosen = SidebarProjects.deletable(conversations.filter { ids.contains($0.id) }, todo: TodoStore.shared.current,
                                               meetings: { self.meetings(of: $0) }, before: cutoff, protected: protected)
        guard !chosen.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L("끝난 TODO 채팅 \(chosen.count)개를 영구 삭제할까요?", "Permanently delete \(chosen.count) finished TODO chats?")
        alert.informativeText = L("채팅의 질문·답변, 회의, 세션 기록, 작업 결과, 파일 되돌리기(Undo) 백업이 지워져요. 되돌릴 수 없어요.\n할 일 보드의 TODO 기록(제목·결과·바뀐 파일·걸린 시간)과 TODO 첨부는 그대로 남아요. 프로젝트 폴더와 Git 기록도 그대로예요.",
                                  "Their messages, meetings, sessions, results and Undo backups are deleted. This cannot be undone.\nThe TODOs on the board (title, result, changed files, time) and their attachments stay, and so do the project folder and its Git history.")
        alert.addButton(withTitle: L("영구 삭제", "Delete"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let failed = removeChats(chosen)
        if failed > 0 {
            let failure = NSAlert()
            failure.messageText = L("\(failed)개 채팅을 지우지 못했어요", "Could not delete \(failed) chats")
            failure.informativeText = L("지우지 못한 채팅은 목록에 남겨뒀어요. 일부 자료는 이미 지워졌을 수 있어요.", "Chats that could not be deleted were kept in the list. Some of their files may already be gone.")
            failure.runModal()
        }
    }

    // Permanently deletes a whole project from the app (SidebarProjects.key): every chat of it (pinned ones, the
    // worktrees' chats and the meetings too), its TODO lists with their TODOs and attachments, and its project info.
    // The folder on disk and its Git history stay. Refused while any of it runs; checked again after asking.
    func deleteProject(_ key: String, name: String) {
        guard !importingMaterials else { return }
        func scope() -> (chats: [Conversation], meetings: Int, lists: Set<UUID>, todos: Int) {
            let chats = conversations.filter { $0.meetingOf == nil && $0.workspace?.project.map(SidebarProjects.key) == key }
            let todo = TodoStore.shared.current
            let lists = Set(todo.lists.filter { $0.project.map(SidebarProjects.key) == key }.map(\.id))
            return (chats, chats.map { meetings(of: $0.id).count }.reduce(0, +), lists, todo.items.filter { lists.contains($0.listID) }.count)
        }
        func refusal(_ s: (chats: [Conversation], meetings: Int, lists: Set<UUID>, todos: Int)) -> String? {
            let rooms = s.chats.flatMap { [$0.id] + meetings(of: $0.id).map(\.id) }
            if !runningRooms.isDisjoint(with: rooms) { return L("이 프로젝트의 채팅이 답하는 중이에요. 끝난 뒤 다시 해 주세요.", "A chat of this project is answering. Try again when it is done.") }
            if TodoStore.shared.current.items.contains(where: { s.lists.contains($0.listID) && $0.state == .running }) {
                return L("이 프로젝트의 TODO가 진행 중이에요. 끝나거나 멈춘 뒤 다시 해 주세요.", "A TODO of this project is running. Try again when it is done or stopped.")
            }
            // A held todos.json reads as empty: its lists for this project could be there, so nothing is deleted.
            if let locked = TodoStore.shared.locked { return locked }
            if ProjectInfoStore.shared.isLocked { return L("project-info.json을 읽지 못해서 프로젝트를 지우지 않았어요. 파일을 확인해 주세요.", "project-info.json could not be read, so the project was not deleted. Please check the file.") }
            return nil
        }
        func tell(_ title: String, _ text: String) {
            let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.runModal()
        }
        let cannot = L("프로젝트를 삭제할 수 없어요", "Cannot delete the project")
        let first = scope()
        if let why = refusal(first) { tell(cannot, why); return }
        let alert = NSAlert()
        alert.messageText = L("‘\(name)’ 프로젝트를 삭제할까요?", "Delete the project “\(name)”?")
        alert.informativeText = L("앱에서 이 프로젝트를 통째로 영구 삭제해요. 되돌릴 수 없어요.\n• 채팅 \(first.chats.count)개 (고정한 채팅, 같은 저장소의 다른 작업 폴더 채팅 포함)와 회의 기록 \(first.meetings)개, 그 세션·작업 결과·Undo 백업\n• TODO \(first.todos)개와 그 첨부\n• 프로젝트 정보 (바꾼 이름, 폴더, 링크)\n\n디스크의 프로젝트 폴더와 파일, Git 기록은 그대로예요. 나중에 폴더를 다시 연결하면 새 프로젝트로 시작해요.",
                                  "This permanently deletes the whole project from the app. This cannot be undone.\n• \(first.chats.count) chats (pinned ones and the chats of other worktrees of this repository too) and \(first.meetings) meeting records, with their sessions, results and Undo backups\n• \(first.todos) TODOs and their attachments\n• The project info (its name, folders and links)\n\nThe project folder on disk, its files and its Git history stay. Linking the folder again starts a new project.")
        alert.addButton(withTitle: L("프로젝트 삭제", "Delete Project"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Checked again: a chat may have started answering, a TODO started or a chat joined while the alert was up.
        let chosen = scope()
        if let why = refusal(chosen) { tell(cannot, why); return }
        // The TODOs first, in one save: if that fails nothing is deleted.
        do { try TodoStore.shared.deleteLists(chosen.lists) } catch { tell(cannot, error.localizedDescription); return }
        if viewingBoard && boardProject == key { viewingBoard = false; boardProject = nil }
        let failed = removeChats(chosen.chats)
        if failed > 0 {
            // What is left stays a project, with its name, folders and links.
            tell(L("\(failed)개 채팅을 지우지 못했어요", "Could not delete \(failed) chats"),
                 L("TODO는 지웠고, 지우지 못한 채팅은 프로젝트에 남겨뒀어요. 다시 삭제해 보세요.", "The TODOs are deleted; the chats that could not be deleted stay in the project. Try deleting it again."))
            return
        }
        do { try ProjectInfoStore.shared.forget(key) } catch {
            tell(L("프로젝트 정보를 지우지 못했어요", "Could not delete the project info"),
                 L("채팅과 TODO는 지웠어요. 프로젝트 이름·폴더·링크는 남아 있어서, 폴더를 다시 연결하면 다시 보여요.\n", "The chats and TODOs are deleted. Its name, folders and links are left and show again if the folder is linked again.\n") + error.localizedDescription)
        }
        SidebarFold.shared.forget(key)
    }

    func delete(_ id: UUID) {
        guard !runningRooms.contains(id), let conversation = conversations.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = L("이 대화를 영구 삭제할까요?", "Permanently delete this chat?")
        alert.informativeText = L("‘\(conversation.title)’의 질문, 답변, 대화 요약을 저장된 파일과 함께 삭제합니다. 되돌릴 수 없어요.", "This deletes all messages, answers, and the summary in “\(conversation.title)”, including its saved file. This cannot be undone.")
        alert.informativeText += L("\n이 방이 만든 세션 기록, 자료·첨부 사본, 작업 결과, 파일 백업도 함께 지워져요. 연결한 원본 폴더와 Gemini 자체 기록은 그대로예요.",
                                   "\nThe sessions, material and attachment copies, results and file backups this chat created are deleted too. Linked original folders and Gemini's own history stay.")
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
        removeMeetings(of: id)
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
        // Plain chat: "@Name" picked from the list, or typed ("@지피", "@ㅋㄹㄷ"), sends this one message to those accounts.
        let plain = Self.modernModes && configuration.mode == 0
        // "/work " at the start picks the way for this message, like the chip in the message box.
        var picked = forcedRoute ?? pickedRoute
        var typed = draft
        if plain, forcedRoute == nil, let found = Route.slash(draft, offered: routeChoices) { picked = found.route; typed = found.rest }
        let allowed = model.accounts.filter { Enterprise.permits($0, lock: current.enterpriseLock) }
        var mentioned = plain ? Self.mentions(in: typed, picked: draftMentions, accounts: allowed, label: label) : []
        for id in mentioned { if let account = model.accounts.first(where: { $0.id == id }) { typed = typed.replacingOccurrences(of: "@" + label(account), with: "") } }
        if plain {
            for found in Self.typedMentions(in: typed, accounts: model.accounts, label: label, lock: current.enterpriseLock,
                                            usage: model.latestUsage, localEnabled: model.localEnabled) {
                if let range = typed.range(of: found.token) { typed.replaceSubrange(range, with: "") }
                if !mentioned.contains(found.id) { mentioned.append(found.id) }
            }
        }
        typed = typed.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let question = !typed.isEmpty ? typed : !mentioned.isEmpty || picked != nil ? L("지금까지의 대화에 대해 네 의견을 말해 줘.", "What do you think about this conversation so far?")
            : L("첨부한 이미지를 설명해줘.", "Describe the attached images.")
        if let reason = startTurn(room: currentID, question: question, mentioned: mentioned, images: pendingImages, forced: picked) {
            attachmentError = reason
            return
        }
        draftMentions = []
        mentionQuery = nil
        slashMenu = nil
        pendingImages = []
        draft = ""
        pickedRoute = nil
        attachmentError = nil
    }

    // The ways the message box offers for the open chat (RouteChoice.offered); none in the team modes.
    var routeChoices: [RouteChoice] {
        guard Self.modernModes && configuration.mode == 0, current.meetingOf == nil else { return [] }
        return RouteChoice.offered(project: current.workspace?.project != nil)
    }

    // Starts a turn in any chat, whether it is open or not (send() is the message box's way in): the same
    // members, routes and workers as a typed message. The message box, its pictures and the open chat are
    // left as they are. On the main thread. Returns why nothing started, nil when the turn started.
    @discardableResult
    func startTurn(room id: UUID, question: String, mentioned: [String] = [], images: [ChatImage] = [],
                   forced: RouteChoice? = nil, extra: String = "") -> String? {
        guard host == nil, conversations.contains(where: { $0.id == id }) else { return L("대화를 찾지 못했어요.", "Chat not found.") }
        if runningRooms.contains(id) { return L("이 대화는 아직 답하는 중이에요.", "This chat is still answering.") }
        guard runningRooms.count < Self.maxRunning, !importingMaterials else {
            return L("동시에 \(Self.maxRunning)개 대화까지 답할 수 있어요. 하나가 끝나면 보낼 수 있어요.",
                     "Up to \(Self.maxRunning) chats can answer at once. Send when one finishes.")
        }
        let plain = Self.modernModes && configuration(of: id).mode == 0
        // Two or more members: in a plain chat they all answer every message (the lead first, the only one that may
        // change files); in a project chat the lead works and the others review (Peer.swift). @ replaces them for
        // this one message.
        if plain { settleMembers(room: id) }
        let project = conversation(id).workspace?.project != nil
        let crew = plain && mentioned.isEmpty ? self.crew(project: project, room: id) : nil
        if let crew, configuration(of: id).lastSoloAccountID != crew.lead { configure(room: id) { $0.lastSoloAccountID = crew.lead } }
        let members = crew.map { project ? [$0.lead] : [$0.lead] + $0.others } ?? []
        let reviewers = project ? crew?.others ?? [] : []
        let called = mentioned.isEmpty ? members : mentioned
        // A project chat with two or more members taking part: each message is sorted into one (the lead answers, read
        // only), all (every member answers, read only) or work (the lead works, the others review) before anyone
        // starts (Route.swift). @ skips this: one picked AI handles it, two or more give opinions.
        let standing = plain && project && mentioned.isEmpty ? standingMembers(room: id) : []
        // A way picked by the user (the chip, "/work", "Run as work") is not sorted. With @ the picked AIs answer that way:
        // @A @B + work, A works and B reviews; @A + work, A works and the other members review.
        // Members left automatic (none checked): a message that asks for a meeting holds one, one that asks several AIs
        // for views (or in a project chat any that asks for views) gets theirs (Route.asksMeeting, Route.askedViewers,
        // Route.asksViews), each with AIs the app picks (meetingTeam: two to four when that many can come). Not in a TODO's own run: its text is a task, not a way.
        let todoRun = TodoStore.shared.current.items.contains { $0.room == id && $0.state == .running }
        let autoMembers = plain && mentioned.isEmpty && memberIDs(room: id).isEmpty
        let meeting = plain && (forced == .meeting || (forced == nil && !todoRun && Route.asksMeeting(question)))
        // Asking several AIs in so many words ("2명 의견 줘") works in a plain chat too, with as many as asked for.
        let asked = !meeting && autoMembers && forced == nil && !todoRun ? Route.askedViewers(question) : nil
        let autoViews = !meeting && autoMembers && forced == nil && !todoRun && (asked != nil || (project && Route.found(Route.asksViews, question)))
        let autoAsked = autoMembers && !meeting && (forced == .all || autoViews)
        let autoTeam = autoAsked
            ? Self.meetingTeam(model.accounts, usage: model.latestUsage, most: asked ?? Self.meetingMost,
                                 picks: model.autoTeamPicks) { self.autoAllowed($0, room: id) }.map(\.id) : []
        let sorting = !meeting && (standing.count >= 2 || (forced != nil && project && plain) || (forced == .all && autoMembers) || autoViews)
        // Two or more picked with @ in a project chat and no way picked: their opinions, read only, never work.
        let pickedOpinion = plain && project && mentioned.count >= 2 && forced == nil
        let opinionLead = crew?.lead ?? standing.first { id in model.accounts.contains { $0.id == id && [.claude, .codex].contains($0.provider) } } ?? standing.first
        let opinionMembers = !mentioned.isEmpty ? mentioned : opinionLead.map { lead in [lead] + standing.filter { $0 != lead } } ?? []
        let judges = standing.compactMap { id in model.accounts.first { $0.id == id && [.claude, .codex].contains($0.provider) } }
        let doers = mentioned.isEmpty ? called : Array(mentioned.prefix(1))
        let checkers = mentioned.isEmpty ? reviewers : mentioned.count >= 2 ? Array(mentioned.dropFirst())
            : project ? memberIDs(room: id).filter { member in
                member != mentioned[0] && model.accounts.contains { $0.id == member && [.claude, .codex].contains($0.provider) && permits($0, room: id) }
                && model.latestUsage[member]?.needsLogin != true && (model.latestUsage[member]?.leftNow ?? 50) > 0
            } : []
        let team = called.isEmpty ? pickTeam(room: id) : called.compactMap { id in model.accounts.first { $0.id == id } }
        // A meeting (Meeting.swift): who meets, in a hidden chat of its own.
        let meetingTeam = meeting ? meetingMembers(room: id, mentioned: mentioned, fallback: team) : []
        if meeting && meetingTeam.isEmpty {
            return autoMembers && mentioned.isEmpty
                ? L("회의할 수 있는 AI가 없어요. 설정 → 채팅 → \"자동으로 부를 AI\"에서 로그인된 AI를 켜 주세요.",
                    "No AI can meet. Turn on a signed-in AI in Settings → Chat → \"AIs picked automatically\".")
                : L("회의할 수 있는 AI가 없어요. Claude·ChatGPT·Gemini 중 로그인된 AI를 참여시켜 주세요.", "No AI can meet. Add a signed-in Claude, ChatGPT or Gemini.")
        }
        var turn = ChatTurn(question: question)
        turn.askedAt = Date()
        turn.mentions = mentioned.isEmpty ? nil : mentioned
        let config = configuration(of: id)
        turn.mode = config.mode
        turn.modeVersion = Self.modernModes ? 2 : nil
        turn.images = images.isEmpty ? nil : images
        let perAI = min(10, max(2, config.turnsPerAI ?? 4))
        if (Self.modernModes && (1...2).contains(config.mode)) || (!Self.modernModes && config.mode == 3) {
            turn.turnsPerAI = perAI; turn.maxTurns = perAI * team.count
        }
        // A meeting needs only its own team (it may be Gemini alone, which does not answer this chat by itself).
        guard team.count > 0 || !meetingTeam.isEmpty else {
            turn.error = L("답할 수 있는 AI가 없어요. 참여 AI를 켜고, 설정에서 로그인됐는지 확인해 주세요.", "No AI is available. Enable a participant and check its sign-in in Settings.")
            return turn.error
        }
        activeSessionRoom = config.sessionsOn && (Self.modernModes || config.mode == 3) ? id : nil
        let chat = conversation(id)
        activeMaterials = chat.documents ?? []
        let solo = Self.modernModes && config.mode == 0
        activeWorkspace = solo ? soloBinding(id) : chat.workspace
        if !solo, var readOnly = activeWorkspace, readOnly.project != nil {
            readOnly.project = nil
            readOnly.level = .view
            readOnly.roots = readOnly.roots.map { WorkspaceRoot(path: $0.path, directory: $0.directory) }
            activeWorkspace = readOnly
        }
        activeAdversarial = Self.modernModes && config.mode == 2
        activeSpeechLength = SpeechLength.clamp(config.speechLength)
        // Mode 0 names its folders after the session marker, so a new file does not restart the session.
        activeDocumentText = solo ? MaterialContext.overview(activeMaterials) : activeWorkspace?.description ?? MaterialContext.overview(activeMaterials)
        let history = chat.turns
        // Everything earlier in this chat that the AIs should see: the user's photos and the pictures
        // the AIs drew, in order. New pictures made in this turn are added as they arrive.
        var shared: [(ChatImage, String)] = []
        for t in history + [turn] {
            shared += (t.images ?? []).map { ($0, "attachment \($0.id.uuidString), user message: \(t.question.prefix(160))") }
            for entry in t.entries { shared += (entry.images ?? []).map { ($0, "\($0.name.replacingOccurrences(of: ".png", with: "")) drawn by \(entry.speaker)") } }
            shared += (t.finalImages ?? []).map { ($0, "\($0.name.replacingOccurrences(of: ".png", with: "")) in the final answer by \(t.finalBy ?? "")") }
        }
        let sent = Self.picturesToSend(shared.map(\.1), current: (turn.images ?? []).count, question: question)
        pictureLock.lock()
        activeImages = shared.indices.filter(sent.contains).map { shared[$0].0.url }
        imageNumber = shared.count
        imageContext = shared.enumerated().map {
            "Image \($0.offset + 1): " + (sent.contains($0.offset) ? "" : "(not attached; the user can name \"Image \($0.offset + 1)\" to show it again) ") + $0.element.1
        }.joined(separator: "\n")
        nextPicture = history.reduce(1) { n, t in n + t.entries.reduce(0) { $0 + ($1.images?.count ?? 0) } + (t.finalImages?.count ?? 0) }
        pictureLock.unlock()
        // Mode 1 sends the running summary, which only mode 1 updates. After messages in modes 2/3,
        // add those exchanges in full so mode 1 (and its next summary) knows about them.
        var summary = chat.summary
        if config.mode == 1 {
            let lastSummarized = history.lastIndex { ($0.mode ?? 1) == 1 && $0.final != nil }
            let since = history[(lastSummarized.map { $0 + 1 } ?? 0)...].filter { ($0.mode ?? 1) != 1 }
            if !since.isEmpty {
                summary += (summary.isEmpty ? "" : "\n\n") + "[요약 이후 다른 방식으로 나눈 대화 원문]\n" + Self.transcript(Array(since))
            }
        }
        // One more turn shown, so the oldest shown one does not drop off the top while the
        // view scrolls to the new one (that left the transcript blank until the next scroll).
        if id == currentID { shownTurns += 1 }
        change(id, save: true) { c in
            if c.turns.isEmpty { c.title = String(question.prefix(40)) }
            c.turns.append(turn)
        }
        let index = conversation(id).turns.count - 1
        let meetingID = meeting ? openMeeting(for: id, turn: turn, history: history) : UUID()
        let cancellation = DebateCancellation()
        let worker = Discussion(workerFor: self, room: id)
        worker.runCancellation = (Self.modernModes || config.mode == 3) ? cancellation : nil
        worker.activeSessionRoom = activeSessionRoom
        worker.activeMaterials = activeMaterials
        worker.activeWorkspace = activeWorkspace
        worker.activeAdversarial = activeAdversarial
        worker.activeSpeechLength = activeSpeechLength
        worker.activeDocumentText = activeDocumentText
        pictureLock.lock()
        worker.activeImages = activeImages; worker.imageContext = imageContext; worker.imageNumber = imageNumber; worker.nextPicture = nextPicture
        pictureLock.unlock()
        workers[id] = worker
        runningRooms.insert(id)
        stoppingRooms.remove(id)
        let usage = model.latestUsage
        let rules = model.chatRules.trimmingCharacters(in: .whitespacesAndNewlines)
        // One member in a project chat, no way or AI picked, not a TODO's own run: while another chat or TODO is changing the
        // project, that member answers read only instead of failing as busy.
        let rerouteBusy = project && mentioned.isEmpty && forced == nil && !TodoStore.shared.current.items.contains { $0.room == id && $0.state == .running }
        let debateLeader = Self.modernModes && !team.isEmpty && !team.contains(where: { $0.provider == config.leader }) ? team[0].provider : config.leader
        worker.work.async {
            // Only work that may write takes the repository lock, once its route is known: meetings, opinions and
            // one-member answers read the project, so other chats can talk while a TODO or chat is changing it.
            var projectLocks: [String] = []
            defer { ProjectWork.release(projectLocks) }
            func lock() -> Bool {
                do { projectLocks = try ProjectWork.acquire(worker.activeWorkspace); return true }
                catch { worker.finish(id, index, error: error.localizedDescription); return false }
            }
            if meeting {
                worker.runMeeting(question: question, history: history, rules: rules, team: meetingTeam, room: meetingID,
                                  cancellation: cancellation, id: id, index: index)
            } else if pickedOpinion {
                // Two or more picked with @ in a project chat: each gives an opinion, read only. "Run as work" sends it again without the @.
                let name = { (accountID: String) in worker.model.accounts.first { $0.id == accountID }.map(worker.label) ?? accountID }
                let note = Self.routeNote(.all, by: nil, names: mentioned.map(name), forced: true)
                worker.changeTurn(id, index, save: true) { $0.route = RouteChoice.all.route; $0.routeNote = note }
                let binding = worker.activeWorkspace ?? worker.soloBinding(id)
                worker.activeWorkspace = Route.opinionView(binding, chatFolder: Self.chatFolder(id).path)
                let peer = worker.beginPeer(id: id, index: index, question: question, binding: worker.activeWorkspace ?? binding, cancellation: cancellation)
                worker.runSolo(question: question, history: history, rules: rules, config: config, mentions: mentioned,
                               cancellation: cancellation, id: id, index: index,
                               extra: Route.opinionNote(project: binding.project?.root ?? "", alone: false))
                worker.endPeer(peer)
            } else if solo && sorting {
                var route = forced ?? (autoViews ? .all : .work), by: String? = autoViews ? L("규칙", "rule") : nil, busy = false
                if forced == nil && !autoViews {
                    // Another chat or TODO is changing the project: the judge picks between one and all, so this chat still answers.
                    busy = ProjectWork.busy(worker.activeWorkspace)
                    worker.changeTurn(id, index) { $0.status = L("한 명이 답할지, 모두 답할지, 작업할지 판정하는 중…", "Deciding: one answer, everyone, or work…") }
                    (route, by) = worker.decideRoute(question: question, history: history, judges: judges, busy: busy, cancellation: cancellation)
                    if cancellation.isCancelled { return worker.endSolo(id, index, stopped: true) }
                }
                // Judged work but another writer started meanwhile: an opinion instead. Work the user picked (/w) still says it is busy.
                if route == .work {
                    do { projectLocks = try ProjectWork.acquire(worker.activeWorkspace) }
                    catch let error where forced == nil && ProjectWork.isBusy(error.localizedDescription) { busy = true; route = Route.withoutWork(route, question: question) }
                    catch { return worker.finish(id, index, error: error.localizedDescription) }
                }
                let name = { (accountID: String) in worker.model.accounts.first { $0.id == accountID }.map(worker.label) ?? accountID }
                // Opinions never fall back to work: with fewer than two members ready (or picked by the app), the lead answers alone.
                // Views the app picks for (autoTeamPicks in Settings → Chat): only those AIs, one answers alone, none: no answer.
                let picked = route == .all && opinionMembers.count < 2 && autoAsked
                if picked && autoTeam.isEmpty {
                    worker.changeTurn(id, index, save: true) {
                        $0.error = L("의견을 줄 AI가 없어요. 설정 → 채팅 → \"자동으로 부를 AI\"에서 로그인된 AI를 켜 주세요.",
                                     "No AI can give a view. Turn on a signed-in AI in Settings → Chat → \"AIs picked automatically\".")
                    }
                    return worker.endSolo(id, index, stopped: false)
                }
                let viewers = picked ? autoTeam : opinionMembers
                if route == .all && viewers.count < 2 { route = .one }
                // Run again after members dropped out (none of them standing): whoever answers this chat now.
                let answering = route == .one ? Array((picked ? autoTeam : opinionMembers.isEmpty ? team.map(\.id) : opinionMembers).prefix(1)) : viewers
                guard route == .work || !answering.isEmpty else {
                    worker.changeTurn(id, index, save: true) { $0.error = L("답할 수 있는 AI가 없어요.", "No AI is available.") }
                    return worker.endSolo(id, index, stopped: false)
                }
                let note = route == .work
                    ? Self.routeNote(.work, by: by, names: doers.isEmpty ? team.map(worker.label) : doers.map(name), reviewers: checkers.map(name), forced: forced != nil)
                    : Self.routeNote(route, by: by, names: answering.map(name), forced: forced != nil, busy: busy)
                worker.changeTurn(id, index, save: true) { $0.route = route.route; $0.routeOne = route == .one ? true : nil; $0.routeNote = note }
                let binding = worker.activeWorkspace ?? worker.soloBinding(id)
                if route != .work {
                    worker.activeWorkspace = Route.opinionView(binding, chatFolder: Self.chatFolder(id).path)
                    let peer = worker.beginPeer(id: id, index: index, question: question, binding: worker.activeWorkspace ?? binding, cancellation: cancellation)
                    worker.runSolo(question: question, history: history, rules: rules, config: config, mentions: answering,
                                   cancellation: cancellation, id: id, index: index,
                                   extra: Route.opinionNote(project: binding.project?.root ?? "", alone: answering.count == 1, busy: busy))
                    worker.endPeer(peer)
                } else {
                    let peer = worker.beginPeer(id: id, index: index, question: question, reviewers: checkers, binding: binding, cancellation: cancellation)
                    worker.runSolo(question: question, history: history, rules: rules, config: config, mentions: doers,
                                   reviewers: checkers, cancellation: cancellation, id: id, index: index, extra: (forced == nil ? Route.workNote() : "") + extra)
                    worker.endPeer(peer)
                }
            } else if solo {
                do { projectLocks = try ProjectWork.acquire(worker.activeWorkspace) }
                catch let error where rerouteBusy && ProjectWork.isBusy(error.localizedDescription) {
                    let name = { (accountID: String) in worker.model.accounts.first { $0.id == accountID }.map(worker.label) ?? accountID }
                    let answering = Array((called.isEmpty ? team.map(\.id) : called).prefix(1))
                    let note = Self.routeNote(.one, by: L("앱", "the app"), names: answering.map(name), busy: true)
                    worker.changeTurn(id, index, save: true) { $0.route = RouteChoice.one.route; $0.routeOne = true; $0.routeNote = note }
                    let binding = worker.activeWorkspace ?? worker.soloBinding(id)
                    worker.activeWorkspace = Route.opinionView(binding, chatFolder: Self.chatFolder(id).path)
                    let peer = worker.beginPeer(id: id, index: index, question: question, binding: worker.activeWorkspace ?? binding, cancellation: cancellation)
                    defer { worker.endPeer(peer) }
                    return worker.runSolo(question: question, history: history, rules: rules, config: config, mentions: answering,
                                          cancellation: cancellation, id: id, index: index,
                                          extra: Route.opinionNote(project: binding.project?.root ?? "", alone: true, busy: true))
                }
                catch { return worker.finish(id, index, error: error.localizedDescription) }
                // ask_ai during the answer (Peer.swift); with reviewers (a project chat with two or more members) also
                // a review of what changed, and the lead fixes what is right.
                let binding = worker.activeWorkspace ?? worker.soloBinding(id)
                let peer = worker.beginPeer(id: id, index: index, question: question, reviewers: reviewers, binding: binding, cancellation: cancellation)
                worker.runSolo(question: question, history: history, rules: rules, config: config, mentions: called,
                             reviewers: reviewers, cancellation: cancellation, id: id, index: index, extra: extra)
                worker.endPeer(peer)
            } else if !lock() {
                return
            } else if Self.modernModes && config.mode == 4 {
                worker.runVote(question: question, history: history, rules: rules, team: team,
                             leader: team.first { $0.id == config.leaderAccountID } ?? team.first { $0.provider == config.leader } ?? team[0],
                             cancellation: cancellation, id: id, index: index)
            } else if Self.modernModes && config.mode == 3 {
                worker.runCollaboration(question: question, history: history, rules: rules, team: team,
                                      leader: config.leaderAccountID, fallbackLeader: config.leader,
                                      cancellation: cancellation, id: id, index: index)
            } else if Self.modernModes || config.mode == 3 {
                worker.runDebate(question: question, history: history, rules: rules, team: team, leader: debateLeader,
                               perAI: perAI, cancellation: cancellation, id: id, index: index)
            } else if config.mode == 2 {
                worker.runSequential(question: question, history: history, rules: rules, team: team,
                                   leader: config.leader, id: id, index: index)
            } else {
                worker.run(question: question, summary: summary, rules: rules, team: team, usage: usage, id: id, index: index)
            }
        }
        return nil
    }

    // Per AI, the logged-in account with the most usage left (accounts at 0% are skipped).
    func pickTeam() -> [Account] { pickTeam(room: currentID) }
    func pickTeam(room: UUID) -> [Account] {
        let configuration = configuration(of: room)
        var providers: [Account.Provider] = []
        if useClaude { providers.append(.claude) }
        if useCodex { providers.append(.codex) }
        if useGemini { providers.append(.gemini) }
        if Self.modernModes || configuration.mode >= 2 {
            providers = configuration.order.filter { configuration.participants.contains($0) }
        }
        if Self.modernModes && configuration.mode == 0 { return soloNext(room: room).map { [$0] } ?? [] }
        // Vote: every account votes (personal and school ones too), except the ones turned off.
        if Self.modernModes && configuration.mode == 4 {
            let skipped = configuration.voteSkippedIDs ?? []
            let voters = model.accounts.filter { account in
                !skipped.contains(account.id) && (account.provider != .ollama || model.localEnabled)
                && model.latestUsage[account.id]?.needsLogin != true && (model.latestUsage[account.id]?.leftNow ?? 50) > 0
            }
            // One Gemma at most (only one fits in memory): the first one not turned off for this vote.
            let gemma = voters.first { $0.provider == .ollama }
            return voters.filter { $0.provider != .ollama || $0.id == gemma?.id }
        }
        if Self.modernModes && configuration.mode == 3 {
            return model.accounts.filter { account in
                (configuration.accountIDs?.contains(account.id) ?? false)
                && model.latestUsage[account.id]?.needsLogin != true && (model.latestUsage[account.id]?.leftNow ?? 50) > 0
            }
        }
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
                        guard configuration.sessionsOn else { return item.1 }
                        if nativeSessions.pinnedAccount(provider, room: room) == item.0.id { return 300 + item.1 }
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
        if let host { return host.change(id, save: save, edit) }
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
            // Plain chat: the message, then each reply under the name of the AI that wrote it.
            if turn.mode == 0 && turn.modeVersion == 2 {
                var parts = ["[User]\n" + turn.question]
                if let images = turn.images, !images.isEmpty { parts.append("[Images: " + images.map { $0.id.uuidString }.joined(separator: ", ") + "]") }
                if let final = turn.final { parts.append("[\(turn.finalBy ?? "AI")]\n" + final) }
                parts += (turn.moreAnswers ?? []).filter { !$0.failed }.map { "[\($0.speaker)]\n" + $0.text }
                return parts.joined(separator: "\n\n")
            }
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
        changeTurn(id, index, save: true) { t in
            if let error {
                t.error = error
                t.status = ""
            }
            if t.askedAt != nil { t.answeredAt = Date() }
        }
        let room = currentID
        DispatchQueue.main.async {
            if let host = self.host { return host.runFinished(room) }
            self.runningRooms.remove(room)
            self.stoppingRooms.remove(room)
            self.model.onAccountsChange?()   // refresh the usage numbers after the discussion
            DeviceSync.shared.noteFinished(self.conversations.first { $0.id == room })
        }
    }

    static func describe(_ failure: Answerer.Failure) -> String {
        switch failure {
        case .missingTool: return L("프로그램을 찾지 못했어요.", "CLI not found.")
        case .timedOut: return L("시간 안에 답하지 못했어요.", "The response timed out.")
        case .failed(let why):
            let lower = why.lowercased()
            if lower.contains("auto-denied") || lower.contains("headless mode cannot prompt") {
                // agy names the blocked permission: `a tool required the "command" permission`.
                var tool = L("도구", "tool")
                if let range = why.range(of: #"the "[a-z_]+" permission"#, options: .regularExpression) {
                    let name = why[range].split(separator: "\"")[1]
                    tool = name == "command" ? L("터미널 명령", "terminal command") : name == "read_url" ? L("웹 페이지 열기", "opening a web page")
                        : L("도구(\(name))", "tool (\(name))")
                }
                return L("\(tool) 사용에 승인이 필요하지만 이 실행에서는 승인을 받을 수 없어 답을 멈췄어요. 계정·개인 권한은 바꾸지 않았어요.",
                         "Stopped: \(tool) needs approval, which this run cannot ask for. Account and personal permissions were not changed.")
            }
            return L("답하지 못했어요.", "Could not respond.") + (why.isEmpty ? "" : " (\(why))")
        }
    }
}

extension ChatTurn.Entry {
    // AIs begin each reply with "TL;DR: …". That line becomes the headline; the rest is the full reply.
    static func reply(round: Int, speaker: String, text: String) -> Self {
        var entry = Self(round: round, speaker: speaker, text: text, failed: false)
        (entry.headline, entry.text) = ReplyHeadline.split(text)
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
