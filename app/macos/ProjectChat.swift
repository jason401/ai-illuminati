import Cocoa
import SwiftUI

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
    // A draft or attached images the user already has there are kept, not sent (the note stays).
    func askAgain(_ request: ProjectApproval) {
        open(request.room)
        let text = request.title.hasPrefix("stable") ? L("stable 배포 다시 진행해 줘", "Please publish stable again")
            : L("방금 허가를 기다리던 작업 다시 진행해 줘", "Please continue the work that was waiting for approval")
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, pendingImages.isEmpty else { return }
        ProjectCenter.shared.dismiss(request.id)
        draft = text
        send()
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
            let alert = NSAlert()
            alert.messageText = L("이 채팅에서 프로젝트 작업 허용", "Allow project work in this chat")
            alert.informativeText = project.root + "\n\n" + L("완전 자동으로 일해요: AI가 승인 카드 없이 모든 명령을 실행하고 인터넷을 쓰고 main에 push해요. 한 번에 최대 8시간, 그동안 Mac이 잠들지 않아요.\n\n막아 두는 것: 강제 push·기록 지우기, 영구 삭제(rm은 휴지통으로). stable 배포는 매번 직접 허용해요.\n\n카드로 하나씩 확인하려면 + 메뉴에서 완전 자동을 끄세요. 신뢰하는 프로젝트만 연결하세요.", "Works in full auto: the AI runs any command without approval cards, uses the network and pushes to main. Up to 8 hours per task, with the Mac kept awake.\n\nStill blocked: force push and history rewrites, permanent deletes (rm moves to the Trash). Publishing stable always asks you.\n\nTo confirm steps with cards, turn off full auto in the + menu. Only connect projects you trust.")
            alert.addButton(withTitle: L("허용", "Allow")); alert.addButton(withTitle: L("취소", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            change(currentID, save: true) { conversation in
                var binding = conversation.workspace ?? WorkspaceBinding(roots: [])
                if !binding.roots.contains(where: { $0.path == project.root }) { binding.roots.append(WorkspaceRoot(path: project.root, directory: true, writable: true)) }
                binding.project = project; conversation.workspace = binding
            }
        } catch { attachmentError = error.localizedDescription }
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
        var projectRules = ""
        for name in ["AGENTS.md", "CLAUDE.md"] {
            let file = URL(fileURLWithPath: selected.root).appendingPathComponent(name)
            if file.resolvingSymlinksInPath().path.hasPrefix(selected.root + "/"), let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) {
                projectRules += "\n[Project rules: \(name)]\n" + String(text.prefix(max(0, 30_000 - projectRules.count)))
                if projectRules.count >= 30_000 { projectRules += "\n[Project rules truncated]"; break }
            }
        }
        let transcript = Self.transcript(history) + "\n[User]\n" + question
        let chatLock = self.lock(of: id)
        var excluded = Set<String>(), checkpoint = run.checkpoint("Project turn started")
        // Picked by hand (@ or one account checked): that one. Otherwise the same rule as a plain chat: the last
        // account keeps going while 5-hour and weekly usage both have 15% or more left (AutoPick). During the
        // work only a usage-limit error hands it to another AI.
        var preferred = mentions.first ?? config.soloAccountID
        var handedFrom: String?   // the AI that reached its usage limit, shown while the next one takes over
        // Before the work starts: what the project looks like, so the review covers only this answer's changes
        // (also when another AI took over after a usage limit).
        let start = reviewers.isEmpty ? nil : ProjectSnapshot.take(root: selected.root)
        while !cancellation.isCancelled && Date() < run.deadline && !run.activeExpired {
            let eligible = model.accounts.filter { [.claude, .codex].contains($0.provider) && !excluded.contains($0.id) && Enterprise.permits($0, lock: chatLock) }
            let account = preferred.flatMap { wanted in eligible.first { $0.id == wanted } }
                ?? AutoPick.choose(eligible, usage: model.latestUsage, lock: chatLock, current: config.lastSoloAccountID)
            guard let account else {
                finish(id, index, error: chatLock != nil
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
                                                  project: ProjectPart(root: selected.root, fullAuto: fullAuto, rules: projectRules), chat: id)
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
                    case .plan(let steps): run.setPlan(steps, note: nil, generation: generation, tool: false)
                    }
                }
                guard permits(account, room: id) else { return .failure(Enterprise.blocked(account)) }
                if let workspaceAnswer { return workspaceAnswer(account, prompt, workspace, run.attempt, progress) }
                return nativeSessions.ask(account, room: id, prompt: prompt, images: activeImages,
                                          timeout: run.deadline.timeIntervalSinceNow, token: run.attempt, web: true, speaker: speaker, fresh: freshPrompt,
                                          invoke: { text, images, session in
                    Answerer.ask(account, prompt: text, timeout: run.deadline.timeIntervalSinceNow, cancellation: run.attempt,
                                 images: images, web: true, session: session,
                                 workspace: WorkspaceInvocation(binding: workspace, room: id, readOnly: false, backupPath: self.activeWorkspaceBackupPath), progress: progress)
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
                if let newState { self.saveState(newState, room: id, index: index) }
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
                                                 root: selected.root, start: start, question: question, reply: text, token: run.attempt) { name in
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
                        let fixed = attempt("\n" + findings, transcript: after, fresh: fresh.map { $0 + "\n[" + speaker + "]\n" + text })
                        run.attempt.cancel(); ToolHub.shared.revoke(project: run.id)
                        if !cancellation.isCancelled {
                            switch fixed {
                            case .success(let raw):
                                let (tagless, mood) = FaceLink.extract(raw)
                                if let mood { FaceLink.shared.show(mood) }
                                let (reply, newState) = Self.extractState(tagless)
                                if let newState { self.saveState(newState, room: id, index: index) }
                                run.setAppStep(1, L("검토 반영", "Apply the review"), .done)
                                let combined = text + "\n\n---\n\n**" + L("검수 반영", "After the review") + "**\n\n" + reply
                                changeTurn(id, index, save: true) { $0.final = combined; $0.partial = nil; $0.activity = nil; $0.status = "" }
                            case .failure(let failure):
                                problem = L("검토 반영에 실패했어요.", "Could not apply the review."); run.setAppStep(1, L("검토 반영", "Apply the review"), .blocked)
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
                        : workspaceAnswer?(reviewer, reviewPrompt, view, run.attempt, nil) ?? Answerer.ask(reviewer, prompt: reviewPrompt, timeout: min(900, run.deadline.timeIntervalSinceNow), cancellation: run.attempt, workspace: WorkspaceInvocation(binding: view, room: id))
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
    You may run any command, use the network, install tools and run tests/builds directly (project_run needs no approval).
    Your shell has no Git/GitHub credentials: commit locally with git, push only with the git_push tool. Never force push or rewrite pushed history.
    rm moves files to the Trash. Stable still needs the user's card: call git_publish_stable only when the user's latest message asks to publish/deploy stable,
    and the app shows the card and waits for the user. Otherwise do not publish; finish with a summary of what is ready for the user to publish.
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
