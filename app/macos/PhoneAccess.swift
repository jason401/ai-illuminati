import AppKit
import SwiftUI
import CoreImage
import AILocalization

// iPhone access over Tailscale (docs: the chat's mobile plan): this Mac's tailnet address as a QR the iPhone camera opens,
// and whether the user's iPhones are on the tailnet now. Read only: it runs `tailscale status`/`serve status` and changes
// nothing (no serve, no ACL). "Connected" is Tailscale's own Online flag: the phone is on the tailnet, not that a page is open.
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
    var url: URL? { host.map { URL(string: "https://\($0)/") } ?? nil }

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

    func refresh() {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            let cli = Self.cliPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
            let next = cli.map { TailnetStatus.parse(status: Self.run($0, ["status", "--json"]), serve: Self.run($0, ["serve", "status", "--json"])) }
                ?? TailnetStatus()
            DispatchQueue.main.async {
                self.busy = false
                self.checked = true
                if self.status != next { self.status = next }
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
                qrSection
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

    @ViewBuilder private var qrSection: some View {
        if let url = status.url, let image = TailnetStatus.qr(url.absoluteString) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 168, height: 168)
                    .padding(8).background(Color.white).cornerRadius(6)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("iPhone 카메라로 찍으세요", "Scan with the iPhone camera")).font(.headline)
                    Text(L("iPhone의 Tailscale이 켜져 있어야 열려요. 열리면 공유 → 홈 화면에 추가.",
                           "Opens only while Tailscale is on on the iPhone. Then Share → Add to Home Screen."))
                        .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(url.absoluteString).font(.system(size: 11).monospaced()).textSelection(.enabled)
                    Button(L("주소 복사", "Copy Address")) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
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
        check(status.served != nil, L("웹 연결 (tailscale serve)", "Web access (tailscale serve)"),
              status.served.map { "→ " + $0 } ?? L("켜진 게 없어서 지금은 QR을 찍어도 페이지가 안 열려요", "Nothing is served, so the QR opens no page yet"))
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
