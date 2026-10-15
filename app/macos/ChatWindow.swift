import Cocoa
import SwiftUI
import UniformTypeIdentifiers

// The chat window: pick which AIs take part, ask, and get one final answer. What the AIs said to
// each other (own answers, then reviews) is folded under the answer.
struct ChatView: View {
    @ObservedObject var discussion: Discussion
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            chat
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    // Saved group chats, newest first. Right-click to delete.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { discussion.newConversation() }) {
                Label(L("새 대화", "New chat"), systemImage: "square.and.pencil").frame(maxWidth: .infinity)
            }
            .disabled(discussion.running)
            .padding(10)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(discussion.conversations) { conversation in
                        let selected = conversation.id == discussion.currentID
                        HStack(spacing: 2) {
                        Button(action: { discussion.open(conversation.id) }) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(conversation.turns.isEmpty ? L("새 대화", "New chat") : conversation.title).lineLimit(2)
                                Text(dateText(conversation.updatedAt)).font(.caption).foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(selected ? Color.accentColor.opacity(0.25) : Color.clear)
                            .cornerRadius(6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(discussion.running)
                        .contextMenu {
                            if !conversation.turns.isEmpty {
                                Button(L("대화 삭제…", "Delete chat…"), role: .destructive) { discussion.delete(conversation.id) }
                            }
                        }
                            if !conversation.turns.isEmpty {
                                Menu {
                                    Button(L("대화 삭제…", "Delete chat…"), role: .destructive) { discussion.delete(conversation.id) }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .frame(width: 20, height: 24)
                                }
                                .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help(L("대화 메뉴", "Chat options"))
                                .accessibilityLabel(L("대화 메뉴: ", "Chat options: ") + conversation.title)
                                .disabled(discussion.running)
                                .padding(.trailing, 6)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .frame(width: 210)
    }

    private var chat: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker(L("대화 방식", "Chat mode"), selection: Binding(get: { discussion.configuration.mode },
                                                        set: { discussion.setMode($0) })) {
                        ForEach(Discussion.availableModes, id: \.self) { mode in
                            Text(ModeChangeMarker.name(mode)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 245)
                    .disabled(discussion.running)
                    Spacer(minLength: 8)
                    if discussion.configuration.mode == 3 {
                        Menu {
                            Picker(L("AI마다 최대 발언", "Maximum turns per AI"), selection: Binding(
                                get: { discussion.configuration.turnsPerAI ?? 4 },
                                set: { limit in discussion.configure { $0.turnsPerAI = limit } })) {
                                ForEach(2...10, id: \.self) { limit in
                                    Text(L("\(limit)회", "\(limit) turns")).tag(limit)
                                }
                            }
                        } label: {
                            Text(L("AI마다 \(discussion.configuration.turnsPerAI ?? 4)회", "\(discussion.configuration.turnsPerAI ?? 4) turns each"))
                        }
                        .fixedSize()
                        .disabled(discussion.running)
                    }
                    Menu {
                        Text(discussion.configuration.mode == 3
                             ? L("모두 동시에 첫 의견을 낸 뒤, 대표가 다음 발언자와 논점, 종료를 정합니다.", "Everyone gives an opening view at once. Then the moderator chooses speakers, topics, and when to finish.")
                             : discussion.configuration.mode == 2
                             ? L("각자 한 번씩 전체 대화를 읽고 답하며, 대표가 다음 순서를 정합니다.", "Each AI reads the full history and replies once. The moderator sets the next order.")
                             : L("각자 답변과 상호 검토 후 최종 답변과 요약을 만듭니다.", "Independent answers and peer review are followed by a final answer and summary."))
                        if discussion.configuration.mode >= 2 {
                            Text(L("손잡이를 끌어 순서를 바꾸고, 이름 옆 메뉴에서 대표를 정하세요.", "Drag the handles to reorder. Use the menu beside a name to choose the moderator."))
                        }
                        if discussion.configuration.mode == 3 {
                            Text(L("첫 의견도 1회로 셉니다. 대표의 진행 판단과 마지막 정리는 발언 수에 포함하지 않습니다.", "The opening view counts as one turn. Moderator decisions and final synthesis do not count."))
                        }
                        if !discussion.current.turns.isEmpty && Discussion.availableModes.count > 1 {
                            Text(L("대화 중에도 방식을 바꿀 수 있어요. 다음 질문부터 적용돼요.", "You can switch modes mid-chat. It applies from the next message."))
                        }
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel(L("대화 방식 안내", "About this chat mode"))
                }
                if discussion.configuration.mode >= 2 {
                    sequentialControls
                } else {
                    HStack(spacing: 14) {
                        Text(L("참여", "Participants")).foregroundColor(.secondary)
                        Toggle("Claude", isOn: $discussion.useClaude)
                        Toggle("ChatGPT", isOn: $discussion.useCodex)
                        Toggle("Gemini", isOn: $discussion.useGemini).disabled(discussion.hasImages)
                        Spacer()
                    }
                    .toggleStyle(.checkbox)
                    .disabled(discussion.running)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        let conversation = discussion.current
                        if conversation.turns.isEmpty {
                            Text(discussion.configuration.mode == 3
                                 ? L("먼저 모든 AI가 동시에 각자 의견을 내요. 그다음 대표가 반론권을 주며 한 명씩 다음 발언자와 논점을 정하고, 각자 앞 발언을 모두 읽고 답해요. AI마다 발언 횟수가 정해져 있고(기본 4회), 전체의 60%(AI마다 최소 2번)까지는 끝내지 않아요. 중지 버튼으로 언제든 끊을 수 있어요.", "First, every AI gives its own view at the same time. Then the moderator picks one speaker at a time, giving a right of reply, and each reads everything said so far. Each AI has a turn limit (4 by default), and the debate won't end before 60% of the total (at least two turns each). Stop at any time.")
                                 : discussion.configuration.mode == 2
                                 ? L("순서와 대표를 정하고 질문하세요. 각 AI가 전체 대화를 읽고 1~2문장씩 이어 말해요.\n한 바퀴가 끝나면 대표가 다음 순서를 정해요. 이름 옆 손잡이를 끌어 직접 바꿀 수도 있어요.", "Choose the order and moderator, then send a message. Each AI reads the full conversation and replies in 1–2 sentences.\nThe moderator sets the next order. Drag the handles to change it yourself.")
                                 : L("질문을 입력하면 AI들이 각자 답하고, 서로 검토한 뒤, 한 명이 최종 답을 정리해 줘요.\n이어서 물어보면 지금까지의 대화 요약을 같이 보내요. 답 길이와 말투는 설정의 '채팅 규칙'에서 정해요.", "Ask a question. The AIs answer, review each other, and produce one final answer.\nFollow-ups include a conversation summary. Adjust length and style in Settings → Chat rules."))
                                .foregroundColor(.secondary)
                                .padding(.top, 40)
                                .frame(maxWidth: .infinity)
                                .multilineTextAlignment(.center)
                        }
                        if discussion.configuration.mode == 1 && !conversation.summary.isEmpty {
                            DisclosureGroup(L("대화 요약 보기 (다음 질문 때 AI들이 읽는 내용)", "Conversation summary (context for the next question)")) {
                                Text(conversation.summary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
                            }
                            .font(.callout)
                            .foregroundColor(.secondary)
                        }
                        ForEach(Array(conversation.turns.enumerated()), id: \.element.id) { index, turn in
                            if index > 0, (turn.mode ?? 1) != (conversation.turns[index - 1].mode ?? 1) {
                                ModeChangeMarker(mode: turn.mode ?? 1)
                            }
                            TurnView(turn: turn, discussion: discussion).id(turn.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: discussion.current.turns.count) { _ in
                    if let last = discussion.current.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                if let error = discussion.attachmentError {
                    Text(error).font(.caption).foregroundColor(.red)
                }
                if discussion.hasImages {
                    Text(L("이미지는 Claude와 ChatGPT에 전달됩니다. 이 대화에서 Gemini는 참여하지 않습니다.", "Images go to Claude and ChatGPT. Gemini is excluded from this image chat."))
                        .font(.caption).foregroundColor(.secondary)
                }
                if !discussion.pendingImages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(discussion.pendingImages) { item in
                                VStack(spacing: 3) {
                                    ZStack(alignment: .topTrailing) {
                                        AttachmentThumbnail(item: item, size: 66)
                                        Button(action: { discussion.removePendingImage(item) }) {
                                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, .black.opacity(0.7))
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(L("첨부 제거: ", "Remove attachment: ") + item.name)
                                        .disabled(discussion.running)
                                    }
                                    Text(item.name).font(.caption2).lineLimit(1).frame(width: 80)
                                }
                            }
                        }
                    }
                }
                HStack(alignment: .bottom, spacing: 10) {
                    Button(action: { discussion.chooseImages() }) {
                        Image(systemName: "plus").font(.system(size: 18, weight: .medium)).frame(width: 30, height: 34)
                    }
                    .buttonStyle(.plain).foregroundColor(.secondary)
                    .accessibilityLabel(L("이미지 첨부", "Attach images"))
                    .help(L("사진 선택 또는 이미지 붙여넣기", "Choose images or paste a screenshot"))
                    .disabled(discussion.running)
                    ZStack(alignment: .leading) {
                        if discussion.draft.isEmpty {
                            Text(L("메시지를 입력하세요…", "Write a message…"))
                                .foregroundColor(.secondary)
                                .frame(height: 36)
                                .padding(.leading, 8)
                                .allowsHitTesting(false)
                        }
                        MultilineInput(text: $discussion.draft, height: $discussion.inputHeight,
                                       onSend: { discussion.send() }, onPasteImages: { discussion.addPastedImages($0) })
                            .frame(height: discussion.inputHeight)
                            .accessibilityLabel(L("질문 입력", "Message"))
                    }
                    .frame(maxWidth: .infinity)
                    composerAction
                        .padding(.bottom, 2)
                }
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.22)))
                HStack {
                    Text(L("Enter: 줄바꿈 · ⌘Enter: 전송", "Enter: new line · ⌘Enter: send"))
                    Spacer()
                    if discussion.running {
                        Text(discussion.stopping ? L("중지 중…", "Stopping…") : L("답변 중", "Responding"))
                    }
                }
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .onDrop(of: [UTType.fileURL, UTType.image], delegate: ImageAttachmentDropDelegate(discussion: discussion))
        }
    }

    @ViewBuilder private var composerAction: some View {
        if discussion.running && discussion.configuration.mode == 3 {
            Button(action: { discussion.stopDebate() }) {
                Image(systemName: "stop.fill").font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .background(Color.secondary.opacity(0.18), in: Circle())
            .accessibilityLabel(L("중지", "Stop"))
            .help(L("응답 중지", "Stop responding"))
            .disabled(discussion.stopping)
        } else if discussion.running {
            ProgressView().controlSize(.small).frame(width: 34, height: 34)
        } else {
            Button(action: { discussion.send() }) {
                Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white).frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .background(!discussion.canSend
                        ? Color.secondary.opacity(0.3) : Color.accentColor, in: Circle())
            .accessibilityLabel(L("보내기", "Send"))
            .help(L("전송 (⌘Enter)", "Send (⌘Enter)"))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!discussion.canSend)
        }
    }

    private var sequentialControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(discussion.configuration.order, id: \.rawValue) { provider in
                    HStack(spacing: 3) {
                        Toggle(provider.title, isOn: Binding(
                            get: { discussion.configuration.participants.contains(provider) },
                            set: { discussion.setParticipation(provider, enabled: $0) }))
                        .disabled(discussion.hasImages && provider == .gemini)
                        Menu {
                            Button(L("대표로 지정", "Make moderator")) {
                                discussion.configure { $0.leader = provider }
                            }
                            .disabled(!discussion.configuration.participants.contains(provider)
                                      || (discussion.hasImages && provider == .gemini))
                        } label: {
                            if discussion.configuration.leader == provider {
                                Image(systemName: "crown.fill")
                                    .foregroundColor(.accentColor)
                            } else {
                                Image(systemName: "chevron.down").font(.caption2)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(L("대표 선택", "Choose moderator"))
                        Image(systemName: "line.3.horizontal")
                            .foregroundColor(.secondary)
                            .frame(width: 22, height: 24)
                            .contentShape(Rectangle())
                            .help(L("끌어서 발언 순서 변경", "Drag to reorder speakers"))
                            .accessibilityLabel(provider.title + L(" 순서 이동", " reorder handle"))
                            .onDrag {
                                guard !discussion.running else { return NSItemProvider() }
                                discussion.draggingProvider = provider
                                discussion.draggingConversationID = discussion.currentID
                                return NSItemProvider(object: provider.rawValue as NSString)
                            }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)
                    .onDrop(of: [UTType.text], delegate: ParticipantDropDelegate(discussion: discussion, target: provider))
                }
                Spacer(minLength: 0)
            }
            .toggleStyle(.checkbox)

        }
        .disabled(discussion.running)
    }

    private func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = AppLanguage.current.locale
        f.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(date) ? "jm" : "MdEEE")
        return f.string(from: date)
    }
}

private struct ParticipantDropDelegate: DropDelegate {
    let discussion: Discussion
    let target: Account.Provider

    func validateDrop(info: DropInfo) -> Bool {
        !discussion.running && discussion.draggingProvider != nil
            && discussion.draggingConversationID == discussion.currentID
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info), let source = discussion.draggingProvider else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            discussion.moveProvider(source, to: target)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        discussion.draggingProvider = nil
        discussion.draggingConversationID = nil
        return true
    }
}

// A thin line where the chat switched to another mode.
private struct ModeChangeMarker: View {
    let mode: Int

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
            Text(L("\(Self.name(mode))(으)로 바뀜", "Switched to \(Self.name(mode))"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize()
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
        }
    }

    static func name(_ mode: Int) -> String {
        switch mode {
        case 3: return L("모드3 · 토론", "Mode 3 · Debate")
        case 2: return L("모드2 · 돌아가며 대화", "Mode 2 · Roundtable")
        default: return L("모드1 · 검토 후 정리", "Mode 1 · Review & summarize")
        }
    }
}

private struct TurnView: View {
    let turn: ChatTurn
    @ObservedObject var discussion: Discussion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 80)
                Text(turn.question)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.18))
                    .cornerRadius(10)
            }
            if let images = turn.images, !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(images) { item in
                            Button(action: { NSWorkspace.shared.open(item.url) }) {
                                AttachmentThumbnail(item: item, size: 120)
                            }
                            .buttonStyle(.plain)
                            .help(item.name)
                            .accessibilityLabel(L("첨부 이미지 열기: ", "Open attached image: ") + item.name)
                        }
                    }
                }
            }
            if !turn.status.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(turn.status).foregroundColor(.secondary)
                }
            }
            if let error = turn.error {
                Text(error).foregroundColor(.red)
            }
            if turn.mode == 3 {
                Text(L("AI 발언 \(turn.entries.count)/\(turn.maxTurns ?? 9)", "AI turns \(turn.entries.count)/\(turn.maxTurns ?? 9)")
                     + (turn.turnsPerAI.map { L(" (AI마다 \($0)회)", " (\($0) each)") } ?? ""))
                    .font(.caption).foregroundColor(.secondary)
                if let focus = turn.debateFocus { Text(L("다음 논점: ", "Next focus: ") + focus).font(.callout).lineLimit(2).foregroundColor(.secondary) }
                if let reason = turn.endReason { Text(L("종료 이유: ", "End reason: ") + reason).font(.callout).foregroundColor(.secondary) }
            }
            if let final = turn.final {
                VStack(alignment: .leading, spacing: 6) {
                    Text(markdown(final))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let by = turn.finalBy {
                        (Text(L("정리: ", "Final answer by: ")).foregroundColor(.secondary)
                         + Text(by).bold().foregroundColor(Account.Provider.of(speaker: by)?.color ?? .secondary))
                            .font(.caption)
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(10)
            }
            if let note = turn.orderNote {
                Text(localizedNotice(note)).font(.caption).foregroundColor(.secondary)
            }
            if !turn.entries.isEmpty {
                if (turn.mode ?? 1) >= 2 {
                    entriesView
                } else {
                    DisclosureGroup(L("AI들의 대화 보기 (\(turn.entries.count))", "View AI discussion (\(turn.entries.count))")) {
                        entriesView
                    }
                    .font(.callout)
                }
            }
        }
    }

    // Entries are appended as each AI finishes; preserve that arrival order on screen.
    // Each shows one short line; clicking it opens the full reply (and the moderator's focus).
    private var entriesView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(turn.entries) { entry in
                EntryRow(entry: entry,
                         isOpen: Binding(get: { discussion.openEntries.contains(entry.id) },
                                         set: { if $0 { discussion.openEntries.insert(entry.id) } else { discussion.openEntries.remove(entry.id) } }),
                         label: (turn.mode ?? 1) >= 2 ? entry.speaker : "\(entry.round == 1 ? L("각자 답", "Initial answer") : L("검토 후", "After review")) · \(entry.speaker)")
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Bold, italics, code and links; line breaks are kept.
    private func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// One chat window, reused. Conversations are saved, so closing it loses nothing.
final class ChatWindow {
    private var window: NSWindow?

    func updateLanguage() { window?.title = L("AI Illuminati 채팅", "AI Illuminati Chat") }

    func show(discussion: Discussion) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ChatView(discussion: discussion, model: discussion.model)))
            w.title = L("AI Illuminati 채팅", "AI Illuminati Chat")
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 900, height: 700))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// Native editor: Return handling stays with the editor, including Korean IME composition.
final class ChatInputTextView: NSTextView {
    var onSend: (() -> Void)?
    var onPasteImages: ((NSPasteboard) -> Bool)?

    private func hasDraggedImage(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        return board.types?.contains(.png) == true || board.types?.contains(.tiff) == true || board.types?.contains(.fileURL) == true
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasDraggedImage(sender) ? .copy : super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasDraggedImage(sender) ? .copy : super.draggingUpdated(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if onPasteImages?(sender.draggingPasteboard) == true { return true }
        return super.performDragOperation(sender)
    }

    override func paste(_ sender: Any?) {
        if onPasteImages?(NSPasteboard.general) == true { return }
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76) && !hasMarkedText() {
            if event.modifierFlags.contains(.command) {
                onSend?()
            } else {
                insertText("\n", replacementRange: selectedRange())
            }
            return
        }
        super.keyDown(with: event)
    }
}

private struct MultilineInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var onSend: () -> Void
    var onPasteImages: (NSPasteboard) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        let editor = ChatInputTextView()
        editor.registerForDraggedTypes([.fileURL, .png, .tiff, .string])
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 4, height: 4)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.onSend = onSend
        editor.onPasteImages = onPasteImages
        editor.string = text
        editor.setAccessibilityLabel(L("질문 입력", "Message"))
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ChatInputTextView else { return }
        editor.onSend = onSend
        editor.onPasteImages = onPasteImages
        editor.setAccessibilityLabel(L("질문 입력", "Message"))
        if editor.string != text && !editor.hasMarkedText() { editor.string = text }
        context.coordinator.measure(editor)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineInput
        init(_ parent: MultilineInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            measure(editor)
        }
        // The box is at least 36 pt tall. Short text gets equal space above and below so a single
        // line sits in the middle (next to the + and send buttons); longer text keeps a 4 pt margin.
        func measure(_ editor: NSTextView) {
            guard let layout = editor.layoutManager, let container = editor.textContainer else { return }
            layout.ensureLayout(for: container)
            let lineHeight = layout.defaultLineHeight(for: editor.font ?? .systemFont(ofSize: NSFont.systemFontSize))
            let textHeight = max(lineHeight, ceil(layout.usedRect(for: container).height))
            let inset = max(4, floor((36 - textHeight) / 2))
            if abs(editor.textContainerInset.height - inset) > 0.5 {
                editor.textContainerInset = NSSize(width: 4, height: inset)
            }
            let measured = min(116, max(36, textHeight + inset * 2))
            DispatchQueue.main.async { [weak self] in
                guard let self, abs(self.parent.height - measured) > 1 else { return }
                self.parent.height = measured
            }
        }
    }
}

private struct AttachmentThumbnail: View {
    let item: ChatImage
    let size: CGFloat
    var body: some View {
        Group {
            if let image = NSImage(contentsOf: item.url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").foregroundColor(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ImageAttachmentDropDelegate: DropDelegate {
    let discussion: Discussion
    func validateDrop(info: DropInfo) -> Bool { !discussion.running }
    func performDrop(info: DropInfo) -> Bool {
        guard !discussion.running else { return false }
        let conversationID = discussion.currentID
        let files = info.itemProviders(for: [UTType.fileURL])
        if !files.isEmpty {
            for provider in files {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else { url = item as? URL }
                    guard let url else { return }
                    DispatchQueue.main.async {
                        guard discussion.currentID == conversationID, !discussion.running else { return }
                        discussion.importImageFile(url)
                    }
                }
            }
        } else {
            for provider in info.itemProviders(for: [UTType.image]) {
                guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else { continue }
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async {
                        guard discussion.currentID == conversationID, !discussion.running else { return }
                        do { try discussion.addImage(data, name: L("드래그한 이미지", "Dropped image")) }
                        catch { discussion.attachmentError = L("이미지를 첨부할 수 없습니다.", "Could not attach image.") }
                    }
                }
            }
        }
        return true
    }
}

// One AI reply in the chat: name and a one-line summary, with the full text folded underneath.
private struct EntryRow: View {
    let entry: ChatTurn.Entry
    @Binding var isOpen: Bool
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isOpen.toggle() } }) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(label)
                        .font(.caption.bold())
                        .foregroundColor(entry.failed ? .red : Account.Provider.of(speaker: entry.speaker)?.color ?? .secondary)
                        .fixedSize()
                    Text(entry.failed ? entry.text : entry.shortLine)
                        .lineLimit(isOpen ? nil : 1)
                        .foregroundColor(entry.failed ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? L("접기", "Collapse") : L("자세히 보기", "Show full reply"))
            .accessibilityLabel(label + ": " + entry.shortLine)
            if isOpen && !entry.failed {
                VStack(alignment: .leading, spacing: 6) {
                    if let focus = entry.focus {
                        Text(L("대표의 논점: ", "Moderator focus: ") + focus).font(.caption).foregroundColor(.secondary)
                    }
                    Text(Self.markdown(entry.text)).textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// Each AI's own color for its name in the chat, close to its company's brand color.
// A lighter shade in dark mode and a deeper one in light mode keep it readable on both.
extension Account.Provider {
    var color: Color {
        let (dark, light): (NSColor, NSColor)
        switch self {
        case .claude: (dark, light) = (NSColor(srgbRed: 0.88, green: 0.55, blue: 0.42, alpha: 1), NSColor(srgbRed: 0.74, green: 0.36, blue: 0.22, alpha: 1))
        case .codex: (dark, light) = (NSColor(srgbRed: 0.27, green: 0.76, blue: 0.60, alpha: 1), NSColor(srgbRed: 0.05, green: 0.53, blue: 0.41, alpha: 1))
        case .gemini: (dark, light) = (NSColor(srgbRed: 0.45, green: 0.66, blue: 0.99, alpha: 1), NSColor(srgbRed: 0.10, green: 0.45, blue: 0.91, alpha: 1))
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    // Speaker labels start with the AI's name ("Claude (학교)"), so older saved replies get a color too.
    static func of(speaker: String) -> Self? { allCases.first { speaker.hasPrefix($0.title) } }
}
