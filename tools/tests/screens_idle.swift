import Cocoa
import SwiftUI
import AIAccounts
import AIProjects
@testable import AIChat

// Screens that hold still must not redraw themselves. A TODO report card once set its @Published flag on every
// redraw (the same value), which redrew it again: the app sat at 100% CPU and stopped answering (2026-11-14).
// Hosted for 2 seconds with nothing changing, a card must use almost no CPU; with the loop the run loop never
// returned, so the stage's time limit catches that too.
@main struct ScreensIdle { static func main() {
    let list = UUID(), other = UUID()
    var ordered: [TodoItem] = []
    for n in 0..<25 {
        var item = TodoItem(listID: list, title: "Finished \(n)")
        item.state = n % 2 == 0 ? .done : .cancelled
        item.updatedAt = Date(timeIntervalSince1970: Double(n))
        item.finishedAt = n == 24 ? nil : item.updatedAt
        ordered.append(item)
    }
    // A newer edit must not override an existing completion time.
    ordered[0].updatedAt = Date(timeIntervalSince1970: 1000)
    let active = [TodoItem.State.draft, .ready, .running, .review, .needsYou].map { state -> TodoItem in
        var item = TodoItem(listID: list, title: "Active"); item.state = state; return item
    }
    ordered.insert(contentsOf: active, at: 12)
    func check(_ limit: Int, count: Int, hidden: Int) {
        let shown = TodoDraft.shownRows(ordered, showDone: true, doneLimit: limit)
        let expected = ordered.filter { active.map(\.id).contains($0.id) || ($0.finishedAt ?? $0.updatedAt) >= Date(timeIntervalSince1970: Double(25 - count)) && $0.id != ordered[0].id }
        precondition(shown.rows.map(\.id) == expected.map(\.id) && shown.hiddenDone == hidden)
    }
    check(10, count: 10, hidden: 15)
    check(20, count: 20, hidden: 5)
    let all = TodoDraft.shownRows(ordered, showDone: true, doneLimit: 30)
    precondition(all.rows.map(\.id) == ordered.map(\.id) && all.hiddenDone == 0)
    precondition(TodoDraft.shownRows(ordered, showDone: false, doneLimit: 30).rows.map(\.id) == active.map(\.id))
    precondition(TodoDraft.shownRows([], showDone: true, doneLimit: 10).hiddenDone == 0)
    let tied = Array(ordered.prefix(2)).map { item -> TodoItem in
        var copy = item; copy.finishedAt = Date(timeIntervalSince1970: 1); return copy
    }
    precondition(TodoDraft.shownRows(tied, showDone: true, doneLimit: 1).rows.first?.id == tied.first?.id)
    let draft = TodoDraft()
    draft.showDone = true; draft.showMoreDone(list); draft.showMoreDone(list)
    precondition(draft.doneLimit(list) == 30 && draft.doneLimit(other) == 10)
    draft.showLessDone(list); precondition(draft.doneLimit(list) == 10)
    draft.showMoreDone(list); draft.showDone = false; draft.showDone = true
    precondition(draft.doneLimits.isEmpty && draft.doneLimit(list) == 10)
    print("PASS: TODO finished rows page by recency and preserve board order")
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    func cpu() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 }
    let discussion = Discussion(model: AppModel())
    for state in [TodoItem.State.review, .needsYou] {
        var item = TodoItem(listID: UUID(), title: "Check")
        item.state = state
        item.result = "Done"
        let host = NSHostingView(rootView: TodoCard(item: item, discussion: discussion).frame(width: 700, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let start = cpu()
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        let used = cpu() - start
        guard used < 0.5 else { print("FAIL: a TODO card (\(state)) redraws itself while nothing changes (\(used) s CPU in 2 s)"); exit(1) }
        window.contentView = nil
    }
    print("PASS: TODO cards stay still when nothing changes")

    // Settings > Skills & Memory > Manage skills (SkillsWindow.swift): the window shows and holds still, its toggle and
    // turn-all buttons reach the stores, and a skill turned off leaves the [Skills] list the AIs get.
    let project = SkillProject(id: "/tmp/skills-window-project", name: "Demo")
    func saved(_ outcome: SkillOutcome) -> Bool { if case .saved = outcome { return true }; return false }
    precondition(saved(SkillStore.shared.save(name: "tidy-notes", description: "Tidy meeting notes", body: "Steps", by: .user)))
    precondition(saved(SkillStore.shared.save(name: "ai-helper", description: "Added by an AI", body: "Steps", by: .ai)))
    precondition(saved(ProjectSkillStore.shared.save(name: "build-check", description: "Build first", body: "Steps", by: .meeting, project: project.id)))
    let skillsHost = NSHostingView(rootView: SkillsView(projects: { [project] }, close: {}).frame(width: 600, height: 500))
    let skillsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
    skillsWindow.contentView = skillsHost
    func settle() { for _ in 0..<5 { skillsHost.layoutSubtreeIfNeeded(); skillsWindow.displayIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
    settle()
    let skillsStart = cpu()
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    guard cpu() - skillsStart < 0.5 else { print("FAIL: the skills window redraws itself while nothing changes"); exit(1) }
    func enabled(_ filter: SkillsFilter) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: SkillsCatalog.rows(filter, projects: [project]).map { ($0.skill.name, $0.skill.record.enabled) })
    }
    func listed() -> String { SkillLink.rule(project: project.id, question: "", local: false) }
    precondition(enabled(.all) == ["tidy-notes": true, "ai-helper": true, "build-check": true])
    precondition(Set(enabled(.global).keys) == ["tidy-notes", "ai-helper"] && Set(enabled(.project(project.id)).keys) == ["build-check"])
    let rows = SkillsCatalog.rows(.all, projects: [project])
    precondition(rows.first { $0.skill.name == "tidy-notes" }?.skill.record.userLocked == true)
    precondition(rows.first { $0.skill.name == "build-check" }?.project == project)
    precondition(SkillsCatalog.set(rows.first { $0.skill.name == "tidy-notes" }!, false) == nil)
    precondition(enabled(.all) == ["tidy-notes": false, "ai-helper": true, "build-check": true])
    precondition(!listed().contains("tidy-notes") && listed().contains("ai-helper") && listed().contains("build-check"))
    precondition(SkillsCatalog.setAll(false, filter: .project(project.id), projects: [project]) == nil)
    precondition(enabled(.all) == ["tidy-notes": false, "ai-helper": true, "build-check": false])
    precondition(SkillsCatalog.setAll(true, filter: .all, projects: [project]) == nil)
    precondition(enabled(.all).values.allSatisfy { $0 })
    precondition(SkillsCatalog.setAll(false, filter: .global, projects: [project]) == nil)
    precondition(enabled(.all) == ["tidy-notes": false, "ai-helper": false, "build-check": true])
    precondition(!listed().contains("ai-helper") && listed().contains("build-check"))
    settle()   // the window redraws with the stores' changes
    skillsWindow.contentView = nil
    print("PASS: the skills window shows every skill, and its toggles and turn-all buttons reach the stores")
}}
