import Foundation
import Darwin

// One token per debate. Cancelling also interrupts every CLI currently answering
// (several run at once during the opening round).
final class DebateCancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var processes: [Process] = []

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func attach(_ process: Process) {
        lock.lock(); processes.append(process); let stop = cancelled; lock.unlock()
        if stop { Self.end(process) }
    }
    func detach(_ process: Process) { lock.lock(); processes.removeAll { $0 === process }; lock.unlock() }
    func cancel() {
        lock.lock(); cancelled = true; let active = processes; lock.unlock()
        active.forEach(Self.end)
    }
    static func end(_ process: Process) {
        if process.isRunning { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

struct DebateDecision: Decodable {
    var action: String
    var speaker: Account.Provider?
    var focus: String?
    var reason: String?

    static func parse(_ text: String, team: [Account]) -> DebateDecision? {
        // Take the JSON object even if the moderator wrapped it in a code fence or a sentence.
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              var decision = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        // Long notes are cut, not rejected: a wordy moderator should not end the debate.
        decision.focus = decision.focus.map(Self.clip)
        decision.reason = decision.reason.map(Self.clip)
        if decision.action == "finish", let reason = decision.reason, !reason.isEmpty { return decision }
        if decision.action == "speak", let speaker = decision.speaker, team.contains(where: { $0.provider == speaker }),
           let focus = decision.focus, !focus.isEmpty { return decision }
        return nil
    }

    static func clip(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 600 ? String(trimmed.prefix(599)) + "…" : trimmed
    }
}

extension Discussion {
    static func minimumDebateTurns(limit: Int, teamSize: Int) -> Int {
        min(limit, max(teamSize * 2, Int((Double(limit) * 0.6).rounded(.up))))
    }

    // Words people use for each AI, in Korean and English (also common misspellings).
    static let aiNames: [Account.Provider: [String]] = [
        .claude: ["claude", "클로드", "클루드"],
        .codex: ["chatgpt", "gpt", "지피티", "챗지피티", "codex", "코덱스"],
        .gemini: ["gemini", "제미나이", "재미나이", "제미니"],
    ]

    // First-lap order: AIs named in the user's message go first, then the rest in the chosen order.
    static func namedFirst(_ question: String, team: [Account]) -> [Account] {
        let text = question.lowercased()
        let named = team.filter { account in (aiNames[account.provider] ?? []).contains { text.contains($0) } }
        return named + team.filter { account in !named.contains { $0.id == account.id } }
    }

    // Among AIs with turns left, the one who has spoken least (not the last speaker when possible).
    static func leastSpoken(_ team: [Account], spoken: [Account.Provider: Int], last: Account.Provider) -> Account {
        let others = team.count > 1 ? team.filter { $0.provider != last } : team
        return others.min { (spoken[$0.provider] ?? 0) < (spoken[$1.provider] ?? 0) }!
    }

    func stopDebate() {
        guard running, let cancellation = debateCancellation else { return }
        stopping = true
        cancellation.cancel()
    }

    private func debateSpeech(_ account: Account, rules: String, focus: String, transcript: String, opening: Bool) -> String {
        """
        [MODE3 SPEECH]
        [Style rules]
        \(rules)
        You are \(label(account)). Read the entire conversation and respond to the latest user question\(opening ? "" : " and to the other AIs").
        Speak only as yourself. Never write, imagine, or quote a statement on another AI's behalf.
        Use 2–4 sentences, at most 400 characters (this debate limit overrides shorter length rules), in the language of the
        latest user message unless they request another language.
        \(opening
            ? "This is the opening round: every AI answers at the same time without seeing the others. Give your own independent position with your main reason."
            : """
              Begin by naming whose point you are answering (e.g. "ChatGPT의 ~에 대해").
              Defend your position when challenged; concede only to a specific stronger argument and say which one.
              Add a new argument, evidence, objection, or counter-rebuttal; do not merely agree or repeat. No separate summary.
              """)
        Do not use tools or execute commands.
        \(Self.headlineRule)
        [Moderator focus]
        \(focus.isEmpty ? "Give your initial contribution." : focus)
        [Complete transcript]
        \(transcript)
        """
    }

    func runDebate(question: String, history: [ChatTurn], rules: String, team: [Account],
                   leader: Account.Provider, perAI: Int, cancellation: DebateCancellation, id: UUID, index: Int) {
        let limit = perAI * team.count
        var transcript = Self.transcript(history) + "\n\n[User]\n" + question
        var successful: Set<Account.Provider> = []
        var used: [Account.Provider: Int] = [:]     // turns attempted, failures included; at most perAI each
        var count = 0
        // The moderator may not end the debate before this many turns (each AI about twice, or 60% of the cap).
        let minTurns = Self.minimumDebateTurns(limit: limit, teamSize: team.count)
        var focus = ""
        var reason = L("모든 AI가 발언 횟수를 다 썼습니다.", "Every AI has used all of its turns.")
        let moderator = team.first { $0.provider == leader }
        var next = team.first!

        // Opening round: everyone answers at once without seeing the others (like mode 1's first step).
        // Replies appear as they arrive; the transcript lists them with any AI the user named first.
        let names = team.map(label).joined(separator: ", ")
        changeTurn(id, index) { $0.status = L("각자 첫 의견을 내는 중… (\(names))", "Everyone is giving an opening view… (\(names))") }
        let opening = transcript
        let lock = NSLock()
        var openings: [Account.Provider: Result<String, Answerer.Failure>] = [:]
        let group = DispatchGroup()
        for account in team {
            let prompt = debateSpeech(account, rules: rules, focus: "", transcript: opening, opening: true)
            group.enter()
            DispatchQueue.global().async {
                let result = self.requestDebate(account, prompt, 240, cancellation)
                lock.lock(); openings[account.provider] = result; lock.unlock()
                if !cancellation.isCancelled {
                    let entry: ChatTurn.Entry
                    switch result {
                    case .success(let text): entry = .reply(round: 1, speaker: self.label(account), text: text)
                    case .failure(let failure): entry = .init(round: 1, speaker: self.label(account), text: Self.describe(failure), failed: true)
                    }
                    self.changeTurn(id, index, save: true) { $0.entries.append(entry) }
                }
                group.leave()
            }
        }
        group.wait()
        if !cancellation.isCancelled {
            for account in Self.namedFirst(question, team: team) {
                count += 1
                used[account.provider, default: 0] += 1
                if case .success(let text) = openings[account.provider] {
                    successful.insert(account.provider)
                    transcript += "\n\n[\(label(account))]\n" + ChatTurn.Entry.reply(round: 1, speaker: "", text: text).text
                }
            }
            if successful.isEmpty { reason = L("모든 AI가 응답하지 못해 종료했습니다.", "No AI could respond. Debate ended."); count = limit }
        }

        // Then the moderator chooses each speaker, who reads everything said so far.
        while count < limit && !cancellation.isCancelled {
            guard let moderator, successful.contains(leader) else {
                reason = L("대표가 응답하지 못해 토론을 종료했습니다.", "The moderator was unavailable. Debate ended."); break
            }
            changeTurn(id, index) { $0.status = L("대표가 다음 발언 또는 종료를 판단하는 중…", "Moderator is choosing the next speaker or ending the debate…") }
            let mayFinish = count >= minTurns
            let available = team.filter { (used[$0.provider] ?? 0) < perAI }
            let counts = team.map { "\($0.provider.rawValue) \(used[$0.provider] ?? 0)/\(perAI)" }.joined(separator: ", ")
            let prompt = """
            [MODE3 MODERATION]
            You are a neutral moderator. Your goal is a deeper debate, not a quick end. Do not favor your own earlier statements.
            Read the complete transcript and find the most important unresolved disagreement, an unanswered criticism, or a claim without evidence.
            Right of reply: if an AI's point was just challenged, prefer that AI as the next speaker. Everyone should speak more than once.
            If the latest user message asks for a particular AI to speak, give that AI the turn.
            The focus must name the specific claim to address and whom to answer, in one or two sentences (under 250 characters).
            Participants: \(team.map { $0.provider.rawValue }.joined(separator: ","))
            Each AI may speak at most \(perAI) times. Turns used so far: \(counts).
            Only these AIs have turns left: \(available.map { $0.provider.rawValue }.joined(separator: ",")).
            Moderation and final synthesis do not count as turns.
            \(mayFinish
                ? "Finish only if the last two turns added no new argument or evidence, or every participant has explicitly agreed."
                : "Finishing is NOT allowed yet (minimum \(minTurns) turns). You must choose a speaker.")
            Return ONLY JSON: {"action":"speak","speaker":"claude|codex|gemini","focus":"specific next point"}
            or {"action":"finish","reason":"why discussion is sufficient"}.
            Write focus/reason in the language of the latest user message unless it requests another language.
            Do not use tools, change files, or run commands.
            [Complete transcript]
            \(transcript)
            """
            let result = requestDebate(moderator, prompt, 180, cancellation)
            if cancellation.isCancelled { break }
            guard case .success(let text) = result, let decision = DebateDecision.parse(text, team: team) else {
                reason = L("대표의 진행 판단을 받지 못해 토론을 종료했습니다.", "Moderator decision failed. Debate ended."); break
            }
            if decision.action == "finish" && mayFinish { reason = decision.reason!; break }
            if decision.action == "speak", let chosen = available.first(where: { $0.provider == decision.speaker }) {
                next = chosen
                focus = decision.focus!
            } else {
                // Too early to end, or the chosen AI has no turns left: the AI with turns left who has
                // spoken least (not the last speaker) answers the strongest objection.
                next = Self.leastSpoken(available, spoken: used, last: next.provider)
                focus = L("지금까지 당신 의견에 나온 가장 강한 반론에 답하거나, 다른 AI의 주장 중 가장 약한 부분을 반박하세요.",
                          "Answer the strongest objection raised against your view so far, or rebut the weakest claim made by another AI.")
            }
            let account = next
            let number = count + 1
            let currentFocus = focus
            changeTurn(id, index) { t in
                t.status = L("\(number)/\(limit) \(self.label(account)) 발언 중…", "\(number)/\(limit) \(self.label(account)) is speaking…")
                t.debateFocus = currentFocus
            }
            let speech = requestDebate(account, debateSpeech(account, rules: rules, focus: focus, transcript: transcript, opening: false), 240, cancellation)
            if cancellation.isCancelled { break }
            count += 1 // Failed attempts count too, so the loop is always bounded.
            used[account.provider, default: 0] += 1
            var entry: ChatTurn.Entry
            switch speech {
            case .success(let text):
                successful.insert(account.provider)
                entry = .reply(round: 1, speaker: label(account), text: text)
                transcript += "\n\n[Moderator focus]\n" + focus
                transcript += "\n\n[\(label(account))]\n" + entry.text
            case .failure(let failure):
                entry = .init(round: 1, speaker: label(account), text: Self.describe(failure), failed: true)
            }
            entry.focus = focus
            changeTurn(id, index, save: true) { $0.entries.append(entry) }
        }
        if cancellation.isCancelled { reason = L("사용자가 중지했습니다.", "Stopped by you.") }
        let ending = reason
        changeTurn(id, index, save: true) { t in t.endReason = ending; t.debateFocus = nil }
        // Stop never starts another request, including the final synthesis.
        if !cancellation.isCancelled, let moderator, successful.contains(leader) {
            changeTurn(id, index) { $0.status = L("대표가 결론과 남은 쟁점을 정리하는 중…", "Moderator is summarizing conclusions and open questions…") }
            let result = requestDebate(moderator, """
                [MODE3 FINAL]
                [Style rules]
                \(rules)
                Summarize the conclusions and any remaining disagreements in at most 3 short sentences.
                Use the language of the latest user question unless they request another language. Do not imply consensus where none exists.
                End reason: \(ending)
                Do not use tools, change files, or execute commands.
                [Complete transcript]
                \(transcript)
                """, 120, cancellation)
            if !cancellation.isCancelled {
                switch result {
                case .success(let text):
                    changeTurn(id, index, save: true) { $0.final = text; $0.finalBy = self.label(moderator) }
                case .failure:
                    changeTurn(id, index, save: true) { $0.error = L("최종 정리에 실패했습니다. 위 발언은 저장됐습니다.", "Final synthesis failed. The contributions have been saved.") }
                }
            }
        }
        changeTurn(id, index, save: true) { t in
            t.status = ""
            if cancellation.isCancelled { t.endReason = L("사용자가 중지했습니다.", "Stopped by you.") }
        }
        finish(id, index)
    }
}
