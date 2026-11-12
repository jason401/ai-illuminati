import SwiftUI
import AILocalization

// Search across chats: titles, messages and final answers. Words are compared two letters at a time
// (bigrams), so "청룡영화제" finds "청룡영화제는" and "청룡영화제에서" and a word with a different ending
// still counts in part. A title match weighs more. The sidebar search and the AIs' search_chats both use it.
enum ChatSearch {
    struct Result: Identifiable, Equatable {
        var id: UUID
        var title: String
        var score: Double
        var turn: UUID?       // the turn that matches best (nil: only the title)
        var snippet: String   // a line around the words in that turn
        var words: String     // a query word that appears there as written, to highlight with ⌘F
        var updatedAt: Date
    }

    enum SideFilter: String, CaseIterable { case all, personal, enterprise }
    enum KindFilter: String, CaseIterable { case all, plain, work }

    static func passes(_ conversation: Conversation, side: SideFilter, kind: KindFilter) -> Bool {
        switch side {
        case .all: break
        case .personal: if conversation.isEnterprise { return false }
        case .enterprise: if !conversation.isEnterprise { return false }
        }
        switch kind {
        case .all: return true
        case .plain: return !conversation.isProjectChat
        case .work: return conversation.isProjectChat
        }
    }

    // What a chat is searched by (titles separately).
    static func texts(_ turn: ChatTurn) -> [String] {
        [turn.question] + [turn.final].compactMap { $0 } + (turn.moreAnswers ?? []).filter { !$0.failed }.map(\.text)
    }

    static func normalized(_ text: String) -> [Character] {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }.map { $0 }
    }

    // A one-letter word ("앱") is its own gram, so a text's grams hold its single letters too.
    static func bigrams(_ text: String, letters single: Bool = false) -> Set<String> {
        let letters = normalized(text)
        guard letters.count > 1 else { return letters.isEmpty ? [] : [String(letters)] }
        var grams = Set((0..<(letters.count - 1)).map { String(letters[$0...$0 + 1]) })
        if single { grams.formUnion(letters.map { String($0) }) }
        return grams
    }

    static func words(_ query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !normalized($0).isEmpty }
    }

    // How much of each word is in `grams` (0…1). A part under half counts as nothing.
    static func coverage(_ words: [[String]], in grams: Set<String>) -> [Double] {
        words.map { word in
            guard !word.isEmpty else { return 0 }
            let part = Double(word.filter(grams.contains).count) / Double(word.count)
            return part >= 0.5 ? part : 0
        }
    }

    // Each chat's bigrams, made again only after it changes.
    private static var cache: [UUID: (stamp: String, title: Set<String>, body: Set<String>)] = [:]
    private static let lock = NSLock()
    private static func grams(_ conversation: Conversation) -> (title: Set<String>, body: Set<String>) {
        let stamp = "\(conversation.title)|\(conversation.turns.count)|\(conversation.updatedAt.timeIntervalSince1970)|\(conversation.turns.last?.final?.count ?? -1)"
        lock.lock()
        if let hit = cache[conversation.id], hit.stamp == stamp { lock.unlock(); return (hit.title, hit.body) }
        lock.unlock()
        let title = bigrams(conversation.title, letters: true)
        var body = Set<String>()
        for turn in conversation.turns { for text in texts(turn) { body.formUnion(bigrams(text, letters: true)) } }
        lock.lock(); cache[conversation.id] = (stamp, title, body); lock.unlock()
        return (title, body)
    }

    // Chats that match at least half of the words, best first (newer first when equal).
    // The list redraws often (hover, typing elsewhere): the same search over unchanged chats is kept.
    private static var last: (key: String, results: [Result])?
    static func search(_ query: String, in conversations: [Conversation], limit: Int = 50) -> [Result] {
        let key = query + "|\(limit)|" + conversations.map { "\($0.id)\($0.updatedAt.timeIntervalSince1970)\($0.turns.count)\($0.title)" }.joined(separator: ",")
        lock.lock(); let kept = last; lock.unlock()
        if let kept, kept.key == key { return kept.results }
        let results = find(query, in: conversations, limit: limit)
        lock.lock(); last = (key, results); lock.unlock()
        return results
    }

    private static func find(_ query: String, in conversations: [Conversation], limit: Int) -> [Result] {
        let list = words(query)
        guard !list.isEmpty else { return [] }
        let wordGrams = list.map { Array(bigrams($0)) }
        let phrase = normalized(query)
        var results: [Result] = []
        for conversation in conversations where !conversation.turns.isEmpty {
            let (title, body) = grams(conversation)
            let inTitle = coverage(wordGrams, in: title)
            let inBody = coverage(wordGrams, in: body)
            let found = zip(inTitle, inBody).map { max($0, $1) }
            let share = found.reduce(0, +) / Double(list.count)
            guard share >= 0.5 else { continue }
            var score = share + inTitle.reduce(0, +) / Double(list.count) * 0.75
            if String(normalized(conversation.title)).contains(String(phrase)) { score += 0.5 }
            results.append(Result(id: conversation.id, title: conversation.title, score: score, turn: nil, snippet: "", words: "", updatedAt: conversation.updatedAt))
        }
        results.sort { $0.score != $1.score ? $0.score > $1.score : $0.updatedAt > $1.updatedAt }
        results = Array(results.prefix(limit))
        // Only the results shown: the best turn and a line from it.
        for i in results.indices {
            guard let conversation = conversations.first(where: { $0.id == results[i].id }) else { continue }
            if let best = bestTurn(conversation, wordGrams) {
                results[i].turn = best.id
                let text = texts(best).joined(separator: "\n")
                let (line, word) = snippet(text, list)
                results[i].snippet = line; results[i].words = word
            }
        }
        return results
    }

    static func bestTurn(_ conversation: Conversation, _ wordGrams: [[String]]) -> ChatTurn? {
        var best: (ChatTurn, Double)?
        for turn in conversation.turns {
            var grams = Set<String>()
            for text in texts(turn) { grams.formUnion(bigrams(text, letters: true)) }
            let score = coverage(wordGrams, in: grams).reduce(0, +)
            if score > 0, score >= (best?.1 ?? 0) { best = (turn, score) }   // later turns win ties
        }
        return best?.0
    }

    // About 90 characters on one line around the first word found as written (the longest first).
    static func snippet(_ text: String, _ words: [String]) -> (String, String) {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        for word in words.sorted(by: { $0.count > $1.count }) {
            if let range = flat.range(of: word, options: .caseInsensitive) {
                let start = flat.index(range.lowerBound, offsetBy: -30, limitedBy: flat.startIndex) ?? flat.startIndex
                let end = flat.index(start, offsetBy: 90, limitedBy: flat.endIndex) ?? flat.endIndex
                let line = flat[start..<end].trimmingCharacters(in: .whitespaces)
                return ((start > flat.startIndex ? "…" : "") + line + (end < flat.endIndex ? "…" : ""), word)
            }
        }
        return (String(flat.prefix(90)) + (flat.count > 90 ? "…" : ""), "")
    }
}

extension Discussion {
    // Opens a search result at its turn, with the words found by ⌘F.
    func openResult(_ result: ChatSearch.Result) {
        open(result.id)
        guard currentID == result.id, let turn = result.turn else { return }
        if !result.words.isEmpty {
            findText = result.words; findOpen = true; findFresh = false
            findPosition = ChatFind.hits(current, result.words).firstIndex { $0.turn == turn } ?? 0
        }
        jump(to: turn)
    }
}

// The sidebar's filters while searching: open / Enterprise and plain / work chats. The sidebar search runs on
// this Mac only, so it lists Enterprise chats too (AI chat search does not).
struct ChatSearchFilters: View {
    @ObservedObject var discussion: Discussion
    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: $discussion.searchSide) {
                Text(L("Enterprise 포함", "With Enterprise")).tag(ChatSearch.SideFilter.all)
                Text(L("Enterprise 아님", "Not Enterprise")).tag(ChatSearch.SideFilter.personal)
                Text("Enterprise").tag(ChatSearch.SideFilter.enterprise)
            }
            .help(L("Enterprise 방: 직접 잠근 대화", "Enterprise chats: the ones you locked"))
            Picker("", selection: $discussion.searchKind) {
                Text(L("일반·작업", "Plain · Work")).tag(ChatSearch.KindFilter.all)
                Text(L("일반", "Plain")).tag(ChatSearch.KindFilter.plain)
                Text(L("작업", "Work")).tag(ChatSearch.KindFilter.work)
            }
            .help(L("일반 대화 / 작업방(Git 프로젝트)", "Plain chats / work chats (Git project)"))
        }
        .labelsHidden().pickerStyle(.menu).controlSize(.small)
        .padding(.horizontal, 4).padding(.top, 6)
    }
}

// One search result: the title, then the matching line.
struct ChatSearchRow: View {
    let result: ChatSearch.Result
    let conversation: Conversation?
    let selected: Bool
    let hovered: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if conversation?.isProjectChat == true {
                    Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
                }
                Text(result.title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                if conversation?.isEnterprise == true { EnterpriseBadge() }
            }
            if !result.snippet.isEmpty {
                Text(FindHighlight(words: result.words).apply(AttributedString(result.snippet)))
                    .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? Color.primary.opacity(0.10) : hovered ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}
