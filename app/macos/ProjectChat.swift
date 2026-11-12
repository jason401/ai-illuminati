import Cocoa
import SwiftUI
import AIAccounts
import AILocalization
import AIRuntime
import AIWorkspace

struct ProjectApprovalView: View {
    let room: UUID
    var discussion: Discussion?
    @ObservedObject private var center = ProjectCenter.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(center.requests.filter { $0.room == room }) { request in
                VStack(alignment: .leading, spacing: 8) {
                    Text(request.title).font(.headline)
                    ScrollView { Text(request.detail).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120)
                    HStack {
                        Button(L("거절", "Deny")) { center.decide(request.id, allow: false) }
                        Spacer()
                        if let always = request.alwaysAllow {
                            Button(L("항상 허용", "Always Allow")) { always(); center.decide(request.id, allow: true) }
                        }
                        Button(L("허용", "Allow")) { center.decide(request.id, allow: true) }.buttonStyle(.borderedProminent)
                    }
                }.padding(12).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            // Unanswered for 15 minutes counts as no; the note stays so the user can pick it up again.
            ForEach(center.expired.filter { $0.room == room }) { request in
                HStack(spacing: 8) {
                    Image(systemName: "clock.badge.xmark").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("허가 기한 지남 · 거절로 처리했어요", "Approval timed out · treated as denied")).font(.system(size: 12, weight: .semibold))
                        Text(request.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button(L("닫기", "Dismiss")) { center.dismiss(request.id) }
                    if let discussion {
                        Button(L("다시 요청", "Ask again")) { discussion.askAgain(request) }
                            .buttonStyle(.borderedProminent)
                            .disabled(discussion.runningRooms.contains(room))
                    }
                }.padding(10).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

// Shown above any other chat while a chat waits for approval, so a card in a chat you are not looking at
// is not missed. Allow only where the details are shown (the card or the approval window).
struct ApprovalBanner: View {
    @ObservedObject var discussion: Discussion
    @ObservedObject private var center = ProjectCenter.shared
    var body: some View {
        let others = center.requests.filter { $0.room != discussion.currentID || discussion.viewingRemote != nil }
        if !others.isEmpty {
            VStack(spacing: 4) {
                ForEach(others) { request in
                    HStack(spacing: 8) {
                        Circle().fill(Color.orange).frame(width: 8, height: 8)
                        Text(discussion.approvalChatName(request.room)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(request.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Button(L("거절", "Deny")) { center.decide(request.id, allow: false) }
                        Button(L("열기", "Open")) { discussion.open(request.room) }.buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 4)
        }
    }
}

// Every waiting approval in one place (opened from the menu bar or a notification).
struct ApprovalListView: View {
    let discussion: Discussion
    var openChat: (UUID) -> Void
    @ObservedObject private var center = ProjectCenter.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if center.requests.isEmpty {
                Spacer()
                Text(L("기다리는 허가 요청이 없어요. 이미 처리됐거나 끝난 요청이에요.", "No approvals waiting. Those requests were already handled or ended."))
                    .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(center.requests) { request in row(request) }
                    }
                }
            }
        }
        .padding(14)
        .frame(minWidth: 420, minHeight: 220)
    }

    private func row(_ request: ProjectApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(discussion.approvalChatName(request.room)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Self.timing(request, now: context.date)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Text(request.title).font(.headline)
            ScrollView { Text(request.detail).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120)
            HStack {
                Button(L("거절", "Deny")) { center.decide(request.id, allow: false) }
                Button(L("채팅 열기", "Open chat")) { openChat(request.room) }
                Spacer()
                Button(L("허용", "Allow")) { center.decide(request.id, allow: true) }.buttonStyle(.borderedProminent)
            }
        }.padding(12).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    static func timing(_ request: ProjectApproval, now: Date) -> String {
        let format = DateFormatter(); format.timeStyle = .short; format.dateStyle = .none
        let asked = L("요청 ", "Asked ") + format.string(from: request.created)
        guard let deadline = request.deadline else { return asked }
        let minutes = max(0, Int((deadline.timeIntervalSince(now) / 60).rounded(.up)))
        return asked + L(" · \(minutes)분 남음", " · \(minutes) min left")
    }
}

extension Discussion {
    func approvalChatName(_ room: UUID) -> String {
        let title = conversations.first(where: { $0.id == room })?.title ?? ""
        return title.isEmpty ? L("새 대화", "New chat") : title
    }
    // Ask again: opens the chat and sends a short message so the AI checks again and shows a new card.
    // A draft or attached images the user has in the message box stay there, unsent. When the chat cannot
    // answer now (busy, or three chats answering), the note stays so the user can ask again later.
    func askAgain(_ request: ProjectApproval) {
        open(request.room)
        let text = request.title.hasPrefix("stable") ? L("stable 배포 다시 진행해 줘", "Please publish stable again")
            : L("방금 허가를 기다리던 작업 다시 진행해 줘", "Please continue the work that was waiting for approval")
        if let reason = startTurn(room: request.room, question: text) { attachmentError = reason; return }
        ProjectCenter.shared.dismiss(request.id)
    }
    // The permission dialog before a Git project works in full auto (+ menu of a chat and the sidebar Projects +).
    static func allowProjectWork(_ project: ProjectBinding) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("이 채팅에서 프로젝트 작업 허용", "Allow project work in this chat")
        alert.informativeText = project.root + "\n\n" + L("완전 자동으로 일해요: AI가 승인 카드 없이 모든 명령을 실행하고 인터넷을 쓰고 main에 push해요. 한 번에 최대 8시간, 그동안 Mac이 잠들지 않아요.\n\n막아 두는 것: 강제 push·기록 지우기, 영구 삭제(rm은 휴지통으로). stable 배포는 매번 직접 허용해요.\n\n카드로 하나씩 확인하려면 + 메뉴에서 완전 자동을 끄세요. 신뢰하는 프로젝트만 연결하세요.", "Works in full auto: the AI runs any command without approval cards, uses the network and pushes to main. Up to 8 hours per task, with the Mac kept awake.\n\nStill blocked: force push and history rewrites, permanent deletes (rm moves to the Trash). Publishing stable always asks you.\n\nTo confirm steps with cards, turn off full auto in the + menu. Only connect projects you trust.")
        alert.addButton(withTitle: L("허용", "Allow")); alert.addButton(withTitle: L("취소", "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    func configureProject() {
        guard !running, configuration.mode == 0 else { return }
        if current.workspace?.project != nil {
            change(currentID, save: true) { $0.workspace?.project = nil; $0.workspace?.fullAuto = nil }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = L("Git 프로젝트 최상위 폴더를 선택하세요.", "Choose the top-level Git project folder.")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let project = try ProjectProcess.inspect(folder.path)
            guard Self.allowProjectWork(project) else { return }
            change(currentID, save: true) { conversation in
                var binding = conversation.workspace ?? WorkspaceBinding(roots: [])
                if !binding.roots.contains(where: { $0.path == project.root }) { binding.roots.append(WorkspaceRoot(path: project.root, directory: true, writable: true)) }
                binding.project = project; conversation.workspace = binding
            }
        } catch { attachmentError = error.localizedDescription }
    }

    // + → Documents project…: a folder (new or existing, not Git) of papers, slides and figures becomes a project with its
    // own sidebar folder and TODO board. This chat links to it, full auto like "Link folder", with a backup before each answer.
    func linkDocumentsProject() {
        guard !running, !importingMaterials, configuration.mode == 0 else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.prompt = L("연결", "Link")
        panel.message = L("논문·발표 하나의 폴더를 고르거나 새로 만드세요 (Google Drive 폴더도 돼요). Git은 쓰지 않아요.",
                          "Pick or create the folder of one paper or talk (a Google Drive folder works too). No Git is used.")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let project = try ProjectProcess.documents(folder.path)
            let alert = NSAlert()
            alert.messageText = L("문서 프로젝트로 연결", "Link as a documents project")
            alert.informativeText = project.root + "\n\n" + L("AI가 이 폴더의 글·그림·슬라이드를 고칠 수 있어요 (완전 자동: 명령 실행·인터넷 사용). 답할 때마다 폴더를 먼저 백업해서 되돌릴 수 있어요. 클라우드에만 있는 파일과 Google 문서에서 고친 것은 백업에 없어요 (Google 버전 기록으로 되돌려요).\n\n왼쪽 목록에 프로젝트 폴더가 생기고 할 일 보드를 쓸 수 있어요.",
                                                                "The AI may change the text, figures and slides in this folder (full auto: runs commands, uses the network). The folder is backed up before each answer, so it can be undone. Files only in the cloud and edits in Google Docs are not in the backup (use Google's version history).\n\nThe project gets its own folder in the sidebar and a TODO board.")
            alert.addButton(withTitle: L("연결", "Link")); alert.addButton(withTitle: L("취소", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try nativeSessions.reset(currentID)
            change(currentID, save: true) { conversation in
                var binding = conversation.workspace ?? WorkspaceBinding(roots: [])
                binding.roots.removeAll { $0.path == project.root }
                binding.roots.insert(WorkspaceRoot(path: project.root, directory: true, writable: true), at: 0)
                binding.project = project; conversation.workspace = binding
            }
            attachmentError = nil
            sessionNote = L("문서 프로젝트 연결됨 · 완전 자동 (답할 때마다 백업, Undo 가능)", "Documents project linked · full auto (backed up before each answer, Undo available)")
        } catch { attachmentError = error.localizedDescription }
    }

    // Sidebar Projects + → Link a folder…: a top-level Git folder with a remote becomes a code project, any other folder a
    // documents project. A new chat opens in it (the current chat is left alone).
    func linkProjectFromSidebar() {
        guard !running, !importingMaterials else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.prompt = L("연결", "Link")
        panel.message = L("프로젝트 폴더를 고르세요. Git 저장소면 코드 프로젝트, 아니면 문서 프로젝트(Git 없음)가 돼요.",
                          "Pick the project folder. A Git repository becomes a code project; any other folder a documents project (no Git).")
        guard panel.runModal() == .OK, let folder = panel.url?.resolvingSymlinksInPath() else { return }
        do {
            let project: ProjectBinding
            if let git = try? ProjectProcess.inspect(folder.path) {
                guard Self.allowProjectWork(git) else { return }
                project = git
            } else {
                project = try ProjectProcess.documents(folder.path)
                let alert = NSAlert()
                alert.messageText = L("문서 프로젝트로 연결", "Link as a documents project")
                alert.informativeText = project.root + "\n\n" + L("Git 저장소가 아니라서 문서 프로젝트로 연결해요. AI가 이 폴더의 파일을 고칠 수 있어요 (완전 자동: 명령 실행·인터넷 사용). 신뢰하는 폴더만 연결하세요. 답할 때마다 폴더를 먼저 백업해서 되돌릴 수 있어요.",
                                                                    "This is not a Git repository, so it is linked as a documents project. The AI may change the files in this folder (full auto: runs commands, uses the network). Only link folders you trust. The folder is backed up before each answer, so it can be undone.")
                alert.addButton(withTitle: L("연결", "Link")); alert.addButton(withTitle: L("취소", "Cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            attachmentError = nil
            _ = addProjectChat(project, title: L("새 대화", "New chat"), open: true)
            sessionNote = project.isDocuments
                ? L("문서 프로젝트 연결됨 · 완전 자동 (답할 때마다 백업, Undo 가능)", "Documents project linked · full auto (backed up before each answer, Undo available)")
                : L("Git 프로젝트 연결됨 · 완전 자동 (stable 배포만 허용 카드)", "Git project linked · full auto (only stable publishing asks)")
        } catch { attachmentError = error.localizedDescription }
    }

    // A chat dragged onto a project folder in the sidebar (or "Move to project" in its menu) joins that project.
    // The first time it says what that allows (full auto, like "Link folder"); "Don't ask again" skips it.
    @discardableResult
    func moveChat(_ id: UUID, into group: ProjectGroup) -> Bool {
        guard host == nil, !importingMaterials, let chat = conversations.first(where: { $0.id == id }), let project = group.bindings.first else { return false }
        if let reason = SidebarProjects.moveRefusal(chat, into: group, todo: TodoStore.shared.snapshot, running: runningRooms.contains(id), mode: configuration(of: id).mode) {
            attachmentError = reason; return false
        }
        let confirmed = "sidebar.moveToProjectConfirmed"
        if !UserDefaults.app.bool(forKey: confirmed) {
            let alert = NSAlert()
            alert.messageText = L("\"\(chat.title)\"을(를) \(group.name) 프로젝트로 옮길까요?", "Move \"\(chat.title)\" into \(group.name)?")
            alert.informativeText = project.root + "\n\n" + L("이 대화에서 AI가 이 프로젝트 폴더에서 일할 수 있어요 (완전 자동: 명령 실행·main에 push, stable 배포만 직접 허용). 지난 대화 내용은 그대로 남아요.", "The AI in this chat can then work in this project folder (full auto: runs commands and pushes to main; publishing stable always asks you). The chat's messages stay.")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = L("다시 묻지 않기", "Don't ask again")
            alert.addButton(withTitle: L("옮기기", "Move")); alert.addButton(withTitle: L("취소", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            if alert.suppressionButton?.state == .on { UserDefaults.app.set(true, forKey: confirmed) }
        }
        // The AI's earlier sessions knew other folders: the next question starts fresh ones from the chat.
        do { try nativeSessions.reset(id) } catch { attachmentError = error.localizedDescription; return false }
        change(id, save: true) { $0.workspace = SidebarProjects.moved($0.workspace, to: project) }
        attachmentError = nil
        sessionNote = L("\(group.name) 프로젝트로 옮겼어요", "Moved into \(group.name)")
        return true
    }

    func runProjectSolo(question: String, history: [ChatTurn], rules: String, config: ChatConfiguration,
                        mentions: [String], reviewers: [String] = [], cancellation: DebateCancellation, id: UUID, index: Int,
                        binding: WorkspaceBinding, fresh: String? = nil, keepState: Bool = false, note: String = "") {
        guard let selected = binding.project else { finish(id, index, error: "No project selected."); return }
        let fullAuto = binding.isFullAuto
        let run = ProjectRun(room: id, binding: selected, token: cancellation, fullAuto: fullAuto)
        run.onNote = { [weak self] log in self?.changeTurn(id, index) { $0.projectLog = log; $0.lastActivityAt = Date() } }
        run.onPlan = { [weak self] steps, note in self?.changeTurn(id, index) { $0.plan = steps; $0.planNote = note; $0.lastActivityAt = Date() } }
        run.onWaiting = { [weak self] waiting in self?.changeTurn(id, index) { $0.waitingApproval = waiting ? true : nil; $0.lastActivityAt = Date() } }
        // Last, after the backup and the status are settled: a macOS notice that the work ended (ApprovalAlerts),
        // unless the user stopped it. A review that failed, or a fix of it that failed, is not a success.
        var problem: String?
        defer {
            let stopped = cancellation.isCancelled, why = problem
            DispatchQueue.main.async {
                if !stopped { NotificationCenter.default.post(name: .projectWorkEnded, object: nil, userInfo: ["room": id, "index": index, "problem": why as Any]) }
            }
        }
        // Full auto keeps the Mac awake while the AI works (the display may still sleep).
        let awake = fullAuto ? ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "AI Illuminati full-auto project work") : nil
        defer { if let awake { ProcessInfo.processInfo.endActivity(awake) } }
        ProjectWork.register(run)
        defer {
            ProjectWork.finish(run)
            changeTurn(id, index) { $0.partial = nil; $0.activity = nil; $0.status = ""; $0.waitingApproval = nil }
        }
        var backup: WorkspaceBackup?
        defer {
            if var saved = backup, (try? saved.finish()) != nil {
                let changes = saved.changes
                changeTurn(id, index, save: true) { $0.workspaceChanges = changes; $0.projectCommitted = run.committed; $0.projectPushed = run.pushed; $0.projectLog = run.log.isEmpty ? nil : run.log }
            }
        }
        var workspace = binding
        workspace.level = .execute
        workspace.roots = binding.roots.map { WorkspaceRoot(path: $0.path, directory: $0.directory, writable: ($0.path == selected.root || $0.path == Self.chatFolder(id).path) ? true : nil) }
        workspace.projectRunID = run.id
        do {
            try run.validate(run.generation)
            // Only back up writable directories; native/MCP write roots are limited to these same roots.
            let backed = WorkspaceBinding(roots: workspace.roots.filter { $0.writable == true }, level: .write)
            let saved = try WorkspaceBackup.begin(backed, room: id, runID: run.id)
            backup = saved; activeWorkspaceBackupPath = saved.directory
            changeTurn(id, index, save: true) { $0.backupPath = saved.directory }
        } catch { finish(id, index, error: error.localizedDescription); return }
        let projectRules = ProjectRules.read(root: selected.root).prompt
        let transcript = Self.transcript(history) + "\n[User]\n" + question
        let chatLock = self.lock(of: id)
        var excluded = Set<String>(), checkpoint = run.checkpoint("Project turn started")
        // Picked by hand (@ or one account checked): that one. Otherwise the same rule as a plain chat: the last
        // account keeps going while 5-hour and weekly usage both have 15% or more left (AutoPick). During the
        // work only a usage-limit error hands it to another AI.
        var preferred = mentions.first ?? config.soloAccountID
        var handedFrom: String?   // the AI that reached its usage limit, shown while the next one takes over
        // A TODO's work, also after a usage limit, stays with the AIs picked for its list when it started.
        let workers = TodoStore.shared.current.workers(room: id)
        // Before the work starts: what the project looks like, so the review covers only this answer's changes
        // (also when another AI took over after a usage limit).
        let reviewRoot = selected.isFolderless ? Self.chatFolder(id).path : selected.root
        let start = reviewers.isEmpty ? nil : selected.isDocuments ? backup.flatMap { ProjectSnapshot.documents(backup: $0, root: reviewRoot) } : ProjectSnapshot.take(root: reviewRoot)
        while !cancellation.isCancelled && Date() < run.deadline && !run.activeExpired {
            let eligible = model.accounts.filter { [.claude, .codex].contains($0.provider) && !excluded.contains($0.id) && Enterprise.permits($0, lock: chatLock) && (workers?.contains($0.id) ?? true) }
            let account = preferred.flatMap { wanted in eligible.first { $0.id == wanted } }
                ?? AutoPick.choose(eligible, usage: model.latestUsage, lock: chatLock, current: config.lastSoloAccountID)
            guard let account else {
                finish(id, index, error: workers != nil
                       ? L("이 TODO에 고른 AI 중 이어서 작업할 계정이 없어요. 파일 변경은 보존했어요.", "None of the AIs picked for this TODO can continue. Changes are preserved.")
                       : chatLock?.isPersonal == true
                       ? L("이 개인 방에서 작업할 개인 Claude/Codex 계정이 필요해요. 파일 변경은 보존했어요.", "This personal chat needs a personal Claude/Codex account to continue. Changes are preserved.")
                       : chatLock != nil
                       ? L("이 Enterprise 방에서 작업할 \(chatLock?.name ?? "") Claude/Codex 계정이 필요해요. 파일 변경은 보존했어요.", "This Enterprise chat needs a \(chatLock?.name ?? "") Claude/Codex account to continue. Changes are preserved.")
                       : L("이어서 작업할 Claude/Codex 계정이 필요해요. 파일 변경은 보존했어요.", "No Claude/Codex account is available to continue. Changes are preserved.")); return
            }
            run.nextAttempt(); workspace.projectGeneration = run.generation; activeWorkspace = workspace
            let speaker = label(account)
            let working = handedFrom.map { L("\($0) 한도 → \(speaker)가 이어받아 작업 중", "\($0) hit its limit → \(speaker) took over") }
                ?? speaker + L(" · 프로젝트 작업 중", " · working on project")
            changeTurn(id, index) { $0.status = working; $0.activity = nil; $0.lastActivityAt = Date() }
            func attempt(_ extra: String, transcript: String, fresh: String?) -> Result<String, Answerer.Failure> {
                var instruction = soloInstruction(account, binding: workspace, helper: "",
                                                  project: ProjectPart(root: selected.root, fullAuto: fullAuto, rules: projectRules, folderless: selected.isFolderless, documents: selected.isDocuments), chat: id)
                if !note.isEmpty { instruction += "\n" + note }
                if keepState { instruction += "\n" + Self.stateRule(current: Self.loadState(id)) }
                instruction += "\n[Verified app checkpoint; do not repeat completed operations blindly]\n" + checkpoint + extra
                let prompt = Self.soloContext(rules: rules, transcript: transcript) + "\n[SOLO TURN]\n" + instruction
                let freshPrompt = fresh.map { Self.soloContext(rules: rules, transcript: $0) + "\n[SOLO TURN]\n" + instruction }
                let generation = run.generation
                let progress: (AnswerProgress) -> Void = { update in
                    switch update {
                    case .text(let text): self.changeTurn(id, index) { $0.partial = Self.extractState(FaceLink.extract(text).text).reply; $0.partialBy = speaker; $0.lastActivityAt = Date() }
                    case .activity(let text): self.changeTurn(id, index) { $0.activity = text; $0.lastActivityAt = Date() }
                    case .todos(let todos): if let steps = PlanLink.todos(todos) { run.setPlan(steps, note: nil, generation: generation, tool: false) }
                    }
                }
                guard permits(account, room: id) else { return .failure(Enterprise.blocked(account)) }
                if let workspaceAnswer { return workspaceAnswer(account, prompt, workspace, run.attempt, progress) }
                return nativeSessions.ask(account, room: id, prompt: prompt, images: activeImages,
                                          timeout: run.deadline.timeIntervalSinceNow, token: run.attempt, web: true, speaker: speaker, fresh: freshPrompt,
                                          invoke: { text, images, session in
                    Answerer.ask(account, prompt: text, timeout: run.deadline.timeIntervalSinceNow, cancellation: run.attempt,
                                 images: images, web: true, session: session,
                                 run: .app(account, WorkspaceInvocation(binding: workspace, room: id, readOnly: false, backupPath: self.activeWorkspaceBackupPath)), progress: progress)
                }, note: { text in DispatchQueue.main.async { self.sessionNote = text } })
            }
            let started = Date()
            let result = attempt("", transcript: transcript, fresh: fresh)
            run.attempt.cancel() // All app commands and CLI descendants finish before another AI can write.
            ToolHub.shared.revoke(project: run.id)
            if cancellation.isCancelled { break }
            switch result {
            case .success(let raw):
                let (tagless, mood) = FaceLink.extract(raw)
                if let mood { FaceLink.shared.show(mood) }
                let (reply, newState) = Self.extractState(tagless)
                notePeerOutcome(account, reply: tagless)
                if let newState { self.saveState(newState, room: id, index: index) }
                deliverSpaceBuild(tagless, room: id, turn: index, cancellation: cancellation)
                let harvest = collectPictures(reply, account: account, since: started, id: id, index: index, cancellation: cancellation)
                let text = harvest.text
                changeTurn(id, index, save: true) {
                    $0.final = text; $0.finalBy = speaker; $0.partial = nil; $0.activity = nil; $0.status = ""
                    $0.finalImages = harvest.images.isEmpty ? nil : harvest.images
                }
                change(id, save: true) { conversation in
                    var saved = conversation.configuration ?? config
                    saved.lastSoloAccountID = account.id
                    conversation.configuration = saved
                }
                // Members who review: when this answer changed the project, one of them reads the changes and the
                // lead fixes what is right, once, in the same turn (with the same backup and project lock).
                if let start, !cancellation.isCancelled {
                    run.attempt.cancel(); ToolHub.shared.revoke(project: run.id)
                    run.nextAttempt()
                    var reviewer: String?, reviewOK = false
                    let findings = reviewChanges(id: id, index: index, worker: account, reviewers: reviewers, binding: workspace,
                                                 root: reviewRoot, start: start, question: question, reply: text, token: run.attempt) { name in
                        reviewer = name; run.setAppStep(0, L("검토: \(name)", "Review: \(name)"), .doing)
                    } reviewed: { reviewOK = $0 }
                    if let reviewer {
                        run.setAppStep(0, L("검토: \(reviewer)", "Review: \(reviewer)"), reviewOK ? .done : .blocked)
                        if !reviewOK && !cancellation.isCancelled { problem = L("\(reviewer)가 검토하지 못했어요.", "\(reviewer) could not review the changes.") }
                    }
                    if let findings, !cancellation.isCancelled {
                        run.setAppStep(1, L("검토 반영", "Apply the review"), .doing)
                        workspace.projectGeneration = run.generation; activeWorkspace = workspace
                        checkpoint = run.checkpoint("Work done by " + speaker + "; review findings received. Fix what is right; do not redo finished steps.")
                        changeTurn(id, index) { $0.status = speaker + L(" · 검수 반영 중", " · fixing review findings") }
                        let after = transcript + "\n[" + speaker + "]\n" + text
                        let fixed = attempt("\n" + findings.note, transcript: after, fresh: fresh.map { $0 + "\n[" + speaker + "]\n" + text })
                        run.attempt.cancel(); ToolHub.shared.revoke(project: run.id)
                        if !cancellation.isCancelled {
                            switch fixed {
                            case .success(let raw):
                                let (tagless, mood) = FaceLink.extract(raw)
                                if let mood { FaceLink.shared.show(mood) }
                                let (reply, newState) = Self.extractState(tagless)
                                notePeerOutcome(account, reply: tagless)
                                if let newState { self.saveState(newState, room: id, index: index) }
                                run.setAppStep(1, L("검토 반영", "Apply the review"), .done)
                                let (shown, counts) = Peer.tally(reply, points: findings.points)
                                markReview(id: id, index: index, findings, counts: counts)
                                let combined = text + "\n\n---\n\n**" + L("검수 반영", "After the review") + "**\n\n" + shown
                                changeTurn(id, index, save: true) { $0.final = combined; $0.partial = nil; $0.activity = nil; $0.status = "" }
                            case .failure(let failure):
                                problem = L("검토 반영에 실패했어요.", "Could not apply the review."); run.setAppStep(1, L("검토 반영", "Apply the review"), .blocked)
                                markReview(id: id, index: index, findings, counts: nil)
                                let entry = ChatTurn.Entry(round: 1, speaker: speaker, text: L("검수 반영 실패: ", "Could not apply the review: ") + Self.describe(failure), failed: true)
                                changeTurn(id, index, save: true) { $0.moreAnswers = ($0.moreAnswers ?? []) + [entry]; $0.partial = nil; $0.activity = nil }
                            }
                        }
                    }
                }
                for reviewerID in mentions.dropFirst() where reviewerID != account.id && !cancellation.isCancelled {
                    guard let reviewer = model.accounts.first(where: { $0.id == reviewerID }) else { continue }
                    run.nextAttempt()
                    var view = workspace
                    view.level = .view; view.project = nil; view.projectRunID = nil; view.projectGeneration = nil
                    view.roots = workspace.roots.map { WorkspaceRoot(path: $0.path, directory: $0.directory, writable: $0.path == Self.chatFolder(id).path ? true : nil) }
                    let reviewPrompt = Self.soloContext(rules: rules, transcript: transcript + "\n[Writer result]\n" + text) + "\n[SOLO TURN]\nReview the linked project read-only. Do not edit the project or run Git writes.\n" + run.checkpoint("Read-only review")
                    let reviewResult = !permits(reviewer, room: id) ? .failure(Enterprise.blocked(reviewer))
                        : workspaceAnswer?(reviewer, reviewPrompt, view, run.attempt, nil) ?? Answerer.ask(reviewer, prompt: reviewPrompt, timeout: min(900, run.deadline.timeIntervalSinceNow), cancellation: run.attempt, run: .app(reviewer, WorkspaceInvocation(binding: view, room: id)))
                    run.attempt.cancel()
                    let reviewText: String, failed: Bool
                    switch reviewResult {
                    case .success(let raw): let parsed = FaceLink.extract(raw); reviewText = parsed.text; failed = false; if let mood = parsed.mood { FaceLink.shared.show(mood) }
                    case .failure(let error): reviewText = Self.describe(error); failed = true
                    }
                    changeTurn(id, index, save: true) { turn in
                        if turn.moreAnswers == nil { turn.moreAnswers = [] }
                        turn.moreAnswers?.append(ChatTurn.Entry(round: 1, speaker: self.label(reviewer), text: reviewText, failed: failed))
                    }
                }
                _ = run.checkpoint("Project turn completed by " + speaker)
                finish(id, index); return
            case .failure(let failure) where Self.isOutOfUsage(failure):
                checkpoint = run.checkpoint("Usage exhausted: " + speaker + ". Continue the same unfinished project without overwriting it.")
                excluded.insert(account.id); preferred = nil; handedFrom = speaker
                run.note(speaker + L(" 한도 소진 → 다른 AI로 인계", " reached its limit → handing off"))
            case .failure(let failure): finish(id, index, error: Self.describe(failure)); return
            }
        }
        finish(id, index, error: L("프로젝트 작업을 중지했습니다. 변경은 보존했어요.", "Project work stopped. Changes are preserved."))
    }

    static let fullAutoNote = """
    [FULL AUTO] The user may be away. Work to completion without asking questions; make reasonable decisions and list them at the end.
    You may run any command, use the network and install tools. Run the registered test/build commands with project_run (no approval needed),
    not your shell: the user sees their progress and how long they usually take.
    Your shell has no Git/GitHub credentials: commit locally with git, push only with the git_push tool. Never force push or rewrite pushed history.
    rm moves files to the Trash. Stable still needs the user's card: call git_publish_stable only when the user's latest message asks to publish/deploy stable,
    and the app shows the card and waits for the user. Otherwise do not publish; finish with a summary of what is ready for the user to publish.
    """

    // A documents project (papers, slides, posters, figures and data mixed in one folder, without Git).
    static let documentsNote = """
    One task may touch several kinds of files (text, figures, slides); pick how to change and check each file by its type:
    - Text sources (.tex .md .typ .bib .txt): edit them directly. When the folder can be built (LaTeX, Typst, Markdown to PDF), build it and look at the
      changed pages as pictures: overflow, broken figures, ?? references, page count.
    - Figures: change the script or data-to-figure code that makes them and run it again; do not paint over the picture. Look at the new figure.
      Keep the old output unless the user asked to replace it.
    - Word/PowerPoint (.docx .pptx): change them with a small python-docx/python-pptx script, run it, and check the result (read it back; render to PDF
      with LibreOffice if it is installed). Leave slides with SmartArt or animations alone and ask. If a "~$" lock file is next to the file, the user has it
      open: do not write it; ask. In Word, prefer tracked changes for edits to the user's text.
    - Google Docs/Slides (.gdoc .gslides pointer files): read them with drive_read; change them only with drive_edit_doc / drive_edit_slides, in folders
      the Drive settings allow writing. The app's backup cannot undo these (Google's version history can): say what you changed there.
    - PDF, images and raw data: read only unless the user asks to change that very file.
    Never invent references, citations or data: leave \\cite{TODO} or a clear [TODO] and ask. Never change numbers, results or measured data unless asked.
    Ask before rewriting large parts of the user's own text. Change the user's original files, not a copy, unless asked for a new version.
    Steps only the user can do (insert a picture into a Google Doc, accept tracked changes, final check in Office) are not done by you: list them as user steps.
    There is no Git: do not run git init or git commands. The app backed this folder up before this answer (the user can Undo it); files only in the cloud
    were not copied. Run registered build commands with project_run when the folder has a .ai-illuminati.json; you may add one (absolute executable, args array).
    If the work has 3 or more steps, first show your steps with work_plan and update it whenever a step starts or ends.
    Use foreground commands only, never leave background writers.
    """
    static let documentsAutoNote = """
    [FULL AUTO] The user may be away. Work to completion without asking questions, except for the rules above (references, numbers, large rewrites,
    open files); make reasonable decisions and list them at the end. You may run commands, use the network and install tools. rm moves files to the Trash.
    """

    // The writing AI ends its reply with a <face> tag (plain chat and project work alike).
    // The read-only reviewer gets no rule, so the writer's face stays.
    static func projectFaceRule(face: Bool, active: Bool = FaceLink.active() != nil,
                                moods: @autoclosure () -> [String] = FaceLink.shared.moods()) -> String {
        face && active ? FaceLink.rule(moods()) : ""
    }

    func toggleFullAuto() {
        guard !running, current.workspace?.project != nil || current.workspace?.roots.contains(where: \.directory) == true else { return }
        let on = current.workspace?.isFullAuto == true
        change(currentID, save: true) { $0.workspace?.fullAuto = on ? false : nil }
    }
}

extension Notification.Name {
    // A project turn ended (not stopped by the user): room, index, problem (nil: done). ApprovalAlerts tells the user.
    static let projectWorkEnded = Notification.Name("AIIlluminatiProjectWorkEnded")
}

// Settings → Chat → Approval requests. Read by ApprovalAlerts; missing keys mean the defaults.
enum ApprovalAlertSettings {
    static let notifyKey = "approvalNotify", soundKey = "approvalSound", repeatKey = "approvalRepeat"
    static var notify: Bool { UserDefaults.app.object(forKey: notifyKey) as? Bool ?? true }
    static var sound: Bool { UserDefaults.app.bool(forKey: soundKey) }
    static var repeats: Bool { UserDefaults.app.bool(forKey: repeatKey) }
}
