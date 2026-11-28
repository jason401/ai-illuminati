import Foundation
import Darwin
import AIAccounts
import AILocalization
import AIWorkspace
import AIProjects
import AIRuntime
import AIChat
import AIIntegrations

extension FaceLink: @retroactive ToolProvider {
    public var active: Bool { Self.active() != nil }
    public func call(_ name: String, _ arguments: [String: Any], context: ToolContext) -> [String: Any] { call(name, arguments) }
}

private final class ScreenTools: ToolProvider {
    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private let finished = DispatchSemaphore(value: 0)
        private var result: [String: Any] = [:]

        func complete(_ result: [String: Any]) {
            lock.withLock { self.result = result }
            finished.signal()
        }

        func wait(_ seconds: Double) -> [String: Any]? {
            guard finished.wait(timeout: .now() + seconds) == .success else { return nil }
            return lock.withLock { result }
        }
    }

    static let shared = ScreenTools()
    let active = true
    func tools() -> [[String: Any]] { [] }
    func tools(context: ToolContext) -> [[String: Any]] {
        MacControl.enabled(context.asker) ? MacControl.tools(context.asker) : []
    }
    func call(_ name: String, _ arguments: [String: Any], context: ToolContext) -> [String: Any] { call(name, arguments, context: context, scope: nil) }
    func call(_ name: String, _ arguments: [String: Any], context: ToolContext, scope: UUID?) -> [String: Any] {
        // Socket calls run on a worker; AppKit reads the app list on the main actor.
        let reply = Reply()
        let capture = Task { @MainActor in
            guard !Task.isCancelled, MacControl.enabled(context.asker) else { reply.complete([:]); return }
            reply.complete(await MacControl.perform(name, arguments, scope: scope))
        }
        // Hands may wait for a card (60 s) and for the user's own input to settle (30 s at most); the bridge waits 125 s for them.
        guard let result = reply.wait(MacControl.handNames.contains(name) ? MacControl.approvalWait + 50 : 12) else {
            capture.cancel()
            return ToolHub.failure(L("화면 도구가 시간 안에 응답하지 않았어요.", "The screen tool timed out."))
        }
        return result
    }

    // A Mac control card (MacControl "ask"): the chat's approval card, so it shows in the chat, the 🔴 strip, the inbox and
    // the Dock; 60 seconds without an answer is no. Tests replace MacControl.approve.
    static func approve(_ card: MacControl.Approval) -> Bool {
        var request = ProjectApproval(room: card.room ?? UUID(), run: UUID(), title: card.title, detail: card.detail)
        request.allowLabel = L("이번 답에서 허용", "Allow for this answer")
        // The card leaves the chat and the inbox as soon as its answer stops (Esc, Stop, the answer's end).
        let token = DebateCancellation(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while done.wait(timeout: .now() + 0.2) == .timedOut { if card.ended() { token.cancel(); return } }
        }
        defer { done.signal() }
        return ProjectCenter.shared.approve(request, token: token, deadline: Date().addingTimeInterval(MacControl.approvalWait))
    }
}

// One app-side gateway. Per-answer capabilities keep other chat modes and arbitrary local
// pointer paths out; they grant the CLI no credentials and no network access.
final class ToolHub {
    static var appProviders: [ToolProvider] { [FaceLink.shared, GitLink.shared, PlanLink.shared, PeerLink.shared, ConveneLink.shared, DelegateLink.shared, ChatLink.shared, MemoryLink.shared, ProjectMakerLink.shared, TaskLink.shared, TodoAddLink.shared, StorageLink.shared, ExternalMCP.shared, SkillLink.shared] }
    static let shared: ToolHub = {
        let hub = ToolHub(providers: { appProviders })
        MacControl.approve = ScreenTools.approve
        ProjectWork.revokeTools = { [weak hub] in hub?.revoke(project: $0) }
        return hub
    }()
    static var socketPath = AccountStore.supportDir + "/tools.sock"
    private let providerList: () -> [ToolProvider]
    private let now: () -> Date
    private let listenOnRegister: Bool
    private var providers: [ToolProvider] { providerList() }
    var active: Bool { providers.contains { $0.active } }
    private let lock = NSLock()
    private var sockets: Set<String> = []
    private struct Session {
        let context: ToolContext
        let expires: Date
        var screenScope: UUID?
        let screenOnly: Bool
    }
    private var sessions: [String: Session] = [:]
    // The app supplies one fixed list; no dynamic registration.
    init(providers: @escaping () -> [ToolProvider], now: @escaping () -> Date = { Date() }, listenOnRegister: Bool = true) {
        self.providerList = providers; self.now = now; self.listenOnRegister = listenOnRegister
    }

    func register(room: UUID, roots: [WorkspaceRoot], projectRun: UUID? = nil, generation: Int? = nil, asker: Account? = nil,
                  origin: ToolOrigin = .member, screenScope: UUID? = nil, screenOnly: Bool = false, allowsSkillEdits: Bool = true) -> String {
        if listenOnRegister { start() }
        let turn = asker == nil || screenOnly ? nil : MemoryLink.shared.newestTurn(room)   // read before taking the lock (it may wait for the main thread)
        lock.lock(); defer { lock.unlock() }
        sessions = sessions.filter { $0.value.expires > now() }
        let key = UUID().uuidString
        var context = ToolContext(room: room, roots: roots, projectRun: projectRun, projectGeneration: generation, asker: asker, turn: turn, origin: origin)
        context.allowsSkillEdits = allowsSkillEdits
        sessions[key] = Session(context: context, expires: now().addingTimeInterval(7200), screenScope: screenScope, screenOnly: screenOnly)
        return key
    }

    // What the workspace bridge gets for one call (Workspace.swift asks only when its chat offers tools).
    static let workspaceLink: WorkspaceTools = { link($0) }
    static func link(_ invocation: WorkspaceInvocation, screenScope: UUID? = nil, screenOnly: Bool = false) -> WorkspaceToolLink? {
        guard screenScope != nil || shared.active else { return nil }
        let binding = invocation.binding
        let session = shared.register(room: invocation.room, roots: binding.roots, projectRun: binding.projectRunID, generation: binding.projectGeneration,
                                      asker: invocation.account, origin: binding.origin ?? .member, screenScope: screenScope, screenOnly: screenOnly,
                                      allowsSkillEdits: binding.allowsSkillEdits != false)
        return WorkspaceToolLink(socket: socketPath, session: session, face: !screenOnly && FaceLink.active() != nil ? FaceLink.socketPath : nil)
    }

    func revoke(project: UUID) { lock.lock(); sessions = sessions.filter { $0.value.context.projectRun != project }; lock.unlock() }

    func revoke(screen scope: UUID) {
        lock.lock(); defer { lock.unlock() }
        for key in Array(sessions.keys) where sessions[key]?.screenScope == scope {
            if sessions[key]?.screenOnly == true { sessions.removeValue(forKey: key) }
            else { sessions[key]?.screenScope = nil }
        }
    }

    func start() { listen(at: Self.socketPath, legacy: false) }
    // One release of compatibility for already prepared face-only manifests.
    func startLegacyFaceSocket(at path: String) { listen(at: path, legacy: true) }

    static func failure(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": true]
    }

    func handle(_ message: [String: Any], legacy: Bool = false) -> [String: Any] {
        let context: ToolContext
        var scope: UUID?
        var screenOnly = false
        let key = message["session"] as? String ?? ""
        if legacy {
            context = ToolContext(room: UUID(), roots: [])
        } else {
            lock.lock()
            let session = sessions[key]
            lock.unlock()
            guard let session, session.expires > now() else { return Self.failure("This tool session has expired or is unavailable.") }
            context = session.context
            scope = session.screenScope
            screenOnly = session.screenOnly
        }
        var available = screenOnly ? [] : available(context: context, legacy: legacy)
        if scope != nil && context.origin == .member { available.append(ScreenTools.shared) }
        switch message["op"] as? String {
        case "tools":
            let tools = available.filter { $0.active }.flatMap { $0.tools(context: context) }
            // Outside servers' tools may take minutes and Mac hands may wait for a card; the bridge waits longer for exactly these names.
            let slow = Set(ExternalMCP.shared.slowTools).union(MacControl.handNames)
            return ["tools": tools, "slow": tools.compactMap { $0["name"] as? String }.filter(slow.contains)]
        case "call":
            let name = message["name"] as? String ?? ""
            guard let provider = available.first(where: { $0.active && $0.tools(context: context).contains { $0["name"] as? String == name } }) else {
                return Self.failure("Tool is disconnected, switched off or unavailable: " + name)
            }
            let arguments = message["arguments"] as? [String: Any] ?? [:]
            let result = provider === ScreenTools.shared ? ScreenTools.shared.call(name, arguments, context: context, scope: scope)
                : provider.call(name, arguments, context: context)
            if provider === ScreenTools.shared {
                lock.lock()
                let current = sessions[key]?.screenScope
                lock.unlock()
                guard current == scope, MacControl.enabled(context.asker), !result.isEmpty else {
                    return Self.failure(L("이 답의 화면 보기 권한이 끝났어요.", "Screen access for this answer has ended."))
                }
            }
            return result
        default: return Self.failure("Unknown tool request")
        }
    }

    // Keep origin filtering distinct from each provider's own context gate.
    func available(context: ToolContext, legacy: Bool = false) -> [ToolProvider] {
        legacy ? [FaceLink.shared]
            : context.origin == .side ? [PeerLink.shared, SkillLink.shared]
            : context.origin == .consulted ? providers.filter { $0 !== PeerLink.shared && $0 !== ConveneLink.shared && $0 !== DelegateLink.shared } : providers
    }

    private func listen(at path: String, legacy: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !sockets.contains(path) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
        unlink(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 8) == 0 else { close(fd); return }
        sockets.insert(path)
        signal(SIGPIPE, SIG_IGN)
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { Thread.sleep(forTimeInterval: 0.05); continue }   // one failed accept must not stop the socket
                DispatchQueue.global().async { self?.serve(client, legacy: legacy) }
            }
        }
    }

    private func serve(_ client: Int32, legacy: Bool) {
        defer { close(client) }
        var timeout = timeval(tv_sec: 65, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data(), chunk = [UInt8](repeating: 0, count: 4096)
        while !data.contains(10) && data.count < 1_000_000 {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { return }
            data.append(contentsOf: chunk.prefix(n))
        }
        guard let line = data.split(separator: 10).first,
              let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let output = try? JSONSerialization.data(withJSONObject: handle(message, legacy: legacy)) else { return }
        (output + Data([10])).withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(client, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}
