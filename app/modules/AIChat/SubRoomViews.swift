import SwiftUI
import AILocalization
import AIProjects

// What the user sees of sub-rooms (docs/SUBROOM_PLAN.md 1, 7): the split card while it waits for approval and after,
// the progress card with its merge results and Continue/Discard, the sub-rooms' approval requests gathered in the main
// room, and the sidebar's badge and sub-room rows under the main room (folded like its meetings).

enum SplitBadge: Equatable { case waiting, working(Int), done }

extension Split.Part {
    // The state in a few words; a running one with its minutes.
    func stateText(_ now: Date = Date()) -> String {
        switch state {
        case .creating, .ready: return live ? Self.minutes(started, now) : L("준비 중", "Starting")
        case .running: return Self.minutes(started, now)
        case .reported: return L("보고됨", "Reported")
        case .blocked: return L("막힘", "Blocked")
        case .failed: return L("실패", "Failed")
        case .cancelled: return L("취소됨", "Cancelled")
        case .merged: return L("합쳐짐", "Merged")
        case .conflict: return L("충돌", "Conflict")
        }
    }
    static func minutes(_ started: Date?, _ now: Date) -> String {
        let m = started.map { max(0, Int(now.timeIntervalSince($0) / 60)) } ?? 0
        return L("진행 중 \(m)분", "Running \(m) min")
    }
    var color: Color {
        switch state {
        case .creating, .ready, .running: return .blue
        case .reported, .merged: return .green
        case .blocked: return .orange
        case .failed, .conflict: return .red
        case .cancelled: return .secondary
        }
    }
    // Ready to merge: reported (or merged already) and its turn over.
    var mergeable: Bool { [.reported, .merged].contains(state) && !live }
    // How long its latest turn took (or has taken so far).
    func took(_ now: Date = Date()) -> String? {
        guard let started, !live, state != .running else { return nil }   // running: its minutes are in stateText
        let m = max(0, Int((finished ?? now).timeIntervalSince(started) / 60))
        return L("\(m)분", "\(m) min")
    }
}

extension Discussion {
    func watchSplits() {
        guard host == nil, splitWatch == nil else { return }
        for room in SplitStore.shared.rooms() { splitRecords[room] = SplitStore.shared.splits(room) }
        splitWatch = NotificationCenter.default.addObserver(forName: SplitStore.changed, object: nil, queue: .main) { [weak self] note in
            guard let self, let room = note.userInfo?["room"] as? UUID else { return }
            self.splitRecords[room] = SplitStore.shared.splits(room)
        }
    }
    // Splits the main room's cards show: not closed yet (closed ones keep their notes in the chat).
    func openSplits(_ main: UUID) -> [Split] { (splitRecords[main] ?? []).filter { !$0.closed } }
    func subLink(_ room: UUID) -> SubRoomLink? { conversations.first { $0.id == room }?.subOf }
    // Where a request is answered: a sub-room's in its main room (its own chat is hidden).
    public func approvalHome(_ room: UUID) -> UUID { subLink(room)?.room ?? room }
    // The sub-rooms' requests, for their main room's gathered card.
    func gatheredApprovals(_ main: UUID, _ requests: [ProjectApproval]) -> [ProjectApproval] {
        requests.filter { subLink($0.room)?.room == main }
    }

    // The sidebar's mark on a main room: a split or a sub-room waiting for approval, sub-rooms working, or the newest
    // split done (every part reported or merged; a closed one for a day).
    func splitBadge(_ main: UUID, requests: [ProjectApproval], now: Date = Date()) -> SplitBadge? {
        if requests.contains(where: { splitPlans[$0.id]?.room == main || subLink($0.room)?.room == main }) { return .waiting }
        guard let split = splitRecords[main]?.last else { return nil }
        let working = split.parts.filter { !$0.ended || $0.live }.count
        if !split.closed, working > 0 { return .working(working) }
        if split.parts.allSatisfy({ [.reported, .merged].contains($0.state) }), !split.closed || now.timeIntervalSince(split.created) < 86_400 { return .done }
        return nil
    }
    // Sub-rooms under the main room: shown while a split is open or one of them is the open chat, until the user folds
    // them (the same rule as meetings: meetingsShown/toggleMeetings). Ended splits fold into one row.
    func subRoomsShown(_ main: UUID) -> Bool {
        if subRoomsOpen.contains(main) { return true }
        if subRoomsClosed.contains(main) { return false }
        return !openSplits(main).isEmpty || conversations.contains { $0.id == currentID && $0.subOf?.room == main }
    }
    func toggleSubRooms(_ main: UUID) {
        if subRoomsShown(main) { subRoomsOpen.remove(main); subRoomsClosed.insert(main) }
        else { subRoomsClosed.remove(main); subRoomsOpen.insert(main) }
    }
    func subRooms(of main: UUID) -> [Conversation] {
        conversations.filter { $0.subOf?.room == main }.sorted { ($0.createdAt, $0.subOf?.n ?? 0) < ($1.createdAt, $1.subOf?.n ?? 0) }
    }
    func part(_ link: SubRoomLink) -> Split.Part? {
        splitRecords[link.room]?.first { $0.id == link.split }?.parts.first { $0.n == link.n }
    }

    // A message for a sub-room (main thread), from its main room's AI or the user's card: read in its running answer, or
    // it starts again with it. Kept on the card as "→ sent to part n". nil: no work left there to steer.
    func messageSub(_ link: SubRoomLink, _ message: String, from: String) -> String? {
        guard let part = SplitStore.shared.split(link.room, link.split)?.parts.first(where: { $0.n == link.n }),
              part.tree != nil, !part.removed, part.state != .merged else { return nil }
        let said = from + message
        SplitStore.shared.changePart(link) { $0.sent = Array((($0.sent ?? []) + [String(message.prefix(300))]).suffix(20)) }
        if runningRooms.contains(part.room) {
            enqueue(QueuedMessage(text: said), room: part.room)
            return "Sent; sub-room \(link.n) reads it in its answer or its next turn."
        }
        SplitStore.shared.changePart(link) { $0.state = .ready; $0.question = nil }
        SplitStore.shared.change(link.room, link.split) { $0.paused = false; $0.delivered = false }
        queueSub(part.room, question: said)
        return "Sub-room \(link.n) starts again with your message."
    }
    // Stops one sub-room (main thread); its work tree stays.
    func cancelSub(_ link: SubRoomLink) {
        guard let part = SplitStore.shared.split(link.room, link.split)?.parts.first(where: { $0.n == link.n }) else { return }
        stopSub(part.room)
        SplitStore.shared.changePart(link) { if !$0.ended { $0.state = .cancelled } }
    }
    // "Allow for this split": the same command (CommandIdentity key) from any sub-room of this split runs without asking
    // until the split closes; a changed script, config or argument asks again.
    func allowForSplit(_ request: ProjectApproval) {
        if let same = request.same, let link = subLink(request.room) {
            SplitStore.shared.change(link.room, link.split) { split in
                if !(split.allowed ?? []).contains(same) { split.allowed = (split.allowed ?? []) + [same] }
            }
        }
        ProjectCenter.shared.decide(request.id, allow: true)
    }
}

// Above the message box of a main room, with its other cards.
struct SubRoomCards: View {
    @ObservedObject var discussion: Discussion
    @ObservedObject private var center = ProjectCenter.shared
    let room: UUID
    var body: some View {
        let plans = center.requests.filter { discussion.splitPlans[$0.id]?.room == room }
        let gathered = discussion.gatheredApprovals(room, center.requests)
        let splits = discussion.openSplits(room)
        if !plans.isEmpty || !gathered.isEmpty || !splits.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(plans) { request in
                    if let split = discussion.splitPlans[request.id] { SplitPlanCard(split: split, request: request, discussion: discussion) }
                }
                ForEach(gathered) { GatheredApprovalCard(request: $0, discussion: discussion) }
                ForEach(splits, id: \.id) { split in
                    SplitPlanCard(split: split, request: nil, discussion: discussion)
                    SplitProgressCard(split: split, discussion: discussion)
                }
            }
        }
    }
}

private struct CardStyle: ViewModifier {
    var tint: Color
    func body(content: Content) -> some View {
        content.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct Chip: View {
    let text: String, color: Color
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundColor(color)
            .padding(.horizontal, 7).padding(.vertical, 2).background(color.opacity(0.14), in: Capsule())
    }
}

// "작업 나누기": each part's goal, who does it (this room or a sub-room's AI), the files it owns, and how it was approved.
// Waiting: Approve and Refuse. Approved: one line that unfolds.
struct SplitPlanCard: View {
    let split: Split
    let request: ProjectApproval?
    @ObservedObject var discussion: Discussion
    var body: some View {
        let waiting = request != nil
        let open = waiting || discussion.splitPlanShown.contains(split.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "square.split.2x1").foregroundColor(.secondary)
                Text(L("작업 나누기", "Split the work")).font(.system(size: 13, weight: .semibold))
                if waiting { Chip(text: L("승인 대기", "Waiting for approval"), color: .orange) }
                else if split.auto { Chip(text: L("자동 승인됨 (FULL AUTO)", "Approved automatically (FULL AUTO)"), color: .blue) }
                else { Chip(text: L("승인됨", "Approved"), color: .green) }
                Text(L("AI \(split.parts.count + 1)명", "\(split.parts.count + 1) AIs")).font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                if !waiting {
                    Button(action: { discussion.splitPlanShown.formSymmetricDifference([split.id]) }) {
                        Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plainHit).foregroundColor(.secondary)
                    .help(open ? L("접기", "Fold") : L("나눈 계획 보기", "Show the plan"))
                }
            }
            if open {
                ForEach(split.parts, id: \.n) { part in
                    row(L("작업 \(part.n)", "Part \(part.n)"), part.goal,
                        who: L("하위방 \(part.n)", "Sub-room \(part.n)") + (part.name.map { " · " + $0 } ?? ""), files: part.owned)
                }
                if let mine = split.mine {
                    row(L("작업 \(split.parts.count + 1)", "Part \(split.parts.count + 1)"), mine, who: L("이 방", "This room"), files: [])
                }
            }
            if let request {
                HStack {
                    Text(L("사용량이 AI 수만큼 더 들어요.", "Uses more, one share per AI.")).font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                    Button(L("거절", "Refuse")) { ProjectCenter.shared.decide(request.id, allow: false) }
                    Button(L("승인", "Approve")) { ProjectCenter.shared.decide(request.id, allow: true) }.buttonStyle(.borderedProminent)
                }
            }
        }
        .modifier(CardStyle(tint: waiting ? .orange : .accentColor))
    }
    private func row(_ name: String, _ goal: String, who: String, files: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(name).font(.system(size: 12, weight: .semibold))
                Text(goal).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
            }
            Text(who + (files.isEmpty ? "" : " · " + L("맡을 파일: ", "Owns: ") + files.joined(separator: ", ")))
                .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}

// The progress card's own state (an ObservableObject: these Command Line Tools cannot build SwiftUI's @State macro).
final class ProgressCardState: ObservableObject {
    @Published var writing: Int?      // the part whose message box is open
    @Published var draft = ""
    @Published var discarding = false
}

// "하위 작업 진행": each part's state, time, commit and tests; Open, Message and Cancel; merge results (merged, conflicting
// files, files outside its part); "ready to merge k/n"; and Continue/Discard when the split was stopped.
struct SplitProgressCard: View {
    let split: Split
    @ObservedObject var discussion: Discussion
    @StateObject private var state = ProgressCardState()
    var body: some View {
        let ready = split.parts.filter(\.mergeable).count
        TimelineView(.periodic(from: Date(), by: 30)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").foregroundColor(.secondary)
                    Text(L("하위 작업 진행", "Sub-room progress")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(L("합칠 준비 \(ready)/\(split.parts.count)", "Ready to merge \(ready)/\(split.parts.count)"))
                        .font(.system(size: 11, weight: .medium)).foregroundColor(ready == split.parts.count ? .green : .secondary)
                }
                ForEach(split.parts, id: \.n) { part in partRow(part, now: context.date) }
                if stopped {
                    HStack(spacing: 8) {
                        Image(systemName: "pause.circle").foregroundColor(.orange)
                        Text(L("하위 작업이 멈췄어요. 작업 폴더와 브랜치는 남아 있어요.", "The sub-rooms stopped. Their work trees and branches stay."))
                            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(L("버리기", "Discard")) { state.discarding = true }
                        Button(L("이어하기", "Continue")) { discussion.resumeSplit(split.room, split.id) }.buttonStyle(.borderedProminent)
                    }
                    .confirmationDialog(L("하위 작업을 버릴까요?", "Discard the sub-rooms' work?"), isPresented: $state.discarding) {
                        Button(L("작업 폴더와 브랜치 지우기", "Remove their work trees and branches"), role: .destructive) { discard() }
                    } message: {
                        Text(L("합치지 않은 커밋도 같이 지워져요.", "Commits not merged go with them."))
                    }
                }
            }
        }
        .modifier(CardStyle(tint: .accentColor))
    }
    // Stopped with the main room or by a restart: parts cancelled with their work trees left and nothing answering.
    private var stopped: Bool {
        !split.parts.contains(where: \.live) && split.parts.contains { $0.state == .cancelled && !$0.removed } && (split.paused || split.parts.allSatisfy(\.ended))
    }
    private func discard() {
        let main = split.room, id = split.id, discussion = discussion
        DispatchQueue.global(qos: .userInitiated).async {
            let problems = discussion.discardSplit(main, id)
            if !problems.isEmpty {
                discussion.splitCard(main, headline: L("버리지 못한 작업 폴더", "Work trees not discarded"), text: problems.joined(separator: "\n"), failed: true)
            }
        }
    }
    @ViewBuilder private func partRow(_ part: Split.Part, now: Date) -> some View {
        let link = SubRoomLink(room: split.room, split: split.id, n: part.n)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(part.color).frame(width: 8, height: 8)
                Text(L("작업 \(part.n)", "Part \(part.n)")).font(.system(size: 12, weight: .semibold))
                Text(part.goal).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Button(action: { discussion.open(part.room) }) { Image(systemName: "arrow.up.forward.square").frame(width: 24, height: 24) }
                    .buttonStyle(.plainHit).help(L("하위방 열기", "Open the sub-room"))
                    .disabled(!discussion.conversations.contains { $0.id == part.room })
                Button(action: { state.draft = ""; state.writing = part.n }) { Image(systemName: "text.bubble").frame(width: 24, height: 24) }
                    .buttonStyle(.plainHit).help(L("이 하위방에 메시지 보내기", "Send this sub-room a message"))
                    .disabled(part.tree == nil || part.removed || part.state == .merged)
                    .popover(isPresented: Binding(get: { state.writing == part.n }, set: { if !$0 { state.writing = nil } })) {
                        HStack(spacing: 6) {
                            TextField(L("작업 \(part.n)에 보낼 말", "Message for part \(part.n)"), text: $state.draft).frame(width: 280).onSubmit { send(link) }
                            Button(L("보내기", "Send")) { send(link) }.disabled(state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(10)
                    }
                Button(action: { discussion.cancelSub(link) }) { Image(systemName: "xmark.circle").frame(width: 24, height: 24) }
                    .buttonStyle(.plainHit).help(L("이 하위방 멈추기 (작업 폴더는 남김)", "Stop this sub-room (its work tree stays)"))
                    .disabled(part.ended && !part.live)
            }
            .foregroundColor(.primary)
            let facts = [part.name, part.stateText(now), part.took(now).map { L("걸린 시간 ", "took ") + $0 },
                         part.sha.map { L("커밋 ", "commit ") + String($0.prefix(7)) }, part.tests.map { L("테스트: ", "tests: ") + $0 }]
                .compactMap { $0 }.filter { !$0.isEmpty }
            Text(facts.joined(separator: " · ")).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
                .padding(.leading, 14)
            Group {
                if part.state == .merged { line("checkmark.circle", L("합쳐짐", "Merged"), .green) }
                if let conflicts = part.conflicts, !conflicts.isEmpty {
                    line("exclamationmark.triangle", L("충돌 파일: ", "Conflicting files: ") + conflicts.joined(separator: ", "), .red)
                }
                if let outside = part.outside, !outside.isEmpty {
                    line("exclamationmark.circle", L("맡은 범위 밖 변경: ", "Changed outside its part: ") + outside.joined(separator: ", "), .orange)
                }
                if part.state == .blocked, let question = part.question { line("questionmark.circle", question, .orange) }
                if let error = part.error, !error.isEmpty, [.failed, .cancelled].contains(part.state) { line("xmark.octagon", error, .red) }
                ForEach(Array((part.sent ?? []).suffix(3).enumerated()), id: \.offset) { _, sent in
                    Text(L("→ 작업 \(part.n)에 보냄: ", "→ Sent to part \(part.n): ") + sent).font(.system(size: 11)).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.leading, 14)
        }
    }
    private func line(_ icon: String, _ text: String, _ color: Color) -> some View {
        Label { Text(text).lineLimit(2).truncationMode(.middle) } icon: { Image(systemName: icon).foregroundColor(color) }
            .font(.system(size: 11))
    }
    private func send(_ link: SubRoomLink) {
        let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        _ = discussion.messageSub(link, text, from: L("[사용자가 보냄] ", "[From the user] "))
        state.writing = nil; state.draft = ""
    }
}

// A sub-room's approval request, gathered in its main room: "Sub-room n asks to run a command: …". The same command
// (CommandIdentity: real path, arguments, work tree, config and script bytes, permission) may be allowed for the split.
struct GatheredApprovalCard: View {
    let request: ProjectApproval
    @ObservedObject var discussion: Discussion
    var body: some View {
        let n = discussion.subLink(request.room)?.n ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(Color.orange).frame(width: 8, height: 8)
                if let command = request.command {
                    Text(L("하위방 \(n)이 명령 실행을 요청해요: ", "Sub-room \(n) asks to run a command: ")).font(.system(size: 12, weight: .semibold))
                        + Text(command).font(.system(size: 12, design: .monospaced))
                } else {
                    Text(L("하위방 \(n)이 허가를 요청해요: ", "Sub-room \(n) asks for approval: ") + request.title).font(.system(size: 12, weight: .semibold))
                }
            }
            ScrollView { Text(request.detail).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 54)
            HStack {
                Button(L("거절", "Deny")) { ProjectCenter.shared.decide(request.id, allow: false) }
                Spacer()
                Button(request.same == nil ? L("허용", "Allow") : L("한 번만", "Just once")) { ProjectCenter.shared.decide(request.id, allow: true) }
                if request.same != nil {
                    Button(L("이번 분할 동안 허용", "Allow during this split")) { discussion.allowForSplit(request) }.buttonStyle(.borderedProminent)
                        .help(L("같은 명령(실행 파일·인자·작업 폴더·설정·스크립트가 모두 같을 때)은 이 분할이 끝날 때까지 다시 묻지 않아요.",
                                "The same command (executable, arguments, work tree, config and scripts all unchanged) is not asked again until this split ends."))
                }
            }
        }
        .modifier(CardStyle(tint: .orange))
    }
}

// The sidebar's mark on a main room.
struct SplitBadgeView: View {
    let badge: SplitBadge
    var body: some View {
        switch badge {
        case .waiting: Chip(text: L("승인 대기", "Approval"), color: .orange).help(L("허가를 기다려요", "Waiting for approval"))
        case .working(let n): Chip(text: L("작업 \(n)", "\(n) working"), color: .blue).help(L("하위방 \(n)개 진행 중", "\(n) sub-rooms working"))
        case .done: Chip(text: L("✓ 완료", "✓ Done"), color: .green).help(L("하위 작업이 모두 끝났어요", "Every sub-room has finished"))
        }
    }
}

// A sub-room under its main room: "↳ part n · title" and "AI · running m min / reported / blocked / failed".
struct SubRoomRow: View {
    let room: Conversation
    @ObservedObject var discussion: Discussion
    var depth = 0
    var body: some View {
        let link = room.subOf
        let part = link.flatMap { discussion.part($0) }
        let selected = room.id == discussion.currentID && discussion.viewingRemote == nil && !discussion.viewingBoard && discussion.viewingSpace == nil
        let key = "sub." + room.id.uuidString
        TimelineView(.periodic(from: Date(), by: 30)) { context in
            HStack(spacing: 5) {
                Circle().fill(part?.color ?? .secondary).frame(width: 6, height: 6).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("↳ " + L("작업 \(link?.n ?? 0) · ", "Part \(link?.n ?? 0) · ") + (part?.goal ?? room.title)).lineLimit(1).truncationMode(.tail)
                    Text([part?.name, part?.stateText(context.date)].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 12))
        .padding(.leading, 24 + CGFloat(depth) * 12).padding(.trailing, 10).frame(height: 36)
        .background(selected ? Color.primary.opacity(0.10) : discussion.hoverKey == key ? Color.primary.opacity(0.05) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { discussion.open(room.id) }
        .onHover { inside in discussion.hover(key, inside) }
        .help(room.title)
        .disabled(discussion.importingMaterials)
    }
}

// The sub-rooms' fold row, above them: unfolds them ("2 sub-rooms · ended (click for the record)") or folds them again.
struct SubRoomsFoldedRow: View {
    let main: UUID
    let count: Int
    @ObservedObject var discussion: Discussion
    var depth = 0
    var body: some View {
        let ended = discussion.openSplits(main).isEmpty, shown = discussion.subRoomsShown(main)
        Button(action: { discussion.toggleSubRooms(main) }) {
            HStack(spacing: 5) {
                Image(systemName: shown ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold)).frame(width: 18)
                Text(shown ? L("하위방 \(count)개 · 접기", "\(count) sub-rooms · fold")
                     : ended ? L("하위방 \(count)개 · 끝남 (눌러서 기록 보기)", "\(count) sub-rooms · ended (click for the record)")
                     : L("하위방 \(count)개 · 접힘 (눌러서 보기)", "\(count) sub-rooms · folded (click to show)"))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11)).foregroundColor(.secondary)
            .padding(.leading, 24 + CGFloat(depth) * 12).padding(.trailing, 10).frame(minHeight: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
    }
}
