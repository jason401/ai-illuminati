import Foundation
import AIAccounts
import AILocalization
import AIProjects
import AIRuntime
import AIWorkspace

// The app's entry point for the idle check and the Project info button. A hidden meeting uses
// a regular running slot so a second check cannot start another cleanup while it is working.
public enum ProjectMemoryCleanupLink {
    @discardableResult
    public static func runIfIdle(in discussion: Discussion, project: String? = nil, manual: Bool = false) -> Bool {
        precondition(Thread.isMainThread)
        let todo = TodoStore.shared.current
        guard !discussion.anyRunning, !todo.items.contains(where: { $0.state == .running }) else { return false }
        let groups = SidebarProjects.group(discussion.listedConversations.filter(\.hasContent), todo: todo, pinned: []).projects
        let now = Date()
        for group in groups where project == nil || group.id == project {
            let lists = todo.lists.filter { group.lists.contains($0.id) }
            let chats = group.chats + group.todoRooms
            let locks = lists.compactMap(\.lock) + chats.compactMap(\.enterpriseLock)
            // Shared memory is read-only in Enterprise projects. Personal projects may only use their own accounts.
            guard !locks.contains(where: { !$0.isPersonal }) else { continue }
            let lock = locks.first
            let team = Discussion.meetingTeam(discussion.model.accounts, usage: discussion.model.latestUsage,
                                              picks: discussion.model.autoTeamPicks) {
                ($0.provider != .ollama || discussion.model.localEnabled) && Enterprise.permits($0, lock: lock)
            }
            guard team.count >= 2 else { continue }
            let since = ProjectMemoryCleanup.last(group.id)?.at ?? .distantPast
            let answers = chats.reduce(0) { count, chat in
                count + chat.turns.filter {
                    $0.final != nil && $0.error == nil && $0.cutOff != true && ($0.answeredAt ?? $0.askedAt ?? chat.updatedAt) > since
                }.count
            }
            guard ProjectMemoryCleanup.due(group.id, answers: answers, manual: manual, now: now,
                                           size: { ProjectMemory.line($0).count }) else { continue }
            let tasks = todo.items.filter { group.lists.contains($0.listID) }
            start(in: discussion, group: group, chats: chats, tasks: tasks, lock: lock, team: team,
                  since: since, now: now, manual: manual)
            return true
        }
        return false
    }

    private static func start(in discussion: Discussion, group: ProjectGroup, chats: [Conversation], tasks: [TodoItem],
                              lock: EnterpriseLock?, team: [Account], since: Date, now: Date, manual: Bool) {
        let anchor = chats.first?.id ?? group.lists.first ?? UUID()
        let topic = L("프로젝트 메모리 정리", "Project memory cleanup")
        let room = discussion.openMeeting(for: anchor, topic: topic, appLock: lock)
        let token = DebateCancellation()
        let worker = discussion.backgroundMeetingWorker(room, cancellation: token)
        worker.prepareMeeting(room: room, binding: WorkspaceBinding(roots: []), appCalled: true)
        let rules = discussion.model.chatRules.trimmingCharacters(in: .whitespacesAndNewlines)
        let leader = team.first { [.claude, .codex].contains($0.provider) }?.provider ?? team[0].provider
        DispatchQueue.global(qos: .utility).async {
            let input = material(group: group, chats: chats, tasks: tasks, since: since, now: now, token: token)
            guard !token.isCancelled else { worker.finish(room, 0); return }
            let brief = Discussion.meetingBrief(state: "", history: [], source: "", brief: input.text, appCalled: true)
            let result = worker.runDebate(question: topic, history: [], rules: rules, team: team, leader: leader,
                                          perAI: Discussion.meetingTurnsPerAI, cancellation: token, id: room, index: 0,
                                          meeting: brief, cleanup: true)
            guard !token.isCancelled else { worker.finish(room, 0); return }
            guard let result, let edits = edits(from: result.text) else {
                worker.finish(room, 0, error: L("정리 회의에서 유효한 변경 목록을 받지 못했어요.",
                                               "The cleanup meeting did not return a valid change list."))
                return
            }
            switch ProjectMemoryCleanup.apply(edits, meeting: room, attendees: result.attendees, chats: input.chats,
                                              commits: input.commits, project: group.id, manual: manual, now: now) {
            case .applied: worker.finish(room, 0)
            case .refused(let reason):
                worker.finish(room, 0, error: L("메모리 정리를 적용하지 못했어요. ", "Could not apply the memory cleanup. ") + reason)
            }
        }
    }

    private static func material(group: ProjectGroup, chats: [Conversation], tasks: [TodoItem], since: Date, now: Date,
                                 token: DebateCancellation) -> (text: String, chats: Set<UUID>, commits: [String]) {
        let notes = ProjectMemory.cleanupLines(ProjectMemoryStore.shared.notes(group.id))
        let summaries = chats.filter { $0.updatedAt > since && !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let recent = max(since, now.addingTimeInterval(-Double(ProjectMemoryCleanup.logDays) * 86_400))
        let date = ISO8601DateFormatter()
        let start = date.string(from: recent), end = date.string(from: now)
        var hashes = Set<String>(), commits: [(hash: String, line: String)] = []
        for binding in group.bindings where !binding.isDocuments && !token.isCancelled {
            let log = (try? ProjectProcess.git(["log", "--no-show-signature", "--since=\(start)", "--until=\(end)", "--format=%H%x09%s"],
                                               root: binding.root, token: token, timeout: 10)) ?? ""
            for line in log.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let hash = String(parts[0])
                guard (hash.count == 40 || hash.count == 64), hash.allSatisfy(\.isHexDigit), hashes.insert(hash).inserted else { continue }
                commits.append((hash, "\(hash) \(parts[1])"))
            }
        }
        let handoff = group.bindings.lazy.filter { !$0.isFolderless }.compactMap { binding -> String? in
            let root = URL(fileURLWithPath: binding.root).resolvingSymlinksInPath().standardizedFileURL
            let file = root.appendingPathComponent("HANDOFF.md").resolvingSymlinksInPath().standardizedFileURL
            guard file.deletingLastPathComponent().path == root.path,
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return try? String(contentsOf: file, encoding: .utf8)
        }.first ?? ""
        let finished = tasks.filter { ($0.state == .done || $0.state == .cancelled) && ($0.finishedAt ?? $0.updatedAt) > recent }
        let taskLines = finished.map { task in
            "- [\(task.state.rawValue)] \(task.title)" + (task.result.map { "\n  " + $0 } ?? "")
        }
        let text = [
            ("Active memory", notes),
            ("Updated chat summaries (with chat IDs)", summaries.map { "[\($0.id.uuidString)]\n\($0.summary)" }),
            ("Recent Git commits", commits.map(\.line)),
            ("HANDOFF.md", [handoff]),
            ("Finished TODOs", taskLines),
        ].map { title, lines in "[\(title)]\n" + lines.joined(separator: "\n") }.joined(separator: "\n\n")
        return (text, Set(summaries.map(\.id)), commits.map(\.hash))
    }

    static let resultPrompt = """
    [MEETING RESULT]
    Return only a JSON array of project memory changes from the meeting. Use [] if no changes are warranted.
    Each change must include kind, ids (a list of affected note IDs, empty for add), evidence (chat UUIDs or commit
    hashes shown in the material), and agreed (a Boolean). Only mark agreed true when the discussion supports that
    change and no participant's objection remains. Preserve disputed changes with agreed false.
    Kinds: merge (two or more notes into text), fix (one note with corrected text), shorten (one note with shorter text),
    archive (obsolete notes or resolved progress), add (new text and noteKind), verify (one note and verified true
    or false), resolve (contradictory notes, with keep set to one of the IDs in ids).
    noteKind may be decision, progress, or log. Set verified only when the evidence supports the change.
    Keep each text to one line in the project's language. Include pinned notes in the review and preserve lasting
    decisions. Do not restore deleted notes or infer facts from missing material.
    """

    private static func edits(from text: String) -> [ProjectMemoryEdit]? {
        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The CLIs sometimes wrap JSON in a single Markdown code fence.
        if json.hasPrefix("```"), json.hasSuffix("```"), let newline = json.firstIndex(of: "\n") {
            json = String(json[json.index(after: newline)...].dropLast(3))
        }
        return try? JSONDecoder().decode([ProjectMemoryEdit].self, from: Data(json.utf8))
    }
}
