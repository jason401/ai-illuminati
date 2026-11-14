import Foundation
import Combine
import AIAccounts
import AILocalization
import AIRuntime
import AIWorkspace
import AIProjects

// What the TODO scheduler (Todo.swift) does through the chats: it decides which TODO starts, retries and what its
// state becomes; the chat side makes the chat, picks the crew by usage and lock, sends the message and tells how it ended.
extension Discussion: TodoChats {
    public var answering: Set<UUID> { runningRooms }
    public var answeringChanged: AnyPublisher<Void, Never> { $runningRooms.map { _ in () }.eraseToAnyPublisher() }
    public var maxAnswering: Int { Self.maxRunning }
    public var importing: Bool { importingMaterials }
    public var chats: [ProjectChatSummary] { conversations.map(\.projectSummary) }

    // Claude/Codex accounts with enough usage left for a TODO (AutoPick.need: lower near a reset), the most surplus first.
    public func crew(lock: EnterpriseLock?, allowed: [String]) -> (lead: Account, reviewer: Account?)? {
        AutoPick.todoCrew(model.accounts, usage: model.latestUsage, lock: lock, allowed: allowed)
    }
    // The bar shown is the lowest one any of the accounts that could take the TODO has now.
    public func noCrew(_ allowed: [String], lock: EnterpriseLock?) -> String {
        let able = model.accounts.filter { [.claude, .codex].contains($0.provider) && Enterprise.permits($0, lock: lock) && (allowed.isEmpty || allowed.contains($0.id)) }
        let bar = AutoPick.todoBar(able, usage: model.latestUsage)
        return TodoScheduler.noCrew(allowed, accounts: model.accounts, lock: lock, percent: bar.percent, note: bar.note)
    }

    public func addChat(_ project: ProjectBinding, title: String, lock: EnterpriseLock?) -> UUID { addProjectChat(project, title: title, open: false, lock: lock) }
    public func setCrew(room: UUID, members: [String], lead: String) {
        configure(room: room) { c in
            c.mode = 0; c.memberIDs = members; c.leadID = lead; c.soloAccountID = members.count == 1 ? lead : nil
        }
    }
    public func folder(_ room: UUID) -> URL { Self.chatFolder(room) }
    public func sentPhotos(_ room: UUID) -> Set<UUID> { Set(conversation(room).turns.flatMap { $0.images ?? [] }.map(\.id)) }
    public func start(room: UUID, question: String, photos: [TodoPhoto], review: Bool, extra: String) -> String? {
        let images = photos.compactMap { try? ImageStore.importImage(Data(contentsOf: $0.file), name: $0.name, conversationID: room, id: $0.id) }
        let reason = startTurn(room: room, question: question, images: images, forced: review ? .work : nil, extra: extra)
        if reason != nil { for image in images { try? ImageStore.remove(image) } }
        return reason
    }
    public func ended(_ room: UUID) -> TodoTurnEnd {
        let turn = conversation(room).turns.last
        // ask_ai cards always have a headline: a failed card without one is the review.
        return TodoTurnEnd(error: turn?.error, unreviewed: turn?.peerNotes?.contains { $0.failed && $0.headline == nil } == true)
    }
    public func stop(_ room: UUID) { runToken(room)?.cancel() }

    // A question left unanswered: another AI than the TODO's lead (a different kind first, the chat's lock kept, enough
    // usage left) reads the chat's folders like ask_ai (read only) and answers in the user's place.
    public func standIn(room: UUID, brief: String, token: DebateCancellation, done: @escaping (TodoStandInReply) -> Void) {
        let lead = conversation(room).configuration?.leadID.flatMap { id in model.accounts.first { $0.id == id } }
        let picked = Peer.pick(asker: lead, to: nil, count: 1, members: [], accounts: model.accounts.filter { $0.provider != .gemini },
                               usage: model.latestUsage, lock: lock(of: room), label: label)
        guard let peer = picked.accounts.first else { done(TodoStandInReply(error: L("대신 답할 AI가 없어요.", "No AI is free to answer."))); return }
        let name = label(peer), view = Self.peerView(soloBinding(room))
        let prompt = """
        [STAND-IN ANSWER]
        You are \(name). You are not talking to the user, and you cannot ask other AIs.
        [Folders you may read — read only]
        \(Peer.folderList(view.roots))
        Read only the files you need; do not edit anything, run commands that change files or use Git writes.
        \(brief)
        Reply in the language of the TODO.
        """
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = self.peerAnswer(peer, prompt: prompt, view: view, room: room, timeout: Peer.askTimeout, token: token)
            DispatchQueue.main.async {
                switch result {
                case .success(let text): done(TodoStandInReply(by: name, text: text))
                case .failure(let failure): done(TodoStandInReply(by: name, error: "\(failure)"))
                }
            }
        }
    }
    // A message sent there after `since`, or one waiting for the running answer.
    public func userWrote(_ room: UUID, since: Date) -> Bool {
        let chat = conversation(room)
        return !(chat.queued ?? []).isEmpty || !(steering[room] ?? []).isEmpty || chat.turns.contains { ($0.askedAt ?? .distantPast) > since }
    }
}

extension TodoScheduler {
    public convenience init(discussion: Discussion, store: TodoStore) { self.init(chats: discussion, store: store) }

    // Why nobody can take a list's TODOs: the picked accounts are gone, kept out by the Enterprise lock, or low on usage.
    // `percent`/`note`: the bar in use now and which reset lowers it (AutoPick.todoBar).
    public static func noCrew(_ allowed: [String], accounts: [Account], lock: EnterpriseLock?, percent: String? = nil, note: String = "") -> String {
        let pct = percent ?? "\(Int(threshold))%"
        guard !allowed.isEmpty else { return L("남은 사용량이 \(pct) 이상인 Claude/Codex 계정이 없어서 기다려요\(note).", "Waiting for a Claude/Codex account with \(pct) usage left\(note).") }
        let picked = accounts.filter { allowed.contains($0.id) && [.claude, .codex].contains($0.provider) }
        if picked.isEmpty { return L("고른 AI 계정이 모두 없어졌어요. 보드에서 일할 AI를 다시 골라 주세요.", "The picked AI accounts are gone. Pick the AIs again on the board.") }
        if !picked.contains(where: { Enterprise.permits($0, lock: lock) }) {
            return L("고른 AI가 이 프로젝트의 잠금(Enterprise·개인)에 맞지 않아요. 일할 AI를 다시 골라 주세요.", "The picked AIs are not allowed by this project's lock (Enterprise or personal). Pick them again.")
        }
        return L("고른 AI의 남은 사용량이 \(pct) 이상이 될 때까지 기다려요\(note).", "Waiting until a picked AI has \(pct) usage left\(note).")
    }
}
