import AppKit
import SwiftUI
import AIChat
import AILocalization

// The app's screens the chat window (AIChat) shows: the TODO board, Project info, the icon, Manage chats' iPhone item
// (PhoneAccess.swift), and Drive's rows in Shared folders.
// Connected once by main.swift with ChatLinksApp.connect.
enum ChatScreensApp {
    static func connect() {
        var screens = ChatApp.Screens()
        screens.boardRow = { AnyView(TodoBoardRow(discussion: $0)) }
        screens.board = { AnyView(TodoBoardView(discussion: $0)) }
        screens.cards = { AnyView(TodoCardsView(room: $0, discussion: $1)) }
        screens.projectInfo = { AnyView(ProjectInfoView(discussion: $0, project: $1)) }
        screens.renameProject = { ProjectInfoView.rename($0, current: $1) }
        screens.icon = { illuminatiIcon(colored: $0) }
        screens.manageItems = { AnyView(PhoneAccessMenuItem()) }
        ChatApp.screens = screens
        // Drive's count comes from its rows (DriveSidebarSection), so nothing here reads the login yet.
        FolderSources.shared.list = [FolderSource(id: "drive", addTitle: L("Google Drive 폴더…", "Google Drive Folder…"),
                                                  add: { DriveCenter.shared.addFolder() }, rows: { AnyView(DriveSidebarSection()) })]
    }
}
