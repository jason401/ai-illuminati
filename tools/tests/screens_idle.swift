import Cocoa
import SwiftUI
import AIAccounts
import AILocalization
import AIProjects
@testable import AIChat

// Screens that hold still must not redraw themselves. A TODO report card once set its @Published flag on every
// redraw (the same value), which redrew it again: the app sat at 100% CPU and stopped answering (2026-11-14).
// Hosted for 2 seconds with nothing changing, a card must use almost no CPU; with the loop the run loop never
// returned, so the stage's time limit catches that too.
@main struct ScreensIdle { @MainActor static func main() {
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
    testTodoGoalBoard(discussion)
}}

@MainActor private func testTodoGoalBoard(_ discussion: Discussion) {
    let previous = TodoStore.shared
    let store = TodoStore(url: URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("board-test.json"))
    TodoStore.shared = store
    defer { TodoStore.shared = previous; TodoDraft.shared.expandedGoals = [] }

    let list = TodoList(title: "Board", project: nil)
    var goal = TodoItem(listID: list.id, title: "Goal")
    goal.role = .goal
    let plain = TodoItem(listID: list.id, title: "Plain TODO")
    func part(_ title: String, _ role: TodoItem.Role, _ state: TodoItem.State) -> TodoItem {
        var item = TodoItem(listID: list.id, title: title)
        item.role = role; item.goal = goal.id; item.state = state
        return item
    }
    var pushed = part("Pushed Step", .step, .done)
    pushed.stepSHA = "step-a"
    var confirmed = part("Confirmed Milestone", .milestone, .done)
    var candidate = TodoItem.MilestoneCandidate(branch: "main", baseSHA: "base", candidateSHA: "candidate")
    candidate.recordReview(for: "candidate"); candidate.recordTest(for: "candidate")
    candidate.setPhase(.confirmation)
    confirmed.milestoneCandidate = candidate
    var local = part("Local Step", .step, .done)
    local.stepSHA = "step-b"
    let fix = part("Fix Step", .step, .running)
    let waiting = part("Waiting Step", .step, .draft)
    var verify = part("Next Milestone", .milestone, .ready)
    let parts = [pushed, confirmed, local, fix, waiting, verify]
    let progress = TodoGoalBoard(parts)
    precondition(progress.parts.map(\.status) == [.remote, .remote, .local, .running, .waiting, .waiting])
    precondition(progress.summary == L("Step 2/4 완료 · 다음 push까지 2 step", "2/4 steps complete · 2 steps until next push"))
    precondition(TodoGoalBoard([pushed, confirmed]).stepsUntilPush == nil)
    verify.state = .running
    candidate.setPhase(.review); verify.milestoneCandidate = candidate
    precondition(TodoGoalBoard([local, verify]).parts.last?.status == .reviewing)
    candidate.setPhase(.test); verify.milestoneCandidate = candidate
    let testing = TodoGoalBoard([local, verify])
    precondition(testing.parts.last?.status == .testing && testing.stepsUntilPush == 0)
    candidate.setPhase(.push); verify.milestoneCandidate = candidate
    precondition(TodoGoalBoard([local, verify]).parts.last?.status == .pushing)
    precondition(TodoGoalBoard([part("Manual Done", .milestone, .done)]).parts.first?.status == nil)
    let manual = part("Manual Done", .step, .done)
    let cancelled = part("Cancelled Step", .step, .cancelled)
    let needsYou = part("Question", .step, .needsYou)
    let adjusted = TodoGoalBoard([local, manual, cancelled, needsYou, verify])
    precondition(adjusted.summary == L("Step 2/3 완료 · 다음 push까지 1 step · 확인 필요", "2/3 steps complete · 1 step until next push · Needs your attention"))
    let review = part("Review result", .milestone, .review)
    let attention = TodoGoalBoard([local, needsYou, review, verify])
    precondition(attention.visibleParts(expanded: false).map(\.id) == [needsYou.id, review.id])

    func height(_ list: TodoList) -> CGFloat {
        let view = TodoBoardView(discussion: discussion).listView(list).frame(width: 700)
        return NSHostingView(rootView: view).fittingSize.height
    }
    let plainList = TodoList(title: "Plain board", project: nil)
    let onlyPlain = TodoItem(listID: plainList.id, title: "Plain TODO")
    try! store.update { data in
        data.lists = [list, plainList]
        data.items = [goal, plain, onlyPlain]
    }
    let plainHeight = height(plainList)
    let unplannedHeight = height(list)

    try! store.update { $0.items += parts }
    try! store.move(plain.id, before: nil)
    let data = store.snapshot
    let groups = TodoGoalBoard.groups(data, list: list.id)
    let ordered = data.ordered(list.id)
    let rows = TodoGoalBoard.rows(ordered, groups: groups, showDone: false)
    precondition(rows.map(\.id) == [goal.id, plain.id])
    let numbers = TodoGoalBoard.numbers(rows, groups: groups)
    precondition(numbers[goal.id] == "1" && numbers[plain.id] == "2" && numbers[waiting.id] == "1.5")
    precondition(groups[goal.id]?.parts.map(\.id) == parts.map(\.id))
    var finishedGoal = goal
    finishedGoal.state = .done
    let finished = [finishedGoal, plain]
    let finishedGroup = [goal.id: TodoGoalBoard([pushed, confirmed])]
    precondition(TodoGoalBoard.rows(finished, groups: finishedGroup, showDone: false).map(\.id) == [plain.id])
    precondition(TodoGoalBoard.rows(finished, groups: finishedGroup, showDone: true).map(\.id) == [goal.id, plain.id])
    let collapsed = height(list)
    precondition(collapsed > unplannedHeight, "the collapsed Goal renders its summary")
    precondition(plainHeight > 0 && height(plainList) == plainHeight, "plain TODO layout stays the same")
    try! store.move(goal.id, before: nil)
    precondition(store.snapshot.ordered(list.id).map(\.id) == [plain.id, goal.id] + ordered.filter { $0.goal == goal.id }.map(\.id))

    TodoDraft.shared.expandedGoals.insert(goal.id)
    precondition(height(list) > collapsed + 100, "expanding the Goal renders its plan")
    TodoDraft.shared.expandedGoals.remove(goal.id)
    try! store.update { $0.items.append(review) }
    precondition(height(list) > collapsed + 22, "the collapsed Goal renders the action row and review card")
    print("PASS: TODO board Goal groups (collapsed, expanded, phase labels and progress)")
}
