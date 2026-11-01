import Cocoa
import SwiftUI

// The game window: pick players, then a poker table with the hand log on the right.
final class PokerWindow {
    private var window: NSWindow?

    func updateLanguage() { window?.title = L("AI Illuminati 게임", "AI Illuminati Games") }

    func show(game: PokerGame) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: PokerView(game: game)))
            w.title = L("AI Illuminati 게임", "AI Illuminati Games")
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 1040, height: 700))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct PokerView: View {
    @ObservedObject var game: PokerGame

    var body: some View {
        if game.running || game.hand != nil {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    PokerToolbar(game: game)
                    Divider()
                    PokerTable(game: game).padding(16)
                }
                Divider()
                PokerLog(game: game).frame(width: 320)
            }
            .frame(minWidth: 900, minHeight: 600)
        } else {
            PokerSetup(game: game).frame(minWidth: 900, minHeight: 600)
        }
    }
}

// MARK: Setup

struct PokerSetup: View {
    @ObservedObject var game: PokerGame

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("텍사스 홀덤", "Texas Hold'em")).font(.largeTitle.bold())
                Text(L("앱이 딜러예요. 카드 섞기, 배팅 규칙, 팟 계산, 족보 판정은 앱이 하고, AI는 자기 카드 두 장과 테이블에 보이는 것만 보고 폴드·체크·콜·레이즈를 정해요. 칩은 가상 칩이에요.",
                       "The app is the dealer: it shuffles, checks every bet, splits pots and ranks hands. Each AI sees only its own two cards and the open table, and picks fold, check, call or raise. Chips are virtual."))
                    .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if !game.notice.isEmpty { Text(game.notice).foregroundColor(.orange) }

                Text(L("AI 선수 (최대 4명)", "AI players (up to 4)")).font(.headline).padding(.top, 6)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(game.aiAccounts, id: \.id) { account in
                        Toggle(isOn: Binding(get: { game.chosenAI.contains(account.id) }, set: { _ in game.toggle(account.id) })) {
                            HStack(spacing: 6) {
                                Text(account.name)
                                if !account.name.hasPrefix(account.provider.title) {
                                    Text(account.provider.title).font(.caption).foregroundColor(.secondary)
                                }
                                if let n = game.chosenAI.firstIndex(of: account.id) {
                                    Text(L("\(n + 1)번 자리", "seat \(n + 1)")).font(.caption).foregroundColor(.accentColor)
                                }
                            }
                        }
                        .disabled(!game.chosenAI.contains(account.id) && game.chosenAI.count >= 4)
                    }
                }
                Toggle(L("나도 같이 하기 (끄면 AI끼리 구경)", "I play too (off: watch the AIs)"), isOn: $game.withMe)
                Toggle(L("판이 끝나면 자동으로 다음 판", "Deal the next hand automatically"), isOn: $game.autoNext)
                Text(L("AI가 한 번 결정할 때마다 그 계정의 사용량을 조금 써요 (보통 5~15초). 한 판은 1~3분쯤 걸려요.",
                       "Each AI decision uses a little of that account's usage (usually 5–15 s). A hand takes about 1–3 minutes."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(action: game.start) {
                    Text(L("게임 시작", "Start game")).frame(minWidth: 140)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!game.canStart)
                if !game.canStart {
                    Text(L("AI를 1명 이상 고르세요 (구경만 할 때는 2명 이상).", "Pick at least one AI (two to only watch)."))
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: 460, alignment: .leading)
            PokerLeaderboard(game: game)
        }
        .padding(28)
    }
}

struct PokerLeaderboard: View {
    @ObservedObject var game: PokerGame

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("순위표", "Leaderboard")).font(.headline)
            if game.leaderboard.isEmpty {
                Text(L("아직 기록이 없어요. 모두 \(PokerStore.startingChips)칩으로 시작해요.", "No records yet. Everyone starts with \(PokerStore.startingChips) chips."))
                    .foregroundColor(.secondary)
            }
            ForEach(Array(game.leaderboard.enumerated()), id: \.element.id) { n, row in
                HStack {
                    Text("\(n + 1)").font(.headline.monospacedDigit()).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.record.name)
                        Text(L("\(row.record.hands)판 · \(row.record.wins)승", "\(row.record.hands) hands · \(row.record.wins) wins")
                             + (row.record.rebuys > 0 ? L(" · 리바이 \(row.record.rebuys)", " · \(row.record.rebuys) rebuys") : ""))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Text("\(row.record.chips)").font(.body.monospacedDigit().bold())
                    if row.record.chips < PokerStore.startingChips {
                        Button(L("리바이", "Rebuy")) { game.rebuy(row.id) }
                            .help(L("\(PokerStore.startingChips)칩으로 다시 채워요", "Refill to \(PokerStore.startingChips) chips"))
                    }
                }
                .padding(.vertical, 2)
            }
            if !game.leaderboard.isEmpty {
                Button(L("기록 모두 지우기", "Reset all records"), action: game.resetRecords).padding(.top, 6)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }
}

// MARK: Table

struct PokerToolbar: View {
    @ObservedObject var game: PokerGame

    var body: some View {
        HStack(spacing: 12) {
            Text(L("\(game.handNumber)번째 판", "Hand \(game.handNumber)")).font(.headline)
            Text(L("블라인드 \(game.smallBlind)/\(game.bigBlind)", "Blinds \(game.smallBlind)/\(game.bigBlind)")).foregroundColor(.secondary)
            if !game.notice.isEmpty { Text(game.notice).foregroundColor(.orange).lineLimit(1) }
            Spacer()
            Toggle(L("자동 다음 판", "Auto next hand"), isOn: $game.autoNext).toggleStyle(.checkbox)
            if game.running && game.hand?.finished == true {
                Button(L("다음 판", "Next hand"), action: game.nextHand).keyboardShortcut(.defaultAction)
            }
            if game.running {
                Button(L("그만하기", "Stop"), action: game.stop)
            } else {
                Button(L("처음 화면", "Back to setup")) { game.hand = nil }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct PokerTable: View {
    @ObservedObject var game: PokerGame

    private var seats: [PokerSeat] { game.hand?.seats ?? game.seats }
    private var spectating: Bool { !seats.contains(where: \.isHuman) }

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(seats.enumerated()).filter { !$0.element.isHuman }, id: \.element.id) { i, seat in
                    PokerSeatView(game: game, index: i, seat: seat, showCards: showCards(seat))
                }
            }
            Spacer(minLength: 0)
            center
            Spacer(minLength: 0)
            if let i = seats.firstIndex(where: \.isHuman) {
                HStack(alignment: .bottom, spacing: 18) {
                    PokerSeatView(game: game, index: i, seat: seats[i], showCards: true)
                    PokerControls(game: game)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(LinearGradient(colors: [Color(red: 0.10, green: 0.42, blue: 0.24), Color(red: 0.05, green: 0.30, blue: 0.17)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color(red: 0.42, green: 0.27, blue: 0.12), lineWidth: 8))
        )
    }

    // Own cards always; AI cards when only watching, and everyone's once the hand is over.
    private func showCards(_ seat: PokerSeat) -> Bool {
        seat.isHuman || spectating || game.hand?.finished == true
    }

    private var center: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(0..<5, id: \.self) { n in
                    if let hand = game.hand, n < hand.board.count {
                        CardView(card: hand.board[n], width: 58)
                    } else {
                        RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                            .frame(width: 58, height: 82)
                    }
                }
            }
            if let hand = game.hand {
                Text(L("팟 \(hand.pot)", "Pot \(hand.pot)")).font(.title3.bold().monospacedDigit()).foregroundColor(.white)
                Text(status(hand)).foregroundColor(.white.opacity(0.85))
            }
        }
    }

    private func status(_ hand: PokerHand) -> String {
        if hand.finished {
            let names = hand.wins.map { "\(hand.seats[$0.seat].name) +\($0.amount)" + ($0.hand.map { " (\($0))" } ?? "") }
            return L("결과: ", "Result: ") + names.joined(separator: ", ")
        }
        if let id = game.thinking, let seat = hand.seats.first(where: { $0.id == id }) {
            return L("\(seat.name) 생각 중…", "\(seat.name) is thinking…")
        }
        if game.waitingForMe { return L("내 차례예요", "Your turn") }
        return hand.street.title
    }
}

struct PokerSeatView: View {
    @ObservedObject var game: PokerGame
    let index: Int
    let seat: PokerSeat
    let showCards: Bool

    private var hand: PokerHand? { game.hand }
    private var isTurn: Bool { hand?.toAct == index && hand?.finished == false }
    private var won: Int? { hand?.finished == true ? hand?.wins.first(where: { $0.seat == index })?.amount : nil }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                if hand?.dealer == index {
                    Text("D").font(.caption.bold()).foregroundColor(.black).frame(width: 18, height: 18).background(Circle().fill(Color.white))
                }
                Text(seat.name).font(.headline).foregroundColor(.white).lineLimit(1)
            }
            HStack(spacing: 4) {
                if seat.hole.isEmpty {
                    CardView(card: nil, width: 44).opacity(0.25)
                    CardView(card: nil, width: 44).opacity(0.25)
                } else {
                    ForEach(seat.hole, id: \.self) { card in CardView(card: showCards ? card : nil, width: 44) }
                }
            }
            .opacity(seat.folded ? 0.35 : 1)
            Text("\(seat.chips)").font(.body.monospacedDigit().bold()).foregroundColor(.white)
            Group {
                if let won { Text("+\(won)").foregroundColor(.yellow).bold() }
                else if game.thinking == seat.id { HStack(spacing: 4) { ProgressView().controlSize(.small); Text(L("생각 중", "thinking")) } }
                else if seat.folded { Text(L("폴드", "Folded")) }
                else if seat.allIn { Text(L("올인", "All in")).foregroundColor(.orange).bold() }
                else if seat.bet > 0 { Text(L("벳 \(seat.bet)", "Bet \(seat.bet)")) }
                else if hand?.inHand(index) == false { Text(L("칩 없음", "Out")) }
                else { Text(" ") }
            }
            .font(.caption).foregroundColor(.white.opacity(0.9)).frame(height: 18)
        }
        .padding(10)
        .frame(minWidth: 130)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(isTurn ? 0.45 : 0.22)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isTurn ? Color.yellow : (won != nil ? Color.yellow.opacity(0.7) : Color.clear), lineWidth: 2))
    }
}

extension PokerHand {
    func inHand(_ i: Int) -> Bool { seats[i].inHand }
}

struct CardView: View {
    let card: Card?
    var width: CGFloat = 50

    var body: some View {
        ZStack {
            if let card {
                RoundedRectangle(cornerRadius: width * 0.12).fill(Color.white)
                VStack(spacing: 0) {
                    Text(card.rankText).font(.system(size: width * 0.38, weight: .bold, design: .rounded))
                    Text(card.suitText).font(.system(size: width * 0.42))
                }
                .foregroundColor(card.isRed ? Color(red: 0.82, green: 0.1, blue: 0.12) : .black)
            } else {
                RoundedRectangle(cornerRadius: width * 0.12)
                    .fill(LinearGradient(colors: [Color(red: 0.18, green: 0.22, blue: 0.55), Color(red: 0.10, green: 0.12, blue: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "eye.triangle")
                    .font(.system(size: width * 0.34))
                    .foregroundColor(Color(red: 0.95, green: 0.78, blue: 0.3).opacity(0.8))
            }
            RoundedRectangle(cornerRadius: width * 0.12).stroke(Color.black.opacity(0.25), lineWidth: 1)
        }
        .frame(width: width, height: width * 1.42)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

struct PokerControls: View {
    @ObservedObject var game: PokerGame

    var body: some View {
        if let hand = game.hand, game.waitingForMe, let i = hand.toAct {
            let owed = hand.currentBet - hand.seats[i].bet
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if owed > 0 {
                        Button(L("폴드", "Fold")) { game.play(.fold) }
                        Button(L("콜 \(hand.toCall(i))", "Call \(hand.toCall(i))")) { game.play(.call) }.keyboardShortcut(.defaultAction)
                    } else {
                        Button(L("체크", "Check")) { game.play(.check) }.keyboardShortcut(.defaultAction)
                    }
                }
                if hand.canRaise(i) {
                    let low = Double(hand.minRaiseTo(i)), high = Double(hand.maxRaiseTo(i))
                    HStack(spacing: 8) {
                        if high > low {
                            Slider(value: $game.raiseTo, in: low...high, step: Double(game.bigBlind) / 2).frame(width: 180)
                        }
                        Button(L("\(hand.currentBet == 0 ? "벳" : "레이즈") \(Int(min(max(game.raiseTo, low), high)))",
                                 "\(hand.currentBet == 0 ? "Bet" : "Raise to") \(Int(min(max(game.raiseTo, low), high)))")) {
                            game.play(.raise(Int(min(max(game.raiseTo, low), high))))
                        }
                        Button(L("올인", "All in")) { game.play(.raise(hand.maxRaiseTo(i))) }
                    }
                    HStack(spacing: 6) {
                        ForEach([(L("½ 팟", "½ pot"), 0.5), (L("팟", "Pot"), 1.0)], id: \.0) { label, part in
                            Button(label) { game.raiseTo = min(max(Double(hand.currentBet) + Double(hand.pot + owed) * part, low), high) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.3)))
        } else if game.seats.first(where: \.isHuman)?.chips == 0 && game.hand?.finished != false {
            Text(L("칩이 다 떨어졌어요. AI들 경기를 구경해요.", "You're out of chips. Watching the AIs.")).foregroundColor(.white.opacity(0.85))
        }
    }
}

// MARK: Log

struct PokerLog: View {
    @ObservedObject var game: PokerGame

    private var revealReasons: Bool {
        game.hand?.finished == true || game.hand?.seats.contains(where: \.isHuman) == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("이번 판 기록", "This hand")).font(.headline).padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(game.hand?.events ?? []) { event in
                            PokerEventRow(event: event, reveal: revealReasons).id(event.id)
                        }
                        if game.hand?.finished == false && game.hand?.seats.contains(where: \.isHuman) == true {
                            Text(L("🤫 AI들의 속마음은 판이 끝나면 공개돼요.", "🤫 The AIs' reasons are shown when the hand ends."))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: game.hand?.events.count ?? 0) { _ in
                    if let last = game.hand?.events.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
    }
}

struct PokerEventRow: View {
    let event: PokerEvent
    let reveal: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(event.text)
                .font(event.seatID == nil ? .callout.bold() : .callout)
                .foregroundColor(event.seatID == nil ? .accentColor : .primary)
                .textSelection(.enabled)
            if let reason = event.reason, !reason.isEmpty, reveal {
                Text("💭 " + reason)
                    .font(.caption)
                    .foregroundColor(event.fallback ? .orange : .secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
