import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI
import AIAccounts
import AILocalization
import AIChat
import AIRuntime

// Every AI's chat settings in one window: AIs down the side (models on this Mac too), settings across.
final class AISettingsWindow {
    static let shared = AISettingsWindow()
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let host = NSHostingController(rootView: AISettingsGrid(model: model)
                .frame(minWidth: 640, idealWidth: 900, minHeight: 360, idealHeight: 760))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.title = L("AI별 설정", "Settings by AI")
            w.setContentSize(NSSize(width: 900, height: 760))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AISettingsGrid: View {
    @ObservedObject var model: AppModel
    @StateObject private var permissions = MacPermissionStatus()

    private enum Column: CaseIterable {
        case model, effort, auto, enterprise, pictures, menuBar, local

        var title: String {
            switch self {
            case .model: return L("모델", "Model")
            case .effort: return L("생각 깊이", "Thinking")
            case .auto: return L("자동으로 부르기", "Picked automatically")
            case .enterprise: return L("엔터프라이즈", "Enterprise")
            case .pictures: return L("그림 담당", "Picture maker")
            case .menuBar: return L("메뉴바", "Menu bar")
            case .local: return L("Ollama 쓰기", "Use Ollama")
            }
        }
        var help: String {
            switch self {
            case .model: return L("이 AI가 답할 때 쓰는 모델. 자동은 그 CLI의 기본값이에요.", "The model this AI answers with. Auto is the CLI's default.")
            case .effort: return L("답하기 전에 얼마나 생각할지. 자동은 보통 중간, 프로젝트·TODO 작업·검수·회의·여러 의견·ask_ai는 높음, 다시 시도하거나 다른 AI가 도운 TODO와 1시간 넘게 잡고 나눈 TODO의 마무리는 아주 높음이에요. 목록은 이 AI의 모델이 받는 단계뿐이에요. 깊을수록 사용량과 시간이 늘어요. Gemini에서 모델을 고르면 그 모델 이름의 깊이를 따라요.",
                                   "How much this AI thinks before answering. Auto is medium; high for project or TODO work, review, meetings, several views and ask_ai; extra high for a TODO retried or helped by another AI and for the finish of a split planned at an hour or more. The list holds only the levels this AI's model takes. Deeper uses more usage and time. A Gemini model you pick keeps the level in its name.")
            case .auto: return L("앱이 스스로 AI를 고를 때 후보가 돼요: 자동으로 답할 AI, 회의·여러 의견, ask_ai, 맡을 AI를 정하지 않은 프로젝트·TODO 작업. 꺼도 채팅에서 직접 고르거나 @로 부르면 답해요. 프로젝트 작업·검수는 Claude·ChatGPT만 해요.",
                                 "A candidate when the app picks by itself: who answers an automatic chat, meetings and several views, ask_ai, project or TODO work nobody was picked for. Off: still answers when picked in a chat or called with @. Project work and review are Claude and ChatGPT only.")
            case .enterprise: return L("엔터프라이즈(학교·회사) 계정: 직접 잠근 Enterprise 방에는 이름이 같은 엔터프라이즈 계정과 내 Mac 모델만 참여해요.",
                                       "Enterprise (school or work) account: a chat you lock as Enterprise is answered only by Enterprise accounts of the same name and models on this Mac.")
            case .pictures: return L("켜 둔 AI가 다른 AI 대신 그림을 그려요. ChatGPT·Gemini는 이미지 생성 도구로 그리고(처음엔 켜져 있어요), Claude·내 Mac 모델은 SVG로 그려요(처음엔 꺼져 있어요). 켜 둔 AI 중 사용량이 가장 많이 남은 쪽이 맡고, 엔터프라이즈 방은 같은 조직의 AI에게만 맡겨요. 숫자가 정확해야 하는 그래프는 각 AI가 직접 그려요.",
                                     "Checked AIs draw pictures for the other AIs. ChatGPT and Gemini use their image tool (checked at first); Claude and models on this Mac draw SVG (unchecked at first). The checked AI with the most usage left draws, and in an Enterprise chat only one of its organization. Charts that must be exact are drawn by each AI.")
            case .menuBar: return L("메뉴바 사용량 표시에 이 계정을 보여요.", "Shows this account in the menu bar usage.")
            case .local: return L("내 Mac의 Ollama 모델 전체에 한 번에 적용돼요. 끄면 @·투표·대타에서 빠지고 메모리에서 내려요.",
                                  "Applies to every Ollama model on this Mac at once. Off: no @, votes or stand-in, and unloaded.")
            }
        }
    }

    // Only the columns that apply to at least one AI in the list.
    private var columns: [Column] {
        Column.allCases.filter { column in model.accounts.contains { applies(column, $0) } }
    }

    private func applies(_ column: Column, _ account: Account) -> Bool {
        switch column {
        case .model, .effort, .enterprise: return account.provider != .ollama
        case .auto: return Discussion.meets(account) || account.provider == .ollama
        case .pictures: return true
        case .menuBar: return true
        case .local: return account.provider == .ollama
        }
    }

    var body: some View {
        ScrollView(.vertical) { content.padding(14) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("AI마다 채팅에서 어떻게 쓸지 한 곳에서 켜고 꺼요. 바꾸면 바로 저장돼요. 열 제목에 마우스를 올리면 설명이 나와요.",
                   "Switch how each AI is used in chats, all in one place. Changes save at once. Hover a column title for what it does."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.accounts.isEmpty {
                Text(L("계정이 없어요. 설정 → 계정에서 추가하세요.", "No accounts. Add one in Settings → Accounts."))
                    .foregroundStyle(.secondary).padding(16)
            } else {
                table {
                    Grid(alignment: .center, horizontalSpacing: 18, verticalSpacing: 8) {
                        GridRow {
                            Text(L("AI", "AI")).font(.system(size: 11, weight: .semibold)).gridColumnAlignment(.leading)
                            ForEach(columns, id: \.self) { column in
                                Text(column.title).font(.system(size: 11, weight: .semibold))
                                    .help(column.help)
                            }
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(model.accounts, id: \.id) { account in
                            GridRow {
                                accountLabel(account)
                                ForEach(columns, id: \.self) { column in
                                    cell(column, account)
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                Text(L("계정 추가·이름·순서·로그인은 설정 → 계정에서 해요.", "Add, rename, reorder and sign in under Settings → Accounts."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if !model.autoTeamPicks.isEmpty {
                    Button(L("자동으로 부르기 기본값으로", "Picked automatically: use default")) { model.autoTeamPicks = [:] }
                        .controlSize(.small)
                }
            }
            Divider().padding(.vertical, 4)
            if !model.accounts.isEmpty { capabilities }
            permissionRows
            Divider().padding(.vertical, 4)
            Text(L("모든 AI 공통", "For all AIs")).font(.system(size: 13, weight: .semibold))
            AICommonSettings(model: model).frame(maxWidth: 560, alignment: .leading)
        }
    }

    private func table<Content: View>(@ViewBuilder _ rows: () -> Content) -> some View {
        ScrollView(.horizontal) { rows().padding(12) }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07)))
    }

    private func accountLabel(_ account: Account) -> some View {
        HStack(spacing: 6) {
            Circle().fill(account.provider.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.name).lineLimit(1)
                Text(account.provider == .ollama ? L("내 Mac", "This Mac") : account.provider.title)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 150, alignment: .leading)
    }

    private var capabilities: some View {
        let columns = AICapability.allCases.filter { capability in model.accounts.contains { applies(capability, $0) } }
        return VStack(alignment: .leading, spacing: 6) {
            Text(L("AI가 쓸 수 있는 기능", "What AIs can use")).font(.system(size: 13, weight: .semibold))
            Text(L("선택한 값은 저장되며, 기능이 연결되면 적용돼요.",
                   "Choices are saved and take effect when the features are connected."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            table {
                Grid(alignment: .center, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text(L("AI", "AI")).font(.system(size: 11, weight: .semibold)).gridColumnAlignment(.leading)
                        ForEach(columns, id: \.self) { capability in
                            Text(capabilityTitle(capability)).font(.system(size: 11, weight: .semibold))
                                .help(capabilityHelp(capability))
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(model.accounts, id: \.id) { account in
                        GridRow {
                            accountLabel(account)
                            ForEach(columns, id: \.self) { capability in
                                capabilityCell(capability, account)
                            }
                        }
                    }
                }
            }
        }
    }

    private func capabilityTitle(_ capability: AICapability) -> String {
        switch capability {
        case .terminal: return L("터미널", "Terminal")
        case .web: return L("인터넷", "Web")
        case .screen: return L("화면 보기", "View screen")
        case .input: return L("마우스·키보드", "Mouse & keyboard")
        case .apps: return L("앱 열기", "Open apps")
        case .chrome: return L("크롬", "Chrome")
        }
    }

    private func capabilityHelp(_ capability: AICapability) -> String {
        switch capability {
        case .terminal: return L("실행이 허용된 채팅에서 AI가 터미널 명령을 써요.", "Lets the AI use terminal commands in chats that allow execution.")
        case .web: return L("AI의 웹 검색과 웹페이지 읽기 도구를 써요.", "Lets the AI use its web search and page reading tools.")
        case .screen: return L("이 Mac의 화면이나 창을 봐요. 지금은 ‘켬’에서만 쓸 수 있어요. ‘물어보기’는 준비 중이에요.",
                               "Views the screen or a window on this Mac. Available with On. Ask is coming later.")
        case .input: return L("이 Mac에서 마우스와 키보드를 써요.", "Uses the mouse and keyboard on this Mac.")
        case .apps: return L("이 Mac에서 앱을 열어요.", "Opens apps on this Mac.")
        case .chrome: return L("Claude in Chrome 확장으로 크롬을 써요.", "Uses Chrome through the Claude in Chrome extension.")
        }
    }

    private func applies(_ capability: AICapability, _ account: Account) -> Bool {
        switch capability {
        case .terminal: return account.provider != .ollama
        case .web: return true
        case .screen, .input, .apps: return account.provider == .claude || account.provider == .codex
        case .chrome: return account.provider == .claude
        }
    }

    @ViewBuilder private func capabilityCell(_ capability: AICapability, _ account: Account) -> some View {
        if applies(capability, account) {
            CapabilityMenu(account: account, capability: capability, title: capabilityTitle(capability))
                .help(capabilityHelp(capability) + enterpriseWarning(capability, account))
        } else {
            Text("—").foregroundStyle(.tertiary)
                .accessibilityLabel(L("해당 없음", "Not applicable"))
                .help(unavailableHelp(capability, account))
        }
    }

    private func enterpriseWarning(_ capability: AICapability, _ account: Account) -> String {
        guard account.isSchool else { return "" }
        switch capability {
        case .screen:
            return "\n" + L("화면 내용이 학교·회사 계정으로 보내져요.", "Screen content is sent to your school or work account.")
        case .input:
            return "\n" + L("화면을 보며 조작할 때 화면 내용이 학교·회사 계정으로 보내져요.",
                            "When the AI views your screen to control it, screen content is sent to your school or work account.")
        case .chrome:
            return "\n" + L("크롬에서 읽은 페이지 내용이 학교·회사 계정으로 보내져요.",
                            "Page content read in Chrome is sent to your school or work account.")
        case .terminal, .web, .apps: return ""
        }
    }

    private func unavailableHelp(_ capability: AICapability, _ account: Account) -> String {
        if capability == .chrome { return L("크롬 연결은 Claude에서만 쓸 수 있어요.", "Chrome integration is available only for Claude.") }
        if account.provider == .gemini {
            return L("Gemini CLI는 헤드리스 모드에서 앱의 맥 조작 도구를 쓸 수 없어요.",
                     "The Gemini CLI cannot use the app’s Mac controls in headless mode.")
        }
        return L("Ollama는 이 기능을 쓸 수 없어요.", "This feature is unavailable for Ollama.")
    }

    private var permissionRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            permissionRow(L("화면 기록", "Screen Recording"), granted: permissions.screen, pane: "Privacy_ScreenCapture",
                          request: permissions.didRequestScreen ? nil : permissions.requestScreen)
            permissionRow(L("손쉬운 사용", "Accessibility"), granted: permissions.accessibility, pane: "Privacy_Accessibility")
            if !permissions.screen {
                Text(L("화면 기록을 허용한 뒤 앱을 다시 시작해야 할 수 있어요.",
                       "You may need to restart the app after granting Screen Recording access."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: permissions.refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permissions.refresh() }
    }

    private func permissionRow(_ title: String, granted: Bool, pane: String,
                               request: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title).fontWeight(.semibold)
            Text(granted ? L("허용됨", "Allowed") : L("허용 안 됨", "Not allowed")).foregroundStyle(.secondary)
            if !granted {
                if let request {
                    let requestTitle = L("권한 요청", "Request access")
                    Button(requestTitle, action: request)
                        .controlSize(.small)
                        .accessibilityLabel(title + " · " + requestTitle)
                }
                let buttonTitle = L("시스템 설정 열기", "Open System Settings")
                Button(buttonTitle) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
                .accessibilityLabel(title + " · " + buttonTitle)
            }
        }
        .font(.system(size: 11))
    }

    @ViewBuilder private func cell(_ column: Column, _ account: Account) -> some View {
        if !applies(column, account) {
            Text("—").foregroundStyle(.tertiary)
        } else {
            switch column {
            case .model:
                CloudModelMenu(account: account)
            case .effort:
                CloudEffortMenu(account: account).help(column.help)
            case .auto:
                let off = account.provider == .ollama && !model.localEnabled
                toggle(column, account, Binding(get: { Discussion.autoPicked(account, picks: model.autoTeamPicks) },
                                                set: { model.autoTeamPicks[account.id] = $0 }))
                    .disabled(off)
                    .help(off ? L("Ollama가 꺼져 있어요", "Ollama is off") : column.help)
            case .enterprise:
                toggle(column, account, Binding(get: { model.accounts.first { $0.id == account.id }?.isSchool ?? false },
                                                set: { model.setSchool(account.id, $0) }))
            case .pictures:
                let off = account.provider == .ollama && !model.localEnabled
                toggle(column, account, Binding(get: { model.isPictureMaker(account) }, set: { model.setPictureMaker(account, $0) }))
                    .disabled(off)
                    .help(off ? L("Ollama가 꺼져 있어요", "Ollama is off") : column.help)
            case .menuBar:
                toggle(column, account, Binding(get: { !model.menuBarHidden.contains(account.id) },
                                                set: { on in if on { model.menuBarHidden.remove(account.id) } else { model.menuBarHidden.insert(account.id) } }))
            case .local:
                toggle(column, account, $model.localEnabled)
            }
        }
    }

    private func toggle(_ column: Column, _ account: Account, _ isOn: Binding<Bool>) -> some View {
        Toggle(account.name + " · " + column.title, isOn: isOn)
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
    }
}

private final class MacPermissionStatus: ObservableObject {
    @Published private(set) var screen = false
    @Published private(set) var accessibility = false
    @Published private(set) var didRequestScreen = false

    func requestScreen() {
        didRequestScreen = true
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }

    func refresh() {
        screen = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
    }
}

private struct CapabilityMenu: View {
    let account: Account
    let capability: AICapability
    let title: String
    @StateObject private var state: CapabilityPick
    private var choices: [CapabilityRule] {
        capability == .terminal || capability == .web ? [.off, .on] : CapabilityRule.allCases
    }

    init(account: Account, capability: AICapability, title: String) {
        self.account = account; self.capability = capability; self.title = title
        let rule = AICapabilities.rule(account, capability)
        let onOff = capability == .terminal || capability == .web
        _state = StateObject(wrappedValue: CapabilityPick(onOff && rule == .ask ? .on : rule))
    }

    var body: some View {
        Menu {
            Picker(title, selection: Binding(get: { state.rule }, set: { rule in
                AICapabilities.set(rule, for: account, capability)
                state.rule = rule
            })) {
                ForEach(choices, id: \.self) { Text(ruleTitle($0)).tag($0) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Text(ruleTitle(state.rule)).lineLimit(1)
        }
        .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
        .accessibilityLabel(account.name + " · " + title)
        .accessibilityValue(ruleTitle(state.rule))
    }

    private func ruleTitle(_ rule: CapabilityRule) -> String {
        switch rule {
        case .off: return L("끔", "Off")
        case .ask: return L("물어보기", "Ask")
        case .on: return L("켬", "On")
        }
    }
}

private final class CapabilityPick: ObservableObject {
    @Published var rule: CapabilityRule
    init(_ rule: CapabilityRule) { self.rule = rule }
}

// The Thinking column: Auto (nothing saved) or any level this account's model takes (CloudEffort.levels(for:)).
private struct CloudEffortMenu: View {
    let account: Account
    @StateObject private var state = CloudEffortPick()   // @State needs a macro plugin the command line build lacks

    static func title(_ level: String?) -> String {
        switch level {
        case "low": return L("낮음", "Low")
        case "medium": return L("중간", "Medium")
        case "high": return L("높음", "High")
        case "xhigh": return L("아주 높음", "Extra high")
        case "max": return L("최대", "Max")
        case "ultra": return L("울트라", "Ultra")
        default: return L("자동", "Auto")
        }
    }

    var body: some View {
        Group {
            if state.offered.isEmpty {
                // A Gemini model picked by name ("… (High)") holds its own level.
                Text(L("모델대로", "By model")).font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Menu {
                    Picker(L("생각 깊이", "Thinking"), selection: Binding(get: { state.picked ?? "" }, set: { value in
                        state.picked = value.isEmpty ? nil : value
                        CloudEffort.set(state.picked, for: account)
                    })) {
                        ForEach([""] + state.offered, id: \.self) { Text(Self.title($0.isEmpty ? nil : $0)).tag($0) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                } label: {
                    // A pick the model no longer takes runs lowered (CloudEffort.level): show what runs.
                    let runs = state.picked.flatMap { _ in CloudEffort.level(account, hard: false) }
                    Text(Self.title(state.picked) + (runs != nil && runs != state.picked ? " → " + Self.title(runs) : "")).lineLimit(1)
                }
                .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
            }
        }
        .onAppear(perform: read)
        // Picking another model in the Model column changes the levels offered.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in read() }
    }

    private func read() {
        let picked = CloudEffort.picked(account), offered = CloudEffort.levels(for: account)
        if picked != state.picked { state.picked = picked }
        if offered != state.offered { state.offered = offered }
    }
}

private final class CloudEffortPick: ObservableObject {
    @Published var picked: String?
    @Published var offered: [String] = []
}
