import SwiftUI

// Which Enterprise accounts (school or work) were sent a chat's content. A mark is added right before the content
// goes out, so a failed or stopped answer counts too, and it is never removed (not when the account or the
// message is deleted). The account's name stands for its organization: a chat seen by one Enterprise account
// is not opened to another organization's account (ChatSearch's AI tools), but an account added again under
// the same name keeps it.
struct EnterpriseMark: Codable, Equatable {
    var id: String
    var name: String
    var provider: Account.Provider?

    init(_ account: Account) {
        id = account.id; name = account.name; provider = account.provider
    }

    // The same account, or one of the same organization.
    func covers(_ account: Account) -> Bool {
        id == account.id || (!Self.organization(name).isEmpty && Self.organization(name) == Self.organization(account.name))
    }

    static func organization(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum ChatSide: Equatable {
    case personal, enterprise
    case unsure   // not known for certain (a copy from another Mac, or an older chat that could not be told): treated as Enterprise
}

extension Conversation {
    var side: ChatSide {
        if enterpriseUnsure == true || enterprise == nil { return .unsure }
        return (enterprise ?? []).isEmpty ? .personal : .enterprise
    }
    // A work chat: a Git project is linked. A chat with only folders linked is a plain chat.
    var isProjectChat: Bool { workspace?.project != nil }
}

enum Enterprise {
    // An account whose use makes a chat Enterprise (a model on this Mac sends nothing out).
    static func counts(_ account: Account) -> Bool { account.provider != .ollama && account.isSchool }

    // Older chats, once: the Enterprise accounts that picked or answered them (DeviceSync.isSchool's rule).
    // A copy from another Mac, or a chat marked Enterprise without an account to name, stays unsure.
    static func classify(_ conversation: inout Conversation, accounts: [Account]) {
        guard conversation.enterprise == nil else { return }
        let config = conversation.configuration
        let ids = Set([config?.soloAccountID, config?.lastSoloAccountID, config?.leaderAccountID].compactMap { $0 }
                      + (config?.accountIDs ?? []) + (config?.memberIDs ?? []))
        var speakers: Set<String> = []
        for turn in conversation.turns {
            if let by = turn.finalBy { speakers.insert(by) }
            for entry in turn.entries + (turn.moreAnswers ?? []) + (turn.peerNotes ?? []) { speakers.insert(entry.speaker) }
        }
        var marks: [EnterpriseMark] = []
        for account in accounts where counts(account)
            && (ids.contains(account.id) || speakers.contains(account.name) || speakers.contains("\(account.provider.title) (\(account.name))"))
            && !marks.contains(where: { $0.id == account.id }) {
            marks.append(EnterpriseMark(account))
        }
        conversation.enterprise = marks
        // Helpers left no account name: the YouTube search (Gemini) and picture makers. With an Enterprise
        // account of that kind on this Mac, which one helped cannot be told.
        let helpers = accounts.filter(counts)
        let youTube = speakers.contains { $0.hasPrefix("Gemini · ") } && helpers.contains { $0.provider == .gemini }
        let pictures = conversation.turns.contains { !($0.finalImages ?? []).isEmpty } && !helpers.isEmpty
        if conversation.origin != nil || (marks.isEmpty && (DeviceSync.isSchool(conversation, accounts: accounts) || youTube || pictures)) {
            conversation.enterpriseUnsure = true
        }
    }
}

extension Discussion {
    // Called right before a chat's content is sent to `account`. Saved at once, without moving the chat up.
    func noteSent(_ account: Account, room: UUID) {
        guard Enterprise.counts(account) else { return }
        if let host { return host.noteSent(account, room: room) }
        let apply = {
            guard let i = self.conversations.firstIndex(where: { $0.id == room }) else { return }
            var marks = self.conversations[i].enterprise ?? []
            guard !marks.contains(where: { $0.id == account.id }) else { return }
            marks.append(EnterpriseMark(account))
            self.conversations[i].enterprise = marks
            if self.conversations[i].hasContent { ChatStore.save(self.conversations[i]) }
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.sync(execute: apply) }
    }

    // Older chats get their side once (at launch).
    func classifyOldChats(accounts: [Account]) {
        for i in conversations.indices where conversations[i].enterprise == nil {
            Enterprise.classify(&conversations[i], accounts: accounts)
            if conversations[i].hasContent { ChatStore.save(conversations[i]) }
        }
    }
}

// The small "E" after an Enterprise chat's title in the list.
struct EnterpriseBadge: View {
    let side: ChatSide
    var body: some View {
        Text("E")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.secondary)
            .frame(width: 14, height: 14)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1))
            .help(side == .unsure
                  ? L("Enterprise로 다뤄요: 어느 계정이 봤는지 확실하지 않아요(다른 Mac에서 가져온 대화 등). AI의 채팅 검색에서는 빠져요.",
                      "Treated as Enterprise: which accounts saw it is not certain (a copy from another Mac, for example). AI chat search leaves it out.")
                  : L("Enterprise: Enterprise 계정이 이 대화를 봤어요.", "Enterprise: an Enterprise account has seen this chat."))
            .accessibilityLabel("Enterprise")
    }
}
