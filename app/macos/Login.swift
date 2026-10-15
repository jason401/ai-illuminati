import Foundation

// Login buttons. The app never sees a password: it opens Terminal with a small script that runs
// each AI tool's own login (which opens the browser). Installing asks y/n first.
// Install commands are the official ones:
//   Claude Code: https://code.claude.com/docs/en/setup  (installs ~/.local/bin/claude)
//   Antigravity CLI: https://codelabs.developers.google.com/antigravity-cli-hands-on  (~/.local/bin/agy)
enum Login {
    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    static var agyInstalled: Bool { FileManager.default.isExecutableFile(atPath: home + "/.local/bin/agy") }

    static func login(_ account: Account) {
        switch account.provider {
        case .claude: claude(account)
        case .codex: codex(account)
        }
    }

    private static func claude(_ account: Account) {
        openInTerminal(name: "로그인 - \(account.name)", exports: exports(account), script: """
        echo "Claude 로그인: \(account.name)"
        echo
        if [ ! -x "$HOME/.local/bin/claude" ]; then
          echo "터미널용 Claude Code가 없어요. 공식 설치 명령으로 설치합니다:"
          echo "  curl -fsSL https://claude.ai/install.sh | bash"
          read "?설치할까요? (y/n) " a
          [ "$a" = y ] || exit 0
          curl -fsSL https://claude.ai/install.sh | bash || { echo "설치 실패"; read; exit 1; }
          echo
        fi
        echo "브라우저가 열리면 '\(account.name)'으로 쓸 Claude 계정으로 로그인하세요."
        echo "다른 계정으로 로그인돼 있으면 브라우저에서 계정을 바꾼 뒤 허용을 누르세요."
        echo
        "$HOME/.local/bin/claude" auth login --claudeai
        echo
        read "?끝났어요. 엔터를 누르면 창이 닫혀요."
        """)
    }

    private static func codex(_ account: Account) {
        guard let binary = CodexUsage.binary else {
            openInTerminal(name: "로그인 - \(account.name)", exports: "", script: """
            echo "Codex 프로그램을 찾지 못했어요. ChatGPT 앱(Codex 포함)을 설치한 뒤 다시 눌러 주세요."
            read
            """)
            return
        }
        openInTerminal(name: "로그인 - \(account.name)", exports: exports(account), script: """
        echo "ChatGPT(Codex) 로그인: \(account.name)"
        echo
        echo "브라우저가 열리면 '\(account.name)'으로 쓸 ChatGPT 계정으로 로그인하세요."
        echo "주의: 이미 추가된 다른 항목과 같은 ChatGPT 계정으로 로그인하면 둘 다 로그인이 풀릴 수 있어요."
        echo
        \(quote(binary)) login
        echo
        read "?끝났어요. 엔터를 누르면 창이 닫혀요."
        """)
    }

    static func gemini() {
        openInTerminal(name: "Gemini 로그인", exports: "", script: """
        echo "Gemini 로그인 (AI Illuminati)"
        echo
        if [ ! -x "$HOME/.local/bin/agy" ]; then
          echo "Antigravity CLI(agy)가 없어요. 공식 설치 명령으로 설치합니다:"
          echo "  curl -fsSL https://antigravity.google/cli/install.sh | bash"
          read "?설치할까요? (y/n) " a
          [ "$a" = y ] || exit 0
          curl -fsSL https://antigravity.google/cli/install.sh | bash || { echo "설치 실패"; read; exit 1; }
          echo
        fi
        echo "곧 agy가 열려요. 로그인 방법을 물으면 'Google OAuth'(개인 계정)를 고르고,"
        echo "브라우저에서 로그인하세요. 코드를 보여주면 터미널에 붙여 넣으면 돼요."
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
    private static func openInTerminal(name: String, exports: String, script: String) {
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
