import Foundation

// A project chat with two or more members decides per message how to answer, before anyone starts:
// one — the lead answers alone, the project read only (facts, checks, explanations, short follow-ups);
// all — every member answers at the same time, the project read only (views, design choices, ideas);
// work — the lead works and the others review its changes (Peer.swift).
// A model on this Mac may judge (Settings → Chat: off, the default, Gemma 4 E4B or Strands Decider; it
// answers only when downloaded). Without it, the checked member with the most usage left judges without tools. If
// nobody can judge, all: a wrong opinion changes no file, and several answers lose less than one. Fixed rules come
// first and last (plain agreement is one, "가자" after an offer is work, "수정하지 마" is never work), whoever judges.
// Missing work costs most (the user asked and nothing happened), so the work answer is told to change nothing when
// the message turns out not to ask for a change. Checked on 100 real messages: route-check in the project chat.
// Saved on the turn as `route` (opinion or work, as older builds read it) plus `routeOne` for one and `meetingRoom`
// for a meeting (Meeting.swift). The user can also pick the way before sending (the chip in the message box, or
// "/work " at the start of the message): that one message skips the sorter.
enum ChatRoute: String, Codable { case opinion, work }

enum RouteChoice: Hashable, CaseIterable {
    case work, one, all, meeting
    var route: ChatRoute { self == .work ? .work : .opinion }
    var title: String {
        switch self {
        case .one: return L("한 명", "One")
        case .all: return L("모두", "Everyone")
        case .work: return L("작업", "Work")
        case .meeting: return L("회의", "Meeting")
        }
    }
    var icon: String {
        switch self {
        case .work: return "hammer"
        case .one: return "bubble.left"
        case .all: return "bubble.left.and.bubble.right"
        case .meeting: return "person.3"
        }
    }
    // The ways a chat offers: a project chat all of them; a plain chat answers with all its members anyway and has no project to work on.
    static func offered(project: Bool) -> [RouteChoice] { project ? [.one, .all, .work, .meeting] : [.all, .meeting] }
}

extension ChatTurn {
    var routeChoice: RouteChoice? {
        if meetingRoom != nil { return .meeting }
        return route.map { $0 == .work ? .work : routeOne == true ? .one : .all }
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
        return text + "\n[Message to sort]\n" + marked(cut(question, message, head: message * 3 / 4, tail: message / 4))
    }

    // Quoted lines (">") marked as quotes.
    static func marked(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { $0.hasPrefix(">") ? "(quoted) " + $0.dropFirst().trimmingCharacters(in: .whitespaces) : $0 }
            .joined(separator: "\n")
    }

    static func prompt(question: String, history: [ChatTurn], busy: Bool = false) -> String {
        let forbid = forbidsChanges(question) ? "\nThe message forbids changes: reply ONE or ALL only.\n"
            : busy ? "\nAnother AI is changing this project now, so this message cannot be work: reply ONE or ALL only.\n" : ""
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

    // Asks the AIs to hold a meeting: "회의해줘", "미팅 좀 해봐", "다 같이 회의하자", "hold a meeting". Not the user's own
    // meetings ("미팅 노트 정리해줘", "오늘 회의했던 거", "회의록"); quoted lines are not orders.
    static let meetingAsk = try! NSRegularExpression(pattern:
        #"(회의|미팅|meeting)\s*(를|을|좀)?\s*(좀\s*)?(해\s*(줘|봐|주세요|보자|라)|하자|합시다|열어|진행해|시작해|ㄱㄱ)|\b(hold|have|run|start)\s+a\s+meeting"#,
        options: [.caseInsensitive])
    static func asksMeeting(_ question: String) -> Bool {
        found(meetingAsk, question.components(separatedBy: "\n").filter { !$0.hasPrefix(">") }.joined(separator: "\n"))
    }

    // Asks several AIs for their views in so many words: "2명 의견 들려줘", "셋이 각자 생각 말해봐", "다들 의견 줘",
    // "what do two of you think". Unlike asksViews this works in a plain chat too, so a bare "어떻게 생각해?" or
    // "다들 이렇게 하던데" (people, not the AIs) is not enough. Quoted lines are not orders.
    static let viewersAsk = try! NSRegularExpression(pattern:
        #"((두|세|네|[234])\s*(명|분)|(둘|셋|넷)(이서|이|\s)|여러\s*(명|분|AI)|다들|너희|각자|다\s*같이|모두\s*(의|들)?|\b(two|three|four|several|all|each)\s+(of\s+you|AIs?|models?))[^\n]{0,12}?(의견|생각|견해|답해|얘기해|말해|opinion|view|take|think)"#,
        options: [.caseInsensitive])
    // How many should answer: the number asked for, or as many as can come.
    static func askedViewers(_ question: String) -> Int? {
        let text = question.components(separatedBy: "\n").filter { !$0.hasPrefix(">") }.joined(separator: "\n")
        guard let match = viewersAsk.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let who = text[range].lowercased()
        for (n, words) in [(2, ["두", "2", "둘", "two"]), (3, ["세", "3", "셋", "three"]), (4, ["네", "4", "넷", "four"])]
            where words.contains(where: who.hasPrefix) { return n }
        return Discussion.meetingMost
    }

    // Asks for a Space, a small app (Space.swift): "이번 주 실험 트래커 만들어 줘", "단어 퀴즈 게임 만들자", "make a habit
    // tracker". Not "앱 만들어 줘" (in a project that is the project), "만들어진", "만들지 마", or quoted lines.
    static let spaceAsk = try! NSRegularExpression(pattern:
        #"(트래커|보드|대시보드|게임|체크리스트|퀴즈|타이머|계산기|위젯|칸반|미니\s*앱|스페이스|space)[^\n]{0,12}?만들(어(?!진|져|지|서|도)|자|래|어\s*줘|어\s*주)|\b(make|build|create)\b[^\n]{0,40}?\b(tracker|dashboard|board|game|checklist|quiz|timer|widget|kanban|mini[- ]?app|space)\b"#,
        options: [.caseInsensitive])
    static func asksSpace(_ question: String) -> Bool {
        found(spaceAsk, question.components(separatedBy: "\n").filter { !$0.hasPrefix(">") }.joined(separator: "\n"))
    }

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
        if found(agreement, key) || asksSpace(question) || !SpaceStore.named(in: question).isEmpty { return .one }
        if !forbidsChanges(question), go.contains(key), let answer = previous?.final, found(offer, String(answer.suffix(400))) { return .work }
        return nil
    }

    // After the judge: never work when the message says not to change anything; asked for views, everyone answers.
    // While another chat or TODO is changing the project: the way that answers without writing (views → all, else one).
    static func withoutWork(_ route: RouteChoice, question: String) -> RouteChoice {
        route != .work ? route : found(asksViews, question) ? .all : .one
    }

    static func adjust(_ route: RouteChoice, question: String) -> RouteChoice {
        if route == .work && forbidsChanges(question) { return .one }
        if route == .one && found(asksViews, question) { return .all }
        return route
    }

    // "/work " (or /one, /all, /meet, their short forms and the Korean words) at the start of a message picks the way
    // for it; the rest is the message. Only before a space or a line break, so a path like "/Users/…" stays text; only
    // the ways `offered`. The first word of each is the one shown in menus.
    static let commands: [(choice: RouteChoice, words: [String])] = [
        (.one, ["one", "1", "한명"]), (.all, ["all", "a", "opinion", "모두"]),
        (.work, ["work", "w", "작업"]), (.meeting, ["meet", "m", "meeting", "회의"])]
    static let slashes: [String: RouteChoice] = Dictionary(uniqueKeysWithValues: commands.flatMap { c in c.words.map { ($0, c.choice) } })
    static func words(_ choice: RouteChoice) -> [String] { commands.first { $0.choice == choice }?.words ?? [] }

    // While the first word of the message is being typed after "/": the ways it may become (all of them for a bare "/"),
    // with where the "/" is. nil when the message does not start that way or nothing matches ("/Users…").
    static func slashMenu(_ text: String, cursor: Int, offered: [RouteChoice]) -> (location: Int, query: String, choices: [RouteChoice])? {
        let chars = Array(text.utf16)
        var start = 0
        while start < chars.count && chars[start] == 32 { start += 1 }
        guard start < chars.count, chars[start] == 47, cursor > start, cursor <= chars.count else { return nil }   // "/"
        let query = String(decoding: chars[(start + 1)..<cursor], as: UTF16.self)
        guard !query.contains(where: \.isWhitespace) else { return nil }
        // The cursor inside a word already typed ("/w|ork"): no list, so picking never leaves the rest of it behind.
        if cursor < chars.count, let next = UnicodeScalar(chars[cursor]), !CharacterSet.whitespacesAndNewlines.contains(next) { return nil }
        let key = query.lowercased()
        let choices = offered.filter { choice in words(choice).contains { $0.hasPrefix(key) } }
        return choices.isEmpty ? nil : (start, query, choices)
    }

    static func hint(_ choice: RouteChoice) -> String {
        switch choice {
        case .one: return L("한 AI만 답해요", "One AI answers")
        case .all: return L("모두 의견을 말해요", "Everyone gives a view")
        case .work: return L("프로젝트를 고쳐요", "Changes the project")
        case .meeting: return L("회의를 열어요", "Holds a meeting")
        }
    }
    static func slash(_ text: String, offered: [RouteChoice]) -> (route: RouteChoice, rest: String)? {
        let trimmed = text.drop { $0 == " " }
        guard trimmed.hasPrefix("/"), let end = trimmed.firstIndex(where: \.isWhitespace) else { return nil }
        let word = trimmed[trimmed.index(after: trimmed.startIndex)..<end].lowercased()
        guard let route = slashes[word], offered.contains(route) else { return nil }
        return (route, String(trimmed[end...]).trimmingCharacters(in: .whitespacesAndNewlines))
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

    static func opinionNote(project: String, alone: Bool = false, busy: Bool = false) -> String {
        let who = alone ? "one answer is enough: you answer it alone, other members stay quiet unless the user asks them,"
            : "every member answers it at the same time,"
        if project.isEmpty {
            return """
            [Opinion mode] The user asked for several views on this message: \(who) so give your own view and do not wait
            for the others. Your folders are read only for this answer, except the chat folder.
            """
        }
        return """
        [Opinion mode] This chat is linked to the project at \(project), and the app judged that this message asks
        for views, not changes: \(who) and the project is read only for this answer.
        Read the files as needed and answer about them. Do not try to edit files or run Git writes; if the user seems to
        want changes, say what you would change — they can say "가자" (go) or press "Run as work" to have it done.
        """ + (busy ? """

        Another chat or TODO is changing this project right now, so this message could not be work. If it asks for
        changes, say so briefly and help without editing; the user can ask again for the work when the other one finishes.
        """ : "")
    }
}

// Which model on this Mac sorts messages (Settings → Chat). Off by default: not every Mac can run a local model,
// so a member AI judges.
enum RouteSorter: String, CaseIterable {
    case off, gemma, decider
    static var current: RouteSorter { UserDefaults.app.string(forKey: "routeSorter").flatMap(RouteSorter.init) ?? .off }
    var variant: LocalModel.Variant? {
        switch self {
        case .off: return nil
        case .gemma: return LocalModel.legacy[0]
        case .decider: return LocalModel.Variant(id: "ollama:strands-decider:latest", model: "strands-decider:latest", title: "Strands Decider")
        }
    }
    var title: String { variant?.title ?? L("안 씀", "Off") }
    // The Ollama that has the decision API (/v1/systemone); https://ollama.com/library/strands-decider
    var minimumOllama: String? { self == .decider ? "0.40.0" : nil }
    var downloadGB: Double {
        guard let variant else { return 0 }
        return LocalModel.catalog.first { LocalModel.same($0.name, variant.model) }?.sizeGB ?? (self == .decider ? 1.98 : 6.58)
    }

    // Whether the chosen model can sort now, and what to do if not (the line under the menu in Settings → Chat).
    enum State: Equatable {
        case off, checking, ready, missing, downloading(String, Double?), failed(String)
        case noOllama, ollamaOff, outdated(String), localOff
    }
    // `installed` nil: Ollama did not answer; `checked` false: not asked yet.
    func state(checked: Bool, hasBinary: Bool, enabled: Bool, installed: [String]?, version: String?,
               pull: (String, Double?)?, failure: String?) -> State {
        guard let variant else { return .off }
        if let pull { return .downloading(pull.0, pull.1) }
        guard checked else { return .checking }
        guard let installed else { return hasBinary ? .ollamaOff : .noOllama }
        if let minimumOllama, let version, !LocalModel.atLeast(version, minimumOllama) { return .outdated(version) }
        guard LocalModel.hasModel(installed, variant) else { return failure.map(State.failed) ?? .missing }
        return enabled ? .ready : .localOff
    }
    var summary: String {
        switch self {
        case .off: return L("기본 · 참여한 Claude나 ChatGPT 중 사용량이 더 남은 쪽이 판정해요", "Default · the member Claude or ChatGPT with more usage left judges")
        case .gemma: return L("100문제 중 91개 맞힘 · 메모리 많이 씀", "91 of 100 right · more memory")
        case .decider: return L("가벼움 · 빠름 · 169문제 중 140개 · 시키지 않은 작업이 조금 더 많아요", "Light · fast · 140 of 169 · a few more needless work runs")
        }
    }
}

extension LocalModel {
    // The chosen sorter's answer for one message, or nil: local models off, Ollama not running (it is not started for
    // this), the model not downloaded, another chat using the local model, or no clear reply within `timeout`.
    // A model that was not in memory leaves it right after (keep_alive 0); one already loaded keeps its time.
    static func judge(question: String, history: [ChatTurn], sorter: RouteSorter = .current, busy: Bool = false, timeout: TimeInterval = Route.localTimeout) -> RouteChoice? {
        guard let variant = sorter.variant, enabled, let names = installedModels(timeout: 1.5), hasModel(names, variant) else { return nil }
        guard gate.wait(timeout: .now() + 0.5) == .success else { return nil }
        defer { gate.signal() }
        let loaded = loadedModels()
        let warm = loaded.contains { matches($0.name, variant.model) }
        if loaded.contains(where: { !matches($0.name, variant.model) }) { unload(except: variant.model) }
        let keep: Any = warm ? "\(max(keepAlive, 1))m" : 0
        switch sorter {
        case .off:
            return nil
        case .gemma:
            // 8K: the message (up to 4,000 characters) and the last answer (3,000) fit; Ollama's default 4K does not.
            let body: [String: Any] = ["model": variant.model, "stream": false, "think": false, "keep_alive": keep,
                                       "messages": [["role": "user", "content": Route.prompt(question: question, history: history, busy: busy)]],
                                       "options": ["num_predict": 8, "temperature": 0, "num_ctx": 8192]]
            let json = post("api/chat", body, timeout: timeout)
            return ((json?["message"] as? [String: Any])?["content"] as? String).flatMap(Route.parse)
        case .decider:
            // A decision model answers yes/no questions with a probability (https://docs.ollama.com/capabilities/decision).
            // The message alone: with earlier messages and the last answer it mixed in the AI's own "수정할게요".
            // Korean questions with what true and false mean; examples in the work question made it worse.
            // On 169 messages: 140 right, 4 missed work, 17 needless work (route-check in the project chat).
            let questions: [String: Any] = [
                "work": ["type": "noul", "instructions": "사용자가 AI에게 말로 답하는 것 말고 지금 작업을 하라고 시키나요?",
                         "criteria": ["true": "사용자가 AI에게 지금 무언가를 실행하라고 시켜요: 수정, 구현, 빌드, 실행, 테스트, 돌려서 비교, 커밋, 배포.",
                                      "false": "사용자는 말로 된 답만 원해요: 설명, 의견, 정리, 계획, 상태 확인, 감사, 동의."]],
                "all": ["type": "noul", "instructions": "사용자가 AI들의 의견을 묻나요?",
                        "criteria": ["true": "의견, 어느 쪽이 나은지, 찬반, 동의하는지를 물어요. 예: 어떻게 생각해?, 어때?, 뭐가 나아?",
                                     "false": "작업, 사실, 설명, 정리를 원하거나 그냥 반응해요."]],
            ]
            let body: [String: Any] = ["model": variant.model, "keep_alive": keep, "questions": questions,
                                       "state": Route.marked(Route.cut(question, 2500, head: 1800, tail: 700))]
            guard let answers = post("v1/systemone", body, timeout: timeout)?["answers"] as? [String: Any],
                  let work = (answers["work"] as? [String: Any])?["noul"] as? Double,
                  let all = (answers["all"] as? [String: Any])?["noul"] as? Double else { return nil }
            // Work above 0.85 would miss 9 instead of 4: missing work costs most.
            return work > 0.75 && !busy ? .work : all > 0.70 ? .all : .one
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
    // busy: another chat or TODO is changing the project, so the judge picks between one and all only.
    func decideRoute(question: String, history: [ChatTurn], judges: [Account], busy: Bool = false, cancellation: DebateCancellation) -> (route: RouteChoice, by: String?) {
        if let route = Route.rule(question: question, previous: history.last) { return (busy ? Route.withoutWork(route, question: question) : route, L("규칙", "rule")) }
        let prompt = Route.prompt(question: question, history: history, busy: busy)
        let (route, by): (RouteChoice, String?)
        if let routeJudge { (route, by) = routeJudge(prompt) } else {
            let judge = AutoPick.choose(judges, usage: model.latestUsage, lock: lock(of: currentID), current: nil)
            let sorter = RouteSorter.current
            (route, by) = Route.decide(local: { LocalModel.judge(question: question, history: history, sorter: sorter, busy: busy) }, localName: sorter.title, judge: judge, ask: { account in
                if cancellation.isCancelled { return nil }
                guard self.permits(account, room: self.currentID) else { return nil }
                // No workspace and no web: the judge has no tools at all.
                guard case .success(let text) = Answerer.ask(account, prompt: prompt, timeout: Route.memberTimeout, cancellation: cancellation) else { return nil }
                return text
            }, label: label)
        }
        let adjusted = by == nil ? route : Route.adjust(route, question: question)
        return (busy ? Route.withoutWork(adjusted, question: question) : adjusted, by)
    }

    static func routeNote(_ route: RouteChoice, by: String?, names: [String], reviewers: [String] = [], forced: Bool = false, busy: Bool = false) -> String {
        let judged = forced ? L("직접 고름", "picked by you") : by.map { L("\($0) 판정", "judged by \($0)") } ?? L("판정 못 함 → 의견", "could not judge → opinion")
        let how = busy ? judged + L(" · 다른 AI가 작업 중이라 작업은 빼고", " · another AI is working, so no work") : judged
        switch route {
        case .one:
            return L("의견 · ", "Opinion · ") + (names.first.map { L("\($0) 혼자", "\($0) alone") } ?? L("한 명", "one AI")) + " · " + how
        case .all:
            return L("의견 · \(names.count)명", "Opinion · \(names.count) AIs") + " · " + how
        case .work:
            let who = names.first.map { L("\($0) 작업", "\($0) works") } ?? L("작업", "Work")
            let check = reviewers.isEmpty ? "" : ", " + L("\(reviewers.joined(separator: ", ")) 검수", "\(reviewers.joined(separator: ", ")) reviews")
            return L("작업 · ", "Work · ") + who + check + " · " + how
        case .meeting:
            return L("회의 · ", "Meeting · ") + names.joined(separator: ", ") + " · " + how
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
