import Foundation
import AIAccounts

// AIChatRecords: the values a chat's record holds, its pictures and dropped files, the collaboration log and the
// disk report; none of them knows Discussion. ChatStore (AIChat) takes its folder from here.
public enum ChatPaths { public static let dir = AccountStore.supportDir + "/chats" }
