import SwiftUI
import AppKit
import AILocalization
import AIProjects
import AIChat

// Project info's "Project memory" section: the notes every AI of the project shares (AIProjects ProjectMemory.swift).
// The AIs add and replace notes without asking, so this is where the user checks them: edit, pin, archive, delete
// for good, and undo any change (or a whole meeting cleanup) from the history. All saving goes through the store.

// The section's typing and choices (an ObservableObject: this Mac's Command Line Tools cannot build SwiftUI's @State).
final class ProjectMemoryDraft: ObservableObject {
    static let shared = ProjectMemoryDraft()
    @Published var query = ""
    @Published var archive = false      // the archive instead of the active notes
    @Published var history = false
    @Published var editing: UUID?
    @Published var text = ""
    @Published var kind = ProjectMemoryNote.Kind.decision
    @Published var verified = false
    @Published var message: String?
}

struct ProjectMemorySection: View {
    @ObservedObject var discussion: Discussion
    let project: String   // SidebarProjects.key
    @ObservedObject private var memory = ProjectMemoryStore.shared
    @ObservedObject private var draft = ProjectMemoryDraft.shared

    static let shownChanges = 100

    var body: some View {
        let _ = memory.revision
        let notes = memory.notes(project)
        let active = notes.filter { $0.state == .active }, archived = notes.filter { $0.state == .archived }
        let history = memory.history(project)
        VStack(alignment: .leading, spacing: 8) {
            Label(L("프로젝트 기억", "Project memory"), systemImage: "brain.head.profile").font(.system(size: 15, weight: .semibold))
            Text(L("이 프로젝트의 AI들이 함께 읽고 쓰는 메모예요. AI가 묻지 않고 추가·대체하니, 여기서 확인하고 고치거나 되돌리세요.",
                   "Notes every AI of this project reads and writes. The AIs add and replace them without asking: check them here, fix or undo."))
                .font(.system(size: 12)).foregroundColor(.secondary)
            HStack(spacing: 8) {
                TextField(L("메모 검색", "Search notes"), text: $draft.query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Picker("", selection: $draft.archive) {
                    Text(L("사용 중 \(active.count)", "In use \(active.count)")).tag(false)
                    Text(L("보관함 \(archived.count)", "Archive \(archived.count)")).tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 220)
                Spacer(minLength: 6)
                Button(draft.history ? L("변경 기록 닫기", "Hide history") : L("변경 기록 \(history.count)", "History \(history.count)")) {
                    draft.history.toggle()
                }
                .controlSize(.small).disabled(history.isEmpty)
            }
            if let message = draft.message { Text(message).font(.system(size: 12)).foregroundColor(.red) }
            if draft.history { changes(history, notes: notes) }
            let shown = Self.filter(draft.archive ? archived : active, draft.query)
            if shown.isEmpty {
                Text(notes.isEmpty ? L("아직 메모가 없어요. 이 프로젝트의 대화에서 AI가 남기면 여기 보여요.", "No notes yet. When an AI saves one in a chat of this project, it shows here.")
                     : draft.query.isEmpty ? (draft.archive ? L("보관된 메모가 없어요.", "No archived notes.") : L("사용 중인 메모가 없어요.", "No notes in use."))
                     : L("찾는 메모가 없어요.", "No note matches."))
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            ForEach(ProjectMemoryNote.Kind.allCases, id: \.self) { kind in
                let list = shown.filter { $0.kind == kind }
                if !list.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.title(kind) + " \(list.count)").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                        ForEach(list) { row($0, all: notes) }
                    }
                }
            }
        }
        .onChange(of: project) { _ in draft.editing = nil; draft.message = nil }
    }

    // Pinned first, then the newest; words match the text or the AI's name.
    static func filter(_ notes: [ProjectMemoryNote], _ query: String) -> [ProjectMemoryNote] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return notes.filter { n in words.allSatisfy { n.text.lowercased().contains($0) || (n.by ?? "").lowercased().contains($0) } }
            .sorted { $0.pinned != $1.pinned ? $0.pinned : $0.createdAt > $1.createdAt }
    }

    static func title(_ kind: ProjectMemoryNote.Kind) -> String {
        switch kind {
        case .decision: return L("결정·사실", "Decisions and facts")
        case .progress: return L("진행 상황", "Progress")
        case .log: return L("작업 기록", "Work log")
        }
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = AppLanguage.current.locale; f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: A note

    private func row(_ note: ProjectMemoryNote, all: [ProjectMemoryNote]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: note.pinned ? "pin.fill" : "circle.fill")
                .font(.system(size: note.pinned ? 11 : 5)).foregroundColor(note.pinned ? .orange : .secondary)
                .frame(width: 18, height: 18)
            if draft.editing == note.id { editor(note) } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.text).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(meta(note, all: all)).font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer(minLength: 6)
                buttons(note)
            }
        }
        .padding(.vertical, 2)
    }

    private func meta(_ note: ProjectMemoryNote, all: [ProjectMemoryNote]) -> String {
        var parts = [note.by ?? "AI", Self.day(note.createdAt), note.verified ? L("확인됨", "Checked") : L("추측", "Guess")]
        if note.pinned { parts.append(L("고정", "Pinned")) }
        if note.replaces != nil { parts.append(L("이전 메모 대체", "Replaced an earlier note")) }
        if note.state == .archived {
            let by = note.replacedBy.flatMap { id in all.first { $0.id == id } }
            parts.append(by.map { L("새 메모로 대체됨: ", "Replaced by: ") + String($0.text.prefix(40)) } ?? L("보관됨", "Archived"))
        }
        return parts.joined(separator: " · ")
    }

    private func buttons(_ note: ProjectMemoryNote) -> some View {
        HStack(spacing: 2) {
            if let chat = note.chat {
                icon("arrow.up.forward.square", L("이 메모를 쓴 대화로 가기", "Go to the chat it was written in")) {
                    if !discussion.openTurn(chat, turn: note.message) { draft.message = L("그 대화는 이제 없어요.", "That chat is gone.") }
                }
            }
            icon("pencil", L("고치기", "Edit")) {
                draft.editing = note.id; draft.text = note.text; draft.kind = note.kind; draft.verified = note.verified; draft.message = nil
            }
            icon(note.pinned ? "pin.slash" : "pin", note.pinned ? L("고정 해제", "Unpin") : L("고정 (AI에게 늘 먼저 보여 줌)", "Pin (always shown to the AIs first)")) {
                report(memory.setPinned(note.id, !note.pinned, project: project))
            }
            if note.state == .archived {
                icon("tray.and.arrow.up", L("보관함에서 꺼내기", "Restore from the archive")) { report(memory.restore(note.id, project: project)) }
            } else {
                icon("archivebox", L("보관 (AI에게 안 보이고 검색에는 남음)", "Archive (hidden from the AIs, still searchable)")) {
                    report(memory.archive(note.id, project: project))
                }
            }
            icon("trash", L("완전 삭제…", "Delete for good…"), tint: .red) { confirmDelete(note) }
        }
    }

    private func icon(_ name: String, _ help: String, tint: Color = .secondary, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 12)).frame(width: 22, height: 22) }
            .buttonStyle(.plainHit).foregroundColor(tint).help(help)
    }

    private func editor(_ note: ProjectMemoryNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(L("메모 (한 줄)", "Note (one line)"), text: $draft.text).textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Picker("", selection: $draft.kind) {
                    ForEach(ProjectMemoryNote.Kind.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 160)
                Toggle(L("확인됨", "Checked"), isOn: $draft.verified).toggleStyle(.checkbox)
                Spacer(minLength: 6)
                Button(L("취소", "Cancel")) { draft.editing = nil }.controlSize(.small)
                Button(L("저장", "Save")) {
                    if report(memory.edit(note.id, text: draft.text, kind: draft.kind, verified: draft.verified, project: project)) { draft.editing = nil }
                }
                .controlSize(.small).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func confirmDelete(_ note: ProjectMemoryNote) {
        let alert = NSAlert()
        alert.messageText = L("이 메모를 완전히 삭제할까요?", "Delete this note for good?")
        alert.informativeText = L("메모와 변경 기록에서 이 내용이 지워지고 되돌릴 수 없어요. 같은 내용의 다른 메모도 함께 지워지고, AI나 정리 회의가 같은 내용을 다시 넣지 못해요.\n\n",
                                  "Its text is removed from the notes and the history and cannot be undone. Notes with the same text go too, and no AI or meeting cleanup can add it again.\n\n")
            + note.text
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("완전 삭제", "Delete"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        report(memory.delete(note.id, project: project))
    }

    // Shows why a change was refused; true when it was saved.
    @discardableResult private func report(_ outcome: ProjectMemoryStore.Outcome) -> Bool {
        if case .refused(let why) = outcome { draft.message = Self.refusal(why); return false }
        draft.message = nil
        return true
    }

    // The store explains refusals in English for the AIs; the user gets them in their language.
    static func refusal(_ why: String) -> String {
        let known: [(String, String, String)] = [
            ("later change", "뒤에 같은 메모를 바꾼 변경이 있어요. 그 변경부터 되돌리세요.", "A later change touched the same note: undo that one first."),
            ("already undone", "이미 되돌린 변경이에요.", "That change was already undone."),
            ("cannot be undone", "완전 삭제는 되돌릴 수 없어요.", "A delete for good cannot be undone."),
            ("deleted this note", "완전 삭제한 내용이 다시 생기게 돼서 되돌리지 않았어요.", "That would bring back a deleted text, so nothing was undone."),
            ("Nothing to undo", "되돌릴 것이 없어요. 메모가 이미 그때와 같아요.", "Nothing to undo: the notes are already as they were."),
            ("Too long", "메모가 너무 길어요 (\(ProjectMemoryStore.textLimit)자까지).", "Too long (at most \(ProjectMemoryStore.textLimit) characters)."),
            ("one line", "메모를 한 줄로 써 주세요.", "Write the note in one line."),
            ("could not be read", "이 Mac의 프로젝트 기억 파일을 읽을 수 없어 아무것도 저장하지 않았어요.", "Project memory on this Mac could not be read, so nothing was saved."),
            ("could not be saved", "프로젝트 기억을 저장하지 못했어요.", "Project memory could not be saved."),
        ]
        if let hit = known.first(where: { why.contains($0.0) }) { return L(hit.1, hit.2) }
        return L("바꾸지 못했어요: ", "Not changed: ") + why
    }

    // MARK: History

    // The newest changes first: who, when, what, with an undo for each change and for a whole meeting cleanup.
    private func changes(_ history: [ProjectMemoryChange], notes: [ProjectMemoryNote]) -> some View {
        let undone = ProjectMemoryStore.undone(history)
        let newest = Array(history.indices.reversed().prefix(Self.shownChanges))
        let firstOfBatch = Dictionary(newest.compactMap { i in history[i].batch.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(newest, id: \.self) { i in
                let change = history[i]
                if let batch = change.batch, firstOfBatch[batch] == i {
                    HStack(spacing: 6) {
                        Text(L("정리 회의 ", "Meeting cleanup ") + Self.day(change.at)).font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 6)
                        Button(L("이 정리 전체 되돌리기", "Undo this whole cleanup")) { report(memory.undo(batch: batch, project: project)) }
                            .controlSize(.small)
                    }
                    .padding(.top, 4)
                }
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.summary(change, notes: notes)).font(.system(size: 12)).lineLimit(2)
                            .strikethrough(undone.contains(i)).foregroundColor(undone.contains(i) ? .secondary : .primary)
                        Text(["#\(i + 1)", Self.who(change), Self.day(change.at)].joined(separator: " · ") + (undone.contains(i) ? L(" · 되돌림", " · Undone") : ""))
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .padding(.leading, change.batch == nil ? 0 : 12)
                    Spacer(minLength: 6)
                    if change.action != "delete" && !undone.contains(i) {
                        Button(L("되돌리기", "Undo")) { report(memory.undo([i], project: project)) }.controlSize(.small)
                    }
                }
            }
            if history.count > Self.shownChanges {
                Text(L("최근 \(Self.shownChanges)개만 보여요 (전체 \(history.count)개).", "Showing the newest \(Self.shownChanges) of \(history.count) changes."))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    static func who(_ change: ProjectMemoryChange) -> String {
        switch change.who {
        case ProjectMemoryChange.byUser: return L("나", "You")
        case ProjectMemoryChange.byMeeting: return L("회의", "Meeting")
        case let name?: return name
        case nil: return "AI"
        }
    }

    static func summary(_ change: ProjectMemoryChange, notes: [ProjectMemoryNote]) -> String {
        func text(_ n: ProjectMemoryNote) -> String { n.state == .deleted ? L("(완전 삭제된 내용)", "(deleted text)") : "\"" + n.text + "\"" }
        switch change.action {
        case "add": return L("추가: ", "Added: ") + text(change.note)
        case "replace": return L("대체: ", "Replaced: ") + (change.archived.map(text) ?? "") + " → " + text(change.note)
        case "edit": return L("고침: ", "Edited: ") + text(change.note)
        case "pin": return L("고정: ", "Pinned: ") + text(change.note)
        case "unpin": return L("고정 해제: ", "Unpinned: ") + text(change.note)
        case "archive": return L("보관: ", "Archived: ") + text(change.note)
        case "restore": return L("보관함에서 꺼냄: ", "Restored: ") + text(change.note)
        case "delete":
            let count = 1 + (change.others?.count ?? 0)
            return count > 1 ? L("완전 삭제 (메모 \(count)개)", "Deleted for good (\(count) notes)") : L("완전 삭제", "Deleted for good")
        case "undo":
            let lines = (change.undoes ?? []).map { "#\($0 + 1)" }.joined(separator: ", ")
            return L("되돌림 (\(lines)): ", "Undid (\(lines)): ") + change.notes.map(text).joined(separator: ", ")
        default: return change.action + ": " + text(change.note)
        }
    }
}
