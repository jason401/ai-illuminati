import SwiftUI

// ⌘F in a chat: the turns whose message or answer contain the words, in order, and the words highlighted.
// Moves go from turn to turn; the chat draws earlier turns first when the one to show is not drawn yet.
enum ChatFind {
    // What is searched in a turn: what the chat shows open (the message, the answer and the other members'
    // answers), not the folded discussion replies.
    static func texts(_ turn: ChatTurn) -> [String] {
        [turn.question] + [turn.final].compactMap { $0 } + (turn.moreAnswers ?? []).filter { !$0.failed }.map(\.text)
    }

    static func ranges(_ text: String, _ query: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var start = text.startIndex
        while let range = text.range(of: query, options: [.caseInsensitive], range: start..<text.endIndex) {
            found.append(range)
            start = range.upperBound
        }
        return found
    }

    // The turns with the words, oldest first, with how many times they appear.
    static func hits(_ conversation: Conversation, _ query: String) -> [(turn: UUID, count: Int)] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return [] }
        return conversation.turns.compactMap { turn in
            let count = texts(turn).reduce(0) { $0 + ranges($1, words).count }
            return count > 0 ? (turn.id, count) : nil
        }
    }

    // Marks the words in a drawn piece of text (the turn being shown in a stronger color).
    static func highlighted(_ text: AttributedString, _ query: String, current: Bool) -> AttributedString {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return text }
        var result = text
        let plain = String(text.characters)
        for range in ranges(plain, words) {
            let lower = plain.distance(from: plain.startIndex, to: range.lowerBound)
            let length = plain.distance(from: range.lowerBound, to: range.upperBound)
            let start = result.index(result.startIndex, offsetByCharacters: lower)
            let end = result.index(start, offsetByCharacters: length)
            result[start..<end].backgroundColor = current ? Color.orange.opacity(0.55) : Color.yellow.opacity(0.35)
        }
        return result
    }
}

// What the transcript highlights: the words, and whether this turn is the one moved to.
struct FindHighlight: Equatable {
    var words = ""
    var current = false
    func apply(_ text: AttributedString) -> AttributedString { words.isEmpty ? text : ChatFind.highlighted(text, words, current: current) }
}

extension Discussion {
    // Shows a turn of the open chat: draws enough earlier turns, then the transcript scrolls to it.
    func jump(to turn: UUID) {
        guard let index = current.turns.firstIndex(where: { $0.id == turn }) else { return }
        shownTurns = max(shownTurns, current.turns.count - index)
        jumpTurn = turn
        jumpCount += 1
    }

    // The next (+1) or earlier (-1) turn with the words; a new search starts at the newest one.
    func findStep(_ delta: Int) {
        let hits = ChatFind.hits(current, findText)
        guard !hits.isEmpty else { findPosition = 0; return }
        if let at = hits.firstIndex(where: { $0.turn == jumpTurn }), findFresh == false {
            findPosition = (at + delta + hits.count) % hits.count
        } else {
            findPosition = hits.count - 1
        }
        findFresh = false
        jump(to: hits[findPosition].turn)
    }

    func closeFind() {
        findOpen = false; findText = ""; findPosition = 0; findFresh = true
    }
}

// The bar above the transcript: the words, "2 / 5", earlier and next, close.
struct ChatFindBar: View {
    @ObservedObject var discussion: Discussion
    @FocusState private var focused: Bool

    var body: some View {
        let hits = ChatFind.hits(discussion.current, discussion.findText)
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField(L("이 대화에서 찾기", "Find in this chat"), text: $discussion.findText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { discussion.findStep(-1) }
                .onExitCommand { discussion.closeFind() }
                .onChange(of: discussion.findText) { _ in discussion.findFresh = true; discussion.findStep(0) }
            if !discussion.findText.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(hits.isEmpty ? L("없음", "No results") : "\(discussion.findPosition + 1) / \(hits.count)")
                    .font(.system(size: 11)).foregroundColor(.secondary).monospacedDigit()
                    .help(L("찾은 말이 있는 턴", "Turns with the words"))
            }
            Button(action: { discussion.findStep(-1) }) { Image(systemName: "chevron.up").frame(width: 20, height: 20) }
                .buttonStyle(.plainHit).disabled(hits.isEmpty).help(L("이전 (Return)", "Previous (Return)"))
            Button(action: { discussion.findStep(1) }) { Image(systemName: "chevron.down").frame(width: 20, height: 20) }
                .buttonStyle(.plainHit).disabled(hits.isEmpty).help(L("다음", "Next"))
            Button(action: { discussion.closeFind() }) { Image(systemName: "xmark.circle.fill").frame(width: 20, height: 20) }
                .buttonStyle(.plainHit).foregroundColor(.secondary).help(L("닫기 (Esc)", "Close (Esc)"))
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 520)
        .onAppear { focused = true }
        .onChange(of: discussion.findFocus) { _ in focused = true }
    }
}
