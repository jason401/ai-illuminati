import Foundation

// A project chat with two or more members decides per message how to answer, before anyone starts:
// opinion — every member answers at the same time and the project is read only;
// work — the lead works and the others review its changes (Peer.swift).
// Gemma 4 E4B on this Mac judges (checked or not; it answers only when checked). Without it, the checked member
// with the most usage left judges without tools. If nobody can judge, opinion: a wrong opinion changes no file.
enum ChatRoute: String, Codable { case opinion, work }

enum Route {
    static let localTimeout: TimeInterval = 10   // Gemma: "a few seconds", cold start included
    static let memberTimeout: TimeInterval = 60

    static func prompt(question: String, previous: ChatTurn?) -> String {
        var earlier = ""
        if let previous {
            earlier = "[Previous user message]\n" + String(previous.question.prefix(600))
            if let answer = previous.final { earlier += "\n[Previous answer]\n" + String(answer.prefix(600)) }
            earlier += "\n\n"
        }
        return """
            You sort chat messages for a coding project chat. Reply with exactly one word: OPINION or WORK.
            WORK: the user wants the project changed now — edit code or files, fix, implement, build, test, commit, push,
            or approves doing what was just discussed ("가자", "그걸로 하자", "해줘", "go ahead").
            OPINION: anything else — questions, explanations, reviews or reading without changes, ideas, "is it possible?",
            "what do you think?", checks and thanks ("다 된듯?", "됐어?", "좋아 고마워"), and every message that says not to
            change anything ("수정하지 말고", "읽어만 봐", "의견만").
            Judge by meaning, not by words: "구현 가능할까?" is OPINION; "이 버그 고쳐줘" is WORK. If unsure, OPINION.

            \(earlier)[Message to sort]
            \(String(question.prefix(2000)))
            """
    }

    // OPINION or WORK in the reply; nil when it says neither or both.
    static func parse(_ text: String) -> ChatRoute? {
        let upper = text.uppercased()
        let opinion = upper.contains("OPINION"), work = upper.contains("WORK")
        return opinion == work ? nil : opinion ? .opinion : .work
    }

    // Gemma first, then the member with the most usage left; the name of whoever judged (nil: nobody could).
    static func decide(local: () -> String?, localName: String, judge: Account?, ask: (Account) -> String?, label: (Account) -> String)
        -> (route: ChatRoute, by: String?) {
        if let reply = local(), let route = parse(reply) { return (route, localName) }
        if let judge, let reply = ask(judge), let route = parse(reply) { return (route, label(judge)) }
        return (.opinion, nil)
    }

    // What the members see in opinion mode: every folder read only except the chat's own, no project tools.
    static func opinionView(_ binding: WorkspaceBinding, chatFolder: String) -> WorkspaceBinding {
        var view = binding
        view.project = nil; view.projectRunID = nil; view.projectGeneration = nil
        view.level = .view; view.fullAccess = nil
        view.roots = binding.roots.map { WorkspaceRoot(path: $0.path, directory: $0.directory, writable: $0.path == chatFolder ? true : nil) }
        return view
    }

    static func opinionNote(project: String) -> String {
        """
        [Opinion mode] This chat is linked to the Git project at \(project), and the app judged that this message asks
        for views, not changes: every member answers it at the same time and the project is read only for this answer.
        Read code as needed and answer about the code. Do not try to edit files or run Git writes; if the user seems to
        want changes, say what you would change — they can say "가자" (go) or press "Run as work" to have it done.
        """
    }
}

extension LocalModel {
    // One short reply from Gemma 4 E4B for the message sorter, or nil: local models off, Ollama not running (it is
    // not started for this), E4B not downloaded, another chat using the local model, or no reply within `timeout`.
    // A Gemma that was not in memory leaves it right after (keep_alive 0); one already loaded keeps its time.
    static func judge(_ prompt: String, timeout: TimeInterval = Route.localTimeout) -> String? {
        let variant = legacy[0]
        guard enabled, let names = installedModels(timeout: 1.5), hasModel(names, variant) else { return nil }
        guard gate.wait(timeout: .now() + 0.5) == .success else { return nil }
        defer { gate.signal() }
        let loaded = loadedModels()
        let warm = loaded.contains { matches($0.name, variant.model) }
        if loaded.contains(where: { !matches($0.name, variant.model) }) { unload(except: variant.model) }
        let body: [String: Any] = ["model": variant.model, "messages": [["role": "user", "content": prompt]], "stream": false, "think": false,
                                   "options": ["num_predict": 8, "temperature": 0], "keep_alive": warm ? "\(max(keepAlive, 1))m" as Any : 0 as Any]
        var request = URLRequest(url: server.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let done = DispatchSemaphore(value: 0)
        var reply: String?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            reply = (json["message"] as? [String: Any])?["content"] as? String
        }
        task.resume()
        if done.wait(timeout: .now() + timeout) == .timedOut { task.cancel(); return nil }
        return reply
    }
}

extension Discussion {
    // The app's own sorter for one message (tests replace it with `routeJudge`).
    func decideRoute(question: String, previous: ChatTurn?, judges: [Account], cancellation: DebateCancellation) -> (route: ChatRoute, by: String?) {
        let prompt = Route.prompt(question: question, previous: previous)
        if let routeJudge { return routeJudge(prompt) }
        let judge = AutoPick.choose(judges, usage: model.latestUsage, school: nil, current: nil)
        return Route.decide(local: { LocalModel.judge(prompt) }, localName: LocalModel.legacy[0].title, judge: judge, ask: { account in
            if cancellation.isCancelled { return nil }
            // No workspace and no web: the judge has no tools at all.
            guard case .success(let text) = Answerer.ask(account, prompt: prompt, timeout: Route.memberTimeout, cancellation: cancellation) else { return nil }
            return text
        }, label: label)
    }

    static func routeNote(_ route: ChatRoute, by: String?, names: [String], reviewers: [String] = [], forced: Bool = false) -> String {
        let how = forced ? L("직접 고름", "picked by you") : by.map { L("\($0) 판정", "judged by \($0)") } ?? L("판정 못 함 → 의견", "could not judge → opinion")
        switch route {
        case .opinion:
            return L("의견 · \(names.count)명", "Opinion · \(names.count) AIs") + " · " + how
        case .work:
            let who = names.first.map { L("\($0) 작업", "\($0) works") } ?? L("작업", "Work")
            let check = reviewers.isEmpty ? "" : ", " + L("\(reviewers.joined(separator: ", ")) 검수", "\(reviewers.joined(separator: ", ")) reviews")
            return L("작업 · ", "Work · ") + who + check + " · " + how
        }
    }

    // Sends the last message again in the other mode, as a new turn. Files the first run changed stay changed.
    func rerun(_ turn: ChatTurn, as route: ChatRoute) {
        guard !anyRunning, current.turns.last?.id == turn.id else { return }
        let saved = draft, savedMentions = draftMentions
        draft = turn.question; draftMentions = []
        forcedRoute = route
        send()
        forcedRoute = nil
        draft = saved; draftMentions = savedMentions
    }
}
