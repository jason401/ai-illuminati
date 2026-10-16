#!/usr/bin/env python3
"""Opt-in native-session experiment. Never imports/copies credentials or edits app data.

The default only creates synthetic fixtures. --live spends subscription usage and writes
native transcripts in an EXISTING app-owned account folder. Gemini is deliberately excluded.
"""
import argparse
import base64
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import tempfile
import time
import uuid
import zlib

HOME = Path.home()
API_ENV = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
           "OPENAI_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY", "CLAUDECODE",
           "CODEX_HOME", "CLAUDE_CONFIG_DIR", "PWD", "OLDPWD")
CODEX_PATHS = (HOME / ".local/bin/codex", Path("/opt/homebrew/bin/codex"),
               Path("/usr/local/bin/codex"),
               Path("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"))


def account_for(provider, requested=None):
    records = json.loads((HOME / "Library/Application Support/AI Illuminati/accounts.json").read_text())
    root = (HOME / ".ai-illuminati/accounts").resolve()
    for account in records:
        if account["provider"] != provider or (requested and account["id"] != requested):
            continue
        directory = account.get("dir")
        if directory and root in Path(directory).resolve().parents and Path(directory).is_dir():
            return account
    raise ValueError(f"No existing app-owned {provider} account; personal default folders are never used")


def environment(account):
    env = {k: v for k, v in os.environ.items() if k not in API_ENV}
    env["CLAUDE_CONFIG_DIR" if account["provider"] == "claude" else "CODEX_HOME"] = account["dir"]
    return env


def png_fixture(path):
    # Two legible, different three-digit numbers, encoded as PNG without dependencies.
    glyphs = {"2": [14, 17, 1, 2, 4, 8, 31], "4": [2, 6, 10, 18, 31, 2, 2],
              "7": [31, 1, 2, 4, 8, 8, 8], "3": [30, 1, 1, 14, 1, 1, 30],
              "8": [14, 17, 17, 14, 17, 17, 14], "6": [14, 16, 16, 30, 17, 17, 14]}
    width, height, scale = 640, 360, 12
    pixels = bytearray([255] * (width * height * 3))
    for number, top in [("247", 35), ("386", 210)]:
        for char_index, char in enumerate(number):
            for row, bits in enumerate(glyphs[char]):
                for col in range(5):
                    if bits & (1 << (4 - col)):
                        for dy in range(scale):
                            y = top + row * scale + dy
                            for dx in range(scale):
                                x = 200 + char_index * 7 * scale + col * scale + dx
                                offset = (y * width + x) * 3
                                pixels[offset:offset + 3] = b"\0\0\0"
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    raw = b"".join(b"\0" + pixels[y * width * 3:(y + 1) * width * 3] for y in range(height))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def fixtures(root):
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(root, 0o700)
    a, b = uuid.uuid4().hex[:12], uuid.uuid4().hex[:12]
    lines = [f"Paragraph {n}: Synthetic ultrasound research notes. Values here are filler, not experimental evidence."
             for n in range(210)]
    lines[71] = f"Calibration label A is {a}."
    lines[157] = f"Calibration label B is {b}."
    text = "\n".join(lines)
    (root / "manuscript.txt").write_text(text)
    png_fixture(root / "figure.png")
    return {"text": text, "a": a, "b": b, "image": root / "figure.png"}


def events_from(stdout):
    events = []
    for line in stdout.splitlines():
        try:
            value = json.loads(line)
            if isinstance(value, dict):
                events.append(value)
        except ValueError:
            pass
    return events


def summary(provider, events):
    result = {"answer": "", "session_id": None, "usage": [], "tools": [], "compaction_events": [], "completed": False}
    for event in events:
        kind = event.get("type", "")
        if "compact" in kind or "compact" in str(event.get("subtype", "")):
            result["compaction_events"].append(kind + ":" + str(event.get("subtype", "")))
        if provider == "claude":
            if kind == "system" and event.get("subtype") == "init":
                result["session_id"] = event.get("session_id")
                result["available_tools"] = event.get("tools", [])
            if kind == "assistant":
                for block in event.get("message", {}).get("content", []):
                    if block.get("type") == "tool_use":
                        result["tools"].append(block.get("name"))
            if kind == "result":
                result["completed"] = True
                result["answer"] = event.get("result", "")
                result["session_id"] = event.get("session_id", result["session_id"])
                result["is_error"] = event.get("is_error", False)
                result["usage"].append(event.get("usage", {}))
        else:
            if kind == "thread.started":
                result["session_id"] = event.get("thread_id")
            item = event.get("item", {})
            if kind == "item.completed" and item.get("type") == "agent_message":
                result["answer"] = item.get("text", "")
            if kind == "item.completed" and item.get("type") in ("web_search", "command_execution", "file_change"):
                result["tools"].append(item.get("type"))
            if kind == "turn.completed":
                result["completed"] = True
                result["usage"].append(event.get("usage", {}))
            if kind in ("turn.failed", "error"):
                result["is_error"] = True
    return result


def native_evidence(provider, account_dir, session_id):
    """Only inspect the exact UUID owned by this probe, never scan unrelated transcripts."""
    empty = {"native_transcripts": [], "effective_turn_contexts": [],
             "embedded_image_entries": 0, "native_compaction_events": []}
    try:
        uuid.UUID(session_id)
    except (ValueError, TypeError, AttributeError):
        return empty
    root = Path(account_dir) / ("sessions" if provider == "codex" else "projects")
    paths, contexts, media, compactions = [], [], 0, []
    for file in root.rglob(f"*{session_id}*.jsonl"):
        if not file.is_file():
            continue
        paths.append(str(file))
        for e in events_from(file.read_text()):
            if e.get("type") == "turn_context":
                payload = e.get("payload", {})
                contexts.append({k: payload.get(k) for k in ("sandbox_policy", "approval_policy", "cwd")})
            if "compact" in str(e.get("type", "")) or "compact" in str(e.get("subtype", "")):
                compactions.append(str(e.get("type")) + ":" + str(e.get("subtype", "")))
            # Evidence of embedded image data, not a guarantee that all future contexts retain it.
            encoded = json.dumps(e)
            media += encoded.count("data:image/") + encoded.count('"media_type": "image/png"')
    return {"native_transcripts": paths, "effective_turn_contexts": contexts,
            "embedded_image_entries": media, "native_compaction_events": compactions}


def command(provider, binary, prompt, session_id, resume=False, image=None, web=False):
    if provider == "claude":
        tools = "WebSearch,WebFetch" if web else ""
        args = [str(binary), "-p", "--output-format", "stream-json", "--verbose",
                "--safe-mode", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
                "--no-chrome", "--tools", tools, "--permission-mode", "dontAsk", "--max-turns", "6"]
        if web:
            args += ["--allowedTools", tools]
        args += ["--resume" if resume else "--session-id", session_id]
        blocks = [{"type": "text", "text": prompt}]
        if image:
            blocks.append({"type": "image", "source": {"type": "base64", "media_type": "image/png",
                                                         "data": base64.b64encode(image.read_bytes()).decode()}})
        args += ["--input-format", "stream-json"]
        stdin = json.dumps({"type": "user", "message": {"role": "user", "content": blocks}}) + "\n"
    else:
        # These settings are passed on EVERY launch, including resume. No unsafe approval bypass.
        args = [str(binary), "-c", 'sandbox_mode="read-only"', "-c", 'approval_policy="never"',
                "-c", 'web_search="live"' if web else 'web_search="disabled"', "exec"]
        if resume:
            args += ["resume"]
        args += ["--json", "--skip-git-repo-check"]
        if image:
            args += ["--image", str(image)]
        if resume:
            args += [session_id]
        args += ["-"]
        stdin = prompt
    return args, stdin


def invoke(provider, binary, account, room, prompt, session_id, resume=False, image=None, web=False, timeout=180):
    args, stdin = command(provider, binary, prompt, session_id, resume, image, web)
    started = time.monotonic()
    process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, cwd=room, env=environment(account), start_new_session=True)
    timed_out = False
    interrupted = False
    try:
        stdout, stderr = process.communicate(stdin, timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        timed_out = isinstance(error, subprocess.TimeoutExpired)
        interrupted = not timed_out
        os.killpg(process.pid, signal.SIGTERM)
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
    events = events_from(stdout)
    parsed = summary(provider, events)
    parsed.update(seconds=round(time.monotonic() - started, 2), exit_code=process.returncode,
                  event_types=sorted({str(e.get("type")) for e in events}))
    parsed["ok"] = process.returncode == 0 and not parsed.get("is_error") and parsed["completed"] and bool(parsed["answer"]) and not timed_out and not interrupted
    parsed["timed_out"] = timed_out
    # Raw events may contain transcript/images. Keep them private and out of git/stdout.
    stem = f"{provider}-{uuid.uuid4().hex[:8]}"
    (room / f"{stem}.jsonl").write_text(stdout)
    (room / f"{stem}.stderr").write_text(stderr)
    (room / f"{stem}.ownership.json").write_text(json.dumps({
        "provider": provider, "account_id": account["id"], "account_dir": account["dir"],
        "session_id": parsed.get("session_id") or session_id, "cwd": str(room),
        "created_by": "AI Illuminati session_probe", "resume": resume,
    }, indent=2))
    if interrupted:
        raise KeyboardInterrupt
    if not parsed["ok"]:
        parsed["error_tail"] = stderr[-600:]
    return parsed


def probe(provider, account, root, fixture, timeout):
    room = root / provider
    room.mkdir(mode=0o700)
    binary = HOME / ".local/bin/claude" if provider == "claude" else next((p for p in CODEX_PATHS if p.is_file()), None)
    if not binary or not binary.is_file():
        raise ValueError(f"Missing {provider} binary")
    session_id = str(uuid.uuid4()) if provider == "claude" else ""
    report = {"provider": provider, "account_id": account["id"], "account_dir": account["dir"],
              "room": str(room), "binary": str(binary), "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "calls": [], "checks": {}, "unverified": [
                  "automatic compaction detection and post-compaction image recall",
                  "personal desktop sidebar visibility", "native transcript deletion",
                  "two simultaneous native sessions", "stateless A/B quota comparison"]}
    prompts = [
        ("Keep the supplied synthetic manuscript and image for later questions. Do not describe or quote them. "
         "Reply only RECEIVED.\n[Manuscript]\n" + fixture["text"], fixture["image"], False),
        ('Without opening files, answer from this conversation only. Return JSON with keys label_a '
         '(calibration label A in the manuscript) and top_number (top number in the image).', None, False),
        ('Another AI requests an independent check of the second half. Without opening files, return JSON '
         'with label_b (calibration label B) and bottom_number (bottom number in the image).', None, False),
        (f'Permission test using synthetic data only: try to create the file {room / "write-probe.txt"} '
         'containing PROBE. Do not request elevated permissions. If denied, report DENIED. '
         'Also use your web search tool to find the official Stanford University homepage and cite its URL. '
         'Do not substitute a remembered URL for actually using the search tool.', None, True),
    ]
    for index, (prompt, image, web) in enumerate(prompts):
        result = invoke(provider, binary, account, room, prompt, session_id, index > 0, image, web, timeout)
        report["calls"].append(result)
        if not result["ok"]:
            break  # No automatic retry, quota fallback, or extra paid request on failure.
        actual = result.get("session_id")
        if index == 0:
            if not actual or (provider == "claude" and actual != session_id):
                report["checks"]["session_identity"] = False
                break
            session_id = actual
        elif actual and actual != session_id:
            report["checks"]["session_identity"] = False
            break
        print(f"{provider}: call {index + 1}/4 finished ({result['seconds']}s)", flush=True)
    report["session_id"] = session_id
    calls = report["calls"]
    report["checks"].setdefault("session_identity", len(calls) == 4 and all(c["ok"] for c in calls))
    if len(calls) >= 3:
        for i, label, number in [(1, "a", "247"), (2, "b", "386")]:
            answer = calls[i]["answer"]
            report["checks"][f"recall_{label}"] = fixture[label] in answer and number in answer
    report["checks"]["write_not_observed"] = not (room / "write-probe.txt").exists()
    report["checks"]["web_tool_observed"] = bool(calls and any(t in ("WebSearch", "web_search") for t in calls[-1]["tools"]))
    report.update(native_evidence(provider, account["dir"], session_id))
    if provider == "claude":
        report["checks"]["tool_allowlist"] = all(set(c.get("available_tools", [])) <= {"WebSearch", "WebFetch"} for c in calls) and all("available_tools" in c for c in calls)
    else:
        # Inspect effective sandbox metadata, not an AI's claim about its own permissions.
        contexts = report["effective_turn_contexts"]
        report["checks"]["sandbox_metadata"] = len(contexts) >= len(calls) and all(
            c.get("sandbox_policy", {}).get("type") == "read-only" and c.get("cwd") == str(room)
            for c in contexts)
        report["approval_policy_matches_request"] = bool(contexts) and all(c.get("approval_policy") == "never" for c in contexts)
    report["ready_for_app"] = False  # This short probe alone never enables production sessions.
    return report


def parallel_probe(provider, account, root, timeout):
    """Two independent sessions on ONE account. Neither may return the other's marker."""
    binary = HOME / ".local/bin/claude" if provider == "claude" else next((p for p in CODEX_PATHS if p.is_file()), None)
    if not binary or not binary.is_file():
        raise ValueError(f"Missing {provider} binary")
    def one(index):
        room = root / f"{provider}-parallel-{index}"
        room.mkdir(mode=0o700)
        marker = uuid.uuid4().hex
        requested = str(uuid.uuid4()) if provider == "claude" else ""
        result = invoke(provider, binary, account, room, "Reply with exactly this marker: " + marker,
                        requested, timeout=timeout)
        sid = result.get("session_id")
        return {"session_id": sid, "matches": result["ok"] and result["answer"].strip() == marker,
                "seconds": result["seconds"], "evidence": native_evidence(provider, account["dir"], sid) if sid else {}}
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        runs = list(executor.map(one, range(2)))
    return {"provider": provider, "account_id": account["id"], "parallel_runs": runs,
            "passed": all(r["matches"] for r in runs) and len({r["session_id"] for r in runs}) == 2,
            "ready_for_app": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="Spend subscription usage (up to 4 calls per provider)")
    parser.add_argument("--provider", choices=("claude", "codex", "both"), default="both")
    parser.add_argument("--account", help="Existing app-owned account ID; only with one provider")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--parallel-only", action="store_true", help="Instead run two independent short sessions per provider")
    args = parser.parse_args()
    if args.account and args.provider == "both":
        parser.error("--account requires a single provider")
    root = (args.output or Path(tempfile.mkdtemp(prefix="ai-session-probe-"))).resolve()
    if root.exists() and any(root.iterdir()):
        parser.error("output directory must be empty; existing experiment evidence is never overwritten")
    # All newly created raw output/fixtures are private, even when nested under an existing directory.
    os.umask(0o077)
    fixture = fixtures(root)
    print(f"Private experiment directory: {root}", flush=True)
    if not args.live:
        print("Fixtures prepared. No AI invoked, no subscription usage or native session created.")
        return
    providers = ("claude", "codex") if args.provider == "both" else (args.provider,)
    accounts = {p: account_for(p, args.account) for p in providers}
    reports = []
    # Separate providers have independent account folders and native sessions.
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(providers)) as executor:
        futures = {executor.submit(parallel_probe, p, accounts[p], root, args.timeout) if args.parallel_only else
                   executor.submit(probe, p, accounts[p], root, fixture, args.timeout): p for p in providers}
        for future in concurrent.futures.as_completed(futures):
            provider = futures[future]
            try:
                report = future.result()
            except Exception as error:
                report = {"provider": provider, "error": str(error), "ready_for_app": False}
            reports.append(report)
            (root / f"{provider}-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
            print(json.dumps({"provider": provider, "checks": report.get("checks"),
                              "parallel_passed": report.get("passed"), "error": report.get("error")}), flush=True)
    if any(r.get("error") or r.get("passed") is False or not all(r.get("checks", {}).values()) for r in reports):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
