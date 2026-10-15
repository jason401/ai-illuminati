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
                        Text(L("모드1 · 검토 후 정리", "Mode 1 · Review & summarize")).tag(1)
                        Text(L("모드2 · 돌아가며 대화", "Mode 2 · Roundtable")).tag(2)
                        Text(L("모드3 · 대표 진행 토론", "Mode 3 · Moderated debate")).tag(3)
                    }
                    .frame(maxWidth: 340)
                    .disabled(discussion.running || !discussion.current.turns.isEmpty)
                    if !discussion.current.turns.isEmpty {
                        Text(L("방식 변경은 새 대화에서", "Start a new chat to change modes")).font(.caption).foregroundColor(.secondary)
                    }
                }
                if discussion.configuration.mode >= 2 {
                    sequentialControls
                } else {
                    HStack(spacing: 14) {
                        Text(L("참여", "Participants")).foregroundColor(.secondary)
                        Toggle("Claude", isOn: $discussion.useClaude)
                        Toggle("ChatGPT", isOn: $discussion.useCodex)
                        Toggle("Gemini", isOn: $discussion.useGemini)
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
                                 ? L("첫 바퀴는 지정한 순서로 말하고, 이후 대표가 다음 발언자와 논점 또는 종료를 정해요. 최대 발언 수에 도달하면 마무리합니다. 중지 버튼으로 언제든 끊을 수 있어요.", "The first lap follows your order. Then the moderator selects speakers and topics until the discussion is sufficient or the turn limit is reached. Stop at any time.")
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
                        ForEach(conversation.turns) { turn in
                            TurnView(turn: turn).id(turn.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: discussion.current.turns.count) { _ in
                    if let last = discussion.current.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } }
                }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    MultilineInput(text: $discussion.draft, onSend: { discussion.send() })
                        .font(.body)
                        .frame(height: 76)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                        .accessibilityLabel(L("질문 입력", "Message"))
                    Text(L("Enter / Shift+Enter: 줄바꿈 · ⌘Enter: 보내기", "Enter / Shift+Enter: new line · ⌘Enter: send"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if discussion.running && discussion.configuration.mode == 3 {
                    Button(discussion.stopping ? L("중지 중…", "Stopping…") : L("중지", "Stop")) { discussion.stopDebate() }
                        .disabled(discussion.stopping)
                }
                Button(discussion.running ? L("토론 중…", "Discussing…") : L("보내기", "Send")) { discussion.send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(discussion.running || discussion.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
    }

    private var sequentialControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L("순서", "Order")).foregroundColor(.secondary)
                ForEach(discussion.configuration.order, id: \.rawValue) { provider in
                    HStack(spacing: 3) {
                        Toggle(provider.title, isOn: Binding(
                            get: { discussion.configuration.participants.contains(provider) },
                            set: { discussion.setParticipation(provider, enabled: $0) }))
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
            HStack {
                Picker(L("대표", "Moderator"), selection: Binding(get: { discussion.configuration.leader },
                                                 set: { leader in discussion.configure { $0.leader = leader } })) {
                    ForEach(discussion.configuration.order.filter { discussion.configuration.participants.contains($0) }, id: \.rawValue) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .frame(width: 170)
                Text(discussion.configuration.mode == 3
                     ? L("전체 대화 전달 · 대표가 진행과 종료 판단", "Full history · Moderator directs and ends discussion")
                     : L("각자 한 번씩 · 전체 대화 전달 · 대표가 다음 순서 지정", "One turn each · Full history · Moderator sets next order"))
                    .font(.caption).foregroundColor(.secondary)
            }
            if discussion.configuration.mode == 3 {
                Stepper(value: Binding(get: { discussion.configuration.maxTurns ?? 9 },
                                       set: { limit in discussion.configure { $0.maxTurns = limit } }), in: 3...30) {
                    Text(L("최대 AI 발언: \(discussion.configuration.maxTurns ?? 9)회", "Maximum AI turns: \(discussion.configuration.maxTurns ?? 9)"))
                }
                .frame(maxWidth: 320)
                Text(L("대표의 진행 판단과 마지막 정리는 발언 수에 포함하지 않습니다.", "Moderator decisions and final synthesis do not count toward this limit."))
                    .font(.caption).foregroundColor(.secondary)
            }
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

private struct TurnView: View {
    let turn: ChatTurn

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
                Text(L("AI 발언 \(turn.entries.count)/\(turn.maxTurns ?? 9)", "AI turns \(turn.entries.count)/\(turn.maxTurns ?? 9)"))
                    .font(.caption).foregroundColor(.secondary)
                if let focus = turn.debateFocus { Text(L("다음 논점: ", "Next focus: ") + focus).font(.callout) }
                if let reason = turn.endReason { Text(L("종료 이유: ", "End reason: ") + reason).font(.callout).foregroundColor(.secondary) }
            }
            if let final = turn.final {
                VStack(alignment: .leading, spacing: 6) {
                    Text(markdown(final))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let by = turn.finalBy {
                        Text(L("정리: \(by)", "Final answer by: \(by)")).font(.caption).foregroundColor(.secondary)
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
    private var entriesView: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(turn.entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text((turn.mode ?? 1) >= 2 ? entry.speaker : "\(entry.round == 1 ? L("각자 답", "Initial answer") : L("검토 후", "After review")) · \(entry.speaker)")
                        .font(.caption.bold())
                        .foregroundColor(entry.failed ? .red : .secondary)
                    if let focus = entry.focus {
                        Text(L("대표의 논점: ", "Moderator focus: ") + focus).font(.caption).foregroundColor(.secondary)
                    }
                    Text(markdown(entry.text))
                        .textSelection(.enabled)
                        .foregroundColor(entry.failed ? .secondary : .primary)
                }
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
    var onSend: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let editor = ChatInputTextView()
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
        editor.string = text
        editor.setAccessibilityLabel(L("질문 입력", "Message"))
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ChatInputTextView else { return }
        editor.onSend = onSend
        editor.setAccessibilityLabel(L("질문 입력", "Message"))
        if editor.string != text && !editor.hasMarkedText() { editor.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineInput
        init(_ parent: MultilineInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}
