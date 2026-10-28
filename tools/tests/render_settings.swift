import Cocoa
import SwiftUI

// Render only fixture views to bitmaps. No screen capture, UI control, real accounts or AI calls.
@main struct SettingsPreview {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in ["en", "ko"] {
            UserDefaults.standard.setVolatileDomain(["appLanguage": language], forName: UserDefaults.argumentDomain)
            let model = AppModel()
            model.accounts = [
                Account(id: "preview-1", provider: .claude, name: "Claude (Personal)", dir: nil),
                Account(id: "preview-2", provider: .claude, name: "Claude (Work)", dir: nil),
                Account(id: "preview-3", provider: .codex, name: "ChatGPT (Personal)", dir: nil),
                Account(id: "preview-4", provider: .codex, name: "ChatGPT (Work)", dir: nil),
                Account(id: "preview-5", provider: .gemini, name: "Gemini", dir: nil)
            ]
            model.usageMenuStyle = .comparisonRings
            for account in model.accounts {
                var usage = AIUsage(name: account.name, account: account)
                usage.fiveHour = UsageWindow(usedPercent: 24, resetsAt: nil)
                model.latestUsage[account.id] = usage
            }
            let views: [(String, AnyView)] = [
                ("general", AnyView(GeneralSettingsTab(model: model))),
                ("accounts", AnyView(AccountsSettingsTab(model: model))),
                ("chat", AnyView(ChatSettingsTab(model: model)))
            ]
            for appearance in [NSAppearance.Name.darkAqua, .aqua] {
                for (name, view) in views {
                    let size = SettingsWindow.size
                    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: appearance)
                    window.contentView = host
                    host.frame = NSRect(origin: .zero, size: size)
                    for _ in 0..<5 {
                        host.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    }
                    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = bitmap.representation(using: .png, properties: [:])!
                    let theme = appearance == .darkAqua ? "dark" : "light"
                    try data.write(to: output.appendingPathComponent("\(language)-\(theme)-\(name).png"))
                    window.contentView = nil
                }
            }
        }
        print("Rendered 12 fixture previews at \(output.path)")
    }
}
