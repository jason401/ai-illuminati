import AppKit
import SwiftUI
import AIChat

// The app's screens the chat window (AIChat) shows: the TODO board, Project info, the icon, Manage chats' iPhone item
// (PhoneAccess.swift).
// Connected once by main.swift with ChatLinksApp.connect.
enum ChatScreensApp {
    static func connect() {
        var screens = ChatApp.Screens()
        screens.boardRow = { AnyView(TodoBoardRow(discussion: $0)) }
        screens.board = { AnyView(TodoBoardView(discussion: $0)) }
        screens.cards = { AnyView(TodoCardsView(room: $0, discussion: $1)) }
        screens.inboxCard = { AnyView(TodoCard(item: $0, discussion: $1, compact: true, panel: true)) }
        screens.projectInfo = { AnyView(ProjectInfoView(discussion: $0, project: $1)) }
        screens.todoPanel = { AnyView(ProjectTodoPanel(discussion: $0, project: $1)) }
        screens.renameProject = { ProjectInfoView.rename($0, current: $1) }
        screens.icon = { illuminatiIcon(colored: $0) }
        screens.manageItems = { AnyView(PhoneAccessMenuItem()) }
        ChatApp.screens = screens
    }
}
