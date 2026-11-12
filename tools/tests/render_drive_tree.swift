import Cocoa
import SwiftUI
@testable import AIChat

@main
struct RenderDriveTree {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let center = DriveCenter(startRefreshing: false)
        let root = DriveFolder(id: "preview-root", name: "Research")
        let paper = DriveFolder(id: "preview-paper", name: "Lamb Wave Paper")
        let references = DriveFolder(id: "preview-ref", name: "References")
        let figures = DriveFolder(id: "preview-fig", name: "Figures")
        let raw = DriveFolder(id: "preview-raw", name: "Raw Data")
        center.folders = [root]
        center.on = true
        center.children = [root.id: [paper, references, raw], paper.id: [figures]]
        center.expanded = [root.id, paper.id]
        center.writeRules = [paper.id: true, raw.id: false]
        let section = DriveSidebarSection(center: center)
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let view = VStack(alignment: .leading, spacing: 1) {
                Text("Google Drive").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
                ForEach(center.treeRows) { item in section.row(item) }
                Spacer()
            }.padding(.top, 14).frame(width: 250, height: 240)
                .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
                .background(appearance == .darkAqua ? Color(red: 0.15, green: 0.15, blue: 0.15) : Color(red: 0.94, green: 0.94, blue: 0.94))
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            for _ in 0..<5 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(appearance == .darkAqua ? "drive-tree-dark.png" : "drive-tree-light.png"))
            window.contentView = nil
        }
    }
}
