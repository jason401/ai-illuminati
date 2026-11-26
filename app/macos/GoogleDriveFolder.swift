import AppKit
import SwiftUI
import AILocalization
import AIChat
import AIIntegrations

// Shared folders' Google Drive: Google's official Drive MCP server (AIIntegrations' GoogleDrive), added from the
// section's + menu with the Mac's sign-in sheet. Its tools reach the AIs as an outside MCP server
// (ExternalMCPTools.swift). Like a local shared folder: the pencil lets the AIs change Drive, the eye pauses it,
// right-click signs in again or disconnects (the login is also revoked at Google).
enum GoogleDriveFolder {
    static func register() {
        FolderSources.shared.list.append(FolderSource(id: GoogleDrive.server, addTitle: L("Google Drive…", "Google Drive…"),
                                                      add: { GoogleDrive.shared.connect() }, rows: { AnyView(GoogleDriveRow()) }))
    }
}

struct GoogleDriveRow: View {
    @ObservedObject private var drive = GoogleDrive.shared
    @ObservedObject private var external = ExternalMCP.shared
    @ObservedObject private var folds = SidebarFold.shared
    @StateObject private var flash = ConnectedFlash()   // @State needs a macro plugin the command line build lacks

    private var added: Bool { external.servers.contains { $0.name == GoogleDrive.server } }
    private var status: ExternalMCP.Status? { external.status[GoogleDrive.server] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if folds.isFolded("shared") {
            } else if added {
                row
            } else if drive.signingIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).frame(width: 18)
                    Text(L("Google 로그인 중…", "Signing in to Google…")).foregroundColor(.secondary)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 13)).padding(.horizontal, 10).frame(height: 30)
            }
            if !folds.isFolded("shared"), let error = drive.error {
                Text(error).font(.system(size: 11)).foregroundColor(.red).lineLimit(3)
                    .padding(.horizontal, 10).padding(.bottom, 4)
            }
        }
        .onAppear { count() }
        .onChange(of: external.servers) { _ in count() }
        .onChange(of: drive.connectedAt) { date in if date != nil { flash.show() } }
    }

    // The section shows its empty hint only while nothing is listed.
    private func count() { FolderSources.shared.counts[GoogleDrive.server] = added ? 1 : 0 }

    private var row: some View {
        let paused = !ExternalMCP.isOn(GoogleDrive.server)
        let writable = GoogleDrive.isWritable(status)
        let needsLogin = status?.signedIn == false || status?.state == .needsLogin
        return HStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.icloud").foregroundColor(paused ? .secondary : .accentColor).frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text("Google Drive").lineLimit(1).foregroundColor(paused ? .secondary : .primary)
                if let note = note(paused: paused, needsLogin: needsLogin) {
                    Text(note.text).font(.system(size: 10)).foregroundColor(note.color).lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            if needsLogin && !paused {
                Button(L("로그인", "Sign In")) { drive.connect() }
                    .buttonStyle(.link).font(.system(size: 11)).disabled(drive.signingIn)
            } else if !paused {
                Button(action: { drive.setWritable(!writable) }) {
                    Image(systemName: writable ? "pencil" : "pencil.slash").font(.system(size: 12, weight: .medium))
                        .foregroundColor(writable ? .accentColor : .secondary.opacity(0.6)).frame(width: 24, height: 24)
                }
                .buttonStyle(.plainHit)
                .help(writable ? L("쓰기 허용: AI가 Drive에 파일·폴더를 만들고, 복사하고, 새 버전을 올릴 수 있어요. 눌러서 읽기만",
                                   "Writable: the AIs may create files and folders, copy and upload new versions in Drive. Click for read only")
                               : L("읽기만: AI가 Drive를 찾고 읽기만 해요. 눌러서 쓰기 허용", "Read only: the AIs only search and read Drive. Click to allow changes"))
                .accessibilityLabel(writable ? L("읽기만으로", "Make read only") : L("쓰기 허용", "Allow changes"))
            }
            Button(action: { ExternalMCP.shared.setOn(GoogleDrive.server, paused) }) {
                Image(systemName: paused ? "eye.slash" : "eye").font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(paused ? 0.6 : 0.9)).frame(width: 24, height: 24)
            }
            .buttonStyle(.plainHit)
            .help(paused ? L("공유 꺼짐: AI가 Drive를 못 봐요. 눌러서 켜기", "Not shared: the AIs cannot see Drive. Click to share")
                         : L("공유 중: AI가 Google 공식 Drive MCP로 Drive를 써요. 눌러서 끄기", "Shared: the AIs use Drive through Google's official Drive MCP. Click to stop"))
            .accessibilityLabel(paused ? L("공유 켜기", "Share") : L("공유 끄기", "Stop sharing"))
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10).frame(minHeight: 30)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(string: "https://drive.google.com")!) }
        .help(L("Google 공식 Drive MCP로 연결됨. 두 번 눌러 브라우저에서 Drive 열기", "Connected through Google's official Drive MCP. Double-click to open Drive in the browser"))
        .contextMenu {
            Button(L("브라우저에서 Drive 열기", "Open Drive in Browser")) { NSWorkspace.shared.open(URL(string: "https://drive.google.com")!) }
            Button(paused ? L("공유 켜기", "Share") : L("공유 끄기", "Stop sharing")) { ExternalMCP.shared.setOn(GoogleDrive.server, paused) }
            Button(writable ? L("읽기만으로", "Make read only") : L("쓰기 허용", "Allow changes")) { drive.setWritable(!writable) }
            Button(L("다시 로그인", "Sign In Again")) { drive.connect() }.disabled(drive.signingIn)
            Divider()
            Button(L("연결 끊기", "Disconnect"), role: .destructive) { disconnect() }
        }
    }

    private func note(paused: Bool, needsLogin: Bool) -> (text: String, color: Color)? {
        if flash.shown && !needsLogin { return (L("연결됐어요", "Connected") + (drive.account.map { " · " + $0 } ?? ""), .green) }
        if paused { return (L("공유 꺼짐", "Not shared"), .secondary) }
        if drive.signingIn { return (L("Google 로그인 중…", "Signing in to Google…"), .secondary) }
        if needsLogin { return (L("다시 로그인이 필요해요", "Sign-in needed"), .orange) }
        switch status?.state {
        case .failed?: return (status?.message ?? L("연결하지 못했어요", "Could not connect"), .orange)
        case .connecting?, nil: return (L("연결 중…", "Connecting…"), .secondary)
        default: return drive.account.map { ($0, .secondary) }
        }
    }

    private func disconnect() {
        let alert = NSAlert()
        alert.messageText = L("Google Drive 연결을 끊을까요?", "Disconnect Google Drive?")
        alert.informativeText = L("AI가 더는 Drive를 못 써요. 이 Mac의 로그인을 지우고 Google에서도 연결을 취소해요. Drive의 파일은 그대로예요.",
                                  "The AIs can no longer use Drive. The login is deleted from this Mac and revoked at Google. Your Drive files stay as they are.")
        alert.addButton(withTitle: L("연결 끊기", "Disconnect"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { drive.disconnect() }
    }
}

// "Connected · account" for a few seconds after a sign-in that worked.
final class ConnectedFlash: ObservableObject {
    @Published private(set) var shown = false
    private var token = 0
    func show() {
        token += 1
        let mine = token
        withAnimation { shown = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.token == mine else { return }
            withAnimation { self.shown = false }
        }
    }
}
