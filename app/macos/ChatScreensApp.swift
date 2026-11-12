import AppKit
import SwiftUI
import AIChat

// The app's screens the chat window (AIChat) shows: the TODO board, Project info, the Drive section, the icon.
// Connected once by main.swift with ChatLinksApp.connect.
enum ChatScreensApp {
    static func connect() {
        var screens = ChatApp.Screens()
        screens.boardRow = { AnyView(TodoBoardRow(discussion: $0)) }
        screens.board = { AnyView(TodoBoardView(discussion: $0)) }
        screens.cards = { AnyView(TodoCardsView(room: $0, discussion: $1)) }
        screens.projectInfo = { AnyView(ProjectInfoView(discussion: $0, project: $1)) }
        screens.renameProject = { ProjectInfoView.rename($0, current: $1) }
        screens.drive = { AnyView(DriveSidebarSection()) }
        screens.icon = { illuminatiIcon(colored: $0) }
        ChatApp.screens = screens
    }
}
