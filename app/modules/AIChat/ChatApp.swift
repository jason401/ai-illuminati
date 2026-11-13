import AppKit
import SwiftUI
@_exported import AIChatRecords
import AIAccounts
import AIRuntime
import AIWorkspace

// What a chat gets from the app, set once by the app before the first chat (ChatLinksApp.connect), like ChatStore.links:
// the chat side names none of these app parts. Unset (a program that did not connect), a chat runs each tool plainly,
// leaves AI Face tags in the text, offers no Drive and shows no app screens.
// What a chat reads of the app's settings (AppModel conforms in Settings.swift). The chat window observes it.
public protocol ChatSettings: ObservableObject {
    var accounts: [Account] { get }
    var latestUsage: [String: AIUsage] { get }   // last readings by account id
    var chatRules: String { get }
    var localEnabled: Bool { get }
    var hasLocal: Bool { get }
    var pictureMakers: [Account] { get }
    var autoTeamPicks: [String: Bool] { get }
    var collaboration: CollabMode { get }
    var sharedFolders: [String] { get set }
    var activeSharedFolders: [String] { get }
    var pausedSharedFolders: Set<String> { get set }
    var writableSharedFolders: Set<String> { get set }
    var onAccountsChange: (() -> Void)? { get }
    func addSharedFolder()
}

public enum ChatApp {
    // How each AI's tool starts (RunConditions.app in RunConditionsApp.swift: AI Face off for Codex, project work's
    // process group, AutoGuard in full access, the folder rules with the app's tool gateway).
    public static var run: (Account, WorkspaceInvocation?) -> RunConditions = { _, _ in RunConditions() }

    // AI Face (FaceLink): the hidden <face>mood</face> tag taken off a reply, the face shown, and the rule an AI gets.
    public struct Face {
        public var extract: (String) -> (text: String, mood: String?) = { ($0, nil) }
        public var show: (String) -> Void = { _ in }
        public var active: () -> Bool = { false }
        public var moods: () -> [String] = { [] }
        public var rule: ([String]) -> String = { _ in "" }
        public init() {}
    }
    public static var face = Face()

    // Google Drive (DriveLink): the rule an AI gets while Drive is on, nil while it is off.
    public static var driveRule: () -> String? = { nil }

    // The app's screens shown inside the chat window: the TODO board (its sidebar row, the board, a chat's TODO cards),
    // Project info and its rename, the Drive section of the sidebar, the app's icon.
    public struct Screens {
        public var boardRow: (Discussion) -> AnyView = { _ in AnyView(EmptyView()) }
        public var board: (Discussion) -> AnyView = { _ in AnyView(EmptyView()) }
        public var cards: (UUID, Discussion) -> AnyView = { _, _ in AnyView(EmptyView()) }
        public var projectInfo: (Discussion, String) -> AnyView = { _, _ in AnyView(EmptyView()) }
        public var renameProject: (String, String) -> Void = { _, _ in }
        public var drive: () -> AnyView = { AnyView(EmptyView()) }
        public var icon: (Bool) -> NSImage = { _ in NSImage() }
        public init() {}
    }
    public static var screens = Screens()
}

extension RunConditions {
    // The chat's calls read as before (`.app(account, invocation)`); the app's rules come in through ChatApp.run.
    static func app(_ account: Account, _ workspace: WorkspaceInvocation? = nil) -> RunConditions { ChatApp.run(account, workspace) }
}

// A tool call's error reply (the same shape as ToolHub.failure).
func toolFailure(_ text: String) -> [String: Any] {
    ["content": [["type": "text", "text": text]], "isError": true]
}
