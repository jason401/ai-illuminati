import SwiftUI
import AppKit
import AILocalization
import AIProjects
import AIChat

// Settings > Skills & Memory > Manage skills: every app skill (global ones and each project's), so skills a meeting or
// an AI added can be seen, turned off, edited and deleted. A skill turned off leaves the [Skills] list the AIs get
// (SkillLink); one the user saves here is locked (🔒), so AIs and meetings need approval to change it.
struct SkillProject: Identifiable, Equatable {
    let id: String     // SidebarProjects.key, the key ProjectSkillStore uses
    let name: String
}

enum SkillsFilter: Hashable { case all, global, project(String) }

struct SkillRowItem: Identifiable, Equatable {
    let project: SkillProject?   // nil: global
    let skill: SkillSummary
    var id: String { Self.id(project, skill.name) }
    static func id(_ project: SkillProject?, _ name: String) -> String { (project?.id ?? "") + "\n" + name }
}

// The last delete, offered for Undo at the bottom of the window for a few seconds.
struct RemovedSkill: Equatable {
    let project: SkillProject?
    let name: String
    let change: UUID   // the delete's history entry
}

enum SkillsCatalog {
    static func projects(_ discussion: Discussion) -> [SkillProject] {
        SidebarProjects.group(discussion.listedConversations.filter(\.hasContent), todo: TodoStore.shared.snapshot,
                              pinned: [], names: ProjectInfoStore.shared.names)
            .projects.map { SkillProject(id: $0.id, name: $0.name) }
    }

    // Global skills first, then projects by name; each by skill name.
    static func rows(_ filter: SkillsFilter, projects: [SkillProject]) -> [SkillRowItem] {
        var out: [SkillRowItem] = []
        if filter == .all || filter == .global {
            out += SkillStore.shared.list().map { SkillRowItem(project: nil, skill: $0) }
        }
        for project in projects.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            if filter == .all || filter == .project(project.id) {
                out += ProjectSkillStore.shared.list(project.id).map { SkillRowItem(project: project, skill: $0) }
            }
        }
        return out
    }

    static func shows(_ row: SkillRowItem, _ filter: SkillsFilter) -> Bool {
        switch filter {
        case .all: return true
        case .global: return row.project == nil
        case .project(let id): return row.project?.id == id
        }
    }

    // nil when saved; otherwise why not.
    static func set(_ row: SkillRowItem, _ on: Bool) -> String? {
        let outcome = row.project.map { ProjectSkillStore.shared.setEnabled(row.skill.name, on, project: $0.id) }
            ?? SkillStore.shared.setEnabled(row.skill.name, on)
        return failure(outcome)
    }

    // Turns on or off every skill the filter shows, each store in one change (one Undo step per store).
    static func setAll(_ on: Bool, filter: SkillsFilter, projects: [SkillProject]) -> String? {
        var failures: [String] = []
        if filter == .all || filter == .global, !SkillStore.shared.list().isEmpty,
           let why = failure(SkillStore.shared.setAllEnabled(on)) { failures.append(why) }
        for project in projects where filter == .all || filter == .project(project.id) {
            guard !ProjectSkillStore.shared.list(project.id).isEmpty else { continue }
            if let why = failure(ProjectSkillStore.shared.setAllEnabled(on, project: project.id)) { failures.append(project.name + ": " + why) }
        }
        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    static func detail(_ row: SkillRowItem) -> SkillDetail? {
        if let project = row.project { return ProjectSkillStore.shared.read(row.skill.name, project: project.id) }
        return SkillStore.shared.read(row.skill.name)
    }

    // Every history entry that touched this skill (by UUID, so renames stay), oldest first.
    static func changes(_ row: SkillRowItem) -> [SkillHistoryEntry] {
        let id = row.skill.record.id
        return (row.project.map { ProjectSkillStore.shared.history($0.id) } ?? SkillStore.shared.history()).filter { entry in
            entry.skillID == id || entry.items.contains { $0.before?.record.id == id || $0.after?.record.id == id }
        }
    }

    // The skill as it is now when it changed after the editor loaded `loaded`; nil when unchanged.
    static func changed(_ row: SkillRowItem, since loaded: SkillDetail) -> SkillDetail? {
        guard let now = detail(row), now.document != loaded.document || now.record.contentHash != loaded.record.contentHash else { return nil }
        return now
    }

    static func markSeen(_ row: SkillRowItem) {
        guard row.skill.record.isNew else { return }
        if let project = row.project { ProjectSkillStore.shared.markSeen(row.skill.name, project: project.id) } else { SkillStore.shared.markSeen(row.skill.name) }
    }

    static func file(_ row: SkillRowItem) -> URL {
        (row.project.map { ProjectSkillStore.folder($0.id) } ?? SkillStore.folder)
            .appendingPathComponent(row.skill.name, isDirectory: true).appendingPathComponent("SKILL.md")
    }

    // Saves the editor as the user's: locked, no longer new. nil when saved; otherwise why not.
    static func save(_ row: SkillRowItem, name: String, description: String, body: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        func put(_ name: String) -> SkillOutcome {
            if let project = row.project {
                return ProjectSkillStore.shared.save(name: name, description: description, body: body, by: .user, project: project.id, id: row.skill.record.id)
            }
            return SkillStore.shared.save(name: name, description: description, body: body, by: .user, id: row.skill.record.id)
        }
        // A file put in or edited outside the app is taken in under its own name first, so the rename moves its
        // folder instead of leaving a copy behind. The new name is checked first, and if the rename still fails the
        // take-in is undone, so a refused rename leaves the file as it was.
        guard name != row.skill.name, row.skill.externallyModified, SkillDocument.isValidSlug(name) else { return failure(put(name)) }
        let folder = file(row).deletingLastPathComponent().deletingLastPathComponent()
        guard (row.project.map { ProjectSkillStore.shared.list($0.id) } ?? SkillStore.shared.list()).allSatisfy({ $0.name != name }),
              !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) else {
            return L("같은 이름의 스킬(\(name))이나 폴더가 이미 있어요.", "A skill or folder named \(name) already exists.")
        }
        if let why = failure(put(row.skill.name)) { return why }
        guard let why = failure(put(name)) else { return nil }
        let history = row.project.map { ProjectSkillStore.shared.history($0.id) } ?? SkillStore.shared.history()
        if let takeIn = history.last(where: { $0.action == .update && $0.skillID == row.skill.record.id })?.id {
            _ = row.project.map { ProjectSkillStore.shared.undo(project: $0.id, change: takeIn) } ?? SkillStore.shared.undo(change: takeIn)
        }
        return why
    }

    // Deletes the skill (skills.json keeps a tombstone) and returns the change Undo takes back.
    static func delete(_ row: SkillRowItem) -> (removed: RemovedSkill?, error: String?) {
        let outcome = row.project.map { ProjectSkillStore.shared.delete(row.skill.name, project: $0.id) } ?? SkillStore.shared.delete(row.skill.name)
        guard case .deleted(let tombstone) = outcome else { return (nil, failure(outcome) ?? L("스킬을 지우지 못했어요.", "Could not delete the skill.")) }
        let history = row.project.map { ProjectSkillStore.shared.history($0.id) } ?? SkillStore.shared.history()
        let change = history.last { $0.action == .delete && $0.skillID == tombstone.id }?.id
        return (change.map { RemovedSkill(project: row.project, name: row.skill.name, change: $0) }, nil)
    }

    // Undoes exactly that delete, not whatever changed last.
    static func undo(_ removed: RemovedSkill) -> String? {
        failure(removed.project.map { ProjectSkillStore.shared.undo(project: $0.id, change: removed.change) }
                ?? SkillStore.shared.undo(change: removed.change))
    }

    // Summary line for the latest review banner; marks 24h fallback / single-company reviews as "부분 검토".
    static func reviewSummary(_ record: KnowledgeReviewRecord) -> String {
        let head = record.partial ? L("최근 검토 · 부분 검토", "Last review · Partial review") : L("최근 검토", "Last review")
        return head + " · \(SkillDetailPane.day(record.at))"
            + L(" · 적용 \(record.applied)개", " · \(record.applied) applied")
            + (record.waiting == 0 ? "" : L(" · 승인 대기 \(record.waiting)개", " · \(record.waiting) awaiting approval"))
    }

    private static func failure(_ outcome: SkillOutcome) -> String? {
        switch outcome {
        case .refused(let why), .needsApproval(_, let why): return why
        default: return nil
        }
    }
}

final class SkillsWindow {
    static let shared = SkillsWindow()
    private var window: NSWindow?

    func show(discussion: Discussion) {
        // A fresh view each time (new identity, so the filter and last error start over): skills edited on disk or by
        // an AI meanwhile show up.
        let view = SkillsView(projects: { SkillsCatalog.projects(discussion) }, close: { [weak self] in self?.window?.close() },
                              review: { KnowledgeReviewLink.run(in: discussion, done: $0) })
            .id(UUID())
            .frame(minWidth: 720, idealWidth: 880, minHeight: 420, idealHeight: 580)
        if let window, let host = window.contentViewController as? NSHostingController<AnyView> {
            host.rootView = AnyView(view)
        } else {
            let w = NSWindow(contentViewController: NSHostingController(rootView: AnyView(view)))
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.title = L("스킬", "Skills")
            w.setContentSize(NSSize(width: 880, height: 580))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// The Settings card's "N skills (M on)", kept between redraws so the card reads the skill files only when the stores
// change or the user comes back to a window (skills edited on disk, projects linked or removed meanwhile).
final class SkillCounts: ObservableObject {
    @Published private(set) var total = 0
    @Published private(set) var on = 0

    func refresh(_ discussion: Discussion) {
        let all = SkillsCatalog.rows(.all, projects: SkillsCatalog.projects(discussion))
        let enabled = all.filter(\.skill.record.enabled).count
        if total != all.count { total = all.count }
        if on != enabled { on = enabled }
    }
}

final class SkillsDraft: ObservableObject {
    @Published var filter = SkillsFilter.all
    @Published var error: String?   // why the last change was not saved
    @Published var selected: String?   // SkillRowItem.id shown on the right
    @Published var loaded: SkillDetail?   // what the editor started from
    @Published var name = ""
    @Published var description = ""
    @Published var body = ""
    @Published var removed: RemovedSkill?
    @Published var note: String?    // what [Review now] or a review's Undo did

    init(selected: String? = nil) { self.selected = selected }

    var edited: Bool {
        guard let loaded else { return false }
        return name != loaded.name || description != loaded.document.description || body != loaded.document.body
    }

    func load(_ detail: SkillDetail?) {
        loaded = detail
        name = detail?.name ?? ""; description = detail?.document.description ?? ""; body = detail?.document.body ?? ""
    }

    func offerUndo(_ removed: RemovedSkill) {
        self.removed = removed
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.removed == removed { self?.removed = nil }
        }
    }
}

struct SkillsView: View {
    let projects: () -> [SkillProject]
    let close: () -> Void
    let review: ((@escaping (String) -> Void) -> Bool)?    // starts a review; its argument gets the review's end line
    @ObservedObject private var global = SkillStore.shared
    @ObservedObject private var scoped = ProjectSkillStore.shared
    @StateObject private var draft: SkillsDraft

    init(projects: @escaping () -> [SkillProject], close: @escaping () -> Void, selected: String? = nil,
         review: ((@escaping (String) -> Void) -> Bool)? = nil) {
        self.projects = projects
        self.close = close
        self.review = review
        _draft = StateObject(wrappedValue: SkillsDraft(selected: selected))
    }

    var body: some View {
        let _ = (global.revision, scoped.revision)
        let known = projects()
        let all = SkillsCatalog.rows(.all, projects: known)
        // Only projects that have skills get a filter entry; a picked project whose last skill went away shows All.
        let withSkills = known.filter { p in all.contains { $0.project?.id == p.id } }
        let filter: SkillsFilter = {
            if case .project(let id) = draft.filter, !withSkills.contains(where: { $0.id == id }) { return .all }
            return draft.filter
        }()
        let rows = all.filter { SkillsCatalog.shows($0, filter) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(L("모두 켜기", "Turn all on")) { draft.error = SkillsCatalog.setAll(true, filter: filter, projects: known) }
                    .disabled(rows.allSatisfy(\.skill.record.enabled))
                Button(L("모두 끄기", "Turn all off")) { draft.error = SkillsCatalog.setAll(false, filter: filter, projects: known) }
                    .disabled(rows.allSatisfy { !$0.skill.record.enabled })
                if let review {
                    Button(L("지금 검토", "Review now")) {
                        // The end line replaces "reviewing" and redraws the window, also when only memory or the
                        // inbox changed (the skill stores are all it watches otherwise).
                        draft.error = nil
                        draft.note = review { [weak draft] line in draft?.note = line }
                            ? L("스킬·기억 후보를 회의에서 검토하고 있어요. 끝나면 바로 적용돼요.", "A meeting is reviewing the skill and memory candidates; its decisions apply when it ends.")
                            : !KnowledgeReviewLink.isReviewHost()
                            ? L("연동 중에는 담당 Mac만 검토해요. 이 Mac의 후보는 담당 Mac의 다음 검토에 올라가요.", "With sync on, only the review Mac holds reviews; this Mac's candidates go to its next review.")
                            : L("검토할 후보가 없거나, 회의할 AI가 둘보다 적거나, 이미 검토 중이에요.", "No candidates to review, fewer than two AIs to meet, or a review is already running.")
                    }
                    .help(L("후보함의 스킬·기억 후보를 AI 회의가 추가·수정·버림으로 정해요.", "AIs meet to add, merge into existing ones, or drop the proposed skills and memories."))
                }
                Spacer()
                Picker(L("보기", "Show"), selection: Binding(get: { filter }, set: { draft.filter = $0 })) {
                    Text(L("전체", "All")).tag(SkillsFilter.all)
                    Text(L("전역", "Global")).tag(SkillsFilter.global)
                    if !withSkills.isEmpty { Divider() }
                    ForEach(withSkills) { Text($0.name).tag(SkillsFilter.project($0.id)) }
                }
                .frame(maxWidth: 220)
            }
            Text(L("꺼진 스킬은 AI에게 보내는 [Skills] 목록에서 빠져요. 🔒는 사용자가 저장한 스킬로, AI나 회의가 바꾸려면 승인이 필요해요.",
                   "Skills turned off leave the [Skills] list the AIs get. 🔒 marks skills you saved: AIs and meetings need your approval to change them."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = draft.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let note = draft.note {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let last = KnowledgeReview.records().last, last.undoneAt == nil, last.applied + last.waiting > 0 || last.partial {
                HStack(spacing: 8) {
                    Text(SkillsCatalog.reviewSummary(last))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if last.applied > 0 {
                        Button(L("이 검토 되돌리기", "Undo this review")) {
                            let failure = KnowledgeReview.undo(last.id)
                            draft.error = failure
                            draft.note = failure == nil ? L("검토 한 번을 통째로 되돌렸어요.", "The whole review was undone.") : nil
                            open(draft.selected)
                        }
                        .controlSize(.small)
                    }
                }
            }
            if rows.isEmpty {
                Text(all.isEmpty
                     ? L("아직 스킬이 없어요. 채팅에서 \"스킬로 만들어줘\"라고 하면 여기에 생겨요.", "No skills yet. Ask a chat to \"make a skill\" and it shows up here.")
                     : L("이 범위에는 스킬이 없어요.", "No skills here."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            } else {
                HStack(alignment: .top, spacing: 10) {
                    List(rows, selection: $draft.selected) { row in
                        SkillRow(row: row) { on in draft.error = SkillsCatalog.set(row, on) }.tag(row.id)
                    }
                    .listStyle(.inset)
                    .frame(minWidth: 240, idealWidth: 290, maxWidth: 330)
                    if let row = rows.first(where: { $0.id == draft.selected }), draft.loaded != nil {
                        SkillDetailPane(row: row, draft: draft, open: open)
                    } else {
                        Text(L("스킬을 고르면 여기에서 보고 고치고 지울 수 있어요.", "Pick a skill to see, edit or delete it here."))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            HStack {
                if let removed = draft.removed {
                    Text(L("‘\(removed.name)’ 지움", "Deleted ‘\(removed.name)’")).font(.system(size: 11))
                    Button(L("취소", "Undo")) {
                        draft.error = SkillsCatalog.undo(removed)
                        draft.removed = nil
                        if draft.error == nil { draft.selected = SkillRowItem.id(removed.project, removed.name) }
                    }
                    .controlSize(.small)
                } else {
                    Text(L("스킬 \(all.count)개 (켜짐 \(all.filter(\.skill.record.enabled).count))",
                           "\(all.count) skills (\(all.filter(\.skill.record.enabled).count) on)"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button(L("완료", "Done"), action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { open(draft.selected) }
        .onChange(of: draft.selected) { open($0) }
    }

    // Loads the picked skill into the editor; the first look clears its "new" badge.
    private func open(_ id: String?) {
        guard let id, let row = SkillsCatalog.rows(.all, projects: projects()).first(where: { $0.id == id }) else { draft.load(nil); return }
        draft.load(SkillsCatalog.detail(row))
        SkillsCatalog.markSeen(row)
    }
}

// The picked skill: name, description and body to edit, who made it and when, its latest changes, and
// Save / Delete / Show in Finder.
private struct SkillDetailPane: View {
    let row: SkillRowItem
    @ObservedObject var draft: SkillsDraft
    let open: (String?) -> Void

    var body: some View {
        let changes = SkillsCatalog.changes(row)
        let record = row.skill.record
        VStack(alignment: .leading, spacing: 5) {
            label(L("이름", "Name"))
            TextField("", text: $draft.name).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
            label(L("설명", "Description"))
            TextField("", text: $draft.description, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3).font(.system(size: 12))
            label(L("본문", "Body"))
            TextEditor(text: $draft.body).font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
            Text(made(record, changes)).font(.system(size: 11)).foregroundStyle(.secondary)
            if row.skill.externallyModified {
                Text(L("앱 밖에서 고친 파일이라 🔒 잠겼어요.", "Edited outside the app, so it is locked 🔒."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !changes.isEmpty {
                label(L("최근 변경", "Latest changes"))
                ForEach(changes.suffix(4).reversed()) { entry in
                    Text([Self.action(entry.action), Self.who(entry.by, entry.actor), Self.day(entry.at)].joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                Button(L("저장", "Save"), action: save).disabled(!draft.edited)
                    .help(L("내가 저장한 스킬은 🔒 잠겨서 AI나 회의가 바꾸려면 승인이 필요해요.", "Skills you save are locked 🔒: AIs and meetings need your approval to change them."))
                Button(L("되돌리기", "Revert")) { draft.load(draft.loaded) }.disabled(!draft.edited)
                Spacer()
                Button(L("Finder에서 보기", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([SkillsCatalog.file(row)]) }
                Button(L("삭제…", "Delete…"), role: .destructive, action: delete)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(_ text: String) -> some View { Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }

    private func save() {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Changed by an AI or on disk since the editor opened: say so once and keep the edits, so saving does not
        // silently put back the old text in the fields the user did not touch. Saving again overwrites.
        if let loaded = draft.loaded, let now = SkillsCatalog.changed(row, since: loaded) {
            draft.loaded = now
            draft.error = L("열어 둔 뒤 이 스킬이 바뀌었어요. [되돌리기]로 새 내용을 불러오거나, 다시 [저장]하면 지금 편집한 내용으로 덮어써요.",
                            "This skill changed after you opened it. [Revert] loads the new version; [Save] again overwrites it with your edits.")
            return
        }
        draft.error = SkillsCatalog.save(row, name: name, description: draft.description, body: draft.body)
        guard draft.error == nil else { return }
        let id = SkillRowItem.id(row.project, name)
        if draft.selected == id { open(id) } else { draft.selected = id }
    }

    private func delete() {
        let alert = NSAlert()
        alert.messageText = L("‘\(row.skill.name)’ 스킬을 지울까요?", "Delete the skill ‘\(row.skill.name)’?")
        alert.informativeText = L("AI에게 더 이상 보내지 않아요. 지운 직후에는 창 아래 [취소]로 되돌릴 수 있어요.",
                                  "The AIs no longer get it. Right after, [Undo] at the bottom of the window brings it back.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("삭제", "Delete"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let result = SkillsCatalog.delete(row)
        draft.error = result.error
        guard result.error == nil else { return }
        draft.selected = nil
        if let removed = result.removed { draft.offerUndo(removed) }
    }

    private func made(_ record: SkillRecord, _ changes: [SkillHistoryEntry]) -> String {
        let by = L("만든 주체: ", "Made by: ") + Self.who(record.createdBy, changes.first { $0.action == .add }?.actor)
        if let added = changes.first(where: { $0.action == .add }) {
            return by + " · " + Self.day(added.at) + (changes.count > 1 ? L(" · 최근 변경 ", " · last changed ") + Self.day(record.updatedAt) : "")
        }
        return by + " · " + L("앱 밖에서 넣은 파일 · ", "a file put in outside the app · ") + Self.day(record.updatedAt)
    }

    static func who(_ by: SkillAuthor, _ actor: String?) -> String {
        switch by {
        case .user: return L("사용자", "You")
        case .ai: return actor ?? "AI"
        case .meeting: return L("회의", "Meeting") + (actor.map { " (\($0))" } ?? "")
        }
    }

    static func action(_ action: SkillAction) -> String {
        switch action {
        case .add: return L("만듦", "Created")
        case .update: return L("수정", "Edited")
        case .delete: return L("지움", "Deleted")
        case .enable: return L("켬", "Turned on")
        case .disable: return L("끔", "Turned off")
        case .setAllEnabled: return L("모두 켜기/끄기", "Turn all on/off")
        case .undo: return L("되돌림", "Undone")
        }
    }

    static func day(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
}

private struct SkillRow: View {
    let row: SkillRowItem
    let set: (Bool) -> Void

    var body: some View {
        let record = row.skill.record
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(row.skill.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if record.userLocked {
                        Text("🔒").font(.system(size: 10)).help(L("사용자가 저장한 스킬: AI나 회의가 바꾸려면 승인이 필요해요.", "Saved by you: AIs and meetings need your approval to change it."))
                    }
                    if record.isNew {
                        Text("new").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                            .help(L("새로 들어온 스킬이에요.", "Newly added skill."))
                    }
                }
                Text(row.skill.description.isEmpty ? L("설명 없음", "No description")
                     : row.skill.description.split(whereSeparator: \.isNewline).joined(separator: " "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .help(row.skill.description)
                Text(row.project?.name ?? L("전역", "Global"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Toggle(L("켜기", "On"), isOn: Binding(get: { record.enabled }, set: set))
                .labelsHidden().toggleStyle(.switch)
                .help(record.enabled ? L("켜짐: AI가 이 스킬을 봐요.", "On: the AIs see this skill.")
                                     : L("꺼짐: AI에게 보내지 않아요.", "Off: not sent to the AIs."))
        }
        .padding(.vertical, 2)
    }
}
