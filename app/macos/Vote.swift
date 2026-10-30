import Foundation

// Mode 4 · Vote: the user asks a question with choices. Every AI votes at the same time without seeing
// the others (so no one follows the crowd) and gives its reason; the app counts the votes itself.
// Choices the user listed are used as written; otherwise the moderator turns the question into choices.
struct VoteBallot: Codable, Equatable {
    var speaker: String
    var choice: Int?   // 1-based; nil = no valid vote
    var reason: String
}

enum VoteCount {
    static let maxOptions = 10

    // Choices written as a list, one per line: "1. …", "2) …", "A. …", "(b) …", "- …", "• …", "① …".
    static func options(in question: String) -> [String] {
        let pattern = #"^\s*(?:\(?(?:\d{1,2}|[A-Za-z])[.)]|[-*•·]|[①-⑩])\s*(.+?)\s*$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let found = question.components(separatedBy: .newlines).compactMap { line -> String? in
            let ns = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let text = ns.substring(with: match.range(at: 1))
            return text.isEmpty ? nil : text
        }
        return (2...maxOptions).contains(found.count) ? found : []
    }

    // {"options":["…","…"]} from the moderator.
    static func parseOptions(_ text: String) -> [String] {
        guard let object = json(text), let list = object["options"] as? [String] else { return [] }
        let cleaned = list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return (2...maxOptions).contains(cleaned.count) ? cleaned : []
    }

    // {"choice":2,"headline":"…","reason":"…"} from a voter; choice must be one of the options.
    static func parseBallot(_ text: String, options: Int) -> (choice: Int, headline: String?, reason: String)? {
        guard let object = json(text) else { return nil }
        let choice = (object["choice"] as? Int) ?? (object["choice"] as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let choice, (1...options).contains(choice) else { return nil }
        let reason = (object["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let headline = (object["headline"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (choice, headline?.isEmpty == false ? headline : nil, reason)
    }

    static func tally(_ ballots: [VoteBallot], options: Int) -> [Int] {
        var counts = Array(repeating: 0, count: options)
        for ballot in ballots { if let c = ballot.choice, counts.indices.contains(c - 1) { counts[c - 1] += 1 } }
        return counts
    }

    // The result in words, counted by the app (not written by an AI).
    static func summary(options: [String], ballots: [VoteBallot]) -> String {
        let counts = tally(ballots, options: options.count)
        let valid = counts.reduce(0, +)
        let top = counts.max() ?? 0
        let winners = counts.indices.filter { counts[$0] == top && top > 0 }
        func name(_ i: Int) -> String { L("\(i + 1)번 「\(options[i])」", "#\(i + 1) “\(options[i])”") }
        var lines: [String] = []
        if winners.isEmpty {
            lines.append(L("**유효한 표가 없어요.**", "**No valid votes.**"))
        } else if winners.count == 1 {
            lines.append(L("**결과: \(name(winners[0])) — \(top)/\(valid)표**", "**Result: \(name(winners[0])) — \(top) of \(valid) votes**"))
        } else {
            lines.append(L("**동점: \(winners.map(name).joined(separator: ", ")) — 각 \(top)표**",
                           "**Tie: \(winners.map(name).joined(separator: ", ")) — \(top) vote\(top == 1 ? "" : "s") each**"))
        }
        lines.append("")
        for i in options.indices {
            let voters = ballots.filter { $0.choice == i + 1 }.map(\.speaker)
            lines.append("- " + name(i) + L(": \(counts[i])표", ": \(counts[i])") + (voters.isEmpty ? "" : " (" + voters.joined(separator: ", ") + ")"))
        }
        let invalid = ballots.filter { $0.choice == nil }.map(\.speaker)
        if !invalid.isEmpty { lines.append(L("- 무효: ", "- No valid vote: ") + invalid.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    static func numbered(_ options: [String]) -> String {
        options.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    private static func json(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

extension Discussion {
    func runVote(question: String, history: [ChatTurn], rules: String, team: [Account],
                 leader moderator: Account, cancellation: DebateCancellation, id: UUID, index: Int) {
        let previous = Self.transcript(history)
        let prefix = previous.isEmpty ? "" : previous + "\n\n"
        var transcript = prefix + "[User]\n" + question
        let language = "Write in the language of the latest user message unless they request another language."

        // 1. The choices: as the user listed them, else the moderator proposes them.
        var options = VoteCount.options(in: question)
        if options.isEmpty {
            changeTurn(id, index) { $0.status = L("\(self.label(moderator))가 선택지를 정리하는 중…", "\(self.label(moderator)) is drafting the choices…") }
            let result = requestDebate(moderator, """
                \(Self.debateContext(rules: rules, transcript: transcript))
                [MODE4 OPTIONS]
                The user wants the AIs to vote on the latest user message. Turn it into 2–\(VoteCount.maxOptions) clear, mutually exclusive
                choices to vote on. Use the choices the user named, in their order and wording; add choices only if the user named
                fewer than two. Each choice is short (under 80 characters). Do not vote and do not explain.
                \(language)
                Return ONLY JSON: {"options":["…","…"]}
                Do not use tools, change files, or run commands.
                """, 180, cancellation)
            if cancellation.isCancelled { return endVote(id, index, stopped: true) }
            if case .success(let text) = result { options = VoteCount.parseOptions(text) }
            guard !options.isEmpty else {
                changeTurn(id, index, save: true) {
                    $0.error = L("선택지를 만들지 못했어요. 선택지를 한 줄에 하나씩(1. … 2. …) 적어 다시 보내 주세요.",
                                 "Could not make the choices. List them one per line (1. … 2. …) and send again.")
                }
                return endVote(id, index)
            }
        }
        let list = options
        changeTurn(id, index, save: true) { $0.voteOptions = list }
        transcript += "\n\n[Vote options]\n" + VoteCount.numbered(list)

        // 2. Everyone votes at once, without seeing the others.
        let names = team.map(label).joined(separator: ", ")
        changeTurn(id, index) { $0.status = L("모두 투표하는 중… (\(names))", "Everyone is voting… (\(names))") }
        let context = transcript
        let lock = NSLock()
        var ballots: [String: (VoteBallot, String)] = [:]   // account id -> ballot, transcript text
        let group = DispatchGroup()
        for account in team {
            let prompt = """
                \(Self.debateContext(rules: rules, transcript: context))
                [MODE4 VOTE]
                You are \(label(account)). Vote on the latest user message by choosing exactly one of the [Vote options].
                Vote on your own judgment; you cannot see the other AIs' votes. If facts matter, search the web first and cite
                what you found as [source: URL]; never invent a source.
                Give your reason: \(SpeechLength.rule(activeSpeechLength)). If none of the options is good, still choose the
                least bad one and say what you would do instead in the reason. \(language)
                Return ONLY JSON: {"choice":<option number>,"headline":"your main reason in one short sentence, at most 60 characters","reason":"…"}
                Use only web search and reading web pages. Do not change files or run commands.
                """
            group.enter()
            DispatchQueue.global().async {
                let result = self.requestDebate(account, prompt, 300, cancellation, web: true)
                defer { group.leave() }
                guard !cancellation.isCancelled else { return }
                var entry: ChatTurn.Entry
                var ballot = VoteBallot(speaker: self.label(account), choice: nil, reason: "")
                switch result {
                case .success(let text):
                    if let vote = VoteCount.parseBallot(text, options: list.count) {
                        ballot.choice = vote.choice
                        ballot.reason = vote.reason
                        let picked = L("\(vote.choice)번 「\(list[vote.choice - 1])」", "#\(vote.choice) “\(list[vote.choice - 1])”")
                        entry = ChatTurn.Entry(round: 1, speaker: ballot.speaker,
                                               text: "**" + L("투표: ", "Vote: ") + picked + "**\n\n" + vote.reason, failed: false)
                        entry.headline = picked + (vote.headline.map { " — " + $0 } ?? "")
                    } else {
                        entry = .init(round: 1, speaker: ballot.speaker,
                                      text: L("투표 형식을 읽지 못해 무효로 셌어요.", "Unreadable vote, counted as invalid.") + "\n\n" + text, failed: true)
                    }
                case .failure(let failure):
                    entry = .init(round: 1, speaker: ballot.speaker, text: Self.describe(failure), failed: true)
                }
                lock.lock(); ballots[account.id] = (ballot, entry.text); lock.unlock()
                self.changeTurn(id, index, save: true) { $0.entries.append(entry) }
            }
        }
        group.wait()
        if cancellation.isCancelled { return endVote(id, index, stopped: true) }

        // 3. The app counts, in the team's order.
        let ordered = team.compactMap { ballots[$0.id] }
        for (ballot, text) in ordered where ballot.choice != nil { transcript += "\n\n[\(ballot.speaker)]\n" + text }
        let final = VoteCount.summary(options: list, ballots: ordered.map(\.0))
        let raw = String(transcript.dropFirst(prefix.count))
        let sessions = activeSessionRoom != nil
        changeTurn(id, index, save: true) { t in
            t.votes = ordered.map(\.0)
            t.final = final
            t.finalBy = L("앱이 집계", "Counted by the app")
            if sessions { t.sessionTranscript = raw }
        }
        endVote(id, index)
    }

    private func endVote(_ id: UUID, _ index: Int, stopped: Bool = false) {
        changeTurn(id, index, save: true) { t in
            t.status = ""
            if stopped { t.endReason = L("사용자가 중지했습니다.", "Stopped by you.") }
        }
        finish(id, index)
    }
}
