"""Live macOS install/upgrade check using disposable, account-free fixture apps."""
from pathlib import Path
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid

repo = Path(__file__).resolve().parents[2]
identity = 'AI Illuminati Local Signing'
with tempfile.TemporaryDirectory(prefix='ai-install-live-') as directory:
    root = Path(directory)
    support = root / 'support'
    support.mkdir()
    source = root / 'fixture.swift'
    source.write_text('''import Cocoa
final class Delegate: NSObject, NSApplicationDelegate {
 func applicationDidFinishLaunching(_ note: Notification) {
  let b = Bundle.main
  let support = URL(fileURLWithPath: b.object(forInfoDictionaryKey: "AITestSupport") as! String)
  let updates = support.appendingPathComponent("updates")
  if let d = try? Data(contentsOf: updates.appendingPathComponent("transaction.json")),
     let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
     let token = r["token"] as? String {
   let ack: [String: Any] = ["revision": b.object(forInfoDictionaryKey: "AISourceRevision") as! String,
                             "pid": ProcessInfo.processInfo.processIdentifier]
   try! JSONSerialization.data(withJSONObject: ack).write(to: updates.appendingPathComponent(token + ".ack"), options: .atomic)
  }
  NSApp.terminate(nil)
 }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.run()
''')
    binary = root / 'fixture'
    subprocess.run(['xcrun', 'swiftc', str(source), '-o', str(binary)], check=True)
    target = root / 'Applications/AI Illuminati.app'
    previous = root / 'original.app'
    def make(app, revision):
        resources = app / 'Contents/Resources'
        resources.mkdir(parents=True)
        (app / 'Contents/MacOS').mkdir()
        shutil.copy2(binary, app / 'Contents/MacOS/AIIlluminati')
        for name in ['workspace_mcp.py', 'WorkspaceDocument', 'install_app.py', 'InstallBridge']:
            (resources / name).write_text('fixture')
        data = dict(CFBundleIdentifier='local.aiilluminati', CFBundleExecutable='AIIlluminati',
                    CFBundlePackageType='APPL', CFBundleVersion=revision, LSUIElement=True,
                    AISourceRevision=revision, AITestSupport=str(support))
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(data))
        subprocess.run(['codesign', '--force', '--sign', identity, str(app)], check=True, capture_output=True)
    make(previous, '1')
    current = previous
    for revision in ['2', '3']:
        candidate = root / ('candidate' + revision + '.app')
        make(candidate, revision)
        parent = subprocess.Popen(['/bin/sleep', '120'])
        token = str(uuid.uuid4())
        helper = subprocess.Popen(['/usr/bin/python3', str(repo / 'tools/install_app.py'),
            '--staged', str(candidate), '--target', str(target), '--current', str(current),
            '--support', str(support), '--pid', str(parent.pid), '--token', token])
        try:
            ready = support / 'updates' / (token + '.ready')
            deadline = time.monotonic() + 20
            while not ready.exists():
                if helper.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('Installer did not prepare')
                time.sleep(.1)
            parent.terminate()
            parent.wait()
            if helper.wait(timeout=90) != 0:
                raise RuntimeError('Installation failed')
            state = json.loads((support / 'update.json').read_text())
            assert state['status'] == 'updated' and state['current'] == revision, state
            current = target
            print('PASS: live signed install/startup acknowledgement, revision ' + revision)
        finally:
            if parent.poll() is None:
                parent.terminate()
                parent.wait()
            if helper.poll() is None:
                helper.terminate()
                helper.wait()
