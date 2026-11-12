import Foundation
import Combine
import AIAccounts
import AILocalization
import AIWorkspace
import AIProjects

// What the TODO scheduler (Todo.swift) does through the chats: it decides which TODO starts, retries and what its
// state becomes; the chat side makes the chat, picks the crew by usage and lock, sends the message and tells how it ended.
extension Discussion: TodoChats {
    var answering: Set<UUID> { runningRooms }
    var answeringChanged: AnyPublisher<Void, Never> { $runningRooms.map { _ in () }.eraseToAnyPublisher() }
    var maxAnswering: Int { Self.maxRunning }
    var importing: Bool { importingMaterials }
    var chats: [ProjectChatSummary] { conversations.map(\.projectSummary) }

    // Claude/Codex accounts with 30% of both limits left (and allowed by the lock), the most weekly usage first
    // (Enterprise first when close, like AutoPick); the reviewer of the other kind when there is one.
    func crew(lock: EnterpriseLock?, allowed: [String]) -> (lead: Account, reviewer: Account?)? {
        let usage = model.latestUsage
        let ready = AutoPick.candidates(model.accounts, usage: usage, lock: lock)
            .filter { [.claude, .codex].contains($0.provider) && AutoPick.enough(usage[$0.id], threshold: TodoScheduler.threshold) && (allowed.isEmpty || allowed.contains($0.id)) }
        func score(_ a: Account) -> (Double, Double) { (AutoPick.weekly(usage[a.id]) + (a.isSchool ? AutoPick.enterpriseBonus : 0), AutoPick.fiveHour(usage[a.id])) }
        guard let lead = ready.max(by: { score($0) < score($1) }) else { return nil }
        let others = ready.filter { $0.id != lead.id }
        let reviewer = others.filter { $0.provider != lead.provider }.max { score($0) < score($1) } ?? others.max { score($0) < score($1) }
        return (lead, reviewer)
    }
    func noCrew(_ allowed: [String], lock: EnterpriseLock?) -> String { TodoScheduler.noCrew(allowed, accounts: model.accounts, lock: lock) }

    func addChat(_ project: ProjectBinding, title: String, lock: EnterpriseLock?) -> UUID { addProjectChat(project, title: title, open: false, lock: lock) }
    func setCrew(room: UUID, members: [String], lead: String) {
        configure(room: room) { c in
            c.mode = 0; c.memberIDs = members; c.leadID = lead; c.soloAccountID = members.count == 1 ? lead : nil
        }
    }
    func folder(_ room: UUID) -> URL { Self.chatFolder(room) }
    func sentPhotos(_ room: UUID) -> Set<UUID> { Set(conversation(room).turns.flatMap { $0.images ?? [] }.map(\.id)) }
    func start(room: UUID, question: String, photos: [TodoPhoto], review: Bool, extra: String) -> String? {
        let images = photos.compactMap { try? ImageStore.importImage(Data(contentsOf: $0.file), name: $0.name, conversationID: room, id: $0.id) }
        let reason = startTurn(room: room, question: question, images: images, forced: review ? .work : nil, extra: extra)
        if reason != nil { for image in images { try? ImageStore.remove(image) } }
        return reason
    }
    func ended(_ room: UUID) -> TodoTurnEnd {
        let turn = conversation(room).turns.last
        // ask_ai cards always have a headline: a failed card without one is the review.
        return TodoTurnEnd(error: turn?.error, unreviewed: turn?.peerNotes?.contains { $0.failed && $0.headline == nil } == true)
    }
    func stop(_ room: UUID) { runToken(room)?.cancel() }
}

extension TodoScheduler {
    convenience init(discussion: Discussion, store: TodoStore) { self.init(chats: discussion, store: store) }

    // Why nobody can take a list's TODOs: the picked accounts are gone, kept out by the Enterprise lock, or low on usage.
    static func noCrew(_ allowed: [String], accounts: [Account], lock: EnterpriseLock?) -> String {
        guard !allowed.isEmpty else { return L("남은 사용량이 30% 넘는 Claude/Codex 계정이 없어서 기다려요.", "Waiting for a Claude/Codex account with 30% usage left.") }
        let picked = accounts.filter { allowed.contains($0.id) && [.claude, .codex].contains($0.provider) }
        if picked.isEmpty { return L("고른 AI 계정이 모두 없어졌어요. 보드에서 일할 AI를 다시 골라 주세요.", "The picked AI accounts are gone. Pick the AIs again on the board.") }
        if !picked.contains(where: { Enterprise.permits($0, lock: lock) }) {
            return L("고른 AI가 이 프로젝트의 잠금(Enterprise·개인)에 맞지 않아요. 일할 AI를 다시 골라 주세요.", "The picked AIs are not allowed by this project's lock (Enterprise or personal). Pick them again.")
        }
        return L("고른 AI의 남은 사용량이 30% 넘을 때까지 기다려요.", "Waiting until a picked AI has 30% usage left.")
    }
}
