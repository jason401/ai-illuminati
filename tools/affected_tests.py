#!/usr/bin/env python3
"""Which tests changed paths need (tools/test_map.txt). Run through tools/affected_tests.sh.

pick PATH...   prints `ALL <reason>`, or lines `contract <Module>`, `test <runTest name>`, `stage space_web`
check          the map against docs/MODULES.md and the tests (check_modules.sh G6); prints problems, exit 1
"""
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAP = "tools/test_map.txt"
MODE2 = "tools/tests/mode2.swift"
RUN = "tools/tests/run_mode2.sh"
SPACE_WEB = "space_web"
# Guard devices, the selection itself and code under every test: a change there can change what any test means.
ALWAYS_ALL = {
    "tools/check_modules.sh", "tools/check_modules.py", "tools/check_module_dependencies.py",
    "tools/tests/test_module_dependencies.py", "tools/module_graph.txt", "tools/module_extensions.txt",
    "tools/build_modules.sh", "tools/setup_dev.sh", "tools/module_guard.sha256", ".githooks/pre-commit",
    ".githooks/pre-push", RUN, MODE2, MAP, "tools/affected_tests.sh", "tools/affected_tests.py",
    "tools/app_files.txt", "tools/build_app.sh", "app/macos/ToolHub.swift", "app/macos/main.swift",
    "app/macos/Settings.swift", "app/macos/ChatLinksApp.swift", "app/macos/RunConditionsApp.swift",
    "docs/MODULES.md", ".ai-illuminati.json",
}
DECL = re.compile(r"^(?:@\w+(?:\([^)]*\))?[ \t]+)*((?:(?:private|fileprivate|internal|public|final|indirect)[ \t]+)*)"
                  r"(func|let|var|struct|class|enum|actor|typealias|protocol|extension)[ \t]+([A-Za-z_]\w*)", re.M)


def text(rel):
    return (ROOT / rel).read_text()


def modules():
    return sorted(p.name for p in (ROOT / "app/modules").iterdir() if p.is_dir())


def contract_file(name):
    return f"tools/tests/{name.removeprefix('AI').lower()}_contract.swift"


def dependents(name):
    """The module and every module that depends on it, directly or not."""
    deps = {m: set((ROOT / "app/modules" / m / "dependencies").read_text().split()) for m in modules()}
    found = {name}
    while True:
        more = {m for m, d in deps.items() if d & found} - found
        if not more:
            return found
        found |= more


def run_tests():
    """runTest names in mode2.swift, in their order."""
    return re.findall(r'^runTest\("(\w+)", \1\)', text(MODE2), re.M)


def compiled():
    """The files of run_mode2 stage 8 (the app test binary), besides mode2.swift."""
    run = text(RUN)
    stage = run[run.index('"[8/11]'):run.index('"[9/11]')]
    return re.findall(r"(?:app/macos|tools/tests)/\w+\.swift", stage)


def defined_in(rel):
    return [n for n in run_tests() if re.search(r"^func " + n + r"\(\)", text(rel), re.M)]


def read_map():
    lines = []
    for number, line in enumerate(text(MAP).splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        path, _, rest = line.partition("\t")
        lines.append((number, path, rest.split()))
    return lines


def test_file(rel):
    """A test file that is not in the map: its own tests, or ALL (as a reason string)."""
    for name in modules():
        if rel == contract_file(name):
            return [("contract", name)]
    if rel == "tools/tests/space_web.swift":
        return [("stage", SPACE_WEB)]
    if rel not in compiled():
        return f"{rel} is not in the app test binary (stage 8)"
    if re.search(r"^extension\b", text(rel), re.M):
        return f"{rel} extends a type: every test may see it"
    own = defined_in(rel)
    if not own:
        return f"{rel} has no runTest function"
    others = "\n".join(text(f) for f in compiled() + [MODE2] if f != rel)
    for match in DECL.finditer(text(rel)):
        private, name = "private" in match.group(1), match.group(3)
        if not private and name not in own and re.search(r"\b" + name + r"\b", others):
            return f"{rel} defines {name}, which other tests use"
    return [("test", n) for n in own]


def normalize(path):
    if not path or "\n" in path:
        return None
    full = os.path.realpath(path if os.path.isabs(path) else ROOT / path)
    rel = os.path.relpath(full, os.path.realpath(ROOT))
    return None if rel.startswith("..") or rel == "." else rel


def pick(paths):
    problems = check()
    if problems:
        return f"{MAP} does not match its documents ({problems[0]})"
    if not paths:
        return "no changed paths given"
    entries = {path: tests for _, path, tests in read_map()}
    chosen = set()
    for path in paths:
        rel = normalize(path)
        if rel is None:
            return f"{path} is outside the project"
        if rel in ALWAYS_ALL or rel.startswith((".githooks/", "app/resources/", "docs/api/")):
            return f"{rel} is a guard device or shared by every test"
        match = re.fullmatch(r"app/modules/(\w+)/[^/]+\.swift", rel)
        key = f"app/modules/{match.group(1)}/" if match else rel
        if key in entries:
            tests = entries[key]
            if tests[0] == "ALL":
                return f"{key}: {' '.join(tests[1:])}"
            chosen |= {("stage", t) if t == SPACE_WEB else ("test", t) for t in tests}
            if match:
                chosen |= {("contract", m) for m in dependents(match.group(1))}
        elif rel.startswith("tools/tests/") and rel.endswith(".swift"):
            found = test_file(rel)
            if isinstance(found, str):
                return found
            chosen |= set(found)
        else:
            return f"{rel} is not in {MAP}"
    order = {n: i for i, n in enumerate(modules() + run_tests() + [SPACE_WEB])}
    kinds = {"contract": 0, "test": 1, "stage": 2}
    return sorted(chosen, key=lambda c: (kinds[c[0]], order[c[1]]))


def doc_sections(name):
    """The `### <Module>` sections of docs/MODULES.md (AIChat has two)."""
    doc = text("docs/MODULES.md")
    return [m.group(1) for m in re.finditer(r"^### " + name + r"\b[^\n]*\n(.*?)(?=^##)", doc, re.M | re.S)]


def check():
    problems, names, seen = [], set(run_tests()), set()
    files = {Path(f).stem: f for f in compiled() if f.startswith("tools/tests/")}
    for number, path, tests in read_map():
        where = f"{MAP}:{number}"
        if path in seen:
            problems.append(f"{where}: {path} is listed twice")
        seen.add(path)
        if path in ALWAYS_ALL:
            problems.append(f"{where}: {path} always runs every test; it has no line")
        module = re.fullmatch(r"app/modules/(\w+)/", path)
        if module and module.group(1) not in modules():
            problems.append(f"{where}: no module {module.group(1)}")
        if not module and path not in compiled():
            problems.append(f"{where}: {path} is not in the app test binary (run_mode2 stage 8)")
        if not tests:
            problems.append(f"{where}: no tests")
            continue
        if tests[0] == "ALL":
            if len(tests) < 2:
                problems.append(f"{where}: ALL needs its reason")
            continue
        for t in tests:
            if t not in names and t != SPACE_WEB:
                problems.append(f"{where}: {t} is not a runTest in {MODE2}")
        if module:
            sections = doc_sections(module.group(1))
            if not sections:
                problems.append(f"{where}: docs/MODULES.md has no ### {module.group(1)} section")
            doc = "\n".join(sections)
            want = {t for t in re.findall(r"\b(test[A-Z]\w*)", doc) if t in names}
            for stem, rel in files.items():
                if re.search(r"\b" + stem + r"\b", doc):
                    want |= set(defined_in(rel))
            if re.search(r"\b" + SPACE_WEB + r"\b", doc):
                want.add(SPACE_WEB)
            for t in sorted(want - set(tests)):
                problems.append(f"{where}: {module.group(1)} has no {t}, which its rows in docs/MODULES.md name")
    for name in modules():
        if f"app/modules/{name}/" not in seen:
            problems.append(f"{MAP}: no line for app/modules/{name}/")
    return problems


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "pick":
        result = pick(sys.argv[2:])
        print(f"ALL {result}" if isinstance(result, str) else "\n".join(f"{k} {n}" for k, n in result))
    elif command == "check":
        problems = check()
        print("\n".join(problems))
        sys.exit(1 if problems else 0)
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
