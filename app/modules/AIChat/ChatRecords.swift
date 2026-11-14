import Foundation
import AIAccounts
import AILocalization
import AISpaces
import AIRuntime
import AIWorkspace
import AIProjects

// A chat's record and where it is kept: chats/<id>.json (Conversation), its turns (ChatTurn) and settings
// (ChatConfiguration). The fields are the saved format, so they are public and keep their names; older keys stay
// (they are read, some only once). What else keeps a chat's data is told through ChatStore.links (set by the app).

// One question and how the AIs worked it out.
public struct ChatTurn: Identifiable, Codable, Equatable {
    public struct Entry: Identifiable, Codable, Equatable {
        public var id = UUID()
        public var round: Int        // 1 = own answer, 2 = after reading the others
        public var speaker: String
        public var text: String
        public var failed: Bool
        public var focus: String?
        public var headline: String?  // one short line the chat shows; `text` opens on click
        public var images: [ChatImage]?  // pictures this AI made in this reply (Pictures.swift)
        public var accountID: String?    // mode 0, several AIs at once: whose reply this is (labels can repeat)
        public var meeting: UUID?        // a meeting an AI convened (convene_meeting): its hidden chat, shown as "Show the meeting"
        public init(id: UUID = UUID(), round: Int, speaker: String, text: String, failed: Bool, focus: String? = nil, headline: String? = nil, images: [ChatImage]? = nil, accountID: String? = nil, meeting: UUID? = nil) {
            self.id = id
            self.round = round
            self.speaker = speaker
            self.text = text
            self.failed = failed
            self.focus = focus
            self.headline = headline
            self.images = images
            self.accountID = accountID
            self.meeting = meeting
        }
    }
    public var id = UUID()
    public var question: String
    public var images: [ChatImage]?
    public var status = ""
    public var entries: [Entry] = []
    public var final: String?
    public var finalImages: [ChatImage]?
    public var finalBy: String?
    public var error: String?
    public var mode: Int?  // missing in older chats means mode 1
    public var orderNote: String?
    public var endReason: String?
    public var modeVersion: Int?
    public var tasks: [CollaborationTask]?
    public var artifact: String?
    public var projectCommitted: Bool?
    public var projectPushed: Bool?
    public var backupPath: String?
    public var workspaceChanges: [WorkspaceChange]?
    public var projectLog: [String]?   // project tools this turn used, e.g. "git_push → …", newest last
    public var undone: Bool?
    public var sessionTranscript: String?
    public var debateFocus: String?
    public var maxTurns: Int?    // mode 3: total AI turns (turnsPerAI × participants)
    public var turnsPerAI: Int?  // missing in older chats, whose limit was a single total
    public var mentions: [String]?     // mode 0: accounts called with @ for this message, in order (nil = automatic)
    public var moreAnswers: [Entry]?   // mode 0: replies after the first when several AIs were called with @
    public var partial: String?        // mode 0: the reply so far while it is being written (cleared when done)
    public var partialBy: String?      // mode 0: who is writing it
    // Mode 0, several AIs answering at once (shown side by side, ChatWindow.swift): the accounts called, in order,
    // their names then, each one's reply so far while it is written, and the account of `final`.
    public var answerOrder: [String]?
    public var answerNames: [String]?
    public var partials: [String: String]?
    public var finalAccountID: String?
    public var activity: String?       // mode 0: what that AI is doing now (reading files, searching…)
    public var voteOptions: [String]?  // mode 4: the choices voted on
    public var votes: [VoteBallot]?    // mode 4: one ballot per AI, in the team's order
    public var askedAt: Date?          // when the message was sent (missing in older chats)
    public var answeredAt: Date?       // when the answer finished
    public var peerNotes: [Entry]?     // mode 0: opinions the AI asked for and reviews of the work (Peer.swift)
    public var peerFolded: Bool?       // collaboration "on its own" (CollabLog.swift): those cards folded into one line
    public var route: ChatRoute?       // project chat with members: how this message was answered (Route.swift)
    public var routeNote: String?      // "Opinion · 3 AIs · judged by Gemma 4 E4B", shown above the answer
    public var routeOne: Bool?         // with route opinion: only the lead answered (nil: everyone did)
    public var meetingRoom: UUID?      // with route opinion: the members met in this hidden chat and `final` is their result (Meeting.swift)
    // Project work: the step list (the AI's, then the app's review steps), why it last changed, when the AI last
    // did something (the chat says "last activity 4 min ago", never "stuck") and whether an approval card waits.
    public var plan: [WorkStep]?
    public var planNote: String?
    public var lastActivityAt: Date?
    public var waitingApproval: Bool?
    public var spaceDraft: SpaceDraftNote?   // the Space this answer made: a preview card under it (SpaceView.swift)
    public var spaceEdits: [SpaceSyncNote]?  // Spaces this answer changed in the Spaces folder, as checked after it (SpaceLibrary.sync)
    public var followUps: [String]?          // messages sent while it answered that the AI read in this answer (steering)
    public init(id: UUID = UUID(), question: String, images: [ChatImage]? = nil, status: String = "", entries: [Entry] = [], final: String? = nil, finalImages: [ChatImage]? = nil, finalBy: String? = nil, error: String? = nil, mode: Int? = nil, orderNote: String? = nil, endReason: String? = nil, modeVersion: Int? = nil, tasks: [CollaborationTask]? = nil, artifact: String? = nil, projectCommitted: Bool? = nil, projectPushed: Bool? = nil, backupPath: String? = nil, workspaceChanges: [WorkspaceChange]? = nil, projectLog: [String]? = nil, undone: Bool? = nil, sessionTranscript: String? = nil, debateFocus: String? = nil, maxTurns: Int? = nil, turnsPerAI: Int? = nil, mentions: [String]? = nil, moreAnswers: [Entry]? = nil, partial: String? = nil, partialBy: String? = nil, answerOrder: [String]? = nil, answerNames: [String]? = nil, partials: [String: String]? = nil, finalAccountID: String? = nil, activity: String? = nil, voteOptions: [String]? = nil, votes: [VoteBallot]? = nil, askedAt: Date? = nil, answeredAt: Date? = nil, peerNotes: [Entry]? = nil, peerFolded: Bool? = nil, route: ChatRoute? = nil, routeNote: String? = nil, routeOne: Bool? = nil, meetingRoom: UUID? = nil, plan: [WorkStep]? = nil, planNote: String? = nil, lastActivityAt: Date? = nil, waitingApproval: Bool? = nil, spaceDraft: SpaceDraftNote? = nil, spaceEdits: [SpaceSyncNote]? = nil) {
        self.id = id
        self.question = question
        self.images = images
        self.status = status
        self.entries = entries
        self.final = final
        self.finalImages = finalImages
        self.finalBy = finalBy
        self.error = error
        self.mode = mode
        self.orderNote = orderNote
        self.endReason = endReason
        self.modeVersion = modeVersion
        self.tasks = tasks
        self.artifact = artifact
        self.projectCommitted = projectCommitted
        self.projectPushed = projectPushed
        self.backupPath = backupPath
        self.workspaceChanges = workspaceChanges
        self.projectLog = projectLog
        self.undone = undone
        self.sessionTranscript = sessionTranscript
        self.debateFocus = debateFocus
        self.maxTurns = maxTurns
        self.turnsPerAI = turnsPerAI
        self.mentions = mentions
        self.moreAnswers = moreAnswers
        self.partial = partial
        self.partialBy = partialBy
        self.answerOrder = answerOrder
        self.answerNames = answerNames
        self.partials = partials
        self.finalAccountID = finalAccountID
        self.activity = activity
        self.voteOptions = voteOptions
        self.votes = votes
        self.askedAt = askedAt
        self.answeredAt = answeredAt
        self.peerNotes = peerNotes
        self.peerFolded = peerFolded
        self.route = route
        self.routeNote = routeNote
        self.routeOne = routeOne
        self.meetingRoom = meetingRoom
        self.plan = plan
        self.planNote = planNote
        self.lastActivityAt = lastActivityAt
        self.waitingApproval = waitingApproval
        self.spaceDraft = spaceDraft
        self.spaceEdits = spaceEdits
    }
}

// Times under the messages and the day lines between them, like the desktop apps.
public enum ChatTime {
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
    public static func stamp(_ date: Date, now: Date = Date(), language: AppLanguage = .current) -> String {
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
    public static func day(_ date: Date, now: Date = Date(), language: AppLanguage = .current) -> String {
        let calendar = calendar(language)
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        if language == .korean {
            return format(sameYear ? "MMMd" : "yMMMd", date, language) + " (" + format("EEE", date, language) + ")"
        }
        return format(sameYear ? "EEEMMMd" : "EEEyMMMd", date, language)
    }

    // When the turn happened, for the day lines: older turns have no time of their own,
    // except the chat's last turn, which ended about when the chat was last changed.
    public static func when(_ turn: ChatTurn, last: Bool, updatedAt: Date) -> Date? {
        turn.askedAt ?? (last ? updatedAt : nil)
    }
}

// How much each AI may say per turn in the discussion modes. The user mostly reads the one-line
// headlines and the final answer, so turns can be longer; longer turns cost more usage because every
// later turn re-reads the whole transcript.
public enum SpeechLength {
    // 0 = no limit (the default): the AI says what its point needs. The user mostly reads the one-line
    // headlines and the final answer, and sessions send each AI only what is new, so longer turns cost less
    // than they seem.
    public static let unlimited = 0, short = 400, standard = 800, long = 1500
    public static let all = [unlimited, short, standard, long]

    public static func clamp(_ value: Int?) -> Int { all.contains(value ?? -1) ? value! : unlimited }

    public static func name(_ value: Int) -> String {
        switch value {
        case short: return L("짧게 · 400자", "Short · 400 chars")
        case standard: return L("보통 · 800자", "Medium · 800 chars")
        case long: return L("길게 · 1500자", "Long · 1500 chars")
        default: return L("제한 없음", "No limit")
        }
    }

    public static func rule(_ value: Int) -> String {
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
public struct ChatConfiguration: Codable {
    public var mode = 1
    public var order: [Account.Provider] = [.claude, .codex, .gemini]
    // Gemini is off by default in every mode (turn it on per chat); chats that saved a list keep it.
    public var participants: [Account.Provider] = [.claude, .codex]
    public var leader: Account.Provider = .claude
    public var maxTurns: Int?    // old total limit, no longer used
    public var turnsPerAI: Int?  // mode 3: turns each AI may speak (default 4)
    public var speechLength: Int? // discussion modes: characters per AI turn (no limit by default, or 400 / 800 / 1500)
    public var keepSessions: Bool?   // no longer used: sessions are always kept (older chats may have saved false)
    public var sessionsOn: Bool { true }
    public var modeVersion: Int?
    public var accountIDs: [String]?
    public var leaderAccountID: String?
    public var voteSkippedIDs: [String]?  // mode 4: accounts turned off; every other account votes
    public var soloAccountID: String?      // mode 0: the account picked by hand (nil = automatic)
    public var lastSoloAccountID: String?  // mode 0: who answered last; it keeps going while it has usage left
    // mode 0: the chat's members (Solo.swift). Two or more: in a plain chat they all answer every message at the
    // same time; in a project chat the lead works and the others review (Peer.swift). One member is the same as
    // soloAccountID; nil or empty = automatic. Not synced: account IDs differ per Mac.
    public var memberIDs: [String]?
    public var leadID: String?             // the member picked by hand to do the work (nil = the app picks and keeps one)
    public var school: Bool?               // older: the side the first answer picked (no longer used; Enterprise.swift)
    // Older review settings, read once to make the reviewer a member (Discussion.migratedMembers).
    public var peerReview: Bool?
    public var peerAccountID: String?
    public var lastReviewSHA: String?
    public var lastReviewAt: Date?
    public var nextReviewAt: Date?
    public var pendingReview: String?
    public init(mode: Int = 1, order: [Account.Provider] = [.claude, .codex, .gemini], participants: [Account.Provider] = [.claude, .codex], leader: Account.Provider = .claude, maxTurns: Int? = nil, turnsPerAI: Int? = nil, speechLength: Int? = nil, keepSessions: Bool? = nil, modeVersion: Int? = nil, accountIDs: [String]? = nil, leaderAccountID: String? = nil, voteSkippedIDs: [String]? = nil, soloAccountID: String? = nil, lastSoloAccountID: String? = nil, memberIDs: [String]? = nil, leadID: String? = nil, school: Bool? = nil, peerReview: Bool? = nil, peerAccountID: String? = nil, lastReviewSHA: String? = nil, lastReviewAt: Date? = nil, nextReviewAt: Date? = nil, pendingReview: String? = nil) {
        self.mode = mode
        self.order = order
        self.participants = participants
        self.leader = leader
        self.maxTurns = maxTurns
        self.turnsPerAI = turnsPerAI
        self.speechLength = speechLength
        self.keepSessions = keepSessions
        self.modeVersion = modeVersion
        self.accountIDs = accountIDs
        self.leaderAccountID = leaderAccountID
        self.voteSkippedIDs = voteSkippedIDs
        self.soloAccountID = soloAccountID
        self.lastSoloAccountID = lastSoloAccountID
        self.memberIDs = memberIDs
        self.leadID = leadID
        self.school = school
        self.peerReview = peerReview
        self.peerAccountID = peerAccountID
        self.lastReviewSHA = lastReviewSHA
        self.lastReviewAt = lastReviewAt
        self.nextReviewAt = nextReviewAt
        self.pendingReview = pendingReview
    }
}

public struct Conversation: Identifiable, Codable {
    public var id = UUID()
    public var title = L("새 대화", "New chat")
    public var createdAt = Date()
    public var updatedAt = Date()
    public var turns: [ChatTurn] = []
    public var summary = ""
    public var configuration: ChatConfiguration?
    public var documents: [RoomDocument]?
    public var workspace: WorkspaceBinding?
    public var pinned: Bool?   // kept at the top of the list
    public var origin: SyncOrigin?       // continued on this Mac from another Mac's copy (DeviceSync.swift)
    public var shareToDevices: Bool?     // shown on your other Macs (when only chosen chats are shared)
    // Locked by the user as an Enterprise chat (Enterprise.swift); never removed. nil = an open chat.
    public var enterpriseLock: EnterpriseLock?
    // A meeting's own chat (Meeting.swift): the message it was held for. Not listed, searched or synced; deleted with that chat.
    public var meetingOf: MeetingLink?
    // Messages sent while it answered, waiting for the answer to end (Discussion.flushQueue sends them together).
    public var queued: [QueuedMessage]?

    // Something worth keeping: messages, materials or a linked folder. A chat with only settings is
    // "blank": it is not kept in the list once you leave it.
    public var hasContent: Bool { !turns.isEmpty || !(documents ?? []).isEmpty || workspace != nil }
    public init(id: UUID = UUID(), title: String = L("새 대화", "New chat"), createdAt: Date = Date(), updatedAt: Date = Date(), turns: [ChatTurn] = [], summary: String = "", configuration: ChatConfiguration? = nil, documents: [RoomDocument]? = nil, workspace: WorkspaceBinding? = nil, pinned: Bool? = nil, origin: SyncOrigin? = nil, shareToDevices: Bool? = nil, enterpriseLock: EnterpriseLock? = nil, meetingOf: MeetingLink? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.turns = turns
        self.summary = summary
        self.configuration = configuration
        self.documents = documents
        self.workspace = workspace
        self.pinned = pinned
        self.origin = origin
        self.shareToDevices = shareToDevices
        self.enterpriseLock = enterpriseLock
        self.meetingOf = meetingOf
    }
}

// A message sent while its chat was answering, as it was typed: read again (its @ and /way) when it is sent.
public struct QueuedMessage: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var text: String
    public var images: [ChatImage]?
    public var mentions: [String]?   // accounts picked from the @ list
    public var route: String?        // the way picked with the chip (RouteChoice raw value)
    public var sentAt = Date()
    public init(id: UUID = UUID(), text: String, images: [ChatImage]? = nil, mentions: [String]? = nil, route: String? = nil, sentAt: Date = Date()) {
        self.id = id; self.text = text; self.images = images; self.mentions = mentions; self.route = route; self.sentAt = sentAt
    }
}

public enum ChatStore {
    public static let dir = ChatPaths.dir

    // What else keeps a chat's data or hears of its changes, set once by the app before the first chat loads
    // (`ChatLinksApp.connect`): the chat side calls none of them by name. Unset (a program that did not connect):
    // only the chat's own files under `dir` are written and removed.
    public struct Links {
        public var purge: [(UUID) throws -> Void] = []          // in order, before the chat's own files: its AI sessions, its backups
        public var documents: (UUID) -> URL? = { _ in nil }      // its attached documents' folder, removed after `<id>.work`
        public var saved: (Conversation) -> Void = { _ in }
        public var deleted: (UUID) -> Void = { _ in }
        public var finished: (Conversation?) -> Void = { _ in }  // a chat finished answering
        public var locked: (Conversation) -> Void = { _ in }     // a chat was locked (Enterprise or personal)
        public var remote: (RemoteChat) -> SyncSnapshot? = { _ in nil }   // another Mac's copy, read to be shown
        public init(purge: [(UUID) throws -> Void] = [], documents: @escaping (UUID) -> URL? = { _ in nil },
                    saved: @escaping (Conversation) -> Void = { _ in }, deleted: @escaping (UUID) -> Void = { _ in },
                    finished: @escaping (Conversation?) -> Void = { _ in }, locked: @escaping (Conversation) -> Void = { _ in },
                    remote: @escaping (RemoteChat) -> SyncSnapshot? = { _ in nil }) {
            self.purge = purge; self.documents = documents; self.saved = saved; self.deleted = deleted
            self.finished = finished; self.locked = locked; self.remote = remote
        }
    }
    public static var links = Links()

    public static func loadAll() -> [Conversation] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.filter { $0.hasSuffix(".json") }
            .compactMap { try? decoder.decode(Conversation.self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/" + $0))) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public static func save(_ conversation: Conversation) {
        guard !conversation.turns.isEmpty || conversation.configuration != nil || !(conversation.documents ?? []).isEmpty || conversation.workspace != nil else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        let file = URL(fileURLWithPath: dir + "/\(conversation.id.uuidString).json")
        try? encoder.encode(conversation).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        links.saved(conversation)
    }

    public static func delete(_ conversation: Conversation) throws {
        // First what the chat keeps elsewhere (its session transcripts, its backups); a failure keeps every file below.
        for purge in links.purge { try purge(conversation.id) }
        let work = URL(fileURLWithPath: dir).appendingPathComponent(conversation.id.uuidString + ".work")
        if FileManager.default.fileExists(atPath: work.path) { try FileManager.default.removeItem(at: work) }
        if let documents = links.documents(conversation.id), FileManager.default.fileExists(atPath: documents.path) {
            try FileManager.default.removeItem(at: documents)
        }
        let assets = dir + "/\(conversation.id.uuidString).assets"
        if FileManager.default.fileExists(atPath: assets) { try FileManager.default.removeItem(atPath: assets) }
        let path = dir + "/\(conversation.id.uuidString).json"
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
        links.deleted(conversation.id)
    }
}

extension ChatTurn.Entry {
    // AIs begin each reply with "TL;DR: …". That line becomes the headline; the rest is the full reply.
    public static func reply(round: Int, speaker: String, text: String) -> Self {
        var entry = Self(round: round, speaker: speaker, text: text, failed: false)
        (entry.headline, entry.text) = ReplyHeadline.split(text)
        return entry
    }

    // The line shown in the chat. Older replies, or an AI that skipped the TL;DR line, use the first sentence.
    public var shortLine: String {
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
