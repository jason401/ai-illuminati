import Foundation
import AIRemote

// The promises of the AIRemote module, checked from outside it with only its public API (run_mode2.sh).
// Optional markers: `// contract needs: app resources`, `// contract needs: chat fixtures`.
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("FAIL: " + message) }
}

// A request is read only once its head and Content-Length bytes are all in; the query and path are decoded.
let raw = "POST /api/chat/a%20b/send?open=1&k=xyz HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 12\r\n\r\n{\"text\":\"h\"}"
if case .more = RemoteHTTP.parse(Data(raw.utf8).dropLast(3)) {} else { expect(false, "a cut body waits for more") }
if case .done(let r) = RemoteHTTP.parse(Data(raw.utf8)) {
    expect(r.method == "POST" && r.path == "/api/chat/a b/send" && r.query == ["open": "1", "k": "xyz"], "method, path, query")
    expect(r.headers["content-type"] == "application/json" && r.json?["text"] as? String == "h", "headers by lowercased name, JSON body")
} else { expect(false, "a whole request is read") }
if case .more = RemoteHTTP.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)) {} else { expect(false, "no blank line yet: more") }
if case .bad(400) = RemoteHTTP.parse(Data("NOPE\r\n\r\n".utf8)) {} else { expect(false, "a broken request line is refused") }
if case .bad(400) = RemoteHTTP.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) {} else { expect(false, "chunked bodies are refused") }
if case .bad(413) = RemoteHTTP.parse(Data("POST / HTTP/1.1\r\nContent-Length: \(RemoteHTTP.maxBody + 1)\r\n\r\n".utf8)) {} else { expect(false, "too big is refused before reading it") }

// The key: by header or `k`, the whole of it, never an empty one.
let key = RemoteHTTP.newKey()
expect(key.count == 48 && key != RemoteHTTP.newKey(), "keys are long and new each time")
expect(RemoteHTTP.authorized(RemoteRequest(method: "GET", path: "/api/x", headers: ["x-remote-key": key]), key: key), "the header key passes")
expect(RemoteHTTP.authorized(RemoteRequest(method: "GET", path: "/api/x", query: ["k": key]), key: key), "the query key passes (pictures)")
expect(!RemoteHTTP.authorized(RemoteRequest(method: "GET", path: "/api/x", query: ["k": String(key.dropLast())]), key: key), "a part of the key fails")
expect(!RemoteHTTP.authorized(RemoteRequest(method: "GET", path: "/api/x"), key: ""), "no key set lets nothing in")

// The page is one HTML document in the app's language, with the list, the chat and the message box.
let page = String(data: RemotePage.html(), encoding: .utf8) ?? ""
expect(page.hasPrefix("<!doctype html>") && page.contains("id=\"listView\"") && page.contains("id=\"send\"") && !page.contains("__STRINGS__"), "the page")

// A real server on 127.0.0.1: the page and icon without a key, /api/ only with it, answers from the handler on the main queue.
var port: UInt16 = 0
var server: RemoteServer?
for candidate in UInt16(47390)...UInt16(47420) {
    let s = RemoteServer(port: candidate, key: key, page: { Data("<p>page</p>".utf8) }, icon: Data([1, 2, 3])) { request in
        expect(Thread.isMainThread, "the handler runs on the main queue")
        return .json(["path": request.path, "text": request.json?["text"] as? String ?? ""])
    }
    if (try? s.start()) != nil { server = s; port = candidate; break }
}
expect(server?.running == true, "the server starts on a free port")
func fetch(_ path: String, key: String? = nil, body: String? = nil) -> (Int, Data) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    if let key { request.setValue(key, forHTTPHeaderField: "X-Remote-Key") }
    if let body { request.httpMethod = "POST"; request.httpBody = Data(body.utf8) }
    var result: (Int, Data)?
    URLSession.shared.dataTask(with: request) { data, response, _ in
        result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
    }.resume()
    let deadline = Date().addingTimeInterval(10)
    while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    return result ?? (0, Data())
}
// The listener comes up asynchronously; the first answer may take a moment.
var first = fetch("/")
for _ in 0..<20 where first.0 == 0 { first = fetch("/") }
expect(first.0 == 200 && String(data: first.1, encoding: .utf8) == "<p>page</p>", "the page needs no key")
expect(fetch("/apple-touch-icon.png").1 == Data([1, 2, 3]), "the icon")
expect(fetch("/api/chats").0 == 401 && fetch("/api/chats", key: "wrong").0 == 401, "no key or a wrong key: 401")
let answered = fetch("/api/chat/x/send", key: key, body: #"{"text":"안녕"}"#)
let json = (try? JSONSerialization.jsonObject(with: answered.1)) as? [String: String]
expect(answered.0 == 200 && json == ["path": "/api/chat/x/send", "text": "안녕"], "the handler answers with the key")
expect(fetch("/elsewhere").0 == 404, "nothing else is served")
server?.stop()
expect(server?.running == false, "stopped")
print("PASS: AIRemote contract")
