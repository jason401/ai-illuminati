import Cocoa
import SwiftUI

// The Ollama models window (Settings → Accounts → Add account → Ollama models): the recommended list grouped by how
// well each model fits this Mac's memory, every model on ollama.com on request, a name typed in, and the models
// already on this Mac. Downloads run inside the app with a progress bar and can be cancelled; deleting frees disk.
final class LocalModelStore: ObservableObject {
    static let shared = LocalModelStore()

    struct Pull { var status: String; var fraction: Double?; let cancellation: DebateCancellation }

    @Published var catalog = LocalModel.catalog
    @Published var library: [LocalModel.LibraryModel] = []
    @Published var loadingLibrary = false
    @Published var installed: [LocalModel.Installed]?   // nil: Ollama is off or not installed
    @Published var pulls: [String: Pull] = [:]           // by normalized model name
    @Published var message: String?                      // the last failure, shown at the top
    @Published var query = ""
    @Published var showAll = false {
        didSet { if showAll { loadLibrary() } }
    }
    @Published var checking = false                      // looking up a typed name's size

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = LocalModel.installed(timeout: 2)
            DispatchQueue.main.async { self.installed = list }
            if LocalModel.refreshCatalog() { DispatchQueue.main.async { self.catalog = LocalModel.catalog } }
        }
    }

    func loadLibrary() {
        guard library.isEmpty, !loadingLibrary else { return }
        loadingLibrary = true
        DispatchQueue.global(qos: .userInitiated).async {
            let list = LocalModel.fetchLibrary()
            DispatchQueue.main.async {
                self.library = list
                self.loadingLibrary = false
                if list.isEmpty { self.message = L("ollama.com 목록을 읽지 못했어요. 추천 목록과 이름 입력은 그대로 쓸 수 있어요.", "Could not read the ollama.com list. The recommended list and typed names still work.") }
            }
        }
    }

    func isInstalled(_ model: String) -> Bool { installed?.contains { LocalModel.matches($0.name, model) } ?? false }
    func pulling(_ model: String) -> Pull? { pulls[LocalModel.normalized(model)] }

    // Asks for the exact size first (the registry also says whether the name exists), then the usual install.
    func install(_ name: String, app: AppModel) {
        let model = LocalModel.normalized(name)
        guard !model.isEmpty, model != ":latest", pulling(model) == nil else { return }
        if let entry = catalog.first(where: { LocalModel.same($0.name, model) }) { return app.addLocal(model, downloadGB: entry.sizeGB) }
        checking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let size = LocalModel.downloadGB(model)
            DispatchQueue.main.async {
                self.checking = false
                guard let size else {
                    self.message = L("'\(model)' 모델을 찾지 못했어요. 이름과 크기(예: qwen3:8b)를 확인해 주세요.", "Could not find “\(model)”. Check the name and size (for example qwen3:8b).")
                    return
                }
                app.addLocal(model, downloadGB: size)
            }
        }
    }

    func pull(_ name: String) {
        let model = LocalModel.normalized(name)
        guard pulls[model] == nil else { return }
        let cancellation = DebateCancellation()
        pulls[model] = Pull(status: L("시작하는 중…", "Starting…"), fraction: nil, cancellation: cancellation)
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let failure = LocalModel.pull(model, cancellation: cancellation) { status, fraction in
                DispatchQueue.main.async { self.pulls[model]?.status = status; self.pulls[model]?.fraction = fraction }
            }
            let list = LocalModel.installed(timeout: 2)
            DispatchQueue.main.async {
                self.pulls[model] = nil
                self.installed = list
                if let failure, !cancellation.isCancelled { self.message = "\(LocalModel.title(for: model)): \(failure)" }
            }
        }
    }

    func cancel(_ model: String) { pulling(model)?.cancellation.cancel() }

    func delete(_ name: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = LocalModel.delete(name)
            let list = LocalModel.installed(timeout: 2)
            DispatchQueue.main.async {
                self.installed = list
                if !ok { self.message = L("\(name) 파일을 지우지 못했어요. Ollama가 켜져 있는지 확인해 주세요.", "Could not delete \(name). Check that Ollama is running.") }
            }
        }
    }
}

final class LocalModelsWindow {
    static let shared = LocalModelsWindow()
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let host = NSHostingController(rootView: LocalModelsView(store: .shared, model: model).frame(width: 460, height: 580))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.title = L("Ollama 모델 (내 Mac)", "Ollama Models (this Mac)")
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        LocalModelStore.shared.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct LocalModelsView: View {
    @ObservedObject var store: LocalModelStore
    @ObservedObject var model: AppModel

    private var memory: Double { LocalModel.memoryGB }
    private var filter: String { store.query.trimmingCharacters(in: .whitespaces).lowercased() }
    private func shown(_ text: String...) -> Bool { filter.isEmpty || text.contains { $0.lowercased().contains(filter) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("이 Mac: 메모리 \(Int(memory.rounded()))GB · ", "This Mac: \(Int(memory.rounded())) GB memory · ") + ollamaState)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField(L("찾기, 또는 이름으로 받기 (예: qwen3:8b)", "Search, or download by name (e.g. qwen3:8b)"), text: $store.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { store.install(store.query, app: model) }
                Button(L("이름으로 받기", "Download")) { store.install(store.query, app: model) }
                    .disabled(filter.isEmpty || store.checking)
            }
            Toggle(L("모두 보기 (ollama.com 전체, 이 Mac에 너무 큰 모델 포함)", "Show all (everything on ollama.com, including models too big for this Mac)"), isOn: $store.showAll)
                .toggleStyle(.checkbox).font(.system(size: 11))
            if let message = store.message {
                HStack(alignment: .top) {
                    Text(message).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { store.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plainHit).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    installedSection
                    ForEach([LocalModel.Fit.good, .tight, .tooBig], id: \.rawValue) { fit in
                        if fit != .tooBig || store.showAll { recommended(fit) }
                    }
                    if store.showAll { librarySection }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(L("크기와 메모리는 대략이에요. 메모리에는 한 번에 한 모델만 올라가요.", "Sizes and memory are approximate. Only one model is in memory at a time."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private var ollamaState: String {
        if LocalModel.binary == nil { return L("Ollama 없음 (처음 받을 때 설치)", "Ollama not installed (installed with the first model)") }
        return store.installed == nil ? L("Ollama 꺼짐 (받을 때 켜요)", "Ollama off (starts when downloading)") : L("Ollama 켜짐", "Ollama running")
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
    }

    // What Ollama already has: in the list or not, with Delete.
    @ViewBuilder private var installedSection: some View {
        let list = (store.installed ?? []).filter { shown($0.name, LocalModel.title(for: $0.name)) }
        if !list.isEmpty {
            header(L("이 Mac에 있음", "On this Mac"))
            ForEach(list, id: \.name) { item in
                row(title: LocalModel.title(for: item.name), detail: item.name + " · " + String(format: "%.1fGB", Double(item.bytes) / 1e9),
                    vision: item.capabilities?.contains("vision")) {
                    if model.hasLocal(item.name) {
                        Image(systemName: "checkmark").foregroundStyle(.green).help(L("계정 목록에 있어요", "In the account list"))
                    } else {
                        Button(L("목록에 추가", "Add to List")) { model.addInstalled(item.name) }
                    }
                    Button { confirmDelete(item) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plainHit).foregroundStyle(.secondary).help(L("모델 파일 지우기", "Delete model files"))
                }
            }
        }
    }

    @ViewBuilder private func recommended(_ fit: LocalModel.Fit) -> some View {
        let list = store.catalog.filter { LocalModel.fit(downloadGB: $0.sizeGB, memoryGB: memory) == fit && shown($0.name, $0.title) }
        if !list.isEmpty {
            header(L("추천 · ", "Recommended · ") + fit.title)
            ForEach(list, id: \.name) { entry in
                row(title: entry.title,
                    detail: entry.name + String(format: L(" · 약 %.1fGB · 메모리 약 %.0fGB", " · about %.1f GB · about %.0f GB memory"), entry.sizeGB, LocalModel.memoryNeed(downloadGB: entry.sizeGB).rounded(.up)),
                    note: entry.summary, vision: entry.vision) { action(entry.name) }
            }
        }
    }

    // Every model family on ollama.com: pick a size from the menu (the exact size is checked before downloading).
    @ViewBuilder private var librarySection: some View {
        header(L("ollama.com 전체", "Everything on ollama.com"))
        if store.loadingLibrary {
            ProgressView().controlSize(.small).padding(10)
        }
        ForEach(store.library.filter { shown($0.name, $0.summary) }, id: \.name) { family in
            row(title: family.name, detail: family.capabilities.joined(separator: " · "), note: family.summary, vision: family.capabilities.contains("vision")) {
                Menu {
                    ForEach(family.sizes, id: \.self) { size in sizeButton(family.name + ":" + size, tag: size) }
                } label: { Text(L("받기", "Get")) }
                .fixedSize()
            }
        }
    }

    private func sizeButton(_ name: String, tag: String) -> some View {
        let gb = LocalModel.estimatedGB(tag) ?? 0
        return Button(String(format: "%@ · ~%.1fGB · %@", tag, gb, LocalModel.fit(downloadGB: gb, memoryGB: memory).title)) { store.install(name, app: model) }
            .disabled(model.hasLocal(name) || store.pulling(name) != nil)
    }

    // Download, the progress of one under way, or a check when it is already in the list.
    @ViewBuilder private func action(_ name: String) -> some View {
        if let pull = store.pulling(name) {
            VStack(alignment: .trailing, spacing: 2) {
                if let fraction = pull.fraction { ProgressView(value: fraction).frame(width: 90) } else { ProgressView().controlSize(.small) }
                Text(pull.fraction.map { "\(Int($0 * 100))%" } ?? pull.status).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 90)
            }
            Button { store.cancel(name) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plainHit).foregroundStyle(.secondary)
                .help(L("받기 취소", "Cancel download"))
        } else if model.hasLocal(name) && store.isInstalled(name) {
            Image(systemName: "checkmark").foregroundStyle(.green).help(L("받아서 계정 목록에 있어요", "Downloaded and in the account list"))
        } else if store.isInstalled(name) {
            Button(L("목록에 추가", "Add to List")) { model.addInstalled(name) }
        } else {
            Button(L("받기", "Get")) { store.install(name, app: model) }
        }
    }

    private func row<Trailing: View>(title: String, detail: String, note: String = "", vision: Bool?, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if vision == true {
                        Image(systemName: "photo").font(.system(size: 9)).foregroundStyle(.secondary).help(L("그림을 읽어요", "Reads pictures"))
                    }
                }
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                if !note.isEmpty { Text(note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 6)
            trailing()
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    private func confirmDelete(_ item: LocalModel.Installed) {
        let alert = NSAlert()
        alert.messageText = L("\(item.name) 파일을 지울까요?", "Delete \(item.name)?")
        alert.informativeText = L("디스크 \(String(format: "%.1f", Double(item.bytes) / 1e9))GB가 비워지고, 이 모델을 쓰는 계정 줄도 목록에서 빠져요. 나중에 다시 받을 수 있어요.",
                                  "Frees \(String(format: "%.1f", Double(item.bytes) / 1e9)) GB of disk and removes its entries from the account list. You can download it again later.")
        alert.addButton(withTitle: L("지우기", "Delete"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.accounts.removeAll { $0.provider == .ollama && LocalModel.matches(item.name, LocalModel.variant($0).model) }
        store.delete(item.name)
    }
}
