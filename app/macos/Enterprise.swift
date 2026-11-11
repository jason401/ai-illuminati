import Cocoa
import SwiftUI
import AIAccounts

// An Enterprise chat: one the user locked (the chat menu, or "New Enterprise chat"). Only the user locks a chat,
// and a lock is never removed. In a locked chat only Enterprise accounts of the organization it was locked for,
// and models on this Mac, are sent its content; AI chat search (ChatTools.swift) never shows it. Every other chat,
// older ones included, is open to every account. The account's name without its AI's name stands for its
// organization, so "Claude (학교)" and "ChatGPT (학교)" are one organization.
struct EnterpriseLock: Codable, Equatable {
    var organization: String   // Enterprise.organization(account name)
    var name: String           // the name as shown
    var lockedAt: Date
}

extension Conversation {
    var isEnterprise: Bool { enterpriseLock != nil }
    // A work chat: a Git project is linked. A chat with only folders linked is a plain chat.
    var isProjectChat: Bool { workspace?.project != nil }
}

enum Enterprise {
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
    // Gemini cannot be marked Enterprise in Settings, so it never joins a locked chat.
    static func permits(_ account: Account, lock: EnterpriseLock?) -> Bool {
        guard let lock else { return true }
        if account.provider == .ollama { return true }
        return account.provider != .gemini && account.isSchool && organization(account.name) == lock.organization
    }

    // The organizations a chat may be locked for: one per name among the Enterprise accounts.
    static func organizations(_ accounts: [Account]) -> [EnterpriseLock] {
        var seen = Set<String>()
        return accounts.filter { $0.provider != .ollama && $0.provider != .gemini && $0.isSchool }.compactMap { account in
            let key = organization(account.name)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return EnterpriseLock(organization: key, name: organizationName(account.name), lockedAt: Date())
        }
    }

    static func blocked(_ account: Account) -> Answerer.Failure {
        .failed(L("Enterprise 방이라 \(account.provider.title) (\(account.name))에게는 보내지 않았어요.",
                  "This is an Enterprise chat, so nothing was sent to \(account.provider.title) (\(account.name))."))
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
    // is taken down (DeviceSync shares no Enterprise chat by default).
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
        DeviceSync.shared.chatLocked(conversations[i])
        objectWillChange.send()
    }
}

extension Discussion {
    // Asks before locking (it cannot be undone), then locks.
    func askToLock(_ room: UUID, organization: EnterpriseLock) {
        let alert = NSAlert()
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

// The lock items in a menu: one per organization (room nil: a new chat). None without an Enterprise account.
struct EnterpriseLockButtons: View {
    @ObservedObject var discussion: Discussion
    let room: UUID?
    var body: some View {
        let organizations = Enterprise.organizations(discussion.model.accounts)
        ForEach(organizations, id: \.organization) { organization in
            let suffix = organizations.count > 1 ? " (\(organization.name))" : ""
            if let room {
                Button(L("Enterprise 방으로 잠그기", "Lock as Enterprise chat") + suffix + "…") { discussion.askToLock(room, organization: organization) }
                    .disabled(discussion.runningRooms.contains(room) || discussion.importingMaterials)
            } else {
                Button(L("새 Enterprise 대화", "New Enterprise chat") + suffix + "…") { discussion.newEnterpriseConversation(organization) }
                    .disabled(discussion.importingMaterials)
            }
        }
    }
}

// The small "E" after an Enterprise chat's title in the list.
struct EnterpriseBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.secondary)
            .frame(width: 14, height: 14)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1))
            .help(L("Enterprise 방: 개인 클라우드 AI가 참여하지 않고, AI 채팅 검색에 나오지 않아요.",
                    "Enterprise chat: personal cloud AIs do not take part, and AI chat search leaves it out."))
            .accessibilityLabel("Enterprise")
    }
}
