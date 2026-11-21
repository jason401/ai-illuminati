import SwiftUI
import AIChatRecords
import AILocalization
import AIRuntime

// Claude's own subagents (its Agent tool) as read-only rooms under the chat that ran them: one hidden chat per Agent
// call, attached like a meeting (meetingOf: read only, deleted with the chat, not listed, searched or synced) and
// marked with agentOf. Its one turn is the task the agent got; its answer grows with what the agent says and the tools
// it runs, and ends with its result. Fed by AnswerProgress.agent from the answering call.

extension Discussion {
    static let agentLogMost = 200_000   // characters kept per record; the newest part stays

    // One agent event from the answer to turn `index` of chat `room` (any thread).
    func agentProgress(_ event: AgentProgress, room: UUID, index: Int) {
        let apply = { [weak self] in
            guard let self else { return }
            let owner = self.host ?? self
            owner.recordAgent(event, room: room, index: index)
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    private func recordAgent(_ event: AgentProgress, room: UUID, index: Int) {
        if event.kind == .started {
            guard !conversations.contains(where: { $0.agentOf?.toolUseID == event.toolUseID }),
                  let chat = conversations.first(where: { $0.id == room }), chat.turns.indices.contains(index) else { return }
            let name = [event.subagentType, event.description].compactMap { $0 }.joined(separator: " · ")
            var record = Conversation()
            record.title = L("에이전트: ", "Agent: ") + String((event.description ?? event.subagentType ?? "").prefix(40))
            record.meetingOf = MeetingLink(room: room, turn: chat.turns[index].id)
            record.agentOf = AgentRoomLink(room: room, turn: chat.turns[index].id, toolUseID: event.toolUseID,
                                           description: event.description, type: event.subagentType)
            record.enterpriseLock = chat.enterpriseLock
            record.shareToDevices = false
            var config = ChatConfiguration()
            config.mode = 0; config.modeVersion = 2
            record.configuration = config
            var turn = ChatTurn(question: event.prompt ?? event.description ?? "")
            turn.mode = 0; turn.modeVersion = 2; turn.askedAt = Date()
            turn.finalBy = name.isEmpty ? L("에이전트", "Agent") : L("에이전트 · ", "Agent · ") + name
            record.turns = [turn]
            conversations.append(record)
            ChatStore.save(record)
            return
        }
        guard let i = conversations.firstIndex(where: { $0.agentOf?.toolUseID == event.toolUseID }),
              conversations[i].agentOf?.running == true, !conversations[i].turns.isEmpty else { return }
        var log = conversations[i].turns[0].final ?? ""
        switch event.kind {
        case .text:
            guard let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            log += (log.isEmpty ? "" : "\n\n") + text
        case .tool:
            let tool = event.toolName ?? "tool"
            let what = (event.text ?? "").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "`", with: "'")
            log += (log.isEmpty ? "" : "\n\n") + "▸ `" + tool + "`" + (what.isEmpty ? "" : " " + what)
            conversations[i].agentOf?.lastTool = tool + (what.isEmpty ? "" : " · " + String(what.prefix(60)))
        case .finished:
            if let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, !log.hasSuffix(text) {
                log += (log.isEmpty ? "" : "\n\n---\n\n") + (event.failed ? L("**실패:** ", "**Failed:** ") : "") + text
            } else if event.failed {
                log += (log.isEmpty ? "" : "\n\n") + L("**실패**", "**Failed**")
            }
            conversations[i].agentOf?.running = false
            conversations[i].agentOf?.failed = event.failed
            conversations[i].agentOf?.endedAt = Date()
            conversations[i].agentOf?.lastTool = nil
            conversations[i].turns[0].answeredAt = Date()
        case .started: return
        }
        if log.count > Self.agentLogMost { log = "…\n\n" + String(log.suffix(Self.agentLogMost)) }
        conversations[i].turns[0].final = log
        conversations[i].updatedAt = Date()
        // Saved at its start and end; in between at most every few seconds (a crash keeps most of it).
        if event.kind == .finished || Date().timeIntervalSince(agentSavedAt[conversations[i].id] ?? .distantPast) >= Self.partialSaveEvery {
            agentSavedAt[conversations[i].id] = Date()
            ChatStore.save(conversations[i])
        }
    }

    // Still working: marked running and the answer that started it still runs (a stopped or crashed answer ends it too).
    func agentRunning(_ record: Conversation) -> Bool {
        guard let link = record.agentOf, link.running else { return false }
        return runningRooms.contains(link.room)
    }

    // The subagent records of chat `id`, newest first.
    func agentRooms(of id: UUID) -> [Conversation] {
        conversations.filter { $0.agentOf?.room == id }.sorted { $0.createdAt > $1.createdAt }
    }

    // Shown while one of them runs or is the open chat, until the user folds them; folded otherwise.
    func agentsShown(_ id: UUID, _ records: [Conversation]) -> Bool {
        if agentsOpen.contains(id) { return true }
        if agentsClosed.contains(id) { return false }
        return records.contains { $0.id == currentID || agentRunning($0) }
    }

    func toggleAgents(_ id: UUID) {
        if agentsShown(id, agentRooms(of: id)) { agentsOpen.remove(id); agentsClosed.insert(id) }
        else { agentsClosed.remove(id); agentsOpen.insert(id) }
    }
}

// The fold row above a chat's subagent records: "에이전트 3개 · 접기" or "· 접힘 (눌러서 보기)".
struct AgentRoomsFoldedRow: View {
    let main: UUID
    let records: [Conversation]
    @ObservedObject var discussion: Discussion
    var depth = 0
    var body: some View {
        let shown = discussion.agentsShown(main, records), working = records.filter { discussion.agentRunning($0) }.count
        Button(action: { discussion.toggleAgents(main) }) {
            HStack(spacing: 5) {
                Image(systemName: shown ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold)).frame(width: 18)
                Text((working > 0 ? L("에이전트 \(records.count)개 · \(working)개 작업 중", "\(records.count) agents · \(working) working")
                                  : L("에이전트 \(records.count)개", "\(records.count) agents"))
                     + (shown ? L(" · 접기", " · fold") : L(" · 접힘 (눌러서 보기)", " · folded (click to show)")))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11)).foregroundColor(.secondary)
            .padding(.leading, 24 + CGFloat(depth) * 12).padding(.trailing, 10).frame(minHeight: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
    }
}

// A subagent record under its chat: "↳ 에이전트 · description" and "running m min · Bash · …" / "done" / "failed".
struct AgentRoomRow: View {
    let room: Conversation
    @ObservedObject var discussion: Discussion
    var depth = 0
    var body: some View {
        let link = room.agentOf
        let running = discussion.agentRunning(room)
        let selected = room.id == discussion.currentID && discussion.viewingRemote == nil && !discussion.viewingBoard && discussion.viewingSpace == nil
        let key = "agent." + room.id.uuidString
        TimelineView(.periodic(from: Date(), by: 30)) { context in
            HStack(spacing: 5) {
                Group {
                    if running { ProgressView().controlSize(.mini) }
                    else { Image(systemName: link?.failed == true ? "xmark.circle" : "checkmark.circle").font(.system(size: 9))
                        .foregroundColor(link?.failed == true ? .red : .secondary) }
                }
                .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("↳ " + L("에이전트 · ", "Agent · ") + (link?.description ?? room.title)).lineLimit(1).truncationMode(.tail)
                    Text(Self.state(room, running: running, now: context.date))
                        .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 12))
        .padding(.leading, 24 + CGFloat(depth) * 12).padding(.trailing, 10).frame(height: 36)
        .background(selected ? Color.primary.opacity(0.10) : discussion.hoverKey == key ? Color.primary.opacity(0.05) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { discussion.open(room.id) }
        .onHover { inside in discussion.hover(key, inside) }
        .help(room.title)
        .disabled(discussion.importingMaterials)
    }

    static func state(_ room: Conversation, running: Bool, now: Date) -> String {
        let link = room.agentOf
        if running {
            let minutes = max(0, Int(now.timeIntervalSince(room.createdAt) / 60))
            return [link?.type, L("실행 중 \(minutes)분", "running \(minutes) min"), link?.lastTool].compactMap { $0 }.joined(separator: " · ")
        }
        let end = link?.failed == true ? L("실패", "failed") : link?.endedAt == nil ? L("멈춤", "stopped") : L("끝남", "done")
        return [link?.type, end].compactMap { $0 }.joined(separator: " · ")
    }
}
