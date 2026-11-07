import Foundation

// Models on this Mac, through Ollama (https://ollama.com). Any Ollama model can be an entry in Accounts: picked in
// the Ollama models window (a recommended list kept in app/resources/local_models.json and refreshed from GitHub,
// every model on ollama.com, or a name typed in), downloaded and deleted there. The first two entries (Gemma 4 E4B
// and 12B) keep their old ids so their chats and order stay. Only one model is ever in memory: answers take turns
// (one at a time across all chats) and the others are unloaded before one loads. No account, key or usage limit:
// the app talks to Ollama on 127.0.0.1:11434 and nothing leaves the Mac. In plain chat it answers when called with
// @, and when every cloud account is out of usage; it also votes. It reads linked files through the app (the
// workspace_reads requests) and cannot change files or search the web.
enum LocalModel {
    struct Variant: Equatable {
        let id: String       // the account's id
        let model: String    // Ollama's name
        let title: String
    }
    // Entries made before any Ollama model could be picked: their ids say which model they are.
    static let legacy = [
        Variant(id: "ollama-local", model: "gemma4:e4b", title: "Gemma 4 E4B"),
        Variant(id: "ollama-12b", model: "gemma4:12b", title: "Gemma 4 12B"),
    ]
    static func variant(_ account: Account) -> Variant {
        if let model = account.model { return Variant(id: account.id, model: model, title: title(for: model)) }
        return legacy.first { $0.id == account.id } ?? legacy[0]
    }
    static func id(for model: String) -> String {
        legacy.first { same($0.model, model) }?.id ?? "ollama:" + normalized(model)
    }
    static func account(for model: String) -> Account {
        let title = title(for: model)
        return Account(id: id(for: model), provider: .ollama, name: L("\(title) (내 Mac)", "\(title) (this Mac)"), dir: nil, model: normalized(model))
    }

    // "qwen3" means "qwen3:latest"; Ollama may list a model with a longer tag ("gemma4:e4b-it-q4").
    static func normalized(_ name: String) -> String {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.contains(":") ? lower : lower + ":latest"
    }
    static func same(_ a: String, _ b: String) -> Bool { normalized(a) == normalized(b) }
    static func matches(_ listed: String, _ model: String) -> Bool {
        same(listed, model) || listed.lowercased().hasPrefix(normalized(model) + "-")
    }

    // The recommended list's name, else "qwen3:8b" → "Qwen3 8B".
    static func title(for model: String) -> String {
        if let entry = catalog.first(where: { same($0.name, model) }) { return entry.title }
        let parts = model.split(separator: ":", maxSplits: 1).map(String.init)
        var base = parts[0].split(separator: "/").last.map(String.init) ?? parts[0]
        base = base.prefix(1).uppercased() + base.dropFirst()
        guard parts.count == 2, parts[1] != "latest" else { return base }
        return base + " " + parts[1].uppercased()
    }

    static var server = URL(string: "http://127.0.0.1:11434")!   // tests point this at a fake server
    static var registry = URL(string: "https://registry.ollama.ai")!
    static var library = URL(string: "https://ollama.com/library")!
    static var catalogURL = URL(string: "https://raw.githubusercontent.com/jason401/ai-illuminati/stable/app/resources/local_models.json")!
    static let context = 32768   // Ollama's default (4K) is too short for a chat with files

    // Set from the menu bar (on/off) and Settings → Accounts (how long it stays in memory after a reply).
    static var enabled: Bool { UserDefaults.standard.object(forKey: "localEnabled") as? Bool ?? true }
    static let keepAliveChoices = [0, 2, 5, 10]   // minutes; 0 = unload right after the reply
    static var keepAlive: Int {
        guard let value = UserDefaults.standard.object(forKey: "localKeepAlive") as? Int, keepAliveChoices.contains(value) else { return 5 }
        return value
    }
    static func keepAliveName(_ minutes: Int) -> String {
        minutes == 0 ? L("답 끝나면 바로", "Right after each reply") : L("\(minutes)분", "\(minutes) min")
    }

    // MARK: Which models, and which fit this Mac

    // One model of the recommended list.
    struct Entry: Codable, Equatable {
        let name: String
        let title: String
        let sizeGB: Double   // download
        var vision: Bool?
        var note: String?
        var noteKo: String?
        var summary: String { (L(noteKo ?? note ?? "", note ?? "")) }
    }
    private struct CatalogFile: Codable { let version: Int; let models: [Entry] }

    static func decodeCatalog(_ data: Data) -> [Entry]? {
        guard let file = try? JSONDecoder().decode(CatalogFile.self, from: data), !file.models.isEmpty else { return nil }
        return file.models
    }
    static var cachedCatalog: URL { URL(fileURLWithPath: AccountStore.supportDir + "/local_models.json") }
    static var bundledCatalog: URL? {
        let base = ProcessInfo.processInfo.environment["AI_ILLUMINATI_TEST_RESOURCES"].map { URL(fileURLWithPath: $0) } ?? Bundle.main.resourceURL
        return base?.appendingPathComponent("local_models.json")
    }
    // The last list fetched from GitHub, else the one the app was built with.
    static var catalog: [Entry] = {
        for url in [cachedCatalog, bundledCatalog].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url), let list = decodeCatalog(data) { return list }
        }
        return []
    }()

    // Fetches the latest recommended list (new models need no new app). Keeps the current one when offline.
    static func refreshCatalog(timeout: TimeInterval = 8) -> Bool {
        guard let data = fetch(URLRequest(url: catalogURL), timeout: timeout), let list = decodeCatalog(data) else { return false }
        try? FileManager.default.createDirectory(atPath: AccountStore.supportDir, withIntermediateDirectories: true)
        try? data.write(to: cachedCatalog, options: .atomic)
        catalog = list
        return true
    }

    enum Fit: Int, Comparable {
        case good, tight, tooBig
        static func < (a: Fit, b: Fit) -> Bool { a.rawValue < b.rawValue }
        var title: String {
            switch self {
            case .good: return L("잘 돌아가요", "Runs well")
            case .tight: return L("빠듯해요 (다른 앱을 닫아야 할 수 있음)", "Tight (may need other apps closed)")
            case .tooBig: return L("이 Mac에는 너무 커요", "Too big for this Mac")
            }
        }
    }
    static var memoryGB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }
    // Memory while answering: the weights plus room for a 32K conversation (rough, but right in size).
    static func memoryNeed(downloadGB: Double) -> Double { downloadGB * 1.1 + 1.5 }
    // macOS lets the GPU use roughly two thirds to three quarters of memory, and the Mac needs the rest.
    static func fit(downloadGB: Double, memoryGB: Double = memoryGB) -> Fit {
        let need = memoryNeed(downloadGB: downloadGB)
        if need <= memoryGB * 0.55 { return .good }
        return need <= memoryGB * 0.75 ? .tight : .tooBig
    }

    // A size as ollama.com shows it ("8b", "0.6b", "270m", "e4b", "16x17b") → about how many GB to download.
    static func estimatedGB(_ tag: String) -> Double? {
        var text = tag.lowercased()
        if text.hasPrefix("e") { text.removeFirst() }
        var factor = 1.0
        if let x = text.firstIndex(of: "x"), let n = Double(text[..<x]) { factor = n; text = String(text[text.index(after: x)...]) }
        let unit = text.last
        guard unit == "b" || unit == "m", let number = Double(text.dropLast()) else { return nil }
        let billions = factor * (unit == "m" ? number / 1000 : number)
        return ((billions * 0.65 + 0.3) * 10).rounded() / 10
    }

    // One model family on ollama.com/library, with its sizes.
    struct LibraryModel: Equatable {
        let name: String
        let summary: String
        let capabilities: [String]
        let sizes: [String]
    }
    // Reads the model cards of ollama.com/library. Ollama has no API for the list, so a page that changes shape
    // just yields nothing (the recommended list and typed names still work). Cloud-only and embedding models are
    // left out: they cannot chat on this Mac.
    static func parseLibrary(_ html: String) -> [LibraryModel] {
        let cards = html.components(separatedBy: "href=\"/library/").dropFirst()
        var seen = Set<String>()
        return cards.compactMap { card in
            guard let end = card.firstIndex(of: "\"") else { return nil }
            let name = String(card[..<end])
            guard !name.isEmpty, !name.contains("/"), !name.contains(":"), seen.insert(name).inserted else { return nil }
            let badges = matches(#"<span\s+class="inline-flex[^"]*"\s*>([^<]*)</span>"#, in: card)
            let sizes = badges.filter { estimatedGB($0) != nil }
            let capabilities = badges.filter { !sizes.contains($0) }
            guard !sizes.isEmpty, !capabilities.contains("embedding") else { return nil }
            let summary = matches(#"<p class="max-w-lg[^"]*">([^<]*)</p>"#, in: card).first ?? ""
            return LibraryModel(name: name, summary: decodeEntities(summary), capabilities: capabilities, sizes: sizes)
        }
    }
    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) } }
    }
    private static func decodeEntities(_ text: String) -> String {
        [("&amp;", "&"), ("&#39;", "'"), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">")].reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
    static func fetchLibrary(timeout: TimeInterval = 10) -> [LibraryModel] {
        guard let data = fetch(URLRequest(url: library), timeout: timeout), let html = String(data: data, encoding: .utf8) else { return [] }
        return parseLibrary(html)
    }

    // The exact download size, from the registry `ollama pull` itself uses. nil when the model does not exist.
    static func downloadGB(_ model: String, timeout: TimeInterval = 8) -> Double? {
        let parts = normalized(model).split(separator: ":", maxSplits: 1).map(String.init)
        let path = parts[0].contains("/") ? parts[0] : "library/" + parts[0]
        var request = URLRequest(url: registry.appendingPathComponent("v2/\(path)/manifests/\(parts[1])"))
        request.setValue("application/vnd.docker.distribution.manifest.v2+json", forHTTPHeaderField: "Accept")
        guard let data = fetch(request, timeout: timeout),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let layers = json["layers"] as? [[String: Any]], !layers.isEmpty else { return nil }
        let bytes = layers.compactMap { ($0["size"] as? NSNumber)?.doubleValue }.reduce(0, +)
        return bytes / 1e9
    }

    // The body of a 200 reply, or nil.
    private static func fetch(_ request: URLRequest, timeout: TimeInterval) -> Data? {
        var request = request
        request.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        var body: Data?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { body = data }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 1)
        return body
    }

    // MARK: Memory

    struct Loaded { var name: String; var title: String; var bytes: Int64; var until: Date? }

    // The model in memory now (one at most), how big, and until when. nil when none or Ollama is off.
    static func loaded(timeout: TimeInterval = 0.7) -> Loaded? { loadedModels(timeout: timeout).first }

    // Every model Ollama has in memory (GET /api/ps).
    static func loadedModels(timeout: TimeInterval = 0.7) -> [Loaded] {
        var request = URLRequest(url: server.appendingPathComponent("api/ps"))
        request.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        var found: [Loaded] = []
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for entry in models {
                guard let name = entry["name"] as? String else { continue }
                let until = (entry["expires_at"] as? String).flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
                found.append(Loaded(name: name, title: title(for: name), bytes: (entry["size"] as? NSNumber)?.int64Value ?? 0, until: until))
            }
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 0.5)
        return found
    }

    // Takes models out of memory now (Ollama keeps running, about 50 MB), every model but `keep`, and waits up to
    // 10 s until Ollama has let them go. Nothing happens when none is loaded.
    static func unload(except keep: String? = nil) {
        func other(_ name: String) -> Bool { keep.map { !matches(name, $0) } ?? true }
        let others = loadedModels().filter { other($0.name) }
        guard !others.isEmpty else { return }
        for entry in others {
            var request = URLRequest(url: server.appendingPathComponent("api/generate"))
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": entry.name, "keep_alive": 0])
            let done = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
            _ = done.wait(timeout: .now() + 11)
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && loadedModels().contains(where: { other($0.name) }) {
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    // The chat window closed: unload once no chat is answering any more (an answer under way finishes first),
    // unless the window was opened again in the meantime.
    static func unloadWhenIdle(busy: @escaping () -> Bool, reopened: @escaping () -> Bool) {
        if reopened() { return }
        if busy() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { unloadWhenIdle(busy: busy, reopened: reopened) }
            return
        }
        DispatchQueue.global(qos: .utility).async { unload() }
    }

    static var binary: String? {
        ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app/Contents/Resources/ollama"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // Why this Mac should not get a model of this size, or nil when it can (how well it fits is shown apart).
    static func unsuitable(downloadGB: Double = 0) -> String? {
        #if !arch(arm64)
        return L("Apple 칩 Mac에서만 쓸 수 있어요.", "Needs a Mac with Apple silicon.")
        #else
        let needed = Int((downloadGB + 2).rounded(.up))
        let home = URL(fileURLWithPath: AccountStore.home)
        if let free = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           Int(free >> 30) < needed {
            return L("디스크 여유가 \(needed)GB 이상 필요해요 (지금 \(Int(free >> 30))GB).", "Needs \(needed) GB of free disk space (now \(Int(free >> 30)) GB).")
        }
        return nil
        #endif
    }

    // A model Ollama has: its name, size on disk and what it can do (newer Ollama lists capabilities here).
    struct Installed: Equatable {
        let name: String
        let bytes: Int64
        let capabilities: [String]?
    }

    // The models Ollama has (GET /api/tags), or nil when Ollama is not running.
    static func installed(timeout: TimeInterval = 3) -> [Installed]? {
        var request = URLRequest(url: server.appendingPathComponent("api/tags"))
        request.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        var list: [Installed]?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return }
            list = models.compactMap { entry in
                guard let name = entry["name"] as? String else { return nil }
                return Installed(name: name, bytes: (entry["size"] as? NSNumber)?.int64Value ?? 0, capabilities: entry["capabilities"] as? [String])
            }
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 1)
        return list
    }
    static func installedModels(timeout: TimeInterval = 3) -> [String]? { installed(timeout: timeout)?.map(\.name) }

    static func hasModel(_ names: [String], _ variant: Variant) -> Bool { names.contains { matches($0, variant.model) } }

    // What a model can do, read once from Ollama (POST /api/show): whether it reads pictures and how long a
    // conversation it takes. Unknown (older Ollama, model missing) counts as pictures yes, 32K.
    struct Details { var vision: Bool; var contextLength: Int? }
    private static var detailsCache: [String: Details] = [:]
    private static let detailsLock = NSLock()
    static func details(_ model: String) -> Details {
        let key = normalized(model)
        detailsLock.lock(); let known = detailsCache[key]; detailsLock.unlock()
        if let known { return known }
        var request = URLRequest(url: server.appendingPathComponent("api/show"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard let data = fetch(request, timeout: 5), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["error"] == nil else { return Details(vision: true, contextLength: nil) }
        let capabilities = json["capabilities"] as? [String]
        let info = json["model_info"] as? [String: Any] ?? [:]
        let length = info.first { $0.key.hasSuffix(".context_length") }.flatMap { ($0.value as? NSNumber)?.intValue }
        let found = Details(vision: capabilities.map { $0.contains("vision") } ?? true, contextLength: length)
        detailsLock.lock(); detailsCache[key] = found; detailsLock.unlock()
        return found
    }
    // Downloads a model inside the app (POST /api/pull, streamed), reporting the step and how far it is
    // (0…1, nil while there is no total). Returns nil when done, else why it failed.
    static func pull(_ model: String, cancellation: DebateCancellation?, progress: @escaping (String, Double?) -> Void) -> String? {
        guard ensureServer() else { return binary == nil ? L("Ollama가 설치돼 있지 않아요.", "Ollama is not installed.") : L("Ollama를 켜지 못했어요.", "Could not start Ollama.") }
        var request = URLRequest(url: server.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600   // between pieces; a big model takes far longer in all
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let stream = PullStream(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: stream, delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.resume()
        while stream.done.wait(timeout: .now() + 0.2) == .timedOut {
            if cancellation?.isCancelled == true {
                task.cancel(); session.invalidateAndCancel()
                return L("취소했어요.", "Cancelled.")
            }
        }
        session.finishTasksAndInvalidate()
        detailsLock.lock(); detailsCache[normalized(model)] = nil; detailsLock.unlock()
        if let error = stream.error { return error }
        return stream.succeeded ? nil : L("받기를 마치지 못했어요.", "The download did not finish.")
    }

    // Deletes a model's files from this Mac (DELETE /api/delete). True when Ollama removed it.
    static func delete(_ model: String) -> Bool {
        var request = URLRequest(url: server.appendingPathComponent("api/delete"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "name": model])
        let done = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 21)
        return ok
    }

    // Starts Ollama when it is installed but not running, and waits up to 15 s for it.
    static func ensureServer() -> Bool {
        if installedModels() != nil { return true }
        guard let binary else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["serve"]
        // Ollama itself also keeps only one model in memory.
        process.environment = ProcessInfo.processInfo.environment.merging(["OLLAMA_MAX_LOADED_MODELS": "1"]) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.5)
            if installedModels(timeout: 1) != nil { return true }
        }
        return false
    }

    // Terminal shows each step: install Ollama with Homebrew (asks y/n first) or open its download page,
    // start it, then download the model with Ollama's own progress bar.
    // Used when Ollama itself is missing; with Ollama installed the app downloads models itself (pull).
    static func install(_ variant: Variant) {
        let terms = variant.model.hasPrefix("gemma") ? L(" (Gemma 이용 약관: https://ai.google.dev/gemma/terms)", " (Gemma terms: https://ai.google.dev/gemma/terms)") : ""
        Login.openInTerminal(name: L("\(variant.title) 설치", "Install \(variant.title)"), exports: "", script: """
        echo "\(L("\(variant.title)를 이 Mac에 설치해요 (Ollama 사용).", "Installs \(variant.title) on this Mac (with Ollama)."))"
        echo
        OLLAMA=""
        for p in /opt/homebrew/bin/ollama /usr/local/bin/ollama /Applications/Ollama.app/Contents/Resources/ollama; do
          [ -x "$p" ] && OLLAMA="$p" && break
        done
        if [ -z "$OLLAMA" ]; then
          if [ -x /opt/homebrew/bin/brew ]; then
            echo "\(L("Ollama가 없어요. Homebrew로 설치합니다: brew install ollama", "Ollama is not installed. Install it with Homebrew: brew install ollama"))"
            read "?\(L("설치할까요? (y/n) ", "Install? (y/n) "))" a
            [ "$a" = y ] || exit 0
            /opt/homebrew/bin/brew install ollama || { echo "\(L("설치 실패", "Installation failed"))"; read; exit 1; }
            OLLAMA=/opt/homebrew/bin/ollama
          else
            echo "\(L("Ollama가 없어요. 공식 다운로드 페이지를 열게요. 설치한 뒤 이 버튼을 다시 눌러 주세요.", "Ollama is not installed. Opening its download page; install it, then press this button again."))"
            open "https://ollama.com/download"
            read "?\(L("엔터를 누르면 창이 닫혀요.", "Press Enter to close this window."))"
            exit 0
          fi
        fi
        if ! curl -s http://127.0.0.1:11434/api/version >/dev/null; then
          echo "\(L("Ollama를 켜는 중…", "Starting Ollama…"))"
          (OLLAMA_MAX_LOADED_MODELS=1 "$OLLAMA" serve >/dev/null 2>&1 &)
          for i in {1..30}; do curl -s http://127.0.0.1:11434/api/version >/dev/null && break; sleep 0.5; done
        fi
        echo "\(L("모델 받는 중", "Downloading the model") + terms)"
        "$OLLAMA" pull \(variant.model) || { echo "\(L("받기 실패", "Download failed"))"; read; exit 1; }
        echo
        read "?\(L("끝났어요. AI Illuminati에서 @\(variant.title)로 불러 보세요. 엔터를 누르면 창이 닫혀요.", "Done. Call it with @\(variant.title) in AI Illuminati. Press Enter to close this window."))"
        """)
    }

    // One answer at a time across every chat, so two models never sit in memory together.
    private static let gate = DispatchSemaphore(value: 1)

    // One reply from POST /api/chat, streamed: each line carries the next piece of text.
    static func ask(_ variant: Variant = legacy[0], prompt: String, images: [URL], timeout: TimeInterval, cancellation: DebateCancellation?,
                    progress: ((AnswerProgress) -> Void)?) -> Result<String, Answerer.Failure> {
        guard enabled else {
            return .failure(.failed(L("Ollama 모델이 꺼져 있어요. 설정 → 계정에서 켤 수 있어요.", "Ollama models are turned off. Turn them on in Settings → Accounts.")))
        }
        guard ensureServer() else {
            return .failure(.failed(binary == nil ? L("Ollama가 설치돼 있지 않아요. 설정 → 계정 → 계정 추가 → Ollama 모델에서 설치하세요.", "Ollama is not installed. Install a model in Settings → Accounts → Add account → Ollama models.")
                                    : L("Ollama를 켜지 못했어요.", "Could not start Ollama.")))
        }
        var waiting = false
        while gate.wait(timeout: .now() + 0.2) == .timedOut {
            if cancellation?.isCancelled == true { return .failure(.failed("Cancelled")) }
            if !waiting {
                waiting = true
                progress?(.activity(L("다른 대화의 로컬 모델 답이 끝나길 기다리는 중", "Waiting for the local model to finish another chat's reply")))
            }
        }
        defer { gate.signal() }
        unload(except: variant.model)   // the other model leaves memory before this one loads
        // A model that cannot read pictures fails on them: it gets the text only. The conversation length is
        // 32K or the model's own limit when that is shorter.
        let info = details(variant.model)
        var message: [String: Any] = ["role": "user", "content": prompt]
        let pictures = info.vision ? images.compactMap { try? Data(contentsOf: $0).base64EncodedString() } : []
        if !pictures.isEmpty { message["images"] = pictures }
        let body: [String: Any] = ["model": variant.model, "messages": [message], "stream": true,
                                   "options": ["num_ctx": min(context, info.contextLength ?? context)], "keep_alive": keepAlive == 0 ? 0 as Any : "\(keepAlive)m" as Any]
        var request = URLRequest(url: server.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let stream = LocalStream(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: stream, delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.resume()
        let deadline = Date().addingTimeInterval(timeout)
        while stream.done.wait(timeout: .now() + 0.1) == .timedOut {
            if cancellation?.isCancelled == true || Date() >= deadline {
                task.cancel(); session.invalidateAndCancel()
                return .failure(cancellation?.isCancelled == true ? .failed("Cancelled") : .timedOut)
            }
        }
        session.finishTasksAndInvalidate()
        if let error = stream.error { return .failure(.failed(error)) }
        let text = stream.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? .failure(.failed(L("빈 답이 왔어요.", "Empty reply."))) : .success(text)
    }
}

// Collects Ollama's JSON lines as they arrive.
final class LocalStream: NSObject, URLSessionDataDelegate {
    let done = DispatchSemaphore(value: 0)
    private(set) var text = ""
    private(set) var error: String?
    private var pending = Data()
    private var lastSent = Date.distantPast
    private let progress: ((AnswerProgress) -> Void)?

    init(progress: ((AnswerProgress) -> Void)?) { self.progress = progress }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let message = json["error"] as? String { error = message; return }
        if let piece = (json["message"] as? [String: Any])?["content"] as? String { text += piece }
        let finished = json["done"] as? Bool == true
        if finished || Date().timeIntervalSince(lastSent) > 0.08 {
            lastSent = Date()
            if !text.isEmpty { progress?(.text(text)) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !pending.isEmpty { handle(pending); pending.removeAll() }
        if let error, (error as NSError).code != NSURLErrorCancelled, self.error == nil { self.error = error.localizedDescription }
        if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 200, self.error == nil { self.error = "HTTP \(status)" }
        done.signal()
    }
}

// Collects Ollama's pull progress lines: {"status":"pulling …","total":…,"completed":…}, then {"status":"success"}.
final class PullStream: NSObject, URLSessionDataDelegate {
    let done = DispatchSemaphore(value: 0)
    private(set) var error: String?
    private(set) var succeeded = false
    private var pending = Data()
    private var lastSent = Date.distantPast
    private let progress: (String, Double?) -> Void

    init(progress: @escaping (String, Double?) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let message = json["error"] as? String { error = message; return }
        let status = json["status"] as? String ?? ""
        if status == "success" { succeeded = true }
        let total = (json["total"] as? NSNumber)?.doubleValue ?? 0
        let completed = (json["completed"] as? NSNumber)?.doubleValue ?? 0
        if succeeded || Date().timeIntervalSince(lastSent) > 0.2 {
            lastSent = Date()
            progress(status, succeeded ? 1 : total > 0 ? min(1, completed / total) : nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !pending.isEmpty { handle(pending); pending.removeAll() }
        if let error, (error as NSError).code != NSURLErrorCancelled, self.error == nil { self.error = error.localizedDescription }
        if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 200, self.error == nil { self.error = "HTTP \(status)" }
        done.signal()
    }
}

// Usage for the menu: no limit. Not installed, not downloaded or not running is said in the note.
enum LocalUsage {
    static func read(_ account: Account) -> AIUsage {
        var result = AIUsage(name: account.name, account: account)
        let variant = LocalModel.variant(account)
        result.detail = L("내 Mac · ", "This Mac · ") + variant.model
        guard LocalModel.enabled else {
            result.needsLogin = true
            result.note = L("꺼 둠 (메뉴바에서 켜기)", "Turned off (turn on from the menu bar)")
            return result
        }
        guard LocalModel.binary != nil else {
            result.needsLogin = true
            result.note = L("설치가 필요해요 (설정 → 계정)", "Needs installing (Settings → Accounts)")
            return result
        }
        if let names = LocalModel.installedModels() {
            guard LocalModel.hasModel(names, variant) else {
                result.needsLogin = true
                result.note = L("모델을 받는 중이거나 없어요", "Model not downloaded yet")
                return result
            }
        } else {
            result.note = L("Ollama가 꺼져 있어요. 부르면 켜요", "Ollama is off; it starts when called")
        }
        // No limit: full bars.
        result.fiveHour = UsageWindow(usedPercent: 0, resetsAt: nil)
        result.weekly = UsageWindow(usedPercent: 0, resetsAt: nil)
        result.checkedAt = Date()
        return result
    }
}
