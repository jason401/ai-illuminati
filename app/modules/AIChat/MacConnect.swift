import AppKit
import SwiftUI
import WebKit
import AILocalization

// Other Macs → a Mac: its phone page (the one the iPhone opens, with its key from remote.json in the sync folder:
// DeviceSync.swift) shown here like on the iPhone, in the notes' place or in a phone-sized window. Everything the
// page does (send, new chat, search, approvals) goes to that Mac directly; Tailscale keeps the address in the tailnet.
// Each Mac's pages share one data store that keeps nothing past this launch, apart from every other site.
final class MacConnect: ObservableObject {
    static let shared = MacConnect()
    static let panelWidth: CGFloat = 400
    @Published var shown: String?                 // the Mac in the side panel
    @Published var copiesOpen: Set<String> = []   // Macs whose saved read-only copies are listed in the sidebar
    private var pages: [String: MacPage] = [:]    // the panel's page per Mac, kept so closing the panel does not reload it
    private var windows: [String: NSWindow] = [:]
    private var closings: [String: NSObjectProtocol] = [:]
    private var stores: [String: WKWebsiteDataStore] = [:]

    private func store(_ id: String) -> WKWebsiteDataStore {
        if let store = stores[id] { return store }
        let store = WKWebsiteDataStore.nonPersistent()
        stores[id] = store
        return store
    }

    // The panel's page, made again when the Mac's address changed (a new key there).
    func page(_ device: RemoteDevice) -> MacPage? {
        guard let url = device.connection?.url else { return nil }
        if let page = pages[device.id], page.url == url { return page }
        let page = MacPage(url: url, store: store(device.id))
        pages[device.id] = page
        return page
    }

    func toggle(_ device: RemoteDevice) { shown = shown == device.id ? nil : device.id }

    func toggleCopies(_ id: String) {
        if copiesOpen.contains(id) { copiesOpen.remove(id) } else { copiesOpen.insert(id) }
    }

    // A phone-sized window of its own (one per Mac), so several Macs can be open at once.
    func openWindow(_ device: RemoteDevice) {
        if shown == device.id { shown = nil }
        if let window = windows[device.id] { window.makeKeyAndOrderFront(nil); return }
        guard let url = device.connection?.url else { return }
        let page = MacPage(url: url, store: store(device.id))
        let window = NSWindow(contentViewController: NSHostingController(rootView: MacPageView(page: page)))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = device.name
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 320, height: 480)
        window.setContentSize(NSSize(width: Self.panelWidth, height: 820))
        window.center()
        window.setFrameAutosaveName("mac-connect." + device.id)
        windows[device.id] = window
        closings[device.id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.windows[device.id] = nil
            if let closing = self.closings.removeValue(forKey: device.id) { NotificationCenter.default.removeObserver(closing) }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// One open page: the web view and whether it loaded.
final class MacPage: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let url: URL
    let webView: WKWebView
    @Published private(set) var loading = true
    @Published private(set) var failure: String?

    init(url: URL, store: WKWebsiteDataStore) {
        self.url = url
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false   // the page's own back (Esc, swipe) moves between its screens
        reload()
    }

    func reload() {
        failure = nil; loading = true
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12))
    }

    // The page stays on its Mac: links elsewhere open in the browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let target = action.request.url else { return decisionHandler(.cancel) }
        if target.host?.lowercased() == url.host?.lowercased(), target.scheme == "https" || target.scheme == "about" {
            return decisionHandler(.allow)
        }
        if ["http", "https", "mailto"].contains(target.scheme ?? "") { NSWorkspace.shared.open(target) }
        decisionHandler(.cancel)
    }

    // target="_blank" links.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let target = action.request.url, ["http", "https", "mailto"].contains(target.scheme ?? "") { NSWorkspace.shared.open(target) }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { reload() }

    private func failed(_ error: Error) {
        loading = false
        if (error as NSError).code == NSURLErrorCancelled { return }
        failure = error.localizedDescription
    }

    // The photo button (<input type=file>).
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        let done: (NSApplication.ModalResponse) -> Void = { completionHandler($0 == .OK ? panel.urls : nil) }
        if let window = webView.window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: L("확인", "OK"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
}

private struct MacWebHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

// The page, with "Not connected · Try again" over it when it did not load.
struct MacPageView: View {
    @ObservedObject var page: MacPage
    var showCopies: (() -> Void)?

    var body: some View {
        ZStack {
            MacWebHost(webView: page.webView)
            if let failure = page.failure {
                VStack(spacing: 10) {
                    Image(systemName: "desktopcomputer.trianglebadge.exclamationmark").font(.system(size: 28)).foregroundColor(.secondary)
                    Text(L("연결 안 됨", "Not connected")).font(.system(size: 15, weight: .semibold))
                    Text(L("그 Mac이 꺼져 있거나 잠들었거나, Tailscale이 꺼져 있을 수 있어요.", "That Mac may be off or asleep, or Tailscale is off."))
                        .font(.system(size: 12)).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Text(failure).font(.system(size: 11)).foregroundColor(.secondary).multilineTextAlignment(.center).lineLimit(3)
                    HStack {
                        Button(L("다시 시도", "Try Again")) { page.reload() }
                        if let showCopies { Button(L("저장된 사본 보기", "Show Saved Copies"), action: showCopies) }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            } else if page.loading {
                ProgressView().controlSize(.small)
            }
        }
    }
}

// The side panel (the notes' place): the Mac's name and state, Reload, New window, Close.
struct MacPanel: View {
    let device: RemoteDevice
    @ObservedObject var sync: DeviceSync
    @ObservedObject var connect = MacConnect.shared

    var body: some View {
        let reach = sync.reach(device)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                MacReachDot(reach: reach)
                Text(device.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                WindowDragRegion().frame(maxWidth: .infinity, maxHeight: .infinity)
                if let page = connect.page(device) {
                    Button(action: { page.reload() }) { Image(systemName: "arrow.clockwise").font(.system(size: 11)).frame(width: 22, height: 22) }
                        .buttonStyle(.plainHit).foregroundColor(.secondary).help(L("새로 고침", "Reload"))
                    Button(action: { connect.openWindow(device) }) { Image(systemName: "macwindow.badge.plus").font(.system(size: 11)).frame(width: 22, height: 22) }
                        .buttonStyle(.plainHit).foregroundColor(.secondary).help(L("새 창으로", "Open in New Window"))
                }
                Button(action: { connect.shown = nil }) { Image(systemName: "xmark").font(.system(size: 11)).frame(width: 22, height: 22) }
                    .buttonStyle(.plainHit).foregroundColor(.secondary).help(L("닫기", "Close"))
            }
            .padding(.horizontal, 12).frame(height: 40)
            Divider().opacity(0.5)
            if let page = connect.page(device) {
                if reach == .offline {
                    Text(L("Tailscale에서 이 Mac이 오프라인으로 보여요. 잠들었으면 깨워 주세요.", "Tailscale shows this Mac offline. Wake it if it is asleep."))
                        .font(.system(size: 11)).foregroundColor(.orange).padding(.horizontal, 12).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                MacPageView(page: page, showCopies: device.chats.isEmpty ? nil : { connect.copiesOpen.insert(device.id) })
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "iphone.slash").font(.system(size: 26)).foregroundColor(.secondary)
                    Text(L("연결할 수 없어요", "Can't connect")).font(.system(size: 15, weight: .semibold))
                    Text(L("그 Mac에서 설정 → 채팅 → iPhone 연결… 의 ‘iPhone에서 채팅 쓰기’와 ‘다른 Mac에서 연결 허용’을 켜 주세요.",
                           "On that Mac, turn on ‘Use chats on iPhone’ and ‘Let my other Macs connect’ in Settings → Chat → Connect iPhone…."))
                        .font(.system(size: 12)).foregroundColor(.secondary).multilineTextAlignment(.center)
                    if !device.chats.isEmpty {
                        Button(L("저장된 사본 보기", "Show Saved Copies")) { connect.copiesOpen.insert(device.id) }
                    }
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: MacConnect.panelWidth)
        .frame(maxHeight: .infinity)
    }
}

// Green: can connect · gray: off, asleep or not on Tailscale · yellow: its phone page (or connecting) is off.
struct MacReachDot: View {
    let reach: MacReach
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .help(reach == .ready ? L("연결할 수 있어요", "Ready to connect")
                  : reach == .offline ? L("꺼져 있거나 잠들었어요", "Off or asleep")
                  : reach == .pageOff ? L("그 Mac의 연결이 꺼져 있어요", "Connecting is off on that Mac")
                  : L("확인하는 중…", "Checking…"))
    }
    private var color: Color {
        switch reach {
        case .ready: return .green
        case .offline, .unknown: return Color.secondary.opacity(0.5)
        case .pageOff: return .yellow
        }
    }
}
