import Foundation
import Cocoa

// Asks one AI one prompt through its own command line tool, logged in with the subscription
// (no API keys). Answers only: every tool is started with file editing and commands turned off,
// in an empty folder (~/.ai-illuminati/chat).
enum Answerer {
    static let chatDir: String = {
        let dir = AccountStore.home + "/.ai-illuminati/chat"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    enum Failure: Error { case missingTool, failed(String), timedOut }

    static func ask(_ account: Account, prompt: String, timeout: TimeInterval = 240) -> Result<String, Failure> {
        let outFile = chatDir + "/answer-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: outFile) }
        let binary: String?
        let arguments: [String]
        switch account.provider {
        case .claude:
            binary = ClaudeUsage.binary
            arguments = ["-p", prompt, "--tools", "", "--no-session-persistence"]
        case .codex:
            binary = CodexUsage.binary
            arguments = ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral",
                         "--color", "never", "-C", chatDir, "-o", outFile, prompt]
        case .gemini:
            binary = Login.agyInstalled ? Login.home + "/.local/bin/agy" : nil
            arguments = ["-p", prompt, "--mode", "plan", "--sandbox", "--disable-slash-commands",
                         "--print-timeout", "\(Int(timeout) - 10)s"]
        }
        guard let binary else { return .failure(.missingTool) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = account.environment
        process.currentDirectoryURL = URL(fileURLWithPath: chatDir)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .failure(.missingTool) }

        // Read both pipes while it runs (a full pipe would stop the tool).
        var stdout = Data(), stderr = Data()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global().async { stdout = out.fileHandleForReading.readDataToEndOfFile(); readers.leave() }
        readers.enter()
        DispatchQueue.global().async { stderr = err.fileHandleForReading.readDataToEndOfFile(); readers.leave() }
        if readers.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return .failure(.timedOut)
        }
        process.waitUntilExit()

        var text = String(data: stdout, encoding: .utf8) ?? ""
        if account.provider == .codex, let file = try? String(contentsOfFile: outFile, encoding: .utf8) { text = file }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !text.isEmpty else {
            let why = (String(data: stderr, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.failed(String(why.suffix(300))))
        }
        return .success(text)
    }
}

// One question and how the AIs worked it out.
struct ChatTurn: Identifiable, Codable {
    struct Entry: Identifiable, Codable {
        var id = UUID()
        var round: Int        // 1 = own answer, 2 = after reading the others
        var speaker: String
        var text: String
        var failed: Bool
    }
    var id = UUID()
    var question: String
    var status = ""
    var entries: [Entry] = []
    var final: String?
    var finalBy: String?
    var error: String?
    var mode: Int?  // missing in older chats means mode 1
    var orderNote: String?
}

// One group chat, saved as ~/Library/Application Support/AI Illuminati/chats/<id>.json.
// `summary` is a few lines about everything so far; it is what the AIs get as context.
struct ChatConfiguration: Codable {
    var mode = 1
    var order: [Account.Provider] = [.claude, .codex, .gemini]
    var participants: [Account.Provider] = [.claude, .codex, .gemini]
    var leader: Account.Provider = .claude
}

struct Conversation: Identifiable, Codable {
    var id = UUID()
    var title = "새 대화"
    var createdAt = Date()
    var updatedAt = Date()
    var turns: [ChatTurn] = []
    var summary = ""
    var configuration: ChatConfiguration?
}

enum ChatStore {
    static let dir = AccountStore.supportDir + "/chats"

    static func loadAll() -> [Conversation] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.filter { $0.hasSuffix(".json") }
            .compactMap { try? decoder.decode(Conversation.self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/" + $0))) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func save(_ conversation: Conversation) {
        guard !conversation.turns.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        try? encoder.encode(conversation).write(to: URL(fileURLWithPath: dir + "/\(conversation.id.uuidString).json"), options: .atomic)
    }

    static func delete(_ conversation: Conversation) throws {
        let path = dir + "/\(conversation.id.uuidString).json"
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }
}

// The discussion: 1) everyone answers on their own, 2) everyone reads the others and improves
// their answer once, 3) one AI (the one with the most usage left) writes the final answer,
// 4) that AI updates the conversation's short summary, which is the context for the next question.
// The chat rules from Settings go at the top of every message.
final class Discussion: ObservableObject {
    @Published var conversations: [Conversation]
    @Published var currentID: UUID
    @Published var running = false
    @Published var draft = ""
    @Published var useClaude = true
    @Published var useCodex = true
    @Published var useGemini = true

    // Injected in tests so full-history sequencing can be checked without spending usage.
    var answer: (Account, String, TimeInterval) -> Result<String, Answerer.Failure> = {
        Answerer.ask($0, prompt: $1, timeout: $2)
    }

    var configuration: ChatConfiguration { current.configuration ?? ChatConfiguration() }

    func configure(_ edit: (inout ChatConfiguration) -> Void) {
        guard !running else { return }
        var config = configuration
        edit(&config)
        change(currentID, save: true) { $0.configuration = config }
    }

    func setMode(_ mode: Int) {
        guard current.turns.isEmpty else { return }
        configure { $0.mode = mode }
    }

    func moveProvider(_ provider: Account.Provider, by offset: Int) {
        configure { config in
            guard let from = config.order.firstIndex(of: provider) else { return }
            let to = from + offset
            if config.order.indices.contains(to) { config.order.swapAt(from, to) }
        }
    }

    func setParticipation(_ provider: Account.Provider, enabled: Bool) {
        configure { config in
            config.participants.removeAll { $0 == provider }
            if enabled { config.participants.append(provider) }
            if !config.participants.contains(config.leader), let first = config.order.first(where: { config.participants.contains($0) }) {
                config.leader = first
            }
        }
    }

    private let model: AppModel
    private let work = DispatchQueue(label: "discussion")

    init(model: AppModel) {
        self.model = model
        let fresh = Conversation()
        conversations = [fresh] + ChatStore.loadAll()
        currentID = fresh.id
    }

    var current: Conversation { conversations.first { $0.id == currentID } ?? Conversation() }

    // Starts an empty chat (reuses the open one if it is still empty).
    func newConversation() {
        guard !running else { return }
        if current.turns.isEmpty { return }
        conversations.removeAll { $0.turns.isEmpty }
        let fresh = Conversation()
        conversations.insert(fresh, at: 0)
        currentID = fresh.id
    }

    func open(_ id: UUID) {
        guard !running else { return }
        conversations.removeAll { $0.turns.isEmpty && $0.id != id }
        currentID = id
    }

    func delete(_ id: UUID) {
        guard !running, let conversation = conversations.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "이 대화를 영구 삭제할까요?"
        alert.informativeText = "‘\(conversation.title)’의 질문, 답변, 대화 요약을 저장된 파일과 함께 삭제합니다. 되돌릴 수 없어요."
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try ChatStore.delete(conversation)
        } catch {
            let failure = NSAlert()
            failure.messageText = "대화를 삭제하지 못했어요"
            failure.informativeText = "저장된 파일을 지우지 못해 대화를 그대로 유지했습니다.\n" + error.localizedDescription
            failure.runModal()
            return
        }
        conversations.removeAll { $0.id == id }
        if currentID == id {
            let fresh = Conversation()
            conversations.insert(fresh, at: 0)
            currentID = fresh.id
        }
    }

    func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !running else { return }
        let team = pickTeam()
        draft = ""
        let id = currentID
        var turn = ChatTurn(question: question)
        let config = configuration
        turn.mode = config.mode
        guard team.count > 0 else {
            turn.error = "답할 수 있는 AI가 없어요. 참여 AI를 켜고, 설정에서 로그인됐는지 확인해 주세요."
            change(id) { $0.turns.append(turn) }
            return
        }
        let history = current.turns
        let summary = current.summary
        change(id) { c in
            if c.turns.isEmpty { c.title = String(question.prefix(40)) }
            c.turns.append(turn)
        }
        running = true
        let index = current.turns.count - 1
        let usage = model.latestUsage
        let rules = model.chatRules.trimmingCharacters(in: .whitespacesAndNewlines)
        work.async {
            if config.mode == 2 {
                self.runSequential(question: question, history: history, rules: rules, team: team,
                                   leader: config.leader, id: id, index: index)
            } else {
                self.run(question: question, summary: summary, rules: rules, team: team, usage: usage, id: id, index: index)
            }
        }
    }

    // Per AI, the logged-in account with the most usage left (accounts at 0% are skipped).
    private func pickTeam() -> [Account] {
        var providers: [Account.Provider] = []
        if useClaude { providers.append(.claude) }
        if useCodex { providers.append(.codex) }
        if useGemini { providers.append(.gemini) }
        if configuration.mode == 2 {
            providers = configuration.order.filter { configuration.participants.contains($0) }
        }
        return providers.compactMap { provider in
            model.accounts.filter { $0.provider == provider }
                .compactMap { account -> (Account, Double)? in
                    let usage = model.latestUsage[account.id]
                    if usage?.needsLogin == true { return nil }
                    let left = usage?.leftNow ?? 50
                    return left > 0 ? (account, left) : nil
                }
                .max { $0.1 < $1.1 }?.0
        }
    }

    private func label(_ account: Account) -> String {
        account.name.hasPrefix(account.provider.title) ? account.name : "\(account.provider.title) (\(account.name))"
    }

    // Changes a conversation (on the main thread), saves it and moves it to the top of the list.
    private func change(_ id: UUID, save: Bool = false, _ edit: @escaping (inout Conversation) -> Void) {
        let apply = {
            guard let i = self.conversations.firstIndex(where: { $0.id == id }) else { return }
            edit(&self.conversations[i])
            if save {
                self.conversations[i].updatedAt = Date()
                ChatStore.save(self.conversations[i])
                let moved = self.conversations.remove(at: i)
                self.conversations.insert(moved, at: 0)
            }
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    private func changeTurn(_ id: UUID, _ index: Int, save: Bool = false, _ edit: @escaping (inout ChatTurn) -> Void) {
        change(id, save: save) { c in if c.turns.indices.contains(index) { edit(&c.turns[index]) } }
    }

    // Asks everyone at once and waits for all answers.
    private func askAll(_ team: [Account], round: Int, prompt: (Account) -> String, id: UUID, index: Int) -> [(Account, String)] {
        let lock = NSLock()
        var answers: [(Account, String)] = []
        let group = DispatchGroup()
        for account in team {
            let text = prompt(account)
            group.enter()
            DispatchQueue.global().async {
                let result = Answerer.ask(account, prompt: text)
                let entry: ChatTurn.Entry
                switch result {
                case .success(let answer):
                    lock.lock(); answers.append((account, answer)); lock.unlock()
                    entry = .init(round: round, speaker: self.label(account), text: answer, failed: false)
                case .failure(let failure):
                    entry = .init(round: round, speaker: self.label(account), text: Self.describe(failure), failed: true)
                }
                self.changeTurn(id, index) { $0.entries.append(entry) }
                group.leave()
            }
        }
        group.wait()
        // Keep the team's order (not the order they finished in).
        return team.compactMap { account in answers.first { $0.0.id == account.id } }
    }

    private func run(question: String, summary: String, rules: String, team: [Account],
                     usage: [String: AIUsage], id: UUID, index: Int) {
        let names = team.map(label).joined(separator: ", ")
        let head = (rules.isEmpty ? "" : "[규칙 — 반드시 지킬 것]\n\(rules)\n\n")
            + (summary.isEmpty ? "" : "[지금까지의 대화 요약]\n\(summary)\n\n")

        changeTurn(id, index) { $0.status = "1/3 각자 답하는 중… (\(names))" }
        let first = askAll(team, round: 1, prompt: { account in
            """
            \(head)당신은 \(self.label(account))입니다. 여러 AI(\(names))가 함께 사용자의 질문에 답하는 토론의 1단계입니다.
            다른 AI를 신경 쓰지 말고 당신의 가장 좋은 답을 한국어로 쓰세요. 파일을 만들거나 명령을 실행하지 마세요.

            [질문]
            \(question)
            """
        }, id: id, index: index)
        guard !first.isEmpty else { return finish(id, index, error: "모든 AI가 답하지 못했어요.") }

        var current = first
        if first.count > 1 {
            changeTurn(id, index) { $0.status = "2/3 서로 답을 검토하는 중…" }
            let answersText = first.map { "### \(label($0.0))\n\($0.1)" }.joined(separator: "\n\n")
            let second = askAll(first.map(\.0), round: 2, prompt: { account in
                """
                \(head)당신은 \(self.label(account))입니다. 토론의 2단계입니다. 아래는 같은 질문에 대한 1단계 답들입니다(당신의 답 포함).
                다른 답과 비교해 틀린 점, 빠진 점만 짧게 짚고, 그걸 반영해 고친 당신의 답을 한국어로 쓰세요.
                형식: "검토:" 다음에 검토, "고친 답:" 다음에 답. 고친 답은 당신의 1단계 답보다 길게 쓰지 마세요.

                [질문]
                \(question)

                [1단계 답들]
                \(answersText)
                """
            }, id: id, index: index)
            if !second.isEmpty { current = second }
        }

        // The one with the most usage left writes the final answer and the summary.
        let writer = current.map(\.0).max { (usage[$0.id]?.leftNow ?? 50) < (usage[$1.id]?.leftNow ?? 50) }!
        var final: String
        var finalBy = label(writer)
        if current.count == 1 {
            final = current[0].1
        } else {
            changeTurn(id, index) { $0.status = "3/3 \(self.label(writer))이(가) 최종 답을 정리하는 중…" }
            let finalPrompt = """
            \(head)당신은 \(label(writer))이고, 여러 AI의 토론을 정리하는 역할입니다. 아래는 각 AI가 서로 검토한 뒤 고친 답입니다.
            이를 종합해 사용자에게 줄 하나의 최종 답을 한국어로 쓰세요. 정확한 내용을 우선하고, 의견이 갈린 부분이 있으면 한 줄로 밝히세요.
            토론 과정이나 "AI들이 말하길" 같은 설명 없이 답만 쓰세요.

            [질문]
            \(question)

            [고친 답들]
            \(current.map { "### \(label($0.0))\n\($0.1)" }.joined(separator: "\n\n"))
            """
            switch Answerer.ask(writer, prompt: finalPrompt) {
            case .success(let text):
                final = text
            case .failure:
                final = current.first { $0.0.id == writer.id }!.1
                finalBy += " (정리 실패, 고친 답 그대로)"
            }
        }
        changeTurn(id, index, save: true) { t in
            t.final = final
            t.finalBy = finalBy
            t.status = "대화 요약 중…"
        }

        // Short summary of the whole chat so far, for the next question.
        let summaryPrompt = """
        아래 [이전 요약]에 이번 [질문]과 [최종 답]을 합쳐, 이 대화의 요약을 새로 쓰세요.
        다음 질문 때 다른 AI들이 맥락으로 읽을 거예요. 300자 이내로, 결론과 사용자의 관심·선호만 남기세요. 요약만 쓰세요.

        [이전 요약]
        \(summary.isEmpty ? "(없음)" : summary)

        [질문]
        \(question)

        [최종 답]
        \(final)
        """
        let newSummary: String
        switch Answerer.ask(writer, prompt: summaryPrompt, timeout: 120) {
        case .success(let text): newSummary = text
        case .failure: newSummary = (summary.isEmpty ? "" : summary + "\n") + "- 질문: \(question.prefix(80)) → 답: \(final.prefix(160))"
        }
        change(id, save: true) { c in
            c.summary = newSummary
            if c.turns.indices.contains(index) { c.turns[index].status = "" }
        }
        finish(id, index)
    }

    // Full transcript, without summarizing or dropping earlier turns.
    static func transcript(_ turns: [ChatTurn]) -> String {
        turns.map { turn in
            var parts = ["[사용자]\n" + turn.question]
            parts += turn.entries.filter { !$0.failed }.map { "[" + $0.speaker + "]\n" + $0.text }
            if let final = turn.final { parts.append("[최종 답]\n" + final) }
            return parts.joined(separator: "\n\n")
        }.joined(separator: "\n\n")
    }

    static func proposedOrder(_ text: String, team: [Account]) -> [Account.Provider]? {
        let tokens = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let order = tokens.compactMap(Account.Provider.init(rawValue:))
        let expected = team.map(\.provider)
        guard order.count == expected.count, Set(order) == Set(expected) else { return nil }
        return order
    }

    private func runSequential(question: String, history: [ChatTurn], rules: String,
                               team: [Account], leader: Account.Provider, id: UUID, index: Int) {
        var transcript = Self.transcript(history)
        transcript += "\n\n[사용자]\n" + question
        var successful: [Account] = []
        for (position, account) in team.enumerated() {
            changeTurn(id, index) { $0.status = "\(position + 1)/\(team.count) \(self.label(account)) 발언 중…" }
            let prompt = """
            [공통 규칙]
            \(rules)
            [모드2 발언 규칙 — 답 길이는 이 규칙 우선]
            당신은 \(label(account))입니다. 아래는 이 방의 전체 대화 원문입니다.
            마지막 사용자 질문과 앞선 AI의 발언을 읽고 자연스럽게 이어 말하세요.
            한국어 1~2문장, 200자 이내로 말하세요. 인사나 단순 동의, 앞말 반복 없이 새 관점, 반론, 보충 중 하나를 말하세요.
            별도 최종 정리나 요약은 하지 마세요. 파일을 만들거나 명령을 실행하지 마세요.

            [전체 대화 원문]
            \(transcript)
            """
            let entry: ChatTurn.Entry
            switch answer(account, prompt, 240) {
            case .success(let text):
                entry = .init(round: 1, speaker: label(account), text: text, failed: false)
                successful.append(account)
                transcript += "\n\n[\(label(account))]\n\(text)"
            case .failure(let failure):
                entry = .init(round: 1, speaker: label(account), text: Self.describe(failure), failed: true)
            }
            changeTurn(id, index, save: true) { $0.entries.append(entry) }
        }
        guard !successful.isEmpty else { return finish(id, index, error: "모든 AI가 답하지 못했어요.") }
        // Only the selected representative schedules. If unavailable, retain the user's order.
        if let moderator = successful.first(where: { $0.provider == leader }), team.count > 1 {
            changeTurn(id, index) { $0.status = "대표 \(self.label(moderator))이(가) 다음 순서를 정하는 중…" }
            let schedulePrompt = """
            당신은 대화 진행자입니다. 전체 대화를 읽고 다음 사용자 질문에 답할 AI들의 발언 순서를 정하세요.
            참여 AI: \(team.map { $0.provider.rawValue }.joined(separator: ","))
            새 관점을 먼저 제시할 AI, 반론이나 보충할 AI 순서로 판단하세요.
            참여 AI를 각각 정확히 한 번 포함해 쉼표로 구분한 ID만 출력하세요. 설명 금지.
            파일을 만들거나 명령을 실행하지 마세요.

            [전체 대화 원문]
            \(transcript)
            """
            if case .success(let text) = answer(moderator, schedulePrompt, 120),
               let order = Self.proposedOrder(text, team: team) {
                change(id, save: true) { c in
                    var config = c.configuration ?? ChatConfiguration()
                    config.order = order + config.order.filter { !order.contains($0) }
                    c.configuration = config
                    c.turns[index].orderNote = "다음 순서: " + order.map(\.title).joined(separator: " → ")
                }
            } else {
                changeTurn(id, index, save: true) { $0.orderNote = "대표의 순서 지정에 실패해 기존 순서를 유지합니다." }
            }
        } else if team.count > 1 {
            changeTurn(id, index, save: true) { $0.orderNote = "대표가 발언하지 못해 기존 순서를 유지합니다." }
        }
        changeTurn(id, index, save: true) { $0.status = "" }
        finish(id, index)
    }

    private func finish(_ id: UUID, _ index: Int, error: String? = nil) {
        if let error {
            changeTurn(id, index, save: true) { t in
                t.error = error
                t.status = ""
            }
        }
        DispatchQueue.main.async {
            self.running = false
            self.model.onAccountsChange?()   // refresh the usage numbers after the discussion
        }
    }

    private static func describe(_ failure: Answerer.Failure) -> String {
        switch failure {
        case .missingTool: return "프로그램을 찾지 못했어요."
        case .timedOut: return "시간 안에 답하지 못했어요."
        case .failed(let why): return "답하지 못했어요." + (why.isEmpty ? "" : " (\(why))")
        }
    }
}
