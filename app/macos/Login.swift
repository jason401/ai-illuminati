import Foundation
import AIAccounts
import AILocalization
import AIRuntime

// Login buttons. The app never sees a password: it opens Terminal with a small script that runs
// each AI tool's own login (which opens the browser). Installing asks y/n first.
// Install commands are the official ones:
//   Claude Code: https://code.claude.com/docs/en/setup  (installs ~/.local/bin/claude)
//   Antigravity CLI: https://codelabs.developers.google.com/antigravity-cli-hands-on  (~/.local/bin/agy)
enum Login {
    static var home: String { ToolHome.path }
    static var agyInstalled: Bool { ToolHome.agyInstalled }

    static func login(_ account: Account) {
        switch account.provider {
        case .claude: claude(account)
        case .codex: codex(account)
        case .gemini: gemini()
        case .ollama: LocalModel.install(LocalModel.variant(account))
        }
    }

    private static func claude(_ account: Account) {
        openInTerminal(name: L("로그인 - \(account.name)", "Sign in - \(account.name)"), exports: exports(account), script: """
        echo "\(L("Claude 로그인: \(account.name)", "Claude sign-in: \(account.name)"))"
        echo
        if [ ! -x "$HOME/.local/bin/claude" ]; then
          echo "\(L("터미널용 Claude Code가 없어요. 공식 설치 명령으로 설치합니다:", "Claude Code is not installed. Install it using the official command:"))"
          echo "  curl -fsSL https://claude.ai/install.sh | bash"
          read "?\(L("설치할까요? (y/n) ", "Install? (y/n) "))" a
          [ "$a" = y ] || exit 0
          curl -fsSL https://claude.ai/install.sh | bash || { echo "\(L("설치 실패", "Installation failed"))"; read; exit 1; }
          echo
        fi
        echo "\(L("브라우저가 열리면 '\(account.name)'으로 쓸 Claude 계정으로 로그인하세요.", "When the browser opens, sign in to the Claude account for '\(account.name)'."))"
        echo "\(L("다른 계정으로 로그인돼 있으면 브라우저에서 계정을 바꾼 뒤 허용을 누르세요.", "If a different account is signed in, switch accounts in the browser before allowing access."))"
        echo
        "$HOME/.local/bin/claude" auth login --claudeai
        echo
        read "?\(L("끝났어요. 엔터를 누르면 창이 닫혀요.", "Done. Press Enter to close this window."))"
        """)
    }

    private static func codex(_ account: Account) {
        guard let binary = CodexUsage.binary else {
            openInTerminal(name: L("로그인 - \(account.name)", "Sign in - \(account.name)"), exports: "", script: """
            echo "\(L("Codex 프로그램을 찾지 못했어요. ChatGPT 앱(Codex 포함)을 설치한 뒤 다시 눌러 주세요.", "Codex was not found. Install the ChatGPT app with Codex and try again."))"
            read
            """)
            return
        }
        openInTerminal(name: L("로그인 - \(account.name)", "Sign in - \(account.name)"), exports: exports(account), script: """
        echo "\(L("ChatGPT(Codex) 로그인: \(account.name)", "ChatGPT (Codex) sign-in: \(account.name)"))"
        echo
        echo "\(L("브라우저가 열리면 '\(account.name)'으로 쓸 ChatGPT 계정으로 로그인하세요.", "When the browser opens, sign in to the ChatGPT account for '\(account.name)'."))"
        echo "\(L("주의: 이미 추가된 다른 항목과 같은 ChatGPT 계정으로 로그인하면 둘 다 로그인이 풀릴 수 있어요.", "Warning: adding the same ChatGPT account twice can sign out both entries."))"
        echo
        \(quote(binary)) login
        echo
        read "?\(L("끝났어요. 엔터를 누르면 창이 닫혀요.", "Done. Press Enter to close this window."))"
        """)
    }

    static func gemini() {
        openInTerminal(name: L("Gemini 로그인", "Gemini sign-in"), exports: "", script: """
        echo "\(L("Gemini 로그인 (AI Illuminati)", "Gemini sign-in (AI Illuminati)"))"
        echo
        if [ ! -x "$HOME/.local/bin/agy" ]; then
          echo "\(L("Antigravity CLI(agy)가 없어요. 공식 설치 명령으로 설치합니다:", "Antigravity CLI (agy) is not installed. Install it using the official command:"))"
          echo "  curl -fsSL https://antigravity.google/cli/install.sh | bash"
          read "?\(L("설치할까요? (y/n) ", "Install? (y/n) "))" a
          [ "$a" = y ] || exit 0
          curl -fsSL https://antigravity.google/cli/install.sh | bash || { echo "\(L("설치 실패", "Installation failed"))"; read; exit 1; }
          echo
        fi
        echo "\(L("곧 agy가 열려요. 로그인 방법을 물으면 'Google OAuth'(개인 계정)를 고르고,", "agy will open. Choose 'Google OAuth' (personal account) when asked,"))"
        echo "\(L("브라우저에서 로그인하세요. 코드를 보여주면 터미널에 붙여 넣으면 돼요.", "then sign in in the browser. If shown a code, paste it into Terminal."))"
        echo
        "$HOME/.local/bin/agy"
        """)
    }

    private static func exports(_ account: Account) -> String {
        guard let dir = account.dir else { return "" }
        let name = account.provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
        return "export \(name)=\(quote(dir))"
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // Writes the script to ~/Library/Application Support/AI Illuminati and opens it in Terminal.
    // API key variables are removed so the tools log in with the subscription, not an API key.
    static func openInTerminal(name: String, exports: String, script: String) {
        let dir = URL(fileURLWithPath: AccountStore.supportDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = name.replacingOccurrences(of: "/", with: "-")
        let file = dir.appendingPathComponent("\(safeName).command")
        // Terminal keeps a window open after its script ends ("[Process completed]"). The closer
        // (same as AI Face's build window) runs detached in its own session and waits until this
        // script has ended, so Terminal has nothing running in the window and closes it without asking.
        let windowName = file.lastPathComponent.replacingOccurrences(of: "\"", with: "")
        let body = """
        #!/bin/zsh
        unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY CLAUDE_CONFIG_DIR CODEX_HOME
        close_window() {
          /usr/bin/python3 -c '
        import os, subprocess, sys, time
        if os.fork():
            os._exit(0)
        os.setsid()
        for fd in (0, 1, 2):
            os.dup2(os.open(os.devnull, os.O_RDWR), fd)
        time.sleep(1.5)
        subprocess.run(["osascript", "-e", "tell application \\"Terminal\\" to close (every window whose name contains \\"" + sys.argv[1] + "\\")"])
        ' "\(windowName)" </dev/null >/dev/null 2>&1
        }
        trap close_window EXIT
        \(exports)
        cd "$HOME"
        \(script)

        """
        try? body.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", "Terminal", file.path]
        try? open.run()
    }
}

extension LocalModel {
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
        read "?\(sortOnly(variant.model) ? L("끝났어요. 이제 메시지 판정에 써요. 엔터를 누르면 창이 닫혀요.", "Done. It now sorts messages. Press Enter to close this window.") : L("끝났어요. AI Illuminati에서 @\(variant.title)로 불러 보세요. 엔터를 누르면 창이 닫혀요.", "Done. Call it with @\(variant.title) in AI Illuminati. Press Enter to close this window."))"
        """)
    }
}
