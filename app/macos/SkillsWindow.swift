import SwiftUI
import AppKit
import AILocalization
import AIProjects
import AIChat

// Settings > Skills & Memory > Manage skills: every app skill (global ones and each project's), so skills a meeting or
// an AI added can be seen and turned off. A skill turned off leaves the [Skills] list the AIs get (SkillLink).
struct SkillProject: Identifiable, Equatable {
    let id: String     // SidebarProjects.key, the key ProjectSkillStore uses
    let name: String
}

enum SkillsFilter: Hashable { case all, global, project(String) }

struct SkillRowItem: Identifiable, Equatable {
    let project: SkillProject?   // nil: global
    let skill: SkillSummary
    var id: String { (project?.id ?? "") + "\n" + skill.name }
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
        // A fresh view each time: skills edited on disk or by an AI meanwhile show up.
        let view = SkillsView(projects: { SkillsCatalog.projects(discussion) }, close: { [weak self] in self?.window?.close() })
            .frame(minWidth: 480, idealWidth: 600, minHeight: 360, idealHeight: 520)
        if let window, let host = window.contentViewController as? NSHostingController<AnyView> {
            host.rootView = AnyView(view)
        } else {
            let w = NSWindow(contentViewController: NSHostingController(rootView: AnyView(view)))
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.title = L("스킬", "Skills")
            w.setContentSize(NSSize(width: 600, height: 520))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class SkillsDraft: ObservableObject {
    @Published var filter = SkillsFilter.all
    @Published var error: String?   // why the last change was not saved
}

struct SkillsView: View {
    let projects: () -> [SkillProject]
    let close: () -> Void
    @ObservedObject private var global = SkillStore.shared
    @ObservedObject private var scoped = ProjectSkillStore.shared
    @StateObject private var draft = SkillsDraft()

    var body: some View {
        let _ = (global.revision, scoped.revision)
        let known = projects()
        let all = SkillsCatalog.rows(.all, projects: known)
        let rows = SkillsCatalog.rows(draft.filter, projects: known)
        // Only projects that have skills get a filter entry.
        let withSkills = known.filter { p in all.contains { $0.project?.id == p.id } }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(L("모두 켜기", "Turn all on")) { draft.error = SkillsCatalog.setAll(true, filter: draft.filter, projects: known) }
                    .disabled(rows.allSatisfy(\.skill.record.enabled))
                Button(L("모두 끄기", "Turn all off")) { draft.error = SkillsCatalog.setAll(false, filter: draft.filter, projects: known) }
                    .disabled(rows.allSatisfy { !$0.skill.record.enabled })
                Spacer()
                Picker(L("보기", "Show"), selection: $draft.filter) {
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
            if rows.isEmpty {
                Text(all.isEmpty
                     ? L("아직 스킬이 없어요. 채팅에서 \"스킬로 만들어줘\"라고 하면 여기에 생겨요.", "No skills yet. Ask a chat to \"make a skill\" and it shows up here.")
                     : L("이 범위에는 스킬이 없어요.", "No skills here."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            } else {
                List(rows) { row in
                    SkillRow(row: row) { on in draft.error = SkillsCatalog.set(row, on) }
                }
                .listStyle(.inset)
            }
            HStack {
                Text(L("스킬 \(all.count)개 (켜짐 \(all.filter(\.skill.record.enabled).count))",
                       "\(all.count) skills (\(all.filter(\.skill.record.enabled).count) on)"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(L("완료", "Done"), action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
    }
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
