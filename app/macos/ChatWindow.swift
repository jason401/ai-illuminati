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
        // A photo dropped anywhere in the window is attached, not only on the message box.
        .onDrop(of: [UTType.fileURL, UTType.image], delegate: ImageAttachmentDropDelegate(discussion: discussion))
        .overlay {
            if discussion.imageDropActive {
                ZStack {
                    Color.accentColor.opacity(0.08)
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .padding(8)
                    Label(L("놓으면 사진이 첨부돼요", "Drop to attach photos"), systemImage: "photo.on.rectangle")
                        .font(.title3.weight(.medium))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                }
                .allowsHitTesting(false)
            }
        }
    }

    // Saved group chats, newest first. Right-click to delete.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button(action: { discussion.newConversation() }) {
                    Label(L("새 대화", "New chat"), systemImage: "square.and.pencil").frame(maxWidth: .infinity)
                }
                Menu {
                    Button(L("대화 전부 지우기…", "Delete all chats…"), role: .destructive) { discussion.deleteAll() }
                        .disabled(!discussion.conversations.contains(where: \.hasContent))
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("대화 목록 메뉴", "Chat list options"))
            }
            .disabled(discussion.running || discussion.importingMaterials)
            .padding(10)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(discussion.listedConversations) { conversation in
                        let selected = conversation.id == discussion.currentID
                        HStack(spacing: 2) {
                        Button(action: { discussion.open(conversation.id) }) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    if conversation.pinned == true {
                                        Image(systemName: "pin.fill").font(.caption2).foregroundColor(.secondary)
                                    }
                                    Text(conversation.turns.isEmpty ? L("새 대화", "New chat") : conversation.title).lineLimit(2)
                                }
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
                        .disabled(discussion.running || discussion.importingMaterials)
                        .contextMenu {
                            if conversation.hasContent {
                                Button(conversation.pinned == true ? L("고정 해제", "Unpin") : L("맨 위에 고정", "Pin to top")) { discussion.togglePin(conversation.id) }
                                Divider()
                                Button(L("대화 삭제…", "Delete chat…"), role: .destructive) { discussion.delete(conversation.id) }
                            }
                        }
                            if conversation.hasContent {
                                Menu {
                                    Button(conversation.pinned == true ? L("고정 해제", "Unpin") : L("맨 위에 고정", "Pin to top")) { discussion.togglePin(conversation.id) }
                                Divider()
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
                                .disabled(discussion.running || discussion.importingMaterials)
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
                    .disabled(discussion.running || discussion.importingMaterials)
                    Spacer(minLength: 8)
                    if discussion.configuration.mode != 3 {
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
                        .disabled(discussion.running || discussion.importingMaterials)
                        Menu {
                            Picker(L("AI 발언 길이", "Length of each AI turn"), selection: Binding(
                                get: { SpeechLength.clamp(discussion.configuration.speechLength) },
                                set: { length in discussion.configure { $0.speechLength = length } })) {
                                ForEach(SpeechLength.all, id: \.self) { length in
                                    Text(SpeechLength.name(length)).tag(length)
                                }
                            }
                            Divider()
                            Text(L("길수록 근거를 더 담지만, 뒤 발언이 앞 대화를 모두 다시 읽어 사용량이 빠르게 늘어요.",
                                   "Longer turns carry more evidence but use more, since every later turn re-reads the whole chat."))
                        } label: {
                            Text(SpeechLength.name(SpeechLength.clamp(discussion.configuration.speechLength)))
                        }
                        .fixedSize()
                        .disabled(discussion.running || discussion.importingMaterials)
                    }
                    Menu {
                        Text(L("1 토론: 대표가 논점을 맡기고 답을 정리합니다. 2 비판 토론: 반론·대안·실패 조건을 검증합니다. 3 협업: 선택 계정에 필요한 결과물 작업을 나누고 검토·통합합니다.", "1 Discussion: moderator-led discussion and synthesis. 2 Critical debate: test objections, alternatives and failure cases. 3 Collaboration: assign work to selected accounts, cross-review and integrate deliverables."))
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
                HStack {
                    Toggle(L("세션 유지 (실험)", "Keep sessions (experimental)"), isOn: Binding(
                        get: { discussion.configuration.sessionsOn },
                        set: { enabled in
                            discussion.configure { $0.keepSessions = enabled }
                            discussion.sessionNote = enabled
                                ? L("앱 전용 Claude·ChatGPT 계정을 사용합니다. 그 외 계정과 Gemini는 전체 대화 전달 방식입니다.", "Uses dedicated Claude / ChatGPT accounts. Other accounts and Gemini receive full context.")
                                : L("다음 질문부터 전체 대화를 전달합니다.", "Next question uses full context.")
                        }))
                        .toggleStyle(.switch).controlSize(.small)
                    Menu {
                        Button(L("파일 선택 (문서·슬라이드·사진)", "Choose files (documents / slides / photos)")) { discussion.chooseMaterials(folder: false) }
                        Button(L("폴더 연결 (경로만)", "Link folder (paths only)")) { discussion.chooseMaterials(folder: true) }
                        Button(L("이미지 첨부", "Attach images")) { discussion.chooseImages() }
                    } label: { Label(L("자료 추가", "Add materials"), systemImage: "folder.badge.plus") }
                    if let workspace = discussion.current.workspace {
                        Menu {
                            ForEach(workspace.roots, id: \.path) { root in
                                Button(root.path) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root.path)]) }
                            }
                            Button(L("연결 끊기", "Disconnect")) { discussion.restartRoomSessions(disconnect: true) }
                        } label: { Text(L("연결 \(workspace.roots.count)개", "\(workspace.roots.count) links")) }
                        Picker(L("권한", "Access"), selection: Binding(get: { workspace.level }, set: { discussion.setWorkspaceLevel($0) })) {
                            ForEach(WorkspaceLevel.offered, id: \.self) { Text($0.title).tag($0) }
                        }.frame(width: 145)
                    }
                    if discussion.current.workspace?.level == .execute {
                        Text(L("Gemini는 개인 권한 설정에 따라 문서 도구·명령이 거절될 수 있습니다. 앱은 개인 설정을 넓히지 않습니다.", "Gemini document tools or commands may be denied by personal permission settings; the app does not widen them."))
                            .font(.caption).foregroundColor(.secondary)
                        Text(L("실행은 각 도구의 샌드박스·계정 정책을 따릅니다. 학교 ChatGPT의 승인 요청은 자동 승인하지 않습니다.", "Execution follows each tool’s sandbox and account policy. School ChatGPT approval requests are not auto-approved."))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if discussion.current.workspace == nil, let documents = discussion.current.documents, !documents.isEmpty {
                        Menu {
                            ForEach(documents) { document in
                                Text(document.name + " · \(document.units?.count ?? 1) parts")
                                if let notice = document.notice { Text(notice) }
                            }
                            Divider()
                            Button(L("자료 연결 해제", "Disconnect materials")) {
                                discussion.restartRoomSessions(disconnect: true)
                                discussion.sessionNote = L("다음 질문은 자료 없이 새 세션에서 시작합니다.", "Next question starts a fresh session without materials.")
                            }
                        } label: { Text(L("자료 \(documents.count)개", "\(documents.count) materials")) }
                    }
                    Spacer()
                    Menu {
                        Text(L("연결은 경로만 저장합니다. 필요한 내용은 AI가 요청할 때 읽어 참여 AI 회사에 전달합니다.", "Links store paths only. Requested file contents are sent to the participating AI provider on demand."))
                        Text(L("PDF는 페이지 이미지도 읽습니다. DOCX·PPTX는 텍스트·노트·삽입 이미지를 추출하며 원래 화면 배치를 완전히 재현하지는 않습니다.", "PDF pages include rendered images. DOCX/PPTX extract text, notes and embedded images; original layouts are not fully rendered."))
                        Text(L("세션 기록은 앱 전용 계정 폴더에 저장되고, 방을 삭제하면 이 방이 만든 세션 기록과 백업도 함께 지워져요. Gemini 자체 기록은 남아요.", "Session history is kept in the app's account folders. Deleting a chat also removes the sessions and backups it created. Gemini keeps its own history."))
                        Button(L("원본 자료로 세션 다시 시작", "Restart sessions from originals")) {
                            discussion.restartRoomSessions()
                            discussion.sessionNote = L("다음 질문에서 원본 자료와 대화로 다시 시작합니다.", "Next question rebuilds sessions from source materials and conversation.")
                        }
                    } label: { Image(systemName: "info.circle") }.fixedSize()
                }.disabled(discussion.running || discussion.importingMaterials)
                if discussion.importingMaterials { ProgressView(L("자료를 가져오는 중…", "Importing materials…")).controlSize(.small) }
                if discussion.configuration.mode == 3 {
                    Text(L("선택 계정 중 필요한 AI에게 작업을 배분합니다. 한 AI가 여러 작업을 맡을 수 있고 결과는 교차 검토합니다.", "Necessary tasks go to selected accounts. One AI can do multiple tasks; results are cross-reviewed.")).font(.caption).foregroundColor(.secondary)
                }
                if !discussion.sessionNote.isEmpty {
                    Text(discussion.sessionNote).font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
                if discussion.configuration.mode == 3 {
                    collaborationControls
                } else {
                    sequentialControls
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
                            Text(L("자료를 연결하고 협업 참여 계정을 선택하세요. 보기에서는 읽기만, 작성에서는 자동 백업 후 파일을 고치고 결과물을 만듭니다.", "Link materials and select collaboration accounts. View only reads; Write backs up linked files before editing and creating deliverables."))
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
                            if index > 0, (turn.mode ?? 1) != (conversation.turns[index - 1].mode ?? 1) || turn.modeVersion != conversation.turns[index - 1].modeVersion {
                                ModeChangeMarker(mode: turn.mode ?? 1, version: turn.modeVersion)
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
                    Text(discussion.configuration.mode == 3
                         ? L("그림은 Claude·ChatGPT가 읽고, Gemini에는 근거 메모를 공유합니다.", "Claude/ChatGPT read images; Gemini receives their evidence notes.")
                         : L("사진과 AI가 그린 그림은 참여한 모든 AI에게 전달돼요(Gemini는 파일로 봐요).", "Photos and pictures the AIs drew go to every participating AI (Gemini reads them as files)."))
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
                                        .disabled(discussion.running || discussion.importingMaterials)
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
                    .disabled(discussion.running || discussion.importingMaterials)
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
                    Text(L("Enter: 전송 · Shift+Enter: 줄바꿈", "Enter: send · Shift+Enter: new line"))
                    Spacer()
                    if discussion.running {
                        Text(discussion.stopping ? L("중지 중…", "Stopping…") : L("답변 중", "Responding"))
                    }
                }
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    @ViewBuilder private var composerAction: some View {
        if discussion.running && discussion.debateCancellation != nil {
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
            .help(L("전송 (Enter)", "Send (Enter)"))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!discussion.canSend)
        }
    }

    private var collaborationControls: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack {
                ForEach(discussion.model.accounts, id: \.id) { account in
                    HStack(spacing: 3) {
                        Toggle(discussion.label(account), isOn: Binding(
                            get: { discussion.configuration.accountIDs?.contains(account.id) ?? false },
                            set: { enabled in discussion.configure { config in
                                var selected = config.accountIDs ?? []
                                selected.removeAll { $0 == account.id }
                                if enabled { selected.append(account.id) }
                                config.accountIDs = selected
                            } }))
                        Button(action: { discussion.configure { $0.leaderAccountID = account.id; $0.leader = account.provider } }) {
                            Image(systemName: discussion.configuration.leaderAccountID == account.id ? "crown.fill" : "crown")
                        }.buttonStyle(.plain).help(L("대표로 지정", "Make moderator"))
                    }.padding(5).background(Color.secondary.opacity(0.1)).cornerRadius(6)
                }
            }.toggleStyle(.checkbox)
        }.disabled(discussion.running || discussion.importingMaterials)
    }

    private var sequentialControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(discussion.configuration.order, id: \.rawValue) { provider in
                    HStack(spacing: 3) {
                        Toggle(provider.title, isOn: Binding(
                            get: { discussion.configuration.participants.contains(provider) },
                            set: { discussion.setParticipation(provider, enabled: $0) }))
                        Menu {
                            Button(L("대표로 지정", "Make moderator")) {
                                discussion.configure { $0.leader = provider }
                            }
                            .disabled(!discussion.configuration.participants.contains(provider))
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
        .disabled(discussion.running || discussion.importingMaterials)
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
    var version: Int? = 2

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
            Text(L("\(Self.display(mode, version))(으)로 바뀜", "Switched to \(Self.display(mode, version))"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize()
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
        }
    }

    static func display(_ mode: Int, _ version: Int?) -> String {
        guard version != 2 else { return name(mode) }
        return L("이전 모드 \(mode)", "Legacy mode \(mode)")
    }

    static func name(_ mode: Int) -> String {
        switch mode {
        case 3: return L("모드3 · 협업", "Mode 3 · Collaboration")
        case 2: return L("모드2 · 비판 토론", "Mode 2 · Critical debate")
        default: return L("모드1 · 토론", "Mode 1 · Discussion")
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
            if (turn.modeVersion == 2 && turn.mode != 3) || (turn.modeVersion == nil && turn.mode == 3) {
                Text(L("AI 발언 \(turn.entries.count)/\(turn.maxTurns ?? 9)", "AI turns \(turn.entries.count)/\(turn.maxTurns ?? 9)")
                     + (turn.turnsPerAI.map { L(" (AI마다 \($0)회)", " (\($0) each)") } ?? ""))
                    .font(.caption).foregroundColor(.secondary)
                if let focus = turn.debateFocus { Text(L("다음 논점: ", "Next focus: ") + focus).font(.callout).lineLimit(2).foregroundColor(.secondary) }
                if let reason = turn.endReason { Text(L("종료 이유: ", "End reason: ") + reason).font(.callout).foregroundColor(.secondary) }
            }
            if turn.modeVersion == 2 && turn.mode == 3, let coverage = turn.endReason {
                Text(coverage).font(.caption).foregroundColor(.secondary)
            }
            if let changes = turn.workspaceChanges {
                DisclosureGroup(L("실제 변경 파일 \(changes.count)개", "\(changes.count) changed files")) {
                    ForEach(changes) { change in
                        HStack {
                            Text(change.kind + " · " + change.path).font(.caption).textSelection(.enabled)
                            Spacer()
                            if change.kind != "deleted" { Button(L("파일 열기", "Open file")) { discussion.openArtifact(change.path) } }
                            Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: change.path)]) }
                        }
                    }
                }
            }
            if turn.backupPath != nil {
                Button(turn.undone == true ? L("되돌림 완료", "Restored") : L("되돌리기", "Undo file changes")) { discussion.undoWorkspace(turn) }
                    .disabled(turn.undone == true || discussion.running || discussion.importingMaterials)
            }
            if let tasks = turn.tasks {
                DisclosureGroup(L("작업 \(tasks.filter { $0.state == "done" }.count)/\(tasks.count) 완료 · 진행 \(tasks.filter { $0.state == "running" }.count)", "Tasks \(tasks.filter { $0.state == "done" }.count)/\(tasks.count) complete · \(tasks.filter { $0.state == "running" }.count) running")) {
                ForEach(tasks) { task in
                    HStack(alignment: .top) {
                        Image(systemName: task.state == "done" ? "checkmark.circle" : task.state == "running" ? "clock" : "circle")
                        VStack(alignment: .leading) {
                            Text(task.title).font(.callout).lineLimit(3)
                            Text((discussion.model.accounts.first { $0.id == task.accountID }.map { discussion.label($0) } ?? task.accountID) + " · " + task.state).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if let path = task.output { Button(L("결과 열기", "Open result")) { discussion.openArtifact(path) } }
                    }
                }
            }
            }
            if let file = turn.artifact { Button(L("최종 결과물 열기", "Open final deliverable")) { discussion.openArtifact(file) } }
            if let final = turn.final {
                VStack(alignment: .leading, spacing: 6) {
                    Text(markdown(final))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    let pictures = Self.finalPictures(turn, final: final)
                    if !pictures.isEmpty { PictureStrip(images: pictures, size: 180) }
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
                if turn.modeVersion == 2 && turn.mode == 3 {
                    DisclosureGroup(L("작업 발언 보기 (\(turn.entries.count))", "View task messages (\(turn.entries.count))")) { entriesView }
                } else if turn.modeVersion == 2 || (turn.mode ?? 1) >= 2 {
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
                         label: (turn.modeVersion == 2 || (turn.mode ?? 1) >= 2) ? entry.speaker : "\(entry.round == 1 ? L("각자 답", "Initial answer") : L("검토 후", "After review")) · \(entry.speaker)")
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // The final answer's own pictures, plus the team's pictures it names ([그림 2] / [Picture 2]).
    static func finalPictures(_ turn: ChatTurn, final: String) -> [ChatImage] {
        var pictures = turn.finalImages ?? []
        let regex = try! NSRegularExpression(pattern: "\\[(?:그림|Picture) (\\d+)\\]")
        let ns = final as NSString
        let named = regex.matches(in: final, range: NSRange(location: 0, length: ns.length)).map { "picture-" + ns.substring(with: $0.range(at: 1)) + ".png" }
        for name in named {
            if let image = turn.entries.flatMap({ $0.images ?? [] }).first(where: { $0.name == name }),
               !pictures.contains(where: { $0.id == image.id }) { pictures.append(image) }
        }
        return pictures
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

    // Like chat apps: Return sends, Shift+Return (or Option+Return) starts a new line; ⌘Return also
    // sends. While Korean (or other) text is still being composed, Return only finishes the character.
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76) && !hasMarkedText() {
            let flags = event.modifierFlags
            if flags.contains(.shift) || flags.contains(.option) {
                insertText("\n", replacementRange: selectedRange())
            } else {
                onSend?()
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

// Pictures an AI made: a row of thumbnails, each opening full size in Preview.
private struct PictureStrip: View {
    let images: [ChatImage]
    let size: CGFloat
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { item in
                    Button(action: { NSWorkspace.shared.open(item.url) }) {
                        AttachmentThumbnail(item: item, size: size)
                    }
                    .buttonStyle(.plain)
                    .help(item.name)
                    .accessibilityLabel(L("그림 열기: ", "Open picture: ") + item.name)
                }
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
    func validateDrop(info: DropInfo) -> Bool { !discussion.running && info.hasItemsConforming(to: [UTType.fileURL, UTType.image]) }
    func dropEntered(info: DropInfo) { discussion.imageDropActive = validateDrop(info: info) }
    func dropExited(info: DropInfo) { discussion.imageDropActive = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: validateDrop(info: info) ? .copy : .forbidden) }
    func performDrop(info: DropInfo) -> Bool {
        discussion.imageDropActive = false
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
            if let images = entry.images, !images.isEmpty {
                PictureStrip(images: images, size: 110)
            }
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
