import AppKit
import Foundation
import SwiftUI
import WebKit
import AISpaces

// The Space web view's isolation (SpaceWeb.swift), checked in a real WKWebView opened the way the app opens it
// (SpaceView: a SpaceWebView, public names only): a page that skips the checks tries every way out to a local server and to files. Nothing may reach the
// server, file:// must fail, navigation and pop-ups stay put, and only the bridge works. Runs in the test home.

func fail(_ message: String) -> Never { print("FAIL: " + message); exit(1) }

// A local server that only counts who connects.
let server = socket(AF_INET, SOCK_STREAM, 0)
var yes: Int32 = 1
setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
var address = sockaddr_in()
address.sin_family = sa_family_t(AF_INET)
address.sin_addr.s_addr = inet_addr("127.0.0.1")
address.sin_port = 0
_ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
listen(server, 16)
var bound = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
_ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &length) } }
let port = Int(UInt16(bigEndian: bound.sin_port))
guard port > 0 else { fail("no local port") }
var connections = 0
let source = DispatchSource.makeReadSource(fileDescriptor: server, queue: .main)
var requests: [String] = []
source.setEventHandler {
    let client = accept(server, nil, nil)
    guard client >= 0 else { return }
    connections += 1
    var buffer = [UInt8](repeating: 0, count: 300)
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let n = read(client, &buffer, 300)
    requests.append(n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self).components(separatedBy: "\r\n").first ?? "" : "(nothing sent)")
    close(client)
}
source.resume()

let secret = FileManager.default.temporaryDirectory.appendingPathComponent("space-web-secret.txt")
try? "secret".write(to: secret, atomically: true, encoding: .utf8)
let base = "http://127.0.0.1:\(port)"
let page = """
    <html><head><link rel="stylesheet" href="\(base)/css"><script src="\(base)/js"></script></head><body>
    <img src="\(base)/img"><iframe src="\(base)/frame"></iframe><object data="\(base)/obj"></object>
    <form id=f action="\(base)/form" method=post><input name=a value=1></form>
    <a id=link href="\(base)/link">x</a><a id=blank href="\(base)/blank" target=_blank>x</a>
    <link rel=preconnect href="\(base)"><link rel=dns-prefetch href="\(base)"><link rel=prefetch href="\(base)/prefetch">
    <svg><a id=svg href="\(base)/svg"><text>x</text></a></svg><div id=closed></div><div id=foreign></div>
    <script>
    const out = {};
    const tries = [];
    const note = (k, p) => tries.push(Promise.resolve().then(p).then(() => { out[k] = 'open'; }, () => { out[k] = 'blocked'; }));
    note('fetch', () => fetch('\(base)/fetch'));
    note('fetchFile', () => fetch('file://\(secret.path)').then(r => r.text()));
    note('xhrFile', () => new Promise((ok, no) => { const x = new XMLHttpRequest(); x.open('GET', 'file://\(secret.path)'); x.onload = () => x.responseText.includes('secret') ? ok() : no(); x.onerror = no; x.send(); }));
    note('socket', () => new Promise((ok, no) => { const w = new WebSocket('ws://127.0.0.1:\(port)/ws'); w.onopen = ok; w.onerror = no; setTimeout(no, 1500); }));
    note('beacon', () => { if (!navigator.sendBeacon('\(base)/beacon', 'x')) throw 0; });
    note('worker', () => new Promise((ok, no) => { const w = new Worker(URL.createObjectURL(new Blob(['postMessage(1)']))); w.onmessage = ok; w.onerror = no; setTimeout(no, 1500); }));
    note('evalCode', () => { eval('1'); });
    out.popup = window.open('\(base)/popup') ? 'open' : 'blocked';
    try { document.getElementById('f').submit(); } catch (e) {}
    document.getElementById('link').click();
    document.getElementById('blank').click();
    document.getElementById('svg').dispatchEvent(new MouseEvent('click', {bubbles: true}));
    // A link inside a closed shadow root, also one made with another frame's attachShadow.
    const root = document.getElementById('closed').attachShadow({mode: 'closed'});
    root.innerHTML = "<a href='\(base)/shadow'>x</a>"; root.querySelector('a').click();
    out.frameWindow = (() => { try { const f = document.createElement('ifr' + 'ame'); document.body.append(f); return f.contentWindow === null ? 'blocked' : 'open'; } catch (e) { return 'blocked'; } })();
    out.frameHTML = (() => { try { document.body.insertAdjacentHTML('beforeend', '<ifr' + 'ame></ifr' + 'ame>'); return window.length ? 'open' : 'blocked'; } catch (e) { return 'blocked'; } })();
    out.frames = window.length === 0 ? 'blocked' : 'open';
    try { const other = window[0].Element.prototype.attachShadow.call(document.getElementById('foreign'), {mode: 'closed'}); other.innerHTML = "<a href='\(base)/foreign'>x</a>"; other.querySelector('a').click(); } catch (e) {}
    out.initial = space.state.get('n');
    try { localStorage.setItem('k', 'v'); out.storage = 'open'; } catch (e) { out.storage = 'blocked'; }
    Promise.all(tries).then(async () => {
      out.bigSet = await space.state.set('big', 'x'.repeat(10100000));
      out.bigGone = space.state.get('big') === undefined;
      out.setOK = await space.state.set('n', 42);
      out.direct = await window.webkit.messageHandlers.space.postMessage({op: 'run', cmd: 'ls'});
      // One address the content rules block, one they do not: the navigation policy alone keeps the page.
      setTimeout(() => { location.href = '\(base)/nav'; }, 10);
      setTimeout(() => { location.href = 'about:blank?moved'; }, 30);
      await space.state.set('result', out);
    });
    </script></body></html>
    """

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
func webView(in view: NSView) -> WKWebView? { view as? WKWebView ?? view.subviews.lazy.compactMap(webView(in:)).first }
// A page as SpaceView shows one; its web view once the isolation rules are ready (nil: it did not load).
func show(_ html: String, host: SpaceStateHost, actions: SpaceActions = SpaceActions(), assets: URL? = nil, color: String = "blue",
          onProblem: @escaping (String) -> Void = { _ in }) -> (NSView, WKWebView?) {
    let hosting = NSHostingView(rootView: SpaceWebView(html: html, assets: assets, color: color, reload: UUID().uuidString, host: { host },
                                                       actions: actions, onProblem: onProblem))
    hosting.frame = window.contentView!.bounds
    window.contentView!.addSubview(hosting)
    let wait = Date().addingTimeInterval(10)
    while webView(in: hosting) == nil && Date() < wait { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    return (hosting, webView(in: hosting))
}
let host = SpaceMemoryHost(Data(#"{"n":1}"#.utf8))
var opened: [[String: String]] = []
var problems: [String] = []
let (firstView, firstPage) = show(page, host: host, actions: SpaceActions(open: { opened.append($0) }), onProblem: { problems.append($0) })
guard let firstPage else { fail("the page did not load") }

func result() -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: host.stateData) as? [String: Any])?["result"] as? [String: Any]
}
let deadline = Date().addingTimeInterval(20)
while result() == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
guard let out = result() else {
    var seen: Any?
    firstPage.evaluateJavaScript("JSON.stringify(typeof out === 'undefined' ? 'no script' : out) + ' ' + location.href") { value, _ in seen = value ?? "nil" }
    let wait = Date().addingTimeInterval(3)
    while seen == nil && Date() < wait { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    fail("the page never reported; it shows: \(seen ?? "nothing")")
}
// Time for any late load (the navigation after the report).
let settle = Date().addingTimeInterval(2)
while Date() < settle { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

print("space web results: \(out), server connections: \(connections)")
for key in ["fetch", "fetchFile", "xhrFile", "socket", "worker", "evalCode", "popup", "storage", "frameWindow", "frameHTML", "frames"] {
    if out[key] as? String != "blocked" { fail("\(key) was not blocked: \(out[key] ?? "missing")") }
}
if connections != 0 { fail("\(connections) connection(s) reached the local server: \(requests)") }
if out["initial"] as? Int != 1 { fail("state.get did not read the first data") }
if out["setOK"] as? Bool != true || (try? JSONSerialization.jsonObject(with: host.stateData) as? [String: Any])?["n"] as? Int != 42 { fail("state.set did not save") }
if out["bigSet"] as? Bool != false || out["bigGone"] as? Bool != true { fail("a write over 10 MB was not refused and undone") }
if out["direct"] as? Bool != false { fail("an unknown bridge call was not refused") }
// What the page cannot show by itself: the view keeps nothing on disk (cookies, storage, cache).
if firstPage.configuration.websiteDataStore.isPersistent { fail("the Space web view keeps its data on disk") }
// Nor which layer stopped a load: the page's own policy must still refuse every kind of load (the content rules
// alone would hide a weaker one).
var policy: Any?
firstPage.evaluateJavaScript("document.querySelector('meta[http-equiv=Content-Security-Policy]').content") { value, _ in policy = value ?? "none" }
let policyWait = Date().addingTimeInterval(3)
while policy == nil && Date() < policyWait { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
for part in ["default-src 'none'", "connect-src 'none'", "frame-src 'none'", "worker-src 'none'", "form-action 'none'", "base-uri 'none'", "script-src 'unsafe-inline';"]
    where !((policy as? String) ?? "").contains(part) { fail("the page's policy lacks \(part): \(policy ?? "none")") }
if firstPage.url?.absoluteString != "about:blank" { fail("the page navigated away: \(firstPage.url?.absoluteString ?? "nil")") }
if !opened.isEmpty { fail("something was opened") }
firstView.removeFromSuperview()

// A Space's picture files load from its assets/ folder (SpaceAssetServer); nothing else there or elsewhere does, and
// the page cannot read them as data.
let assetFolder = FileManager.default.temporaryDirectory.appendingPathComponent("space-web-assets-\(UUID().uuidString)")
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 12, bitsPerPixel: 32)!
try! FileManager.default.createDirectory(at: assetFolder.appendingPathComponent("assets"), withIntermediateDirectories: true)
try! bitmap.representation(using: .png, properties: [:])!.write(to: assetFolder.appendingPathComponent("assets/cat.png"))
try! bitmap.representation(using: .png, properties: [:])!.write(to: assetFolder.appendingPathComponent(".hidden.png"))
try! bitmap.representation(using: .png, properties: [:])!.write(to: assetFolder.appendingPathComponent("assets/.kept.png"))
let assetHost = SpaceMemoryHost(Data("{}".utf8))
let pictures = """
    <img id=a src="assets/cat.png"><img id=b src='./assets/none.png'><img id=c src="space-asset://local/..%2F.hidden.png"><img id=d src="space-asset://other/cat.png"><img id=e src="space-asset://local/.kept.png">
    <script>
    const seen = id => new Promise(ok => { const i = document.getElementById(id); if (i.complete && i.naturalWidth) ok(i.naturalWidth); i.onload = () => ok(i.naturalWidth); i.onerror = () => ok(-1); });
    Promise.all(['a', 'b', 'c', 'd', 'e'].map(seen)).then(async sizes => {
      let read = 'blocked'; try { await fetch(document.getElementById('a').src); read = 'open'; } catch (e) {}
      space.state.set('result', {sizes, read});
    });
    </script>
    """
let (assetView, assetPage) = show(pictures, host: assetHost, assets: assetFolder)
if assetPage == nil { fail("the picture page did not load") }
func assetResult() -> [String: Any]? { (try? JSONSerialization.jsonObject(with: assetHost.stateData) as? [String: Any])?["result"] as? [String: Any] }
let assetDeadline = Date().addingTimeInterval(10)
while assetResult() == nil && Date() < assetDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
guard let assetOut = assetResult() else { fail("the picture page never reported") }
if (assetOut["sizes"] as? [Int]) != [3, -1, -1, -1, -1] { fail("only assets/cat.png should load: \(assetOut)") }
if assetOut["read"] as? String != "blocked" { fail("the page read a picture file as data") }
assetView.removeFromSuperview()
try? FileManager.default.removeItem(at: assetFolder)

// The built-in templates run under the same guard: they draw, and a check is saved through the bridge.
func run(_ script: String, in page: WKWebView?) -> Any? {
    var value: Any?, done = false
    page?.evaluateJavaScript(script) { result, error in value = result ?? error.map { "error: \($0)" }; done = true }
    let wait = Date().addingTimeInterval(5)
    while !done && Date() < wait { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    return value
}
func settle(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
// Each is made as the sidebar makes it and shown from its folder, as SpaceView shows a Space.
for template in SpaceTemplate.allCases {
    guard let made = try? SpaceStore.shared.makeFromTemplate(template) else { fail("the \(template.rawValue) template was not made") }
    let folder = SpaceStore.folder(made.id), data = SpaceFolderHost(folder)
    let (shownView, shown) = show(SpaceStore.html(folder), host: data, assets: folder, color: made.color)
    settle(1.5)
    guard shown != nil, (run("document.querySelector('h1') ? document.querySelector('h1').textContent : 'none'", in: shown) as? String) == template.name else {
        fail("the \(template.rawValue) template did not draw: \(String(describing: run("document.body.innerHTML.slice(0,200)", in: shown)))")
    }
    if template == .checklist {
        _ = run("const i=document.querySelector('input[type=text]');i.value='실험 1';i.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter'}));1", in: shown)
        settle(0.5)
        _ = run("document.querySelector('input[type=checkbox]').click();1", in: shown)
        settle(0.5)
        let items = (try? JSONSerialization.jsonObject(with: data.stateData) as? [String: Any])?["items"] as? [[String: Any]] ?? []
        if items.count != 1 || items[0]["done"] as? Bool != true || items[0]["text"] as? String != "실험 1" { fail("the checklist did not save an item and its check: \(items)") }
    }
    shownView.removeFromSuperview()
}

// A Space whose state.json is not one object (an AI wrote a list) opens with empty data, and the bridge still saves.
let oddFolder = SpaceStore.folder("odd-data")
try! FileManager.default.createDirectory(at: oddFolder, withIntermediateDirectories: true)
try! Data("[1,2]".utf8).write(to: oddFolder.appendingPathComponent("state.json"))
let (oddView, oddPage) = show("<script>space.state.set('keys', space.state.keys().length)</script>", host: SpaceFolderHost(oddFolder), assets: oddFolder)
settle(1.5)
if oddPage == nil || (try? JSONSerialization.jsonObject(with: SpaceFolderHost(oddFolder).stateData) as? [String: Any])?["keys"] as? Int != 0 {
    fail("a Space with odd data did not open with {}: \(String(data: SpaceFolderHost(oddFolder).stateData, encoding: .utf8) ?? "")")
}
oddView.removeFromSuperview()

// migrate runs in a page of its own: the result comes back; an error, a non-object or an endless loop is refused.
func migrate(_ code: String) -> Result<Data, SpaceBad>? {
    var result: Result<Data, SpaceBad>?
    SpaceMigrator.run(code, state: Data(#"{"n":3,"t":"</script>"}"#.utf8)) { result = $0 }
    let wait = Date().addingTimeInterval(8)
    while result == nil && Date() < wait { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    return result
}
guard case .success(let moved)? = migrate("function migrate(o){return {count:o.n, t:o.t, has:typeof space}}"),
      let object = try? JSONSerialization.jsonObject(with: moved) as? [String: Any],
      object["count"] as? Int == 3, object["t"] as? String == "</script>", object["has"] as? String == "undefined" else { fail("migrate did not move the data (or saw the bridge)") }
guard case .failure? = migrate("function migrate(o){throw new Error('x')}"), case .failure? = migrate("function migrate(o){return 5}"),
      case .failure? = migrate("function migrate(o){while(true){}}") else { fail("a failing migrate was not refused") }

try? FileManager.default.removeItem(at: secret)
print("PASS: Space web view — no network, no file://, no frames, navigation or pop-ups; only the bridge; templates and migrate run")
exit(0)
