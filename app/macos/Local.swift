import Foundation

// Gemma 4 E4B on this Mac, through Ollama (https://ollama.com). No account, key or usage limit: the app talks
// to Ollama on 127.0.0.1:11434 and nothing leaves the Mac. Installed from Settings → Accounts only when the user
// asks (Terminal shows each step and asks before installing). In plain chat it answers when called with @, and
// when every cloud account is out of usage; it also votes. It reads linked files through the app (the
// workspace_reads requests) and cannot change files or search the web.
enum LocalModel {
    static let model = "gemma4:e4b"
    static var server = URL(string: "http://127.0.0.1:11434")!   // tests point this at a fake server
    static let minMemoryGB = 16
    static let minDiskGB = 15
    static let context = 32768   // Ollama's default (4K) is too short for a chat with files

    static var binary: String? {
        ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app/Contents/Resources/ollama"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // Why this Mac should not run it, or nil when it can.
    static func unsuitable() -> String? {
        #if !arch(arm64)
        return L("Apple 칩 Mac에서만 쓸 수 있어요.", "Needs a Mac with Apple silicon.")
        #else
        let memory = Int(ProcessInfo.processInfo.physicalMemory >> 30)
        if memory < minMemoryGB {
            return L("메모리가 \(minMemoryGB)GB 이상 필요해요 (이 Mac: \(memory)GB).", "Needs at least \(minMemoryGB) GB of memory (this Mac: \(memory) GB).")
        }
        let home = URL(fileURLWithPath: AccountStore.home)
        if let free = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           Int(free >> 30) < minDiskGB {
            return L("디스크 여유가 \(minDiskGB)GB 이상 필요해요 (지금 \(Int(free >> 30))GB).", "Needs \(minDiskGB) GB of free disk space (now \(Int(free >> 30)) GB).")
        }
        return nil
        #endif
    }

    // The models Ollama has (GET /api/tags), or nil when Ollama is not running.
    static func installedModels(timeout: TimeInterval = 3) -> [String]? {
        var request = URLRequest(url: server.appendingPathComponent("api/tags"))
        request.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        var names: [String]?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return }
            names = models.compactMap { $0["name"] as? String }
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 1)
        return names
    }

    static func hasModel(_ names: [String]) -> Bool { names.contains { $0 == model || $0.hasPrefix(model + "-") } }

    // Starts Ollama when it is installed but not running, and waits up to 15 s for it.
    static func ensureServer() -> Bool {
        if installedModels() != nil { return true }
        guard let binary else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["serve"]
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
    // start it, then download the model (about 10 GB) with Ollama's own progress bar.
    static func install() {
        Login.openInTerminal(name: L("Gemma 4 설치", "Install Gemma 4"), exports: "", script: """
        echo "\(L("Gemma 4 E4B를 이 Mac에 설치해요 (Ollama 사용, 약 10GB).", "Installs Gemma 4 E4B on this Mac (with Ollama, about 10 GB)."))"
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
          ("$OLLAMA" serve >/dev/null 2>&1 &)
          for i in {1..30}; do curl -s http://127.0.0.1:11434/api/version >/dev/null && break; sleep 0.5; done
        fi
        echo "\(L("모델 받는 중 (Gemma 이용 약관: https://ai.google.dev/gemma/terms)", "Downloading the model (Gemma terms: https://ai.google.dev/gemma/terms)"))"
        "$OLLAMA" pull \(model) || { echo "\(L("받기 실패", "Download failed"))"; read; exit 1; }
        echo
        read "?\(L("끝났어요. AI Illuminati에서 @Gemma로 불러 보세요. 엔터를 누르면 창이 닫혀요.", "Done. Call it with @Gemma in AI Illuminati. Press Enter to close this window."))"
        """)
    }

    // One reply from POST /api/chat, streamed: each line carries the next piece of text.
    static func ask(prompt: String, images: [URL], timeout: TimeInterval, cancellation: DebateCancellation?,
                    progress: ((AnswerProgress) -> Void)?) -> Result<String, Answerer.Failure> {
        guard ensureServer() else {
            return .failure(.failed(binary == nil ? L("Ollama가 설치돼 있지 않아요. 설정 → 계정에서 Gemma를 설치하세요.", "Ollama is not installed. Install Gemma in Settings → Accounts.")
                                    : L("Ollama를 켜지 못했어요.", "Could not start Ollama.")))
        }
        var message: [String: Any] = ["role": "user", "content": prompt]
        let pictures = images.compactMap { try? Data(contentsOf: $0).base64EncodedString() }
        if !pictures.isEmpty { message["images"] = pictures }
        let body: [String: Any] = ["model": model, "messages": [message], "stream": true,
                                   "options": ["num_ctx": context], "keep_alive": "10m"]
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

// Usage for the menu: no limit. Not installed, not downloaded or not running is said in the note.
enum LocalUsage {
    static func read(_ account: Account) -> AIUsage {
        var result = AIUsage(name: account.name, account: account)
        result.detail = L("내 Mac · ", "This Mac · ") + LocalModel.model
        guard LocalModel.binary != nil else {
            result.needsLogin = true
            result.note = L("설치가 필요해요 (설정 → 계정)", "Needs installing (Settings → Accounts)")
            return result
        }
        if let names = LocalModel.installedModels() {
            guard LocalModel.hasModel(names) else {
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
