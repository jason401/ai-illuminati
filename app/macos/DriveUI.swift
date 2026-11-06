import Cocoa
import AuthenticationServices
import SwiftUI
import UniformTypeIdentifiers

// Google Drive in the chat sidebar, under Shared folders: connect (read only), the Drive folders the AIs may read
// (each with an eye to pause it), and the folder picker. The login lives in GoogleAuth (Keychain); the gate that
// keeps the AIs inside these folders is DriveLink.isAllowed.
final class DriveCenter: ObservableObject {
    static let shared = DriveCenter()
    @Published private(set) var connected = false
    @Published private(set) var needsReconnect = false
    @Published private(set) var signingIn = false
    @Published private(set) var email: String?
    @Published var picking = false
    let picker = DrivePicker()
    @Published var folders: [DriveFolder] = DriveLink.folders {
        didSet {
            DriveLink.folders = folders
            let kept = paused.intersection(folders.map(\.id))
            if kept != paused { paused = kept }
        }
    }
    @Published var paused: Set<String> = DriveLink.pausedFolders {
        didSet { DriveLink.pausedFolders = paused }
    }
    @Published var on: Bool = DriveLink.shared.enabled {
        didSet { if DriveLink.shared.enabled != on { DriveLink.shared.enabled = on } }
    }
    private var attempt = UUID()

    private init() { refresh() }

    func refresh() {
        connected = GoogleAuth.shared.connected
        needsReconnect = !connected && GoogleAuth.shared.needsReconnect
        if on != DriveLink.shared.enabled { on = DriveLink.shared.enabled }
        guard connected else { email = nil; return }
        if email == nil {
            DispatchQueue.global(qos: .utility).async {
                let found = DriveLink.shared.accountEmail()
                DispatchQueue.main.async { if self.connected { self.email = found } }
            }
        }
    }

    // First connection uses the public Google client; own Desktop client remains an advanced fallback.
    // Reconnect: the saved client, straight to the browser.
    func connect() {
        if let saved = GoogleAuth.shared.publicClientID { return publicSignIn(saved) }
        if needsReconnect { return signIn { try GoogleAuth.shared.beginReauthorization(completion: $0) } }
        if !GoogleAuth.builtInClientID.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("Google 드라이브 연결 (읽기 전용)", "Connect Google Drive (read only)")
            alert.informativeText = L("구글 로그인 후 AI가 읽을 폴더를 골라요. 읽은 내용은 답하는 AI로 보내져요. 로그인 정보는 이 Mac의 키체인에만 저장돼요. 확인되지 않은 앱 경고가 나오면 고급 → AI Illuminati(으)로 이동을 누르세요.", "Sign in, then choose the folders your AI may read. Read content goes to the responding AI; login credentials stay in this Mac's Keychain. If Google shows an unverified app warning, choose Advanced → Go to AI Illuminati.")
            alert.addButton(withTitle: L("구글로 로그인", "Sign in with Google"))
            alert.addButton(withTitle: L("취소", "Cancel"))
            if alert.runModal() == .alertFirstButtonReturn { publicSignIn(GoogleAuth.builtInClientID) }
            return
        }
        connectOwnClient()
    }

    func connectOwnClient() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Google 드라이브 연결 (읽기 전용)", "Connect Google Drive (read only)")
        alert.informativeText = L("""
            처음 한 번만 해요 (10분쯤).
            1. Google Cloud에서 새 프로젝트를 만들고 Google Drive API와 Google Sheets API를 켜요.
            2. OAuth 동의 화면: 외부, 앱 이름 AI Illuminati, 범위 drive.readonly. 그다음 "앱 게시"를 눌러요. 안 누르면 7일마다 다시 로그인해야 해요.
            3. 사용자 인증 정보 → OAuth 클라이언트 ID 만들기 → 데스크톱 앱 → JSON 다운로드.
            4. 그 파일을 고르면 브라우저에 구글 로그인이 떠요. "확인되지 않은 앱" 경고는 고급 → 이동으로 넘어가요.

            API 키가 아니에요. 로그인 정보는 이 Mac의 키체인에만 있고 AI에게 가지 않아요. 연결한 뒤 AI가 읽을 드라이브 폴더를 골라요. 읽은 내용은 그때 답하는 AI로 보내져요.
            """, """
            One time only (about 10 minutes).
            1. In Google Cloud, create a project and enable the Google Drive API and Google Sheets API.
            2. OAuth consent screen: External, app name AI Illuminati, scope drive.readonly. Then press "Publish app"; otherwise you must sign in again every 7 days.
            3. Credentials → Create OAuth client ID → Desktop app → download the JSON.
            4. Choose that file and Google's sign-in opens in the browser. Pass the "unverified app" warning with Advanced → Go to.

            This is not an API key. The login stays in this Mac's Keychain and never goes to an AI. After connecting, choose the Drive folders the AIs may read. What they read goes to whichever AI answers.
            """)
        alert.addButton(withTitle: L("파일 고르기…", "Choose File…"))
        alert.addButton(withTitle: L("Google Cloud 열기", "Open Google Cloud"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: break
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/apis/credentials")!)
            return
        default: return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = L("Google Cloud에서 받은 OAuth 클라이언트 파일(client_secret_….json)", "The OAuth client file from Google Cloud (client_secret_….json)")
        panel.prompt = L("연결", "Connect")
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        signIn { try GoogleAuth.shared.beginAuthorization(clientJSON: data, completion: $0) }
    }

    private func publicSignIn(_ clientID: String) {
        let current = UUID(); attempt = current; signingIn = true
        do {
            try GoogleAuth.shared.beginBuiltInAuthorization(present: GoogleBrowserSession(), clientID: clientID) { result in
                DispatchQueue.main.async {
                    guard self.attempt == current else { return }
                    self.signingIn = false; self.refresh()
                    switch result {
                    case .success: if self.folders.isEmpty { self.picking = true }
                    case .failure(let error): self.show(error)
                    }
                }
            }
        } catch { signingIn = false; show(error) }
    }

    private func signIn(_ begin: (@escaping (Result<Void, Error>) -> Void) throws -> URL) {
        let current = UUID()
        attempt = current
        do {
            let url = try begin { result in
                DispatchQueue.main.async {
                    guard self.attempt == current else { return }
                    self.signingIn = false
                    self.refresh()
                    switch result {
                    case .success: if self.folders.isEmpty { self.picking = true }
                    case .failure(let error): self.show(error)
                    }
                }
            }
            signingIn = true
            NSWorkspace.shared.open(url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) {   // nobody finished it in the browser
                if self.attempt == current && self.signingIn { self.cancelSignIn() }
            }
        } catch { show(error) }
    }

    func cancelSignIn() {
        attempt = UUID()
        signingIn = false
        GoogleAuth.shared.cancelAuthorization()
        refresh()
    }

    func disconnect() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Google 드라이브 연결을 끊을까요?", "Disconnect Google Drive?")
        alert.informativeText = L("이 Mac의 로그인 정보를 지우고 구글에도 접근 취소를 보내요. 고른 폴더 목록은 남아요.",
                                  "Removes the login from this Mac and revokes it at Google. The folder list stays.")
        alert.addButton(withTitle: L("연결 끊기", "Disconnect"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do { try GoogleAuth.shared.disconnect() } catch { failure = error }
            DispatchQueue.main.async {
                self.refresh()
                if let failure { self.show(failure) }
            }
        }
    }

    func add(_ folder: DriveFolder) {
        if !folders.contains(where: { $0.id == folder.id }) { folders.append(folder) }
    }

    func togglePaused(_ id: String) {
        if paused.contains(id) { paused.remove(id) } else { paused.insert(id) }
    }

    private func show(_ error: Error) {
        let text = (error as? GoogleFailure)?.message ?? error.localizedDescription
        if text.contains("cancelled") { return }   // the user stopped it
        let alert = NSAlert()
        alert.messageText = L("Google 드라이브", "Google Drive")
        alert.informativeText = text.contains("administrator")
            ? L("학교·회사 계정 관리자가 이 앱을 막아 둔 것 같아요. 개인 계정으로 연결해 보세요.", "Your school or work administrator seems to block this app. Try a personal account.")
            : text
        alert.runModal()
    }
}

// The sidebar section under Shared folders.
struct DriveSidebarSection: View {
    @ObservedObject var center = DriveCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SidebarHeader(title: "Google Drive") {
                if center.signingIn {
                    ProgressView().controlSize(.mini).frame(width: 22, height: 22)
                } else {
                    Button(action: { center.connected ? (center.picking = true) : center.connect() }) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plainHit).foregroundColor(.secondary)
                    .help(center.connected ? L("AI가 읽을 드라이브 폴더 추가", "Add a Drive folder the AIs can read")
                                           : L("Google 드라이브 연결 (읽기 전용)", "Connect Google Drive (read only)"))
                    .accessibilityLabel(center.connected ? L("드라이브 폴더 추가", "Add Drive folder") : L("드라이브 연결", "Connect Drive"))
                }
            }
            if center.signingIn {
                hint(L("구글 로그인 창에서 허용을 눌러 주세요 · 취소", "Press Allow in the Google sign-in window · Cancel"), symbol: "safari") { center.cancelSignIn() }
            } else if center.needsReconnect {
                hint(L("다시 연결 필요", "Reconnect needed"), symbol: "exclamationmark.triangle", color: .orange) { center.connect() }
            } else if !center.connected {
                hint(L("드라이브 연결 · 읽기 전용", "Connect Drive · read only"), symbol: "cloud") { center.connect() }
            } else {
                if !center.on {
                    hint(L("꺼 둠 · 눌러서 켜기", "Off · click to turn on"), symbol: "power") { center.on = true }
                }
                if center.folders.isEmpty {
                    hint(L("폴더 추가 · AI가 읽을 드라이브 폴더", "Add a folder · the AIs read only these"), symbol: "folder.badge.plus") { center.picking = true }
                }
                ForEach(center.folders, id: \.id) { folder in row(folder) }
            }
        }
        .sheet(isPresented: $center.picking) { DriveFolderPicker(center: center) }
        .onAppear { center.refresh() }
    }

    private func hint(_ text: String, symbol: String, color: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: symbol)
                .font(.system(size: 12)).foregroundColor(color).lineLimit(1)
                .padding(.horizontal, 10).frame(height: 28, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plainHit)
        .contextMenu { accountMenu }
    }

    // Double-click opens it in the browser; the eye pauses it (it stays listed); right-click to remove.
    private func row(_ folder: DriveFolder) -> some View {
        let paused = center.paused.contains(folder.id)
        let link = URL(string: "https://drive.google.com/drive/folders/" + folder.id)!
        return HStack(spacing: 8) {
            Image(systemName: "cloud").foregroundColor(.secondary).frame(width: 18)
            Text(folder.name).lineLimit(1).foregroundColor(paused || !center.on ? .secondary : .primary)
            Spacer(minLength: 2)
            Button(action: { center.togglePaused(folder.id) }) {
                Image(systemName: paused ? "eye.slash" : "eye").font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(paused ? 0.6 : 0.9)).frame(width: 24, height: 24)
            }
            .buttonStyle(.plainHit)
            .help(paused ? L("공유 꺼짐: AI가 이 폴더를 못 봐요. 눌러서 켜기", "Not shared: the AIs cannot see it. Click to share")
                         : L("공유 중 (읽기 전용): 일반 채팅의 AI가 볼 수 있어요. 눌러서 끄기", "Shared (read only): the AI in plain chat can see it. Click to stop"))
            .accessibilityLabel(paused ? L("공유 켜기", "Share") : L("공유 끄기", "Stop sharing"))
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10).frame(height: 30)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(link) }
        .help(folder.name + (center.email.map { "\n" + $0 } ?? "") + "\n" + L("두 번 눌러 브라우저에서 열기 · 읽기 전용", "Double-click to open in the browser · read only"))
        .contextMenu {
            Button(L("브라우저에서 열기", "Open in Browser")) { NSWorkspace.shared.open(link) }
            Button(paused ? L("공유 켜기", "Share") : L("공유 끄기", "Stop sharing")) { center.togglePaused(folder.id) }
            Button(L("드라이브 폴더에서 빼기", "Remove from Drive folders"), role: .destructive) { center.folders.removeAll { $0.id == folder.id } }
            Divider()
            accountMenu
        }
    }

    @ViewBuilder private var accountMenu: some View {
        Button(L("내 등록 파일로 연결…", "Connect with Own Client File…")) { center.connectOwnClient() }
        if center.connected {
        Button(L("폴더 추가…", "Add Folder…")) { center.picking = true }
        Button(center.on ? L("드라이브 끄기", "Turn Drive Off") : L("드라이브 켜기", "Turn Drive On")) { center.on.toggle() }
        Button(L("다시 연결…", "Reconnect…")) { center.connect() }
        Button(L("연결 끊기…", "Disconnect…")) { center.disconnect() }
        }
    }
}

// Browse My Drive / Shared with me and add folders, or paste a folder link. (State lives in an ObservableObject:
// this Mac's Command Line Tools cannot build SwiftUI's @State macro.)
final class DrivePicker: ObservableObject {
    @Published var path: [DriveFolder] = []
    @Published var items: [DriveFolder] = []
    @Published var loading = false
    @Published var error: String?
    @Published var link = ""
    static let myDrive = DriveFolder(id: "root", name: L("내 드라이브", "My Drive"))
    static let shared = DriveFolder(id: "shared", name: L("공유 문서함", "Shared with me"))

    func open(_ folder: DriveFolder) { path.append(folder); load() }
    func back() { if !path.isEmpty { path.removeLast() }; load() }

    func load() {
        error = nil
        guard let current = path.last else { items = [Self.myDrive, Self.shared]; loading = false; return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try DriveLink.shared.childFolders(of: current.id) }
            DispatchQueue.main.async {
                guard self.path.last?.id == current.id else { return }
                self.loading = false
                switch result {
                case .success(let found): self.items = found
                case .failure(let failure): self.items = []; self.error = (failure as? GoogleFailure)?.message ?? failure.localizedDescription
                }
            }
        }
    }

    // My Drive itself is added under its real ID, so the gate can recognize it as a parent.
    func add(_ folder: DriveFolder, to center: DriveCenter) {
        guard folder.id == Self.myDrive.id else { center.add(folder); return }
        resolve("root", to: center)
    }

    func addLink(to center: DriveCenter) {
        let value = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        resolve(value, to: center) { self.link = "" }
    }

    private func resolve(_ value: String, to center: DriveCenter, then: @escaping () -> Void = {}) {
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try DriveLink.shared.folder(from: value) }
            DispatchQueue.main.async {
                switch result {
                case .success(let folder): center.add(folder); then()
                case .failure(let failure): self.error = (failure as? GoogleFailure)?.message ?? failure.localizedDescription
                }
            }
        }
    }
}

struct DriveFolderPicker: View {
    @ObservedObject var center: DriveCenter
    @ObservedObject var model = DriveCenter.shared.picker

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("AI가 읽을 Google 드라이브 폴더", "Google Drive folders the AIs may read")).font(.system(size: 14, weight: .semibold))
            Text(L("고른 폴더와 그 안의 하위 폴더만 읽을 수 있어요 (읽기 전용).", "Only these folders and their subfolders can be read (read only)."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button(action: model.back) { Image(systemName: "chevron.left").frame(width: 22, height: 22) }
                    .buttonStyle(.plainHit).disabled(model.path.isEmpty)
                    .accessibilityLabel(L("뒤로", "Back"))
                Text(model.path.isEmpty ? "Google Drive" : model.path.map(\.name).joined(separator: " › "))
                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.head)
                Spacer()
                if let current = model.path.last, current.id != DrivePicker.shared.id {
                    addButton(current, title: L("이 폴더 추가", "Add This Folder"))
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.loading {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(20)
                    } else if model.items.isEmpty {
                        Text(L("하위 폴더가 없어요.", "No subfolders.")).font(.system(size: 12)).foregroundStyle(.secondary).padding(10)
                    }
                    ForEach(model.loading ? [] : model.items, id: \.id) { folder in
                        HStack(spacing: 8) {
                            Image(systemName: folder.id == DrivePicker.shared.id ? "person.2" : "folder").foregroundColor(.secondary).frame(width: 18)
                            Text(folder.name).lineLimit(1)
                            Spacer(minLength: 4)
                            if folder.id != DrivePicker.shared.id { addButton(folder, title: L("추가", "Add")) }
                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundColor(.secondary)
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 8).frame(height: 30)
                        .contentShape(Rectangle())
                        .onTapGesture { model.open(folder) }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 6) {
                TextField(L("또는 드라이브 폴더 링크 붙여넣기", "Or paste a Drive folder link"), text: $model.link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.addLink(to: center) }
                Button(L("추가", "Add")) { model.addLink(to: center) }
                    .disabled(model.link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error = model.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            HStack {
                Text(L("추가한 폴더 \(center.folders.count)개", "\(center.folders.count) folders added")).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(L("완료", "Done")) { center.picking = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460, height: 480)
        .onAppear { model.path = []; model.link = ""; model.load() }
    }

    private func addButton(_ folder: DriveFolder, title: String) -> some View {
        let added = center.folders.contains { $0.id == folder.id }
        return Button(added ? L("추가됨", "Added") : title) { model.add(folder, to: center) }
            .controlSize(.small).disabled(added)
    }
}

// ASWebAuthenticationSession owns the browser callback; no screen capture or embedded web view.
private final class GoogleBrowserSession: NSObject, GoogleAuthPresenter, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var completion: ((Result<URL, Error>) -> Void)?
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) ?? ASPresentationAnchor()
    }
    func start(_ url: URL, scheme: String, completion: @escaping (Result<URL, Error>) -> Void) {
        self.completion = completion
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { [weak self] url, error in
            guard let self else { return }
            if let url { self.finish(.success(url)) }
            else { self.finish(.failure(GoogleFailure(message: (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin ? "Google sign-in was cancelled." : "Could not open Google sign-in."))) }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        if !session.start() { finish(.failure(GoogleFailure(message: "Could not open Google sign-in."))) }
    }
    private func finish(_ result: Result<URL, Error>) {
        let callback = completion; completion = nil; session = nil; callback?(result)
    }
    func cancel() {
        let stop = { self.session?.cancel(); self.finish(.failure(GoogleFailure(message: "Google sign-in was cancelled."))) }
        if Thread.isMainThread { stop() } else { DispatchQueue.main.async(execute: stop) }
    }
}
