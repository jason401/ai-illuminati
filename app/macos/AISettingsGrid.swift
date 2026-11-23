import AppKit
import SwiftUI
import AIAccounts
import AILocalization
import AIChat
import AIRuntime

// Every AI's chat settings in one window: AIs down the side (models on this Mac too), settings across.
// It only shows and switches the settings that already live in AppModel; a cell that does not apply shows a dash.
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
                ScrollView(.horizontal) {
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
                                HStack(spacing: 6) {
                                    Circle().fill(account.provider.color).frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(account.name).lineLimit(1)
                                        Text(account.provider == .ollama ? L("내 Mac", "This Mac") : account.provider.title)
                                            .font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(minWidth: 150, alignment: .leading)
                                ForEach(columns, id: \.self) { column in
                                    cell(column, account)
                                }
                            }
                        }
                    }
                    .padding(12)
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07)))
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
            Text(L("모든 AI 공통", "For all AIs")).font(.system(size: 13, weight: .semibold))
            AICommonSettings(model: model).frame(maxWidth: 560, alignment: .leading)
        }
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
