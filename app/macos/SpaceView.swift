import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AIAccounts
import AILocalization
import AISpaces
import AIRuntime
import AIProjects
import AIChat

// Spaces on screen (Space.swift): a Space in place of the chat with its change box below, the preview card an
// answer's <space-build> leaves in the chat, the sidebar's Spaces and "Make a Space" on a meeting's result.
// Nothing here runs commands or approves work: a page may only move the user somewhere (a link asks first).

// The talk that changes a Space: who is answering, the new version waiting to be applied, the last notice.
final class SpaceRefiner: ObservableObject {
    static let shared = SpaceRefiner()
    struct Pending: Equatable { var build: SpaceBuild; var migrated: Data?; var by: String; var request: String }
    @Published var busy: [String: String] = [:]        // Space → who is answering
    @Published var pending: [String: Pending] = [:]
    @Published var notes: [String: String] = [:]       // Space → the last refusal, failure or page notice
    @Published var drafts: [String: String] = [:]      // the change box's text per Space
    var cancels: [String: DebateCancellation] = [:]

    // The Spaces folder checked when the app comes to the front (an editor or another tool may have changed it), unless
    // an answer is still writing there. A refusal shows in that Space.
    private static var watcher: NSObjectProtocol?
    static func watchLibrary() {
        check()
        watcher = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in check() }
    }
    // The stop button of a Space's change box: only this Space's talk stops.
    func stop(_ id: String) {
        cancels[id]?.cancel()
        cancels[id] = nil
        busy[id] = nil
    }

    // The previewed version applied. With migrate, it runs again on the data as it is now (the user may have checked
    // something since the preview), and that result is saved.
    func apply(_ id: String) {
        let refiner = self
        guard let pending = refiner.pending[id] else { return }
        func save(_ state: Data?) {
            do {
                try SpaceStore.shared.apply(id, html: pending.build.html, state: state, note: String(pending.request.prefix(80)),
                                            name: pending.build.name, icon: pending.build.icon, color: pending.build.color)
                refiner.pending[id] = nil
            } catch {
                refiner.notes[id] = (error as? SpaceBad)?.reason ?? error.localizedDescription
            }
        }
        guard let migrate = pending.build.migrate else { return save(nil) }
        refiner.busy[id] = L("데이터 옮기는 중", "Moving the data")
        SpaceMigrator.run(migrate, state: SpaceStore.state(SpaceStore.folder(id))) { result in
            refiner.busy[id] = nil
            switch result {
            case .success(let data): save(data)
            case .failure(let bad): refiner.notes[id] = bad.reason
            }
        }
    }

    static func check() {
        guard !SpaceLibrary.busy else { return }
        for note in SpaceStore.shared.syncLibrary() where note.kind == "refused" || note.kind == "set-aside" {
            shared.notes[note.space] = SpaceEditsView.text(note)
        }
    }
}

extension Discussion {
    func openSpace(_ id: String) {
        SpaceRefiner.check()
        guard SpaceStore.shared.manifest(id) != nil else { return }
        viewingRemote = nil; viewingBoard = false; sidebarOverlay = false
        viewingSpace = id
    }

    // The Space button in the message box: with words, they are sent as a Space request; without, it starts one.
    func askForSpace() {
        let prefix = L("Space 만들어 줘: ", "Make a Space: ")
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty { draft = prefix; return }
        if !Route.asksSpace(typed) { draft = prefix + typed }
        send()
    }

    private func changeSpaceNote(_ turnID: UUID, in room: UUID, _ body: @escaping (inout SpaceDraftNote) -> Void) {
        change(room, save: true) { c in
            guard let i = c.turns.firstIndex(where: { $0.id == turnID }), var note = c.turns[i].spaceDraft else { return }
            body(&note); c.turns[i].spaceDraft = note
        }
    }

    func addDraftSpace(_ turn: ChatTurn, in room: UUID) {
        guard let draft = turn.spaceDraft?.draft else { return }
        do {
            let made = try SpaceStore.shared.adopt(draft: draft, origin: room, lock: lock(of: room))
            changeSpaceNote(turn.id, in: room) { $0.space = made.id; $0.draft = nil }
            if folds.isFolded("spaces") { folds.toggle("spaces") }
        } catch {
            changeSpaceNote(turn.id, in: room) { $0.reason = (error as? SpaceBad)?.reason ?? error.localizedDescription }
        }
    }

    func discardDraftSpace(_ turn: ChatTurn, in room: UUID) {
        if let draft = turn.spaceDraft?.draft { SpaceStore.discardDraft(draft) }
        changeSpaceNote(turn.id, in: room) { $0.discarded = true; $0.draft = nil }
    }

    // The same request again; a refused build sends its reason along, so the AI can fix it.
    func rebuildSpace(_ turn: ChatTurn, in room: UUID) {
        let reason = turn.spaceDraft?.reason
        if let draft = turn.spaceDraft?.draft { SpaceStore.discardDraft(draft) }
        changeSpaceNote(turn.id, in: room) { $0.discarded = true; $0.draft = nil }
        var question = L("Space 다시 만들어 줘: ", "Make the Space again: ") + turn.question
        if let reason { question += L("\n(앞의 Space는 검사에서 거부됐어요: ", "\n(The last one was refused by the checks: ") + reason + ")" }
        if let problem = startTurn(room: room, question: question) { attachmentError = problem }
    }

    // A chat's change to an existing Space: shown as that Space's preview (migrate run first), applied there.
    func reviewSpaceChange(_ turn: ChatTurn) {
        let refiner = SpaceRefiner.shared
        guard let note = turn.spaceDraft, let id = note.target, let draft = note.draft, SpaceStore.shared.manifest(id) != nil,
              refiner.busy[id] == nil, let build = SpaceStore.draftBuild(draft) else { return }
        let by = L("채팅의 변경안", "A chat's change")
        func show(_ migrated: Data?) {
            refiner.notes[id] = nil
            refiner.pending[id] = .init(build: build, migrated: migrated, by: by, request: turn.question)
            openSpace(id)
        }
        guard let migrate = build.migrate else { return show(nil) }
        refiner.busy[id] = L("데이터 옮기는 중", "Moving the data")
        SpaceMigrator.run(migrate, state: SpaceStore.state(SpaceStore.folder(id))) { result in
            refiner.busy[id] = nil
            switch result {
            case .success(let data): show(data)
            case .failure(let bad):
                refiner.notes[id] = L("데이터 옮기기(migrate)가 실패해 적용하지 않았어요: ", "Moving the data (migrate) failed, so nothing changed: ") + bad.reason
                self.openSpace(id)
            }
        }
    }

    private var folds: SidebarFold { SidebarFold.shared }

    // A meeting's result becomes a new decision log Space.
    func makeSpace(from turn: ChatTurn, in room: UUID) {
        guard let result = turn.final else { return }
        let chat = conversations.first { $0.id == room }
        let number = (chat?.turns.firstIndex { $0.id == turn.id } ?? 0) + 1
        let day = DateFormatter.localizedString(from: turn.answeredAt ?? Date(), dateStyle: .short, timeStyle: .short)
        let source = L("회의 · \(day) · \(number)번째 메시지", "Meeting · \(day) · message \(number)")
        let title = L("회의 결정 · ", "Meeting decisions · ") + day
        var state = SpacePatch.meetingState(result, title: title, source: source, chat: turn.meetingRoom)
        state["goal"] = String(turn.question.prefix(200))
        do {
            let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
            let made = try SpaceStore.shared.makeFromTemplate(.decisions, state: data, name: String((chat?.title ?? title).prefix(SpaceLimits.name)),
                                                             origin: room, lock: lock(of: room))
            openSpace(made.id)
        } catch {
            attachmentError = L("Space를 만들지 못했어요: ", "Could not make the Space: ") + error.localizedDescription
        }
    }

    func openSpaceTodo(_ id: String) {
        let todo = TodoStore.shared.snapshot
        guard let item = todo.items.first(where: { $0.id.uuidString == id }) else { openBoard(project: nil); return }
        openBoard(project: todo.lists.first { $0.id == item.listID }?.project?.groupKey, tab: .todo)
    }

    // What a page may ask: go to a chat or a TODO of this Mac, show a file of the chat that made it in Finder, or open
    // a web link after the user agrees.
    func spaceActions(_ id: String, origin: String?) -> SpaceActions {
        SpaceActions(open: { [weak self] target in
            guard let self else { return }
            if let chat = target["chat"].flatMap(UUID.init(uuidString:)), self.conversations.contains(where: { $0.id == chat }) {
                self.viewingSpace = nil; self.open(chat)
            } else if let todo = target["todo"] {
                self.viewingSpace = nil; self.openSpaceTodo(todo)
            } else if let name = target["file"], let origin = origin.flatMap(UUID.init(uuidString:)) {
                let folder = Self.chatFolder(origin).resolvingSymlinksInPath().standardizedFileURL
                let file = folder.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
                guard file.pathComponents.starts(with: folder.pathComponents), file.pathComponents.count > folder.pathComponents.count,
                      FileManager.default.fileExists(atPath: file.path) else { SpaceRefiner.shared.notes[id] = L("파일을 찾지 못했어요: ", "File not found: ") + name; return }
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } else if let text = target["url"], let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                let alert = NSAlert()
                alert.messageText = L("이 Space가 링크를 열려고 해요", "This Space wants to open a link")
                alert.informativeText = url.absoluteString
                alert.addButton(withTitle: L("브라우저에서 열기", "Open in browser"))
                alert.addButton(withTitle: L("취소", "Cancel"))
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
            }
        }, notify: { text in SpaceRefiner.shared.notes[id] = text })
    }

    // spaceLock, spaceWorkers, refineAccount: Solo.swift (the tests reach them there).

    // A change asked in a Space's box: the AI sees the code and the data's shape (never its values) and sends a new
    // page; a refused one is sent back once with the reason. The result waits as a preview (migrate run first).
    func refineSpace(_ id: String, request: String) {
        let refiner = SpaceRefiner.shared
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, refiner.busy[id] == nil, let manifest = SpaceStore.shared.manifest(id) else { return }
        guard let account = refineAccount(manifest) else { refiner.notes[id] = L("답할 계정이 없어요", "No account can answer"); return }
        // Checked again right before the Space's code is sent, as a chat checks before each request (Attachments.swift).
        guard Enterprise.permits(account, lock: spaceLock(manifest)) else { refiner.notes[id] = Self.describe(Enterprise.blocked(account)); return }
        let folder = SpaceStore.folder(id)
        let html = SpacePictures.hide(SpaceStore.html(folder)), state = SpaceStore.state(folder), history = SpaceStore.refineLog(id)
        let draws = account.provider == .codex
        SpaceStore.addRefine(id, SpaceRefineEntry(role: "user", text: request))
        let speaker = label(account)
        let cancel = DebateCancellation()
        refiner.busy[id] = speaker; refiner.cancels[id] = cancel; refiner.notes[id] = nil; refiner.pending[id] = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let prompt = SpaceBuilder.refinePrompt(manifest: manifest, html: html.text, state: state, history: history, request: request,
                                                   draws: draws, kept: html.kept.count)
            var started = Date()
            let outcome = SpaceBuilder.refine(prompt: prompt, kept: html.kept, ask: { prompt in
                started = Date()
                return Answerer.ask(account, prompt: prompt, timeout: 600, cancellation: cancel, run: .app(account))
                    .map { FaceLink.extract($0).text }.mapError { SpaceBad(reason: Self.describe($0)) }
            }, made: {
                // Pictures ChatGPT made in this answer and those already in the page go in for their markers.
                draws ? Pictures.newCodexImages(account, since: started).prefix(SpacePictures.perAnswer).compactMap { Pictures.spaceDataURL($0) } : []
            }, said: { Self.extractState($0).reply })
            DispatchQueue.main.async {
                guard refiner.cancels[id] === cancel else { return }
                refiner.cancels[id] = nil
                if cancel.isCancelled { refiner.busy[id] = nil; return }
                switch outcome {
                case .failure(let bad):
                    refiner.busy[id] = nil
                    refiner.notes[id] = bad.reason
                    SpaceStore.addRefine(id, SpaceRefineEntry(role: "ai", text: bad.reason))
                case .success(let (build, said)):
                    SpaceStore.addRefine(id, SpaceRefineEntry(role: "ai", text: said.isEmpty ? L("새 판을 보냈어요", "Sent a new version") : said))
                    guard let migrate = build.migrate else {
                        refiner.busy[id] = nil
                        refiner.pending[id] = .init(build: build, migrated: nil, by: speaker, request: request)
                        return
                    }
                    SpaceMigrator.run(migrate, state: SpaceStore.state(folder)) { result in
                        refiner.busy[id] = nil
                        switch result {
                        case .success(let data): refiner.pending[id] = .init(build: build, migrated: data, by: speaker, request: request)
                        case .failure(let bad): refiner.notes[id] = L("데이터 옮기기(migrate)가 실패해 적용하지 않았어요: ", "Moving the data (migrate) failed, so nothing changed: ") + bad.reason
                        }
                    }
                }
            }
        }
    }
}

enum SpaceStyle {
    static func color(_ name: String) -> Color {
        switch name {
        case "purple": return .purple
        case "pink": return .pink
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "teal": return .teal
        case "gray": return .gray
        default: return .blue
        }
    }
    static func icon(_ name: String) -> String { NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : "square.grid.2x2" }

    static func reveal(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // One HTML file with its pictures and a stand-in for the bridge (SpaceExport): it runs in any browser, apart from
    // this app, its data kept in that browser from the data the Space has now. A big one goes out as a folder.
    static func export(_ id: String) {
        guard let manifest = SpaceStore.shared.manifest(id) else { NSSound.beep(); return }
        guard SpaceExport.fitsOneFile(id) else { return exportFolder(id, manifest) }
        guard let html = SpaceExport.document(id) else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = manifest.name.replacingOccurrences(of: "/", with: "-") + ".html"
        panel.allowedContentTypes = [.html]
        panel.message = L("브라우저에서 바로 열리는 HTML 파일 하나로 저장해요. 이 앱과 분리되고, 데이터는 지금 데이터에서 시작해 그 브라우저에 따로 저장돼요.",
                          "Saves one HTML file that opens in a browser. It is apart from this app; its data starts from the data now and is kept in that browser.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(html.utf8).write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert(); alert.messageText = L("내보내지 못했어요", "Could not export"); alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }

    private static func exportFolder(_ id: String, _ manifest: SpaceManifest) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = manifest.name.replacingOccurrences(of: "/", with: "-")
        panel.message = L("그림 파일이 커서 폴더로 저장해요: 안의 index.html을 브라우저로 열면 돼요. 이 앱과 분리되고, 데이터는 지금 데이터에서 시작해 그 브라우저에 따로 저장돼요.",
                          "Its picture files are big, so it is saved as a folder: open index.html in it with a browser. It is apart from this app; its data starts from the data now and is kept in that browser.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            try SpaceExport.folder(id, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url.appendingPathComponent("index.html")])
        } catch {
            let alert = NSAlert(); alert.messageText = L("내보내지 못했어요", "Could not export"); alert.informativeText = (error as? SpaceBad)?.reason ?? error.localizedDescription; alert.runModal()
        }
    }

    // A one-line question (rename, icon, schedule). nil: cancelled.
    static func ask(_ title: String, _ info: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = info
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: L("확인", "OK")); alert.addButton(withTitle: L("취소", "Cancel"))
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

// The header row above an open Space (beside the sidebar button): its name, Undo and its versions.
struct SpaceHeader: View {
    @ObservedObject var discussion: Discussion
    let id: String
    @ObservedObject private var store = SpaceStore.shared
    @ObservedObject private var refiner = SpaceRefiner.shared

    var body: some View {
        let manifest = store.manifest(id)
        let versions = manifest.map { _ in SpaceStore.versions(id) } ?? []
        HStack(spacing: 8) {
            Image(systemName: SpaceStyle.icon(manifest?.icon ?? "")).foregroundColor(SpaceStyle.color(manifest?.color ?? ""))
            Text(manifest?.name ?? "Space").font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text(L("\(manifest?.version ?? 1)판", "v\(manifest?.version ?? 1)")).font(.system(size: 11)).foregroundColor(.secondary)
            WindowDragRegion().frame(maxWidth: .infinity, maxHeight: .infinity)
            Button(action: {
                do { try store.undo(id) } catch { refiner.notes[id] = error.localizedDescription }
            }) { Label(L("되돌리기", "Undo"), systemImage: "arrow.uturn.backward").frame(height: 24) }
                .buttonStyle(.plainHit).foregroundColor(.secondary).font(.system(size: 12))
                .disabled(versions.isEmpty || refiner.pending[id] != nil)
                .help(versions.last.map { L("되돌리기: ", "Undo: ") + $0.note + ($0.migrated ? L(" (데이터도 그때로)", " (data too)") : "") } ?? L("되돌릴 변경이 없어요", "Nothing to undo"))
            Button(action: { SpaceStyle.export(id) }) { Image(systemName: "square.and.arrow.up").frame(width: 24, height: 24) }
                .buttonStyle(.plainHit).foregroundColor(.secondary)
                .help(L("내보내기: 브라우저에서 열리는 HTML 파일 하나로, 이 앱과 따로 돌아가요", "Export: one HTML file that runs in a browser, apart from this app"))
            Menu {
                if versions.isEmpty { Text(L("이전 판이 없어요", "No earlier versions")) }
                ForEach(versions.reversed()) { version in
                    Button(L("\(version.version)판 · ", "v\(version.version) · ") + DateFormatter.localizedString(from: version.at, dateStyle: .short, timeStyle: .short) + " · " + version.note) {
                        do { try store.restore(id, to: version.version) } catch { refiner.notes[id] = (error as? SpaceBad)?.reason ?? error.localizedDescription }
                    }
                }
            } label: { Image(systemName: "clock.arrow.circlepath").frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(L("판 목록: 고르면 그 판의 화면으로 돌아가요. 데이터는 그대로지만, 그 뒤에 데이터 키가 바뀌었으면 그때 데이터로 돌아가요 (되돌리기 가능)",
                        "Versions: pick one to bring its page back. The data stays, unless its keys changed since; then that version's data comes back too (can be undone)"))
                .disabled(refiner.pending[id] != nil)
        }
    }
}

// An open Space in place of the chat: the page, a preview of a new version when one waits, and the change box.
struct SpaceMainView: View {
    @ObservedObject var discussion: Discussion
    let id: String
    @ObservedObject private var store = SpaceStore.shared
    @ObservedObject private var refiner = SpaceRefiner.shared

    var body: some View {
        if let manifest = store.manifest(id) {
            VStack(spacing: 0) {
                if let pending = refiner.pending[id] {
                    previewBar(pending)
                    let state = pending.migrated ?? SpaceStore.state(SpaceStore.folder(id))
                    SpaceWebView(html: pending.build.html, assets: SpaceStore.folder(id), color: pending.build.color ?? manifest.color, reload: "preview-\(id)-\(pending.build.html.count)",
                                 host: { SpaceMemoryHost(state) }, actions: SpaceActions(), onProblem: { refiner.notes[id] = $0 })
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2))
                        .padding(.horizontal, 12)
                } else {
                    SpaceWebView(html: SpaceStore.html(SpaceStore.folder(id)), assets: SpaceStore.folder(id), color: manifest.color,
                                 reload: "\(id)-\(manifest.version)-\(store.stateVersion[id] ?? 0)",
                                 host: { SpaceFolderHost(SpaceStore.folder(id)) }, actions: discussion.spaceActions(id, origin: manifest.originChat),
                                 onProblem: { refiner.notes[id] = $0 })
                }
                if let note = refiner.notes[id] {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                        Text(note).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Button(action: { refiner.notes[id] = nil }) { Image(systemName: "xmark").frame(width: 22, height: 22) }.buttonStyle(.plainHit)
                    }
                    .font(.system(size: 12)).foregroundColor(.orange)
                    .padding(.horizontal, 28).padding(.top, 6)
                }
                changeBox(manifest)
            }
        } else {
            VStack { Spacer(); Text(L("이 Space는 없어졌어요", "This Space is gone")).foregroundColor(.secondary); Spacer() }.frame(maxWidth: .infinity)
        }
    }

    private func previewBar(_ pending: SpaceRefiner.Pending) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "eye")
            VStack(alignment: .leading, spacing: 1) {
                Text(L("새 판 미리보기 · ", "Preview of the new version · ") + pending.by).font(.system(size: 12, weight: .medium))
                Text(pending.migrated != nil
                     ? L("데이터 이름이 바뀌어 옮긴 결과로 보여요. 적용 전엔 저장되지 않아요.", "Its data was moved to new keys; nothing is saved until you apply.")
                     : L("데이터는 그대로예요. 미리보기에서 바꾼 건 저장되지 않아요.", "The data stays as it is; changes made in the preview are not saved."))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            Button(L("버리기", "Discard")) { refiner.pending[id] = nil }
            Button(L("적용", "Apply")) { SpaceRefiner.shared.apply(id) }.buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    // Who changes this Space: automatic, or one account the user picked (ChatGPT can also draw pictures).
    private func workerMenu(_ manifest: SpaceManifest) -> some View {
        let workers = discussion.spaceWorkers(for: manifest)
        let picked = manifest.worker.flatMap { id in workers.first { $0.id == id } }
        let next = discussion.refineAccount(manifest)
        return Menu {
            Button((picked == nil ? "✓ " : "") + L("자동", "Automatic") + (picked == nil ? next.map { " · " + discussion.label($0) } ?? "" : "")) {
                store.update(id) { $0.worker = nil }
            }
            Divider()
            ForEach(workers, id: \.id) { account in
                Button((picked?.id == account.id ? "✓ " : "") + discussion.label(account) + (account.provider == .codex ? L(" · 그림 그리기 가능", " · can draw pictures") : "")) {
                    store.update(id) { $0.worker = account.id }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: picked == nil ? "wand.and.stars" : "person.crop.circle")
                Text(picked.map { discussion.label($0) } ?? L("자동", "Auto")).lineLimit(1)
            }
            .font(.system(size: 11)).foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
        .help(L("이 Space를 고칠 AI. 자동이면 만든 채팅의 AI, 없으면 사용량이 가장 많이 남은 계정. ChatGPT는 그림도 그려 넣어요.",
                "Who changes this Space. Automatic: the AI of the chat that made it, else the account with most usage left. ChatGPT can also draw pictures into it."))
    }

    private func changeBox(_ manifest: SpaceManifest) -> some View {
        let busy = refiner.busy[id]
        return HStack(spacing: 8) {
            workerMenu(manifest).disabled(busy != nil)
            TextField(L("말로 고치기: 예) 완료한 건 아래로, 색은 초록으로", "Change it by asking: e.g. move done items down, make it green"),
                      text: Binding(get: { refiner.drafts[id] ?? "" }, set: { refiner.drafts[id] = $0 }), axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...5)
                .onSubmit(send)
                .disabled(busy != nil)
            if let busy {
                ProgressView().controlSize(.small)
                Text(L("\(busy) 고치는 중…", "\(busy) is changing it…")).font(.system(size: 11)).foregroundColor(.secondary)
                Button(action: { SpaceRefiner.shared.stop(id) }) { Image(systemName: "stop.circle").frame(width: 24, height: 24) }
                    .buttonStyle(.plainHit).help(L("멈추기", "Stop"))
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)).frame(width: 26, height: 26) }
                    .buttonStyle(.plainHit).foregroundColor(.accentColor)
                    .disabled((refiner.drafts[id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                    .help(L("AI는 화면 코드와 데이터 키 구조만 봐요 (값은 안 봐요)", "The AI sees the page's code and the data's keys only (never the values)"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1)))
        .frame(maxWidth: 760)
        .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 18)
        .frame(maxWidth: .infinity)
    }

    private func send() {
        let text = refiner.drafts[id] ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        refiner.drafts[id] = nil
        discussion.refineSpace(id, request: text)
    }
}

// The card an answer's <space-build> leaves under it: a working preview with [Add to sidebar] [Rebuild] [Discard].
struct SpaceDraftCard: View {
    let note: SpaceDraftNote
    let turn: ChatTurn
    let discussion: Discussion
    let busy: Bool

    var body: some View {
        let room = discussion.currentID
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                let manifest = note.draft.flatMap { SpaceStore.manifest(at: SpaceStore.draftFolder($0)) } ?? note.target.flatMap { SpaceStore.shared.manifest($0) }
                Image(systemName: SpaceStyle.icon(manifest?.icon ?? "square.grid.2x2")).foregroundColor(SpaceStyle.color(manifest?.color ?? ""))
                Text(note.name).font(.system(size: 13, weight: .semibold))
                Text(note.target == nil ? "Space" : L("Space 변경안", "Space change")).font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
            }
            if let space = note.space {
                HStack {
                    Text(L("사이드바에 추가했어요", "Added to the sidebar")).font(.system(size: 12)).foregroundColor(.secondary)
                    Button(L("열기", "Open")) { discussion.openSpace(space) }.buttonStyle(.link).font(.system(size: 12))
                        .disabled(SpaceStore.shared.manifest(space) == nil)
                }
            } else if note.discarded == true {
                Text(L("버린 미리보기예요", "This preview was discarded")).font(.system(size: 12)).foregroundColor(.secondary)
            } else if let reason = note.reason {
                Text(L("검사에서 거부했어요: ", "Refused by the checks: ") + reason).font(.system(size: 12)).foregroundColor(.orange).textSelection(.enabled)
                Button(L("다시 만들기 (이유를 AI에게 알려요)", "Rebuild (tells the AI why)")) { discussion.rebuildSpace(turn, in: room) }.disabled(busy)
            } else if let target = note.target, note.draft != nil {
                let current = SpaceStore.shared.manifest(target)
                Text(L("이 Space를 고친 변경안이에요. Space에서 미리 보고 적용하면 되고, 데이터는 그대로예요.",
                       "A change to this Space. Preview it in the Space and apply it there; the data stays."))
                    .font(.system(size: 12)).foregroundColor(.secondary)
                if let current, let base = note.baseVersion, current.version != base {
                    Text(L("이 변경안은 \(base)판 기준인데 지금은 \(current.version)판이에요. 적용하면 그 사이 변경을 덮어써요 (되돌리기 가능).",
                           "Written for v\(base), the Space is now v\(current.version). Applying replaces the changes since (can be undone)."))
                        .font(.system(size: 12)).foregroundColor(.orange)
                }
                HStack(spacing: 8) {
                    Button(L("Space에서 미리보기", "Preview in the Space")) { discussion.reviewSpaceChange(turn) }.buttonStyle(.borderedProminent)
                        .disabled(current == nil)
                    Button(L("다시 만들기", "Rebuild")) { discussion.rebuildSpace(turn, in: room) }.disabled(busy)
                    Button(L("버리기", "Discard")) { discussion.discardDraftSpace(turn, in: room) }
                    Spacer()
                    if current == nil { Text(L("이 Space는 없어졌어요", "This Space is gone")).font(.system(size: 11)).foregroundColor(.secondary) }
                }
                .controlSize(.small)
            } else if let draft = note.draft {
                let folder = SpaceStore.draftFolder(draft)
                SpaceWebView(html: SpaceStore.html(folder), assets: folder, color: SpaceStore.manifest(at: folder)?.color ?? "blue", reload: draft,
                             host: { SpaceFolderHost(folder) }, actions: SpaceActions())
                    .frame(height: 380)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
                HStack(spacing: 8) {
                    Button(L("사이드바에 추가", "Add to sidebar")) { discussion.addDraftSpace(turn, in: room) }.buttonStyle(.borderedProminent)
                    Button(L("다시 만들기", "Rebuild")) { discussion.rebuildSpace(turn, in: room) }.disabled(busy)
                    Button(L("버리기", "Discard")) { discussion.discardDraftSpace(turn, in: room) }
                    Spacer()
                    Text(L("미리보기에서 바꾼 데이터는 추가할 때 함께 가요", "What you change in the preview comes along when you add it"))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }
}

// What an answer changed in the Spaces folder, as checked after it (SpaceLibrary.sync): each Space with [Open].
struct SpaceEditsView: View {
    let notes: [SpaceSyncNote]
    let discussion: Discussion

    static func text(_ note: SpaceSyncNote) -> String {
        switch note.kind {
        case "added": return L("새 Space를 사이드바에 넣었어요", "Added to the sidebar")
        case "changed": return note.version.map { L("\($0)판으로 고쳤어요 (되돌리기 가능)", "Changed to v\($0) (can be undone)") } ?? L("고쳤어요", "Changed")
        case "removed": return L("휴지통으로 옮겼어요", "Moved to the Trash")
        case "set-aside": return L("새 Space를 넣지 않고 따로 두었어요: ", "Set aside, not added: ") + (note.reason ?? "")
        default: return L("검사에서 거부해 전 판으로 되돌렸어요: ", "Refused by the checks and put back: ") + (note.reason ?? "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                let bad = note.kind == "refused" || note.kind == "set-aside"
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: bad ? "exclamationmark.triangle" : "square.grid.2x2").foregroundColor(bad ? .orange : .secondary)
                    Text(note.name).font(.system(size: 12, weight: .semibold))
                    Text(Self.text(note)).font(.system(size: 12)).foregroundColor(bad ? .orange : .secondary).textSelection(.enabled)
                    Spacer(minLength: 4)
                    if note.kind != "removed" && note.kind != "set-aside" {
                        Button(L("열기", "Open")) { discussion.openSpace(note.space) }.buttonStyle(.link).font(.system(size: 12))
                            .disabled(SpaceStore.shared.manifest(note.space) == nil)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
}

// The minute, for the sidebar's schedules (an ObservableObject: this Mac's Command Line Tools cannot build @State).
final class SpaceClock: ObservableObject {
    static let shared = SpaceClock()
    @Published private(set) var now = Date()
    private var timer: Timer?
    init() { timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.now = Date() } }
}

// The sidebar's Spaces: pinned first, then in the user's order. Hidden ones and those outside their schedule fold
// into "Hidden" and "Later". The + makes one from a built-in template.
struct SpaceSidebarSection: View {
    @ObservedObject var discussion: Discussion
    @ObservedObject private var store = SpaceStore.shared
    @ObservedObject private var folds = SidebarFold.shared
    @ObservedObject private var clock = SpaceClock.shared

    var body: some View {
        let tick = clock.now
        let all = store.spaces.sorted { ($0.pinned == true ? 0 : 1, $0.order) < ($1.pinned == true ? 0 : 1, $1.order) }
        let shown = all.filter { $0.shown(at: tick) }
        let later = all.filter { $0.hidden != true && !$0.shown(at: tick) }
        let hidden = all.filter { $0.hidden == true }
        Group {
            SidebarHeader(title: L("Spaces", "Spaces"), fold: "spaces") { addMenu }
            if !folds.isFolded("spaces") {
                if all.isEmpty {
                    Text(L("채팅에서 \"…트래커 만들어 줘\"라고 해 보세요", "Ask a chat to \"make a … tracker\""))
                        .font(.system(size: 12)).foregroundColor(.secondary).padding(.horizontal, 10).frame(height: 28, alignment: .leading)
                }
                ForEach(shown) { row($0, listed: shown.map(\.id)) }
                group(L("나중에", "Later"), key: "spaces.later.open", spaces: later)
                group(L("숨김", "Hidden"), key: "spaces.hidden.open", spaces: hidden)
            }
        }
    }

    @ViewBuilder private func group(_ title: String, key: String, spaces: [SpaceManifest]) -> some View {
        if !spaces.isEmpty {
            // Folded unless the user opened it ("open" kept in the fold list).
            let open = folds.isFolded(key)
            Button(action: { folds.toggle(key) }) {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 18)
                    Text("\(title) (\(spaces.count))")
                    Spacer()
                }
                .font(.system(size: 12)).foregroundColor(.secondary)
                .padding(.horizontal, 10).frame(height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plainHit)
            if open { ForEach(spaces) { row($0, listed: spaces.map(\.id)) } }
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(SpaceTemplate.allCases, id: \.self) { template in
                Button(template.name) {
                    if let made = try? store.makeFromTemplate(template) { discussion.openSpace(made.id) }
                }
            }
            Divider()
            Button(L("채팅에서 말로 만들기…", "Make one by asking in a chat…")) {
                discussion.newConversation()
                discussion.draft = L("Space 만들어 줘: ", "Make a Space: ")
            }
            Button(L("Spaces 폴더 열기", "Open the Spaces folder")) { SpaceStyle.reveal(SpaceStore.root) }
        } label: { Image(systemName: "plus").font(.system(size: 11)).frame(width: 22, height: 22) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundColor(.secondary)
            .help(L("새 Space", "New Space"))
    }

    private func row(_ space: SpaceManifest, listed: [String]) -> some View {
        let key = "space." + space.id
        let selected = discussion.viewingSpace == space.id
        return Button(action: { discussion.openSpace(space.id) }) {
            HStack(spacing: 8) {
                Image(systemName: SpaceStyle.icon(space.icon)).foregroundColor(SpaceStyle.color(space.color)).frame(width: 18)
                Text(space.name).lineLimit(1)
                Spacer()
                if space.pinned == true { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundColor(.secondary) }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10).frame(height: 30)
            .background(selected ? Color.primary.opacity(0.1) : discussion.hoverKey == key ? Color.primary.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
        .onHover { discussion.hover(key, $0) }
        .contextMenu { menu(space, listed: listed) }
    }

    @ViewBuilder private func menu(_ space: SpaceManifest, listed: [String]) -> some View {
        let id = space.id
        Button(space.pinned == true ? L("고정 해제", "Unpin") : L("고정", "Pin")) { store.update(id) { $0.pinned = $0.pinned == true ? nil : true } }
        Button(space.hidden == true ? L("다시 보이기", "Show again") : L("숨기기", "Hide")) { store.update(id) { $0.hidden = $0.hidden == true ? nil : true } }
        Button(L("위로", "Move up")) { store.move(id, by: -1, among: listed) }.disabled(listed.first == id)
        Button(L("아래로", "Move down")) { store.move(id, by: 1, among: listed) }.disabled(listed.last == id)
        Divider()
        Button(L("이름 바꾸기…", "Rename…")) {
            if let name = SpaceStyle.ask(L("Space 이름", "Space name"), "", value: space.name) { store.update(id) { $0.name = name } }
        }
        Button(L("아이콘 바꾸기…", "Change icon…")) {
            if let icon = SpaceStyle.ask(L("SF Symbol 이름", "SF Symbol name"), L("예: checklist, drop, chart.bar, flask", "e.g. checklist, drop, chart.bar, flask"), value: space.icon)?
                .trimmingCharacters(in: .whitespaces), NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil {
                store.update(id) { $0.icon = icon }
            }
        }
        Menu(L("색", "Color")) {
            ForEach(SpaceManifest.colors, id: \.self) { color in
                Button((space.color == color ? "✓ " : "") + color) { store.update(id) { $0.color = color } }
            }
        }
        Button(L("표시 일정…", "Schedule…")) {
            let info = L("요일(1=월 … 7=일)과 시간. 예: 1-5 09:00-18:00 · 6,7 · 22:00-02:00. 비우면 늘 보여요.",
                         "Days (1 = Mon … 7 = Sun) and hours, e.g. 1-5 09:00-18:00 · 6,7 · 22:00-02:00. Empty: always shown.")
            let current = [space.schedule?.days.map { $0.map(String.init).joined(separator: ",") }, space.schedule?.from.map { $0 + "-" + (space.schedule?.to ?? "") }]
                .compactMap { $0 }.joined(separator: " ")
            guard let text = SpaceStyle.ask(L("표시 일정", "Schedule"), info, value: current) else { return }
            if text.trimmingCharacters(in: .whitespaces).isEmpty { store.update(id) { $0.schedule = nil } }
            else if let schedule = SpaceSchedule.parse(text) { store.update(id) { $0.schedule = schedule } }
            else { NSSound.beep() }
        }
        Divider()
        Button(L("Finder에서 보기", "Show in Finder")) { SpaceStyle.reveal(SpaceStore.folder(id)) }
        Button(L("내보내기 (HTML 파일)…", "Export (HTML file)…")) { SpaceStyle.export(id) }
        Divider()
        Button(L("삭제…", "Delete…"), role: .destructive) {
            let alert = NSAlert()
            alert.messageText = L("\"\(space.name)\" Space를 지울까요?", "Delete the Space \"\(space.name)\"?")
            alert.informativeText = L("화면·데이터·이전 판을 휴지통으로 옮겨요.", "Its page, data and versions go to the Trash.")
            alert.addButton(withTitle: L("휴지통으로", "Move to Trash")); alert.addButton(withTitle: L("취소", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if discussion.viewingSpace == id { discussion.viewingSpace = nil }
            try? store.delete(id)
        }
    }
}
