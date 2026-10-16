# Native session verification — first implementation step

This is an isolated experiment, not a switch to production sessions. The app's current
mode 3, account selection, attachments, and ephemeral Claude/Codex calls are unchanged.
No framework, API key, login migration, or credential copy is introduced.

## Run

Offline checks and fixture generation (no model calls):

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/tests -p test_session_probe.py
python3 tools/tests/session_probe.py
```

Opt-in live experiment (uses subscription allowance):

```sh
python3 tools/tests/session_probe.py --live --provider both
python3 tools/tests/session_probe.py --live --parallel-only --provider both
```

The first command makes at most four calls per provider. The parallel experiment makes
two fresh sessions on the same account per provider (two calls). It tests concurrent
creation, not concurrent resumption. `--provider claude|codex` and `--account <id>` can
limit the experiment. `--output <empty-directory>` and `--timeout <seconds>` are optional.

Only existing accounts whose resolved `dir` is below `~/.ai-illuminati/accounts/` are
eligible. Personal default folders, Gemini, and paths outside that root are rejected.
No auth files are read, copied, or edited by this script; each CLI uses its own login.
The CLI can update its own authentication/session state through its normal operation.

Every subprocess gets sanitized account-specific environment variables and its own
temporary working directory. Claude gets an explicit UUID, safe mode, an empty MCP
configuration and an explicit tool allowlist. Codex gets explicit read-only,
approval, and web settings on every invocation, including resume. Never use `--last`,
permission bypass, or a broadly writable sandbox in this experiment.

The fixtures are a synthetic manuscript of over 20,000 characters and a generated PNG
with two distinct numbers. Only the first call receives them. Subsequent processes
resume by ID and ask about previously unqueried facts. No answers are supplied in the
follow-up prompts. The final call requests a write to a disposable test file and a real
web search. No other user files are used.

Raw JSONL, stderr, fixtures, ownership records, answers and usage remain in a private
temporary directory, not in git. A populated experiment directory cannot be reused.
Timeouts terminate the process group; failures do not trigger paid retries. Reports
identify native transcript paths for the exact experiment UUIDs, not arbitrary sessions.
Sessions are deliberately retained for inspection. Do not delete whole provider folders;
native deletion and its index/sidebar effects still require verification before rollout.

## Observations on 2026-10-16

Installed CLI binaries were exercised using existing app-owned Claude and school Codex
accounts. No personal default Codex account or Gemini quota was used.

| Check | Claude | Codex |
| --- | --- | --- |
| Resume same native session across four process launches | Pass | Pass |
| Retrieve original manuscript label A + top image number, without reattachment | Pass | Pass |
| Retrieve previously unqueried label B + bottom image number, without reattachment | Pass | Pass |
| Web search observed after resuming | WebSearch event | web_search event |
| Disposable write file created | No; no write tool available | No |
| Permission evidence | init events show no tools / only WebSearch + WebFetch | all four turn_context records show read-only and the expected cwd |
| Separate native sessions created concurrently on same account | Pass | Pass |
| Image data present in exact native transcript | Observed | Observed |

Important Codex finding: the school account's managed requirements override the requested
`approval_policy="never"` with `on-request`. The read-only sandbox remains read-only on
all four turns. An absent write file or a model's refusal alone is not permission proof;
the report records the native sandbox metadata separately. The experiment must report an
approval override without confusing it with loss of read-only enforcement. Do not bypass
managed requirements to make the requested approval policy take effect.

Timings for the four serial calls were Claude 2.47 / 2.76 / 2.33 / 11.86 seconds and
Codex 5.43 / 5.76 / 5.09 / 11.68 seconds. These are one small sample, not a performance
comparison. Later calls contain cached-input tokens, but there is no matched stateless
baseline and no measurement of subscription-percentage savings. Usage event values are
stored as reported: some CLI counters can be cumulative, so do not sum calls blindly.

The first sandboxed launch could not access the CLI runtime/keychain correctly; it is
not counted as a successful model experiment. The successful live tests ran with host
execution permission. This environment issue must not be treated as expired user login.

## What is NOT verified / rollout gates

- Actual automatic compaction detection and image/detail access after compaction. The
  parser recognizes observable compaction event names, but a parser unit test is not an
  actual compression experiment. A >100k-token stress run was not performed.
- Initial image perception control, matched stateless A/B comparison, or research PDFs.
- Personal desktop/sidebar visibility (only app-owned account folders were used).
- Native deletion, provider index cleanup and deletion recovery.
- Concurrent resume on separate sessions, app restart recovery, interruption/replay and
  account handoff under actual quota exhaustion.
- Gemini session or image support.

`ready_for_app` stays false even if this short experiment passes. Do not automatically
enable sessions from this report. Next: verify ownership/deletion and recovery, then add
an opt-in room setting with a bounded stateless fallback. Keep the current mode 3 default.
Quota/auth/permission failures and user Stop must never cause an automatic repeat call.
Compaction recovery should reintroduce relevant material, not replay every attachment
until the context window overflows again.

## Regression validation

Six offline Python tests pass, and all 12 saved live outputs contain terminal completion
events. The existing `zsh tools/tests/run_mode2.sh` suite passes with host pasteboard
access. Its mode-switch fake previously appended to a captured array from concurrent
mode 1 calls and intermittently crashed with SIGSEGV; only that test fake now uses a lock.
The production Swift files were not changed, so the menu bar app was not rebuilt/restarted.
