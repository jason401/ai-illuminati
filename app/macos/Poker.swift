import Foundation
import Combine

// Texas Hold'em (no limit) with virtual chips. The app is the dealer: it shuffles, deals, checks
// every bet, splits pots and ranks hands. Each AI only answers "fold / check / call / raise N" from
// its own two cards and what everyone at the table can see; it never sees other players' cards or
// reasons. Chips and records are kept in ~/Library/Application Support/AI Illuminati/poker.json.

struct Card: Codable, Hashable {
    let rank: Int   // 2…14 (14 = ace)
    let suit: Int   // 0 ♠, 1 ♥, 2 ♦, 3 ♣

    var rankText: String {
        switch rank {
        case 14: return "A"
        case 13: return "K"
        case 12: return "Q"
        case 11: return "J"
        default: return String(rank)
        }
    }
    var suitText: String { ["♠", "♥", "♦", "♣"][suit] }
    var text: String { rankText + suitText }
    var isRed: Bool { suit == 1 || suit == 2 }

    static var fullDeck: [Card] { (0..<4).flatMap { suit in (2...14).map { Card(rank: $0, suit: suit) } } }

    // "As", "10h", "Td" → card (used by tests).
    init(rank: Int, suit: Int) { self.rank = rank; self.suit = suit }
    init?(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let s = t.last, let suit = ["s", "h", "d", "c"].firstIndex(of: String(s).lowercased()) else { return nil }
        let r = t.dropLast().uppercased()
        let ranks = ["A": 14, "K": 13, "Q": 12, "J": 11, "T": 10]
        guard let rank = ranks[r] ?? Int(r), (2...14).contains(rank) else { return nil }
        self.init(rank: rank, suit: suit)
    }
}

// How strong a hand is. Bigger is better; equal means a split.
struct HandValue: Comparable {
    let category: Int   // 0 high card … 8 straight flush
    let ranks: [Int]    // tie breakers, most important first

    static func < (a: HandValue, b: HandValue) -> Bool {
        a.category != b.category ? a.category < b.category : a.ranks.lexicographicallyPrecedes(b.ranks)
    }

    var name: String {
        switch category {
        case 8: return ranks.first == 14 ? L("로열 플러시", "Royal flush") : L("스트레이트 플러시", "Straight flush")
        case 7: return L("포카드", "Four of a kind")
        case 6: return L("풀하우스", "Full house")
        case 5: return L("플러시", "Flush")
        case 4: return L("스트레이트", "Straight")
        case 3: return L("트리플", "Three of a kind")
        case 2: return L("투페어", "Two pair")
        case 1: return L("원페어", "One pair")
        default: return L("하이카드", "High card")
        }
    }
}

enum HandEvaluator {
    // Best five of the given cards (5 to 7).
    static func best(_ cards: [Card]) -> HandValue {
        guard cards.count > 5 else { return five(cards) }
        var best: HandValue?
        let n = cards.count
        for a in 0..<n { for b in (a + 1)..<n { for c in (b + 1)..<n { for d in (c + 1)..<n { for e in (d + 1)..<n {
            let value = five([cards[a], cards[b], cards[c], cards[d], cards[e]])
            if best == nil || best! < value { best = value }
        } } } } }
        return best!
    }

    static func five(_ cards: [Card]) -> HandValue {
        let ranks = cards.map(\.rank).sorted(by: >)
        let flush = Set(cards.map(\.suit)).count == 1
        let unique = Array(Set(ranks)).sorted(by: >)
        var straightHigh: Int?
        if unique.count == 5 {
            if unique[0] - unique[4] == 4 { straightHigh = unique[0] }
            else if unique == [14, 5, 4, 3, 2] { straightHigh = 5 }
        }
        if let high = straightHigh { return HandValue(category: flush ? 8 : 4, ranks: [high]) }
        if flush { return HandValue(category: 5, ranks: ranks) }
        // Groups of the same rank: bigger groups first, then higher ranks.
        var counts: [Int: Int] = [:]
        ranks.forEach { counts[$0, default: 0] += 1 }
        let groups = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key > $1.key }
        let order = groups.map(\.key)
        switch groups.map(\.value) {
        case [4, 1]: return HandValue(category: 7, ranks: order)
        case [3, 2]: return HandValue(category: 6, ranks: order)
        case [3, 1, 1]: return HandValue(category: 3, ranks: order)
        case [2, 2, 1]: return HandValue(category: 2, ranks: order)
        case [2, 1, 1, 1]: return HandValue(category: 1, ranks: order)
        default: return HandValue(category: 0, ranks: order)
        }
    }
}

enum PokerAction: Equatable {
    case fold, check, call
    case raise(Int)   // raise to this total bet for the current street

    var text: String {
        switch self {
        case .fold: return L("폴드", "Fold")
        case .check: return L("체크", "Check")
        case .call: return L("콜", "Call")
        case .raise(let to): return L("레이즈 \(to)", "Raise to \(to)")
        }
    }
}

struct PokerSeat: Identifiable, Equatable {
    let id: String          // account id, or "me"
    var name: String
    var isHuman: Bool
    var chips: Int
    var hole: [Card] = []
    var folded = false
    var bet = 0             // put in on this street
    var committed = 0       // put in during this hand
    var acted = false
    var inHand = false      // dealt in (had chips when the hand started)

    var allIn: Bool { inHand && !folded && chips == 0 }
}

enum Street: Int, Comparable {
    case preflop, flop, turn, river, showdown
    static func < (a: Street, b: Street) -> Bool { a.rawValue < b.rawValue }
    var title: String {
        switch self {
        case .preflop: return L("프리플랍", "Preflop")
        case .flop: return L("플랍", "Flop")
        case .turn: return L("턴", "Turn")
        case .river: return L("리버", "River")
        case .showdown: return L("쇼다운", "Showdown")
        }
    }
}

struct PokerEvent: Identifiable, Equatable {
    let id = UUID()
    var street: Street
    var seatID: String?
    var text: String
    var reason: String?     // the AI's private reason; shown after the hand
    var fallback = false    // the answer could not be used, so the app chose for it
}

struct PokerWin: Equatable {
    var seat: Int
    var amount: Int
    var hand: String?
}

// One hand, from the deal to the last chip. Pure rules, no waiting or UI.
struct PokerHand {
    var seats: [PokerSeat]
    let dealer: Int
    let smallBlind: Int
    let bigBlind: Int
    var deck: [Card]
    var board: [Card] = []
    var street: Street = .preflop
    var currentBet = 0
    var minRaise: Int
    var toAct: Int?
    var events: [PokerEvent] = []
    var wins: [PokerWin] = []
    var finished = false

    init(seats: [PokerSeat], dealer: Int, smallBlind: Int, bigBlind: Int, deck: [Card]) {
        self.seats = seats
        self.dealer = dealer
        self.smallBlind = smallBlind
        self.bigBlind = bigBlind
        self.deck = deck
        self.minRaise = bigBlind
        for i in self.seats.indices {
            let chips = self.seats[i].chips
            self.seats[i] = PokerSeat(id: seats[i].id, name: seats[i].name, isHuman: seats[i].isHuman, chips: chips)
            self.seats[i].inHand = chips > 0
        }
        let players = self.seats.indices.filter { self.seats[$0].inHand }
        guard players.count >= 2, self.seats[dealer].inHand else { finished = true; return }
        // Two cards each, starting left of the dealer.
        for _ in 0..<2 {
            var i = dealer
            for _ in players { i = next(after: i) { self.seats[$0].inHand }!; self.seats[i].hole.append(self.deck.removeFirst()) }
        }
        let small = players.count == 2 ? dealer : next(after: dealer) { self.seats[$0].inHand }!
        let big = next(after: small) { self.seats[$0].inHand }!
        put(small, smallBlind)
        put(big, bigBlind)
        events.append(PokerEvent(street: .preflop, seatID: nil,
                                 text: L("블라인드: \(self.seats[small].name) \(smallBlind), \(self.seats[big].name) \(bigBlind)",
                                         "Blinds: \(self.seats[small].name) \(smallBlind), \(self.seats[big].name) \(bigBlind)")))
        currentBet = bigBlind
        if let first = next(after: big, where: needsAction) { toAct = first } else { finishStreet() }
    }

    // MARK: Who plays

    var contenders: [Int] { seats.indices.filter { seats[$0].inHand && !seats[$0].folded } }
    func canAct(_ i: Int) -> Bool { seats[i].inHand && !seats[i].folded && seats[i].chips > 0 }
    func needsAction(_ i: Int) -> Bool {
        guard canAct(i) else { return false }
        if seats[i].bet < currentBet { return true }
        // Alone against all-in players with nothing to call: nothing left to decide.
        if seats.indices.filter(canAct).count < 2 { return false }
        return !seats[i].acted
    }
    func next(after i: Int, where test: (Int) -> Bool) -> Int? {
        for step in 1...seats.count {
            let j = (i + step) % seats.count
            if test(j) { return j }
        }
        return nil
    }

    var pot: Int { seats.reduce(0) { $0 + $1.committed } }
    func toCall(_ i: Int) -> Int { max(0, min(currentBet - seats[i].bet, seats[i].chips)) }
    func maxRaiseTo(_ i: Int) -> Int { seats[i].bet + seats[i].chips }
    func minRaiseTo(_ i: Int) -> Int { min(currentBet + minRaise, maxRaiseTo(i)) }
    func canRaise(_ i: Int) -> Bool { maxRaiseTo(i) > currentBet }

    // Turns any wish into a legal action: check when nothing is owed instead of folding or calling,
    // raises are kept between the minimum and all-in, and a raise without enough chips is a call.
    func legal(_ action: PokerAction, for i: Int) -> PokerAction {
        let owed = currentBet - seats[i].bet
        switch action {
        case .fold: return owed > 0 ? .fold : .check
        case .check: return owed > 0 ? .fold : .check
        case .call: return owed > 0 ? .call : .check
        case .raise(let to):
            guard canRaise(i) else { return owed > 0 ? .call : .check }
            return .raise(min(max(to, minRaiseTo(i)), maxRaiseTo(i)))
        }
    }

    // MARK: Playing

    private mutating func put(_ i: Int, _ amount: Int) {
        let paid = min(amount, seats[i].chips)
        seats[i].chips -= paid
        seats[i].bet += paid
        seats[i].committed += paid
    }

    // Applies the seat's action (made legal first). Returns what was really done.
    @discardableResult
    mutating func apply(_ wish: PokerAction, by i: Int, reason: String? = nil, fallback: Bool = false) -> PokerAction {
        guard !finished, toAct == i else { return wish }
        let action = legal(wish, for: i)
        var text = ""
        switch action {
        case .fold:
            seats[i].folded = true
            text = L("폴드", "folds")
        case .check:
            text = L("체크", "checks")
        case .call:
            let amount = toCall(i)
            put(i, amount)
            text = L("콜 \(amount)", "calls \(amount)")
        case .raise(let to):
            let size = to - currentBet
            put(i, to - seats[i].bet)
            if size >= minRaise {
                minRaise = size
                for j in seats.indices where j != i { seats[j].acted = false }
            }
            text = (currentBet == 0 ? L("벳 \(to)", "bets \(to)") : L("레이즈 \(to)", "raises to \(to)"))
            currentBet = to
        }
        if seats[i].allIn && action != .fold { text += L(" (올인)", " (all in)") }
        seats[i].acted = true
        events.append(PokerEvent(street: street, seatID: seats[i].id, text: "\(seats[i].name): \(text)", reason: reason, fallback: fallback))
        if contenders.count == 1 {
            let winner = contenders[0]
            let amount = pot
            seats[winner].chips += amount
            wins = [PokerWin(seat: winner, amount: amount, hand: nil)]
            events.append(PokerEvent(street: street, seatID: nil, text: L("\(seats[winner].name) 승리 +\(amount) (모두 폴드)", "\(seats[winner].name) wins \(amount) (everyone folded)")))
            toAct = nil
            finished = true
        } else if let n = next(after: i, where: needsAction) {
            toAct = n
        } else {
            finishStreet()
        }
        return action
    }

    private mutating func finishStreet() {
        toAct = nil
        while true {
            for j in seats.indices { seats[j].bet = 0; seats[j].acted = false }
            currentBet = 0
            minRaise = bigBlind
            if street == .river { showdown(); return }
            let count = street == .preflop ? 3 : 1
            deck.removeFirst()   // burn
            board += deck.prefix(count)
            deck.removeFirst(count)
            street = Street(rawValue: street.rawValue + 1)!
            events.append(PokerEvent(street: street, seatID: nil, text: "\(street.title): " + board.map(\.text).joined(separator: " ")))
            if let first = next(after: dealer, where: needsAction) { toAct = first; return }
        }
    }

    // Main pot and side pots: each level of commitment is a pot shared only by players who put in that much.
    func pots() -> [(amount: Int, eligible: [Int])] {
        let levels = Array(Set(seats.filter(\.inHand).map(\.committed).filter { $0 > 0 })).sorted()
        var result: [(amount: Int, eligible: [Int])] = []
        var previous = 0, carried = 0
        for level in levels {
            let amount = seats.reduce(0) { $0 + min($1.committed, level) - min($1.committed, previous) } + carried
            let eligible = contenders.filter { seats[$0].committed >= level }
            previous = level
            if eligible.isEmpty { carried = amount; continue }
            carried = 0
            if let last = result.last, last.eligible == eligible { result[result.count - 1].amount += amount }
            else { result.append((amount, eligible)) }
        }
        if carried > 0, !result.isEmpty { result[result.count - 1].amount += carried }
        return result
    }

    private mutating func showdown() {
        street = .showdown
        let values = Dictionary(uniqueKeysWithValues: contenders.map { ($0, HandEvaluator.best(seats[$0].hole + board)) })
        for i in contenders {
            events.append(PokerEvent(street: .showdown, seatID: seats[i].id,
                                     text: "\(seats[i].name): " + seats[i].hole.map(\.text).joined(separator: " ") + " — " + values[i]!.name))
        }
        var won: [Int: Int] = [:]
        for pot in pots() {
            let top = pot.eligible.map { values[$0]! }.max()!
            // Winners in seat order from the dealer's left, so the odd chip goes to the first one.
            let winners = (1...seats.count).map { (dealer + $0) % seats.count }.filter { pot.eligible.contains($0) && values[$0]! == top }
            let share = pot.amount / winners.count
            for (n, w) in winners.enumerated() { won[w, default: 0] += share + (n == 0 ? pot.amount % winners.count : 0) }
        }
        for (i, amount) in won.sorted(by: { $0.key < $1.key }) {
            seats[i].chips += amount
            wins.append(PokerWin(seat: i, amount: amount, hand: values[i]!.name))
            events.append(PokerEvent(street: .showdown, seatID: nil, text: L("\(seats[i].name) 승리 +\(amount) (\(values[i]!.name))",
                                                                             "\(seats[i].name) wins \(amount) (\(values[i]!.name))")))
        }
        finished = true
    }
}

// MARK: - AI decisions

enum PokerAI {
    // What one AI sees: its own cards and the public table, never other hands or reasons.
    static func prompt(_ hand: PokerHand, seat i: Int) -> String {
        let me = hand.seats[i]
        let table = hand.seats.indices.filter { hand.seats[$0].inHand }.map { j -> String in
            let s = hand.seats[j]
            var line = "- \(s.name)\(j == i ? " (you)" : ""): stack \(s.chips), bet this street \(s.bet)"
            if j == hand.dealer { line += ", dealer button" }
            if s.folded { line += ", folded" } else if s.allIn { line += ", all in" }
            return line
        }.joined(separator: "\n")
        let history = hand.events.map { "[\($0.street.title)] \($0.text)" }.joined(separator: "\n")
        let owed = hand.currentBet - me.bet
        var options = owed > 0 ? ["fold", "call \(hand.toCall(i))"] : ["check"]
        if hand.canRaise(i) { options.append("raise (to a total bet between \(hand.minRaiseTo(i)) and \(hand.maxRaiseTo(i)); \(hand.maxRaiseTo(i)) is all in)") }
        let language = AppLanguage.current == .korean ? "Korean" : "English"
        return """
        You are \(me.name), playing a friendly game of No-Limit Texas Hold'em with virtual chips (no real money) against other AIs\(hand.seats.contains(where: \.isHuman) ? " and a human" : ""). Play to win chips.
        Blinds \(hand.smallBlind)/\(hand.bigBlind). Street: \(hand.street.title).
        Your cards: \(me.hole.map(\.text).joined(separator: " "))
        Board: \(hand.board.isEmpty ? "(none yet)" : hand.board.map(\.text).joined(separator: " "))
        Pot: \(hand.pot). Your stack: \(me.chips). Your bet this street: \(me.bet). To call: \(max(0, owed)).
        Players:
        \(table)
        This hand so far:
        \(history)
        Your options: \(options.joined(separator: ", ")).
        Do not use tools. Reply with only one line of JSON and nothing else:
        {"action":"fold|check|call|raise","amount":<total bet for raise, else 0>,"reason":"<one short sentence in \(language): why>"}
        """
    }

    struct Decision: Equatable {
        var action: PokerAction
        var reason: String
        var usable: Bool
    }

    // Reads the reply. Unreadable answers become check (or fold when a bet is owed).
    static func parse(_ reply: String, hand: PokerHand, seat i: Int) -> Decision {
        let safe = Decision(action: hand.legal(.check, for: i), reason: L("답을 읽지 못해 자동으로 \(hand.legal(.check, for: i).text)", "Unreadable answer, so \(hand.legal(.check, for: i).text)"), usable: false)
        var word = "", amount: Int?, reason = ""
        if let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
           let object = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any] {
            word = (object["action"] as? String ?? "").lowercased()
            if let n = object["amount"] as? NSNumber { amount = n.intValue }
            else if let s = object["amount"] as? String { amount = Int(s.filter(\.isNumber)) }
            reason = (object["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let lower = reply.lowercased()
            for candidate in ["fold", "check", "call", "raise", "bet", "all in", "all-in"] where lower.contains(candidate) { word = candidate; break }
            amount = lower.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first
        }
        let action: PokerAction
        switch word {
        case "fold": action = .fold
        case "check": action = .check
        case "call": action = .call
        case "raise", "bet": action = .raise(amount ?? hand.minRaiseTo(i))
        case "all in", "all-in", "allin", "all_in": action = .raise(hand.maxRaiseTo(i))
        default: return safe
        }
        if reason.count > 200 { reason = String(reason.prefix(200)) + "…" }
        return Decision(action: hand.legal(action, for: i), reason: reason, usable: true)
    }
}

// MARK: - Saved chips and records

struct PokerRecord: Codable, Equatable {
    var name: String
    var chips: Int
    var hands = 0
    var wins = 0
    var rebuys = 0
}

enum PokerStore {
    static let startingChips = 1000
    static var file: URL { URL(fileURLWithPath: AccountStore.supportDir + "/poker.json") }

    static func load() -> [String: PokerRecord] {
        guard let data = try? Data(contentsOf: file),
              let records = try? JSONDecoder().decode([String: PokerRecord].self, from: data) else { return [:] }
        return records
    }
    static func save(_ records: [String: PokerRecord]) {
        try? FileManager.default.createDirectory(atPath: AccountStore.supportDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(records).write(to: file, options: .atomic)
    }
}

// MARK: - The game at the table (one hand after another)

final class PokerGame: ObservableObject {
    let model: AppModel
    static let humanID = "me"

    // Setup
    @Published var chosenAI: [String] = []      // account ids, in seat order
    @Published var withMe = true
    // Table
    @Published var seats: [PokerSeat] = []
    @Published var hand: PokerHand?
    @Published var running = false
    @Published var thinking: String?            // seat id of the AI deciding now
    @Published var autoNext = true
    @Published var raiseTo: Double = 0
    @Published var notice = ""
    @Published var records: [String: PokerRecord] = PokerStore.load()
    @Published var handNumber = 0

    let smallBlind = 10, bigBlind = 20
    private var dealer = -1
    private var cancellation: DebateCancellation?
    private var generation = 0
    // Tests replace this to answer without running an AI.
    var answer: ((Account, String) -> Result<String, Answerer.Failure>)?
    var shuffle: () -> [Card] = { Card.fullDeck.shuffled() }
    var nextHandDelay: TimeInterval = 4

    init(model: AppModel) {
        self.model = model
        chosenAI = Array(model.accounts.prefix(3).map(\.id))
    }

    var aiAccounts: [Account] { model.accounts }
    var canStart: Bool { (2...4).contains(chosenAI.count) || (withMe && (1...4).contains(chosenAI.count)) }
    var waitingForMe: Bool {
        guard let hand, !hand.finished, let i = hand.toAct else { return false }
        return hand.seats[i].isHuman
    }
    var leaderboard: [(id: String, record: PokerRecord)] {
        records.map { ($0.key, $0.value) }.sorted { $0.record.chips != $1.record.chips ? $0.record.chips > $1.record.chips : $0.record.name < $1.record.name }
    }

    func toggle(_ id: String) {
        if let i = chosenAI.firstIndex(of: id) { chosenAI.remove(at: i) }
        else if chosenAI.count < 4 { chosenAI.append(id) }
    }

    func start() {
        guard canStart, !running else { return }
        var list: [PokerSeat] = []
        if withMe { list.append(seat(id: Self.humanID, name: L("나", "Me"), human: true)) }
        for id in chosenAI {
            guard let account = model.accounts.first(where: { $0.id == id }) else { continue }
            list.append(seat(id: id, name: account.name, human: false))
        }
        seats = list
        PokerStore.save(records)
        running = true
        notice = ""
        dealer = Int.random(in: 0..<seats.count) - 1
        nextHand()
    }

    // A player with no chips gets a fresh stack (counted as a rebuy).
    private func seat(id: String, name: String, human: Bool) -> PokerSeat {
        var record = records[id] ?? PokerRecord(name: name, chips: PokerStore.startingChips)
        record.name = name
        if record.chips <= 0 { record.chips = PokerStore.startingChips; record.rebuys += 1 }
        records[id] = record
        return PokerSeat(id: id, name: name, isHuman: human, chips: record.chips)
    }

    func stop() {
        generation += 1
        cancellation?.cancel()
        cancellation = nil
        running = false
        thinking = nil
        // An unfinished hand is called off: everyone keeps the chips they had before it.
        if let hand, !hand.finished { self.hand = nil; notice = L("진행 중이던 판은 취소했어요 (칩은 그대로).", "The unfinished hand was called off (chips unchanged).") }
    }

    func rebuy(_ id: String) {
        guard !running, var record = records[id] else { return }
        record.chips = PokerStore.startingChips
        record.rebuys += 1
        records[id] = record
        PokerStore.save(records)
    }

    func resetRecords() {
        guard !running else { return }
        records = [:]
        PokerStore.save(records)
    }

    func nextHand() {
        guard running else { return }
        let alive = seats.indices.filter { seats[$0].chips > 0 }
        guard alive.count >= 2 else {
            running = false
            if let winner = alive.first { notice = L("\(seats[winner].name) 님이 칩을 모두 가져갔어요! 게임 끝.", "\(seats[winner].name) took every chip! Game over.") }
            return
        }
        dealer = (1...seats.count).map { (dealer + $0) % seats.count }.first { seats[$0].chips > 0 }!
        handNumber += 1
        hand = PokerHand(seats: seats, dealer: dealer, smallBlind: smallBlind, bigBlind: bigBlind, deck: shuffle())
        step()
    }

    // Moves the hand on: ends it, waits for the human, or asks the AI whose turn it is.
    private func step() {
        guard running, let current = hand else { return }
        if current.finished { handEnded(); return }
        guard let i = current.toAct else { return }
        let seat = current.seats[i]
        if seat.isHuman {
            raiseTo = Double(current.minRaiseTo(i))
            return
        }
        guard let account = model.accounts.first(where: { $0.id == seat.id }) else {
            act(.fold, reason: L("계정이 없어서 폴드", "Account missing, so fold"), fallback: true)
            return
        }
        thinking = seat.id
        let prompt = PokerAI.prompt(current, seat: i)
        let ticket = generation
        let stopper = DebateCancellation()
        cancellation = stopper
        let answer = self.answer
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let reply = answer?(account, prompt) ?? Answerer.ask(account, prompt: prompt, timeout: 120, cancellation: stopper)
            DispatchQueue.main.async {
                guard let self, self.generation == ticket, let hand = self.hand, hand.toAct == i else { return }
                self.thinking = nil
                switch reply {
                case .success(let text):
                    let decision = PokerAI.parse(text, hand: hand, seat: i)
                    self.act(decision.action, reason: decision.reason, fallback: !decision.usable)
                case .failure(let error):
                    let action = hand.legal(.check, for: i)
                    self.act(action, reason: L("응답 실패 (\(Self.describe(error))), 자동으로 \(action.text)", "No answer (\(Self.describe(error))), so \(action.text)"), fallback: true)
                }
            }
        }
    }

    static func describe(_ error: Answerer.Failure) -> String {
        switch error {
        case .missingTool: return L("프로그램 없음", "tool missing")
        case .timedOut: return L("시간 초과", "timed out")
        case .failed(let text): return String(text.prefix(80))
        }
    }

    // The human's buttons call this; AIs come through step().
    func act(_ action: PokerAction, reason: String? = nil, fallback: Bool = false) {
        guard running, var current = hand, let i = current.toAct else { return }
        current.apply(action, by: i, reason: reason, fallback: fallback)
        hand = current
        step()
    }

    func play(_ action: PokerAction) {
        guard waitingForMe else { return }
        act(action)
    }

    private func handEnded() {
        guard let hand else { return }
        for (i, seat) in hand.seats.enumerated() {
            seats[i].chips = seat.chips
            var record = records[seat.id] ?? PokerRecord(name: seat.name, chips: seat.chips)
            record.chips = seat.chips
            if seat.inHand { record.hands += 1 }
            if hand.wins.contains(where: { $0.seat == i }) { record.wins += 1 }
            records[seat.id] = record
        }
        PokerStore.save(records)
        guard autoNext else { return }
        let ticket = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + nextHandDelay) { [weak self] in
            guard let self, self.generation == ticket, self.running, self.hand?.finished == true else { return }
            self.nextHand()
        }
    }
}
