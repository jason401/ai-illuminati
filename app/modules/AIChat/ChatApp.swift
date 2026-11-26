import AppKit
import SwiftUI
import AIAccounts
import AIChatRecords
import AIProjects
import AIRuntime
import AIWorkspace

// What a chat gets from the app, set once by the app before the first chat (ChatLinksApp.connect), like ChatStore.links:
// the chat side names none of these app parts. Unset (a program that did not connect), a chat runs each tool plainly,
// leaves AI Face tags in the text and shows no app screens.
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
    var opinionDigest: Bool { get }   // several views: one AI sums them up (Settings → Chat, on by default)
    var sharedFolders: [String] { get set }
    var activeSharedFolders: [String] { get }
    var pausedSharedFolders: Set<String> { get set }
    var writableSharedFolders: Set<String> { get set }
    var onAccountsChange: (() -> Void)? { get }
    func addSharedFolder()
}

public enum ChatApp {
    // How each AI's tool starts (RunConditions.app in RunConditionsApp.swift: AI Face off for Codex, project work's
    // process group, AutoGuard in full access, the folder rules and whether this answer can use the screen).
    // The third value is set when this answer may use the Mac (screen, mouse, keys): see ScreenAnswer.
    public static var run: (Account, WorkspaceInvocation?, ScreenAnswer?) -> RunConditions = { _, _, _ in RunConditions() }

    // The answer a Mac control grant belongs to: its chat (approval cards), who answers (the cards, the band, the
    // lock's refusal), how Esc stops it, and its action log under the reply (ChatTurn.macLog).
    public struct ScreenAnswer {
        public let room: UUID
        public let speaker: String
        public let stop: () -> Void
        public let note: (String) -> Void
    }

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

    // The app's screens shown inside the chat window: the TODO board (its sidebar row, the board, a chat's TODO cards),
    // Project info and its rename, the app's icon, the items the app adds to Manage chats (iPhone access).
    // (An outside kind's sidebar rows come in through FolderSources.)
    public struct Screens {
        public var boardRow: (Discussion) -> AnyView = { _ in AnyView(EmptyView()) }
        public var board: (Discussion) -> AnyView = { _ in AnyView(EmptyView()) }
        public var cards: (UUID, Discussion) -> AnyView = { _, _ in AnyView(EmptyView()) }
        public var inboxCard: (TodoItem, Discussion) -> AnyView = { _, _ in AnyView(EmptyView()) }   // a TODO's answer or result box in the inbox
        public var projectInfo: (Discussion, String) -> AnyView = { _, _ in AnyView(EmptyView()) }
        public var todoPanel: (Discussion, String) -> AnyView = { _, _ in AnyView(EmptyView()) }   // a project's TODOs beside its Project info
        public var renameProject: (String, String) -> Void = { _, _ in }
        public var icon: (Bool) -> NSImage = { _ in NSImage() }
        public var manageItems: () -> AnyView = { AnyView(EmptyView()) }
        public var approvals: () -> Void = {}   // the app's approval window (an outside tool's request has no chat to open)
        public init() {}
    }
    public static var screens = Screens()
}

// Folders from outside this Mac, listed in the sidebar's Shared folders after the local ones (Google Drive is one,
// GoogleDriveFolder.swift): its item in the section's + menu, its rows (with its own account hints) and how many folders
// it has, so the section shows one empty hint only while every kind is empty. Only the list is shared, not the storage.
// The rows stay in the view while the section is folded (SidebarFold "shared"): they hide their own content there.
public struct FolderSource {
    public let id: String
    public var addTitle: String
    public var add: () -> Void
    public var rows: () -> AnyView
    public init(id: String, addTitle: String, add: @escaping () -> Void, rows: @escaping () -> AnyView) {
        self.id = id; self.addTitle = addTitle; self.add = add; self.rows = rows
    }
}

public final class FolderSources: ObservableObject {
    public static let shared = FolderSources()
    @Published public var list: [FolderSource] = []
    @Published public var counts: [String: Int] = [:]
    var isEmpty: Bool { list.allSatisfy { (counts[$0.id] ?? 0) == 0 } }
}

extension RunConditions {
    // The chat's calls read as before (`.app(account, invocation)`); the app's rules come in through ChatApp.run.
    static func app(_ account: Account, _ workspace: WorkspaceInvocation? = nil, screen: ChatApp.ScreenAnswer? = nil) -> RunConditions {
        ChatApp.run(account, workspace, screen)
    }
}

// A tool call's error reply (the same shape as ToolHub.failure).
func toolFailure(_ text: String) -> [String: Any] {
    ["content": [["type": "text", "text": text]], "isError": true]
}
