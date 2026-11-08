import Cocoa
import SwiftUI

struct ProjectApprovalView: View {
    let room: UUID
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
        }
    }
}

extension Discussion {
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
                        mentions: [String], cancellation: DebateCancellation, id: UUID, index: Int, binding: WorkspaceBinding,
                        fresh: String? = nil, keepState: Bool = false) {
        guard let selected = binding.project else { finish(id, index, error: "No project selected."); return }
        let fullAuto = binding.isFullAuto
        let run = ProjectRun(room: id, binding: selected, token: cancellation, fullAuto: fullAuto)
        run.onNote = { [weak self] log in self?.changeTurn(id, index) { $0.projectLog = log } }
        // Full auto keeps the Mac awake while the AI works (the display may still sleep).
        let awake = fullAuto ? ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "AI Illuminati full-auto project work") : nil
        defer { if let awake { ProcessInfo.processInfo.endActivity(awake) } }
        ProjectWork.register(run)
        defer {
            ProjectWork.finish(run)
            changeTurn(id, index) { $0.partial = nil; $0.activity = nil; $0.status = "" }
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
        var projectSchool = config.school
        var excluded = Set<String>(), checkpoint = run.checkpoint("Project turn started")
        var preferred = mentions.first ?? config.soloAccountID ?? config.lastSoloAccountID
        while !cancellation.isCancelled && Date() < run.deadline && !run.activeExpired {
            let eligible = model.accounts.filter { [.claude, .codex].contains($0.provider) && !excluded.contains($0.id) }
            let account = preferred.flatMap { wanted in eligible.first { $0.id == wanted } }
                ?? AutoPick.choose(eligible, usage: model.latestUsage, school: model.schoolOnlyHandoff ? projectSchool : nil, current: nil)
            guard let account else { finish(id, index, error: L("이어서 작업할 Claude/Codex 계정이 필요해요. 파일 변경은 보존했어요.", "No Claude/Codex account is available to continue. Changes are preserved.")); return }
            if model.schoolOnlyHandoff && projectSchool == nil { projectSchool = account.isSchool }
            run.nextAttempt(); workspace.projectGeneration = run.generation; activeWorkspace = workspace
            let speaker = label(account)
            changeTurn(id, index) { $0.status = speaker + L(" · 프로젝트 작업 중", " · working on project") }
            var instruction = soloInstruction(account, binding: workspace, helper: "",
                                              project: ProjectPart(root: selected.root, fullAuto: fullAuto, rules: projectRules), chat: id)
            if keepState { instruction += "\n" + Self.stateRule(current: Self.loadState(id)) }
            instruction += "\n[Verified app checkpoint; do not repeat completed operations blindly]\n" + checkpoint
            let prompt = Self.soloContext(rules: rules, transcript: transcript) + "\n[SOLO TURN]\n" + instruction
            let freshPrompt = fresh.map { Self.soloContext(rules: rules, transcript: $0) + "\n[SOLO TURN]\n" + instruction }
            let progress: (AnswerProgress) -> Void = { update in
                switch update {
                case .text(let text): self.changeTurn(id, index) { $0.partial = Self.extractState(FaceLink.extract(text).text).reply; $0.partialBy = speaker }
                case .activity(let text): self.changeTurn(id, index) { $0.activity = text }
                }
            }
            let started = Date()
            let result: Result<String, Answerer.Failure>
            if let workspaceAnswer { result = workspaceAnswer(account, prompt, workspace, run.attempt, progress) }
            else {
                result = nativeSessions.ask(account, room: id, prompt: prompt, images: activeImages,
                                            timeout: run.deadline.timeIntervalSinceNow, token: run.attempt, web: true, speaker: speaker, fresh: freshPrompt,
                                            invoke: { text, images, session in
                    Answerer.ask(account, prompt: text, timeout: run.deadline.timeIntervalSinceNow, cancellation: run.attempt,
                                 images: images, web: true, session: session,
                                 workspace: WorkspaceInvocation(binding: workspace, room: id, readOnly: false, backupPath: self.activeWorkspaceBackupPath), progress: progress)
                }, note: { text in DispatchQueue.main.async { self.sessionNote = text } })
            }
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
                    if self.model.schoolOnlyHandoff && saved.school == nil { saved.school = account.isSchool }
                    conversation.configuration = saved
                }
                for reviewerID in mentions.dropFirst() where reviewerID != account.id && !cancellation.isCancelled {
                    guard let reviewer = model.accounts.first(where: { $0.id == reviewerID }) else { continue }
                    run.nextAttempt()
                    var view = workspace
                    view.level = .view; view.project = nil; view.projectRunID = nil; view.projectGeneration = nil
                    view.roots = workspace.roots.map { WorkspaceRoot(path: $0.path, directory: $0.directory, writable: $0.path == Self.chatFolder(id).path ? true : nil) }
                    let reviewPrompt = Self.soloContext(rules: rules, transcript: transcript + "\n[Writer result]\n" + text) + "\n[SOLO TURN]\nReview the linked project read-only. Do not edit the project or run Git writes.\n" + run.checkpoint("Read-only review")
                    let reviewResult = workspaceAnswer?(reviewer, reviewPrompt, view, run.attempt, nil)
                        ?? Answerer.ask(reviewer, prompt: reviewPrompt, timeout: min(900, run.deadline.timeIntervalSinceNow), cancellation: run.attempt, workspace: WorkspaceInvocation(binding: view, room: id))
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
                excluded.insert(account.id); preferred = nil
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
