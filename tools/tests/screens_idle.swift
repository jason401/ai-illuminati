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
}}
