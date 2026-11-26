import AppKit
import Network
import SwiftUI
import CoreImage
import AIAccounts
import AILocalization
import AIRuntime
import AIChat
import AIProjects
import AIRemote

// iPhone access over Tailscale: this Mac's tailnet address as a QR the iPhone camera opens, whether the user's iPhones are
// on the tailnet now, and (turned on in the window) the phone page: AIRemote's server on 127.0.0.1 with `tailscale serve`
// bringing https://<mac>.ts.net/ to it. "Connected" is Tailscale's own Online flag: the phone is on the tailnet.
struct TailnetStatus: Equatable {
    struct Phone: Equatable, Identifiable {
        var id: String
        var name: String
        var online: Bool
        var lastSeen: Date?
    }
    enum State: Equatable { case missing, stopped, running }
    var state: State = .missing
    var host: String?          // this Mac's MagicDNS name, without the trailing dot
    var https = false          // the admin console's HTTPS certificates are on for this host
    var served: String?        // what `tailscale serve` sends https://host/ to, nil while nothing is served
    var phones: [Phone] = []
    var macs: [String: Bool] = [:]   // the other Macs on the tailnet: MagicDNS name (lowercased) → online
    var url: URL? { host.map { URL(string: "https://\($0)/") } ?? nil }
    // The phone page is what serve sends the address to.
    var servesPhone: Bool { served == PhoneServer.target }

    // `tailscale status --json` and `tailscale serve status --json`; phones are the peers whose OS is iOS.
    static func parse(status: Data?, serve: Data?) -> TailnetStatus {
        var result = TailnetStatus()
        guard let data = status, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return result }
        result.state = (json["BackendState"] as? String) == "Running" ? .running : .stopped
        let me = json["Self"] as? [String: Any]
        if let name = (me?["DNSName"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: ".")), !name.isEmpty { result.host = name }
        result.https = result.host.map { ((json["CertDomains"] as? [String]) ?? []).contains($0) } ?? false
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let peers = (json["Peer"] as? [String: [String: Any]]) ?? [:]
        result.phones = peers.compactMap { key, peer in
            guard (peer["OS"] as? String) == "iOS" else { return nil }
            // An iPhone's HostName is often "localhost"; its DNS name carries the device name.
            let dns = (peer["DNSName"] as? String)?.split(separator: ".").first.map(String.init)
            let host = peer["HostName"] as? String
            let name = dns ?? (host == "localhost" ? nil : host) ?? "iPhone"
            let seen = (peer["LastSeen"] as? String).flatMap { iso.date(from: $0) ?? plain.date(from: $0) }
            return Phone(id: (peer["ID"] as? String) ?? key, name: name, online: (peer["Online"] as? Bool) == true,
                         lastSeen: seen.flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil })
        }
        .sorted { ($0.online ? 0 : 1, $0.name) < ($1.online ? 0 : 1, $1.name) }
        for peer in peers.values where (peer["OS"] as? String) == "macOS" {
            guard let dns = (peer["DNSName"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased(), !dns.isEmpty else { continue }
            result.macs[dns] = (peer["Online"] as? Bool) == true
        }
        if let host = result.host, let data = serve, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let web = json["Web"] as? [String: [String: Any]], let site = web[host + ":443"],
           let handlers = site["Handlers"] as? [String: [String: Any]] {
            result.served = (handlers["/"]?["Proxy"] as? String) ?? (handlers["/"]?["Path"] as? String)
        }
        return result
    }

    static func qr(_ text: String, scale: CGFloat = 8) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

final class PhoneAccess: ObservableObject {
    static let shared = PhoneAccess()
    @Published private(set) var status = TailnetStatus()
    @Published private(set) var checked = false
    private var timer: Timer?
    private var busy = false

    // The standalone app's CLI first (the one the Tailscale menu offers to link), then the usual installs.
    static let cliPaths = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
    // Started from an app (no TERM), the standalone app's binary tries to open its GUI and fails; this makes it the CLI.
    static var cliEnvironment: [String: String] { ProcessInfo.processInfo.environment.merging(["TAILSCALE_BE_CLI": "1"]) { $1 } }

    func refresh(then done: ((TailnetStatus) -> Void)? = nil) {
        guard !busy else { if let done { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh(then: done) } }; return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            let cli = Self.cliPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
            let next = cli.map { TailnetStatus.parse(status: Self.run($0, ["status", "--json"]), serve: Self.run($0, ["serve", "status", "--json"])) }
                ?? TailnetStatus()
            DispatchQueue.main.async {
                self.busy = false
                self.checked = true
                if self.status != next { self.status = next }
                PhoneServer.shared.tailnetChecked(next)
                done?(next)
            }
        }
    }

    // Polls while the window is open; the window stops it when it closes.
    func watch(_ on: Bool) {
        timer?.invalidate(); timer = nil
        guard on else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private static func run(_ path: String, _ args: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = cliEnvironment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // A stuck daemon must not hold the refresh forever.
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return process.terminationStatus == 0 ? data : nil
    }
}

// The phone page (turned on in the iPhone window, remembered across launches): AIRemote serves it, the chats answer
// (AIChat's RemoteChats) and approvals are ProjectCenter's, so deciding on the phone clears the
// Mac's card too. The key in the QR guards every /api/ call; a new key (the window's "New QR") locks out old phones.
protocol PhoneUsage: AnyObject {
    func phoneUsageSnapshot() -> PhoneUsageSnapshot
    func phoneRefreshUsage()
}

struct PhoneUsageSnapshot {
    let device: String
    let accounts: [Account]
    let readings: [String: AIUsage]
    let colors: [Account.Provider: [String]]

    func json(at now: Date) -> [String: Any] {
        // Account names and notes can contain user-supplied text, including email addresses.
        func safe(_ text: String) -> String {
            text.replacingOccurrences(of: #"\S*@\S*"#, with: "…", options: .regularExpression)
        }
        // All date values on the wire use Unix milliseconds for JavaScript.
        func timestamp(_ date: Date?) -> Any {
            guard let date else { return NSNull() }
            return date.timeIntervalSince1970 * 1000
        }
        func window(_ usage: UsageWindow?) -> Any {
            guard let usage else { return NSNull() }
            return ["left": usage.left(now: now), "resetsAt": timestamp(usage.resetsAt)]
        }
        var providers: [Account.Provider] = []
        var entries: [Account.Provider: [[String: Any]]] = [:]
        for account in accounts {
            if entries[account.provider] == nil { providers.append(account.provider) }
            let usage = readings[account.id]
            let plan = usage?.detail?.components(separatedBy: " · ").last
            let isLocal = account.provider == .ollama
            var extras = usage?.extras.map(safe) ?? []
            // Ollama's synthetic full bars are only for the menu bar icon.
            if isLocal, usage?.fiveHour != nil || usage?.weekly != nil {
                extras.insert(L("한도 없음", "No limit"), at: 0)
            }
            entries[account.provider, default: []].append([
                "name": safe(account.name),
                "plan": plan.flatMap { $0.isEmpty || $0.contains("@") ? nil : $0 } as Any? ?? NSNull(),
                "fiveHour": window(isLocal ? nil : usage?.fiveHour),
                "weekly": window(isLocal ? nil : usage?.weekly),
                "checkedAt": timestamp(usage?.checkedAt),
                "extras": extras,
                "note": usage?.note.map(safe) as Any? ?? NSNull(),
                "needsLogin": usage?.needsLogin ?? false,
            ])
        }
        let checkedAt = accounts.compactMap { readings[$0.id]?.checkedAt }.min()
        let groups: [[String: Any]] = providers.map { provider in
            ["provider": provider.rawValue, "name": provider.title,
             "color": colors[provider] ?? [], "accounts": entries[provider] ?? []]
        }
        return ["device": safe(device), "checkedAt": timestamp(checkedAt), "groups": groups]
    }

    static func webColors(_ provider: Account.Provider) -> [String] {
        let color = AIColors.color(provider, in: .app)
        return [NSAppearance.Name.aqua, .darkAqua].map { name in
            var hex = "#888888"
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                guard let rgb = color.usingColorSpace(.sRGB) else { return }
                hex = String(format: "#%02x%02x%02x",
                             Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
            }
            return hex
        }
    }
}

/// The phone page's update screen (Updater; tests give a stand-in). Only a person's tap on the page reaches it: no AI tool does.
protocol PhoneUpdates: AnyObject {
    func phoneState(at now: Date) -> [String: Any]
    /// nil when started; otherwise why not (answered as 409).
    func phoneCheck() -> String?
    func phoneInstall() -> String?
}

extension Updater: PhoneUpdates {}

final class PhoneServer: ObservableObject {
    static let shared = PhoneServer()
    static let port: UInt16 = 47380
    static let target = "http://127.0.0.1:\(port)"
    static let enabledKey = "phone.enabled", keyKey = "phone.key"
    @Published private(set) var running = false
    @Published private(set) var problem: String?
    weak var discussion: Discussion?   // set by start; tests set it directly
    weak var usage: PhoneUsage?        // set at app start; tests set a stand-in
    private var lastUsageRefresh: TimeInterval?
    weak var updates: PhoneUpdates?    // set at app start; tests set a stand-in
    // This Mac's nickname (Settings → other Macs' device name, else the Mac's name), so the page says which Mac it is.
    var deviceName: () -> String = { DeviceSync.shared.deviceName }
    private var server: RemoteServer?

    @Published private(set) var enabled: Bool

    init(enabled: Bool = UserDefaults.app.bool(forKey: PhoneServer.enabledKey)) {
        self.enabled = enabled
    }

    var key: String {
        if let key = UserDefaults.app.string(forKey: Self.keyKey), !key.isEmpty { return key }
        let key = RemoteHTTP.newKey()
        UserDefaults.app.set(key, forKey: Self.keyKey)
        return key
    }
    func address(_ status: TailnetStatus) -> String? { status.url.map { $0.absoluteString + "?k=" + key } }

    // After each Tailscale check: which other Macs are online, and what this Mac's page offers them (DeviceSync
    // writes it to the sync folder only while "Let my other Macs connect" is on there).
    func tailnetChecked(_ status: TailnetStatus) {
        let sync = DeviceSync.shared
        let online = status.state == .running ? Set(status.macs.filter(\.value).keys) : []
        if sync.onlineHosts != online { sync.onlineHosts = online }
        let open = enabled && running && status.state == .running && status.servesPhone
        sync.offerConnection(open ? status.host.flatMap { host in address(status).map {
            RemoteConnection(address: $0, host: host, app: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        } } : nil)
    }

    // App start: the page comes back if it was on (serve --bg stays set in Tailscale itself).
    func start(discussion: Discussion) {
        self.discussion = discussion
        guard enabled else { return }
        listen()
        // Tailscale forgets serve after `serve reset`: set it again unless another site took the address.
        PhoneAccess.shared.refresh { [weak self] status in
            guard let self, self.running, status.state == .running, status.served == nil else { return }
            self.serve(["serve", "--bg", "--https=443", Self.target])
        }
    }

    func setEnabled(_ on: Bool, status: TailnetStatus) {
        UserDefaults.app.set(on, forKey: Self.enabledKey)
        enabled = on
        problem = nil
        if on {
            listen()
            guard running else { return }
            // Another site already at https://<mac>/ is the user's: it is not replaced.
            if let other = status.served, other != Self.target {
                problem = L("tailscale serve가 이미 \(other)를 보여 주고 있어요. 그걸 끄면 켤 수 있어요.",
                            "tailscale serve already shows \(other). Turn that off first.")
                return
            }
            if !status.servesPhone { serve(["serve", "--bg", "--https=443", Self.target]) }
        } else {
            server?.stop(); server = nil; running = false
            DeviceSync.shared.offerConnection(nil)
            if status.servesPhone { serve(["serve", "--https=443", "off"]) }
        }
    }

    func newKey() {
        UserDefaults.app.set(RemoteHTTP.newKey(), forKey: Self.keyKey)
        if running { server?.stop(); server = nil; running = false; listen() }
        PhoneAccess.shared.refresh()   // the other Macs get the new address
    }

    private func listen() {
        guard server == nil else { return }
        let icon = NSApp.applicationIconImage.flatMap { Self.png($0, size: 180) }
        let server = RemoteServer(port: Self.port, key: key, page: { RemotePage.html() }, icon: icon) { [weak self] request in
            self?.handle(request) ?? .error(404, "not found")
        }
        do { try server.start(); self.server = server; running = true } catch {
            problem = L("폰 페이지를 열지 못했어요: ", "Could not start the phone page: ") + error.localizedDescription
        }
    }

    // After an update started from the phone page: true once this page answers its key on 127.0.0.1 and Tailscale
    // runs and serves it, so the phone can reach the new app. Calls back on the main queue.
    func reachable(_ done: @escaping (Bool) -> Void) {
        guard enabled, running else { return done(false) }
        Self.probe(port: Self.port, key: key) { ok in
            guard ok else { return done(false) }
            PhoneAccess.shared.refresh { status in done(status.state == .running && status.servesPhone) }
        }
    }

    // One GET /api/update over TCP: true for a 200 within `timeout`. Calls back on the main queue.
    static func probe(port: UInt16, key: String, timeout: TimeInterval = 5, done: @escaping (Bool) -> Void) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return done(false) }
        let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        let queue = DispatchQueue(label: "PhoneServer.probe")
        var finished = false
        func finish(_ ok: Bool) {
            guard !finished else { return }
            finished = true
            connection.cancel()
            DispatchQueue.main.async { done(ok) }
        }
        func read(_ sofar: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { chunk, _, end, error in
                let data = sofar + (chunk ?? Data())
                if let line = data.range(of: Data("\r\n".utf8)).map({ String(decoding: data[..<$0.lowerBound], as: UTF8.self) }) {
                    return finish(line.hasPrefix("HTTP/1.1 200"))
                }
                if end || error != nil { return finish(false) }
                read(data)
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let request = "GET /api/update HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Remote-Key: \(key)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                    if error != nil { finish(false) } else { read(Data()) }
                })
            case .failed, .waiting: finish(false)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
    }

    private func serve(_ args: [String]) {
        guard let cli = PhoneAccess.cliPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = args
            process.environment = PhoneAccess.cliEnvironment
            let err = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = err
            var message: String?
            do { try process.run(); process.waitUntilExit() } catch { message = error.localizedDescription }
            if message == nil, process.terminationStatus != 0 {
                message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            DispatchQueue.main.async {
                if let message { self.problem = "tailscale serve: " + message }
                PhoneAccess.shared.refresh()
            }
        }
    }

    // GET /api/chats[?n.<list>=<rows>] (with the inbox's 🔴/🟡), GET /api/search?q=, GET /api/chat/<id>[?open=1], GET /api/image/<chat>/<picture>,
    // POST /api/chat/new {text, images, project?, mentions?} → {id}, GET /api/chat/new[?project=] (its message box's @ and / lists),
    // POST /api/chat/<id>/send {text, images, mentions?}, POST /api/approval/<id> {allow},
    // POST /api/fold {key, folded} (a list section or project folder, shared with the Mac's sidebar),
    // GET /api/usage, POST /api/usage/refresh (returns the cached reading immediately),
    // GET /api/update, POST /api/update/check, POST /api/update/install (409 while an update step runs).
    func handle(_ request: RemoteRequest, now: Date = Date(),
                uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> RemoteResponse {
        let parts = request.path.split(separator: "/").map(String.init)   // ["api", ...]
        if parts.count > 1, parts[1] == "usage" {
            return handleUsage(request.method, Array(parts.dropFirst(2)), now: now, uptime: uptime)
        }
        if parts.count > 1, parts[1] == "update" { return handleUpdate(request.method, Array(parts.dropFirst(2)), now: now) }
        guard let discussion else { return .error(404, "not ready") }
        switch (request.method, parts.count > 1 ? parts[1] : "", parts.count) {
        case ("GET", "chats", 2):
            // ?n.<list key>=<rows>: the lists the phone lengthened with "Show more".
            let limits = request.query.reduce(into: [String: Int]()) { out, item in
                if item.key.hasPrefix("n."), let n = Int(item.value) { out[String(item.key.dropFirst(2))] = min(n, 1000) }
            }
            return .json(["sections": RemoteChats.list(discussion, limits: limits), "inbox": RemoteChats.inbox(discussion, now: now), "device": deviceName()])
        case ("GET", "search", 2):
            return .json(["results": RemoteChats.search(discussion, request.query["q"] ?? "")])
        case ("POST", "chat", 3) where parts[2] == "new":
            guard let body = request.json else { return .error(400, "bad request") }
            let photos = ((body["images"] as? [String]) ?? []).compactMap { Data(base64Encoded: $0) }
            let made = RemoteChats.create(discussion, project: body["project"] as? String, text: (body["text"] as? String) ?? "", photos: photos,
                                          mentions: (body["mentions"] as? [String]) ?? [])
            guard let id = made.id else { return .error(409, made.reason ?? L("보내지 못했어요.", "Could not send.")) }
            return .json(["id": id.uuidString])
        case ("GET", "chat", 3) where parts[2] == "new":
            return .json(RemoteChats.composer(discussion, project: request.query["project"]))
        case ("GET", "chat", 3):
            guard let room = UUID(uuidString: parts[2]), let chat = RemoteChats.chat(discussion, room, opened: request.query["open"] == "1") else {
                return .error(404, L("대화를 찾지 못했어요.", "Chat not found."))
            }
            return .json(chat.merging(["device": deviceName()]) { a, _ in a })
        case ("GET", "image", 4):
            guard let room = UUID(uuidString: parts[2]), let id = UUID(uuidString: parts[3]),
                  let url = RemoteChats.image(discussion, room, id: id), let data = try? Data(contentsOf: url) else { return .error(404, "no picture") }
            return RemoteResponse(type: "image/png", body: data)
        case ("POST", "chat", 4) where parts[3] == "send":
            guard let room = UUID(uuidString: parts[2]), let body = request.json else { return .error(400, "bad request") }
            let photos = ((body["images"] as? [String]) ?? []).compactMap { Data(base64Encoded: $0) }
            if let reason = RemoteChats.send(discussion, room: room, text: (body["text"] as? String) ?? "", photos: photos,
                                             mentions: (body["mentions"] as? [String]) ?? []) { return .error(409, reason) }
            return .json(["ok": true])
        case ("POST", "fold", 2):
            guard let key = request.json?["key"] as? String, let folded = request.json?["folded"] as? Bool else { return .error(400, "bad request") }
            return RemoteChats.fold(key, folded: folded) ? .json(["ok": true]) : .error(400, "unknown fold")
        case ("POST", "approval", 3):
            guard let id = UUID(uuidString: parts[2]), let allow = request.json?["allow"] as? Bool else { return .error(400, "bad request") }
            guard ProjectCenter.shared.requests.contains(where: { $0.id == id }) else {
                return .error(409, L("이미 처리된 요청이에요.", "This request was already decided."))
            }
            ProjectCenter.shared.decide(id, allow: allow)
            return .json(["ok": true])
        default:
            return .error(404, "not found")
        }
    }

    private func handleUsage(_ method: String, _ rest: [String], now: Date, uptime: TimeInterval) -> RemoteResponse {
        guard let usage else { return .error(404, "not ready") }
        switch (method, rest) {
        case ("GET", []):
            return .json(usage.phoneUsageSnapshot().json(at: now))
        case ("POST", ["refresh"]):
            let started = lastUsageRefresh.map { uptime - $0 >= 60 } ?? true
            var response = usage.phoneUsageSnapshot().json(at: now)
            response["refreshStarted"] = started
            if started {
                lastUsageRefresh = uptime
                usage.phoneRefreshUsage()
            }
            return .json(response)
        default:
            return .error(404, "not found")
        }
    }

    private func handleUpdate(_ method: String, _ rest: [String], now: Date) -> RemoteResponse {
        guard let updates else { return .error(404, "not ready") }
        switch (method, rest) {
        case ("GET", []):
            return .json(updates.phoneState(at: now))
        case ("POST", ["check"]), ("POST", ["install"]):
            if let reason = rest == ["check"] ? updates.phoneCheck() : updates.phoneInstall() { return .error(409, reason) }
            return .json(updates.phoneState(at: now))
        default:
            return .error(404, "not found")
        }
    }

    private static func png(_ image: NSImage, size: CGFloat) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

// Manage chats → "Connect iPhone…": the title says whether an iPhone is on the tailnet (as of the last check).
struct PhoneAccessMenuItem: View {
    @ObservedObject var access = PhoneAccess.shared
    var body: some View {
        let online = access.status.phones.contains(where: \.online)
        Button(action: { PhoneAccessWindow.shared.show() }) {
            Label(online ? L("iPhone 연결 (연결됨)…", "Connect iPhone (connected)…") : L("iPhone 연결…", "Connect iPhone…"),
                  systemImage: online ? "iphone.radiowaves.left.and.right" : "iphone")
        }
        .onAppear { access.refresh() }
    }
}

final class PhoneAccessWindow: NSObject, NSWindowDelegate {
    static let shared = PhoneAccessWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: PhoneAccessView(access: .shared).frame(width: 420))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.title = L("iPhone 연결", "Connect iPhone")
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        PhoneAccess.shared.watch(true)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { PhoneAccess.shared.watch(false) }
}

struct PhoneAccessView: View {
    @ObservedObject var access: PhoneAccess
    @ObservedObject var server = PhoneServer.shared
    private var status: TailnetStatus { access.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !access.checked {
                HStack { ProgressView().controlSize(.small); Text(L("Tailscale 확인 중…", "Checking Tailscale…")) }
            } else if status.state == .missing {
                notice(L("Tailscale이 없어요. tailscale.com/download에서 Mac용을 받아 iPhone과 같은 계정으로 로그인하세요.",
                         "Tailscale is not installed. Get it from tailscale.com/download and sign in with the same account as your iPhone."))
                Link(L("Tailscale 받기", "Get Tailscale"), destination: URL(string: "https://tailscale.com/download/mac")!)
            } else if status.state == .stopped {
                notice(L("Tailscale이 꺼져 있어요. 메뉴 막대의 Tailscale에서 연결하세요.", "Tailscale is off. Connect it from Tailscale in the menu bar."))
            } else {
                pageSection
                if server.enabled { qrSection }
                Divider()
                phonesSection
                Divider()
                checks
            }
            HStack {
                Spacer()
                Button(L("새로 고침", "Refresh")) { access.refresh() }
            }
        }
        .padding(20)
    }

    @ViewBuilder private var pageSection: some View {
        Toggle(isOn: Binding(get: { server.enabled }, set: { server.setEnabled($0, status: status) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("iPhone에서 채팅 쓰기", "Use chats on iPhone")).font(.headline)
                Text(L("켜 두면 이 Mac에서 앱이 켜져 있는 동안 폰에서 채팅 목록을 보고, 메시지·사진을 보내고, 승인할 수 있어요.",
                       "While on and this app runs, the iPhone can see the chats, send messages and photos, and approve requests."))
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        if let problem = server.problem {
            Text(problem).font(.system(size: 11)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
        }
        if server.enabled { MacConnectToggle() }
    }

    @ViewBuilder private var qrSection: some View {
        if let url = server.address(status).flatMap(URL.init(string:)), let image = TailnetStatus.qr(url.absoluteString) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 168, height: 168)
                    .padding(8).background(Color.white).cornerRadius(6)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("iPhone 카메라로 찍으세요", "Scan with the iPhone camera")).font(.headline)
                    Text(L("iPhone의 Tailscale이 켜져 있어야 열려요. 열리면 공유 → 홈 화면에 추가.",
                           "Opens only while Tailscale is on on the iPhone. Then Share → Add to Home Screen."))
                        .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(status.url?.absoluteString ?? "").font(.system(size: 11).monospaced()).textSelection(.enabled)
                    HStack {
                        Button(L("주소 복사", "Copy Address")) {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                        // The address carries the key: a new one locks out every phone that opened the old QR.
                        Button(L("새 QR", "New QR")) { server.newKey() }
                            .help(L("전에 찍은 폰은 다시 찍어야 열려요", "Phones that scanned the old QR must scan again"))
                    }
                    .controlSize(.small)
                }
            }
        } else {
            notice(L("MagicDNS 주소가 없어요. Tailscale 관리 콘솔 → DNS에서 MagicDNS를 켜세요.",
                     "No MagicDNS name. Turn on MagicDNS in the Tailscale admin console → DNS."))
        }
    }

    @ViewBuilder private var phonesSection: some View {
        Text("iPhone").font(.headline)
        if status.phones.isEmpty {
            Text(L("이 tailnet에 iPhone이 없어요. iPhone에 Tailscale을 깔고 같은 계정으로 로그인하세요.",
                   "No iPhone on this tailnet. Install Tailscale on the iPhone and sign in with the same account."))
                .font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(status.phones) { phone in
            HStack(spacing: 8) {
                Circle().fill(phone.online ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                Text(phone.name)
                Spacer()
                Text(phone.online ? L("연결됨", "Connected") : lastSeen(phone.lastSeen))
                    .font(.system(size: 12)).foregroundColor(phone.online ? .green : .secondary)
            }
        }
    }

    @ViewBuilder private var checks: some View {
        check(status.https, L("HTTPS 인증서", "HTTPS certificate"),
              status.https ? nil : L("관리 콘솔 → DNS → Enable HTTPS", "Admin console → DNS → Enable HTTPS"))
        check(status.servesPhone && server.running, L("웹 연결 (tailscale serve)", "Web access (tailscale serve)"),
              status.servesPhone && server.running ? nil
                : !server.enabled ? L("위 스위치를 켜면 연결돼요", "Turn on the switch above")
                : status.served.map { "→ " + $0 } ?? L("연결 중…", "Connecting…"))
    }

    private func check(_ ok: Bool, _ title: String, _ detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundColor(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12))
                if let detail { Text(detail).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }

    private func lastSeen(_ date: Date?) -> String {
        guard let date else { return L("오프라인", "Offline") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return L("오프라인 · ", "Offline · ") + f.localizedString(for: date, relativeTo: Date())
    }
}

// "Let my other Macs connect": this Mac's phone page address (with its key) goes in the sync folder, so the user's
// other Macs list this Mac under Other Macs and open it like the iPhone does. Off by default; needs Settings → Chat →
// Chats from other Macs (the sync folder) and the phone page on.
struct MacConnectToggle: View {
    @ObservedObject var sync = DeviceSync.shared

    var body: some View {
        Toggle(isOn: Binding(get: { sync.settings.enabled && sync.settings.sharesConnection }, set: { on in
            sync.settings.sharesConnection = on
            if on { PhoneAccess.shared.refresh() }
        })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("다른 Mac에서 연결 허용", "Let my other Macs connect")).font(.system(size: 12, weight: .medium))
                Text(sync.settings.enabled
                     ? L("이 페이지 주소(열쇠 포함)를 iCloud 동기화 폴더에 둬요. 같은 iCloud·Tailscale 계정의 다른 Mac이 Other Macs에서 이 Mac을 바로 열 수 있어요.",
                         "Puts this page's address (with its key) in the iCloud sync folder, so your other Macs on the same iCloud and Tailscale can open this Mac from Other Macs.")
                     : L("먼저 설정 → 채팅 → ‘다른 기기의 대화’를 켜 주세요.", "First turn on Settings → Chat → ‘Chats from other Macs’."))
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .disabled(!sync.settings.enabled)
    }
}
