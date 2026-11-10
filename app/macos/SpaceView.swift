import SwiftUI

// The Space of a chat (Space.swift) in the right panel, its "Space로 만들기" on a meeting's result and the
// sidebar's Spaces. The buttons only move around (open a TODO or a chat); nothing here runs work or approves it.

extension Discussion {
    // A meeting's result becomes a decision log (and its next steps) in chat `room`'s Space, made if it has none.
    func makeSpace(from turn: ChatTurn, in room: UUID) {
        guard let result = turn.final else { return }
        let chat = conversations.first { $0.id == room }
        let number = (chat?.turns.firstIndex { $0.id == turn.id } ?? 0) + 1
        let day = DateFormatter.localizedString(from: turn.answeredAt ?? Date(), dateStyle: .short, timeStyle: .short)
        let source = L("회의 · \(day) · \(number)번째 메시지", "Meeting · \(day) · message \(number)")
        let blocks = SpacePatch.meetingBlocks(result, title: L("회의 결정 · ", "Meeting decisions · ") + day, source: source, chat: turn.meetingRoom)
        SpaceStore.shared.change(room) { doc in
            var d = doc ?? SpaceDoc.new(title: chat?.title ?? "Space", goal: String(turn.question.prefix(200)))
            var next = d.content
            let free = max(0, SpacePatch.blockLimit - next.blocks.count)
            next.blocks += d.withIDs(Array(blocks.prefix(free)))
            if blocks.count > free { d.notice(L("블록이 \(SpacePatch.blockLimit)개를 넘어 회의 결과 일부를 넣지 못했어요", "The Space has \(SpacePatch.blockLimit) blocks; part of the meeting result was left out")) }
            d.commit(next, note: L("회의에서 가져옴", "From a meeting"))
            doc = d
        }
        openSpace(room)
    }

    func openSpace(_ room: UUID) {
        if room != currentID || viewingBoard || viewingRemote != nil { open(room) }
        panelTab = "space"; notesShown = true
    }

    // The only way a Space is refreshed: the user asks, and the answer's patch updates it.
    func refreshSpace() {
        guard !running else { return }
        draft = L("지금까지의 대화에 맞게 Space를 갱신해 줘.", "Update the Space to match the chat so far.")
        send()
    }

    func openSpaceTodo(_ id: String) {
        let todo = TodoStore.shared.snapshot
        guard let item = todo.items.first(where: { $0.id.uuidString == id }) else { openBoard(project: nil); return }
        openBoard(project: todo.lists.first { $0.id == item.listID }?.project.map(SidebarProjects.key), tab: .todo)
    }
}

struct SpacePanel: View {
    @ObservedObject var discussion: Discussion
    let room: UUID
    @ObservedObject private var store = SpaceStore.shared

    var body: some View {
        Group {
            if store.room == room, store.broken {
                note(L("space.json을 읽을 수 없어 고치지 않았어요. 파일: ", "space.json could not be read, so nothing changes it. File: ") + SpaceStore.file(room).path)
            } else if store.room == room, let doc = store.doc {
                filled(doc)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    note(L("이 대화엔 아직 Space가 없어요. 회의 결과의 \"Space로 만들기\"로 만들거나 빈 Space로 시작해요.",
                           "This chat has no Space yet. Make one with \"Make a Space\" on a meeting's result, or start an empty one."))
                    Button(L("빈 Space 만들기", "Start an empty Space")) {
                        store.change(room) { doc in
                            var d = SpaceDoc.new(title: discussion.conversations.first { $0.id == room }?.title ?? "Space", goal: "")
                            d.userAddBlock(.checklist, title: L("할 일", "Checklist"))
                            doc = d
                        }
                    }
                    .padding(.horizontal, 14)
                    Spacer()
                }
            }
        }
        .onAppear { store.open(room) }
        .onChange(of: room) { store.open($0) }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundColor(.secondary).padding(.horizontal, 14).padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }

    private func edit(_ body: (inout SpaceDoc) -> Void) {
        store.change(room) { doc in
            guard var d = doc else { return }
            body(&d); doc = d
        }
    }

    private func filled(_ doc: SpaceDoc) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        SpaceField(key: "\(room).title", value: doc.title, placeholder: L("제목", "Title"), size: 15, weight: .semibold) { text in
                            edit { d in var c = d.content; c.title = text; c.userLocked = true; d.commit(c, note: L("제목 수정", "Renamed")) }
                        }
                        SpaceField(key: "\(room).goal", value: doc.goal, placeholder: L("목표 (하나)", "Goal (one)"), size: 12) { text in
                            edit { d in var c = d.content; c.goal = text; c.userLocked = true; d.commit(c, note: L("목표 수정", "Goal edited")) }
                        }
                        .foregroundColor(.secondary)
                    }
                    ForEach(doc.proposals) { proposalCard($0, doc) }
                    if !doc.notices.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(doc.notices.enumerated()), id: \.offset) { Text("• " + $0.element).font(.system(size: 11)) }
                            Button(L("지우기", "Clear")) { edit { $0.notices = [] } }.buttonStyle(.link).font(.system(size: 11))
                        }
                        .foregroundColor(.orange)
                    }
                    ForEach(doc.blocks) { block($0) }
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
            }
            Divider().opacity(0.5)
            HStack(spacing: 10) {
                Button(action: { discussion.refreshSpace() }) { Label(L("갱신", "Refresh"), systemImage: "arrow.clockwise") }
                    .disabled(discussion.running || discussion.currentID != room)
                    .help(L("AI에게 지금까지의 대화로 Space를 고치게 해요 (자동 갱신은 없어요)", "Asks the AI to update the Space from the chat (it never updates on its own)"))
                Button(action: { edit { $0.undo() } }) { Label(L("되돌리기", "Undo"), systemImage: "arrow.uturn.backward") }
                    .disabled(doc.history.isEmpty)
                    .help(doc.history.last.map { L("되돌리기: ", "Undo: ") + $0.note } ?? L("되돌릴 변경이 없어요", "Nothing to undo"))
                Spacer()
                Menu {
                    ForEach(SpaceKind.allCases, id: \.self) { kind in
                        Button(Self.name(kind)) { edit { _ = $0.userAddBlock(kind, title: Self.name(kind)) } }
                    }
                } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(doc.blocks.count >= SpacePatch.blockLimit)
                    .help(L("블록 추가", "Add a block"))
            }
            .font(.system(size: 12)).buttonStyle(.plainHit).foregroundColor(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            Text(L("버전 \(doc.version) · AI는 변경 블록으로만 바꿔요", "Version \(doc.version) · the AI changes it only through patches"))
                .font(.system(size: 11)).foregroundColor(.secondary)
                .padding(.horizontal, 14).padding(.bottom, 12)
        }
    }

    static func name(_ kind: SpaceKind) -> String {
        switch kind {
        case .checklist: return L("체크리스트", "Checklist")
        case .table: return L("표", "Table")
        case .kanban: return L("칸반", "Kanban")
        case .decisionLog: return L("결정 로그", "Decision log")
        }
    }

    private func proposalCard(_ proposal: SpaceProposal, _ doc: SpaceDoc) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("변경안 · ", "Proposal · ") + proposal.by).font(.system(size: 12, weight: .semibold))
            Text(proposal.reason).font(.system(size: 11)).foregroundColor(.secondary)
            ForEach(Array(proposal.ops.prefix(8).enumerated()), id: \.offset) { Text("• " + SpacePatch.describe($0.element, in: doc)).font(.system(size: 11)) }
            if proposal.ops.count > 8 { Text(L("… \(proposal.ops.count - 8)개 더", "… \(proposal.ops.count - 8) more")).font(.system(size: 11)).foregroundColor(.secondary) }
            HStack {
                Button(L("수락", "Accept")) { edit { _ = SpacePatch.accept(proposal.id, in: &$0) } }
                Button(L("거절", "Reject")) { edit { d in d.proposals.removeAll { $0.id == proposal.id } } }
            }
            .controlSize(.small)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func block(_ block: SpaceBlock) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(block.kind)).font(.system(size: 11)).foregroundColor(.secondary)
                SpaceField(key: "\(room).\(block.id)", value: block.title, placeholder: Self.name(block.kind), size: 13, weight: .medium) { text in
                    edit { d in
                        guard let at = d.find(block.id) else { return }
                        var c = d.content; c.blocks[at.block].title = text; c.blocks[at.block].userLocked = true; d.commit(c, note: L("블록 이름", "Block renamed"))
                    }
                }
                Menu {
                    Button(L("블록 삭제", "Delete block"), role: .destructive) {
                        edit { d in var c = d.content; c.blocks.removeAll { $0.id == block.id }; d.commit(c, note: L("블록 삭제", "Block deleted")) }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 22, height: 22) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundColor(.secondary)
            }
            switch block.kind {
            case .checklist: ForEach(block.items) { checkRow($0) }
            case .table: table(block)
            case .kanban:
                ForEach(block.columns ?? [], id: \.self) { lane in
                    Text(lane).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary).padding(.top, 2)
                    ForEach(block.items.filter { $0.lane == lane }) { kanbanRow($0, block) }
                }
            case .decisionLog: ForEach(block.items) { decisionRow($0) }
            }
            SpaceAddRow(key: "\(room).add.\(block.id)", placeholder: block.kind == .table ? L("줄 추가 (칸은 | 로)", "Add a row (cells split by |)") : L("항목 추가", "Add an item")) { text in
                edit { $0.userAdd(text, to: block.id) }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    static func symbol(_ kind: SpaceKind) -> String {
        switch kind {
        case .checklist: return "checklist"
        case .table: return "tablecells"
        case .kanban: return "rectangle.split.3x1"
        case .decisionLog: return "list.bullet.rectangle"
        }
    }

    private func change(_ item: SpaceItem, _ note: String = L("직접 수정", "Edited"), _ body: (inout SpaceItem) -> Void) {
        edit { $0.userChange(item.id, note: note) { item, _ in body(&item) } }
    }

    private func checkRow(_ item: SpaceItem) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Button(action: { change(item, L("체크", "Checked")) { $0.done = !($0.done ?? false) } }) {
                Image(systemName: item.done == true ? "checkmark.square.fill" : "square").frame(width: 22, height: 22)
            }
            .buttonStyle(.plainHit).foregroundColor(item.done == true ? .accentColor : .secondary)
            SpaceField(key: "\(room).\(item.id)", value: item.text, placeholder: "", size: 12) { text in change(item) { $0.text = text } }
                .strikethrough(item.done == true)
            accessories(item)
        }
    }

    private func table(_ block: SpaceBlock) -> some View {
        let columns = block.columns ?? []
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                ForEach(Array(columns.enumerated()), id: \.offset) { Text($0.element).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                Color.clear.frame(width: 22, height: 1)
            }
            ForEach(block.items) { item in
                HStack(alignment: .top, spacing: 4) {
                    ForEach(Array(columns.indices), id: \.self) { column in
                        SpaceField(key: "\(room).\(item.id).\(column)", value: (item.cells ?? []).indices.contains(column) ? item.cells![column] : "", placeholder: "", size: 12) { text in
                            change(item) { row in
                                var cells = row.cells ?? []
                                while cells.count < columns.count { cells.append("") }
                                cells[column] = text; row.cells = cells
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    accessories(item)
                }
            }
        }
    }

    private func kanbanRow(_ item: SpaceItem, _ block: SpaceBlock) -> some View {
        HStack(alignment: .top, spacing: 6) {
            SpaceField(key: "\(room).\(item.id)", value: item.text, placeholder: "", size: 12) { text in change(item) { $0.text = text } }
            Menu {
                ForEach((block.columns ?? []).filter { $0 != item.lane }, id: \.self) { lane in
                    Button(lane) { change(item, L("옮김", "Moved")) { $0.lane = lane } }
                }
            } label: { Image(systemName: "arrow.left.arrow.right").frame(width: 22, height: 22) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundColor(.secondary)
                .help(L("다른 열로 옮기기", "Move to another lane"))
            accessories(item)
        }
        .padding(.leading, 8)
    }

    private func decisionRow(_ item: SpaceItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                SpaceField(key: "\(room).\(item.id)", value: item.text, placeholder: "", size: 12) { text in change(item) { $0.text = text } }
                accessories(item)
            }
            HStack(spacing: 6) {
                Button(item.open == true ? L("미해결", "Open") : L("결정", "Decided")) {
                    change(item, L("결정 상태", "Decision state")) { $0.open = !($0.open ?? false) }
                }
                .help(L("미해결 ↔ 결정", "Open ↔ decided"))
                Button(item.confirmed ? L("내가 확정함", "Confirmed by me") : L("AI 제안 · 확정하기", "AI proposal · confirm")) {
                    change(item, L("확정", "Confirmed")) { $0.status = $0.confirmed ? "proposed" : "confirmed" }
                }
                .foregroundColor(item.confirmed ? .green : .secondary)
            }
            .buttonStyle(.link).font(.system(size: 11))
            let pro = (item.pro ?? []).joined(separator: ", "), con = (item.con ?? []).joined(separator: ", ")
            if !pro.isEmpty || !con.isEmpty {
                Text([pro.isEmpty ? nil : L("찬성: ", "For: ") + pro, con.isEmpty ? nil : L("반대: ", "Against: ") + con].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            if let source = item.source, !source.isEmpty { Text(source).font(.system(size: 10)).foregroundColor(.secondary) }
        }
        .padding(.vertical, 3)
    }

    // A lock (the user changed it; click to let the AI change it again), the links, and delete.
    @ViewBuilder private func accessories(_ item: SpaceItem) -> some View {
        if let todo = item.todo {
            Button(action: { discussion.openSpaceTodo(todo) }) { Image(systemName: "checklist").frame(width: 22, height: 22) }
                .buttonStyle(.plainHit).foregroundColor(.accentColor).help(L("TODO 열기", "Open the TODO"))
        }
        if let chat = item.chat.flatMap(UUID.init(uuidString:)), discussion.conversations.contains(where: { $0.id == chat }) {
            Button(action: { discussion.open(chat) }) { Image(systemName: "bubble.left").frame(width: 22, height: 22) }
                .buttonStyle(.plainHit).foregroundColor(.accentColor).help(L("채팅으로 이동", "Go to the chat"))
        }
        Menu {
            if item.locked {
                Button(L("잠금 풀기 (AI가 다시 바꿀 수 있게)", "Unlock (let the AI change it again)")) {
                    edit { d in
                        guard let at = d.find(item.id), let i = at.item else { return }
                        var c = d.content; c.blocks[at.block].items[i].userLocked = nil; d.commit(c, note: L("잠금 풀기", "Unlocked"))
                    }
                }
            }
            Button(L("삭제", "Delete"), role: .destructive) {
                edit { d in
                    guard let at = d.find(item.id), let i = at.item else { return }
                    var c = d.content; c.blocks[at.block].items.remove(at: i); d.commit(c, note: L("항목 삭제", "Item deleted"))
                }
            }
        } label: {
            Image(systemName: item.locked ? "lock.fill" : "ellipsis").font(.system(size: 10)).frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundColor(.secondary)
        .help(item.locked ? L("내가 고친 항목: AI가 바꾸려면 변경안으로 와요", "You edited this: an AI change comes as a proposal") : L("항목 메뉴", "Item menu"))
    }
}

// What is being typed in the Space panel, by field (an ObservableObject: this Mac's Command Line Tools cannot build
// SwiftUI's @State macro). A field saves when the user presses Return or leaves it, not on every key (one Undo step).
final class SpaceDrafts: ObservableObject {
    static let shared = SpaceDrafts()
    @Published var texts: [String: String] = [:]
}

private struct SpaceField: View {
    let key: String
    let value: String
    let placeholder: String
    var size: CGFloat = 12
    var weight: Font.Weight = .regular
    let commit: (String) -> Void
    @ObservedObject private var drafts = SpaceDrafts.shared
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: Binding(get: { drafts.texts[key] ?? value }, set: { drafts.texts[key] = $0 }), axis: .vertical)
            .textFieldStyle(.plain).font(.system(size: size, weight: weight))
            .focused($focused)
            .onChange(of: focused) { if !$0 { save() } }
            .onSubmit(save)
    }

    private func save() {
        guard let draft = drafts.texts.removeValue(forKey: key) else { return }
        let text = String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SpacePatch.textLimit))
        if text != value { commit(text) }
    }
}

private struct SpaceAddRow: View {
    let key: String
    let placeholder: String
    let add: (String) -> Void
    @ObservedObject private var drafts = SpaceDrafts.shared
    var body: some View {
        TextField(placeholder, text: Binding(get: { drafts.texts[key] ?? "" }, set: { drafts.texts[key] = $0 }))
            .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(.secondary)
            .onSubmit { add(drafts.texts.removeValue(forKey: key) ?? "") }
    }
}

// The sidebar's Spaces: every chat of this Mac with a Space; a click opens the chat on its Space.
struct SpaceSidebarSection: View {
    @ObservedObject var discussion: Discussion
    @ObservedObject private var store = SpaceStore.shared
    @ObservedObject private var folds = SidebarFold.shared

    var body: some View {
        let known = Set(discussion.conversations.map(\.id))
        let spaces = store.titles.filter { known.contains($0.key) }
            .sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
        Group {
            if !spaces.isEmpty {
                SidebarHeader(title: L("Spaces", "Spaces"), fold: "spaces")
                if !folds.isFolded("spaces") {
                    ForEach(spaces, id: \.key) { entry in
                        let room = entry.key, title = entry.value
                        let key = "space." + room.uuidString
                        let selected = discussion.currentID == room && discussion.notesShown && discussion.panelTab == "space"
                            && !discussion.viewingBoard && discussion.viewingRemote == nil
                        Button(action: { discussion.openSpace(room) }) {
                            HStack(spacing: 8) {
                                Image(systemName: "square.grid.2x2").frame(width: 18)
                                Text(title.isEmpty ? "Space" : title).lineLimit(1)
                                Spacer()
                            }
                            .font(.system(size: 13))
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(selected ? Color.primary.opacity(0.1) : discussion.hoverKey == key ? Color.primary.opacity(0.06) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plainHit)
                        .onHover { discussion.hover(key, $0) }
                    }
                }
            }
        }
        .onAppear { store.scanOnce() }
    }
}
