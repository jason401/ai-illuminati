#!/usr/bin/env python3
"""Check declared and actual Swift module edges before compiling (no app data)."""
import re
import sys
from pathlib import Path

# Allowed direction, not a registration mechanism. New edges require a boundary decision.
ALLOWED = {
    "AIAccounts": set(),
    "AILocalization": set(),
    "AISpaces": {"AIAccounts", "AILocalization"},
    "AIRuntime": {"AIAccounts", "AILocalization"},
    "AIWorkspace": {"AIAccounts", "AILocalization", "AIRuntime"},
    "AIProjects": {"AIAccounts", "AILocalization", "AIRuntime", "AIWorkspace"},
    "AIChat": {"AIAccounts", "AILocalization", "AIRuntime", "AIWorkspace", "AIProjects", "AISpaces"},
    "AIIntegrations": {"AIAccounts", "AILocalization", "AIRuntime", "AIWorkspace"},
}
# Swift must also see modules named by a dependency's public interface.
INTERFACE_ONLY = {"AIIntegrations": {"AIRuntime"}}


def code_only(source):
    """Mask nested comments and Swift literals, keeping line boundaries."""
    token = re.compile(r'/\*|//[^\n]*|(?P<raw>\#*)(?P<quote>"""|")')
    out, pos = [], 0
    while match := token.search(source, pos):
        out.append(source[pos:match.start()])
        start = match.start()
        if match.group() == "/*":
            depth, end = 1, match.end()
            while depth:
                found = re.search(r'/\*|\*/', source[end:])
                if not found:
                    end = len(source)
                    break
                end += found.end()
                depth += 1 if found.group() == "/*" else -1
        elif match.group().startswith("//"):
            end = match.end()
        else:
            closing = match.group("quote") + match.group("raw")
            end = match.end()
            while True:
                at = source.find(closing, end)
                if at < 0:
                    end = len(source)
                    break
                # An escaped delimiter is not the end of a normal Swift string.
                back = at - 1
                while back >= 0 and source[back] == "\\":
                    back -= 1
                end = at + len(closing)
                if match.group("raw") or (at - 1 - back) % 2 == 0:
                    break
        out.append(re.sub(r'[^\n]', ' ', source[start:end]))
        pos = end
    out.append(source[pos:])
    return "".join(out)


def imports(source):
    pattern = r'\bimport\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z_]\w*)'
    return set(re.findall(pattern, code_only(source)))


def check(root):
    errors, graph = [], {}
    modules = root / "app/modules"
    found = {p.name for p in modules.iterdir() if p.is_dir()}
    if found != set(ALLOWED):
        errors.append(f"module map differs: {sorted(found ^ set(ALLOWED))}")
    for name in sorted(found):
        folder = modules / name
        declaration = folder / "dependencies"
        deps = declaration.read_text().split() if declaration.exists() else []
        graph[name] = set(deps)
        if len(deps) != len(set(deps)):
            errors.append(f"{name}: repeated dependency")
        for dep in deps:
            if dep not in ALLOWED.get(name, set()):
                errors.append(f"{name}: forbidden dependency {dep} (reverse or unknown edge)")
        used = set()
        for file in sorted(folder.glob("*.swift")):
            for dep in imports(file.read_text()):
                if dep in found or dep.startswith("AI"):
                    used.add(dep)
                    if dep not in graph[name]:
                        errors.append(f"{file.relative_to(root)}: undeclared import {dep}")
                    if dep not in ALLOWED.get(name, set()):
                        errors.append(f"{file.relative_to(root)}: forbidden import {dep}")
        unused = graph[name] - used - INTERFACE_ONLY.get(name, set())
        if unused:
            errors.append(f"{name}: unused dependencies {sorted(unused)}")
    visiting, done = set(), set()

    def visit(name):
        if name in visiting:
            errors.append(f"dependency cycle at {name}")
            return
        if name in done:
            return
        visiting.add(name)
        for dep in sorted(graph.get(name, set())):
            visit(dep)
        visiting.remove(name)
        done.add(name)

    for name in sorted(graph):
        visit(name)
    for file in sorted((root / "app/macos").glob("*.swift")):
        for dep in imports(file.read_text()):
            if dep.startswith("AI") and dep not in found:
                errors.append(f"{file.relative_to(root)}: unknown import {dep}")
    return errors


if __name__ == "__main__":
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
    failures = check(root)
    for failure in failures:
        print("FAIL: " + failure, file=sys.stderr)
    if failures:
        sys.exit(1)
    print("PASS: module dependencies and imports follow the declared direction")
