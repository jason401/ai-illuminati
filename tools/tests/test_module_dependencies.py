#!/usr/bin/env python3
"""Falsify dependency rules in disposable source trees, never the real app home."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("module_dependencies", Path(__file__).resolve().parents[1] / "check_module_dependencies.py")
rules = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rules)


class DependencyRules(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "app/macos").mkdir(parents=True)
        for name, deps in rules.ALLOWED.items():
            folder = self.root / "app/modules" / name
            folder.mkdir(parents=True)
            if deps:
                (folder / "dependencies").write_text("\n".join(sorted(deps)) + "\n")
            used = deps - rules.INTERFACE_ONLY.get(name, set())
            (folder / "Value.swift").write_text("import Foundation\n" + "".join("import " + dep + "\n" for dep in sorted(used)))

    def test_current_direction_and_interface_only_dependency(self):
        self.assertEqual(rules.check(self.root), [])

    def test_reverse_edge_even_when_declared(self):
        folder = self.root / "app/modules/AIRuntime"
        with (folder / "dependencies").open("a") as out:
            out.write("AIChat\n")
        with (folder / "Value.swift").open("a") as out:
            out.write("import AIChat\n")
        errors = rules.check(self.root)
        self.assertTrue(any("forbidden dependency AIChat" in e for e in errors), errors)
        self.assertTrue(any("dependency cycle" in e for e in errors), errors)

    def test_undeclared_import_in_supported_forms(self):
        file = self.root / "app/modules/AIAccounts/Value.swift"
        for form in ["import AIChat", "@_exported import AIChat", "@preconcurrency import AIChat",
                     "@_spi(Tests) import AIChat", "import struct AIChat.Conversation",
                     "#if canImport(AIChat)\nimport AIChat\n#endif"]:
            with self.subTest(form=form):
                file.write_text(form + "\n")
                self.assertTrue(any("undeclared import AIChat" in e for e in rules.check(self.root)))

    def test_unknown_and_unused_declarations(self):
        file = self.root / "app/modules/AIIntegrations/dependencies"
        file.write_text(file.read_text() + "AIMissing\n")
        self.assertTrue(any("forbidden dependency AIMissing" in e for e in rules.check(self.root)))
        file = self.root / "app/modules/AIWorkspace/Value.swift"
        file.write_text(file.read_text().replace("import AIRuntime\n", ""))
        self.assertTrue(any("unused dependencies ['AIRuntime']" in e for e in rules.check(self.root)))

    def test_comments_and_literals_are_not_imports(self):
        source = '/* nested /* import AIChat */ import AIRuntime */\n// import AIChat\n'
        source += 'let a = "import AIChat"\nlet b = #"import AIChat"#\n'
        source += 'let c = """\nimport AIChat\n"""\nimport Foundation\n'
        self.assertEqual(rules.imports(source), {"Foundation"})

    def test_map_and_duplicate_declarations(self):
        (self.root / "app/modules/AINew").mkdir()
        self.assertTrue(any("module map differs" in e for e in rules.check(self.root)))
        file = self.root / "app/modules/AIRuntime/dependencies"
        file.write_text(file.read_text() + "AIAccounts\n")
        self.assertTrue(any("repeated dependency" in e for e in rules.check(self.root)))


if __name__ == "__main__":
    unittest.main()
