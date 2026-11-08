import Foundation

// A project chat with two or more members decides per message how to answer, before anyone starts:
// one — the lead answers alone, the project read only (facts, checks, explanations, short follow-ups);
// all — every member answers at the same time, the project read only (views, design choices, ideas);
// work — the lead works and the others review its changes (Peer.swift).
// A model on this Mac judges (Settings → Accounts → Ollama: Gemma 4 E4B, the default, or Strands Decider; it
// answers only when downloaded). Without it, the checked member with the most usage left judges without tools. If
// nobody can judge, all: a wrong opinion changes no file, and several answers lose less than one. Fixed rules come
// first and last (plain agreement is one, "가자" after an offer is work, "수정하지 마" is never work), whoever judges.
// Missing work costs most (the user asked and nothing happened), so the work answer is told to change nothing when
// the message turns out not to ask for a change. Checked on 100 real messages: route-check in the project chat.
// Saved on the turn as `route` (opinion or work, as older builds read it) plus `routeOne` for one.
enum ChatRoute: String, Codable { case opinion, work }

enum RouteChoice: Equatable {
    case work, one, all
    var route: ChatRoute { self == .work ? .work : .opinion }
}

extension ChatTurn {
    var routeChoice: RouteChoice? {
        route.map { $0 == .work ? .work : routeOne == true ? .one : .all }
    }
}

enum Route {
    static let localTimeout: TimeInterval = 10   // Gemma: "a few seconds", cold start included
    static let memberTimeout: TimeInterval = 60

    static let instructions = """
        You sort one chat message in a coding project chat with several AIs. Reply with exactly one word: WORK, ONE or ALL.
        Decide in this order and stop at the first that fits:
        1. WORK — the user tells the AI to change the project now (edit, fix, implement, build, test, commit, push, deploy),
           or approves a concrete change the last answer offered to make ("가자", "수정 ㄱㄱ", "문제 없으면 다 하자", "그걸로 하자").
           Not WORK: asking for text in the chat (정리해줘, 설명해줘, 보여줘, 알려줘, 조사해봐, 찾아봐), even with 해줘;
           plain agreement or praise ("좋네", "ㅇㅋ", "다 된듯?", "드디어 됐네"); telling what someone else is doing;
           deciding to wait or leave it ("그냥 기다리자", "놔두자"); asking whether something is possible or hard;
           describing how a feature should work while a plan is still being made; approving a plan for a plan.
           Lines marked (quoted) are old text the user is quoting, not orders.
        2. ALL — the user asks for views where different AIs would answer differently: what they think of an idea or plan,
           which option is better, pros and cons, agreement ("어떻게 생각해?", "어느 쪽이 나아?", "동의함?", "~하는 게 나으려나?", "다들").
        3. ONE — everything else: facts, explanations, summaries ("정리해봐"), plans ("계획 세워보자", even "어떻게 하는 게 좋을까? 계획만 세워보자"), investigations,
           research, reading code, status, short follow-ups, thanks.
        If unsure, ONE.
        Examples: "좋네" ONE · "ㅇㅋ 이제 다 된듯?" ONE · "계획만 세워보자" ONE · "다시 정리해보자" ONE · "좋아 그렇게 정리해줘" ONE · "표로 보여줘" ONE · "고마워" ONE ·
        "어느 쪽이 나아?" ALL · "이거 추가하는 거 어떻게 생각해?" ALL · "이 버그 고쳐줘" WORK · "push 해봐" WORK.
        """

    // The start and the end of a long text: an answer's offer ("가자라고 하시면…") is at its end.
    static func cut(_ text: String, _ limit: Int, head: Int, tail: Int) -> String {
        text.count <= limit ? text : String(text.prefix(head)) + "\n…\n" + String(text.suffix(tail))
    }

    // The message with the two user messages before it and the last answer; quoted lines (">") are marked as quotes.
    static func context(question: String, history: [ChatTurn], answer: Int = 3000, message: Int = 4000) -> String {
        var text = ""
        let earlier = history.suffix(2).map(\.question)
        if !earlier.isEmpty {
            text += "[Earlier user messages, oldest first]\n" + earlier.map { "- " + cut($0, 500, head: 300, tail: 200) }.joined(separator: "\n") + "\n"
        }
        if let last = history.last?.final, !last.isEmpty {
            text += "[Last answer]\n" + cut(last, answer, head: answer / 3, tail: answer - answer / 3) + "\n"
        }
        let lines = cut(question, message, head: message * 3 / 4, tail: message / 4).components(separatedBy: "\n")
        let marked = lines.map { $0.hasPrefix(">") ? "(quoted) " + $0.dropFirst().trimmingCharacters(in: .whitespaces) : $0 }
        return text + "\n[Message to sort]\n" + marked.joined(separator: "\n")
    }

    static func prompt(question: String, history: [ChatTurn]) -> String {
        let forbid = forbidsChanges(question) ? "\nThe message forbids changes: reply ONE or ALL only.\n" : ""
        return instructions + "\n" + forbid + "\n" + context(question: question, history: history)
    }

    // MARK: Fixed rules, the same for every judge

    static let noChanges = try! NSRegularExpression(pattern:
        #"수정\s*(은|을|는)?\s*하지\s*말|수정하지\s*말|읽어만|확인만|계획만|의견만|건드리지\s*말|고치지\s*말|손대지\s*말|코드\s*건들지\s*마|뭘\s*하지는\s*말"#)
    static let asksViews = try! NSRegularExpression(pattern:
        #"어떻게\s*생각|동의\s*(해|함|하)|의견\s*(줘|ㄱㄱ|좀|주)|어느\s*쪽|뭐가\s*(더\s*)?나아|나으려나|좋으려나|다들"#)
    static let agreement = try! NSRegularExpression(pattern:
        #"^(좋[네아다요]*|ㅇㅋ|오케이|ok|굿|ㄳ|고마워|감사)+(이제)?(다된듯|된듯|됐네)?\??$"#)
    static let offer = try! NSRegularExpression(pattern:
        #"(가자|ㄱㄱ|진행|해 ?줘|해 ?봐)["'”’」]?\s*(라고|하시면|해 주세요)|(고칠|구현할|수정할|바꿀|올릴|배포할|진행할|시작할|넣을)게요"#)
    static let go: Set<String> = ["가자", "ㄱㄱ", "고고", "해줘", "해봐", "진행해", "그걸로하자", "그렇게하자", "그거로하자", "goahead", "go"]

    static func found(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    static func forbidsChanges(_ question: String) -> Bool { found(noChanges, question) }
    // The message without spaces, punctuation and trailing ㅇ, lowercased: "ㅇㅋ 좋아!" → "ㅋ좋아".
    static func key(_ question: String) -> String {
        question.lowercased().filter { !($0.isWhitespace || ".!,~ㅇ".contains($0)) }
    }

    // Decided without a judge: plain agreement, or a bare "가자" right after an answer that offered a change.
    static func rule(question: String, previous: ChatTurn?) -> RouteChoice? {
        let key = key(question)
        if found(agreement, key) { return .one }
        if !forbidsChanges(question), go.contains(key), let answer = previous?.final, found(offer, String(answer.suffix(400))) { return .work }
        return nil
    }

    // After the judge: never work when the message says not to change anything; asked for views, everyone answers.
    static func adjust(_ route: RouteChoice, question: String) -> RouteChoice {
        if route == .work && forbidsChanges(question) { return .one }
        if route == .one && found(asksViews, question) { return .all }
        return route
    }

    // WORK, ONE or ALL in the reply (OPINION, the older word, is ALL); nil when it says none or more than one.
    static func parse(_ text: String) -> RouteChoice? {
        let words = Set(text.uppercased().split { !$0.isLetter }.map(String.init))
        let found = Set(words.compactMap { word -> RouteChoice? in
            switch word {
            case "WORK": return .work
            case "ONE": return .one
            case "ALL", "OPINION": return .all
            default: return nil
            }
        })
        return found.count == 1 ? found.first : nil
    }

    // The model on this Mac first, then the member with the most usage left; the name of whoever judged (nil: nobody could).
    static func decide(local: () -> RouteChoice?, localName: String, judge: Account?, ask: (Account) -> String?, label: (Account) -> String)
        -> (route: RouteChoice, by: String?) {
        if let route = local() { return (route, localName) }
        if let judge, let reply = ask(judge), let route = parse(reply) { return (route, label(judge)) }
        return (.all, nil)
    }

    static func workNote() -> String {
        """
        [Work mode] The app judged that this message asks you to change the project, so you may edit it now. The app can be
        wrong: if the message only asks for an explanation, a plan, a summary or your view, answer it and change nothing.
        """
    }

    // What the members see in opinion mode: every folder read only except the chat's own, no project tools.
    static func opinionView(_ binding: WorkspaceBinding, chatFolder: String) -> WorkspaceBinding {
        var view = binding
        view.project = nil; view.projectRunID = nil; view.projectGeneration = nil
        view.level = .view; view.fullAccess = nil
        view.roots = binding.roots.map { WorkspaceRoot(path: $0.path, directory: $0.directory, writable: $0.path == chatFolder ? true : nil) }
        return view
    }

    static func opinionNote(project: String, alone: Bool = false) -> String {
        let who = alone ? "one answer is enough: you answer it alone, other members stay quiet unless the user asks them,"
            : "every member answers it at the same time,"
        return """
        [Opinion mode] This chat is linked to the Git project at \(project), and the app judged that this message asks
        for views, not changes: \(who) and the project is read only for this answer.
        Read code as needed and answer about the code. Do not try to edit files or run Git writes; if the user seems to
        want changes, say what you would change — they can say "가자" (go) or press "Run as work" to have it done.
        """
    }
}

// Which model on this Mac sorts messages (Settings → Accounts → Ollama).
enum RouteSorter: String, CaseIterable {
    case gemma, decider
    static var current: RouteSorter { UserDefaults.app.string(forKey: "routeSorter").flatMap(RouteSorter.init) ?? .gemma }
    var variant: LocalModel.Variant {
        self == .gemma ? LocalModel.legacy[0] : LocalModel.Variant(id: "ollama:strands-decider:latest", model: "strands-decider:latest", title: "Strands Decider")
    }
    var title: String { variant.title }
    var summary: String {
        self == .gemma ? L("기본 · 100문제 중 91개 맞힘 · 메모리 많이 씀", "Default · 91 of 100 right · more memory")
            : L("가벼움 · 100문제 중 67개 · 한국어 작업 지시를 자주 놓쳐요", "Light · 67 of 100 · often misses Korean work requests")
    }
}

extension LocalModel {
    // The chosen sorter's answer for one message, or nil: local models off, Ollama not running (it is not started for
    // this), the model not downloaded, another chat using the local model, or no clear reply within `timeout`.
    // A model that was not in memory leaves it right after (keep_alive 0); one already loaded keeps its time.
    static func judge(question: String, history: [ChatTurn], sorter: RouteSorter = .current, timeout: TimeInterval = Route.localTimeout) -> RouteChoice? {
        let variant = sorter.variant
        guard enabled, let names = installedModels(timeout: 1.5), hasModel(names, variant) else { return nil }
        guard gate.wait(timeout: .now() + 0.5) == .success else { return nil }
        defer { gate.signal() }
        let loaded = loadedModels()
        let warm = loaded.contains { matches($0.name, variant.model) }
        if loaded.contains(where: { !matches($0.name, variant.model) }) { unload(except: variant.model) }
        let keep: Any = warm ? "\(max(keepAlive, 1))m" : 0
        switch sorter {
        case .gemma:
            // 8K: the message (up to 4,000 characters) and the last answer (3,000) fit; Ollama's default 4K does not.
            let body: [String: Any] = ["model": variant.model, "stream": false, "think": false, "keep_alive": keep,
                                       "messages": [["role": "user", "content": Route.prompt(question: question, history: history)]],
                                       "options": ["num_predict": 8, "temperature": 0, "num_ctx": 8192]]
            let json = post("api/chat", body, timeout: timeout)
            return ((json?["message"] as? [String: Any])?["content"] as? String).flatMap(Route.parse)
        case .decider:
            // A decision model answers yes/no questions with a probability (https://docs.ollama.com/capabilities/decision).
            // Two Korean questions and these thresholds scored best on the tuning messages.
            let questions = [
                "work": "사용자가 마지막 메시지에서 AI에게 지금 프로젝트 코드를 고치거나 만들거나 배포하라고 시키나요? 설명·정리·계획·조사 요청은 아니에요.",
                "all": "사용자가 마지막 메시지에서 여러 AI의 의견, 어느 쪽이 나은지, 찬반을 묻나요?",
            ].mapValues { ["type": "noul", "instructions": $0] }
            let body: [String: Any] = ["model": variant.model, "keep_alive": keep, "questions": questions,
                                       "state": Route.context(question: question, history: history, answer: 1500, message: 2500)]
            guard let answers = post("v1/systemone", body, timeout: timeout)?["answers"] as? [String: Any],
                  let work = (answers["work"] as? [String: Any])?["noul"] as? Double,
                  let all = (answers["all"] as? [String: Any])?["noul"] as? Double else { return nil }
            return work > 0.30 ? .work : all > 0.35 ? .all : .one
        }
    }

    private static func post(_ path: String, _ body: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        var request = URLRequest(url: server.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let done = DispatchSemaphore(value: 0)
        var reply: [String: Any]?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data else { return }
            reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        task.resume()
        if done.wait(timeout: .now() + timeout) == .timedOut { task.cancel(); return nil }
        return reply
    }
}

extension Discussion {
    // The app's own sorter for one message (tests replace the judge with `routeJudge`; the fixed rules still apply).
    func decideRoute(question: String, history: [ChatTurn], judges: [Account], cancellation: DebateCancellation) -> (route: RouteChoice, by: String?) {
        if let route = Route.rule(question: question, previous: history.last) { return (route, L("규칙", "rule")) }
        let prompt = Route.prompt(question: question, history: history)
        let (route, by): (RouteChoice, String?)
        if let routeJudge { (route, by) = routeJudge(prompt) } else {
            let judge = AutoPick.choose(judges, usage: model.latestUsage, school: nil, current: nil)
            let sorter = RouteSorter.current
            (route, by) = Route.decide(local: { LocalModel.judge(question: question, history: history, sorter: sorter) }, localName: sorter.title, judge: judge, ask: { account in
                if cancellation.isCancelled { return nil }
                // No workspace and no web: the judge has no tools at all.
                guard case .success(let text) = Answerer.ask(account, prompt: prompt, timeout: Route.memberTimeout, cancellation: cancellation) else { return nil }
                return text
            }, label: label)
        }
        return (by == nil ? route : Route.adjust(route, question: question), by)
    }

    static func routeNote(_ route: RouteChoice, by: String?, names: [String], reviewers: [String] = [], forced: Bool = false) -> String {
        let how = forced ? L("직접 고름", "picked by you") : by.map { L("\($0) 판정", "judged by \($0)") } ?? L("판정 못 함 → 의견", "could not judge → opinion")
        switch route {
        case .one:
            return L("의견 · ", "Opinion · ") + (names.first.map { L("\($0) 혼자", "\($0) alone") } ?? L("한 명", "one AI")) + " · " + how
        case .all:
            return L("의견 · \(names.count)명", "Opinion · \(names.count) AIs") + " · " + how
        case .work:
            let who = names.first.map { L("\($0) 작업", "\($0) works") } ?? L("작업", "Work")
            let check = reviewers.isEmpty ? "" : ", " + L("\(reviewers.joined(separator: ", ")) 검수", "\(reviewers.joined(separator: ", ")) reviews")
            return L("작업 · ", "Work · ") + who + check + " · " + how
        }
    }

    // Sends the last message again in another mode, as a new turn, with its pictures. Files the first run changed stay changed.
    func rerun(_ turn: ChatTurn, as route: RouteChoice) {
        guard !anyRunning, current.turns.last?.id == turn.id else { return }
        // What the user is writing now (text, @ names, attached pictures) stays in the message box.
        let saved = draft, savedMentions = draftMentions, savedImages = pendingImages
        draft = turn.question; draftMentions = []; pendingImages = turn.images ?? []
        forcedRoute = route
        send()
        forcedRoute = nil
        draft = saved; draftMentions = savedMentions; pendingImages = savedImages
    }
}
