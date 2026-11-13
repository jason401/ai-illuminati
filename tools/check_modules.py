#!/usr/bin/env python3
"""Module guards (docs/MODULES.md "Rules"). Run through tools/check_modules.sh.

fast                 G2-G7 from the files alone (no compiler); G1 is check_module_dependencies.py.
slow MODULES TMP     S1 public API snapshots, S2 boundary files, S3 App size, on modules built by build_modules.sh.
snapshot MODULES     writes docs/api/<Module>.txt from built modules (after a reviewed public change).
guard                prints the lines of tools/module_guard.sha256 for the current files.
"""
import difflib
import glob
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from check_module_dependencies import code_only  # noqa: E402

MODULES = ROOT / "app/modules"
GUARD = ROOT / "tools/module_guard.sha256"
# The guard devices themselves (G7): changing one shows up as a hash change in the same commit.
GUARDED = ["tools/check_modules.sh", "tools/check_modules.py", "tools/check_module_dependencies.py",
           "tools/tests/test_module_dependencies.py", "tools/module_graph.txt", "tools/module_extensions.txt",
           "tools/build_modules.sh", "tools/setup_dev.sh", ".githooks/pre-commit", ".githooks/pre-push"]
MODE2 = "tools/tests/run_mode2.sh"
BLOCK = re.compile(r"^# >>> module checks.*?^# <<< module checks[^\n]*$", re.M | re.S)
MODE2_BLOCKS = 2
warnings, failures = [], []


def modules():
    return sorted(p.name for p in MODULES.iterdir() if p.is_dir())


def contract(name):
    return ROOT / "tools/tests" / (name.removeprefix("AI").lower() + "_contract.swift")


def rows(path):
    return [line for line in path.read_text().splitlines() if line.strip() and not line.lstrip().startswith("#")]


def section(text, heading):
    """The text under a `## heading` line, up to the next `## `."""
    match = re.search(r"^## " + re.escape(heading) + r"[^\n]*\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    return match.group(1) if match else None


def g2_required_files():
    for name in modules():
        folder = MODULES / name
        if not (folder / "dependencies").is_file():
            failures.append(f"G2 {name}: no dependencies file (an empty one means none)")
        if not contract(name).is_file():
            failures.append(f"G2 {name}: no contract test {contract(name).relative_to(ROOT)}")
        boundary = folder / "boundary"
        if not boundary.is_file():
            failures.append(f"G2 {name}: no boundary file")
        elif not rows(boundary) and "# none:" not in boundary.read_text():
            failures.append(f"G2 {name}: boundary has no check and no `# none: <reason>` line")
        if not (ROOT / "docs/api" / f"{name}.txt").is_file():
            failures.append(f"G2 {name}: no API snapshot docs/api/{name}.txt")
    for path in sorted(glob.glob(str(ROOT / "tools/tests/*_contract.swift"))):
        stem = Path(path).stem.removesuffix("_contract")
        if not any(contract(name).stem.removesuffix("_contract") == stem for name in modules()):
            failures.append(f"G2 {Path(path).name}: a contract test with no module")


def g3_app_files():
    listed = {}
    for line in rows(ROOT / "tools/app_files.txt"):
        file, _, reason = line.partition(" ")
        if not reason.strip():
            failures.append(f"G3 tools/app_files.txt: {file} has no reason")
        listed[file] = reason
    found = {Path(p).name for p in glob.glob(str(ROOT / "app/macos/*.swift"))}
    for file in sorted(found - set(listed)):
        failures.append(f"G3 app/macos/{file}: not in tools/app_files.txt (does it belong in a module? AGENTS.md \"Module rules\")")
    for file in sorted(set(listed) - found):
        failures.append(f"G3 tools/app_files.txt: {file} is listed but missing")


OWNED = re.compile(r"^(?:@\w+(?:\([^)]*\))?[ \t]+)*(?:public|open)[ \t]+(?:(?:final|indirect)[ \t]+)*"
                   r"(?:class|struct|enum|protocol|actor|typealias)[ \t]+([A-Z]\w*)", re.M)
EXTENSION = re.compile(r"^[ \t]*(?:@\w+[ \t]+)*(?:(?:public|private|fileprivate|internal)[ \t]+)?extension[ \t]+([A-Z]\w*)", re.M)


def g4_extensions():
    """Another module's type extended outside it. Warning only until it has shown no false hits."""
    owner = {}
    for name in modules():
        for file in (MODULES / name).glob("*.swift"):
            for typ in OWNED.findall(code_only(file.read_text())):
                owner.setdefault(typ, set()).add(name)
    allowed = set()
    for line in rows(ROOT / "tools/module_extensions.txt"):
        parts = line.split("\t")
        if len(parts) < 3 or not parts[2].strip():
            failures.append(f"G4 tools/module_extensions.txt: `{line}` needs file<TAB>type<TAB>reason")
        allowed.add(tuple(parts[:2]))
    files = sorted(glob.glob(str(ROOT / "app/macos/*.swift")) + glob.glob(str(MODULES / "*/*.swift")))
    for path in files:
        rel = str(Path(path).relative_to(ROOT))
        mine = rel.split("/")[2] if rel.startswith("app/modules/") else None
        text = code_only(Path(path).read_text())
        for match in EXTENSION.finditer(text):
            typ = match.group(1)
            if typ in owner and mine not in owner[typ] and (rel, typ) not in allowed:
                line = text.count("\n", 0, match.start()) + 1
                warnings.append(f"G4 {rel}:{line}: extension of {typ} ({'/'.join(sorted(owner[typ]))}) outside its module; "
                                "put the logic in its module, or list it with a reason in tools/module_extensions.txt")


def g5_testable():
    files = glob.glob(str(ROOT / "app/macos/*.swift")) + glob.glob(str(ROOT / "tools/tests/*_contract.swift"))
    for path in sorted(files):
        if re.search(r"@testable\b", code_only(Path(path).read_text())):
            failures.append(f"G5 {Path(path).relative_to(ROOT)}: @testable import (app files and contracts see public names only)")


def g6_documents():
    found = set(modules())
    agents = section((ROOT / "AGENTS.md").read_text(), "Module rules")
    if agents is None:
        failures.append("G6 AGENTS.md: no \"## Module rules\" section")
    else:
        named = set(re.findall(r"`(AI[A-Z]\w*)`", agents))
        if named != found:
            failures.append(f"G6 AGENTS.md \"Module rules\" names {sorted(named)}, the folders are {sorted(found)}")
        if len(agents) > 2000:
            failures.append(f"G6 AGENTS.md \"Module rules\" is {len(agents)} characters (at most 2000)")
    # CLAUDE.md is kept out of Git here (.git/info/exclude), so a fresh clone may have none.
    size = sum(len((ROOT / f).read_text()) for f in ["AGENTS.md", "CLAUDE.md"] if (ROOT / f).exists())
    if size > 25000:
        failures.append(f"G6 AGENTS.md + CLAUDE.md are {size} characters (at most 25000 of the 30000 the app passes on)")
    mapped = section((ROOT / "docs/MODULES.md").read_text(), "Module map")
    if mapped is None:
        failures.append("G6 docs/MODULES.md: no \"## Module map\" section")
    else:
        named = set(re.findall(r"^### (AI[A-Z]\w*)", mapped, re.M))
        if named != found:
            failures.append(f"G6 docs/MODULES.md \"Module map\" has sections for {sorted(named)}, the folders are {sorted(found)}")


def guard_lines():
    lines = []
    for rel in GUARDED:
        path = ROOT / rel
        digest = hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else "missing"
        lines.append(f"{digest}  {rel}")
    blocks = BLOCK.findall((ROOT / MODE2).read_text())
    digest = hashlib.sha256("\n".join(blocks).encode()).hexdigest() if len(blocks) == MODE2_BLOCKS else f"{len(blocks)}-blocks"
    lines.append(f"{digest}  {MODE2}#module-checks")
    return lines


def g7_guard():
    want = GUARD.read_text().splitlines() if GUARD.exists() else []
    want = [line for line in want if line and not line.startswith("#")]
    changed = [line.split("  ", 1)[1] for line in guard_lines() if line not in want]
    if changed:
        failures.append(f"G7 guard devices changed: {', '.join(changed)}. A guard change needs the user's approval; then "
                        "`zsh tools/check_modules.sh guard > tools/module_guard.sha256` in the same commit")


# Slow checks: on modules built by build_modules.sh.
def api(built, name, tmp):
    out = Path(tmp) / "symbols" / name
    out.mkdir(parents=True, exist_ok=True)
    triple = json.loads(subprocess.run(["xcrun", "swiftc", "-print-target-info"], capture_output=True, text=True,
                                       check=True).stdout)["target"]["triple"]
    sdk = subprocess.run(["xcrun", "--show-sdk-path"], capture_output=True, text=True, check=True).stdout.strip()
    run = subprocess.run(["xcrun", "swift-symbolgraph-extract", "-module-name", name, "-I", f"{built}/.see/{name}",
                          "-I", built, "-target", triple, "-sdk", sdk, "-minimum-access-level", "public",
                          "-skip-synthesized-members", "-module-cache-path", f"{tmp}/guard-cache", "-output-dir", str(out)],
                         capture_output=True, text=True)
    if run.returncode:
        raise SystemExit(f"FAIL: S1 swift-symbolgraph-extract {name}:\n{run.stderr}")
    lines = set()
    for file in sorted(out.glob(f"{name}.symbols.json")) + sorted(out.glob(f"{name}@*.symbols.json")):
        extended = file.name[:-len(".symbols.json")].partition("@")[2]
        for symbol in json.loads(file.read_text())["symbols"]:
            if symbol.get("accessLevel") not in ("public", "open"):
                continue
            declaration = " ".join("".join(f["spelling"] for f in symbol.get("declarationFragments", [])).split())
            lines.add((f"extension {extended}: " if extended else "") + ".".join(symbol["pathComponents"]) + " | " + declaration)
    return "".join(line + "\n" for line in sorted(lines))


def s1_snapshots(built, tmp):
    for name in modules():
        path = ROOT / "docs/api" / f"{name}.txt"
        want = path.read_text() if path.exists() else ""
        have = api(built, name, tmp)
        if have != want:
            diff = "".join(difflib.unified_diff(want.splitlines(True), have.splitlines(True), f"docs/api/{name}.txt", "built"))
            failures.append(f"S1 {name}: public API differs from docs/api/{name}.txt:\n{diff}"
                            "  Give each new public name its reason in docs/MODULES.md, then update the snapshot in the same "
                            "commit: zsh tools/check_modules.sh snapshot")


def s2_boundaries(built, tmp):
    for name in modules():
        checks = [line.split("\t") for line in rows(MODULES / name / "boundary")]
        if not checks:
            continue
        expected = []
        for parts in checks:
            if len(parts) not in (2, 3) or (len(parts) == 3 and parts[2] != "hidden"):
                failures.append(f"S2 {name}/boundary: `{chr(9).join(parts)}` is not code<TAB>name[<TAB>hidden]")
                continue
            if len(parts) == 3:
                # A hidden name must exist inside, or a typo would pass as "cannot find".
                source = "".join(code_only(f.read_text()) for f in (MODULES / name).glob("*.swift"))
                if not re.search(r"\b(?:class|struct|enum|protocol|actor|typealias)\s+" + re.escape(parts[1]) + r"\b", source):
                    failures.append(f"S2 {name}/boundary: hidden {parts[1]} is not a type of {name}")
                expected.append(f"cannot find '{parts[1]}' in scope")
            else:
                expected.append(f"'{parts[1]}' is inaccessible due to 'internal' protection level")
        folder = Path(tmp) / f"boundary-{name}"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "main.swift").write_text(f"import {name}\n" + "".join(parts[0] + "\n" for parts in checks))
        run = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-typecheck", "-module-cache-path", f"{tmp}/guard-cache",
                              "-I", built, str(folder / "main.swift")], capture_output=True, text=True)
        errors = [line for line in run.stderr.splitlines() if ": error: " in line]
        missing = [e for e in expected if not any(e in line for line in errors)]
        other = [line for line in errors if not any(e in line for e in expected)]
        if run.returncode == 0 or missing or other:
            failures.append(f"S2 {name}: code outside reached an internal name, or failed for another reason\n"
                            + "".join(f"  missing: {e}\n" for e in missing) + "".join(f"  other: {e}\n" for e in other))


def s3_app_size():
    baseline = re.search(r"^# baseline-lines: (\d+)", (ROOT / "tools/app_files.txt").read_text(), re.M)
    lines = sum(len(Path(p).read_text().splitlines()) for p in glob.glob(str(ROOT / "app/macos/*.swift")))
    if baseline and lines > int(baseline.group(1)) * 1.1:
        warnings.append(f"S3 app/macos has {lines} lines, over 10% above the baseline {baseline.group(1)} "
                        "(tools/app_files.txt): does new code belong in a module?")
    return lines


def report(label):
    for warning in warnings:
        print("WARN: " + warning, file=sys.stderr)
    for failure in failures:
        print("FAIL: " + failure, file=sys.stderr)
    if failures:
        print("A failing check means the code changes, not the check (AGENTS.md \"Module rules\").", file=sys.stderr)
        sys.exit(1)
    print(f"PASS: {label}")


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "fast"
    if command == "fast":
        g2_required_files(); g3_app_files(); g4_extensions(); g5_testable(); g6_documents(); g7_guard()
        report("module guards G2-G7 (required files, App files, extensions, @testable, documents, guard hashes)")
    elif command == "slow":
        built, tmp = sys.argv[2], sys.argv[3]
        s1_snapshots(built, tmp); s2_boundaries(built, tmp); lines = s3_app_size()
        report(f"public API snapshots, boundary files, App size ({lines} lines)")
    elif command == "snapshot":
        built, tmp = sys.argv[2], sys.argv[3]
        (ROOT / "docs/api").mkdir(exist_ok=True)
        for name in modules():
            (ROOT / "docs/api" / f"{name}.txt").write_text(api(built, name, tmp))
            print(f"wrote docs/api/{name}.txt")
    elif command == "guard":
        print("# sha256 of the module guard devices (G7). Update only with the user's approval: zsh tools/check_modules.sh guard")
        print("\n".join(guard_lines()))
    else:
        sys.exit(__doc__)
