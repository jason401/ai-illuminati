import Foundation

// A meeting: the user picks "회의" (or "/meet ") for one message, and the AIs of the chat hold a short discussion
// about it in a hidden chat of their own, then bring the result back as the answer.
// - The hidden chat keeps every speech, so the chat's own history (and every later prompt) gets only the result.
// - It is locked like the chat it was held for, and the AIs speak in its sessions, not the chat's.
// - They know the chat: its state, its last turns and the whole chat up to then in meeting-source.md, read only.
// - It runs as the chat's own answer (one of the running slots); the chat's stop button stops it.
// Each AI speaks twice at most: everyone gives a first view without seeing the others, then reviews once.
struct MeetingLink: Codable, Equatable {
    var room: UUID   // the chat the meeting was held for
    var turn: UUID   // its message
}

extension Discussion {
    static let meetingTurnsPerAI = 2
    static let meetingSource = "meeting-source.md"

    // Who meets: the AIs picked with @, else the chat's members, else whoever answers now; allowed by the chat's lock.
    // The discussion keeps one AI of each kind (it keys turns by kind): the first one picked of each.
    func meetingMembers(room: UUID, mentioned: [String], fallback: [Account]) -> [Account] {
        let standing = standingMembers(room: room)
        let ids = !mentioned.isEmpty ? mentioned : !standing.isEmpty ? standing : memberIDs(room: room).isEmpty ? fallback.map(\.id) : memberIDs(room: room)
        var kinds: Set<Account.Provider> = [], team: [Account] = []
        for id in ids {
            guard let account = model.accounts.first(where: { $0.id == id }), [.claude, .codex, .gemini].contains(account.provider),
                  permits(account, room: room), model.latestUsage[id]?.needsLogin != true, kinds.insert(account.provider).inserted else { continue }
            team.append(account)
        }
        return team
    }

    // Makes the meeting's hidden chat for `turn` of chat `id` (on the main thread), with the chat's lock and the
    // whole chat so far in its folder. Returns its id.
    func openMeeting(for id: UUID, turn: ChatTurn, history: [ChatTurn]) -> UUID {
        let chat = conversation(id)
        var room = Conversation()
        room.title = L("회의: ", "Meeting: ") + String(turn.question.prefix(40))
        room.meetingOf = MeetingLink(room: id, turn: turn.id)
        room.enterpriseLock = chat.enterpriseLock
        var config = ChatConfiguration()
        config.mode = 1; config.modeVersion = 2; config.turnsPerAI = Self.meetingTurnsPerAI
        room.configuration = config
        var first = ChatTurn(question: turn.question)
        first.mode = 1; first.modeVersion = 2; first.askedAt = Date(); first.turnsPerAI = Self.meetingTurnsPerAI
        first.images = turn.images
        room.turns = [first]
        let source = "# \(chat.title)\n\n" + Self.transcript(history) + "\n\n[User — the meeting's topic]\n" + turn.question + "\n"
        Self.saveText(source, to: Self.chatFolder(room.id).appendingPathComponent(Self.meetingSource))
        conversations.append(room)
        ChatStore.save(room)
        meetingsClosed.remove(id)
        return room.id
    }

    // What every speech starts with instead of the whole chat: the chat's state, its last turns and where the rest is.
    static func meetingBrief(state: String, history: [ChatTurn], source: String) -> String {
        let recent = transcript(Array(history.suffix(recentTurns)))
        return """
        [Meeting] The user asked the AIs below to hold a short meeting about their message from another chat, and to bring
        the result back there. Read that chat's context first. The whole chat up to now is in \(source): read it when you
        need a detail that is not here. Every folder is read only; do not change files or run commands.
        \(state.isEmpty ? "" : "[Chat state]\n" + state + "\n")\(recent.isEmpty ? "" : "[Latest turns of the chat, word for word]\n" + recent)
        """
    }

    // The chat's worker holds the meeting in the hidden chat `room` and puts the result on turn `index` of chat `id`.
    func runMeeting(question: String, history: [ChatTurn], rules: String, team: [Account], room: UUID,
                    cancellation: DebateCancellation, id: UUID, index: Int) {
        let names = team.map(label)
        let note = Self.routeNote(.meeting, by: nil, names: names, forced: true)
        changeTurn(id, index, save: true) { t in
            t.route = RouteChoice.meeting.route; t.meetingRoom = room; t.routeNote = note
            t.status = L("회의 중… (\(names.joined(separator: ", "))) · 아래 \"회의 과정 보기\"에서 볼 수 있어요",
                         "Meeting… (\(names.joined(separator: ", "))) · see \"Show the meeting\" below")
        }
        // The meeting's own sessions and lock (permits checks activeSessionRoom), the chat's folders read only.
        let folder = Self.chatFolder(room)
        var binding = soloBinding(id)
        binding.roots.insert(WorkspaceRoot(path: folder.path, directory: true, writable: true), at: 0)
        var view = Route.opinionView(binding, chatFolder: folder.path)
        view.face = nil
        activeSessionRoom = room
        activeWorkspace = view
        activeMeeting = true
        activeAdversarial = false
        activeDocumentText = "[Folders]\n" + view.roots.map { "- \($0.path)" + ($0.writable == true ? " (meeting notes — you may write here)" : " (read only)") }.joined(separator: "\n")
        let brief = Self.meetingBrief(state: Self.loadState(id), history: history, source: folder.appendingPathComponent(Self.meetingSource).path)
        let leader = team.first { [.claude, .codex].contains($0.provider) }?.provider ?? team[0].provider
        let result = runDebate(question: question, history: [], rules: rules, team: team, leader: leader, perAI: Self.meetingTurnsPerAI,
                               cancellation: cancellation, id: room, index: 0, meeting: brief)
        changeTurn(room, 0, save: true) { $0.answeredAt = Date() }
        changeTurn(id, index, save: true) { t in
            t.status = ""
            if let result {
                t.final = result.text
                t.finalBy = L("회의 · ", "Meeting · ") + names.joined(separator: ", ")
                t.finalImages = result.images.isEmpty ? nil : result.images
            } else if cancellation.isCancelled {
                t.endReason = L("회의를 중지했어요. 지금까지의 발언은 \"회의 과정 보기\"에 있어요.", "Meeting stopped. What was said so far is under \"Show the meeting\".")
            } else {
                t.error = L("회의 결론을 정리하지 못했어요. 발언은 \"회의 과정 보기\"에 있어요.", "The meeting's result could not be written. What was said is under \"Show the meeting\".")
            }
        }
        finish(id, index)
    }

    // The final prompt of a meeting: the result for a user who was not there, disagreements kept.
    static func meetingFinal(missing: [String]) -> String {
        """
        [MEETING RESULT]
        Write the result of this meeting for the user, who did not see it. Use these headings, in the user's language,
        and skip one only when it has nothing: \(L("결론 / 근거 / 합의 / 이견 / 네 결정이 필요한 것 / 다음 행동", "Conclusion / Reasons / Agreed / Disagreements / Needs your decision / Next step")).
        Conclusion first, directly. Under disagreements keep every real one: who held which view and why; do not smooth them into
        a consensus. Name who said what where it matters. Short bullet points; links the team found.
        \(missing.isEmpty ? "" : "These AIs did not answer in the meeting; say so in one line: \(missing.joined(separator: ", ")).\n")If there is a next step an AI could do in the project, end with one line offering it: \(L("\"가자라고 하면 …할게.\"", "\"Say 가자 (go) and I will ….\""))
        """
    }

    // The meeting chats held for chat `id`, newest first: the sidebar lists them under it.
    func meetings(of id: UUID) -> [Conversation] {
        conversations.filter { $0.meetingOf?.room == id }.sorted { $0.createdAt > $1.createdAt }
    }

    // Still being held: its chat is answering and the meeting has no end yet.
    func meetingRunning(_ meeting: Conversation) -> Bool {
        guard let link = meeting.meetingOf else { return false }
        return runningRooms.contains(link.room) && meeting.turns.first?.answeredAt == nil
    }

    // Unfolded by the user, or (unless folded by the user) while one runs or the chat or one of them is open.
    func meetingsShown(_ id: UUID, _ meetings: [Conversation]) -> Bool {
        if meetingsOpen.contains(id) { return true }
        if meetingsClosed.contains(id) { return false }
        return currentID == id || meetings.contains { $0.id == currentID || meetingRunning($0) }
    }

    func toggleMeetings(_ id: UUID) {
        if meetingsShown(id, meetings(of: id)) { meetingsOpen.remove(id); meetingsClosed.insert(id) }
        else { meetingsClosed.remove(id); meetingsOpen.insert(id) }
    }

    // Removes the hidden meeting chats of a deleted chat (files, sessions and backups too).
    func removeMeetings(of id: UUID) {
        for meeting in conversations where meeting.meetingOf?.room == id {
            guard (try? ChatStore.delete(meeting)) != nil else { continue }
            conversations.removeAll { $0.id == meeting.id }
            if currentID == meeting.id {
                let fresh = Conversation()
                conversations.insert(fresh, at: 0)
                currentID = fresh.id
            }
        }
    }
}
