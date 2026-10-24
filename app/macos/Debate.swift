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
        guard process.isRunning else { return }
        // Stop command/MCP descendants too, before collecting the final source diff.
        // Killing only the CLI can leave a Python writer running after Stop.
        let listing = Process(), pipe = Pipe()
        listing.executableURL = URL(fileURLWithPath: "/bin/ps")
        listing.arguments = ["-axo", "pid=,ppid="]; listing.standardOutput = pipe; listing.standardError = FileHandle.nullDevice
        var children: [Int32] = []
        if (try? listing.run()) != nil {
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            listing.waitUntilExit()
            let pairs = text.split(separator: "\n").compactMap { line -> (Int32, Int32)? in
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count == 2, let pid = Int32(parts[0]), let parent = Int32(parts[1]) else { return nil }
                return (pid, parent)
            }
            var parents: Set<Int32> = [process.processIdentifier]
            while true {
                let next = pairs.filter { parents.contains($0.1) && !parents.contains($0.0) }.map { $0.0 }
                if next.isEmpty { break }
                children += next; parents.formUnion(next)
            }
        }
        for child in children.reversed() { kill(child, SIGKILL) }
        if process.isRunning { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

struct DebateDecision: Decodable {
    var action: String
    var speaker: Account.Provider?
    var focus: String?   // the task for the next speaker
    var reason: String?
    var board: String?   // the moderator's running notes: agreed / needs checking / still open

    enum CodingKeys: String, CodingKey { case action, speaker, focus, reason, board }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(String.self, forKey: .action)
        speaker = try? c.decode(Account.Provider.self, forKey: .speaker)
        focus = try? c.decode(String.self, forKey: .focus)
        reason = try? c.decode(String.self, forKey: .reason)
        board = try? c.decode(String.self, forKey: .board)  // a board in any other shape is ignored, not fatal
    }

    static func parse(_ text: String, team: [Account]) -> DebateDecision? {
        // Take the JSON object even if the moderator wrapped it in a code fence or a sentence.
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              var decision = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        // Long notes are cut, not rejected: a wordy moderator should not end the debate.
        decision.focus = decision.focus.map(Self.clip)
        decision.reason = decision.reason.map(Self.clip)
        decision.board = decision.board.map(Self.clip).flatMap { $0.isEmpty ? nil : $0 }
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

    // A reply that failed because the account's usage limit is used up: asking again would only fail again.
    static func isOutOfUsage(_ failure: Answerer.Failure) -> Bool {
        let text = describe(failure).lowercased()
        return ["429", "resource_exhausted", "quota", "usage limit", "rate limit", "limit reached"].contains { text.contains($0) }
    }

    func stopDebate() {
        guard running, let cancellation = debateCancellation else { return }
        stopping = true
        cancellation.cancel()
    }

    // Every mode 3 call starts with the same rules and the transcript, which only grows, and puts what
    // changes (the task, the focus) last. Repeated calls then share a long identical opening, which the
    // AI services can reuse from their cache instead of reading again.
    static func debateContext(rules: String, transcript: String) -> String {
        """
        [MODE3 DEBATE]
        [Style rules]
        \(rules)
        [Complete transcript]
        \(transcript)
        """
    }

    private func debateSpeech(_ account: Account, rules: String, focus: String, transcript: String, opening: Bool) -> String {
        """
        \(Self.debateContext(rules: rules, transcript: transcript))
        [MODE3 SPEECH]
        You are \(label(account)). The AIs here are one team. The shared goal is the best possible answer to the
        latest user question, not winning an argument.
        Speak only as yourself. Never write, imagine, or quote a statement on another AI's behalf.
        \(SpeechLength.rule(activeSpeechLength)) (this limit overrides shorter length rules), in the language of the
        latest user message unless they request another language.
        You can search the web and read pages. For any fact, number, name or link that matters, search first and cite
        what you found as [source: URL]. Use [from memory] or [estimate] only when a search found nothing. Never invent a source.
        Before calling another AI's claim unverified or wrong, check it yourself with a search. If your search confirms it, say so.
        If it does not, say what you searched and what you found instead. Never dispute a sourced claim without a source of your own.
        \(activeAdversarial ? "This is a critical debate: identify the strongest opposing interpretation, concrete failure cases and missing controls in other claims. Defend claims with evidence, rebut ideas rigorously, never attack people or invent disagreement. Do not agree merely to end the discussion." : "")
        \(opening
            ? "This is the opening round: every AI answers at the same time without seeing the others. Give your best answer to the question with its main reason."
            : """
              Do the moderator's task below. Your turn must add at least one thing the answer does not have yet:
              new evidence or data, a calculation, a concrete example or counterexample, or a specific improvement to the answer.
              If you think something said earlier is wrong, give the better version or the evidence, not only "that is wrong".
              When another AI is right, say so briefly and build on it. Change your own view freely if the discussion shows a better one.
              No attacks, no repeating, no separate summary.
              """)
        Use only web search and reading web pages. Do not change files or run commands.
        \(Pictures.rule(for: account.provider))
        \(Self.headlineRule)
        [Moderator focus]
        \(focus.isEmpty ? "Give your initial contribution." : focus)
        """
    }

    func runDebate(question: String, history: [ChatTurn], rules: String, team: [Account],
                   leader: Account.Provider, perAI: Int, cancellation: DebateCancellation, id: UUID, index: Int) {
        let limit = perAI * team.count
        let previous = Self.transcript(history)
        let prefix = previous.isEmpty ? "" : previous + "\n\n"
        var transcript = prefix + "[User]\n" + question
        var successful: Set<Account.Provider> = []
        var used: [Account.Provider: Int] = [:]     // turns attempted, failures included; at most perAI each
        var count = 0
        // The moderator may not end the debate before this many turns (each AI about twice, or 60% of the cap).
        var focus = ""
        var board = ""
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
        var openingPictures: [Account.Provider: [ChatImage]] = [:]
        let group = DispatchGroup()
        for account in team {
            let prompt = debateSpeech(account, rules: rules, focus: "", transcript: opening, opening: true)
            group.enter()
            DispatchQueue.global().async {
                let started = Date()
                var result = self.requestDebate(account, prompt, 300, cancellation, web: true)
                var pictures: [ChatImage] = []
                if case .success(let text) = result {
                    let harvest = self.collectPictures(text, account: account, since: started, id: id)
                    result = .success(harvest.text); pictures = harvest.images
                }
                lock.lock(); openings[account.provider] = result; openingPictures[account.provider] = pictures; lock.unlock()
                if !cancellation.isCancelled {
                    var entry: ChatTurn.Entry
                    switch result {
                    case .success(let text): entry = .reply(round: 1, speaker: self.label(account), text: text); entry.images = pictures.isEmpty ? nil : pictures
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
                switch openings[account.provider] {
                case .success(let text):
                    successful.insert(account.provider)
                    transcript += "\n\n[\(label(account))]\n" + ChatTurn.Entry.reply(round: 1, speaker: "", text: text).text
                    sharePictures(openingPictures[account.provider] ?? [], by: label(account))
                case .failure(let failure) where Self.isOutOfUsage(failure):
                    used[account.provider] = perAI  // out of usage: leave it out of the rest of the debate
                default: break
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
            let available = team.filter { (used[$0.provider] ?? 0) < perAI }
            guard !available.isEmpty else { break }
            let counts = team.map { "\($0.provider.rawValue) \(used[$0.provider] ?? 0)/\(perAI)" }.joined(separator: ", ")
            let prompt = """
            \(Self.debateContext(rules: rules, transcript: transcript))
            [MODE3 MODERATION]
            You are the neutral moderator. The goal is the best possible answer to the latest user question.
            Do not favor your own earlier statements.
            \(activeAdversarial ? "Critical debate: actively assign unresolved opposing hypotheses, rebuttals, stress tests and missing controls; resolve material disagreements with evidence. No personal attacks or fabricated objections." : "")
            1. Update the board: what is agreed, what needs checking, and what is still open. A claim backed by a URL that no one has
               contradicted with another source counts as verified. Saying "unverified" without searching does not make it unverified.
            2. Find the most important thing the answer still lacks: missing evidence or data, an unchecked number, an unanswered part of
               the question, a perspective nobody covered, or a real disagreement that changes the answer.
            3. Give that as a task to the AI best placed to do it. The AIs can search the web, so a task can be "search for…".
               The focus is a task ("search…", "find…", "calculate…", "propose…", "check…"),
               never "rebut X". One or two sentences, under 250 characters.
            If the latest user message asks for a particular AI to speak, give that AI the turn.
            Participants: \(team.map { $0.provider.rawValue }.joined(separator: ","))
            Each AI may speak at most \(perAI) times. Turns used so far: \(counts).
            Only these AIs have turns left: \(available.map { $0.provider.rawValue }.joined(separator: ",")).
            Moderation and final synthesis do not count as turns.
            Finish as soon as the answer is good enough: nothing important is missing, or the last turns did not change the board.
            Do not continue just to use up turns.
            Return ONLY JSON: {"action":"speak","speaker":"claude|codex|gemini","focus":"task for that AI","board":"Agreed: … / Check: … / Open: …"}
            or {"action":"finish","reason":"why the answer is good enough","board":"…"}.
            Write focus/reason/board in the language of the latest user message unless it requests another language.
            Do not use tools, change files, or run commands.
            """
            let result = requestDebate(moderator, prompt, 180, cancellation)
            if cancellation.isCancelled { break }
            guard case .success(let text) = result, let decision = DebateDecision.parse(text, team: team) else {
                reason = L("대표의 진행 판단을 받지 못해 토론을 종료했습니다.", "Moderator decision failed. Debate ended."); break
            }
            if let notes = decision.board { board = notes }
            let criticalPending = activeAdversarial ? available.filter { (used[$0.provider] ?? 0) < 2 } : []
            if decision.action == "finish" && criticalPending.isEmpty { reason = decision.reason!; break }
            if decision.action == "finish", let critic = criticalPending.first {
                next = critic
                focus = L("다른 AI의 핵심 주장에 대한 가장 강한 반론·대안과 이를 판별할 근거를 제시하세요. 억지 반대나 인신공격은 하지 마세요.", "Give the strongest evidence-based objection or alternative to another claim and a discriminating check. No fabricated disagreement or personal attacks.")
            } else if let chosen = available.first(where: { $0.provider == decision.speaker }) {
                next = chosen
                focus = decision.focus!
            } else {
                // The chosen AI has no turns left: the AI with turns left who has spoken least (not the last
                // speaker) adds what the answer is missing.
                next = Self.leastSpoken(available, spoken: used, last: next.provider)
                focus = L("지금 답에서 가장 중요하게 빠진 것을 하나 더하세요: 새 근거나 데이터, 계산, 구체적인 예, 또는 답을 고칠 구체적인 수정안.",
                          "Add the most important thing the answer is still missing: new evidence or data, a calculation, a concrete example, or a specific fix.")
            }
            let account = next
            let number = count + 1
            let currentFocus = focus
            changeTurn(id, index) { t in
                t.status = L("\(number)/\(limit) \(self.label(account)) 발언 중…", "\(number)/\(limit) \(self.label(account)) is speaking…")
                t.debateFocus = currentFocus
            }
            let started = Date()
            let speech = requestDebate(account, debateSpeech(account, rules: rules, focus: focus, transcript: transcript, opening: false), 300, cancellation, web: true)
            if cancellation.isCancelled { break }
            count += 1 // Failed attempts count too, so the loop is always bounded.
            used[account.provider, default: 0] += 1
            var entry: ChatTurn.Entry
            switch speech {
            case .success(let text):
                successful.insert(account.provider)
                let harvest = collectPictures(text, account: account, since: started, id: id)
                entry = .reply(round: 1, speaker: label(account), text: harvest.text)
                entry.images = harvest.images.isEmpty ? nil : harvest.images
                sharePictures(harvest.images, by: label(account))
                if !board.isEmpty { transcript += "\n\n[Moderator board]\n" + board }
                transcript += "\n\n[Moderator focus]\n" + focus
                transcript += "\n\n[\(label(account))]\n" + entry.text
            case .failure(let failure):
                entry = .init(round: 1, speaker: label(account), text: Self.describe(failure), failed: true)
                if Self.isOutOfUsage(failure) { used[account.provider] = perAI }
            }
            entry.focus = focus
            changeTurn(id, index, save: true) { $0.entries.append(entry) }
        }
        if cancellation.isCancelled { reason = L("사용자가 중지했습니다.", "Stopped by you.") }
        let ending = reason
        if activeSessionRoom != nil {
            let raw = String(transcript.dropFirst(prefix.count))
            changeTurn(id, index, save: true) { $0.sessionTranscript = raw }
        }
        changeTurn(id, index, save: true) { t in t.endReason = ending; t.debateFocus = nil }
        // Stop never starts another request, including the final synthesis.
        if !cancellation.isCancelled, let moderator, successful.contains(leader) {
            changeTurn(id, index) { $0.status = L("대표가 최종 답을 정리하는 중…", "Moderator is writing the final answer…") }
            let finalStarted = Date()
            let result = requestDebate(moderator, """
                \(Self.debateContext(rules: rules, transcript: transcript))
                [MODE3 FINAL]
                Write the final answer to the latest user question, using the best of what the team found.
                Answer the question directly first, with the links the team found. Then, briefly: what rests on a source and what is an estimate,
                and any open question that would change the answer (skip it if there is none).
                At most about 8 short sentences or bullet points. Do not describe the discussion or who said what.
                Use the language of the latest user question unless they request another language. Do not imply certainty or consensus where none exists.
                \(board.isEmpty ? "" : "Moderator board:\n" + board + "\n")End reason: \(ending)
                If the user asked for a picture and the team made some, they are already shown: name the best one by its marker
                (e.g. [그림 2] / [Picture 2]) and say why in one line; make a new one only if the team made none.
                \(Pictures.rule(for: moderator.provider))
                Do not change files or execute commands.
                """, 180, cancellation)
            if !cancellation.isCancelled {
                switch result {
                case .success(let text):
                    let harvest = collectPictures(text, account: moderator, since: finalStarted, id: id)
                    changeTurn(id, index, save: true) {
                        $0.final = harvest.text; $0.finalBy = self.label(moderator)
                        $0.finalImages = harvest.images.isEmpty ? nil : harvest.images
                    }
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
