import Cocoa
import Combine
import SwiftUI
import UserNotifications
import AILocalization
import AIProjects
import AIChat

// Reaches the user when an approval waits while they look at another chat or another app:
// a macOS notification with Open / Deny, the Dock badge, and the approval window. Allow is only
// in the window or the chat card, where the details are shown. Nothing pulls a window to the front
// by itself; a notification closed without a choice leaves the request waiting.
final class ApprovalAlerts: NSObject, UNUserNotificationCenterDelegate {
    static let category = "approval", openAction = "open", denyAction = "deny", doneCategory = "workDone"
    private let discussion: Discussion
    private let openChatWindow: (UUID?) -> Void
    private var window: NSWindow?
    private var watching: AnyCancellable?
    private var ended: NSObjectProtocol?
    private var todo: NSObjectProtocol?
    private var known: Set<UUID> = []
    private var lastPosted: [UUID: Date] = [:]
    private var repeatTimer: Timer?
    private var asked = false

    init(discussion: Discussion, openChat: @escaping (UUID?) -> Void) {
        self.discussion = discussion
        self.openChatWindow = openChat
        super.init()
    }

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: Self.openAction, title: L("열기", "Open"), options: [.foreground])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: L("거절", "Deny"), options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [open, deny], intentIdentifiers: []),
                                          UNNotificationCategory(identifier: Self.doneCategory, actions: [], intentIdentifiers: [])])
        ended = NotificationCenter.default.addObserver(forName: .projectWorkEnded, object: nil, queue: .main) { [weak self] note in self?.workEnded(note) }
        todo = NotificationCenter.default.addObserver(forName: .todoNeedsUser, object: nil, queue: .main) { [weak self] note in self?.todoNeedsUser(note) }
        watching = ProjectCenter.shared.$requests.receive(on: DispatchQueue.main).sink { [weak self] requests in self?.changed(requests) }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.remind() }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func changed(_ requests: [ProjectApproval]) {
        let ids = Set(requests.map(\.id))
        let gone = known.subtracting(ids)
        if !gone.isEmpty {
            let names = gone.map(\.uuidString)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: names)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: names)
            for id in gone { lastPosted.removeValue(forKey: id) }
        }
        for request in requests where !known.contains(request.id) {
            // Looking right at the card: nothing more to say.
            let seen = NSApp.isActive && discussion.currentID == request.room && discussion.viewingRemote == nil
                && NSApp.keyWindow?.title == L("AI Illuminati 채팅", "AI Illuminati Chat")
            if seen { lastPosted[request.id] = Date() } else {
                post(request)
                if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            }
        }
        known = ids
        NSApp.dockTile.badgeLabel = requests.isEmpty ? nil : String(requests.count)
    }

    // Project work ended while the user looks elsewhere: "작업 완료 · 5/5" or "작업 실패", opening that chat.
    private func workEnded(_ note: Notification) {
        guard ApprovalAlertSettings.notify, let room = note.userInfo?["room"] as? UUID, let index = note.userInfo?["index"] as? Int,
              let turns = discussion.conversations.first(where: { $0.id == room })?.turns, turns.indices.contains(index) else { return }
        let turn = turns[index]
        // A TODO's chat says it with its own notice (todoNeedsUser), once the result or the question is there.
        if TodoStore.shared.current.items.contains(where: { $0.room == room }) { return }
        let seen = NSApp.isActive && discussion.currentID == room && discussion.viewingRemote == nil
            && NSApp.keyWindow?.title == L("AI Illuminati 채팅", "AI Illuminati Chat")
        if seen { return }
        let problem = note.userInfo?["problem"] as? String
        let ok = turn.error == nil && problem == nil
        let steps = turn.plan ?? []
        let count = steps.isEmpty ? "" : " · \(steps.filter { $0.status == .done }.count)/\(steps.count)"
        let content = UNMutableNotificationContent()
        content.title = (ok ? L("작업 완료", "Work done") : L("작업이 끝나지 못했어요", "Work did not finish")) + count
        content.subtitle = discussion.approvalChatName(room)
        content.body = ok ? String((turn.final ?? "").prefix(140)) : (turn.error ?? problem ?? "")
        content.categoryIdentifier = Self.doneCategory
        content.userInfo = ["room": room.uuidString]
        if ApprovalAlertSettings.sound { content.sound = .default }
        let center = UNUserNotificationCenter.current()
        let send = { center.add(UNNotificationRequest(identifier: "done-" + turn.id.uuidString, content: content, trigger: nil)) }
        if asked { send(); return }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.asked = true; if granted { send() } }
        }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    // A TODO waits for the user: its result to check, or a decision. Opens its chat.
    private func todoNeedsUser(_ note: Notification) {
        guard ApprovalAlertSettings.notify, let title = note.userInfo?["title"] as? String else { return }
        let room = note.userInfo?["room"] as? UUID
        let content = UNMutableNotificationContent()
        content.title = (note.userInfo?["review"] as? Bool == true ? L("TODO 확인 대기", "TODO ready to check") : L("TODO · 네 결정 필요", "TODO needs you")) + " · " + title
        content.body = String((note.userInfo?["body"] as? String ?? "").prefix(160))
        content.categoryIdentifier = Self.doneCategory
        if let room { content.userInfo = ["room": room.uuidString] }
        if ApprovalAlertSettings.sound { content.sound = .default }
        let center = UNUserNotificationCenter.current()
        let send = { center.add(UNNotificationRequest(identifier: "todo-" + UUID().uuidString, content: content, trigger: nil)) }
        if asked { send(); return }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.asked = true; if granted { send() } }
        }
    }

    // Optional reminder every 5 minutes while a request still waits (Settings → Chat).
    private func remind() {
        guard ApprovalAlertSettings.repeats else { return }
        for request in ProjectCenter.shared.requests where Date().timeIntervalSince(lastPosted[request.id] ?? request.created) >= 300 {
            post(request)
        }
    }

    private func post(_ request: ProjectApproval) {
        lastPosted[request.id] = Date()
        guard ApprovalAlertSettings.notify else { return }
        let center = UNUserNotificationCenter.current()
        let send = {
            let content = UNMutableNotificationContent()
            content.title = L("허가가 필요해요", "Approval needed")
            content.subtitle = self.discussion.approvalChatName(request.room)
            content.body = request.title
            content.categoryIdentifier = Self.category
            content.userInfo = ["request": request.id.uuidString, "room": request.room.uuidString]
            content.interruptionLevel = .timeSensitive
            if ApprovalAlertSettings.sound { content.sound = .default }
            center.add(UNNotificationRequest(identifier: request.id.uuidString, content: content, trigger: nil))
        }
        if asked { send(); return }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.asked = true
                // Still waiting? A request decided while macOS asked for permission is not announced.
                if granted, ProjectCenter.shared.requests.contains(where: { $0.id == request.id }) { send() }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(ApprovalAlertSettings.sound ? [.banner, .list, .sound] : [.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let id = (info["request"] as? String).flatMap(UUID.init(uuidString:))
        let room = (info["room"] as? String).flatMap(UUID.init(uuidString:))
        let done = response.notification.request.content.categoryIdentifier == Self.doneCategory
        DispatchQueue.main.async {
            if done {
                if response.actionIdentifier != UNNotificationDismissActionIdentifier, let room { self.openChatWindow(room) }
                completionHandler(); return
            }
            switch response.actionIdentifier {
            case Self.denyAction:
                // Only a request still waiting; an old notification does nothing.
                if let id { ProjectCenter.shared.decide(id, allow: false) }
            case UNNotificationDismissActionIdentifier:
                break   // Closing the notification is not a decision.
            default:
                self.show()
            }
            completionHandler()
        }
    }

    // The approval window: every waiting request, with Allow / Deny / Open chat.
    func show() {
        if window == nil {
            let view = ApprovalListView(discussion: discussion) { [weak self] room in
                self?.openChatWindow(room)
            }
            let host = NSHostingController(rootView: view)
            let w = NSWindow(contentViewController: host)
            w.title = L("허가 요청", "Approval requests")
            w.styleMask = [.titled, .closable, .resizable]
            w.setContentSize(NSSize(width: 480, height: 360))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
