import Cocoa
import SwiftUI
import AIAccounts
import AILocalization
import AIRuntime
import AIProjects

// An Enterprise chat: one the user locked (the chat menu, or "New Enterprise chat"). Only the user locks a chat,
// and a lock is never removed. In a locked chat only Enterprise accounts of the organization it was locked for,
// and models on this Mac, are sent its content; AI chat search (ChatTools.swift) never shows it. Every other chat,
// older ones included, is open to every account. The account's name without its AI's name stands for its
// organization, so "Claude (학교)" and "ChatGPT (학교)" are one organization.
// The lock itself (EnterpriseLock) is in AIAccounts, so a Space can keep it.
// A personal lock is the other way round: the same lock with Enterprise.personal as its organization, so every gate,
// meeting, review, TODO and Space that keeps a lock keeps it too. Only personal accounts and models on
// this Mac take part; it is otherwise an open chat (searched by personal AIs, synced, saves memory).
// A project is locked by locking all its chats and TODO lists (lockProject); new ones in it take the same lock.

extension EnterpriseLock {
    var isPersonal: Bool { organization == Enterprise.personal }
}

extension Conversation {
    public var isEnterprise: Bool { enterpriseLock.map { !$0.isPersonal } ?? false }
    var isPersonalLocked: Bool { enterpriseLock?.isPersonal == true }
    // A work chat: a Git project is linked. A chat with only folders linked is a plain chat.
    var isProjectChat: Bool { workspace?.project != nil }
}

public enum Enterprise {
    // The organization of a personal lock: no account name is lowercased into it.
    static let personal = "\u{1}personal"
    static var personalLock: EnterpriseLock { EnterpriseLock(organization: personal, name: L("개인", "Personal"), lockedAt: Date()) }

    static func organization(_ name: String) -> String { organizationName(name).lowercased() }

    // "ChatGPT (학교)" → "학교". A name that is only the AI's name stays as it is.
    static func organizationName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for title in Account.Provider.allCases.map(\.title) + ["Codex"] where trimmed.lowercased().hasPrefix(title.lowercased()) {
            let rest = String(trimmed.dropFirst(title.count)).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "()-·:")))
            if !rest.isEmpty { return rest }
        }
        return trimmed
    }

    // Whether `account` may be sent the content of a chat with `lock` (nil: an open chat, every account may).
    // Every cloud AI (Gemini too) follows its Enterprise mark in Settings; models on this Mac join every chat.
    public static func permits(_ account: Account, lock: EnterpriseLock?) -> Bool {
        guard let lock else { return true }
        if account.provider == .ollama { return true }
        if lock.isPersonal { return !account.isSchool }
        return account.isSchool && organization(account.name) == lock.organization
    }

    // The organizations a chat may be locked for: one per name among the Enterprise accounts.
    static func organizations(_ accounts: [Account]) -> [EnterpriseLock] {
        var seen = Set<String>()
        return accounts.filter { $0.provider != .ollama && $0.isSchool }.compactMap { account in
            let key = organization(account.name)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return EnterpriseLock(organization: key, name: organizationName(account.name), lockedAt: Date())
        }
    }

    static func blocked(_ account: Account) -> Answerer.Failure {
        .failed(L("잠긴 방(Enterprise·개인)이라 \(account.provider.title) (\(account.name))에게는 보내지 않았어요.",
                  "This chat is locked (Enterprise or personal), so nothing was sent to \(account.provider.title) (\(account.name))."))
    }
}

extension Discussion {
    // The lock of a chat as saved now (a worker's own copy may be older). A chat that cannot be found is
    // treated as locked to nobody, so its content goes only to models on this Mac.
    func lock(of room: UUID) -> EnterpriseLock? {
        let read = { (self.host ?? self).conversations.first { $0.id == room } ?? self.conversations.first { $0.id == room } }
        let found = Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
        guard let found else { return EnterpriseLock(organization: "", name: "", lockedAt: .distantPast) }
        return found.enterpriseLock
    }

    // The gate: called right before a chat's content is sent to `account`. false = do not send.
    func permits(_ account: Account, room: UUID) -> Bool {
        Enterprise.permits(account, lock: lock(of: room))
    }

    // The open chat's lock (for picking accounts).
    var currentLock: EnterpriseLock? { lock(of: currentID) }

    // Locks a chat for `organization`, by the user only (the chat menu). It cannot be undone. Its copy on iCloud
    // is taken down (no Enterprise chat is shared to other Macs by default; the app hears it as `ChatStore.links.locked`).
    func lockEnterprise(_ room: UUID, organization: EnterpriseLock) {
        guard let i = conversations.firstIndex(where: { $0.id == room }), conversations[i].enterpriseLock == nil,
              !runningRooms.contains(room) else { return }
        var lock = organization
        lock.lockedAt = Date()
        conversations[i].enterpriseLock = lock
        // Accounts picked by hand that may no longer take part drop out.
        if var config = conversations[i].configuration {
            let allowed = { (id: String) in self.model.accounts.first { $0.id == id }.map { Enterprise.permits($0, lock: lock) } ?? false }
            if let id = config.soloAccountID, !allowed(id) { config.soloAccountID = nil }
            if let ids = config.memberIDs { let kept = ids.filter(allowed); config.memberIDs = kept.isEmpty ? nil : kept }
            if let id = config.leadID, !allowed(id) { config.leadID = nil }
            if let id = config.lastSoloAccountID, !allowed(id) { config.lastSoloAccountID = nil }
            conversations[i].configuration = config
        }
        if conversations[i].hasContent { ChatStore.save(conversations[i]) }
        ChatStore.links.locked(conversations[i])
        fillSpaceLocks()   // Spaces this chat made before keep the lock, also after the chat is deleted
        objectWillChange.send()
    }
}

extension Discussion {
    // Locks a whole project (every worktree of its repository) for good: its chats with their meetings and TODO chats,
    // and its TODO lists (a project with none gets one, so the lock stays after its chats go). New chats, TODOs and
    // meetings in it then keep the lock. Returns why it was not locked (nil: locked).
    @discardableResult
    func lockProject(_ key: String, name: String, organization: EnterpriseLock, todos: TodoStore = .shared) -> String? {
        let chats = conversations.filter { $0.meetingOf == nil && $0.workspace?.project?.groupKey == key }
            .sorted { $0.updatedAt > $1.updatedAt }
        let rooms = chats.flatMap { [$0] + meetings(of: $0.id) }
        let lists = todos.current.lists.filter { $0.project?.groupKey == key }
        if let held = todos.locked { return held }
        if !runningRooms.isDisjoint(with: rooms.map(\.id)) {
            return L("이 프로젝트의 채팅이 답하는 중이에요. 끝난 뒤 다시 해 주세요.", "A chat of this project is answering. Try again when it is done.")
        }
        if (rooms.compactMap(\.enterpriseLock) + lists.compactMap(\.lock)).contains(where: { $0.organization != organization.organization }) {
            return L("이 프로젝트에 다른 잠금의 대화나 TODO가 있어요.", "This project has chats or TODOs with another lock.")
        }
        guard let binding = chats.compactMap({ $0.workspace?.project }).first ?? lists.compactMap(\.project).first else {
            return L("이 프로젝트에는 연결된 폴더가 없어요.", "This project has no linked folder.")
        }
        var lock = organization
        lock.lockedAt = Date()
        do { try todos.lockProject(key, name: name, project: binding, lock: lock) } catch { return error.localizedDescription }
        for room in rooms where room.enterpriseLock == nil { lockEnterprise(room.id, organization: lock) }
        return nil
    }

    // Asks before locking a project (it cannot be undone), then locks it or says why not.
    func askToLockProject(_ key: String, name: String, organization: EnterpriseLock) {
        let alert = NSAlert()
        if organization.isPersonal {
            alert.messageText = L("‘\(name)’ 프로젝트를 개인으로 잠글까요?", "Lock the project “\(name)” as personal?")
            alert.informativeText = L("""
                되돌릴 수 없어요. 이 프로젝트의 모든 대화·회의·TODO와 앞으로 생기는 것까지 개인 계정과 내 Mac 모델만 사용하고, 회사·학교(Enterprise) 계정에는 보내지 않아요.

                잠그기 전에 Enterprise 계정에게 보낸 내용은 이미 보낸 거예요.
                """, """
                This cannot be undone. Every chat, meeting and TODO of this project, and every new one, uses only personal accounts and models on this Mac; nothing goes to Enterprise accounts.

                Whatever was already sent to Enterprise accounts was sent.
                """)
        } else {
            alert.messageText = L("‘\(name)’ 프로젝트를 \(organization.name) Enterprise로 잠글까요?", "Lock the project “\(name)” as \(organization.name) Enterprise?")
            alert.informativeText = L("""
                되돌릴 수 없어요. 이 프로젝트의 모든 대화·회의·TODO와 앞으로 생기는 것까지 \(organization.name) 엔터프라이즈 계정과 내 Mac 모델만 사용하고, 다른 대화의 AI 검색에 나오지 않아요.

                잠그기 전에 개인 AI에게 보낸 내용은 이미 보낸 거예요. 프로젝트 폴더는 디스크에 그대로 있어서 다른 방의 AI도 읽을 수 있어요.
                """, """
                This cannot be undone. Every chat, meeting and TODO of this project, and every new one, uses only \(organization.name) Enterprise accounts and models on this Mac, and AI search from other chats never shows them.

                Whatever was already sent to personal AIs was sent. The project folder stays on disk, where AIs of other chats can read it.
                """)
        }
        alert.addButton(withTitle: L("영구히 잠그기", "Lock for good"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let why = lockProject(key, name: name, organization: organization) {
            let refused = NSAlert()
            refused.messageText = L("프로젝트를 잠그지 못했어요", "Could not lock the project")
            refused.informativeText = why
            refused.runModal()
        }
    }

    // Asks before locking (it cannot be undone), then locks.
    func askToLock(_ room: UUID, organization: EnterpriseLock) {
        let alert = NSAlert()
        if organization.isPersonal {
            alert.messageText = L("이 대화를 개인 방으로 잠글까요?", "Lock this chat as a personal chat?")
            alert.informativeText = L("""
                되돌릴 수 없어요. 잠근 뒤에는 개인 계정과 내 Mac 모델만 이 대화에 참여하고, 회사·학교(Enterprise) 계정에는 보내지 않아요. 그 계정의 AI 검색에도 나오지 않아요.

                잠그기 전에 Enterprise 계정에게 보낸 내용은 이미 보낸 거예요.
                """, """
                This cannot be undone. Once locked, only personal accounts and models on this Mac take part; nothing goes to Enterprise accounts, and their AI search never shows it.

                Whatever this chat already sent to Enterprise accounts was sent.
                """)
            alert.addButton(withTitle: L("영구히 잠그기", "Lock for good"))
            alert.addButton(withTitle: L("취소", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            lockEnterprise(room, organization: organization)
            return
        }
        alert.messageText = L("이 대화를 \(organization.name) Enterprise 방으로 잠글까요?", "Lock this chat as a \(organization.name) Enterprise chat?")
        alert.informativeText = L("""
            되돌릴 수 없어요. 잠근 뒤에는 \(organization.name) 엔터프라이즈 계정과 내 Mac 모델만 이 대화에 참여하고, 다른 대화의 AI 검색에 나오지 않아요.

            잠그기 전에 이 대화에서 개인 AI에게 보낸 내용은 이미 보낸 거예요. 학교·회사 자료는 잠근 다음에 넣으세요.
            공유 폴더와 프로젝트 폴더는 일반 방과 같이 쓰는 곳이에요. 여기에 쓴 파일은 일반 방의 AI도 읽을 수 있어요.
            """, """
            This cannot be undone. Once locked, only \(organization.name) Enterprise accounts and models on this Mac take part, and AI search from other chats never shows it.

            Whatever this chat already sent to personal AIs was sent. Add school or work material after locking.
            Shared and project folders are also used by open chats: files written there can be read by their AIs.
            """)
        alert.addButton(withTitle: L("영구히 잠그기", "Lock for good"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        lockEnterprise(room, organization: organization)
    }

    // "New Enterprise chat": a new chat, locked before anything is sent.
    func newEnterpriseConversation(_ organization: EnterpriseLock) {
        newConversation()
        guard current.turns.isEmpty, current.enterpriseLock == nil else { return }
        askToLock(currentID, organization: organization)
    }
}

// The lock items in a menu: one per organization, then the personal lock (room nil: a new chat; project: a whole project).
struct EnterpriseLockButtons: View {
    @ObservedObject var discussion: Discussion
    let room: UUID?
    var project: ProjectGroup? = nil
    var body: some View {
        let organizations = Enterprise.organizations(discussion.model.accounts)
        ForEach(organizations + [Enterprise.personalLock], id: \.organization) { organization in
            let suffix = organizations.count > 1 && !organization.isPersonal ? " (\(organization.name))" : ""
            if let project {
                Button((organization.isPersonal ? L("프로젝트를 개인으로 잠그기", "Lock Project as Personal")
                                                : L("프로젝트를 Enterprise로 잠그기", "Lock Project as Enterprise") + suffix) + "…") {
                    discussion.askToLockProject(project.id, name: project.name, organization: organization)
                }
                .disabled(!discussion.runningRooms.isDisjoint(with: (project.chats + project.todoRooms).map(\.id)) || discussion.importingMaterials)
            } else if let room {
                Button((organization.isPersonal ? L("개인 방으로 잠그기", "Lock as Personal chat") : L("Enterprise 방으로 잠그기", "Lock as Enterprise chat") + suffix) + "…") {
                    discussion.askToLock(room, organization: organization)
                }
                .disabled(discussion.runningRooms.contains(room) || discussion.importingMaterials)
            } else {
                Button((organization.isPersonal ? L("새 개인 대화", "New Personal chat") : L("새 Enterprise 대화", "New Enterprise chat") + suffix) + "…") {
                    discussion.newEnterpriseConversation(organization)
                }
                .disabled(discussion.importingMaterials)
            }
        }
    }
}

// The small "E" after an Enterprise chat's title in the list, "P" after a personal one.
struct EnterpriseBadge: View {
    var personal = false
    var body: some View {
        Text(personal ? "P" : "E")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.secondary)
            .frame(width: 14, height: 14)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1))
            .help(personal ? L("개인 잠금: 회사·학교(Enterprise) 계정이 참여하지 않아요.", "Personal lock: Enterprise accounts do not take part.")
                           : L("Enterprise 방: 개인 클라우드 AI가 참여하지 않고, AI 채팅 검색에 나오지 않아요.",
                               "Enterprise chat: personal cloud AIs do not take part, and AI chat search leaves it out."))
            .accessibilityLabel(personal ? "Personal" : "Enterprise")
    }
}

// The badge of a chat's lock, if it has one.
struct LockBadge: View {
    let lock: EnterpriseLock?
    var body: some View {
        if let lock { EnterpriseBadge(personal: lock.isPersonal) }
    }
}
