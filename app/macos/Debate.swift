import Foundation
import Darwin

// One token per debate. Cancelling also interrupts the CLI currently answering.
final class DebateCancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func attach(_ process: Process) {
        lock.lock(); self.process = process; let stop = cancelled; lock.unlock()
        if stop { Self.end(process) }
    }
    func detach() { lock.lock(); process = nil; lock.unlock() }
    func cancel() {
        lock.lock(); cancelled = true; let active = process; lock.unlock()
        if let active { Self.end(active) }
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
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        guard let data = cleaned.data(using: .utf8), let decision = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        if decision.action == "finish", let reason = decision.reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reason.count <= 500 { return decision }
        if decision.action == "speak", let speaker = decision.speaker, team.contains(where: { $0.provider == speaker }),
           let focus = decision.focus, !focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, focus.count <= 500 { return decision }
        return nil
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

    static func leastSpoken(_ team: [Account], spoken: [Account.Provider: Int], last: Account.Provider) -> Account {
        let others = team.count > 1 ? team.filter { $0.provider != last } : team
        return others.min { (spoken[$0.provider] ?? 0) < (spoken[$1.provider] ?? 0) }!
    }

    func stopDebate() {
        guard running, let cancellation = debateCancellation else { return }
        stopping = true
        cancellation.cancel()
    }

    func runDebate(question: String, history: [ChatTurn], rules: String, team: [Account],
                   leader: Account.Provider, limit: Int, cancellation: DebateCancellation, id: UUID, index: Int) {
        var transcript = Self.transcript(history) + "\n\n[User]\n" + question
        var successful: Set<Account.Provider> = []
        var spoken: [Account.Provider: Int] = [:]
        var count = 0
        // The moderator may not end the debate before this many turns (each AI about twice, or 60% of the cap).
        let minTurns = Self.minimumDebateTurns(limit: limit, teamSize: team.count)
        // If the user's message names an AI ("제미나이한테…"), that AI opens the first lap.
        let firstLap = Self.namedFirst(question, team: team)
        var focus = ""
        var reason = L("최대 발언 수에 도달했습니다.", "Maximum number of turns reached.")
        let moderator = team.first { $0.provider == leader }
        var next = team.first!
        // The first lap follows the user's order. Thereafter, the moderator chooses each speaker.
        while count < limit && !cancellation.isCancelled {
            if count >= team.count {
                guard let moderator, successful.contains(leader) else {
                    reason = L("대표가 응답하지 못해 토론을 종료했습니다.", "The moderator was unavailable. Debate ended."); break
                }
                changeTurn(id, index) { $0.status = L("대표가 다음 발언 또는 종료를 판단하는 중…", "Moderator is choosing the next speaker or ending the debate…") }
                let mayFinish = count >= minTurns
                let counts = team.map { "\($0.provider.rawValue) \(spoken[$0.provider] ?? 0)" }.joined(separator: ", ")
                let prompt = """
                [MODE3 MODERATION]
                You are a neutral moderator. Your goal is a deeper debate, not a quick end. Do not favor your own earlier statements.
                Read the complete transcript and find the most important unresolved disagreement, an unanswered criticism, or a claim without evidence.
                Right of reply: if an AI's point was just challenged, prefer that AI as the next speaker. Everyone should speak more than once.
                If the latest user message asks for a particular AI to speak, give that AI the turn.
                The focus must name the specific claim to address and whom to answer.
                Participants: \(team.map { $0.provider.rawValue }.joined(separator: ","))
                Turns spoken so far: \(counts). Used \(count) of \(limit) speaking turns. Moderation and final synthesis are outside that limit.
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
                let result = requestDebate(moderator, prompt, 120, cancellation)
                if cancellation.isCancelled { break }
                guard case .success(let text) = result, let decision = DebateDecision.parse(text, team: team) else {
                    reason = L("대표의 진행 판단을 받지 못해 토론을 종료했습니다.", "Moderator decision failed. Debate ended."); break
                }
                if decision.action == "finish" && mayFinish { reason = decision.reason!; break }
                if decision.action == "finish" {
                    // Too early to end: the AI who has spoken least (not the last speaker) answers the strongest objection.
                    next = Self.leastSpoken(team, spoken: spoken, last: next.provider)
                    focus = L("아직 끝내기 이릅니다. 지금까지 당신 의견에 나온 가장 강한 반론에 답하거나, 다른 AI의 주장 중 가장 약한 부분을 반박하세요.",
                              "Too early to end. Answer the strongest objection raised against your view so far, or rebut the weakest claim made by another AI.")
                } else {
                    next = team.first { $0.provider == decision.speaker }!
                    focus = decision.focus!
                }
            } else {
                next = firstLap[count]
                focus = ""
            }
            let account = next
            let number = count + 1
            let currentFocus = focus
            changeTurn(id, index) { t in
                t.status = L("\(number)/\(limit) \(self.label(account)) 발언 중…", "\(number)/\(limit) \(self.label(account)) is speaking…")
                t.debateFocus = currentFocus.isEmpty ? nil : currentFocus
            }
            let prompt = """
            [MODE3 SPEECH]
            [Style rules]
            \(rules)
            You are \(label(account)). Read the entire conversation and respond to the latest user question and to the other AIs.
            Speak only as yourself. Never write, imagine, or quote a statement on another AI's behalf.
            Use 2–4 sentences, at most 400 characters (this debate limit overrides shorter length rules), in the language of the
            latest user message unless they request another language.
            Unless this is your first turn, begin by naming whose point you are answering (e.g. "ChatGPT의 ~에 대해").
            Defend your position when challenged; concede only to a specific stronger argument and say which one.
            Add a new argument, evidence, objection, or counter-rebuttal; do not merely agree or repeat. No separate summary.
            Do not use tools or execute commands.
            [Moderator focus]
            \(focus.isEmpty ? "Give your initial contribution." : focus)
            [Complete transcript]
            \(transcript)
            """
            let result = requestDebate(account, prompt, 240, cancellation)
            if cancellation.isCancelled { break }
            count += 1 // Failed attempts count too, so the loop is always bounded.
            var entry: ChatTurn.Entry
            switch result {
            case .success(let text):
                successful.insert(account.provider)
                spoken[account.provider, default: 0] += 1
                entry = .init(round: 1, speaker: label(account), text: text, failed: false)
                if !focus.isEmpty { transcript += "\n\n[Moderator focus]\n" + focus }
                transcript += "\n\n[\(label(account))]\n" + text
            case .failure(let failure):
                entry = .init(round: 1, speaker: label(account), text: Self.describe(failure), failed: true)
            }
            entry.focus = focus.isEmpty ? nil : focus
            changeTurn(id, index, save: true) { $0.entries.append(entry) }
            if count == team.count && successful.isEmpty {
                reason = L("모든 AI가 응답하지 못해 종료했습니다.", "No AI could respond. Debate ended."); break
            }
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
