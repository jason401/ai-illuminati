"""Offline checks: never invokes a model or loads a real account."""
import tempfile
import unittest
from unittest.mock import patch
import json
from pathlib import Path
from session_probe import account_for, command, events_from, fixtures, summary, native_evidence


class SessionProbeTests(unittest.TestCase):
    def test_resume_reasserts_permissions_and_never_uses_last(self):
        for provider in ("claude", "codex"):
            args, stdin = command(provider, "/fake/tool", "delta only", "test-id", resume=True, web=True)
            self.assertNotIn("--last", args)
            self.assertNotIn("--continue", args)
            self.assertNotIn("--ephemeral", args)
            self.assertNotIn("--no-session-persistence", args)
            self.assertIn("test-id", args)
            if provider == "codex":
                self.assertIn('sandbox_mode="read-only"', args)
                self.assertIn('approval_policy="never"', args)
                self.assertIn('web_search="live"', args)
                self.assertEqual(stdin, "delta only")
            else:
                self.assertIn("--safe-mode", args)
                self.assertIn("--resume", args)
                self.assertIn("WebSearch,WebFetch", args)
                self.assertNotIn("Bash", args)

    def test_event_parsing_does_not_treat_errors_as_answers(self):
        events = events_from('noise\n{"type":"thread.started","thread_id":"s1"}\n'
                             '{"type":"item.completed","item":{"type":"agent_message","text":"answer"}}\n'
                             '{"type":"turn.failed","error":{"message":"quota"}}')
        parsed = summary("codex", events)
        self.assertEqual(parsed["session_id"], "s1")
        self.assertEqual(parsed["answer"], "answer")
        self.assertTrue(parsed["is_error"])
        self.assertFalse(parsed["completed"])

    def test_default_personal_and_escaped_folders_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            app_root = home / ".ai-illuminati/accounts"
            allowed = app_root / "owned"
            allowed.mkdir(parents=True)
            personal = home / ".codex"
            personal.mkdir()
            config = home / "Library/Application Support/AI Illuminati/accounts.json"
            config.parent.mkdir(parents=True)
            config.write_text(json.dumps([
                {"provider": "codex", "id": "personal", "dir": None},
                {"provider": "codex", "id": "outside", "dir": str(personal)},
                {"provider": "codex", "id": "owned", "dir": str(allowed)},
            ]))
            with patch("session_probe.HOME", home):
                self.assertEqual(account_for("codex")["id"], "owned")
                with self.assertRaises(ValueError):
                    account_for("codex", "personal")
                with self.assertRaises(ValueError):
                    account_for("codex", "outside")

    def test_native_evidence_only_reads_owned_uuid(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "sessions"
            root.mkdir()
            owned = "00000000-0000-4000-8000-000000000001"
            (root / f"rollout-{owned}.jsonl").write_text(json.dumps({"type": "turn_context", "payload": {
                "sandbox_policy": {"type": "read-only"}, "approval_policy": "on-request", "cwd": "/room"}}))
            (root / "rollout-other.jsonl").write_text("not even JSON")
            observed = native_evidence("codex", directory, owned)
            self.assertEqual(len(observed["native_transcripts"]), 1)
            self.assertEqual(observed["effective_turn_contexts"][0]["sandbox_policy"], {"type": "read-only"})
            self.assertEqual(native_evidence("codex", directory, "")["native_transcripts"], [])

    def test_claude_tools_and_compaction_are_observed(self):
        parsed = summary("claude", [
            {"type": "system", "subtype": "init", "tools": ["WebSearch"], "session_id": "s1"},
            {"type": "system", "subtype": "compact_boundary"},
            {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "WebSearch"}]}},
            {"type": "result", "session_id": "s1", "result": "answer", "is_error": False},
        ])
        self.assertEqual(parsed["tools"], ["WebSearch"])
        self.assertEqual(parsed["compaction_events"], ["system:compact_boundary"])
        self.assertEqual(parsed["available_tools"], ["WebSearch"])

    def test_fixtures_and_image_only_on_first_call(self):
        with tempfile.TemporaryDirectory() as directory:
            f = fixtures(Path(directory))
            self.assertGreater(len(f["text"]), 20000)
            self.assertTrue(f["image"].read_bytes().startswith(b"\x89PNG"))
            args, stdin = command("claude", "/fake/tool", "first", "s1", image=f["image"])
            self.assertIn('"type": "image"', stdin)
            args, stdin = command("claude", "/fake/tool", "next", "s1", resume=True)
            self.assertNotIn('"type": "image"', stdin)


if __name__ == "__main__":
    unittest.main()
