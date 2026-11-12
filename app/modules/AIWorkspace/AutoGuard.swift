import Foundation
import AIAccounts

// Full auto (the user is away): the AI gets every tool without approval cards, but cannot destroy the backups.
// - No Git or GitHub credentials in its environment: pushes go through git_push (main/feature, never force)
//   and git_publish_stable (always an approval card). A `git` shim refuses push and history rewrites.
// - An `rm` shim moves files to the Trash instead of deleting them (temporary folders are deleted normally).
// - A `security` shim keeps the app's own Keychain logins (Google, remote MCP) out of reach.
// Limits: a deliberate script could still call /bin/rm or /usr/bin/security directly; this guards mistakes and
// injected one-liners, not malice.
enum AutoGuard {
    static let claudeDenied = ["Bash(git push:*)", "Bash(git filter-branch:*)", "Bash(git filter-repo:*)", "Bash(/usr/bin/git push:*)",
                               "Bash(gh repo delete:*)", "Bash(/bin/rm:*)", "Bash(git clean:*)", "Bash(/usr/bin/security:*)"]
    static var folder: URL { URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("auto-guard", isDirectory: true) }

    static let gitShim = """
    #!/bin/bash
    # AI Illuminati full auto: Git without push or history rewrites. Use the app's git_push tool.
    i=1; sub=""
    while [ $i -le $# ]; do
      a="${!i}"
      case "$a" in
        -C|-c|--git-dir|--work-tree|--namespace|--exec-path) i=$((i+2)); continue;;
        -*) i=$((i+1)); continue;;
        *) sub="$a"; break;;
      esac
    done
    case "$sub" in
      push|filter-branch|filter-repo|send-pack)
        echo "AI Illuminati full auto: 'git $sub' is blocked here. Use the git_push tool (main or feature branches; stable needs the user's approval)." >&2
        exit 1;;
    esac
    exec /usr/bin/git "$@"
    """

    static let rmShim = """
    #!/bin/bash
    # AI Illuminati full auto: rm moves files to the Trash (recoverable). Temporary folders are deleted normally.
    force=0; ended=0; files=()
    for a in "$@"; do
      if [ $ended -eq 0 ] && [ "$a" = "--" ]; then ended=1; continue; fi
      if [ $ended -eq 0 ] && [ "${a#-}" != "$a" ] && [ "$a" != "-" ]; then case "$a" in *f*) force=1;; esac; continue; fi
      files+=("$a")
    done
    tmp="${TMPDIR:-/tmp}"; status=0
    for f in "${files[@]}"; do
      if [ ! -e "$f" ] && [ ! -L "$f" ]; then
        [ $force -eq 1 ] || { echo "rm: $f: No such file or directory" >&2; status=1; }
        continue
      fi
      full="$(cd "$(dirname "$f")" 2>/dev/null && pwd -P)/$(basename "$f")"
      case "$full" in
        /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*|"${tmp%/}"/*) /bin/rm -rf -- "$f" || status=1; continue;;
      esac
      if [ -x /usr/bin/trash ]; then /usr/bin/trash "$f" >/dev/null 2>&1 || status=1
      else mkdir -p "$HOME/.Trash" && mv -- "$f" "$HOME/.Trash/$(basename "$f").$(date +%s).$$" || status=1; fi
    done
    exit $status
    """

    // The Google and remote MCP logins trust /usr/bin/security (no password prompt after rebuilds), so a plain
    // `security find-generic-password` would hand them to the AI. Only Claude Code's own login items (it calls
    // `security` by name, also with `-i` and commands on stdin) and certificate lookups pass.
    static let securityShim = """
    #!/bin/bash
    # AI Illuminati full auto: Keychain access only for Claude Code's own login and certificate lookups.
    deny() { echo "AI Illuminati full auto: this Keychain access is blocked here (other app logins live in the Keychain)." >&2; exit 1; }
    re='^Claude Code(-credentials)?(-[0-9a-f]+)?$'
    item() {  # one generic-password command with exactly one -s naming a Claude Code item
      case "$1" in find-generic-password|add-generic-password|delete-generic-password) ;; *) return 1;; esac
      shift; local n=0 s="" take=0 a
      for a in "$@"; do
        if [ $take -eq 1 ]; then s="$a"; take=0; continue; fi
        case "$a" in -s) take=1; n=$((n+1));; -*s*) return 1;; esac
      done
      [ $n -eq 1 ] && [[ "$s" =~ $re ]]
    }
    top=()
    while [ $# -gt 0 ]; do
      case "$1" in -i|-q|-v) top+=("$1"); shift;; -*) deny;; *) break;; esac
    done
    if [ $# -eq 0 ]; then
      [ -t 0 ] && deny
      input="$(head -c 65537)"; [ ${#input} -le 65536 ] || deny
      while IFS= read -r line; do
        line="${line%$'\\r'}"
        case "$line" in *\\\\*|*\\'*) deny;; esac
        tokens=(); cur=""; inq=0; have=0
        for ((k = 0; k < ${#line}; k++)); do
          c="${line:k:1}"
          if [ "$c" = '"' ]; then inq=$((1 - inq)); have=1
          elif [ $inq -eq 0 ] && { [ "$c" = " " ] || [ "$c" = $'\\t' ]; }; then [ $have -eq 1 ] && tokens+=("$cur"); cur=""; have=0
          else cur+="$c"; have=1; fi
        done
        [ $inq -eq 0 ] || deny
        [ $have -eq 1 ] && tokens+=("$cur")
        [ ${#tokens[@]} -eq 0 ] && continue
        case "${tokens[0]}" in exit|quit) continue;; esac
        item "${tokens[@]}" || deny
      done <<< "$input"
      printf '%s\\n' "$input" | /usr/bin/security ${top[@]+"${top[@]}"}
      exit $?
    fi
    case "$1" in
      find-identity|find-certificate|verify-cert|show-keychain-info) exec /usr/bin/security ${top[@]+"${top[@]}"} "$@";;
    esac
    item "$@" || deny
    exec /usr/bin/security ${top[@]+"${top[@]}"} "$@"
    """

    static func environment(_ base: [String: String]) -> [String: String] {
        var env = base
        let bin = folder.appendingPathComponent("bin", isDirectory: true)
        let gh = folder.appendingPathComponent("gh-empty", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.createDirectory(at: gh, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (name, text) in [("git", gitShim), ("rm", rmShim), ("security", securityShim)] {
            let url = bin.appendingPathComponent(name)
            if (try? String(contentsOf: url, encoding: .utf8)) != text {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        env["PATH"] = bin.path + ":" + (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        // No credentials: an empty helper list, no prompts, no SSH keys, and an empty GitHub CLI login.
        env["GIT_CONFIG_COUNT"] = "2"; env["GIT_CONFIG_KEY_0"] = "credential.helper"; env["GIT_CONFIG_VALUE_0"] = ""
        env["GIT_CONFIG_KEY_1"] = "credential.https://github.com.helper"; env["GIT_CONFIG_VALUE_1"] = ""
        env["GIT_TERMINAL_PROMPT"] = "0"; env["GIT_ASKPASS"] = "/usr/bin/false"; env["SSH_ASKPASS"] = "/usr/bin/false"
        env["GIT_SSH_COMMAND"] = "/usr/bin/ssh -o BatchMode=yes -o IdentitiesOnly=yes -i /dev/null"
        env["GH_CONFIG_DIR"] = gh.path
        for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "SSH_AUTH_SOCK"] { env.removeValue(forKey: key) }
        return env
    }
}
