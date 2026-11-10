import AppKit
import SwiftUI
import WebKit

// A Space's page runs here, cut off from everything: a data store that keeps nothing, no base URL (so no file://),
// our CSP before the page's own markup (SpaceCheck.document), content rules that block every http(s), ws, file, ftp
// and blob load, no navigation after the first load, no new windows, no file pickers and no alerts. The only way out
// is window.space, one message handler that knows which Space it serves (the page never names one).

// Where a page's data lives: a Space's or a draft's folder, or memory (a migrate preview).
protocol SpaceStateHost: AnyObject {
    var stateData: Data { get }
    func set(key: String, json: String?) -> Result<Void, SpaceBad>
}

final class SpaceFolderHost: SpaceStateHost {
    let folder: URL
    init(_ folder: URL) { self.folder = folder }
    var stateData: Data { SpaceStore.state(folder) }
    func set(key: String, json: String?) -> Result<Void, SpaceBad> { SpaceStore.setState(folder, key: key, json: json) }
}

final class SpaceMemoryHost: SpaceStateHost {
    private(set) var stateData: Data
    init(_ data: Data) { stateData = data }
    func set(key: String, json: String?) -> Result<Void, SpaceBad> {
        switch SpaceStore.setting(stateData, key: key, json: json) {
        case .success(let data): stateData = data; return .success(())
        case .failure(let bad): return .failure(bad)
        }
    }
}

// What a page may ask of the app; the view that shows it decides (SpaceView.swift).
struct SpaceActions {
    var open: (_ target: [String: String]) -> Void = { _ in }
    var notify: (_ text: String) -> Void = { _ in }
}

enum SpaceRules {
    static let json = """
        [{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^file:"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^blob:"},"action":{"type":"block"}}]
        """
    private static var list: WKContentRuleList?
    private static var failed: String?
    private static var waiting: [(WKContentRuleList?, String?) -> Void] = []

    // The compiled rules (once per launch, kept under spaces/.rules). Nothing loads without them.
    static func get(_ done: @escaping (WKContentRuleList?, String?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        if list != nil || failed != nil { return done(list, failed) }
        waiting.append(done)
        guard waiting.count == 1 else { return }
        let dir = SpaceStore.root.appendingPathComponent(".rules")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let store = WKContentRuleListStore(url: dir) else { return finish(nil, "WKContentRuleListStore") }
        store.compileContentRuleList(forIdentifier: "space-offline-1", encodedContentRuleList: json) { compiled, error in
            DispatchQueue.main.async { finish(compiled, compiled == nil ? (error?.localizedDescription ?? "rules") : nil) }
        }
    }

    private static func finish(_ compiled: WKContentRuleList?, _ error: String?) {
        list = compiled; failed = error
        let calls = waiting; waiting = []
        calls.forEach { $0(compiled, error) }
    }

    static func configuration(_ rules: WKContentRuleList) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(rules)
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isFraudulentWebsiteWarningEnabled = false
        config.preferences.isElementFullscreenEnabled = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        return config
    }
}

// The page's window.space, made before its own scripts run.
enum SpaceBridge {
    static func script(state: Data, theme: [String: Any]) -> String {
        let initial = String(data: state, encoding: .utf8) ?? "{}"
        let themeJSON = (try? JSONSerialization.data(withJSONObject: theme)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
            (() => {
              const handler = window.webkit.messageHandlers.space;
              const post = m => handler.postMessage(m);
              const cache = \(initial.replacingOccurrences(of: "<", with: "\\u003c"));
              const subs = new Set(), seq = {};
              const copy = v => v === undefined ? undefined : JSON.parse(JSON.stringify(v));
              const tell = (k, v) => { for (const f of subs) { try { f(k, copy(v)); } catch (e) {} } };
              const own = k => Object.prototype.hasOwnProperty.call(cache, k);
              const state = Object.freeze({
                get: k => own(String(k)) ? copy(cache[String(k)]) : undefined,
                keys: () => Object.keys(cache),
                set: (key, value) => {
                  const k = String(key);
                  let json;
                  try { json = value === undefined ? null : JSON.stringify(value); } catch (e) { return Promise.resolve(false); }
                  if (json === undefined) return Promise.resolve(false);
                  const had = own(k), old = cache[k], n = (seq[k] || 0) + 1;
                  seq[k] = n;
                  if (json === null) delete cache[k]; else cache[k] = JSON.parse(json);
                  tell(k, cache[k]);
                  const undo = () => { if (seq[k] !== n) return false; if (had) cache[k] = old; else delete cache[k]; tell(k, cache[k]); return false; };
                  return post({op: 'set', key: k, value: json}).then(ok => ok === true ? true : undo(), undo);
                },
                subscribe: f => { if (typeof f !== 'function') return () => {}; subs.add(f); return () => { subs.delete(f); }; }
              });
              const space = Object.freeze({
                state,
                theme: Object.freeze(\(themeJSON)),
                open: target => { let t; try { t = JSON.stringify(target || {}); } catch (e) { return Promise.resolve(false); } return post({op: 'open', target: t}).then(ok => ok === true, () => false); },
                notify: text => { post({op: 'notify', text: String(text).slice(0, 300)}).catch(() => {}); }
              });
              Object.defineProperty(window, 'space', {value: space, writable: false, configurable: false});
            })();
            """
    }

    // In every frame, before any page script: links never start a load (WebKit opens a connection to a clicked link's
    // host before the navigation policy refuses it), so they are caught first, on window in the capture phase; jumps
    // inside the page stay. Shadow roots are always open, so a link inside one is still seen, also with another
    // frame's attachShadow; frames' windows are not handed out.
    static let guardScript = """
        (() => {
          const attach = Element.prototype.attachShadow;
          Object.defineProperty(Element.prototype, 'attachShadow', {value: function (init) { return attach.call(this, Object.assign({}, init, {mode: 'open'})); }, writable: false, configurable: false});
          for (const type of [window.HTMLIFrameElement, window.HTMLFrameElement, window.HTMLObjectElement, window.HTMLEmbedElement]) {
            if (!type) continue;
            for (const name of ['contentWindow', 'contentDocument']) Object.defineProperty(type.prototype, name, {get: () => null, configurable: false});
            Object.defineProperty(type.prototype, 'getSVGDocument', {value: () => null, writable: false, configurable: false});
          }
          // No frames at all (another frame's realm would bring back what is changed here): they cannot be made from
          // script or HTML text, inserted, or kept when the page's own markup has one.
          const frameTag = /^(iframe|frame|frameset|object|embed|portal)$/i, frameText = /<\\s*(iframe|frame|frameset|object|embed|portal)\\b/i;
          const frameSel = 'iframe,frame,frameset,object,embed,portal';
          const refuse = () => { throw new DOMException('Frames are not allowed in a Space', 'NotSupportedError'); };
          const hasFrame = n => n && (n.nodeType === 1 || n.nodeType === 11) && ((n.nodeType === 1 && n.matches(frameSel)) || !!n.querySelector(frameSel));
          const wrap = (proto, name, test) => { const f = proto && proto[name]; if (typeof f !== 'function') return;
            Object.defineProperty(proto, name, {value: function (...a) { if (test(a)) refuse(); return f.apply(this, a); }, writable: false, configurable: false}); };
          const wrapSetter = (proto, name) => { const d = proto && Object.getOwnPropertyDescriptor(proto, name); if (!d || !d.set) return;
            Object.defineProperty(proto, name, {get: d.get, set: function (v) { if (frameText.test(String(v))) refuse(); d.set.call(this, v); }, configurable: false}); };
          wrap(Document.prototype, 'createElement', a => frameTag.test(String(a[0])));
          wrap(Document.prototype, 'createElementNS', a => frameTag.test(String(a[1]).split(':').pop()));
          for (const name of ['appendChild', 'insertBefore', 'replaceChild']) wrap(Node.prototype, name, a => hasFrame(a[0]));
          for (const name of ['append', 'prepend', 'before', 'after', 'replaceWith', 'replaceChildren', 'insertAdjacentElement'])
            for (const proto of [Element.prototype, Document.prototype, DocumentFragment.prototype, CharacterData.prototype]) wrap(proto, name, a => a.some(hasFrame));
          for (const name of ['adoptNode', 'importNode']) wrap(Document.prototype, name, a => hasFrame(a[0]));
          for (const proto of [Element.prototype, ShadowRoot.prototype]) { wrapSetter(proto, 'innerHTML'); wrapSetter(proto, 'outerHTML'); wrap(proto, 'setHTMLUnsafe', a => frameText.test(String(a[0]))); }
          wrap(Element.prototype, 'insertAdjacentHTML', a => frameText.test(String(a[1])));
          for (const name of ['write', 'writeln']) wrap(Document.prototype, name, a => frameText.test(a.join('')));
          wrap(Range.prototype, 'createContextualFragment', a => frameText.test(String(a[0])));
          wrap(DOMParser.prototype, 'parseFromString', a => frameText.test(String(a[0])));
          wrapSetter(HTMLIFrameElement.prototype, 'srcdoc');
          new MutationObserver(list => { for (const m of list) for (const n of m.addedNodes) {
            if (n.nodeType === 1 && n.matches(frameSel)) n.remove(); else if (n.nodeType === 1) n.querySelectorAll(frameSel).forEach(f => f.remove()); } })
            .observe(document, {childList: true, subtree: true});
          const linkOf = e => e.composedPath().find(n => n && n.tagName && ['a', 'area'].includes(n.tagName.toLowerCase()) && (n.hasAttribute('href') || n.hasAttribute('xlink:href')));
          const stop = e => { const a = linkOf(e); if (a && !(a.getAttribute('href') || '').startsWith('#')) e.preventDefault(); };
          for (const type of ['click', 'auxclick', 'keydown']) window.addEventListener(type, e => { if (type !== 'keydown' || e.key === 'Enter') stop(e); }, true);
          window.addEventListener('submit', e => e.preventDefault(), true);
        })();
        """

    static func theme(color: String) -> [String: Any] {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return ["dark": dark, "accent": SpaceManifest.hexes[color] ?? "#0a84ff", "color": color]
    }
}

// The message handler without a strong reference back (WKUserContentController keeps its handlers).
private final class SpaceWeakHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var target: SpacePage?
    init(_ target: SpacePage) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let target else { return replyHandler(false, nil) }
        target.receive(message, reply: replyHandler)
    }
}

// One loaded page: its web view, its data host and what it may ask for.
final class SpacePage: NSObject, WKNavigationDelegate, WKUIDelegate {
    let host: SpaceStateHost
    var actions: SpaceActions
    var onProblem: (String) -> Void = { _ in }
    private(set) var webView: WKWebView?
    private var started = false
    private var lastNotice = Date.distantPast

    init(host: SpaceStateHost, actions: SpaceActions) { self.host = host; self.actions = actions }

    // Loads `html` once the rules are compiled; without them nothing loads and `done` gets the reason.
    func load(_ html: String, color: String, in container: NSView?, done: @escaping (WKWebView?, String?) -> Void) {
        SpaceRules.get { [weak self] rules, error in
            guard let self else { return }
            guard let rules else { return done(nil, L("격리 규칙을 준비하지 못해 Space를 열지 않았어요: ", "The isolation rules could not be prepared, so the Space was not opened: ") + (error ?? "")) }
            let config = SpaceRules.configuration(rules)
            config.userContentController.addUserScript(WKUserScript(source: SpaceBridge.guardScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            config.userContentController.addUserScript(WKUserScript(source: SpaceBridge.script(state: self.host.stateData, theme: SpaceBridge.theme(color: color)),
                                                                     injectionTime: .atDocumentStart, forMainFrameOnly: true))
            config.userContentController.addScriptMessageHandler(SpaceWeakHandler(self), contentWorld: .page, name: "space")
            let view = WKWebView(frame: container?.bounds ?? .zero, configuration: config)
            view.navigationDelegate = self
            view.uiDelegate = self
            view.allowsLinkPreview = false
            view.allowsMagnification = false
            view.setValue(false, forKey: "drawsBackground")
            self.webView = view
            view.loadHTMLString(SpaceCheck.document(html), baseURL: nil)
            done(view, nil)
        }
    }

    func close() {
        webView?.stopLoading()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.navigationDelegate = nil; webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
    }

    func receive(_ message: WKScriptMessage, reply: @escaping (Any?, String?) -> Void) {
        // Only this page's own top document, with a known shape.
        guard message.webView === webView, message.frameInfo.isMainFrame, message.frameInfo.request.url?.scheme != "file",
              let body = message.body as? [String: Any], let op = body["op"] as? String else { return reply(false, nil) }
        switch op {
        case "set":
            guard let key = body["key"] as? String else { return reply(false, nil) }
            let json = body["value"] as? String
            if json == nil && !(body["value"] is NSNull) { return reply(false, nil) }
            switch host.set(key: key, json: json) {
            case .success: reply(true, nil)
            case .failure(let bad): onProblem(bad.reason); reply(false, nil)
            }
        case "open":
            guard let text = body["target"] as? String, text.utf8.count <= 4000, let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return reply(false, nil) }
            let target = object.compactMapValues { $0 as? String }
            guard target.count == 1, ["chat", "todo", "file", "url"].contains(target.keys.first!) else { return reply(false, nil) }
            actions.open(target)
            reply(true, nil)
        case "notify":
            // At most one notice every 3 seconds.
            guard let text = body["text"] as? String, Date().timeIntervalSince(lastNotice) > 3 else { return reply(false, nil) }
            lastNotice = Date()
            actions.notify(String(text.prefix(300)))
            reply(true, nil)
        default: reply(false, nil)
        }
    }

    // The first load (about:blank from loadHTMLString) and jumps inside the page; nothing else.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url?.absoluteString ?? ""
        guard action.targetFrame?.isMainFrame == true else { return decisionHandler(.cancel) }
        if !started && url == "about:blank" { started = true; return decisionHandler(.allow) }
        if started && url.hasPrefix("about:blank#") { return decisionHandler(.allow) }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.isForMainFrame && response.response.url?.absoluteString.hasPrefix("about:blank") == true && response.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }
    // A crashed or killed page (an endless loop) comes back once the view reloads it; here it only says so.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onProblem(L("Space 화면이 멈춰 닫혔어요. 다시 열어 주세요.", "The Space page stopped. Open it again.")) }
}

// A Space page in SwiftUI. A new `reload` value (another version, data put back) loads it again.
struct SpaceWebView: NSViewRepresentable {
    let html: String
    let color: String
    let reload: String
    let host: () -> SpaceStateHost
    let actions: SpaceActions
    var onProblem: (String) -> Void = { _ in }

    final class Coordinator { var page: SpacePage?; var loaded: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.autoresizesSubviews = true
        load(container, context.coordinator)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.page?.actions = actions
        if context.coordinator.loaded != key { load(container, context.coordinator) }
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) { coordinator.page?.close(); coordinator.page = nil }

    private var key: String { reload + "|" + color + "|" + String(html.hashValue) }

    private func load(_ container: NSView, _ coordinator: Coordinator) {
        coordinator.page?.close()
        container.subviews.forEach { $0.removeFromSuperview() }
        coordinator.loaded = key
        let page = SpacePage(host: host(), actions: actions)
        page.onProblem = onProblem
        coordinator.page = page
        page.load(html, color: color, in: container) { view, error in
            guard coordinator.page === page else { return }
            if let view {
                view.frame = container.bounds
                view.autoresizingMask = [.width, .height]
                container.addSubview(view)
            } else {
                let label = NSTextField(wrappingLabelWithString: error ?? "")
                label.textColor = .secondaryLabelColor
                label.frame = container.bounds.insetBy(dx: 16, dy: 16)
                label.autoresizingMask = [.width, .height]
                container.addSubview(label)
            }
        }
    }
}

// migrate(oldState) in a page of its own: no bridge, no network, nothing kept. Only its JSON result comes back
// (an object within the data limit), or why not. A page that does not finish in 5 seconds is closed.
final class SpaceMigrator: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var done: ((Result<Data, SpaceBad>) -> Void)?
    private var started = false
    private static var running: [SpaceMigrator] = []

    static func run(_ migrate: String, state: Data, done: @escaping (Result<Data, SpaceBad>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        let runner = SpaceMigrator()
        runner.done = done
        running.append(runner)
        SpaceRules.get { rules, error in
            guard let rules else { return runner.finish(.failure(SpaceBad(reason: error ?? "rules"))) }
            let config = SpaceRules.configuration(rules)
            config.userContentController.addUserScript(WKUserScript(source: SpaceBridge.guardScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), configuration: config)
            view.navigationDelegate = runner
            runner.webView = view
            let text = String(data: state, encoding: .utf8) ?? "{}"
            let literal = ((try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"{}\"")
                .replacingOccurrences(of: "<", with: "\\u003c")
            let page = "<script>\n" + migrate.replacingOccurrences(of: "</script", with: "<\\/script") + "\n;window.__spaceResult=(function(){try{const r=migrate(JSON.parse(" + literal
                + "));return JSON.stringify(r===undefined?null:r)}catch(e){return JSON.stringify({__spaceError:String(e)})}})();</script>"
            view.loadHTMLString(SpaceCheck.document(page), baseURL: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { runner.finish(.failure(SpaceBad(reason: L("migrate가 5초 안에 끝나지 않았어요", "migrate did not finish in 5 seconds")))) }
        }
    }

    private func finish(_ result: Result<Data, SpaceBad>) {
        guard let done else { return }
        self.done = nil
        webView?.stopLoading(); webView?.navigationDelegate = nil; webView = nil
        Self.running.removeAll { $0 === self }
        done(result)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if !started && action.request.url?.absoluteString == "about:blank" { started = true; return decisionHandler(.allow) }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("window.__spaceResult") { [weak self] value, error in
            guard let self else { return }
            guard let text = value as? String, let data = text.data(using: .utf8) else {
                return self.finish(.failure(SpaceBad(reason: L("migrate 결과가 없어요", "migrate gave no result") + (error.map { ": " + $0.localizedDescription } ?? ""))))
            }
            let object = try? JSONSerialization.jsonObject(with: data)
            if let failed = (object as? [String: Any])?["__spaceError"] as? String { return self.finish(.failure(SpaceBad(reason: "migrate: " + failed))) }
            guard object is [String: Any], data.count <= SpaceLimits.state else {
                return self.finish(.failure(SpaceBad(reason: L("migrate 결과가 1MB 이하 JSON 객체가 아니에요", "migrate did not return a JSON object within 1 MB"))))
            }
            self.finish(.success(data))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(SpaceBad(reason: error.localizedDescription))) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(SpaceBad(reason: error.localizedDescription))) }
}
