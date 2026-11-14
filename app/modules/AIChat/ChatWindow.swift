import Cocoa
import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import AIAccounts
import AILocalization
import AIRuntime
import AIWorkspace
import AIProjects

// The chat window: pick which AIs take part, ask, and get one final answer. What the AIs said to
// each other (own answers, then reviews) is folded under the answer.
// The window's sizes (ChatView is generic over the app's settings, which holds no stored statics).
enum ChatViewSize {
    // Smallest window: room for the chat or the TODO board (its rows fold onto more lines) on their own. The sidebar
    // sits beside them only while they keep that width (`sidebarFits`); narrower, it slides over them.
    static let minSize = NSSize(width: 560, height: 480)
    static let sidebarWidth: CGFloat = 250
    static let sidebarFits = sidebarWidth + 1 + minSize.width
    // The notes sit beside a chat that keeps at least this much.
    static let wide: CGFloat = 700
    static let notesWidth: CGFloat = 280
    static let bottomSlack: CGFloat = 80
    static let bottomID = "transcript-bottom"
}

struct ChatView<Model: ChatSettings>: View {
    @ObservedObject var discussion: Discussion
    @ObservedObject var model: Model


    // Which side panels fit. Kept apart from the window size so resizing rebuilds the views only when one
    // of these changes, not on every frame of the drag.
    @ObservedObject private var layout = ChatLayout.shared
    @ObservedObject private var sync = DeviceSync.shared
    @ObservedObject private var approvals = ProjectCenter.shared
    @ObservedObject private var folds = SidebarFold.shared
    @ObservedObject private var todos = TodoStore.shared
    @ObservedObject private var projectInfo = ProjectInfoStore.shared
    @ObservedObject private var photo = PhotoViewer.shared

    var body: some View {
        let wide = layout.wide
        // ⌘F: find in the open chat (again: back to the words).
        let findKey = Button("") { discussion.findOpen = true; discussion.findFocus += 1 }
            .keyboardShortcut("f", modifiers: .command).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        let inline = wide && !discussion.sidebarHidden
        // The notes sit beside the chat when it keeps at least `wide` points, else they slide over it.
        let notesInline = inline ? layout.notesFit : layout.notesFitAlone
        // Notes belong to a chat: a project folder (board or info) or another Mac's chat hides them, and they come
        // back when a chat of this Mac is open again.
        let notesShown = discussion.notesShown && !discussion.viewingBoard && discussion.viewingRemote == nil && discussion.viewingSpace == nil
        // A clicked photo is shown large over the whole window until it is closed.
        let photoShown = photo.image != nil && !discussion.viewingBoard && discussion.viewingSpace == nil
        Group {
            ZStack(alignment: .leading) {
                findKey
                HStack(spacing: 0) {
                    if inline {
                        sidebar
                        Divider().opacity(0.5)
                    }
                    // Never wider than what is left: something too wide is cut on the right, the sidebar stays whole.
                    chat(sidebarShown: inline, wide: wide)
                        .frame(minWidth: 0, maxWidth: .infinity).clipped()
                    if notesShown && notesInline {
                        Divider().opacity(0.5)
                        NotesPanel(room: discussion.currentID) { discussion.notesShown = false }
                    }
                }
                if notesShown && !notesInline {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        NotesPanel(room: discussion.currentID) { discussion.notesShown = false }
                            .background(Color(nsColor: .windowBackgroundColor))
                            .shadow(color: .black.opacity(0.25), radius: 12)
                    }
                }
                if !wide && discussion.sidebarOverlay {
                    // Click outside to close, like the desktop apps.
                    Color.black.opacity(0.18).contentShape(Rectangle())
                        .onTapGesture { discussion.sidebarOverlay = false }
                    sidebar
                        .background(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.25), radius: 12)
                }
                if photoShown, let image = photo.image {
                    PhotoOverlay(item: image) { photo.image = nil }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { layout.measure(geometry.size.width) }
                .onChange(of: geometry.size.width) { layout.measure($0) }
        })
        .onAppear {
            let chats = discussion
            PhotoViewer.shared.chatTitle = { [weak chats] id in chats?.conversations.first { $0.id == id }?.title }
        }
        .onChange(of: discussion.currentID) { _ in discussion.sidebarOverlay = false; photo.image = nil }
        // Leaving the chat (another Mac's chat, the board or a Space) closes the photo, so it does not come back later.
        .onChange(of: discussion.viewingRemote == nil) { _ in photo.image = nil }
        .onChange(of: discussion.viewingBoard) { _ in photo.image = nil }
        .onChange(of: discussion.viewingSpace == nil) { _ in photo.image = nil }
        .frame(minWidth: ChatViewSize.minSize.width, minHeight: ChatViewSize.minSize.height)
        .background(Color(nsColor: .textBackgroundColor))
        // A photo dropped anywhere in the window is attached, not only on the message box.
        .onDrop(of: [UTType.fileURL, UTType.image, UTType.item], delegate: ImageAttachmentDropDelegate(discussion: discussion))
        .overlay {
            if discussion.imageDropActive {
                ZStack {
                    Color.accentColor.opacity(0.08)
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .padding(8)
                    Label(L("놓으면 파일이 첨부돼요", "Drop to attach files"), systemImage: "paperclip")
                        .font(.title3.weight(.medium))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                }
                .allowsHitTesting(false)
            }
        }
    }

    // Like the Claude and ChatGPT apps: New chat and Search on top, shared folders, then pinned and recent
    // chats as single lines. Right-click (or ⋯ on hover) to pin or delete.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The title bar above is macOS's own; it moves the window (no drag view of ours there).
            Color.clear.frame(height: 16)
            VStack(alignment: .leading, spacing: 1) {
                SidebarRow(discussion: discussion, title: L("새 대화", "New chat"), symbol: "square.and.pencil") { discussion.newConversation() }
                    .contextMenu { EnterpriseLockButtons(discussion: discussion, room: nil) }
                if discussion.sidebarSearching {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundColor(.secondary).frame(width: 18)
                        TextField(L("대화 검색", "Search chats"), text: $discussion.sidebarSearch).textFieldStyle(.plain)
                        Button(action: {
                            discussion.sidebarSearching = false; discussion.sidebarSearch = ""
                            discussion.searchSide = .all; discussion.searchKind = .all
                        }) { Image(systemName: "xmark.circle.fill").frame(width: 22, height: 22) }
                            .buttonStyle(.plainHit).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    ChatSearchFilters(discussion: discussion)
                } else {
                    SidebarRow(discussion: discussion, title: L("검색", "Search"), symbol: "magnifyingglass") { discussion.sidebarSearching = true }
                }
            }
            .padding(.horizontal, 10)
            // Other chats stay usable while one answers (Discussion.maxRunning at once).
            .disabled(discussion.importingMaterials)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    sharedFolders
                    ChatApp.screens.drive().disabled(discussion.importingMaterials)
                    // A new chat with nothing in it yet is not listed (like the desktop apps); it appears once it has a message.
                    // Searching: the filters apply, and words find chats by their messages and answers too.
                    let chats = discussion.listedConversations.filter {
                        $0.hasContent && (!discussion.sidebarSearching || ChatSearch.passes($0, side: discussion.searchSide, kind: discussion.searchKind))
                    }
                    let query = discussion.sidebarSearching ? discussion.sidebarSearch.trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    if !query.isEmpty {
                        let results = ChatSearch.search(query, in: chats)
                        SidebarHeader(title: L("검색 결과", "Results"))
                        if results.isEmpty {
                            Text(L("찾은 대화가 없어요", "No chats found")).font(.system(size: 12)).foregroundColor(.secondary).padding(.horizontal, 10)
                        }
                        ForEach(results) { result in
                            ChatSearchRow(result: result, conversation: chats.first { $0.id == result.id },
                                          selected: result.id == discussion.currentID && discussion.viewingRemote == nil,
                                          hovered: discussion.hoverKey == "search." + result.id.uuidString)
                                .onTapGesture { discussion.openResult(result) }
                                .onHover { inside in discussion.hover("search." + result.id.uuidString, inside) }
                                .help(dateText(result.updatedAt))
                                .disabled(discussion.importingMaterials)
                        }
                    } else {
                        // Chats with a Git project under its folder (SidebarProjects.swift); the rest pinned or recent.
                        let grouped = SidebarProjects.group(chats, todo: todos.snapshot, pinned: folds.pinnedProjects, withLists: !discussion.sidebarSearching,
                                                             names: projectInfo.names)
                        SidebarHeader(title: L("프로젝트", "Projects"), fold: "projects", badge: todos.waitingForUser) { addProjectMenu }
                        if !folds.isFolded("projects") { ChatApp.screens.boardRow(discussion) }
                        if folds.isFolded("projects") {
                        } else if grouped.projects.isEmpty {
                            Button(action: { discussion.linkProjectFromSidebar() }) {
                                Label(L("프로젝트 추가", "Add a project"), systemImage: "folder.badge.plus")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                    .padding(.horizontal, 10).frame(height: 28, alignment: .leading)
                            }
                            .buttonStyle(.plainHit).disabled(discussion.running || discussion.importingMaterials)
                        } else {
                            ForEach(grouped.projects) { projectGroup($0) }
                        }
                        if !discussion.sidebarSearching { SpaceSidebarSection(discussion: discussion) }
                        let pinned = grouped.loose.filter { $0.pinned == true }
                        if !pinned.isEmpty {
                            SidebarHeader(title: L("고정됨", "Pinned"), fold: "pinned")
                            if !folds.isFolded("pinned") { ForEach(pinned) { chatGroup($0) } }
                        }
                        let recents = grouped.loose.filter { $0.pinned != true }
                        if !recents.isEmpty {
                            SidebarHeader(title: L("최근", "Recents"), fold: "recents")
                            if !folds.isFolded("recents") {
                                // The newest page (and the open chat, or the chat of the open meeting); every match while searching or filtering.
                                let page = SidebarFold.recentsPage
                                let open = discussion.viewingRemote == nil && !discussion.viewingBoard ? discussion.current.meetingOf?.room ?? discussion.currentID : nil
                                let listed = discussion.sidebarSearching ? recents : SidebarFold.listed(recents, limit: folds.limit("recents", page: page), open: open)
                                ForEach(listed) { chatGroup($0) }
                                if !discussion.sidebarSearching { moreRow("recents", page: page, total: recents.count, listed: listed.count) }
                            }
                        }
                    }
                    if sync.settings.enabled { otherMacs }
                }
                .padding(.horizontal, 10).padding(.bottom, 12)
            }
            Spacer(minLength: 0)
            HStack {
                Menu {
                    Button(L("대화 전부 지우기…", "Delete all chats…"), role: .destructive) { discussion.deleteAll() }
                        .disabled(!discussion.conversations.contains(where: \.hasContent) || discussion.anyRunning)
                } label: {
                    Label(L("대화 관리", "Manage chats"), systemImage: "ellipsis.circle").font(.system(size: 12))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .disabled(discussion.importingMaterials)
        }
        .frame(width: ChatViewSize.sidebarWidth)
        .background(Color.primary.opacity(0.035))
    }

    // Projects header +: make a new Git project or an empty one, or link an existing folder (Git → code project, otherwise documents).
    private var addProjectMenu: some View {
        Menu {
            Button(L("빈 프로젝트… (Git·기존 폴더 없이)", "Empty project… (no Git, no existing folder)")) { discussion.newEmptyProject() }
            Button(L("새 프로젝트… (Git·GitHub)", "New project… (Git and GitHub)")) { discussion.newProjectFromMenu() }
            Button(L("기존 폴더 연결… (Git 저장소 또는 문서 폴더)", "Link a folder… (Git repository or documents)")) { discussion.linkProjectFromSidebar() }
        } label: {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundColor(.secondary)
        .help(L("프로젝트 추가", "Add a project"))
        .accessibilityLabel(L("프로젝트 추가", "Add project"))
        .disabled(discussion.running || discussion.importingMaterials)
    }

    // The same items in the ⋯ menu and on right-click.
    @ViewBuilder private func chatMenu(_ conversation: Conversation) -> some View {
        Button(L("이름 바꾸기…", "Rename…")) { discussion.rename(conversation.id) }
        if conversation.isProjectChat {
            Button(conversation.pinned == true ? L("고정 해제", "Unpin") : L("프로젝트 안에서 맨 위에 고정", "Pin to the top of its project")) { discussion.togglePin(conversation.id) }
        } else {
            Button(conversation.pinned == true ? L("고정 해제", "Unpin") : L("맨 위에 고정", "Pin to top")) { discussion.togglePin(conversation.id) }
        }
        moveMenu(conversation)
        if let todo = Discussion.todoToFinish(room: conversation.id, in: todos.snapshot) {
            Button(L("완료로 표시", "Mark as done")) { discussion.markTodoDone(todo.id) }
        }
        Button(L("이 대화 폴더 열기", "Show this chat's folder")) { discussion.openChatFolder(conversation.id) }
        if sync.settings.enabled && !sync.settings.shareAll {
            Button(conversation.shareToDevices == true ? L("다른 기기에서 숨기기", "Hide on other Macs") : L("다른 기기에 보이기", "Show on other Macs")) {
                discussion.toggleShareToDevices(conversation.id)
            }
        }
        Divider()
        Button(L("대화 삭제…", "Delete chat…"), role: .destructive) { discussion.delete(conversation.id) }
            .disabled(discussion.runningRooms.contains(conversation.id))
    }

    // The same as dragging the chat onto a project folder: the projects it can go into.
    @ViewBuilder private func moveMenu(_ conversation: Conversation) -> some View {
        let projects = SidebarProjects.group(discussion.listedConversations.filter(\.hasContent), todo: todos.snapshot, pinned: folds.pinnedProjects,
                                             names: projectInfo.names).projects
        let targets = projects.filter {
            SidebarProjects.moveRefusal(conversation, into: $0, todo: todos.snapshot, running: false, mode: discussion.configuration(of: conversation.id).mode) == nil
        }
        if !targets.isEmpty {
            Menu(L("프로젝트로 옮기기", "Move to project")) {
                ForEach(targets) { group in Button(group.name) { discussion.moveChat(conversation.id, into: group) } }
            }
            .disabled(discussion.runningRooms.contains(conversation.id))
        }
    }

    // A chat that may be dragged onto a project folder: not a TODO's chat (it stays with its TODO).
    private func draggable(_ conversation: Conversation, todo: TodoItem.State?) -> Bool {
        conversation.hasContent && todo == nil && conversation.meetingOf == nil && !todos.snapshot.items.contains { $0.room == conversation.id }
    }

    // A chat dragged over a project folder outlines it; dropped, the chat joins the project (unfolded to show it).
    private func dropTargeted(_ project: String) -> Binding<Bool> {
        Binding(get: { folds.dropProject == project },
                set: { inside in
                    if inside { folds.dropProject = project } else if folds.dropProject == project { folds.dropProject = nil }
                })
    }
    private func dropChat(_ providers: [NSItemProvider], into group: ProjectGroup) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        let key = "project." + group.id
        _ = provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let text = item as? String, text.hasPrefix(SidebarProjects.dragPrefix),
                  let id = UUID(uuidString: String(text.dropFirst(SidebarProjects.dragPrefix.count))) else { return }
            DispatchQueue.main.async {
                if discussion.moveChat(id, into: group), folds.isFolded(key) { folds.toggle(key) }
            }
        }
        return true
    }

    // A project folder: click to open its TODO board, double-click or the chevron to fold or unfold, + for a new chat in it,
    // right-click to pin. Inside: the chats answering now, the chats its TODOs still work in, then its chats (each with its meetings), then finished TODOs.
    @ViewBuilder private func projectGroup(_ group: ProjectGroup) -> some View {
        let open = !folds.isFolded("project." + group.id)
        projectRow(group, open: open)
        if open {
            // Chats answering now come first, then TODO chats still going, so the work running now is in sight right away.
            let rooms = SidebarProjects.runningFirst(group, todo: todos.snapshot, running: discussion.runningRooms)
            let todoIDs = Set(group.todoRooms.map(\.id))
            ForEach(rooms.running) { room in
                if todoIDs.contains(room.id) { todoRoom(room) } else { chatGroup(room, depth: 1) }
            }
            ForEach(rooms.going) { todoRoom($0) }
            // Its own chats: pinned ones and the newest page (and the open chat); every match while searching.
            let key = "project-chats." + group.id, page = SidebarFold.projectPage
            let current = discussion.viewingRemote == nil && !discussion.viewingBoard ? discussion.current.meetingOf?.room ?? discussion.currentID : nil
            let chats = SidebarFold.listedChats(rooms.chats, limit: discussion.sidebarSearching ? .max : folds.limit(key, page: page), open: current)
            ForEach(chats.rows) { chatGroup($0, depth: 1) }
            if !discussion.sidebarSearching { moreRow(key, page: page, total: chats.unpinned, listed: chats.listed, indent: 22) }
            if !rooms.finished.isEmpty {
                // Searching lists every match; folded, only the chat open now (or the one whose meeting is open) stays.
                let unfolded = folds.openFinished.contains(group.id) || discussion.sidebarSearching
                finishedRow(group, finished: rooms.finished, open: unfolded)
                ForEach(unfolded ? rooms.finished : rooms.finished.filter { room in
                    room.id == discussion.currentID || discussion.meetings(of: room.id).contains { $0.id == discussion.currentID }
                }) { todoRoom($0) }
            }
        }
    }

    private func todoRoom(_ room: Conversation) -> some View {
        chatGroup(room, depth: 1, todo: todos.snapshot.items.first { $0.room == room.id }?.state)
    }

    // The fold row of a project's finished TODO chats.
    // Right-click: permanently delete the old ones or all (not while searching: the list then holds only the matches).
    private func finishedRow(_ group: ProjectGroup, finished: [Conversation], open: Bool) -> some View {
        let count = finished.count
        let key = "finished." + group.id
        let hovered = discussion.hoverKey == key
        return HStack(spacing: 5) {
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundColor(.secondary)
                .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 14)
            Image(systemName: "checkmark.circle").font(.system(size: 10)).foregroundColor(.secondary).frame(width: 14)
            Text(L("끝난 TODO", "Finished TODOs")).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text("\(count)").font(.system(size: 10)).foregroundColor(.secondary)
        }
        .font(.system(size: 12)).foregroundColor(.secondary)
        .padding(.leading, 22).padding(.trailing, 10).frame(height: 26)
        .background(hovered ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { folds.toggleFinished(group.id) }
        .onHover { inside in discussion.hover(key, inside) }
        .contextMenu {
            if !discussion.sidebarSearching {
                let protected = discussion.runningRooms.union([discussion.currentID] + [discussion.current.meetingOf?.room].compactMap { $0 })
                let old = SidebarProjects.deletable(finished, todo: todos.snapshot, meetings: { discussion.meetings(of: $0) },
                                                    before: Date().addingTimeInterval(-30 * 86400), protected: protected).count
                let all = SidebarProjects.deletable(finished, todo: todos.snapshot, protected: protected).count
                Button(L("30일 지난 채팅 영구 삭제… (\(old)개)", "Delete chats older than 30 days… (\(old))")) {
                    discussion.deleteFinishedTodoChats(finished, olderThan: 30)
                }.disabled(old == 0)
                Button(L("끝난 TODO 채팅 모두 영구 삭제… (\(all)개)", "Delete all finished TODO chats… (\(all))")) {
                    discussion.deleteFinishedTodoChats(finished, olderThan: nil)
                }.disabled(all == 0)
                Divider()
                Text(L("TODO 기록은 할 일 보드에 남아요. 고정한 채팅은 빼요.", "The TODOs stay on the board. Pinned chats are kept."))
            }
        }
        .help(open ? L("끝난 TODO 채팅 접기", "Fold the finished TODO chats") : L("끝난 TODO 채팅 펼치기", "Unfold the finished TODO chats"))
    }

    private func projectRow(_ group: ProjectGroup, open: Bool) -> some View {
        let key = "project." + group.id
        let hovered = discussion.hoverKey == key
        let rooms = Set((group.chats + group.todoRooms).map(\.id))
        let waiting = SidebarProjects.waiting(todos.snapshot, lists: group.lists)
        let selected = discussion.viewingBoard && discussion.boardProject == group.id
        let todoCount = todos.snapshot.items.filter { group.lists.contains($0.listID) && $0.state != .done && $0.state != .cancelled }.count
        return HStack(spacing: 5) {
            Button(action: { folds.toggle(key) }) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundColor(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 22, height: 22)
            }
            .buttonStyle(.plainHit).padding(.leading, -6).padding(.trailing, -6)
            .help(open ? L("접기", "Fold") : L("펼치기", "Unfold"))
            Image(systemName: open ? "folder" : "folder.fill").font(.system(size: 12)).foregroundColor(.secondary).frame(width: 16)
            Text(group.name).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            LockBadge(lock: SidebarProjects.lock(of: group, todo: todos.snapshot))
            if group.pinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundColor(.secondary).help(L("고정된 프로젝트", "Pinned project")) }
            if waiting > 0 {
                Text("\(waiting)").font(.system(size: 10, weight: .semibold)).foregroundColor(.white)
                    .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16).background(Color.orange, in: Capsule())
                    .help(L("네 결정이나 확인을 기다리는 TODO", "TODOs waiting for your decision or check"))
            }
            // Folded: what is going on inside still shows.
            if !open {
                if approvals.requests.contains(where: { rooms.contains($0.room) }) {
                    Circle().fill(Color.orange).frame(width: 7, height: 7).help(L("허가를 기다려요", "Waiting for approval"))
                }
            }
            // Open or folded: a chat of it answering shows a spinner by the folder.
            if !discussion.runningRooms.isDisjoint(with: rooms) { ProgressView().controlSize(.mini).help(L("이 프로젝트의 채팅이 답하는 중", "A chat of this project is answering")) }
            if hovered, let binding = group.bindings.first {
                Button(action: { newChat(in: group, binding) }) { Image(systemName: "square.and.pencil").font(.system(size: 11)).frame(width: 20, height: 20) }
                    .buttonStyle(.plainHit).foregroundColor(.secondary)
                    .help(L("이 프로젝트에 새 대화", "New chat in this project"))
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 10).frame(height: 30)
        .background(selected ? Color.primary.opacity(0.10) : hovered ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
        // A chat dragged over it: outlined; dropped, it joins this project.
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2).opacity(folds.dropProject == group.id ? 1 : 0))
        .contentShape(Rectangle())
        .onDrop(of: [UTType.text], isTargeted: dropTargeted(group.id)) { providers in dropChat(providers, into: group) }
        // A click opens its board and leaves the fold alone; a double click (or the chevron) folds or unfolds it.
        .onTapGesture(count: 2) {
            if !selected { discussion.openBoard(project: group.id) }
            folds.toggle(key)
        }
        .onTapGesture { if !selected { discussion.openBoard(project: group.id) } }
        .onHover { inside in discussion.hover(key, inside) }
        .help((group.bindings.map(\.root) + [todoCount > 0 ? L("눌러서 프로젝트 정보·할 일 보드 (할 일 \(todoCount))", "Click for the project info and TODO board (\(todoCount) TODOs)")
                                                             : L("눌러서 프로젝트 정보·할 일 보드", "Click for the project info and TODO board")]).joined(separator: "\n"))
        .contextMenu {
            if let binding = group.bindings.first { Button(L("이 프로젝트에 새 대화", "New chat in this project")) { newChat(in: group, binding) } }
            Button(L("프로젝트 정보", "Project info")) { discussion.openBoard(project: group.id, tab: .info) }
            Button(L("할 일 보드", "TODO board")) { discussion.openBoard(project: group.id, tab: .todo) }
            Button(L("이름 바꾸기…", "Rename…")) { ChatApp.screens.renameProject(group.id, group.name) }
            Button(group.pinned ? L("프로젝트 고정 해제", "Unpin project") : L("프로젝트 맨 위에 고정", "Pin project to top")) { folds.togglePin(group.id) }
            if let lock = SidebarProjects.lock(of: group, todo: todos.snapshot) {
                Text(lock.isPersonal ? L("🔒 개인 프로젝트 (해제할 수 없어요)", "🔒 Personal project (cannot be undone)")
                                     : L("🔒 \(lock.name) Enterprise 프로젝트 (해제할 수 없어요)", "🔒 \(lock.name) Enterprise project (cannot be undone)"))
                let left = discussion.unlockedParts(group.id, todos: todos.snapshot)
                if left.chats + left.lists > 0 {
                    Button(L("안 잠긴 대화·TODO도 잠그기…", "Lock Its Unlocked Chats and TODOs…")) {
                        discussion.askToLockProject(group.id, name: group.name, organization: lock)
                    }
                    .disabled(!discussion.runningRooms.isDisjoint(with: (group.chats + group.todoRooms).map(\.id)) || discussion.importingMaterials)
                }
            } else {
                EnterpriseLockButtons(discussion: discussion, room: nil, project: group)
            }
            if let binding = group.bindings.first, !binding.isFolderless {
                Button(L("Finder에서 열기", "Open in Finder")) { NSWorkspace.shared.open(URL(fileURLWithPath: binding.root)) }
            }
            Divider()
            if !group.bindings.isEmpty, !group.bindings.contains(where: \.isFolderless) {
                Button(L("작업 폴더 연결 끊기…", "Disconnect Work Folder…")) { discussion.disconnectProjectFolder(group.id, name: group.name) }
            }
            Button(L("프로젝트 삭제…", "Delete Project…")) { discussion.deleteProject(group.id, name: group.name) }
        }
        .disabled(discussion.importingMaterials)
    }

    // A new chat linked to the project's newest root, locked like its chats or its TODO lists when they are locked
    // (a project may have only a locked list left).
    private func newChat(in group: ProjectGroup, _ binding: ProjectBinding) {
        let lock = SidebarProjects.lock(of: group, todo: todos.snapshot)
        discussion.addProjectChat(binding, title: L("새 대화", "New chat"), open: true, lock: lock)
        if folds.isFolded("project." + group.id) { folds.toggle("project." + group.id) }
    }

    // A chat and, under it, the meetings held for it (Meeting.swift): the newest 5 until "show all".
    // depth 1: inside a project folder. todo: the state of the TODO this chat works on.
    @ViewBuilder private func chatGroup(_ conversation: Conversation, depth: Int = 0, todo: TodoItem.State? = nil) -> some View {
        let meetings = discussion.meetings(of: conversation.id)
        let shown = !meetings.isEmpty && discussion.meetingsShown(conversation.id, meetings)
        chatRow(conversation, meetings: meetings.count, shown: shown, depth: depth, todo: todo)
        if shown {
            let all = discussion.meetingsAll.contains(conversation.id)
            // The open meeting stays listed even when it is older than the newest 5.
            let listed = all ? meetings : meetings.enumerated().filter { $0.offset < 5 || $0.element.id == discussion.currentID }.map(\.element)
            ForEach(listed) { meetingRow($0, depth: depth) }
            if meetings.count > 5 && !all {
                Button(L("전체 보기 (\(meetings.count))", "Show all (\(meetings.count))")) { discussion.meetingsAll.insert(conversation.id) }
                    .buttonStyle(.link).font(.system(size: 11)).padding(.leading, 34 + CGFloat(depth) * 12).frame(height: 22)
            }
        }
    }

    // A meeting held for the chat above: its topic and when (its chat is read only).
    private func meetingRow(_ meeting: Conversation, depth: Int = 0) -> some View {
        let selected = meeting.id == discussion.currentID && discussion.viewingRemote == nil && discussion.viewingSpace == nil
        let key = "meeting." + meeting.id.uuidString
        let hovered = discussion.hoverKey == key
        return HStack(spacing: 5) {
            Image(systemName: "person.3").font(.system(size: 9)).foregroundColor(.secondary).frame(width: 18)
            Text(meeting.turns.first?.question ?? meeting.title).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if discussion.meetingRunning(meeting) {
                ProgressView().controlSize(.mini).help(L("회의 중", "Meeting"))
            } else {
                Text(dateText(meeting.createdAt)).font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
        .font(.system(size: 12))
        .padding(.leading, 24 + CGFloat(depth) * 12).padding(.trailing, 10).frame(height: 26)
        .background(selected ? Color.primary.opacity(0.10) : hovered ? Color.primary.opacity(0.05) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { discussion.open(meeting.id) }
        .onHover { inside in discussion.hover(key, inside) }
        .help(meeting.title)
        .disabled(discussion.importingMaterials)
    }

    private func chatRow(_ conversation: Conversation, meetings: Int = 0, shown: Bool = false, depth: Int = 0, todo: TodoItem.State? = nil) -> some View {
        let selected = conversation.id == discussion.currentID && discussion.viewingRemote == nil && !discussion.viewingBoard && discussion.viewingSpace == nil
        let hovered = discussion.hoverKey == conversation.id.uuidString
        let todoPrefix = "TODO · "
        return HStack(spacing: 4) {
            if let todo {
                Image(systemName: "checkmark.square").font(.system(size: 10)).foregroundColor(todo.color).frame(width: 14)
                    .help(L("TODO 작업방 · ", "TODO chat · ") + todo.title)
            } else if conversation.isProjectChat && depth == 0 {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary).frame(width: 14)
                    .help(L("작업방: Git 프로젝트가 연결된 대화", "Work chat: a Git project is linked"))
            }
            HStack(spacing: 5) {
                Text(conversation.turns.isEmpty && todo == nil ? L("새 대화", "New chat")
                     : todo != nil && conversation.title.hasPrefix(todoPrefix) ? String(conversation.title.dropFirst(todoPrefix.count)) : conversation.title)
                    .lineLimit(1).truncationMode(.tail)
                LockBadge(lock: conversation.enterpriseLock)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if approvals.requests.contains(where: { $0.room == conversation.id }) {
                Circle().fill(Color.orange).frame(width: 7, height: 7)
                    .help(L("허가를 기다려요", "Waiting for approval"))
            }
            if discussion.runningRooms.contains(conversation.id) {
                ProgressView().controlSize(.mini)
                    .help(L("답하는 중", "Answering"))
            }
            if meetings > 0 {
                Button(action: { discussion.toggleMeetings(conversation.id) }) {
                    HStack(spacing: 2) {
                        Image(systemName: shown ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                        Text("\(meetings)").font(.system(size: 10))
                    }
                    .padding(.horizontal, 6).frame(minWidth: 30, minHeight: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plainHit).foregroundColor(.secondary)
                .help(shown ? L("회의 접기 (줄을 두 번 눌러도 돼요)", "Hide meetings (or double-click the row)") : L("회의 \(meetings)개 보기 (줄을 두 번 눌러도 돼요)", "Show \(meetings) meetings (or double-click the row)"))
            }
            if conversation.hasContent && (hovered || selected) {
                Menu { chatMenu(conversation) } label: { Image(systemName: "ellipsis").frame(width: 18, height: 18) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L("대화 메뉴: ", "Chat options: ") + conversation.title)
            }
        }
        .font(.system(size: 13))
        .padding(.leading, 10 + CGFloat(depth) * 12).padding(.trailing, 10).frame(height: 30)
        .background(selected ? Color.primary.opacity(0.10) : hovered ? Color.primary.opacity(0.05) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        // Double-click folds or unfolds its meetings. The single click runs alongside, so opening is not delayed.
        .onTapGesture(count: 2) { if meetings > 0 { discussion.toggleMeetings(conversation.id) } }
        .simultaneousGesture(TapGesture().onEnded { discussion.open(conversation.id) })
        .onHover { inside in discussion.hover(conversation.id.uuidString, inside) }
        .help(dateText(conversation.updatedAt))
        .contextMenu {
            if conversation.hasContent { chatMenu(conversation) }
        }
        // Drag it onto a project folder to put it in that project.
        .onDrag {
            guard draggable(conversation, todo: todo) else { return NSItemProvider() }
            return NSItemProvider(object: (SidebarProjects.dragPrefix + conversation.id.uuidString) as NSString)
        }
        .disabled(discussion.importingMaterials)
    }

    // Chats on your other Macs (read only): one header per Mac, newest first.
    @ViewBuilder private var otherMacs: some View {
        let search = discussion.sidebarSearch
        SidebarHeader(title: L("다른 기기", "Other Macs"), fold: "devices") {
            Button(action: { sync.scan() }) { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                .buttonStyle(.plainHit).foregroundColor(.secondary)
                .help(sync.lastChecked.map { L("지금 확인 · 마지막 확인 ", "Check now · last checked ") + DeviceSync.ago($0) } ?? L("지금 확인", "Check now"))
        }
        if folds.isFolded("devices") {
        } else if !sync.folderAvailable {
            Text(L("iCloud Drive가 꺼져 있거나 동기화 폴더가 없어요. 설정 → 채팅에서 확인해 주세요.", "iCloud Drive is off or the sync folder is missing. Check Settings → Chat."))
                .font(.system(size: 11)).foregroundColor(.secondary).padding(.horizontal, 10)
        } else if sync.devices.isEmpty {
            Text(sync.lastChecked == nil ? L("확인하는 중…", "Checking…") : L("아직 다른 Mac의 대화가 없어요. 다른 Mac에서도 켜 주세요.", "No chats from other Macs yet. Turn this on there too."))
                .font(.system(size: 11)).foregroundColor(.secondary).padding(.horizontal, 10)
        }
        ForEach(folds.isFolded("devices") ? [] : sync.devices) { device in
            let chats = device.chats.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
            if !chats.isEmpty || search.isEmpty {
                Text(device.name).font(.system(size: 11)).foregroundColor(.secondary)
                    .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
                    .help(device.writtenAt.map { L("마지막으로 올린 시각 ", "Last written ") + DeviceSync.ago($0) } ?? "")
                // Each Mac shows its newest page (and the open chat); every match while searching.
                let all = discussion.sidebarSearching || !search.isEmpty
                let key = "device." + device.id, page = SidebarFold.devicePage
                let listed = all ? chats : SidebarFold.listed(chats, limit: folds.limit(key, page: page), open: discussion.viewingRemote?.chat.id)
                ForEach(listed) { remoteRow($0) }
                if !all { moreRow(key, page: page, total: chats.count, listed: listed.count) }
            }
        }
    }

    // "Show more (n)" under a shortened list, and "Show less" once it was lengthened.
    @ViewBuilder private func moreRow(_ key: String, page: Int, total: Int, listed: Int, indent: CGFloat = 10) -> some View {
        let hidden = total - listed
        let expanded = folds.limit(key, page: page) > page && total > page
        if hidden > 0 || expanded {
            HStack(spacing: 12) {
                if hidden > 0 { Button(L("더 보기 (\(hidden))", "Show more (\(hidden))")) { folds.showMore(key, page: page) } }
                if expanded { Button(L("접기", "Show less")) { folds.showLess(key) } }
            }
            .buttonStyle(.link).font(.system(size: 11)).padding(.leading, indent).frame(height: 22)
        }
    }

    private func remoteRow(_ chat: RemoteChat) -> some View {
        let selected = discussion.viewingRemote?.chat.id == chat.id
        let hovered = discussion.hoverKey == "remote." + chat.id
        return HStack(spacing: 4) {
            Image(systemName: chat.status == .ready ? "desktopcomputer" : chat.status == .downloading ? "icloud.and.arrow.down" : "exclamationmark.triangle")
                .font(.system(size: 10)).foregroundColor(.secondary).frame(width: 14)
            Text(chat.title).lineLimit(1).truncationMode(.tail)
                .foregroundColor(chat.status == .ready ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10).frame(height: 30)
        .background(selected ? Color.primary.opacity(0.10) : hovered ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { discussion.openRemote(chat) }
        .onHover { inside in discussion.hover("remote." + chat.id, inside) }
        .help(chat.updatedAt.map { L("내용 ", "Changed ") + DeviceSync.ago($0) } ?? "")
        .disabled(discussion.importingMaterials)
    }

    private func chat(sidebarShown: Bool, wide: Bool) -> some View {
        VStack(spacing: 0) {
            // Every mode shares the plain chat's layout; a team mode only adds a pill and a settings chip
            // in the message box.
            HStack(spacing: 8) {
                Button(action: {
                    if wide { discussion.sidebarHidden.toggle() } else { discussion.sidebarOverlay.toggle() }
                }) { Image(systemName: "sidebar.left").frame(width: 24, height: 24) }
                    .buttonStyle(.plainHit).foregroundColor(.secondary)
                    .help(sidebarShown ? L("사이드바 숨기기", "Hide sidebar") : L("사이드바 보기", "Show sidebar"))
                if discussion.viewingBoard, discussion.boardProject != nil {
                    // A project folder: two tabs, what belongs to the project and its TODOs.
                    Picker("", selection: Binding(get: { discussion.boardTab }, set: { discussion.showBoardTab($0) })) {
                        Text(L("프로젝트 정보", "Project info")).tag(BoardTab.info)
                        Text(L("할 일", "TODOs")).tag(BoardTab.todo)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    WindowDragRegion().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if discussion.viewingBoard {
                    Text(L("할 일 보드", "TODO board")).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    WindowDragRegion().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let space = discussion.viewingSpace {
                    SpaceHeader(discussion: discussion, id: space)
                } else if let remote = discussion.viewingRemote {
                    Text(remote.snapshot?.title ?? remote.chat.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(L("\(remote.chat.deviceName) · 읽기 전용", "\(remote.chat.deviceName) · read only"))
                        .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                    WindowDragRegion().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    soloHeader
                }
            }
            .padding(.leading, 12).padding(.trailing, 18).frame(height: 40)
            // Another chat waits for approval: say so here, whichever chat is open.
            ApprovalBanner(discussion: discussion)
            if discussion.findOpen && discussion.viewingRemote == nil && !discussion.viewingBoard && discussion.viewingSpace == nil && !discussion.current.turns.isEmpty {
                ChatFindBar(discussion: discussion).padding(.horizontal, 28).padding(.bottom, 4)
            }
            if discussion.viewingBoard, let project = discussion.boardProject, discussion.boardTab == .info {
                ChatApp.screens.projectInfo(discussion, project)
            } else if discussion.viewingBoard {
                ChatApp.screens.board(discussion)
            } else if let space = discussion.viewingSpace {
                SpaceMainView(discussion: discussion, id: space)
            } else if let remote = discussion.viewingRemote {
                RemoteChatView(viewing: remote, discussion: discussion, sync: sync)
            } else if discussion.current.turns.isEmpty {
                // A new chat: the greeting and the message box in the middle, like the desktop apps.
                VStack(spacing: 28) {
                    Spacer(minLength: 0)
                    HStack(spacing: 12) {
                        Image(nsImage: ChatApp.screens.icon(true)).resizable().frame(width: 30, height: 30)
                        Text(Self.greeting(discussion.configuration.mode))
                            // Serif reads well in English; Korean serif fonts look like handwriting, so Korean stays sans.
                            .font(.system(size: 30, weight: AppLanguage.current == .korean ? .light : .regular,
                                          design: AppLanguage.current == .korean ? .default : .serif))
                    }
                    composer
                    Text(Self.greetingNote(discussion.configuration.mode))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer(minLength: 0)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity)
            } else {
                transcript
                // TODO report cards and approval cards sit right above the message box, where the user is looking.
                ChatApp.screens.cards(discussion.currentID, discussion)
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 28)
                    .frame(maxWidth: .infinity)
                ProjectApprovalView(room: discussion.currentID, discussion: discussion)
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 28)
                    .frame(maxWidth: .infinity)
                composer
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 28).padding(.top, 4).padding(.bottom, 18)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    static func greeting(_ mode: Int) -> String {
        switch mode {
        case 1: return L("여러 AI와 토론해요", "Discuss it with several AIs")
        case 2: return L("서로 반론하며 따져 봐요", "Put it to a critical debate")
        case 3: return L("여러 AI와 함께 만들어요", "Work on it together")
        case 4: return L("AI들에게 투표를 맡겨요", "Let the AIs vote")
        default: return L("무엇을 도와드릴까요?", "What should we work on?")
        }
    }

    static func greetingNote(_ mode: Int) -> String {
        switch mode {
        case 1: return L("각자 의견을 낸 뒤, 대표가 논점을 맡기고 답을 하나로 정리해요.", "Each gives a view, the moderator assigns the open points and writes one answer.")
        case 2: return L("반론, 대안, 실패할 조건을 서로 검증한 뒤 정리해요.", "They test objections, alternatives and failure cases, then sum up.")
        case 3: return L("대표가 작업을 나누고, 결과를 서로 검토해서 하나로 합쳐요.", "The moderator splits the work; results are cross-reviewed and combined.")
        case 4: return L("선택지를 한 줄에 하나씩 적으면 모든 계정이 서로 보지 않고 한 표씩 던져요.", "List the choices one per line; every account votes without seeing the others.")
        default: return L("남은 사용량이 넉넉한 AI가 답하고, 한도에 가까워지면 다른 AI가 이어받아요.", "The AI with the most usage left answers; another one continues when it runs low.")
        }
    }

    // A team mode's settings, opened from the chip in the message box.
    private var teamSettings: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(ModeChangeMarker.name(discussion.configuration.mode)).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    if discussion.configuration.mode <= 2 {
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
                    }
                    if discussion.configuration.mode != 3 {
                        Menu {
                            Picker(L("AI 발언 길이", "Length of each AI turn"), selection: Binding(
                                get: { SpeechLength.clamp(discussion.configuration.speechLength) },
                                set: { length in discussion.configure { $0.speechLength = length } })) {
                                ForEach(SpeechLength.all, id: \.self) { length in
                                    Text(SpeechLength.name(length)).tag(length)
                                }
                            }
                            Divider()
                            Text(L("기본은 제한 없음: AI가 근거와 예시를 필요한 만큼 써요. 화면에는 한 줄 요약과 최종 답이 보여요.",
                                   "No limit by default: each AI uses the evidence and examples its point needs. The chat shows one-line summaries and the final answer."))
                        } label: {
                            Text(SpeechLength.name(SpeechLength.clamp(discussion.configuration.speechLength)))
                        }
                        .fixedSize()
                        .disabled(discussion.running || discussion.importingMaterials)
                    }
                    Menu {
                        Text(L("1 토론: 대표가 논점을 맡기고 답을 정리합니다. 2 비판 토론: 반론·대안·실패 조건을 검증합니다. 3 협업: 선택 계정에 필요한 결과물 작업을 나누고 검토·통합합니다. 4 투표: 선택지를 한 줄에 하나씩 적으면 모든 계정이 서로 보지 않고 한 표씩 이유와 함께 던지고, 앱이 개표합니다.", "1 Discussion: moderator-led discussion and synthesis. 2 Critical debate: test objections, alternatives and failure cases. 3 Collaboration: assign work to selected accounts, cross-review and integrate deliverables. 4 Vote: list the choices one per line; every account casts one vote with its reason without seeing the others, and the app counts."))
                        if discussion.configuration.mode == 4 {
                            Text(L("연결된 모든 계정(개인·엔터프라이즈 포함)이 한 표씩 던져요. 체크를 끄면 빠져요. 선택지를 적지 않으면 대표(왕관)가 선택지를 만들고, 대표도 한 표만 던져요.", "Every connected account (personal and Enterprise) casts one vote; uncheck to leave one out. Without a list, the moderator (crown) drafts the choices and still gets one vote."))
                        } else if discussion.configuration.mode >= 2 {
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
                        Text(L("실행은 각 도구의 샌드박스·계정 정책을 따릅니다. 엔터프라이즈 ChatGPT의 승인 요청은 자동 승인하지 않습니다.", "Execution follows each tool’s sandbox and account policy. Enterprise ChatGPT approval requests are not auto-approved."))
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
                Text(L("참여 AI", "Participants")).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary).padding(.top, 4)
                if discussion.configuration.mode == 3 {
                    collaborationControls
                } else if discussion.configuration.mode == 4 {
                    voteControls
                } else {
                    sequentialControls
                }
            }
            .padding(16)
            .frame(width: 520)
    }

    private var transcript: some View {
    ScrollViewReader { proxy in
      GeometryReader { viewport in
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                let conversation = discussion.current
                let busy = discussion.running || discussion.importingMaterials
                let accountLabels = Dictionary(discussion.model.accounts.map { ($0.id, discussion.label($0)) }, uniquingKeysWith: { first, _ in first })
                let chatFolder = Discussion.chatFolder(discussion.currentID).path
                let found = discussion.findOpen ? Set(ChatFind.hits(conversation, discussion.findText).map(\.turn)) : []
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
                let hidden = max(0, conversation.turns.count - discussion.shownTurns)
                if hidden > 0 {
                    Button(action: { showEarlierTurns(proxy) }) {
                        Text(L("이전 대화 \(min(hidden, Discussion.turnPage))턴 더 보기 · \(hidden)턴 숨김", "Show \(min(hidden, Discussion.turnPage)) earlier turns · \(hidden) hidden"))
                            .font(.callout)
                    }
                    .buttonStyle(.link)
                    .frame(maxWidth: .infinity)
                    .background(GeometryReader { marker in
                        Color.clear.preference(key: TranscriptTopKey.self, value: marker.frame(in: .named(ChatViewSize.bottomID)).minY)
                    })
                }
                // Lazy, so a window resize re-lays out only the turns near the screen, not every shown turn.
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(Array(conversation.turns.enumerated()).dropFirst(hidden), id: \.element.id) { index, turn in
                        VStack(alignment: .leading, spacing: 28) {
                            if index > 0, (turn.mode ?? 1) != (conversation.turns[index - 1].mode ?? 1) || turn.modeVersion != conversation.turns[index - 1].modeVersion {
                                ModeChangeMarker(mode: turn.mode ?? 1, version: turn.modeVersion)
                            }
                            let last = index == conversation.turns.count - 1
                            if let day = Self.dayLine(conversation, index) {
                                Text(day)
                                    .font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity)
                            }
                            TurnView(turn: turn, discussion: discussion, busy: busy,
                                     openEntries: discussion.openEntries.intersection((turn.entries + (turn.peerNotes ?? [])).map(\.id)),
                                     accountLabels: accountLabels, chatFolder: chatFolder, language: AppLanguage.current,
                                     askedTime: turn.askedAt.map { ChatTime.stamp($0) },
                                     answeredTime: (turn.answeredAt ?? (last && turn.askedAt == nil && turn.final != nil ? conversation.updatedAt : nil)).map { ChatTime.stamp($0) },
                                     last: last,
                                     highlight: found.contains(turn.id) ? FindHighlight(words: discussion.findText, current: turn.id == discussion.jumpTurn) : FindHighlight())
                                .equatable()
                        }
                        .id(turn.id)
                    }
                }
                // Where the transcript ends, for the jump-to-bottom button (macOS 13 has no scroll position API).
                Color.clear.frame(height: 1).id(ChatViewSize.bottomID)
                    .background(GeometryReader { marker in
                        Color.clear.preference(key: TranscriptBottomKey.self, value: marker.frame(in: .named(ChatViewSize.bottomID)).maxY)
                    })
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .coordinateSpace(name: ChatViewSize.bottomID)
        .onPreferenceChange(TranscriptBottomKey.self) { end in
            let away = end > viewport.size.height + ChatViewSize.bottomSlack
            if away != discussion.awayFromBottom { withAnimation(.easeOut(duration: 0.15)) { discussion.awayFromBottom = away } }
        }
        .onPreferenceChange(TranscriptTopKey.self) { top in
            // The "show earlier" row came into view near the top: add the next page.
            discussion.earlierRowInView = top > -40 && top < viewport.size.height
            if discussion.reachedBottom && discussion.earlierRowInView { showEarlierTurns(proxy) }
        }
        // A new scroll view for each chat (the .id below), so it opens at the latest turn once,
        // instead of keeping the last chat's offset and landing in empty space.
        .onAppear { openAtLatestTurn(proxy) }
        .overlay(alignment: .bottom) {
            if discussion.awayFromBottom {
                Button(action: { withAnimation { proxy.scrollTo(ChatViewSize.bottomID, anchor: .bottom) } }) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(Circle().stroke(Color.secondary.opacity(0.25)))
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
                }
                .buttonStyle(.plainHit).foregroundColor(.primary)
                .padding(.bottom, 10)
                .help(L("맨 아래로", "Scroll to bottom"))
                .accessibilityLabel(L("맨 아래로", "Scroll to bottom"))
                .transition(.opacity)
            }
        }
        // Only a new turn in the same chat: switching chats makes a new scroll view, which does not fire this.
        // Not animated, and once more after the lazy list has laid the new turn out: an animated jump
        // to a turn it knew only by estimate could stop in empty space until the next scroll.
        .onChange(of: discussion.jumpCount) { _ in scrollToJump(proxy) }
        .onChange(of: discussion.current.turns.count) { _ in
            guard let last = discussion.current.turns.last?.id else { return }
            proxy.scrollTo(last, anchor: .top)
            DispatchQueue.main.async { if discussion.current.turns.last?.id == last { proxy.scrollTo(last, anchor: .top) } }
        }
        // A new scroll view also when the window is reopened (showLatestTurns), so it opens at the latest turn again.
        .id("\(discussion.currentID)-\(discussion.transcriptGeneration)")
      }
    }
    }


    // The day above a turn when it starts a new day (turns from before times were saved have none).
    static func dayLine(_ conversation: Conversation, _ index: Int) -> String? {
        let turns = conversation.turns
        let when = { (i: Int) in ChatTime.when(turns[i], last: i == turns.count - 1, updatedAt: conversation.updatedAt) }
        guard let date = when(index) else { return nil }
        if index > 0, let before = when(index - 1), Calendar.current.isDate(before, inSameDayAs: date) { return nil }
        return ChatTime.day(date)
    }

    // Scrolls a just opened chat to its latest turn (twice: the lazy list knows far turns only by estimate),
    // then lets scrolling to the top add earlier turns.
    private func openAtLatestTurn(_ proxy: ScrollViewProxy) {
        let chat = discussion.currentID
        // Opened from a search result: show that turn instead.
        if discussion.jumpTurn != nil { return scrollToJump(proxy, opening: true) }
        DispatchQueue.main.async {
            if let last = discussion.current.turns.last { proxy.scrollTo(last.id, anchor: .top) }
            DispatchQueue.main.async {
                if discussion.currentID == chat, let last = discussion.current.turns.last { proxy.scrollTo(last.id, anchor: .top) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard discussion.currentID == chat else { return }
            discussion.reachedBottom = true
            // A short last page leaves the row in view already: no scroll would add the next one.
            if discussion.earlierRowInView { showEarlierTurns(proxy) }
        }
    }

    // Scrolls to the turn asked for (⌘F, a search result). Again after layout: far turns are known only by estimate.
    private func scrollToJump(_ proxy: ScrollViewProxy, opening: Bool = false) {
        guard let target = discussion.jumpTurn else { return }
        let chat = discussion.currentID
        for delay in [0.0, 0.05, 0.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if discussion.currentID == chat, discussion.jumpTurn == target { proxy.scrollTo(target, anchor: .top) }
            }
        }
        // Earlier pages load only after the user scrolls up from here.
        if opening { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if discussion.currentID == chat { discussion.reachedBottom = true } } }
    }

    // Adds the next page of earlier turns and keeps the turn being read where it was.
    private func showEarlierTurns(_ proxy: ScrollViewProxy) {
        let turns = discussion.current.turns
        guard !discussion.loadingEarlier, turns.count > discussion.shownTurns else { return }
        discussion.loadingEarlier = true
        let anchor = turns[turns.count - discussion.shownTurns].id
        discussion.shownTurns += Discussion.turnPage
        DispatchQueue.main.async {
            proxy.scrollTo(anchor, anchor: .top)
            DispatchQueue.main.async { discussion.loadingEarlier = false }
        }
    }
    // How far (pt) the end may sit below the visible area and still count as the bottom, so the button does not flicker.

    // The message box: text on top, then + on the left and who answers and send on the right. A meeting's own chat
    // is read only: a bar back to the chat it was held for instead.
    @ViewBuilder private var composer: some View {
        if let link = discussion.current.meetingOf { meetingBar(link) } else { messageBox }
    }

    private func meetingBar(_ link: MeetingLink) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.3").foregroundColor(.secondary)
            Text(L("회의 기록 · 읽기 전용", "Meeting record · read only")).font(.system(size: 13)).foregroundColor(.secondary)
            Spacer()
            if discussion.conversations.contains(where: { $0.id == link.room }) {
                Button(L("← 원래 채팅으로", "← Back to the chat")) {
                    discussion.open(link.room); discussion.jumpTurn = link.turn; discussion.jumpCount += 1
                }
                .buttonStyle(.link).font(.system(size: 13))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.10)))
    }

    private var messageBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = discussion.attachmentError {
                Text(error).font(.caption).foregroundColor(.red)
            }
            if discussion.hasImages && discussion.configuration.mode != 0 {
                Text(discussion.configuration.mode == 3
                     ? L("그림은 Claude·ChatGPT가 읽고, Gemini에는 근거 메모를 공유합니다.", "Claude/ChatGPT read images; Gemini receives their evidence notes.")
                     : L("사진과 AI가 그린 그림은 참여한 모든 AI에게 전달돼요(Gemini는 파일로 봐요).", "Photos and pictures the AIs drew go to every participating AI (Gemini reads them as files)."))
                    .font(.caption).foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                if !(discussion.current.queued ?? []).isEmpty || !(discussion.steering[discussion.currentID] ?? []).isEmpty { waitingList }
                if discussion.mentionQuery != nil { mentionList }
                if discussion.slashMenu != nil { slashList }
                if !discussion.pendingImages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(discussion.pendingImages) { item in
                                ZStack(alignment: .topTrailing) {
                                    AttachmentThumbnail(item: item, size: 56)
                                    Button(action: { discussion.removePendingImage(item) }) {
                                        Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.7))
                                    }
                                    .buttonStyle(.plainHit)
                                    .accessibilityLabel(L("첨부 제거: ", "Remove attachment: ") + item.name)
                                    .disabled(discussion.running || discussion.importingMaterials)
                                }
                                .help(item.name)
                            }
                        }
                    }
                }
                ZStack(alignment: .topLeading) {
                    if discussion.draft.isEmpty {
                        Text(discussion.configuration.mode == 0 ? L("무엇이든 물어보세요", "How can I help you today?") : L("메시지를 입력하세요…", "Write a message…"))
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .padding(.leading, 5).padding(.top, 2)
                            .allowsHitTesting(false)
                    }
                    MultilineInput(text: $discussion.draft, height: $discussion.inputHeight,
                                   onSend: { discussion.send() }, onPasteImages: { discussion.addPastedImages($0) },
                                   onKey: { event, editor in mentionKey(event, editor) },
                                   onTextChange: { editor in mentionChanged(editor) }, focusRequest: discussion.focusRequest)
                        .frame(height: discussion.inputHeight)
                        .accessibilityLabel(L("질문 입력", "Message"))
                }
                HStack(spacing: 10) {
                    plusMenu
                    if discussion.configuration.mode == 0 && discussion.current.meetingOf == nil {
                        // A Space (a small app) made from what is typed: the words say so, and the AI hears the Space rules.
                        Button(action: { discussion.askForSpace() }) {
                            Image(systemName: "square.grid.2x2").font(.system(size: 13)).frame(width: 28, height: 28)
                                .background(Circle().strokeBorder(Color.primary.opacity(0.15)))
                        }
                        .buttonStyle(.plainHit).foregroundColor(.secondary)
                        .disabled(discussion.running || discussion.importingMaterials)
                        .help(L("Space 만들기: 적은 내용으로 작은 앱(트래커·보드·게임)을 만들어요", "Make a Space: a small app (tracker, board, game) from what you type"))
                        .accessibilityLabel("Space")
                    }
                    if discussion.importingMaterials {
                        ProgressView().controlSize(.small)
                        Text(L("자료를 가져오는 중…", "Importing materials…")).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    if discussion.running {
                        Text(discussion.stopping ? L("중지 중…", "Stopping…") : L("답변 중…", "Responding…"))
                            .font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    Spacer()
                    if !discussion.routeChoices.isEmpty && !discussion.running { routeChip }
                    if discussion.configuration.mode == 0 && !discussion.running { accountChip }
                    if discussion.configuration.mode != 0 && !discussion.running { teamChip }
                    composerAction
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            // A light wash over the box colour, so the box stands out from the page in dark mode too.
            .background(RoundedRectangle(cornerRadius: 20).fill(Color.primary.opacity(0.045)))
            .background(RoundedRectangle(cornerRadius: 20).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.10)))
            .shadow(color: .black.opacity(0.07), radius: 10, y: 3)
        }
    }

    static func shortName(_ mode: Int) -> String {
        switch mode {
        case 1: return L("토론", "Discussion")
        case 2: return L("비판 토론", "Critical debate")
        case 3: return L("협업", "Collaboration")
        case 4: return L("투표", "Vote")
        default: return L("기본 대화", "Chat")
        }
    }

    // Who takes part (the crown is the moderator) and, for discussions, turns and length; click for all settings.
    private var teamChip: some View {
        let config = discussion.configuration
        let accounts = discussion.model.accounts
        var names: [String]
        switch config.mode {
        case 3:
            names = accounts.filter { config.accountIDs?.contains($0.id) ?? false }
                .map { ($0.id == config.leaderAccountID ? "👑 " : "") + discussion.label($0) }
        case 4:
            names = accounts.filter { !(config.voteSkippedIDs ?? []).contains($0.id) }.map { discussion.label($0) }
        default:
            names = config.order.filter { config.participants.contains($0) }
                .map { ($0 == config.leader ? "👑 " : "") + $0.title }
        }
        if names.isEmpty { names = [L("참여 AI 고르기", "Choose participants")] }
        var summary = names.count > 3 ? names.prefix(2).joined(separator: " · ") + L(" 외 \(names.count - 2)", " +\(names.count - 2)") : names.joined(separator: " · ")
        if (1...2).contains(config.mode) {
            summary += "  " + L("\(config.turnsPerAI ?? 4)회", "\(config.turnsPerAI ?? 4) turns") + " · " + SpeechLength.name(SpeechLength.clamp(config.speechLength)).components(separatedBy: " · ").first!
        }
        return Button(action: { discussion.teamSettingsOpen.toggle() }) {
            HStack(spacing: 4) {
                Text(summary).foregroundColor(.primary)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
            }
            .font(.system(size: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("참여 AI와 이 모드의 설정", "Participants and settings for this mode"))
        .popover(isPresented: $discussion.teamSettingsOpen, arrowEdge: .bottom) { teamSettings }
        .disabled(discussion.importingMaterials)
    }

    // @ in plain chat: a numbered list of accounts above the text. 1–9 or Return picks, ↑↓ moves, Esc closes;
    // a picked name is one colored piece that ⌫ removes at once.
    private var mentionList: some View {
        let list = discussion.mentionCandidates()
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(list.enumerated()), id: \.element.id) { n, account in
                let usage = discussion.model.latestUsage[account.id]
                Button(action: { if let editor = discussion.mentionEditor { pickMention(account, editor) } }) {
                    HStack(spacing: 8) {
                        Text("\(n + 1)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .frame(width: 18, height: 18)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                        Circle().fill(account.provider.color).frame(width: 7, height: 7)
                        Text(discussion.label(account)).font(.system(size: 13))
                        Spacer()
                        Text(account.provider == .gemini ? L("@로만 답해요", "answers only when called") : AutoPick.describe(usage))
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(n == discussion.mentionIndex ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(L("숫자나 Enter로 고르기 · Esc 닫기", "Number or Return to pick · Esc to close"))
                .font(.system(size: 10)).foregroundColor(.secondary).padding(.horizontal, 8).padding(.top, 2)
        }
        .padding(4)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    // "/" at the start of a message: the ways this chat offers, narrowed as the word is typed. Return or Tab picks
    // (the word becomes "/work "), ↑↓ moves, Esc closes.
    private var slashList: some View {
        let list = discussion.slashMenu?.choices ?? []
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(list.enumerated()), id: \.element) { n, choice in
                Button(action: { if let editor = discussion.mentionEditor { pickSlash(choice, editor) } }) {
                    HStack(spacing: 8) {
                        Image(systemName: choice.icon).font(.system(size: 11)).frame(width: 18, height: 18)
                        Text(choice.title).font(.system(size: 13))
                        Text(Route.words(choice).map { "/" + $0 }.joined(separator: "  "))
                            .font(.system(size: 11).monospaced()).foregroundColor(.secondary)
                        Spacer()
                        Text(Route.hint(choice)).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(n == discussion.slashIndex ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(L("Enter나 Tab으로 고르기 · Esc 닫기 · 이 메시지에만 적용돼요", "Return or Tab to pick · Esc to close · for this message only"))
                .font(.system(size: 10)).foregroundColor(.secondary).padding(.horizontal, 8).padding(.top, 2)
        }
        .padding(4)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func slashChanged(_ editor: NSTextView) {
        let menu = discussion.mentionQuery == nil
            ? Route.slashMenu(editor.string, cursor: editor.selectedRange().location, offered: discussion.routeChoices) : nil
        if menu?.query != discussion.slashMenu?.query { discussion.slashIndex = 0 }
        discussion.slashMenu = menu
    }

    private func pickSlash(_ choice: RouteChoice, _ editor: NSTextView) {
        guard let menu = discussion.slashMenu else { return }
        discussion.slashMenu = nil
        let range = NSRange(location: menu.location, length: 1 + (menu.query as NSString).length)
        guard NSMaxRange(range) <= (editor.string as NSString).length else { return }
        // Keep a space already there after the word instead of doubling it.
        let after = NSMaxRange(range) < (editor.string as NSString).length
            && CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar((editor.string as NSString).character(at: NSMaxRange(range))) ?? "x")
        let token = "/" + (Route.words(choice).first ?? "") + (after ? "" : " ")
        if editor.shouldChangeText(in: range, replacementString: token) {
            editor.replaceCharacters(in: range, with: token)
            editor.didChangeText()
        }
        if after { editor.setSelectedRange(NSRange(location: menu.location + (token as NSString).length + 1, length: 0)) }
        discussion.slashMenu = nil
        editor.window?.makeFirstResponder(editor)
    }

    // Opens, narrows or closes the list as the text after @ changes; colors the picked names.
    private func mentionChanged(_ editor: NSTextView) {
        discussion.mentionEditor = editor
        defer { colorMentions(editor); slashChanged(editor) }
        guard discussion.configuration.mode == 0 else { discussion.mentionQuery = nil; return }
        let text = editor.string as NSString
        let cursor = editor.selectedRange().location
        var at: Int?
        var i = cursor - 1
        while i >= 0 && cursor - i <= 24 {
            let c = text.character(at: i)
            if c == 64 { at = i; break }       // @
            if c == 10 { break }               // a new line ends the search
            i -= 1
        }
        guard let at, at == 0 || CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(text.character(at: at - 1)) ?? " ") else {
            discussion.mentionQuery = nil; return
        }
        // Right after a name already picked: no list.
        let tail = text.substring(from: at)
        for id in discussion.draftMentions {
            if let account = discussion.model.accounts.first(where: { $0.id == id }), tail.hasPrefix("@" + discussion.label(account)) {
                discussion.mentionQuery = nil; return
            }
        }
        let query = text.substring(with: NSRange(location: at + 1, length: cursor - at - 1))
        if query != discussion.mentionQuery { discussion.mentionIndex = 0 }
        discussion.mentionLocation = at
        discussion.mentionQuery = query
        if discussion.mentionCandidates().isEmpty { discussion.mentionQuery = nil }
    }

    private func mentionKey(_ event: NSEvent, _ editor: NSTextView) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        if event.keyCode == 51, flags.isEmpty, editor.selectedRange().length == 0 {
            // ⌫ right after a picked name removes the whole name and the pick.
            let text = editor.string as NSString
            let cursor = editor.selectedRange().location
            for id in discussion.draftMentions {
                guard let account = discussion.model.accounts.first(where: { $0.id == id }) else { continue }
                for token in ["@" + discussion.label(account) + " ", "@" + discussion.label(account)] {
                    let length = (token as NSString).length
                    if cursor >= length, text.substring(with: NSRange(location: cursor - length, length: length)) == token {
                        let range = NSRange(location: cursor - length, length: length)
                        if editor.shouldChangeText(in: range, replacementString: "") {
                            editor.replaceCharacters(in: range, with: "")
                            editor.didChangeText()
                        }
                        if !(editor.string.contains("@" + discussion.label(account))) { discussion.draftMentions.removeAll { $0 == id } }
                        return true
                    }
                }
            }
            return false
        }
        // Shift too: Shift+Return keeps making a new line.
        if let menu = discussion.slashMenu, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           discussion.mentionQuery == nil {
            switch event.keyCode {
            case 36, 76, 48:                              // Return, Enter, Tab
                pickSlash(menu.choices[min(discussion.slashIndex, menu.choices.count - 1)], editor); return true
            case 125: discussion.slashIndex = min(discussion.slashIndex + 1, menu.choices.count - 1); return true   // ↓
            case 126: discussion.slashIndex = max(discussion.slashIndex - 1, 0); return true                        // ↑
            case 53: discussion.slashMenu = nil; return true                                                        // Esc
            default: return false
            }
        }
        guard discussion.mentionQuery != nil, flags.isEmpty else { return false }
        let list = discussion.mentionCandidates()
        guard !list.isEmpty else { return false }
        switch event.keyCode {
        case 36, 76, 48:                                  // Return, Enter, Tab
            pickMention(list[min(discussion.mentionIndex, list.count - 1)], editor); return true
        case 125: discussion.mentionIndex = min(discussion.mentionIndex + 1, list.count - 1); return true   // ↓
        case 126: discussion.mentionIndex = max(discussion.mentionIndex - 1, 0); return true                // ↑
        case 53: discussion.mentionQuery = nil; return true                                                // Esc
        default:
            if let key = event.charactersIgnoringModifiers, let n = Int(key), (1...list.count).contains(n) {
                pickMention(list[n - 1], editor); return true
            }
            return false
        }
    }

    private func pickMention(_ account: Account, _ editor: NSTextView) {
        let cursor = editor.selectedRange().location
        let start = discussion.mentionLocation
        guard start <= cursor, cursor <= (editor.string as NSString).length else { return }
        if !discussion.draftMentions.contains(account.id) { discussion.draftMentions.append(account.id) }
        discussion.mentionQuery = nil
        let range = NSRange(location: start, length: cursor - start)
        let token = "@" + discussion.label(account) + " "
        if editor.shouldChangeText(in: range, replacementString: token) {
            editor.replaceCharacters(in: range, with: token)
            editor.didChangeText()
        }
        editor.window?.makeFirstResponder(editor)
    }

    private func colorMentions(_ editor: NSTextView) {
        guard !editor.hasMarkedText(), let storage = editor.textStorage else { return }
        let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor]
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(plain, range: whole)
        for id in discussion.draftMentions {
            guard let account = discussion.model.accounts.first(where: { $0.id == id }) else { continue }
            let token = "@" + discussion.label(account)
            var search = NSRange(location: 0, length: storage.length)
            while true {
                let found = (storage.string as NSString).range(of: token, options: [], range: search)
                if found.location == NSNotFound { break }
                storage.addAttributes([.foregroundColor: NSColor.controlAccentColor, .font: NSFont.systemFont(ofSize: 14, weight: .semibold)], range: found)
                let next = found.location + found.length
                search = NSRange(location: next, length: storage.length - next)
            }
        }
        storage.endEditing()
        editor.typingAttributes = plain
    }

    private var plusMenu: some View {
        Menu {
            Button(L("파일 첨부", "Attach files")) { discussion.chooseFiles() }
            Button(L("폴더 연결 (모든 권한)", "Link folder (full access)")) { discussion.chooseMaterials(folder: true) }
            if discussion.configuration.mode == 0 {
                Button(L("새 프로젝트… (Git·GitHub)", "New project… (Git and GitHub)")) { discussion.newProjectFromMenu() }
                if discussion.current.workspace?.project == nil {
                    Button(L("문서 프로젝트 연결… (논문·슬라이드, Git 없음)", "Documents project… (papers and slides, no Git)")) { discussion.linkDocumentsProject() }
                }
                if discussion.current.workspace?.project != nil || discussion.current.workspace?.roots.contains(where: \.directory) == true {
                    Button(discussion.current.workspace?.isFullAuto == true ? L("완전 자동 끄기 (카드로 확인)", "Turn off full auto (confirm with cards)") : L("완전 자동 켜기", "Turn on full auto")) { discussion.toggleFullAuto() }
                }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 15, weight: .medium))
                .frame(width: 28, height: 28)
                .background(Circle().strokeBorder(Color.primary.opacity(0.15)))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundColor(.secondary)
        .accessibilityLabel(L("첨부", "Attach"))
        .help(L("사진·파일·폴더 첨부", "Attach photos, files or folders"))
        .disabled(discussion.running || discussion.importingMaterials)
    }

    // Messages sent while this chat answers: the ones the answer may still read, then the queue (sent together at the end).
    private var waitingList: some View {
        let queued = discussion.current.queued ?? [], steering = discussion.steering[discussion.currentID] ?? []
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "tray.full").foregroundColor(.secondary)
                Text(queued.isEmpty ? L("답에 전달 중 \(steering.count)개", "\(steering.count) passing into the answer")
                     : L("대기 중 \(queued.count)개 · 답이 끝나면 한 번에 보내요", "\(queued.count) waiting · sent together when the answer ends"))
                    .font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                Spacer()
                if !queued.isEmpty {
                    Button(discussion.running ? L("멈추고 지금 보내기", "Stop and send now") : L("지금 보내기", "Send now")) { discussion.sendQueueNow() }
                        .buttonStyle(.link).font(.system(size: 12))
                        .disabled(discussion.stopping || (!discussion.running && discussion.runningRooms.count >= Discussion.maxRunning))
                }
            }
            ForEach(steering, id: \.message.id) { pair in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 10)).foregroundColor(.secondary)
                    Text(pair.message.text).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Text(L("AI가 읽으면 이 답에 반영돼요", "Read into this answer when the AI gets to it")).font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            ForEach(Array(queued.enumerated()), id: \.element.id) { n, message in
                HStack(spacing: 6) {
                    Text("\(n + 1).").font(.system(size: 12)).foregroundColor(.secondary)
                    if !(message.images ?? []).isEmpty { Image(systemName: "photo").font(.system(size: 11)).foregroundColor(.secondary) }
                    Text(message.text).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Button(action: { discussion.editQueued(message.id) }) { Image(systemName: "pencil") }
                        .buttonStyle(.plainHit).foregroundColor(.secondary)
                        .help(L("입력창으로 꺼내서 고치기", "Back into the message box to change it"))
                    Button(action: { discussion.removeQueued(message.id) }) { Image(systemName: "xmark") }
                        .buttonStyle(.plainHit).foregroundColor(.secondary)
                        .help(L("대기 중인 메시지 지우기", "Remove the waiting message"))
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private var queueButton: some View {
        Button(action: { discussion.send() }) {
            Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white).frame(width: 30, height: 30)
        }
        .buttonStyle(.plainHit)
        .background(Color.accentColor, in: Circle())
        .accessibilityLabel(L("보내기 (답이 끝나면 이어서)", "Send (after this answer)"))
        .help(L("답하는 중이에요. 지금 답에 전달하거나, 끝나면 이어서 보내요 (Enter)", "Still answering: passed into this answer, or sent when it ends (Enter)"))
        .keyboardShortcut(.return, modifiers: .command)
    }

    @ViewBuilder private var composerAction: some View {
        if discussion.running && discussion.canSend { queueButton }
        if discussion.running && discussion.debateCancellation != nil {
            Button(action: { discussion.stopDebate() }) {
                Image(systemName: "stop.fill").font(.system(size: 11, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plainHit)
            .background(Color.secondary.opacity(0.18), in: Circle())
            .accessibilityLabel(L("중지", "Stop"))
            .help(L("응답 중지", "Stop responding"))
            .disabled(discussion.stopping)
        } else if discussion.running {
            ProgressView().controlSize(.small).frame(width: 30, height: 30)
        } else {
            Button(action: { discussion.send() }) {
                Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white).frame(width: 30, height: 30)
            }
            .buttonStyle(.plainHit)
            .background(!discussion.canSend
                        ? Color.secondary.opacity(0.3) : Color.accentColor, in: Circle())
            .accessibilityLabel(L("보내기", "Send"))
            .help(discussion.runningRooms.count >= Discussion.maxRunning
                  ? L("동시에 \(Discussion.maxRunning)개 대화까지 답할 수 있어요. 하나가 끝나면 보낼 수 있어요.",
                      "Up to \(Discussion.maxRunning) chats can answer at once. Send when one finishes.")
                  : L("전송 (Enter)", "Send (Enter)"))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!discussion.canSend)
        }
    }

    private var collaborationControls: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack {
                ForEach(discussion.model.accounts.filter { $0.provider != .ollama || discussion.model.localEnabled }, id: \.id) { account in
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
                        }.buttonStyle(.plainHit).help(L("대표로 지정", "Make moderator"))
                    }.padding(5).background(Color.secondary.opacity(0.1)).cornerRadius(6)
                }
            }.toggleStyle(.checkbox)
        }.disabled(discussion.running || discussion.importingMaterials)
    }

    // Folders every chat's AI may read (read only for now). Right-click to open or remove.
    private var sharedFolders: some View {
        VStack(alignment: .leading, spacing: 1) {
            SidebarHeader(title: L("공동 폴더", "Shared folders"), fold: "shared") {
                Button(action: { model.addSharedFolder() }) { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22) }
                    .buttonStyle(.plainHit).foregroundColor(.secondary)
                    .help(L("모든 대화의 AI가 읽을 폴더 추가", "Add a folder every chat's AI can read"))
                    .accessibilityLabel(L("공동 폴더 추가", "Add shared folder"))
            }
            if folds.isFolded("shared") {
            } else if model.sharedFolders.isEmpty {
                Button(action: { model.addSharedFolder() }) {
                    Label(L("폴더 추가 · 모든 대화에서 읽기", "Add a folder · read in every chat"), systemImage: "folder.badge.plus")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                        .padding(.horizontal, 10).frame(height: 28, alignment: .leading)
                }
                .buttonStyle(.plainHit)
            }
            // Double-click opens the folder in Finder; the pencil lets the AIs change it (backed up before each
            // answer); the eye turns sharing on or off (the folder stays listed); right-click to remove it.
            ForEach(folds.isFolded("shared") ? [] : model.sharedFolders, id: \.self) { path in
                let paused = model.pausedSharedFolders.contains(path)
                let writable = model.writableSharedFolders.contains(path)
                let toggleWrite = { if writable { model.writableSharedFolders.remove(path) } else { model.writableSharedFolders.insert(path) } }
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundColor(.secondary).frame(width: 18)
                    Text((path as NSString).lastPathComponent).lineLimit(1)
                        .foregroundColor(paused ? .secondary : .primary)
                    Spacer(minLength: 2)
                    if !paused {
                        Button(action: toggleWrite) {
                            Image(systemName: writable ? "pencil" : "pencil.slash").font(.system(size: 12, weight: .medium))
                                .foregroundColor(writable ? .accentColor : .secondary.opacity(0.6)).frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plainHit)
                        .help(writable ? L("쓰기 허용: AI가 고치고 만들고 지울 수 있어요(답하기 전에 자동 백업). 눌러서 읽기만", "Writable: the AIs may edit, create and delete (backed up before each answer). Click for read only")
                                       : L("읽기만: AI가 고칠 수 없어요. 눌러서 쓰기 허용", "Read only: the AIs cannot change it. Click to allow changes"))
                        .accessibilityLabel(writable ? L("읽기만으로", "Make read only") : L("쓰기 허용", "Allow changes"))
                    }
                    Button(action: {
                        if paused { model.pausedSharedFolders.remove(path) } else { model.pausedSharedFolders.insert(path) }
                    }) {
                        Image(systemName: paused ? "eye.slash" : "eye").font(.system(size: 12))
                            .foregroundColor(.secondary.opacity(paused ? 0.6 : 0.9)).frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plainHit)
                    .help(paused ? L("공유 꺼짐: AI가 이 폴더를 못 봐요. 눌러서 켜기", "Not shared: the AIs cannot see it. Click to share")
                                 : L("공유 중: 모든 대화의 AI가 볼 수 있어요. 눌러서 끄기", "Shared: every chat's AI can see it. Click to stop"))
                    .accessibilityLabel(paused ? L("공유 켜기", "Share") : L("공유 끄기", "Stop sharing"))
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10).frame(height: 30)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                .help(path + "\n" + L("두 번 눌러 Finder에서 열기", "Double-click to open in Finder"))
                .contextMenu {
                    Button(L("Finder에서 열기", "Open in Finder")) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    Button(paused ? L("공유 켜기", "Share") : L("공유 끄기", "Stop sharing")) {
                        if paused { model.pausedSharedFolders.remove(path) } else { model.pausedSharedFolders.insert(path) }
                    }
                    Button(writable ? L("읽기만으로", "Make read only") : L("쓰기 허용 (자동 백업)", "Allow changes (backed up)"), action: toggleWrite)
                    Divider()
                    Button(L("공동 폴더에서 빼기", "Remove from shared folders"), role: .destructive) { model.sharedFolders.removeAll { $0 == path } }
                }
            }
        }
        .disabled(discussion.importingMaterials)
    }

    // Mode 0: this chat's folder and links on the right; everything else lives in the message box.
    private var soloHeader: some View {
        HStack(spacing: 6) {
            Text(discussion.current.turns.isEmpty ? "" : discussion.current.title)
                .font(.system(size: 13, weight: .medium)).lineLimit(1)
                .onTapGesture(count: 2) { discussion.rename(discussion.currentID) }
                .help(L("두 번 눌러 이름 바꾸기", "Double-click to rename"))
                .disabled(discussion.running || discussion.importingMaterials)
            if !discussion.sessionNote.isEmpty {
                Text(discussion.sessionNote).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
            WindowDragRegion().frame(maxWidth: .infinity, maxHeight: .infinity)
            if let workspace = discussion.current.workspace {
                Menu {
                    ForEach(workspace.roots, id: \.path) { root in
                        Button(root.path) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root.path)]) }
                    }
                    Divider()
                    Button(L("연결 끊기", "Disconnect")) { discussion.restartRoomSessions(disconnect: true) }
                } label: {
                    Label((workspace.isFullAuto ? L("완전 자동 · ", "Full auto · ") : "") + L("연결 \(workspace.roots.count)개", "\(workspace.roots.count) linked"),
                          systemImage: workspace.isFullAuto ? "bolt.fill" : "link")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(discussion.running || discussion.importingMaterials)
                .foregroundColor(.secondary)
                .help(discussion.configuration.mode == 0
                      ? L("이 대화에 연결한 폴더: AI가 읽고 쓰고 지울 수 있어요 (답하기 전에 자동 백업)", "Folders linked to this chat: its AI may read, edit and delete (backed up before each answer)")
                      : L("이 대화에 연결한 폴더: 권한은 모드 설정(입력창 오른쪽)에서 정해요", "Folders linked to this chat: set access in the mode settings (right of the message box)"))
            }
            Button(action: { discussion.notesShown.toggle() }) {
                Image(systemName: "note.text").frame(width: 24, height: 24)
            }
            .buttonStyle(.plainHit)
            .foregroundColor(discussion.notesShown ? .accentColor : .secondary)
            .help(discussion.notesShown ? L("메모 접기", "Hide notes") : L("메모 펼치기 (AI는 읽기만 해요)", "Show notes (the AI only reads them)"))
            .accessibilityLabel(L("메모", "Notes"))
        }
    }

    // Who answers: automatic (most usage left), or the accounts checked for this chat. Two or more checked: in a
    // plain chat all answer every message at the same time; in a project chat one works (the lead) and the others
    // review its changes. @ in a message calls others for that message only.
    // How the next message is answered: the app decides (automatic), or the way picked here, for that message only.
    private var routeChip: some View {
        let picked = discussion.pickedRoute
        return Menu {
            Button((picked == nil ? "✓ " : "") + L("자동 (앱이 판단)", "Automatic (the app decides)")) { discussion.pickedRoute = nil }
            Divider()
            ForEach(discussion.routeChoices, id: \.self) { choice in
                Button((picked == choice ? "✓ " : "") + choice.title + "  /" + (Route.words(choice).first ?? "")) {
                    discussion.pickedRoute = choice
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: picked?.icon ?? "wand.and.stars").font(.system(size: 11))
                Text(picked?.title ?? L("자동", "Auto"))
            }
            .font(.system(size: 12))
            .foregroundColor(picked == nil ? .secondary : .accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("이 메시지를 어떻게 답할지 고르기. 보내면 다시 자동이 돼요. 메시지 앞에 /work(/w), /meet(/m) 처럼 써도 돼요. / 만 치면 목록이 나와요.",
                "How to answer this message. Back to automatic after sending. You can also start the message with /work (/w), /meet (/m)… Type / for the list."))
    }

    private var accountChip: some View {
        let config = discussion.configuration
        let members = discussion.memberIDs
        let project = discussion.current.workspace?.project != nil
        let crew = discussion.crew(project: project)
        let next = discussion.soloNext
        let usage = next.flatMap { discussion.model.latestUsage[$0.id] }
        let lock = discussion.current.enterpriseLock
        func name(_ id: String) -> String { discussion.model.accounts.first { $0.id == id }.map { discussion.label($0) } ?? id }
        return Menu {
            Button((members.isEmpty ? "✓ " : "") + L("자동 (남은 사용량 기준)", "Automatic (most usage left)")) {
                discussion.configure { c in
                    c.soloAccountID = nil; c.memberIDs = nil; c.leadID = nil
                    c.peerReview = nil; c.peerAccountID = nil; c.pendingReview = nil
                }
            }
            Divider()
            Text(project ? L("여러 명 체크: 한 명이 작업하고 나머지가 검수해요", "Check several: one works, the others review")
                         : L("여러 명 체크: 모두 함께 답해요", "Check several: they all answer"))
            ForEach(discussion.model.accounts.filter { $0.provider != .gemini }, id: \.id) { account in
                Button((members.contains(account.id) ? "✓ " : "") + discussion.label(account) + " · "
                       + AutoPick.describe(discussion.model.latestUsage[account.id])) {
                    discussion.toggleMember(account.id)
                }
                .disabled(!Enterprise.permits(account, lock: lock))   // an Enterprise chat: personal accounts cannot take part
            }
            if members.count >= 2 {
                Divider()
                Menu(L("작업 담당", "Who does the work")) {
                    Button((config.leadID == nil ? "✓ " : "") + L("자동 (앱이 정하고 유지)", "Automatic (the app picks and keeps one)")) {
                        discussion.configure { $0.leadID = nil }
                    }
                    ForEach(members.filter { id in !project || discussion.model.accounts.contains { $0.id == id && [.claude, .codex].contains($0.provider) } }, id: \.self) { id in
                        Button((config.leadID == id ? "✓ " : "") + name(id)) { discussion.configure { $0.leadID = id } }
                    }
                }
            }
            Divider()
            if let lock {
                Text(lock.isPersonal ? L("🔒 개인 방 (해제할 수 없어요)", "🔒 Personal chat (cannot be undone)")
                                     : L("🔒 \(lock.name) Enterprise 방 (해제할 수 없어요)", "🔒 \(lock.name) Enterprise chat (cannot be undone)"))
            } else {
                EnterpriseLockButtons(discussion: discussion, room: discussion.currentID)
            }
        } label: {
            // A menu label keeps a single text view, so the name and usage are one concatenated Text.
            if let crew, project {
                (Text(Image(systemName: "person.2")) + Text(" " + L("작업 ", "Work ")).foregroundColor(.secondary) + Text(name(crew.lead)).foregroundColor(.primary)
                 + Text(" · " + L("검수 ", "Review ")).foregroundColor(.secondary) + Text(crew.others.map(name).joined(separator: ", ")).foregroundColor(.primary))
                    .font(.system(size: 12))
            } else if let crew {
                (Text(Image(systemName: "person.2")) + Text(" " + ([crew.lead] + crew.others).map(name).joined(separator: " + ")).foregroundColor(.primary))
                    .font(.system(size: 12))
            } else if members.count >= 2 {
                (Text(Image(systemName: "person.2")) + Text(" " + members.map(name).joined(separator: " + ")).foregroundColor(.secondary))
                    .font(.system(size: 12))
            } else {
                let name = (lock.map { $0.isPersonal ? L("개인 · ", "Personal · ") : "Enterprise · " } ?? "")
                    + (next.map { discussion.label($0) } ?? L("쓸 수 있는 계정 없음", "No account available"))
                (Text(members.isEmpty ? Image(systemName: "sparkles") : Image(systemName: "person.crop.circle"))
                 + Text(" " + name).foregroundColor(.primary)
                 + Text(next == nil ? "" : "  " + AutoPick.describe(usage)).foregroundColor(.secondary))
                    .font(.system(size: 12))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("답할 AI: 자동이면 5시간이 \(Int(AutoPick.threshold))% 이상 남은 계정 중 주간이 가장 많이 남은 계정. 여러 명을 체크하면 일반 채팅에서는 모두 동시에 답하고, 프로젝트 채팅에서는 한 명이 작업하고 나머지가 바뀐 내용을 검수해요 (@는 그 메시지에만 적용).",
                "Who answers: automatic picks, among accounts with at least \(Int(AutoPick.threshold))% of the 5-hour limit left, the one with the most weekly usage left. Check several: in a plain chat they all answer at the same time; in a project chat one works and the others review its changes (@ applies to one message only)."))
    }

    // Mode 4: every account votes unless unchecked; the crown drafts the choices when none are listed.
    private var voteControls: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack {
                ForEach(discussion.model.accounts, id: \.id) { account in
                    let config = discussion.configuration
                    let moderator = config.leaderAccountID ?? discussion.model.accounts.first { $0.provider == config.leader }?.id
                    HStack(spacing: 3) {
                        Toggle(discussion.label(account), isOn: Binding(
                            get: { !(discussion.configuration.voteSkippedIDs ?? []).contains(account.id) },
                            set: { enabled in discussion.configure { config in
                                var skipped = config.voteSkippedIDs ?? []
                                skipped.removeAll { $0 == account.id }
                                if !enabled { skipped.append(account.id) }
                                config.voteSkippedIDs = skipped
                            } }))
                        Button(action: { discussion.configure { $0.leaderAccountID = account.id; $0.leader = account.provider } }) {
                            Image(systemName: moderator == account.id ? "crown.fill" : "crown")
                        }.buttonStyle(.plainHit).help(L("대표로 지정 (선택지를 적지 않았을 때 선택지를 만듦)", "Make moderator (drafts the choices when none are listed)"))
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

private struct TranscriptTopKey: PreferenceKey {
    static var defaultValue: CGFloat = -.infinity
    // Only the "show earlier" row sets it; the larger value keeps it from being overwritten by the views after it.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct TranscriptBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
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

// Mode 4: the choices, and once everyone has voted, a bar per choice (the leading choice in the accent color).
private struct VoteResultView: View {
    let options: [String]
    let votes: [VoteBallot]?

    var body: some View {
        let counts = VoteCount.tally(votes ?? [], options: options.count)
        let total = max(counts.reduce(0, +), 1)
        let top = counts.max() ?? 0
        VStack(alignment: .leading, spacing: 7) {
            ForEach(options.indices, id: \.self) { i in
                let leading = votes != nil && top > 0 && counts[i] == top
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(i + 1). " + options[i]).fontWeight(leading ? .semibold : .regular)
                        Spacer(minLength: 8)
                        if votes != nil {
                            Text(L("\(counts[i])표", "\(counts[i])")).monospacedDigit().foregroundColor(.secondary)
                        }
                    }
                    if votes != nil {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.15))
                                Capsule().fill(leading ? Color.accentColor : Color.secondary.opacity(0.5))
                                    .frame(width: geometry.size.width * CGFloat(counts[i]) / CGFloat(total))
                            }
                        }
                        .frame(height: 6)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }
}

// A borderless icon in the chat's top bar, shaded while hovered.
private struct HeaderIconButton: View {
    @ObservedObject var discussion: Discussion
    let symbol: String
    let help: String
    let action: () -> Void
    private var hovered: Bool { discussion.hoverKey == "header." + symbol }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14))
                .frame(width: 28, height: 28)
                .background(hovered ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit).foregroundColor(.secondary)
        .onHover { discussion.hover("header." + symbol, $0) }
        .help(help)
        .accessibilityLabel(help)
    }
}

// One action row at the top of the sidebar (New chat, Search).
private struct SidebarRow: View {
    @ObservedObject var discussion: Discussion
    let title: String
    let symbol: String
    let action: () -> Void
    private var hovered: Bool { discussion.hoverKey == "row." + symbol }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer()
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10).frame(height: 30)
            .background(hovered ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
        .onHover { discussion.hover("row." + symbol, $0) }
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
        case 0: return L("기본 대화 (AI 한 명)", "Plain chat (one AI)")
        case 4: return L("모드4 · 투표", "Mode 4 · Vote")
        case 3: return L("모드3 · 협업", "Mode 3 · Collaboration")
        case 2: return L("모드2 · 비판 토론", "Mode 2 · Critical debate")
        default: return L("모드1 · 토론", "Mode 1 · Discussion")
        }
    }
}

// A chat from another Mac, read only: its turns as usual, and in place of the message box when it was
// written and checked, and "Continue on this Mac".
private struct RemoteChatView: View {
    let viewing: RemoteViewing
    @ObservedObject var discussion: Discussion   // unfolded AI replies live in discussion.openEntries
    @ObservedObject var sync: DeviceSync

    var body: some View {
        VStack(spacing: 0) {
            if let snap = viewing.snapshot {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(snap.turns) { turn in
                            TurnView(turn: turn, discussion: discussion, busy: true,
                                     openEntries: discussion.openEntries.intersection((turn.entries + (turn.peerNotes ?? [])).map(\.id)), accountLabels: [:],
                                     chatFolder: "", language: AppLanguage.current,
                                     askedTime: turn.askedAt.map { ChatTime.stamp($0) }, answeredTime: turn.answeredAt.map { ChatTime.stamp($0) })
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 28).padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
            } else if viewing.loading {
                VStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: viewing.chat.status == .downloading ? "icloud.and.arrow.down" : "exclamationmark.triangle")
                        .font(.system(size: 28)).foregroundColor(.secondary)
                    Text(message).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(32).frame(maxWidth: .infinity)
            }
            bar
                .frame(maxWidth: 760)
                .padding(.horizontal, 28).padding(.top, 4).padding(.bottom, 18)
                .frame(maxWidth: .infinity)
        }
        // A newer copy arrived while it is open: show it.
        .onChange(of: sync.devices) { devices in
            guard let fresh = devices.first(where: { $0.id == viewing.chat.device })?.chats.first(where: { $0.chat == viewing.chat.chat }),
                  fresh != viewing.chat else { return }
            discussion.openRemote(fresh)
        }
    }

    private var message: String {
        switch viewing.chat.status {
        case .downloading: return L("iCloud에서 받는 중이에요. 잠시 뒤 다시 눌러 주세요.", "Downloading from iCloud. Click it again in a moment.")
        case .newerVersion: return L("이 대화는 더 새 버전의 앱이 저장했어요. 이 Mac의 앱을 업데이트하면 볼 수 있어요.", "A newer version of the app saved this chat. Update the app on this Mac to read it.")
        default: return L("이 대화를 읽을 수 없어요. 아직 동기화 중이거나 파일이 손상됐어요.", "This chat cannot be read. It may still be syncing, or the file is damaged.")
        }
    }

    private var bar: some View {
        let continued = discussion.continued(from: viewing.chat)
        return HStack(spacing: 10) {
            Image(systemName: "lock").foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(status).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(2)
                if let snap = viewing.snapshot, snap.pictures > 0 {
                    Text(L("그림 \(snap.pictures)개는 \(viewing.chat.deviceName)에만 있어요.", "\(snap.pictures) pictures stay on \(viewing.chat.deviceName)."))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                if let earlier = continued.first {
                    Button(L("이 Mac에서 이어간 대화 열기: ", "Open the chat continued here: ") + earlier.title) { discussion.open(earlier.id) }
                        .buttonStyle(.link).font(.system(size: 11)).lineLimit(1)
                }
            }
            Spacer()
            Button(L("이 Mac에서 이어서 하기", "Continue on this Mac")) { discussion.continueRemote(viewing) }
                .buttonStyle(.borderedProminent)
                .disabled(viewing.snapshot == nil || discussion.importingMaterials)
                .help(L("이 Mac에 새 대화를 만들고 지금까지의 내용을 복사해요. 원래 기기의 대화는 그대로예요.",
                        "Makes a new chat on this Mac with everything so far. The chat on the other Mac stays as it is."))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.10)))
    }

    private var status: String {
        var parts = [viewing.chat.deviceName]
        if let changed = viewing.snapshot?.updatedAt ?? viewing.chat.updatedAt { parts.append(L("내용 ", "changed ") + DeviceSync.ago(changed)) }
        if let checked = sync.lastChecked { parts.append(L("확인 ", "checked ") + DeviceSync.ago(checked)) }
        parts.append(L("읽기 전용", "read only"))
        return parts.joined(separator: " · ")
    }
}

// Each turn gets only the values it shows, and redraws only when they change: with the whole Discussion
// observed, any change (typing, the scroll-to-bottom button) redrew every turn of a long chat.
private struct TurnView: View, Equatable {
    let turn: ChatTurn
    let discussion: Discussion   // for actions only; not observed
    let busy: Bool               // running or importing materials
    let openEntries: Set<UUID>   // this turn's unfolded AI replies
    let accountLabels: [String: String]
    let chatFolder: String
    let language: AppLanguage
    let askedTime: String?       // "오후 3:12" under the message
    let answeredTime: String?    // the same next to the answer's Copy
    var last = false             // the chat's newest turn: it may be run again in the other mode
    var highlight = FindHighlight()   // ⌘F words, for turns that have them

    static func == (a: TurnView, b: TurnView) -> Bool {
        a.turn == b.turn && a.busy == b.busy && a.openEntries == b.openEntries && a.last == b.last && a.highlight == b.highlight
            && a.accountLabels == b.accountLabels && a.chatFolder == b.chatFolder && a.language == b.language
            && a.askedTime == b.askedTime && a.answeredTime == b.answeredTime
    }

    // "· 7분째" and, with no news for 2 minutes or more, "· 마지막 활동 3분 전".
    static func timing(asked: Date, last: Date?, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(asked) / 60))
        var text = minutes < 1 ? L("· 방금 시작", "· just started") : L("· \(minutes)분째", "· \(minutes) min")
        if let last, now.timeIntervalSince(last) >= 120 {
            text += L(" · 마지막 활동 \(Int(now.timeIntervalSince(last) / 60))분 전", " · last activity \(Int(now.timeIntervalSince(last) / 60)) min ago")
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The user's side, all on the right like the desktop apps: attached pictures, the message,
            // who was called with @, and Copy.
            VStack(alignment: .trailing, spacing: 6) {
                if let images = turn.images, !images.isEmpty {
                    // On the right while they fit on one line; more scroll sideways across the whole width.
                    ViewThatFits(in: .horizontal) {
                        attachedImages(images)
                        ScrollView(.horizontal, showsIndicators: false) { attachedImages(images) }
                    }
                    .padding(.bottom, 2)
                }
                HStack {
                    Spacer(minLength: 120)
                    Text(highlight.apply(AttributedString(turn.question)))
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                }
                // Sent while it answered and read by the AI in this answer (steering).
                ForEach(Array((turn.followUps ?? []).enumerated()), id: \.offset) { _, text in
                    HStack {
                        Spacer(minLength: 120)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("답하는 중에 보냄", "Sent while answering")).font(.system(size: 11)).foregroundColor(.secondary)
                            Text(highlight.apply(AttributedString(text))).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
                    }
                }
                HStack(spacing: 6) {
                    Spacer()
                    if let mentions = turn.mentions, !mentions.isEmpty {
                        // Called with @: who was asked, under the message.
                        Text("@ " + mentions.map { accountLabels[$0] ?? $0 }.joined(separator: ", "))
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    if let askedTime { timeText(askedTime) }
                    CopyButton(text: turn.question, key: "question-\(turn.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            if !turn.status.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    if turn.waitingApproval == true {
                        Text(L("승인 대기 중 · 아래 카드에서 허용하거나 거절하세요", "Waiting for your approval · allow or deny on the card below")).foregroundColor(.orange)
                    } else {
                        Text(turn.activity ?? turn.status).foregroundColor(.secondary)
                    }
                    // Project work: how long it has run and, after a quiet spell, when the AI last did something.
                    if turn.plan != nil || turn.lastActivityAt != nil, let asked = turn.askedAt {
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            Text(Self.timing(asked: asked, last: turn.waitingApproval == true ? nil : turn.lastActivityAt, now: context.date))
                                .foregroundColor(.secondary).monospacedDigit()
                        }
                    }
                }
                .font(turn.mode == 0 ? .system(size: 12) : .body)
                // Project work: the latest tool result, under what the AI is doing now.
                if let latest = turn.projectLog?.last {
                    Text(latest).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
                }
            }
            if let plan = turn.plan, !plan.isEmpty {
                WorkPlanView(steps: plan, note: turn.planNote, running: !turn.status.isEmpty)
            }
            if let error = turn.error {
                Text(error).foregroundColor(.red)
            }
            if (turn.modeVersion == 2 && (1...2).contains(turn.mode ?? 1)) || (turn.modeVersion == nil && turn.mode == 3) {
                Text(L("AI 발언 \(turn.entries.count)/\(turn.maxTurns ?? 9)", "AI turns \(turn.entries.count)/\(turn.maxTurns ?? 9)")
                     + (turn.turnsPerAI.map { L(" (AI마다 \($0)회)", " (\($0) each)") } ?? ""))
                    .font(.caption).foregroundColor(.secondary)
                if let focus = turn.debateFocus { Text(L("다음 논점: ", "Next focus: ") + focus).font(.callout).lineLimit(2).foregroundColor(.secondary) }
                if let reason = turn.endReason { Text(L("종료 이유: ", "End reason: ") + reason).font(.callout).foregroundColor(.secondary) }
            }
            if turn.modeVersion == 2 && turn.mode == 3, let coverage = turn.endReason {
                Text(coverage).font(.caption).foregroundColor(.secondary)
            }
            if turn.mode != 0, let changes = turn.workspaceChanges {
                changesView(changes, title: L("실제 변경 파일 \(changes.count)개", "\(changes.count) changed files"))
            }
            // Plain chat: Undo only when the answer changed a linked folder (the chat's own folder is not backed up).
            if turn.projectCommitted != true, turn.projectPushed != true, let backupPath = turn.backupPath, FileManager.default.fileExists(atPath: backupPath) && (turn.mode != 0 || (turn.workspaceChanges ?? []).contains { !$0.path.hasPrefix(chatFolder + "/") }) {
                Button(turn.undone == true ? L("되돌림 완료", "Restored") : L("되돌리기", "Undo file changes")) { discussion.undoWorkspace(turn) }
                    .disabled(turn.undone == true || busy)
            }
            if let tasks = turn.tasks {
                DisclosureGroup(L("작업 \(tasks.filter { $0.state == "done" }.count)/\(tasks.count) 완료 · 진행 \(tasks.filter { $0.state == "running" }.count)", "Tasks \(tasks.filter { $0.state == "done" }.count)/\(tasks.count) complete · \(tasks.filter { $0.state == "running" }.count) running")) {
                ForEach(tasks) { task in
                    HStack(alignment: .top) {
                        Image(systemName: task.state == "done" ? "checkmark.circle" : task.state == "running" ? "clock" : "circle")
                        VStack(alignment: .leading) {
                            Text(task.title).font(.callout).lineLimit(3)
                            Text((accountLabels[task.accountID] ?? task.accountID) + " · " + task.state).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if let path = task.output { Button(L("결과 열기", "Open result")) { discussion.openArtifact(path) } }
                    }
                }
            }
            }
            if let file = turn.artifact { Button(L("최종 결과물 열기", "Open final deliverable")) { discussion.openArtifact(file) } }
            if let options = turn.voteOptions {
                VoteResultView(options: options, votes: turn.votes)
            }
            if turn.mode == 0, let route = turn.routeChoice, let note = turn.routeNote {
                // Project chat with members: how the app answered this message, and the other ways for the newest one.
                HStack(spacing: 8) {
                    Label(note, systemImage: route.icon)
                        .font(.system(size: 11)).foregroundColor(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    if let meeting = turn.meetingRoom {
                        // The meeting's own chat (on this Mac only).
                        if discussion.conversations.contains(where: { $0.id == meeting }) {
                            Button(L("회의 과정 보기", "Show the meeting")) { discussion.open(meeting) }
                                .buttonStyle(.link).font(.system(size: 11))
                            if turn.final != nil {
                                Button(L("Space로 만들기", "Make a Space")) { discussion.makeSpace(from: turn, in: discussion.currentID) }
                                    .buttonStyle(.link).font(.system(size: 11))
                                    .help(L("회의 결론·합의·이견·결정할 것으로 새 결정 로그 Space를 만들어요", "Makes a new decision log Space from the meeting's conclusion, agreements, disagreements and open decisions"))
                            }
                        } else {
                            Text(L("회의 기록은 다른 Mac에 있어요", "The meeting record is on another Mac")).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    } else if last && !busy && (turn.final != nil || turn.error != nil) {
                        if route == .one {
                            Button(L("다른 AI 의견도 듣기", "Ask the others too")) { discussion.rerun(turn, as: .all) }
                                .buttonStyle(.link).font(.system(size: 11))
                                .help(L("같은 메시지를 다시 보내 모든 AI가 읽기만 하고 답해요.", "Sends the same message again: every AI answers, read only."))
                        }
                        if route == .work {
                            Button(L("의견으로 다시", "Ask for opinions")) { discussion.rerun(turn, as: .all) }
                                .buttonStyle(.link).font(.system(size: 11))
                                .help((turn.workspaceChanges ?? []).isEmpty
                                      ? L("같은 메시지를 의견 모드로 다시 보내요. 모두 읽기만 하고 답해요.", "Sends the same message again for opinions: everyone answers, read only.")
                                      : L("같은 메시지를 의견 모드로 다시 보내요. 이번 답에서 바뀐 파일은 그대로 남아요.", "Sends the same message again for opinions. Files this answer changed stay changed."))
                        } else {
                            Button(L("작업으로 다시", "Run as work")) { discussion.rerun(turn, as: .work) }
                                .buttonStyle(.link).font(.system(size: 11))
                                .help(L("같은 메시지를 작업 모드로 다시 보내요. 담당 AI가 작업하고 다른 AI가 검수해요.", "Sends the same message again as work: the lead works and the others review."))
                        }
                    }
                }
            }
            if turn.mode == 0, let note = turn.orderNote {
                Label(note, systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11)).foregroundColor(.orange)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.orange.opacity(0.10), in: Capsule())
            }
            if turn.mode == 0, let order = turn.answerOrder, order.count > 1 {
                // Several AIs answered at once: side by side (or one under the other), each reply as it is written.
                ParallelAnswers(turn: turn, order: order, highlight: highlight, answeredTime: answeredTime)
            } else if turn.mode == 0, let final = turn.final {
                // Plain chat: the answer reads like the desktop apps, without a card, under who wrote it.
                VStack(alignment: .leading, spacing: 8) {
                    if let by = turn.finalBy {
                        HStack(spacing: 6) {
                            Circle().fill(Account.Provider.of(speaker: by)?.color ?? .secondary).frame(width: 7, height: 7)
                            Text(by).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                        }
                    }
                    let pictures = Self.finalPictures(turn, final: final)
                    MarkdownText(text: final, size: 15, highlight: highlight, pictures: pictures)
                        .font(.system(size: 15))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !pictures.isEmpty { PictureList(images: pictures, text: final, size: 180) }
                    HStack(spacing: 6) {
                        CopyButton(text: final, key: "final-\(turn.id)")
                        if let answeredTime { timeText(answeredTime) }
                    }
                }
            } else if let final = turn.final {
                VStack(alignment: .leading, spacing: 6) {
                    let pictures = Self.finalPictures(turn, final: final)
                    MarkdownText(text: final, highlight: highlight, pictures: pictures)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !pictures.isEmpty { PictureList(images: pictures, text: final, size: 180) }
                    HStack(spacing: 6) {
                        if let by = turn.finalBy {
                            (Text(turn.mode == 0 ? L("답: ", "Answered by: ") : L("정리: ", "Final answer by: ")).foregroundColor(.secondary)
                             + Text(by).bold().foregroundColor(Account.Provider.of(speaker: by)?.color ?? .secondary))
                                .font(.caption)
                        }
                        CopyButton(text: final, key: "final-\(turn.id)")
                        if let answeredTime { timeText(answeredTime) }
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(10)
            }
            if turn.mode == 0 { RememberedLine(turnID: turn.id) }
            if let note = turn.spaceDraft { SpaceDraftCard(note: note, turn: turn, discussion: discussion, busy: busy) }
            if let edits = turn.spaceEdits, !edits.isEmpty { SpaceEditsView(notes: edits, discussion: discussion) }
            ForEach(turn.mode == 0 && (turn.answerOrder?.count ?? 0) < 2 ? (turn.moreAnswers ?? []) : []) { answer in
                // A second (third…) AI called with @, which answered at the same time without seeing the others.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(Account.Provider.of(speaker: answer.speaker)?.color ?? .secondary).frame(width: 7, height: 7)
                        Text(answer.speaker).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                    }
                    Group {
                        if answer.failed { Text(answer.text) } else { MarkdownText(text: answer.text, size: 15, highlight: highlight, pictures: answer.images ?? []) }
                    }
                        .font(.system(size: 15)).lineSpacing(5)
                        .foregroundColor(answer.failed ? .red : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let images = answer.images, !images.isEmpty { PictureList(images: images, text: answer.failed ? "" : answer.text, size: 180) }
                    if !answer.failed { CopyButton(text: answer.text, key: "answer-\(answer.id)") }
                }
                .padding(.top, 6)
            }
            if turn.mode == 0, let partial = turn.partial, !partial.isEmpty {
                // The reply as it is being written.
                VStack(alignment: .leading, spacing: 8) {
                    if let by = turn.partialBy {
                        HStack(spacing: 6) {
                            Circle().fill(Account.Provider.of(speaker: by)?.color ?? .secondary).frame(width: 7, height: 7)
                            Text(by).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                        }
                    }
                    MarkdownText(text: partial, size: 15)
                        .font(.system(size: 15))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if turn.mode == 0, let notes = turn.peerNotes, !notes.isEmpty {
                // Opinions the AI asked for and reviews of the work, one line each (click for the full text); with
                // collaboration "on its own" (Settings → Chat) folded into one line.
                if turn.peerFolded == true {
                    DisclosureGroup(L("AI끼리 협업 \(notes.count)건", "AIs worked together: \(notes.count)")) { peerCards(notes) }
                        .font(.callout)
                } else {
                    peerCards(notes)
                }
            }
            if turn.mode == 0, turn.status.isEmpty, let log = turn.projectLog, !log.isEmpty {
                DisclosureGroup(L("작업 기록 \(log.count)개", "\(log.count) project steps")) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .font(.callout)
            }
            if turn.mode == 0, let changes = turn.workspaceChanges {
                changesView(changes, title: L("이 대화 폴더의 파일 \(changes.count)개", "\(changes.count) files in this chat's folder"))
                    .font(.callout)
            }
            if turn.mode != 0, let note = turn.orderNote {
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

    private func timeText(_ time: String) -> some View {
        Text(time).font(.system(size: 11)).foregroundColor(.secondary)
    }

    private func attachedImages(_ images: [ChatImage]) -> some View {
        HStack(spacing: 8) {
            ForEach(images) { item in
                Button(action: { PhotoViewer.shared.show(item) }) {
                    AttachmentThumbnail(item: item, size: 120)
                }
                .buttonStyle(.plainHit)
                .help(item.name)
                .contextMenu { PhotoViewer.menu(item) }
                .accessibilityLabel(L("첨부 이미지 열기: ", "Open attached image: ") + item.name)
            }
        }
    }

    // Files an answer created or changed, each with Open and Finder.
    private func changesView(_ changes: [WorkspaceChange], title: String) -> some View {
        DisclosureGroup(title) {
            ForEach(changes) { change in
                HStack {
                    Text(change.kind + " · " + change.path).font(.caption).textSelection(.enabled)
                    if change.kind.hasPrefix("cloud-") {
                        // Only in the cloud before the answer, so not in the backup.
                        Text(L("되돌리기 안 됨 · 클라우드 버전 기록으로 복구", "Not undoable · restore from the cloud's version history"))
                            .font(.caption).foregroundColor(.orange)
                            .help(L("이 파일은 답하기 전에 클라우드에만 있어서 백업하지 않았어요. Google Drive는 버전 기록과 휴지통(30일), iCloud는 최근 삭제된 항목(30일)에서 되찾을 수 있어요.",
                                    "This file was only in the cloud before the answer, so it was not backed up. Google Drive keeps versions and a trash (30 days); iCloud keeps Recently Deleted (30 days)."))
                    }
                    Spacer()
                    if !change.kind.hasSuffix("deleted") { Button(L("파일 열기", "Open file")) { discussion.openArtifact(change.path) } }
                    Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: change.path)]) }
                }
            }
        }
    }

    private func peerCards(_ notes: [ChatTurn.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(notes) { entry in
                EntryRow(entry: entry,
                         isOpen: Binding(get: { openEntries.contains(entry.id) },
                                         set: { if $0 { discussion.openEntries.insert(entry.id) } else { discussion.openEntries.remove(entry.id) } }),
                         label: entry.speaker)
                // A meeting the AI convened (convene_meeting): its result went to that AI; the speeches are in its own chat.
                if let meeting = entry.meeting, discussion.conversations.contains(where: { $0.id == meeting }) {
                    Button(L("회의 과정 보기", "Show the meeting")) { discussion.open(meeting) }
                        .buttonStyle(.link).font(.system(size: 11))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    // Entries are appended as each AI finishes; preserve that arrival order on screen.
    // Each shows one short line; clicking it opens the full reply (and the moderator's focus).
    private var entriesView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(turn.entries) { entry in
                EntryRow(entry: entry,
                         isOpen: Binding(get: { openEntries.contains(entry.id) },
                                         set: { if $0 { discussion.openEntries.insert(entry.id) } else { discussion.openEntries.remove(entry.id) } }),
                         label: (turn.modeVersion == 2 || (turn.mode ?? 1) >= 2) ? entry.speaker : "\(entry.round == 1 ? L("각자 답", "Initial answer") : L("검토 후", "After review")) · \(entry.speaker)")
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // The final answer's own pictures, plus named team pictures using localized [Picture N] markers.
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

}

// One chat window, reused. Conversations are saved, so closing it loses nothing.
// While it is open the app shows in the Dock and ⌘Tab like a normal app (so it can be kept in the Dock);
// closed, it is a menu bar app again. A Dock icon kept there reopens the chat (applicationShouldHandleReopen).
public final class ChatWindow {
    private static func host<M: ChatSettings>(_ discussion: Discussion, _ model: M) -> NSViewController {
        let host = NSHostingController(rootView: ChatView(discussion: discussion, model: model))
        // Keep content changes from renegotiating window size during a native drag.
        host.sizingOptions = []
        return host
    }
    private var window: NSWindow?
    private var closing: NSObjectProtocol?
    public init() {}

    public func show(discussion: Discussion) {
        if window == nil {
            let host = Self.host(discussion, discussion.model)
            let w = ChatDragWindow(contentViewController: host)
            w.title = L("AI Illuminati 채팅", "AI Illuminati Chat")
            // One surface from the title bar down, like the desktop chat apps.
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            // Opaque title bar on purpose (see WindowDrag.swift): a transparent one jumps between displays.
            w.titlebarSeparatorStyle = .none
            w.titleVisibility = .hidden
            w.minimumContentSize = ChatViewSize.minSize
            w.setContentSize(NSSize(width: 1040, height: 720))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                ProjectCenter.shared.cancel()
                NSApp.setActivationPolicy(.accessory)
                // Reopened later, the chat starts again from its latest turns.
                discussion.showLatestTurns()
                ChatNotes.shared.flush()
                // No chat open: Gemma need not hold its memory (an answer under way finishes first).
                if discussion.model.hasLocal {
                    LocalModel.unloadWhenIdle(busy: { discussion.anyRunning }, reopened: { self?.window?.isVisible == true })
                }
            }
        }
        ProjectCenter.shared.resume()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        discussion.focusRequest += 1   // opened from the menu or the Dock: type right away
    }
}

// Native editor: Return handling stays with the editor, including Korean IME composition.
final class ChatInputTextView: NSTextView {
    var onSend: (() -> Void)?
    var onKey: ((NSEvent, NSTextView) -> Bool)?   // the @ list: numbers, arrows, Return, Esc, ⌫ on a picked name
    var onPasteImages: ((NSPasteboard) -> Bool)?
    var wantsFocus = false   // asked for the typing before it was in a window

    func takeFocus() {
        guard let window else { wantsFocus = true; return }
        wantsFocus = false
        window.makeFirstResponder(self)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocus { takeFocus() }
    }

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
        if !hasMarkedText(), onKey?(event, self) == true { return }
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
    var onKey: ((NSEvent, NSTextView) -> Bool)? = nil
    var onTextChange: ((NSTextView) -> Void)? = nil
    var focusRequest = 0   // a new value (or a new box) takes the typing, so no click is needed

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
        editor.font = .systemFont(ofSize: 14)
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 0, height: 2)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.onSend = onSend
        editor.onPasteImages = onPasteImages
        editor.onKey = onKey
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
        editor.onKey = onKey
        editor.setAccessibilityLabel(L("질문 입력", "Message"))
        if editor.string != text && !editor.hasMarkedText() { editor.string = text; onTextChange?(editor) }
        context.coordinator.measure(editor)
        if context.coordinator.focused != focusRequest {
            context.coordinator.focused = focusRequest
            DispatchQueue.main.async { editor.takeFocus() }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineInput
        var focused: Int?
        init(_ parent: MultilineInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            parent.onTextChange?(editor)
            measure(editor)
        }
        // Grows with the text from one line (at least 40 pt, like the desktop apps) up to about 8 lines.
        func measure(_ editor: NSTextView) {
            guard let layout = editor.layoutManager, let container = editor.textContainer else { return }
            layout.ensureLayout(for: container)
            let lineHeight = layout.defaultLineHeight(for: editor.font ?? .systemFont(ofSize: 14))
            let textHeight = max(lineHeight, ceil(layout.usedRect(for: container).height))
            let measured = min(180, max(40, textHeight + 4))
            DispatchQueue.main.async { [weak self] in
                guard let self, abs(self.parent.height - measured) > 1 else { return }
                self.parent.height = measured
            }
        }
    }
}

// Which side panels fit in the chat window (no @State: see DriveUI.swift). Published only when one changes.
private final class ChatLayout: ObservableObject {
    static let shared = ChatLayout()
    @Published private(set) var wide = true
    @Published private(set) var notesFit = true
    @Published private(set) var notesFitAlone = true

    func measure(_ width: CGFloat) {
        let isWide = width >= ChatViewSize.sidebarFits
        let fit = width - ChatViewSize.sidebarWidth - 1 - ChatViewSize.notesWidth >= ChatViewSize.wide
        let fitAlone = width - ChatViewSize.notesWidth >= ChatViewSize.wide
        if isWide != wide { wide = isWide }
        if fit != notesFit { notesFit = fit }
        if fitAlone != notesFitAlone { notesFitAlone = fitAlone }
    }
}

// Which Copy button was pressed last, so it shows a check mark for a moment (no @State: see DriveUI.swift).
private final class CopyFeedback: ObservableObject {
    static let shared = CopyFeedback()
    @Published var copied: String?
}

// A small Copy button under a message or an answer, like the desktop apps. Copies the text as written (Markdown).
private struct CopyButton: View {
    let text: String
    let key: String
    @ObservedObject var feedback = CopyFeedback.shared

    var body: some View {
        let done = feedback.copied == key
        Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            feedback.copied = key
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if feedback.copied == key { feedback.copied = nil } }
        }) {
            Image(systemName: done ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
        .foregroundColor(.secondary)
        .help(done ? L("복사했어요", "Copied") : L("복사", "Copy"))
        .accessibilityLabel(L("복사", "Copy"))
    }
}

// The chat's notes on the right: only the user edits them; each answer reads them (see ChatNotes).
private struct NotesPanel: View {
    let room: UUID
    let close: () -> Void
    @ObservedObject var notes = ChatNotes.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(L("메모", "Notes")).font(.system(size: 13, weight: .medium))
                WindowDragRegion().frame(maxWidth: .infinity, maxHeight: .infinity)
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 11)).frame(width: 22, height: 22) }
                    .buttonStyle(.plainHit).foregroundColor(.secondary)
                    .help(L("메모 접기", "Hide notes"))
            }
            .padding(.horizontal, 14).frame(height: 40)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $notes.text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel(L("이 대화의 메모", "Notes for this chat"))
                if notes.text.isEmpty {
                    Text(L("이 대화의 메모예요. 나만 고칠 수 있고, AI는 답할 때 읽기만 해요.",
                           "Notes for this chat. Only you edit them; the AI reads them when it answers."))
                        .font(.system(size: 13)).foregroundColor(.secondary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 10)
            Text(L("AI는 읽기만 해요", "The AI only reads these"))
                .font(.system(size: 11)).foregroundColor(.secondary)
                .padding(.horizontal, 14).padding(.bottom, 12)
        }
        .frame(width: ChatViewSize.notesWidth)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.035))
        .onAppear { notes.open(room) }
        .onChange(of: room) { notes.open($0) }
        .onDisappear { notes.flush() }
    }
}

// Pictures an AI made: a row of thumbnails, each opening large over the chat (PhotoOverlay).
private struct PictureStrip: View {
    let images: [ChatImage]
    let size: CGFloat
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { item in
                    Button(action: { PhotoViewer.shared.show(item) }) {
                        AttachmentThumbnail(item: item, size: size)
                    }
                    .buttonStyle(.plainHit)
                    .help(item.name)
                    .contextMenu { PhotoViewer.menu(item) }
                    .accessibilityLabel(L("그림 열기: ", "Open picture: ") + item.name)
                }
            }
        }
    }
}

// A picture where its marker was in the reply: as wide as the chat allows, at most `maxSide` points
// and never larger than the picture itself.
struct InlinePicture: View {
    let item: ChatImage
    let maxSide: CGFloat
    var body: some View {
        Button(action: { PhotoViewer.shared.show(item) }) {
            if let image = AttachmentThumbnail.thumbnail(item.url, size: maxSide) {
                // The copy is twice maxSide in pixels, so half its pixels is the picture's own size, capped at maxSide.
                let w = image.size.width / 2, h = image.size.height / 2
                let fit = min(1, maxSide / max(w, h, 1))
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: max(1, w * fit))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "photo").foregroundColor(.secondary)
                    .frame(width: 120, height: 90).background(Color.secondary.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .buttonStyle(.plainHit)
        .help(item.name)
        .contextMenu { PhotoViewer.menu(item) }
        .accessibilityLabel(L("그림 열기: ", "Open picture: ") + item.name)
    }
}

// Under a reply: one line "그림 3개 · 모두 저장"; opened, a small list with a save button for each picture.
// Pictures the text has no place for (no marker line) keep their preview row here.
private final class PictureListFold: ObservableObject { @Published var expanded = false }
private struct PictureList: View {
    let images: [ChatImage]
    let text: String
    let size: CGFloat
    @StateObject private var fold = PictureListFold()

    var body: some View {
        let placed = ChatMarkdown.placedPictures(text)
        let loose = images.filter { !placed.contains($0.name) }
        VStack(alignment: .leading, spacing: 6) {
            if !loose.isEmpty { PictureStrip(images: loose, size: size) }
            HStack(spacing: 6) {
                Button(action: { fold.expanded.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "photo.on.rectangle")
                        Text(images.count == 1 ? L("그림 1개", "1 picture") : L("그림 \(images.count)개", "\(images.count) pictures"))
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(fold.expanded ? 90 : 0))
                    }
                    .frame(minHeight: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plainHit)
                .help(fold.expanded ? L("목록 접기", "Hide the list") : L("그림 목록 보기", "Show the pictures"))
                Text("·")
                Button(L("모두 저장", "Save all")) { PhotoViewer.saveAll(images) }
                    .buttonStyle(.link)
                    .help(L("그림을 모두 한 폴더에 저장해요", "Saves every picture into one folder"))
            }
            .font(.system(size: 12)).foregroundColor(.secondary)
            if fold.expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(images) { item in
                        HStack(spacing: 8) {
                            Button(action: { PhotoViewer.shared.show(item) }) { AttachmentThumbnail(item: item, size: 32) }
                                .buttonStyle(.plainHit)
                                .help(L("크게 보기", "View large"))
                            Text(item.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            Button(action: { PhotoViewer.save(item) }) {
                                Image(systemName: "square.and.arrow.down").font(.system(size: 12)).frame(width: 22, height: 22)
                            }
                            .buttonStyle(.plainHit).foregroundColor(.secondary)
                            .help(L("저장…", "Save…"))
                            .accessibilityLabel(L("저장: ", "Save: ") + item.name)
                        }
                        .contextMenu { PhotoViewer.menu(item) }
                    }
                }
                .padding(.leading, 4)
            }
        }
    }
}

// The photo clicked in the chat, shown large over the window (no @State: see DriveUI.swift). Clicking it again closes it.
final class PhotoViewer: ObservableObject {
    static let shared = PhotoViewer()
    @Published var image: ChatImage?
    // The chat a picture belongs to, for its saved file name (set by the chat window).
    var chatTitle: (UUID) -> String? = { _ in nil }

    func show(_ item: ChatImage) { image = image?.id == item.id ? nil : item }

    // Preview, Finder and Save stay one right-click away.
    @ViewBuilder static func menu(_ item: ChatImage) -> some View {
        Button(L("미리보기에서 열기", "Open in Preview")) { NSWorkspace.shared.open(item.url) }
        Button(L("Finder에서 보기", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Button(L("저장…", "Save…")) { save(item) }
    }

    private static func fileName(_ item: ChatImage) -> String {
        Pictures.saveName(chat: shared.chatTitle(item.conversationID), picture: item.name)
    }

    // One picture, where the user picks (the panel asks before replacing a file).
    static func save(_ item: ChatImage) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName(item)
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url,
              url.standardizedFileURL.resolvingSymlinksInPath() != item.url.standardizedFileURL.resolvingSymlinksInPath() else { return }
        // Copied next to the target first, then swapped in: a failed copy leaves the old file as it was.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).png")
        do {
            try FileManager.default.copyItem(at: item.url, to: temporary)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            failed(error)
        }
    }

    // Every picture into one folder; a name already there gets a number ("… 2.png"), nothing is replaced.
    static func saveAll(_ items: [ChatImage]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("저장", "Save")
        panel.message = L("그림 \(items.count)개를 저장할 폴더를 골라 주세요.", "Choose a folder for the \(items.count) pictures.")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        var saved: [URL] = []
        for item in items {
            let name = Pictures.freeName(fileName(item)) { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            let url = folder.appendingPathComponent(name)
            do { try FileManager.default.copyItem(at: item.url, to: url); saved.append(url) } catch { failed(error); break }
        }
        if !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
    }

    private static func failed(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("그림을 저장하지 못했어요", "Could not save the picture")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

// One photo as large as the window allows, over a dimmed chat. A click beside it or Esc closes it;
// double-click opens it in Preview.
private struct PhotoOverlay: View {
    let item: ChatImage
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).contentShape(Rectangle()).onTapGesture(perform: close)
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    // Room for the window's traffic lights; the bar still moves the window.
                    WindowDragRegion().frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text(item.name).font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                        .lineLimit(1).truncationMode(.middle)
                    WindowDragRegion().frame(maxWidth: .infinity, maxHeight: .infinity)
                    Button(action: { NSWorkspace.shared.open(item.url) }) {
                        Image(systemName: "arrow.up.forward.square").font(.system(size: 14)).frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plainHit).foregroundColor(.white.opacity(0.85))
                    .help(L("미리보기에서 열기", "Open in Preview"))
                    Button(action: { PhotoViewer.save(item) }) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 14)).frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plainHit).foregroundColor(.white.opacity(0.85))
                    .help(L("저장…", "Save…"))
                    Button(action: close) { Image(systemName: "xmark").font(.system(size: 13)).frame(width: 28, height: 28) }
                        .buttonStyle(.plainHit).foregroundColor(.white.opacity(0.85))
                        .keyboardShortcut(.cancelAction)
                        .help(L("사진 닫기 (Esc)", "Close photo (Esc)"))
                }
                .padding(.leading, 80).padding(.trailing, 12).frame(height: 44)
                Group {
                    // Chat pictures are stored at most 1600 px on a side (ImageStore), so reading the whole file is fine.
                    if let image = NSImage(contentsOf: item.url) {
                        Image(nsImage: image).resizable().scaledToFit()
                            // Never blown up past the picture's own size: a small icon stays sharp.
                            .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(color: .black.opacity(0.4), radius: 16)
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
                            .contextMenu { PhotoViewer.menu(item) }
                            .accessibilityLabel(item.name)
                    } else {
                        Text(L("사진을 열 수 없어요", "Could not open the photo")).font(.callout).foregroundColor(.white.opacity(0.8))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 32).padding(.bottom, 32)
            }
        }
        .transition(.opacity)
    }
}

struct AttachmentThumbnail: View {
    let item: ChatImage
    let size: CGFloat
    var body: some View {
        Group {
            if let image = Self.thumbnail(item.url, size: size) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").foregroundColor(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // A small copy (twice the shown size, for Retina), read once: redrawing the chat must not decode full pictures again.
    // Missing files are not remembered, so a picture still being written shows once it exists.
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()

    static func thumbnail(_ url: URL, size: CGFloat) -> NSImage? {
        let key = "\(Int(size))|\(url.path)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceShouldCacheImmediately: true,
                       kCGImageSourceThumbnailMaxPixelSize: Int(size * 2)] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let image = NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height))
        cache.setObject(image, forKey: key)
        return image
    }
}

// Photos from Finder, the Photos app or a screenshot thumbnail (see PictureDrop).
private struct ImageAttachmentDropDelegate: DropDelegate {
    let discussion: Discussion
    func validateDrop(info: DropInfo) -> Bool {
        // The board and Project info take their own drops; the chat behind them is not shown.
        !discussion.running && !discussion.viewingBoard && (info.hasItemsConforming(to: [UTType.fileURL, UTType.image]) || PictureDrop.hasPromises())
    }
    func dropEntered(info: DropInfo) { discussion.imageDropActive = validateDrop(info: info) }
    func dropExited(info: DropInfo) { discussion.imageDropActive = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: validateDrop(info: info) ? .copy : .forbidden) }
    func performDrop(info: DropInfo) -> Bool {
        discussion.imageDropActive = false
        guard validateDrop(info: info) else { return false }
        let conversationID = discussion.currentID
        PictureDrop.receive(info.itemProviders(for: [UTType.image])) { urls, folder in
            defer { if let folder { try? FileManager.default.removeItem(at: folder) } }
            guard discussion.currentID == conversationID, !discussion.running else { return }
            if urls.isEmpty { discussion.attachmentError = L("파일을 첨부할 수 없습니다.", "Could not attach file."); return }
            // Pictures attach, others (PDFs…) are linked whole. Promised files (Mail, …) sit in a temporary
            // folder removed below, so those are first copied into the chat's own folder.
            guard folder != nil else { discussion.attachFiles(urls); return }
            do { discussion.attachFiles(try RoomDocuments.keepDropped(urls, room: conversationID)) }
            catch { discussion.attachmentError = L("파일을 첨부할 수 없습니다.", "Could not attach file.") }
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
            .buttonStyle(.plainHit)
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
                    MarkdownText(text: entry.text).textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }
        }
    }

}

// Each AI's own color for its name in the chat, close to its company's brand color.
// A lighter shade in dark mode and a deeper one in light mode keep it readable on both.
extension Account.Provider {
    public var color: Color {
        let (dark, light): (NSColor, NSColor)
        switch self {
        case .claude: (dark, light) = (NSColor(srgbRed: 0.88, green: 0.55, blue: 0.42, alpha: 1), NSColor(srgbRed: 0.74, green: 0.36, blue: 0.22, alpha: 1))
        case .codex: (dark, light) = (NSColor(srgbRed: 0.27, green: 0.76, blue: 0.60, alpha: 1), NSColor(srgbRed: 0.05, green: 0.53, blue: 0.41, alpha: 1))
        case .gemini: (dark, light) = (NSColor(srgbRed: 0.45, green: 0.66, blue: 0.99, alpha: 1), NSColor(srgbRed: 0.10, green: 0.45, blue: 0.91, alpha: 1))
        case .ollama: (dark, light) = (NSColor(srgbRed: 0.72, green: 0.58, blue: 0.98, alpha: 1), NSColor(srgbRed: 0.45, green: 0.30, blue: 0.80, alpha: 1))
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    // Speaker labels start with the AI's name (for example, "Claude (Work)"), so older replies get a color too.
    static func of(speaker: String) -> Self? { allCases.first { speaker.hasPrefix($0.title) } }
}

// Several AIs answering one message at once (Solo.swift): one column each, in the order they were called, with
// its reply as it is written, then the finished reply (or the error in red). Two fit side by side; three or more
// scroll sideways; a narrow window, or "one under the other" (remembered), stacks them.
private struct ParallelAnswers: View {
    let turn: ChatTurn
    let order: [String]
    let highlight: FindHighlight
    let answeredTime: String?
    @AppStorage("answersSideBySide") private var sideBySide = true

    typealias Column = ChatTurn.Column

    var body: some View {
        let columns = turn.columns(order)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button(action: { sideBySide.toggle() }) {
                    Label(sideBySide ? L("위아래로 보기", "One under the other") : L("나란히 보기", "Side by side"),
                          systemImage: sideBySide ? "rectangle.split.1x2" : "rectangle.split.2x1")
                        .font(.system(size: 11))
                }
                .buttonStyle(.link)
                .help(L("여러 AI의 답을 나란히 또는 위아래로 보여 줘요. 고른 방식은 기억해요.", "Shows the AIs' replies side by side or one under the other. Your choice is kept."))
            }
            if sideBySide {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        // ViewThatFits measures the ideal width, and a reply's text would report its whole length on one line.
                        ForEach(columns) { column in card(column).frame(minWidth: 280, idealWidth: 280, maxWidth: .infinity, alignment: .topLeading) }
                    }
                    if columns.count > 2 {
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(columns) { column in card(column).frame(width: 320, alignment: .topLeading) }
                            }
                            .padding(.bottom, 8)
                        }
                        // ViewThatFits measures the ideal width: sideways scrolling needs room for about two columns.
                        .frame(minWidth: 600, idealWidth: 600, maxWidth: .infinity)
                    }
                    stacked(columns)
                }
            } else {
                stacked(columns)
            }
        }
    }

    private func stacked(_ columns: [Column]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(columns) { column in content(column).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    private func card(_ column: Column) -> some View {
        content(column)
            .padding(12)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func content(_ column: Column) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Account.Provider.of(speaker: column.name)?.color ?? .secondary).frame(width: 7, height: 7)
                Text(column.name).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                if column.writing { ProgressView().controlSize(.mini) }
            }
            if let text = column.text {
                let pictures = column.final ? TurnView.finalPictures(turn, final: text) : column.images
                Group {
                    if column.failed { Text(text) } else { MarkdownText(text: text, size: 15, highlight: column.writing ? FindHighlight() : highlight, pictures: pictures) }
                }
                .font(.system(size: 15)).lineSpacing(5)
                .foregroundColor(column.failed ? .red : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !pictures.isEmpty { PictureList(images: pictures, text: column.failed ? "" : text, size: 160) }
                if column.done && !column.failed {
                    HStack(spacing: 6) {
                        CopyButton(text: text, key: "answer-\(turn.id)-\(column.id)")
                        if let answeredTime { Text(answeredTime).font(.system(size: 11)).foregroundColor(.secondary) }
                    }
                }
            } else {
                Text(column.writing ? L("쓰는 중…", "Writing…") : L("답 없음", "No reply"))
                    .font(.system(size: 13)).foregroundColor(.secondary)
            }
        }
    }
}

// What an AI saved to memory in this answer (Memory.swift), with Undo.
// The project AI's steps: folded, one line ("3/5 · 테스트 실행 · test [7/9] Compile app tests"); unfolded, every step
// with its state and how long it took (the current one counts up), and under it the test/build stage it is in.
// (Folded state in an ObservableObject: this Mac's Command Line Tools cannot build SwiftUI's @State macro.)
private final class WorkPlanFold: ObservableObject { @Published var expanded = false }
private struct WorkPlanView: View {
    let steps: [WorkStep]
    let note: String?
    let running: Bool
    @StateObject private var fold = WorkPlanFold()

    var body: some View {
        // Times count up only while the work runs; a saved or interrupted turn shows no live time.
        TimelineView(.periodic(from: .now, by: running ? 1 : 3600)) { context in content(context.date) }
    }

    private func content(_ now: Date) -> some View {
        let done = steps.filter { $0.status == .done }.count
        let current = steps.first { $0.status == .doing } ?? steps.first { $0.status == .blocked }
        return DisclosureGroup(isExpanded: $fold.expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: Self.icon(step.status)).foregroundColor(Self.color(step.status)).frame(width: 14)
                        Text(step.text).foregroundColor(step.status == .done ? .secondary : .primary).lineLimit(3)
                        Spacer(minLength: 8)
                        if let time = Self.duration(step, now: now, running: running) {
                            Text(time).foregroundColor(.secondary).monospacedDigit()
                        }
                    }
                    if running, step.status == .doing, let sub = step.sub {
                        HStack(spacing: 6) {
                            Text(sub).foregroundColor(.secondary).lineLimit(1)
                            Spacer(minLength: 8)
                            if let since = step.subStarted { Text(Self.clock(now.timeIntervalSince(since))).foregroundColor(.secondary).monospacedDigit() }
                        }
                        .font(.system(size: 11)).padding(.leading, 20)
                    }
                }
                if let note { Text(L("바뀐 이유: ", "Changed: ") + note).foregroundColor(.secondary).lineLimit(2).padding(.top, 2) }
            }
            .padding(.top, 4)
        } label: {
            Text(L("작업 \(done)/\(steps.count)", "Steps \(done)/\(steps.count)")
                 + (running ? current.map { " · " + $0.text + ($0.status == .doing ? $0.sub.map { " · " + $0 } ?? "" : "") } ?? "" : ""))
                .lineLimit(1)
                // The arrow alone is too small to hit: the whole line folds and unfolds.
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { fold.expanded.toggle() } }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    // Done or blocked: how long it took. Doing: so far, only while running. No start time (older chats): nothing.
    static func duration(_ step: WorkStep, now: Date, running: Bool) -> String? {
        guard let started = step.started else { return nil }
        if let ended = step.ended { return clock(ended.timeIntervalSince(started)) }
        return running && step.status == .doing ? clock(now.timeIntervalSince(started)) : nil
    }
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func icon(_ status: WorkStep.Status) -> String {
        switch status {
        case .done: return "checkmark.circle.fill"
        case .doing: return "circle.dotted"
        case .blocked: return "exclamationmark.circle"
        case .todo: return "circle"
        }
    }
    static func color(_ status: WorkStep.Status) -> Color {
        switch status {
        case .done: return .green
        case .doing: return .accentColor
        case .blocked: return .orange
        case .todo: return .secondary
        }
    }
}

private struct RememberedLine: View {
    let turnID: UUID
    @ObservedObject var memory = MemoryStore.shared

    var body: some View {
        let saved = memory.data.items.filter { $0.turn == turnID }
        if !saved.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(saved) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "brain.head.profile").foregroundColor(.secondary)
                        Text(L("기억함: ", "Remembered: ") + item.text).foregroundColor(.secondary).lineLimit(2)
                        Button(L("취소", "Undo")) { memory.remove(item.id) }
                            .buttonStyle(.link)
                            .help(L("이 기억을 지워요.", "Removes this from memory."))
                    }
                    .font(.system(size: 11))
                }
            }
        }
    }
}

// These are app-generated notices saved with a chat, never user or AI messages.
func localizedNotice(_ text: String) -> String {
    for prefix in ["다음 순서: ", "Next order: "] where text.hasPrefix(prefix) {
        return L("다음 순서: ", "Next order: ") + text.dropFirst(prefix.count)
    }
    let notices = [
        ("대표의 순서 지정에 실패해 기존 순서를 유지합니다.", "Scheduling failed. Keeping the current order."),
        ("대표가 발언하지 못해 기존 순서를 유지합니다.", "The moderator was unavailable. Keeping the current order.")
    ]
    for (ko, en) in notices where text == ko || text == en { return L(ko, en) }
    return text
}
