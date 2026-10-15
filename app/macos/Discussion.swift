import Foundation

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
struct ChatTurn: Identifiable {
    struct Entry: Identifiable {
        let id = UUID()
        let round: Int        // 1 = own answer, 2 = after reading the others
        let speaker: String
        let text: String
        let failed: Bool
    }
    let id = UUID()
    let question: String
    var status = ""
    var entries: [Entry] = []
    var final: String?
    var finalBy: String?
    var error: String?
}

// The discussion: 1) everyone answers on their own, 2) everyone reads the others and improves
// their answer once, 3) one AI (the one with the most usage left) writes the final answer.
final class Discussion: ObservableObject {
    @Published var turns: [ChatTurn] = []
    @Published var running = false
    @Published var draft = ""
    @Published var useClaude = true
    @Published var useCodex = true
    @Published var useGemini = true

    private let model: AppModel
    private let work = DispatchQueue(label: "discussion")

    init(model: AppModel) { self.model = model }

    func reset() {
        guard !running else { return }
        turns = []
    }

    func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !running else { return }
        let team = pickTeam()
        draft = ""
        var turn = ChatTurn(question: question)
        guard team.count > 0 else {
            turn.error = "답할 수 있는 AI가 없어요. 참여 AI를 켜고, 설정에서 로그인됐는지 확인해 주세요."
            turns.append(turn)
            return
        }
        let history = turns.suffix(3).compactMap { t in t.final.map { (t.question, $0) } }
        turns.append(turn)
        running = true
        let index = turns.count - 1
        let usage = model.latestUsage
        work.async { self.run(question: question, history: history, team: team, usage: usage, index: index) }
    }

    // Per AI, the logged-in account with the most usage left (accounts at 0% are skipped).
    private func pickTeam() -> [Account] {
        var providers: [Account.Provider] = []
        if useClaude { providers.append(.claude) }
        if useCodex { providers.append(.codex) }
        if useGemini { providers.append(.gemini) }
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

    private func update(_ index: Int, _ change: @escaping (inout ChatTurn) -> Void) {
        DispatchQueue.main.async { change(&self.turns[index]) }
    }

    // Asks everyone at once and waits for all answers.
    private func askAll(_ team: [Account], round: Int, prompt: (Account) -> String, index: Int) -> [(Account, String)] {
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
                self.update(index) { $0.entries.append(entry) }
                group.leave()
            }
        }
        group.wait()
        // Keep the team's order (not the order they finished in).
        return team.compactMap { account in answers.first { $0.0.id == account.id } }
    }

    private func run(question: String, history: [(String, String)], team: [Account], usage: [String: AIUsage], index: Int) {
        let names = team.map(label).joined(separator: ", ")
        let context = history.isEmpty ? "" : "[이전 대화]\n" + history.map { "질문: \($0.0)\n최종 답: \($0.1)" }.joined(separator: "\n\n") + "\n\n"

        update(index) { $0.status = "1/3 각자 답하는 중… (\(names))" }
        let first = askAll(team, round: 1, prompt: { account in
            """
            당신은 \(self.label(account))입니다. 여러 AI(\(names))가 함께 사용자의 질문에 답하는 토론의 1단계입니다.
            다른 AI를 신경 쓰지 말고 당신의 가장 좋은 답을 한국어로 쓰세요. 파일을 만들거나 명령을 실행하지 마세요.

            \(context)[질문]
            \(question)
            """
        }, index: index)
        guard !first.isEmpty else { return finish(index, error: "모든 AI가 답하지 못했어요.") }

        var current = first
        if first.count > 1 {
            update(index) { $0.status = "2/3 서로 답을 검토하는 중…" }
            let answersText = first.map { "### \(label($0.0))의 답\n\($0.1)" }.joined(separator: "\n\n")
            let second = askAll(first.map(\.0), round: 2, prompt: { account in
                """
                당신은 \(self.label(account))입니다. 토론의 2단계입니다. 아래는 같은 질문에 대한 1단계 답들입니다(당신의 답 포함).
                다른 답에서 틀린 점, 빠진 점, 더 나은 점을 짧게 짚고, 그걸 반영해 고친 당신의 답을 한국어로 쓰세요.
                형식: "검토:" 다음에 짧은 검토, "고친 답:" 다음에 답. 인사나 칭찬 같은 의례적인 말은 쓰지 마세요.

                \(context)[질문]
                \(question)

                [1단계 답들]
                \(answersText)
                """
            }, index: index)
            if !second.isEmpty { current = second }
        }

        // The one with the most usage left writes the final answer.
        let writer = current.map(\.0).max { (usage[$0.id]?.leftNow ?? 50) < (usage[$1.id]?.leftNow ?? 50) }!
        if current.count == 1 {
            return finish(index, final: current[0].1, by: label(writer))
        }
        update(index) { $0.status = "3/3 \(self.label(writer))이(가) 최종 답을 정리하는 중…" }
        let finalPrompt = """
        당신은 \(label(writer))이고, 여러 AI의 토론을 정리하는 역할입니다. 아래는 각 AI가 서로 검토한 뒤 고친 답입니다.
        이를 종합해 사용자에게 줄 하나의 최종 답을 한국어로 쓰세요. 정확한 내용을 우선하고, 의견이 갈린 부분이 있으면 짧게 밝히세요.
        토론 과정이나 "AI들이 말하길" 같은 설명 없이 답만 쓰세요.

        \(context)[질문]
        \(question)

        [고친 답들]
        \(current.map { "### \(label($0.0))\n\($0.1)" }.joined(separator: "\n\n"))
        """
        switch Answerer.ask(writer, prompt: finalPrompt) {
        case .success(let text):
            finish(index, final: text, by: label(writer))
        case .failure:
            // Fall back to the writer's own improved answer.
            let own = current.first { $0.0.id == writer.id }!.1
            finish(index, final: own, by: label(writer) + " (정리 실패, 고친 답 그대로)")
        }
    }

    private func finish(_ index: Int, final: String? = nil, by: String? = nil, error: String? = nil) {
        DispatchQueue.main.async {
            self.turns[index].final = final
            self.turns[index].finalBy = by
            self.turns[index].error = error
            self.turns[index].status = ""
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
