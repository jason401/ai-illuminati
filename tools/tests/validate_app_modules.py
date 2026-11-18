#!/usr/bin/env python3
"""A's reproducible falsification and parallel trial. Writes only disposable project-local artifacts."""
import concurrent.futures
import hashlib
import json
import os
import shutil
import signal
import sys
import subprocess
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS = ROOT / ".ai-illuminati/a-trial"
MAIN = """import Foundation
import AIIntegrations
final class EmptyGoogleStore: GoogleTokenStore {
    func load() throws -> Data? { nil }
    func save(_ data: Data) throws {}
    func clear() throws {}
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { print("FAIL: " + message); exit(1) }
}
GoogleAuth.shared = GoogleAuth(store: EmptyGoogleStore())
testToolHub()
print("PASS: ToolHub order, collision, exposure and revocation")
"""


def run(argv, *, cwd=ROOT, env=None, expected=0, contains=None, timeout=600):
    process = subprocess.Popen([str(a) for a in argv], cwd=cwd, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        output, _ = process.communicate()
        raise RuntimeError(f"timeout: {argv[0]}\n{output[-3000:]}")
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    if expected is not None and ((expected == 0 and process.returncode != 0) or (expected != 0 and process.returncode == 0)):
        raise RuntimeError(f"unexpected exit {process.returncode}: {argv[0]}\n{output[-5000:]}")
    if contains and contains not in output:
        raise RuntimeError(f"missing evidence {contains!r}\n{output[-5000:]}")
    return (process.returncode, output) if expected is None else output


def compile_hub(folder, modules, source):
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "main.swift").write_text(MAIN)
    (folder / "ToolHub.swift").write_text(source)
    argv = ["xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", folder / "cache",
            "-I", modules, "-o", folder / "run", folder / "main.swift", folder / "ToolHub.swift",
            ROOT / "app/macos/DriveTools.swift", ROOT / "app/macos/ExternalMCPTools.swift",
            ROOT / "tools/tests/tool_hub.swift", *sorted(modules.glob("lib*.a"))]
    run(argv)


def test_env(home):
    home.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, AI_ILLUMINATI_TEST_HOME=str(home), PYTHONDONTWRITEBYTECODE="1")
    env.pop("AI_ILLUMINATI_PROJECT_PROCESS", None)
    return env


def falsify(base):
    print("[1/3] Build modules and run the unchanged ToolHub contract", flush=True)
    modules = base / "modules"
    run(["zsh", "tools/build_modules.sh", modules, "-enable-testing", "-module-cache-path", base / "cache"])
    original = (ROOT / "app/macos/ToolHub.swift").read_text()
    folder = base / "baseline"
    compile_hub(folder, modules, original)
    print(run([folder / "run"], env=test_env(folder / "home")), end="", flush=True)
    mutations = [
        ("A1 provider order", "PeerLink.shared, ConveneLink.shared", "ConveneLink.shared, PeerLink.shared",
         "the app supplies all 13 providers in their original order"),
        ("A2 last duplicate wins", "available.first(where:", "available.last(where:",
         "a duplicate tool is called on the first eligible provider"),
        ("A3 inactive provider callable", "$0.active && $0.tools(context:", "$0.tools(context:",
         "inactive providers are absent from both listing and calls"),
        ("A4 consulted Convene filter removed", " && $0 !== ConveneLink.shared", "",
         "consulted provider identities exclude Peer and Convene before their own gates"),
        ("A5 expired sessions accepted", "session.1 > now()", "true",
         "expired sessions cannot list or call"),
    ]
    results = []
    for index, (title, before, after, evidence) in enumerate(mutations):
        assert original.count(before) == 1, title
        folder = base / ("mutation-" + str(index))
        compile_hub(folder, modules, original.replace(before, after))
        run([folder / "run"], env=test_env(folder / "home"), expected=1, contains=evidence)
        print("CAUGHT: " + title + " — " + evidence, flush=True)
        results.append({"mutation": title, "caught_by": "testToolHub: " + evidence})
    run(["python3", "-B", "tools/tests/test_module_dependencies.py"])
    print("CAUGHT: declared reverse dependency, cycle and undeclared imports (DependencyRules)", flush=True)
    return results


def module_test(tree, name, folder, test):
    # This trial deliberately picks the two leaf modules (no dependencies).
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "main.swift").write_text(test)
    module = tree / "app/modules" / name
    run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-module-name", name,
         "-emit-module", "-emit-module-path", folder / (name + ".swiftmodule"), "-emit-library", "-static",
         "-o", folder / ("lib" + name + ".a"), "-module-cache-path", folder / "cache",
         *sorted(module.glob("*.swift"))])
    run(["xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", folder / "cache",
         "-I", folder, "-o", folder / "run", folder / "main.swift", folder / ("lib" + name + ".a")])
    return run([folder / "run"], env=test_env(folder / "home"))


def parallel_trial(base, report):
    print("[2/3] Two independent module changes and tests run concurrently", flush=True)
    barrier = threading.Barrier(2)
    changes = {
        "AIAccounts": ("app/modules/AIAccounts/Accounts.swift", 'case .gemini: return "Gemini"',
                       'case .gemini: return "Google Gemini"'),
        "AILocalization": ("app/modules/AILocalization/Language.swift", "for id in preferred {",
                          "for raw in preferred {\n            let id = raw.lowercased()"),
    }
    accounts = (ROOT / "tools/tests/accounts_contract.swift").read_text()
    accounts += '\nexpect(Account.Provider.gemini.title == "Google Gemini", "trial: Gemini display title")\n'
    localization = """import Foundation
import AILocalization
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { print("FAIL: " + message); exit(1) }
}
expect(AppLanguage.resolve(["KO-KR"]) == .korean, "trial: uppercase Korean")
expect(AppLanguage.resolve(["EN-us", "ko"]) == .english, "trial: first supported language")
expect(AppLanguage.resolve(["ja"]) == .english, "trial: fallback")
AppLanguage.current = .korean
expect(L("한국어", "English") == "한국어", "trial: Korean text")
AppLanguage.current = .english
expect(L("한국어", "English") == "English", "trial: English text")
print("PASS: localization trial")
"""
    tests = {"AIAccounts": accounts, "AILocalization": localization}
    intervals = {}

    def worker(name):
        tree = base / name
        relative, before, after = changes[name]
        file = tree / relative
        file.parent.mkdir(parents=True)
        for source in (ROOT / "app/modules" / name).glob("*.swift"):
            shutil.copy2(source, file.parent / source.name)
        barrier.wait(timeout=30)
        start = time.monotonic()
        original = file.read_text()
        assert original.count(before) == 1
        file.write_text(original.replace(before, after))
        output = module_test(tree, name, tree / "test", tests[name])
        intervals[name] = [start, time.monotonic()]
        return {"module": name, "path": relative, "output": output.strip(), "test": tests[name]}

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        jobs = [executor.submit(worker, name) for name in changes]
        results = [job.result() for job in jobs]
    assert max(v[0] for v in intervals.values()) < min(v[1] for v in intervals.values()), "trial did not overlap"
    paths = [r["path"] for r in results]
    assert len(set(paths)) == len(paths), "trial changed the same path"
    print("PASS: edits and module-only test intervals overlap; changed paths are disjoint", flush=True)
    print("[3/3] Combine both changes and rerun each module contract", flush=True)
    combined = base / "combined"
    shutil.copytree(ROOT / "app", combined / "app")
    shutil.copytree(ROOT / "tools", combined / "tools", ignore=shutil.ignore_patterns("__pycache__"))
    (combined / "tools/tests/accounts_contract.swift").write_text(accounts)
    (combined / "tools/tests/localization_trial.swift").write_text(localization)
    for result in results:
        name, relative = result["module"], result["path"]
        source = base / name / relative
        dest = combined / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        for file in source.parent.glob("*.swift"):
            shutil.copy2(file, dest.parent / file.name)
        print(module_test(combined, name, combined / ("test-" + name), result["test"]), end="", flush=True)
    # Persist the experiment before consumer validation, including a negative result.
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    for result in results:
        name = result["module"]
        target = ARTIFACTS / name
        target.mkdir(exist_ok=True)
        shutil.copy2(combined / result["path"], target / Path(result["path"]).name)
        (target / "contract.swift").write_text(result["test"])
    trial = {"overlap": True, "manual_combination": "disjoint module directories copied; Git conflicts not checked",
             "modules": [{k: v for k, v in r.items() if k != "test"} for r in results],
             "integration": "module contracts passed; consumer validation pending"}
    report["parallel_trial"] = trial
    (ARTIFACTS / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    status, output = run(["zsh", "tools/tests/run_mode2.sh"], cwd=combined, expected=None, timeout=2400)
    if status:
        evidence = next((line for line in output.splitlines() if "Fatal error:" in line or "FAIL:" in line), "exit=" + str(status))
        trial["consumer_test"] = {"passed": False, "exit": status, "evidence": evidence}
        (ARTIFACTS / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        if "everyone must give an opening view first" not in evidence:
            raise RuntimeError("unrelated consumer failure: " + evidence)
        print("CONSUMER CAUGHT: module-only tests missed the Gemini title's opening-speaker effect", flush=True)
    else:
        assert "PASS: the real accounts.json is unchanged" in output
        trial["consumer_test"] = {"passed": True}
        print("PASS: combined trial full run_mode2.sh", flush=True)
    # Reuse the other modules, overlay the two changed leaf modules, then link every app source.
    linked = combined / "link-modules"
    shutil.copytree(base.parent / "modules", linked, symlinks=True)
    for name in changes:
        own = combined / ("test-" + name)
        for source in [*own.glob(name + ".*"), own / ("lib" + name + ".a")]:
            shutil.copy2(source, linked / source.name)
    run(["xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", combined / "link-cache",
         "-I", linked, "-o", combined / "app-link", *sorted((combined / "app/macos").glob("*.swift")),
         *sorted(linked.glob("lib*.a"))], timeout=900)
    print("PASS: combined trial links every app source", flush=True)
    # Save only trial sources and tests under an ignored folder for explicit trial-branch snapshots.
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    for result in results:
        name = result["module"]
        target = ARTIFACTS / name
        target.mkdir(exist_ok=True)
        shutil.copy2(combined / result["path"], target / Path(result["path"]).name)
        (target / "contract.swift").write_text(result.pop("test"))
    trial["app_link"] = "passed"
    trial["integration"] = "module contracts and app link passed; see consumer_test for whether module-only validation was sufficient"
    return trial



if __name__ == "__main__":
    watched = {p: hashlib.sha256(p.read_bytes()).hexdigest()
               for p in (ROOT / "app").glob("**/*.swift")}
    if sys.argv[1:]:
        raise SystemExit("usage: validate_app_modules.py")
    with tempfile.TemporaryDirectory(prefix="a-final-", dir="/tmp") as temp:
        base = Path(temp)
        report = {"falsifications": falsify(base)}
        report["parallel_trial"] = parallel_trial(base / "trial", report)
    assert all(hashlib.sha256(p.read_bytes()).hexdigest() == digest for p, digest in watched.items()), "trial changed app sources"
    report["main_sources_unchanged"] = True
    (ARTIFACTS / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
