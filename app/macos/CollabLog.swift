import Foundation

// AI-to-AI collaboration: the setting (Settings → Chat) and a local log of calls for tuning the budgets and rules
// later. The log keeps who asked whom, why (the purpose, never the message), how it went and what the asking AI says
// it took; no message or reply text.
enum CollabMode: String, CaseIterable {
    case off, notify, auto
    // off: only the work path's ask_peer (project chat with reviewers), as before ask_ai. notify: cards under the
    // answer, no confirmation. auto: the same calls, the cards folded into one line.
    var title: String {
        switch self {
        case .off: return L("끔", "Off")
        case .notify: return L("알리고 진행", "Show and go")
        case .auto: return L("알아서", "On its own")
        }
    }
    var summary: String {
        switch self {
        case .off: return L("AI가 스스로 다른 AI에게 묻거나 회의를 열지 않아요. 프로젝트 작업의 검토 질문(ask_peer)만 남아요.",
                            "AIs do not ask other AIs or hold meetings on their own. Only the review question of project work (ask_peer) stays.")
        case .notify: return L("필요할 때 AI가 다른 AI에게 묻거나 회의를 열고, 답 아래 카드로 알려 줘요. 확인 창은 없어요.",
                               "AIs ask other AIs or hold a meeting when needed and show a card under the answer. No confirmation.")
        case .auto: return L("필요할 때 AI끼리 알아서 묻고 회의해요. 카드는 한 줄로 접혀 있어요.",
                             "AIs ask each other and meet when needed. The cards are folded into one line.")
        }
    }
}

struct CollabEvent: Codable, Equatable {
    // review: a review of project changes (points found); reviewed: what the lead then took / left.
    enum Kind: String, Codable { case ask, meeting, review, reviewed, outcome, request }
    var at = Date()
    var kind: Kind
    var chat: UUID
    var turn: UUID?
    var mode: String?
    var from: String?          // the asking AI's account id
    var fromKind: String?      // its provider
    var to: [String]?          // account ids asked or called to a meeting
    var toKinds: [String]?
    var purpose: String?       // ask: opinion, fact_check, alternative, review; ask_peer: legacy
    var call: Int?             // ask/outcome: the call's number within that AI's answer
    var failed: Int?           // ask: how many of those asked gave no reply
    var smallTalk: Bool?       // ask/meeting: the user's message was a greeting or thanks
    var outcome: String?       // outcome: yes, partly, no or unknown (as the asking AI reports it)
    var points: Int?, taken: Int?, left: Int?   // review: findings and what the lead says it took / left
    var priorCalls: Int?       // request: cards under the previous answer when the user asked for other AIs
}

enum CollabLog {
    static var maxBytes = 2_000_000             // past this the older half of the lines goes
    private static let lock = NSLock()
    static var file: URL { URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("collab-log.jsonl") }

    static func add(_ event: CollabEvent) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .sortedKeys
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile(); handle.write(line); try? handle.close()
        } else {
            try? line.write(to: file, options: .atomic)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if size > maxBytes, let lines = (try? String(contentsOf: file, encoding: .utf8))?.split(separator: "\n") {
            try? (lines.suffix(lines.count / 2).joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }

    static func events(since: Date = .distantPast) -> [CollabEvent] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        lock.lock(); let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""; lock.unlock()
        return text.split(separator: "\n").compactMap { try? decoder.decode(CollabEvent.self, from: Data($0.utf8)) }.filter { $0.at >= since }
    }

    // Greetings, thanks and acknowledgements only: a short request like "fix this" is not small talk.
    static func smallTalk(_ message: String) -> Bool {
        let plain = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
        guard !plain.isEmpty, plain.count <= 20 else { return false }
        let pattern = #"^(안녕(하세요|하십니까)?|하이|헬로|ㅎㅇ|고마워(요)?|감사(합니다|해요)?|ㄱㅅ|땡큐|수고(했어|하셨어요|했어요)?|좋아(요)?|알겠(어|어요|습니다)|오케이|ㅇㅋ|넵|네|응|ㅇㅇ|굿|잘\s?자|hi|hello|hey|thanks?( you)?|thx|ok(ay)?|got it|good (morning|night)|bye)[\s!~.ㅎㅋ^]*$"#
        return plain.range(of: pattern, options: .regularExpression) != nil
    }

    // The user asks the AIs to bring in another AI or a meeting.
    static func asksOthers(_ message: String) -> Bool {
        let pattern = #"(다른\s?(ai|에이아이|모델)(한테|에게|들한테|들에게)?(도)?\s?(물어|의견|확인)|회의\s?(해|하자|열어|소집|좀)|ask (another|other|a different) (ai|model)|(hold|have|call) a meeting|second opinion)"#
        return message.lowercased().range(of: pattern, options: .regularExpression) != nil
    }

    struct Summary: Equatable {
        var asks = 0, meetings = 0, failedAsks = 0, smallTalk = 0
        var yes = 0, partly = 0, no = 0, unknown = 0
        var reviews = 0, points = 0, taken = 0, left = 0
        var requests = 0, requestsAfterNone = 0
    }

    static func summary(_ events: [CollabEvent]) -> Summary {
        var s = Summary()
        for e in events {
            switch e.kind {
            case .ask:
                s.asks += 1
                if (e.failed ?? 0) > 0 { s.failedAsks += 1 }
                if e.smallTalk == true { s.smallTalk += 1 }
            case .meeting:
                s.meetings += 1
                if e.smallTalk == true { s.smallTalk += 1 }
            case .outcome:
                switch e.outcome { case "yes": s.yes += 1; case "partly": s.partly += 1; case "no": s.no += 1; default: s.unknown += 1 }
            case .review:
                // Logs from before "reviewed" kept what was taken in the review line itself.
                s.reviews += 1; s.points += e.points ?? 0; s.taken += e.taken ?? 0; s.left += e.left ?? 0
            case .reviewed:
                s.taken += e.taken ?? 0; s.left += e.left ?? 0
            case .request:
                s.requests += 1
                if (e.priorCalls ?? 0) == 0 { s.requestsAfterNone += 1 }
            }
        }
        return s
    }

    static func line(_ s: Summary) -> String {
        guard s.asks + s.meetings + s.requests + s.reviews > 0 else { return L("아직 기록이 없어요.", "Nothing recorded yet.") }
        return L("묻기 \(s.asks)번 · 회의 \(s.meetings)번 · 반영 \(s.yes) / 일부 \(s.partly) / 안 씀 \(s.no) · 검토 \(s.reviews)번 · 지적 \(s.points)개 중 반영 \(s.taken)개 · 인사에 부름 \(s.smallTalk)번 · 사용자가 직접 부탁 \(s.requests)번",
                 "\(s.asks) asks · \(s.meetings) meetings · taken \(s.yes) / partly \(s.partly) / left \(s.no) · \(s.reviews) reviews · \(s.taken) of \(s.points) points taken · \(s.smallTalk) on small talk · \(s.requests) asked by the user")
    }
}
