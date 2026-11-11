import Foundation

// Spaces: small personal apps the user makes and changes by talking (like Meta Muse Spaces). An AI writes one
// HTML page; it runs in an isolated web view (SpaceWeb.swift) with no network, no files and one bridge
// (window.space: its own state, opening a chat/TODO/file/link, a notice, the theme). A Space belongs to the app,
// not to a chat: spaces/<id>/ holds manifest.json, app.html (the code, written only after the checks here),
// state.json (the user's data, written only through the bridge, at most 1 MB), versions/<n>/ (the code and the
// data before each change: Undo) and refine.json (the talk that changed it). An AI changes the code only, never the
// data; when a change renames data keys it sends migrate(oldState), run in the web view and previewed first.

// When a Space shows in the sidebar: days 1 (Monday) … 7 (Sunday), from–to "HH:mm" (to before from: overnight).
// Outside it, the Space folds into "Later".
struct SpaceSchedule: Codable, Equatable {
    var days: [Int]?
    var from: String?
    var to: String?

    static func minutes(_ text: String?) -> Int? {
        guard let text, let match = text.range(of: #"^\s*(\d{1,2}):(\d{2})\s*$"#, options: .regularExpression) else { return nil }
        let parts = text[match].trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...24).contains(parts[0]), (0...59).contains(parts[1]), parts[0] * 60 + parts[1] <= 1440 else { return nil }
        return parts[0] * 60 + parts[1]
    }

    var valid: Bool {
        (days ?? []).allSatisfy { (1...7).contains($0) } && (from == nil) == (to == nil)
            && (from == nil || (Self.minutes(from) != nil && Self.minutes(to) != nil))
    }

    func shows(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard valid else { return true }
        let weekday = calendar.component(.weekday, from: date)   // 1 = Sunday
        let day = weekday == 1 ? 7 : weekday - 1
        let now = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let days = Set(self.days ?? [])
        guard let start = Self.minutes(from), let end = Self.minutes(to), start != end else { return days.isEmpty || days.contains(day) }
        if start < end { return (days.isEmpty || days.contains(day)) && now >= start && now < end }
        // Overnight: the part after midnight belongs to the day before.
        if now >= start { return days.isEmpty || days.contains(day) }
        if now < end { return days.isEmpty || days.contains(day == 1 ? 7 : day - 1) }
        return false
    }

    // "1-5 09:00-18:00", "6,7", "09:00-12:00": what the user types in the sidebar menu. nil: not understood.
    static func parse(_ text: String) -> SpaceSchedule? {
        var schedule = SpaceSchedule()
        for word in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            if word.contains(":") {
                let ends = word.split(separator: "-").map(String.init)
                guard ends.count == 2, minutes(ends[0]) != nil, minutes(ends[1]) != nil else { return nil }
                schedule.from = ends[0]; schedule.to = ends[1]
            } else {
                var days: [Int] = []
                for part in word.split(separator: ",") {
                    let ends = part.split(separator: "-").compactMap { Int($0) }
                    if ends.count == 2, ends[0] <= ends[1] { days += Array(ends[0]...ends[1]) } else if ends.count == 1 { days.append(ends[0]) } else { return nil }
                }
                schedule.days = Array(Set(days)).sorted()
            }
        }
        return schedule.valid ? schedule : nil
    }

    var text: String {
        let names = [L("월", "Mon"), L("화", "Tue"), L("수", "Wed"), L("목", "Thu"), L("금", "Fri"), L("토", "Sat"), L("일", "Sun")]
        var parts: [String] = []
        if let days, !days.isEmpty { parts.append(days.map { names[$0 - 1] }.joined(separator: ",")) }
        if let from, let to { parts.append("\(from)–\(to)") }
        return parts.joined(separator: " ")
    }
}

struct SpaceManifest: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var icon = "square.grid.2x2"
    var color = "blue"
    var pinned: Bool?
    var hidden: Bool?
    var order = 0
    var schedule: SpaceSchedule?
    var version = 1
    var originChat: String?
    var template: String?
    var worker: String?       // the account that changes it (nil: picked automatically)
    var createdAt = Date()
    var updatedAt = Date()

    static let colors = ["blue", "purple", "pink", "red", "orange", "yellow", "green", "teal", "gray"]
    static let hexes = ["blue": "#0a84ff", "purple": "#bf5af2", "pink": "#ff375f", "red": "#ff453a", "orange": "#ff9f0a",
                        "yellow": "#e0b000", "green": "#30b158", "teal": "#30b0c7", "gray": "#8e8e93"]
    var hex: String { Self.hexes[color] ?? "#0a84ff" }

    init(id: String, name: String) { self.id = id; self.name = name }

    // Missing keys keep their defaults, so a file written by an older or newer build still opens.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Space"
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? icon
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? color
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        schedule = try? c.decodeIfPresent(SpaceSchedule.self, forKey: .schedule)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        originChat = try c.decodeIfPresent(String.self, forKey: .originChat)
        template = try c.decodeIfPresent(String.self, forKey: .template)
        worker = try c.decodeIfPresent(String.self, forKey: .worker)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    // In the sidebar now (not hidden, inside its schedule)?
    func shown(at date: Date = Date()) -> Bool { hidden != true && (schedule?.shows(at: date) ?? true) }
}

// What a chat turn keeps about the Space its answer made: a draft to preview, why it was refused, or what became of it.
struct SpaceDraftNote: Codable, Equatable {
    var draft: String?          // spaces/.drafts/<draft>
    var name: String
    var reason: String?         // refused by the checks: the AI hears it on "Rebuild"
    var space: String?          // added to the sidebar as this Space
    var discarded: Bool?
    var target: String?         // a change to this existing Space (its preview and Apply are in the Space)
    var baseVersion: Int?       // the target's version the change was written for
}

// One <space-build> block, checked: the code, and for a new Space its manifest and first data.
struct SpaceBuild: Equatable {
    var name: String?
    var icon: String?
    var color: String?
    var schedule: SpaceSchedule?
    var html: String
    var state: Data?          // a JSON object
    var migrate: String?      // function migrate(oldState) { … return newState }
}

struct SpaceBad: Error, Equatable { let reason: String }

enum SpaceLimits {
    static let html = 300_000, state = 1_000_000, migrate = 20_000, key = 100, name = 40, versions = 30, refine = 40
}

enum SpaceBuilder {
    static let openTag = "<space-build>", closeTag = "</space-build>"

    // The reply without <space-build> blocks and old <space-patch> ones (also one still being written), and the
    // first build block's body (nil body: it was not closed). A chat's block may name an existing Space:
    // <space-build for="id"> changes it, <space-build from="id"> makes a new one from it.
    static func split(_ text: String) -> (reply: String, found: Bool, body: String?, target: String?, base: String?) {
        var rest = Substring(text), kept = "", found = false, body: String?, attributes = ""
        while let (start, tag, closed) = opening(rest) {
            kept += rest[..<start.lowerBound]
            if !closed { if !found { found = true; body = nil; attributes = tag }; rest = ""; break }
            let after = rest[start.upperBound...]
            guard let end = after.range(of: closeTag) else { if !found { found = true; body = nil; attributes = tag }; rest = ""; break }
            if !found { found = true; body = String(after[..<end.lowerBound]); attributes = tag }
            rest = after[end.upperBound...]
        }
        kept += rest
        var reply = SpacePatch.split(kept).reply
        // "<space-bu…" still arriving at the end of a streamed reply is not shown either.
        if let lt = reply.range(of: "<", options: .backwards) {
            let tail = reply[lt.lowerBound...]
            if tail.count >= 2 && openTag.hasPrefix(tail) { reply = String(reply[..<lt.lowerBound]) }
        }
        return (found || reply != text ? reply.trimmingCharacters(in: .whitespacesAndNewlines) : text, found, body,
                attribute("for", in: attributes), attribute("from", in: attributes))
    }

    // The next "<space-build …>": its range, what is between the name and ">", and whether the tag is complete yet.
    private static func opening(_ text: Substring) -> (Range<Substring.Index>, String, Bool)? {
        var from = text.startIndex
        while let start = text.range(of: "<space-build", range: from..<text.endIndex) {
            let after = text[start.upperBound...]
            if after.first == ">" { return (start.lowerBound..<text.index(after: start.upperBound), "", true) }
            if after.first?.isWhitespace == true {
                guard let end = after.firstIndex(where: { $0 == ">" || $0 == "<" }) else { return (start.lowerBound..<text.endIndex, String(after), false) }
                if after[end] == ">" { return (start.lowerBound..<text.index(after: end), String(after[..<end]), true) }
            }
            from = start.upperBound
        }
        return nil
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let match = tag.range(of: #"\b"# + name + #"\s*=\s*["']?[A-Za-z0-9-]{1,80}"#, options: .regularExpression) else { return nil }
        let id = tag[match].drop { $0 != "=" }.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        return SpaceStore.validID(id) ? id : nil
    }

    static func section(_ name: String, in body: String) -> String? {
        guard let open = body.range(of: "<\(name)>"), let close = body.range(of: "</\(name)>", range: open.upperBound..<body.endIndex) else { return nil }
        var text = String(body[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {   // a fenced section: what is inside the fence
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
            text = lines.joined(separator: "\n")
        }
        return text
    }

    // A block's body checked: the page, its manifest (new Spaces), first data (new only) and migrate (changes only).
    static func parse(_ body: String?, new: Bool) -> Result<SpaceBuild, SpaceBad> {
        do {
            guard let body else { throw SpaceBad(reason: L("<space-build> 블록이 닫히지 않았어요 (답이 잘렸을 수 있어요)", "The <space-build> block is not closed (the reply may have been cut)")) }
            guard let html = section("space-html", in: body), !html.isEmpty else { throw SpaceBad(reason: L("<space-html>이 없어요", "No <space-html>")) }
            if let problem = SpaceCheck.problem(html) { throw SpaceBad(reason: problem) }
            var build = SpaceBuild(html: html)
            if let manifest = section("space-manifest", in: body), !manifest.isEmpty {
                guard let data = manifest.data(using: .utf8), let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw SpaceBad(reason: L("manifest가 JSON 객체가 아니에요", "The manifest is not a JSON object"))
                }
                if let name = dict["name"] as? String {
                    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { build.name = String(name.prefix(SpaceLimits.name)) }
                }
                if let icon = dict["icon"] as? String, icon.range(of: #"^[a-z0-9]+(\.[a-z0-9]+)*$"#, options: .regularExpression) != nil, icon.count <= 60 { build.icon = icon }
                if let color = dict["color"] as? String, SpaceManifest.colors.contains(color) { build.color = color }
                if let value = dict["schedule"], let data = try? JSONSerialization.data(withJSONObject: value),
                   let schedule = try? JSONDecoder().decode(SpaceSchedule.self, from: data), schedule.valid { build.schedule = schedule }
            }
            if new, let state = section("space-state", in: body), !state.isEmpty {
                guard state.utf8.count <= SpaceLimits.state else { throw SpaceBad(reason: L("처음 데이터가 1MB를 넘어요", "The first data is over 1 MB")) }
                guard let data = state.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                    throw SpaceBad(reason: L("<space-state>가 JSON 객체가 아니에요", "<space-state> is not a JSON object"))
                }
                build.state = data
            }
            if !new, let migrate = section("space-migrate", in: body), !migrate.isEmpty {
                guard migrate.utf8.count <= SpaceLimits.migrate else { throw SpaceBad(reason: L("migrate가 너무 길어요", "migrate is too long")) }
                if let problem = SpaceCheck.problem(migrate) { throw SpaceBad(reason: "migrate: " + problem) }
                guard migrate.range(of: #"function\s+migrate\s*\("#, options: .regularExpression) != nil else {
                    throw SpaceBad(reason: L("migrate는 function migrate(oldState) { … } 모양이어야 해요", "migrate must be function migrate(oldState) { … }"))
                }
                build.migrate = migrate
            }
            return .success(build)
        } catch let bad as SpaceBad {
            return .failure(bad)
        } catch {
            return .failure(SpaceBad(reason: error.localizedDescription))
        }
    }

    // The instruction a Space-making (or Space-changing) answer gets: the bridge, what is refused, the limits, one example.
    static let rule = """
        [Space]
        The user asks for a Space: a small personal app (tracker, board, dashboard, checklist, quiz, game) that runs in an
        isolated web view of this app. If the message does not really ask for such an app, answer normally and add no block.
        Otherwise reply in one or two short sentences (what it does, how to use it), then add ONE block (the user does not see it):
        <space-build>
        <space-manifest>{"name":"short name","icon":"SF Symbol name, e.g. checklist","color":"blue|purple|pink|red|orange|yellow|green|teal|gray"}</space-manifest>
        <space-html>one complete HTML page: inline <style> and <script> only</space-html>
        <space-state>{"first data as one JSON object"}</space-state>
        </space-build>
        The page has no network and no files. Refused (the whole block is dropped): over 300 KB; any URL (http, https, ws, //host,
        file); fetch, XMLHttpRequest, WebSocket, EventSource; eval, new Function, string timers; iframe, object, embed, frame, base;
        form action; meta refresh. Images only as data: URLs or inline SVG.
        Keep every piece of user data in the state, never in the HTML. Bridge (window.space, ready before your script runs):
        space.state.get(key) → the saved value (a copy) or undefined; space.state.set(key, value) → Promise<bool>, saves at once,
        JSON values, all data at most 1 MB; space.state.keys(); space.state.subscribe(fn(key, value)) → unsubscribe function;
        space.open({chat:"<chat id>"} | {todo:"<TODO id>"} | {file:"name in the chat's files folder"} | {url:"https://…"}) moves the
        user there (a link asks first); space.notify(text) shows a notice; space.theme = {dark: bool, accent: "#rrggbb", color}.
        Follow light and dark mode (prefers-color-scheme or space.theme.dark), use system-ui fonts, fit a narrow or wide window,
        write the page's words in the user's language. No commands, files, Git or approvals exist here.
        Example (a counter):
        <space-build><space-manifest>{"name":"물 마시기","icon":"drop","color":"teal"}</space-manifest>
        <space-html><!doctype html><style>body{font:15px system-ui;margin:24px}</style><button id=b>+1</button> <span id=n></span>
        <script>const n=document.getElementById('n');const show=()=>n.textContent=(space.state.get('count')||0)+'잔';
        document.getElementById('b').onclick=()=>space.state.set('count',(space.state.get('count')||0)+1).then(show);show();</script></space-html>
        <space-state>{"count":0}</space-state></space-build>
        """

    // A chat that names existing Spaces (SpaceStore.named) gets their code (pictures hidden) and the shape of their data,
    // so it can change one or make a new one from it. A change waits in the chat for the user to preview and apply.
    static func chatRule(_ spaces: [SpaceManifest]) -> String {
        guard !spaces.isEmpty else { return "" }
        let pages = spaces.map { manifest -> String in
            let folder = SpaceStore.folder(manifest.id)
            let html = SpacePictures.hide(SpaceStore.html(folder))
            return """
                [Space "\(manifest.name)" · id \(manifest.id) · icon \(manifest.icon) · color \(manifest.color) · version \(manifest.version)]
                [Data shape — keys and types only]
                \(SpaceStore.shape(SpaceStore.state(folder)))
                \(html.kept.isEmpty ? "" : "space-kept:1 … space-kept:\(html.kept.count) stand for its pictures (the app keeps their bytes).\n")[Current app.html]
                \(html.text)
                [End of app.html]
                """
        }
        return """
            [Existing Spaces the user named]
            The message names these Spaces of the user. You see their code and the shape of their data, never the data itself.
            To change one, add <space-build for="its id"> … </space-build>: the whole new page in <space-html>, <space-manifest> only
            to change its name, icon or color, never <space-state> (the data stays); if the page reads its data under other keys
            or in another shape, also send <space-migrate>function migrate(oldState) { …; return newState }</space-migrate>.
            The user previews the change in that Space and applies it. Keep every key the page does not need to change.
            To make a new Space from one (a copy, a variant, the same style), add <space-build from="its id"> with a new manifest,
            the page and first data, as for any new Space. space-kept:N markers stay pictures of the Space in for/from; leave each
            where its picture should stay, move it or drop it.
            If the message only asks about a Space, answer and add no block.
            \(pages.joined(separator: "\n"))
            """
    }

    // Changing a Space: its code, the shape of its data (keys and types, never values) and the talk so far.
    // `html` comes with its pictures hidden (SpacePictures.hide); `draws`: the AI can make pictures (ChatGPT).
    static func refinePrompt(manifest: SpaceManifest, html: String, state: Data, history: [SpaceRefineEntry], request: String,
                             draws: Bool = false, kept: Int = 0) -> String {
        let talk = history.suffix(10).map { ($0.role == "user" ? "[User] " : "[AI] ") + String($0.text.prefix(600)) }.joined(separator: "\n")
        return """
            You change a Space, a small app the user made in this app. The rules below are for its code.
            \(rule)
            Changing it: send the whole new page in <space-html> (and <space-manifest> only to change its name, icon or color).
            Never send <space-state>: the user's data stays. If the new page reads its data under other keys or in another shape,
            also send <space-migrate>function migrate(oldState) { …; return newState }</space-migrate> (plain JavaScript, no
            bridge calls); the user previews the result before it is applied. Keep every key the page does not need to change.
            \(SpacePictures.rule(draws: draws, kept: kept))
            [Space] name: \(manifest.name) · icon: \(manifest.icon) · color: \(manifest.color) · version \(manifest.version)
            [Data shape — keys and types only]
            \(SpaceStore.shape(state))
            [Current app.html]
            \(html)
            [End of app.html]
            \(talk.isEmpty ? "" : "[Earlier requests about this Space]\n" + talk + "\n")[User request]
            \(request)
            """
    }
}

// Checks before anything is saved. They are a lint that tells the AI what to fix, not the isolation itself: the web
// view's CSP, content rules and navigation policy (SpaceWeb.swift) keep a page that slips past them offline.
enum SpaceCheck {
    private static let patterns: [(String, String, String)] = [
        (#"\b(https?|wss?|ftp)://"#, "외부 URL이 있어요", "It has an external URL"),
        (#"\bfile://"#, "file:// 주소가 있어요", "It has a file:// address"),
        (#"\b(src|href|action|poster|data|srcset|formaction|xlink:href)\s*=\s*["']?\s*//"#, "외부 주소(//…)가 있어요", "It has an external address (//…)"),
        (#"url\(\s*["']?\s*//"#, "외부 주소(//…)가 있어요", "It has an external address (//…)"),
        (#"@import"#, "@import가 있어요", "It has @import"),
        (#"\beval\s*\("#, "eval을 써요", "It uses eval"),
        (#"\bnew\s+Function\b|(^|[^\w.$])Function\s*\("#, "new Function을 써요", "It uses new Function"),
        (#"\bset(Timeout|Interval)\s*\(\s*["'`]"#, "글자로 된 타이머 코드를 써요", "It passes code as a string to a timer"),
        (#"\b(fetch|importScripts|XMLHttpRequest|WebSocket|EventSource|sendBeacon|RTCPeerConnection)\b"#, "네트워크 기능을 써요", "It uses the network"),
        (#"<\s*(iframe|object|embed|frame|frameset|base|portal|applet)\b"#, "iframe·object·embed 같은 태그가 있어요", "It has iframe, object, embed or a similar tag"),
        (#"<\s*form\b[^>]*\baction\s*="#, "form action이 있어요", "It has a form action"),
        (#"\bformaction\s*="#, "formaction이 있어요", "It has formaction"),
        (#"<\s*meta\b[^>]*http-equiv\s*=\s*["']?\s*refresh"#, "meta refresh가 있어요", "It has a meta refresh"),
        (#"shadowroot(mode)?\s*=|\bmode\s*:\s*["'`]closed"#, "닫힌 shadow DOM을 써요", "It uses a closed or declarative shadow DOM"),
        (#"\b(contentWindow|contentDocument)\b"#, "다른 프레임에 접근해요", "It reaches into another frame"),
    ]
    private static let compiled = patterns.map { (try! NSRegularExpression(pattern: $0.0, options: [.caseInsensitive, .anchorsMatchLines]), $0.1, $0.2) }

    // XML namespaces (inline SVG needs them: createElementNS) are names, not addresses.
    private static let namespaces = try! NSRegularExpression(pattern: #"https?://www\.w3\.org/(2000/svg|1999/xhtml|1999/xlink|1998/Math/MathML|XML/1998/namespace|2000/xmlns/?)(?=["'\s>])"#)

    // Why `html` is refused, or nil.
    static func problem(_ source: String) -> String? {
        // Pictures put in by the app do not count toward the code's 300 KB, only toward the page's whole limit.
        if source.utf8.count > SpacePictures.limit { return L("그림까지 합쳐 3MB를 넘어요", "It is over 3 MB with its pictures") }
        let code = SpacePictures.hide(source).text.utf8.count
        if code > SpaceLimits.html { return L("300KB를 넘어요 (\(code / 1000)KB)", "It is over 300 KB (\(code / 1000) KB)") }
        let html = namespaces.stringByReplacingMatches(in: source, range: NSRange(source.startIndex..., in: source), withTemplate: "ns:")
        let range = NSRange(html.startIndex..., in: html)
        for (regex, ko, en) in compiled {
            if let match = regex.firstMatch(in: html, range: range), let found = Range(match.range, in: html) {
                return L(ko, en) + ": " + String(html[found].prefix(60))
            }
        }
        return nil
    }

    static let csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; media-src data:; form-action 'none'; base-uri 'none'; frame-src 'none'; worker-src 'none'; connect-src 'none'"

    // The page as loaded: our CSP first, before any of the AI's markup (its own <html>/<head> tags merge into these).
    static func document(_ html: String) -> String {
        var body = Substring(html)
        while let first = body.first, first.isWhitespace || first == "\u{FEFF}" { body = body.dropFirst() }
        if body.lowercased().hasPrefix("<!doctype"), let end = body.firstIndex(of: ">") { body = body[body.index(after: end)...] }
        return "<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">"
            + "<meta name=\"color-scheme\" content=\"light dark\"><meta name=\"viewport\" content=\"width=device-width\">" + body
    }
}

// Pictures in a page. A ChatGPT (Codex) account changing a Space may draw with its image tool and write
// space-image:1 for the first picture it made in that answer; the app shrinks each (Pictures.spaceDataURL) and puts it
// in the page as a data: URL. Pictures already in the page reach the AI as space-kept:N, not as their bytes, and
// are put back the same way, so any AI can change a page another one drew for.
enum SpacePictures {
    static let limit = 3_000_000, perAnswer = 4
    private static let dataURL = try! NSRegularExpression(pattern: #"data:image/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=]{1000,}"#)
    private static let marker = try! NSRegularExpression(pattern: #"space-(image|kept):(\d+)"#)

    static func hide(_ html: String) -> (text: String, kept: [String]) {
        var kept: [String] = [], text = "", last = html.startIndex
        for match in dataURL.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            kept.append(String(html[range]))
            text += String(html[last..<range.lowerBound]) + "space-kept:\(kept.count)"
            last = range.upperBound
        }
        return (text + String(html[last...]), kept)
    }

    // The markers replaced by the pictures: `made` in this answer, `kept` from the page before.
    static func embed(_ html: String, made: [String], kept: [String]) -> Result<String, SpaceBad> {
        var text = "", last = html.startIndex
        for match in marker.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html), let kind = Range(match.range(at: 1), in: html),
                  let digits = Range(match.range(at: 2), in: html), let n = Int(html[digits]) else { continue }
            let list = html[kind] == "image" ? made : kept
            guard n >= 1 && n <= list.count else {
                return .failure(SpaceBad(reason: L("\(html[range])에 해당하는 그림이 없어요", "No picture for \(html[range])")))
            }
            text += String(html[last..<range.lowerBound]) + list[n - 1]
            last = range.upperBound
        }
        text += String(html[last...])
        guard text.utf8.count <= limit else { return .failure(SpaceBad(reason: L("그림까지 합쳐 3MB를 넘어요: 그림을 줄여 주세요", "Over 3 MB with its pictures: use fewer pictures"))) }
        return .success(text)
    }

    static func rule(draws: Bool, kept: Int) -> String {
        let old = kept > 0 ? "space-kept:1 … space-kept:\(kept) in the page stand for pictures already in it (the app keeps their bytes): "
            + "leave each marker where its picture should stay, move it or drop it as asked.\n" : ""
        return old + (draws
            ? "You can make pictures: when the request needs one (illustration, character, background, art), make it with your image "
              + "generation tool (no other commands), then write space-image:1 for the first picture you made in this answer, "
              + "space-image:2 for the second … as an <img> src or CSS url(). The app shrinks each to at most 768 px and puts it in "
              + "the page. At most \(perAnswer) new pictures."
            : "You cannot make painted pictures here: draw with inline SVG or CSS. If the user wants a painted picture, say that a "
              + "ChatGPT account chosen as this Space's worker (beside the change box) can draw it.")
    }

    // A chat's picture requests in its <space-build> (any AI may write them; a ChatGPT account draws them,
    // Discussion.drawSpacePictures): <space-picture n="1">what to draw</space-picture> for space-image:1, or
    // <space-picture n="1" from="2">how to change it</space-picture> to redraw space-kept:2 with that picture attached.
    struct Request: Equatable { var n: Int; var from: Int?; var text: String }
    private static let requestTag = try! NSRegularExpression(pattern: #"<space-picture\b([^>]*)>([\s\S]*?)</space-picture>"#)

    static func requests(in body: String) -> Result<[Request], SpaceBad> {
        var found: [Request] = []
        for match in requestTag.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let tag = Range(match.range(at: 1), in: body), let inner = Range(match.range(at: 2), in: body) else { continue }
            let text = String(body[inner].trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
            let n = number("n", in: String(body[tag])) ?? found.count + 1
            guard n == found.count + 1 else { return .failure(SpaceBad(reason: L("그림 요청은 n=\"1\"부터 차례로 번호를 매겨야 해요", "Number picture requests n=\"1\", \"2\", … in order"))) }
            guard !text.isEmpty else { return .failure(SpaceBad(reason: L("그림 \(n) 요청이 비어 있어요", "Picture request \(n) is empty"))) }
            found.append(Request(n: n, from: number("from", in: String(body[tag])), text: text))
        }
        guard found.count <= perAnswer else { return .failure(SpaceBad(reason: L("새 그림은 한 번에 \(perAnswer)장까지예요", "At most \(perAnswer) new pictures at a time"))) }
        return .success(found)
    }

    private static func number(_ name: String, in tag: String) -> Int? {
        guard let match = tag.range(of: #"\b"# + name + #"\s*=\s*["']?\d{1,3}"#, options: .regularExpression) else { return nil }
        return Int(tag[match].filter(\.isNumber))
    }

    // A kept picture (data: URL) as a file to attach for a redraw; the caller removes it.
    static func referenceFile(_ dataURL: String) -> URL? {
        guard let comma = dataURL.firstIndex(of: ","), let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        let type = dataURL[..<comma].dropFirst("data:image/".count).prefix { $0 != ";" }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("AI Illuminati space picture \(UUID().uuidString).\(type == "jpeg" ? "jpg" : type)")
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return nil }
        return file
    }

    // How a chat's AI puts painted pictures in a Space page (`draws`: a ChatGPT account can draw for it).
    static func chatRule(draws: Bool) -> String {
        draws
            ? "[Space pictures] For a painted picture in the page (illustration, character, background, art), do not draw it "
              + "yourself: inside the <space-build> block add <space-picture n=\"1\">what to draw: subject, style, colors, aspect "
              + "ratio</space-picture> and write space-image:1 in the page (an <img> src or CSS url()); n=\"2\" for space-image:2 … "
              + "At most \(perAnswer). To change a picture already in the page, add <space-picture n=\"1\" from=\"K\">how to change it"
              + "</space-picture> and put space-image:1 where space-kept:K was: the drawer gets that picture to work from, and "
              + "describe in words what stays. A ChatGPT account draws each one; the app shrinks it to at most 768 px and puts it in."
            : "[Space pictures] No ChatGPT account can draw here: draw with inline SVG or CSS, and say so if the user wants a painted picture."
    }
}

struct SpaceVersion: Codable, Equatable, Identifiable {
    var version: Int
    var at: Date
    var note: String
    var migrated: Bool     // the data changed with it: Undo also brings the data back
    var id: Int { version }
}

struct SpaceRefineEntry: Codable, Equatable {
    var role: String       // "user" or "ai"
    var text: String
    var at = Date()
}

// The Spaces on disk. The list and every change run on the main thread; the file helpers are static and may run anywhere.
final class SpaceStore: ObservableObject {
    static let shared = SpaceStore()
    @Published private(set) var spaces: [SpaceManifest] = []
    @Published private(set) var stateVersion: [String: Int] = [:]   // bumps when the data is replaced (Undo, migrate)

    static var root: URL { URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("spaces") }
    static func folder(_ id: String) -> URL { root.appendingPathComponent(id) }
    static func draftFolder(_ id: String) -> URL { root.appendingPathComponent(".drafts").appendingPathComponent(id) }
    static func validID(_ id: String) -> Bool { id.range(of: #"^[A-Za-z0-9-]{1,80}$"#, options: .regularExpression) != nil }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    static func manifest(at folder: URL) -> SpaceManifest? {
        (try? Data(contentsOf: folder.appendingPathComponent("manifest.json"))).flatMap { try? JSONDecoder().decode(SpaceManifest.self, from: $0) }
    }
    static func html(_ folder: URL) -> String { (try? String(contentsOf: folder.appendingPathComponent("app.html"), encoding: .utf8)) ?? "" }
    static func state(_ folder: URL) -> Data {
        (try? Data(contentsOf: folder.appendingPathComponent("state.json"))).flatMap { (try? JSONSerialization.jsonObject(with: $0)) is [String: Any] ? $0 : nil } ?? Data("{}".utf8)
    }

    func reload() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.root.path)) ?? []
        spaces = names.filter { !$0.hasPrefix(".") }.compactMap { Self.manifest(at: Self.folder($0)) }
            .sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) }
    }

    func manifest(_ id: String) -> SpaceManifest? { spaces.first { $0.id == id } }

    // MARK: Data, only through the bridge (or Undo / migrate)

    // `state` with `value` (JSON text; nil removes the key) under `key`. Fails when the key is odd, the value is not
    // JSON or the data would go over 1 MB.
    static func setting(_ state: Data, key: String, json: String?) -> Result<Data, SpaceBad> {
        guard !key.isEmpty, key.count <= SpaceLimits.key else { return .failure(SpaceBad(reason: L("키 이름이 이상해요", "Bad key"))) }
        guard var object = (try? JSONSerialization.jsonObject(with: state)) as? [String: Any] else { return .failure(SpaceBad(reason: "state.json")) }
        if let json {
            guard json.utf8.count <= SpaceLimits.state, let data = json.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
                return .failure(SpaceBad(reason: L("저장할 값이 JSON이 아니거나 너무 커요", "The value is not JSON or too big")))
            }
            object[key] = value
        } else {
            object.removeValue(forKey: key)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return .failure(SpaceBad(reason: "JSON")) }
        guard data.count <= SpaceLimits.state else { return .failure(SpaceBad(reason: L("데이터가 1MB를 넘어 저장하지 않았어요", "The data would be over 1 MB, so nothing was saved"))) }
        return .success(data)
    }

    // The same, saved in a Space's (or a draft's) folder. Nothing is written when it fails.
    static func setState(_ folder: URL, key: String, json: String?) -> Result<Void, SpaceBad> {
        switch setting(state(folder), key: key, json: json) {
        case .failure(let bad): return .failure(bad)
        case .success(let data):
            do { try write(data, to: folder.appendingPathComponent("state.json")) } catch { return .failure(SpaceBad(reason: error.localizedDescription)) }
            return .success(())
        }
    }

    // The data's shape for an AI: keys and types, never values (lists show the shape of their first item).
    static func shape(_ state: Data) -> String {
        func describe(_ value: Any, depth: Int) -> String {
            if depth > 4 { return "…" }
            switch value {
            case let dict as [String: Any]:
                return "{" + dict.keys.sorted().prefix(30).map { "\($0): " + describe(dict[$0]!, depth: depth + 1) }.joined(separator: ", ") + "}"
            case let list as [Any]: return "[" + (list.first.map { describe($0, depth: depth + 1) } ?? "") + "] (\(list.count))"
            case let number as NSNumber: return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
            case is String: return "string"
            default: return "null"
            }
        }
        guard let object = try? JSONSerialization.jsonObject(with: state) else { return "{}" }
        return describe(object, depth: 0)
    }

    // MARK: Making Spaces

    // A checked build saved as a draft (an answer's preview card plays with it): spaces/.drafts/<id>/. A change to an
    // existing Space keeps that Space's look unless it sends its own, and its migrate.
    static func saveDraft(_ build: SpaceBuild, over target: SpaceManifest? = nil) throws -> String {
        let id = UUID().uuidString
        let folder = draftFolder(id)
        var manifest = SpaceManifest(id: id, name: build.name ?? target?.name ?? "Space")
        manifest.icon = build.icon ?? target?.icon ?? manifest.icon; manifest.color = build.color ?? target?.color ?? manifest.color
        manifest.schedule = build.schedule
        try write(Data(build.html.utf8), to: folder.appendingPathComponent("app.html"))
        try write(build.state ?? Data("{}".utf8), to: folder.appendingPathComponent("state.json"))
        if let migrate = build.migrate { try write(Data(migrate.utf8), to: folder.appendingPathComponent("migrate.js")) }
        try write(encode(manifest), to: folder.appendingPathComponent("manifest.json"))
        return id
    }

    // A draft back as a change: its page, look and migrate.
    static func draftBuild(_ draft: String) -> SpaceBuild? {
        let folder = draftFolder(draft)
        guard validID(draft), let manifest = manifest(at: folder) else { return nil }
        let html = html(folder)
        guard !html.isEmpty else { return nil }
        let migrate = try? String(contentsOf: folder.appendingPathComponent("migrate.js"), encoding: .utf8)
        return SpaceBuild(name: manifest.name, icon: manifest.icon, color: manifest.color, html: html, migrate: migrate)
    }

    // Words that ask to change or reuse something: with a Space's name, the chat gets that Space.
    static let changeWords = try! NSRegularExpression(pattern:
        #"고치|고쳐|수정|바꿔|바꾸|바뀌게|업데이트|추가|넣어|넣고|빼줘|빼고|지워|없애|만들|참고|복사|기반|베이스|처럼|비슷하게|개선|업그레이드|다듬|\b(update|change|edit|fix|add|remove|make|build|improve|copy|based\s+on|like)\b"#,
        options: [.caseInsensitive])
    // The Spaces a message names (by name, spaces ignored) while asking to change, fix or reuse something; at most two,
    // longest name first. Read from disk, so any thread may ask.
    static func named(in question: String) -> [SpaceManifest] {
        let text = question.components(separatedBy: "\n").filter { !$0.hasPrefix(">") }.joined(separator: "\n")
        guard changeWords.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return [] }
        let squeezed = text.lowercased().filter { !$0.isWhitespace }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let all = names.filter { !$0.hasPrefix(".") }.compactMap { manifest(at: folder($0)) }
        func key(_ m: SpaceManifest) -> String { m.name.lowercased().filter { !$0.isWhitespace } }
        var picked: [SpaceManifest] = []
        for space in all.sorted(by: { key($0).count > key($1).count }) {
            let name = key(space)
            guard name.count >= 2, name != "space", squeezed.contains(name), !picked.contains(where: { key($0).contains(name) }) else { continue }
            picked.append(space)
            if picked.count == 2 { break }
        }
        return picked
    }

    // A new Space from code and first data. `id` given: made once (migration), nil when it is already there.
    @discardableResult
    static func make(name: String, icon: String, color: String, html: String, state: Data, origin: String?, template: String? = nil,
                     schedule: SpaceSchedule? = nil, id: String = UUID().uuidString, order: Int = 0) throws -> SpaceManifest {
        let folder = folder(id)
        var manifest = SpaceManifest(id: id, name: String(name.prefix(SpaceLimits.name)))
        manifest.icon = icon; manifest.color = color; manifest.originChat = origin; manifest.template = template
        manifest.schedule = schedule; manifest.order = order
        // Written into a hidden folder and moved whole, so a half-made Space never shows.
        let temp = root.appendingPathComponent(".new-" + id)
        try? FileManager.default.removeItem(at: temp)
        try write(Data(html.utf8), to: temp.appendingPathComponent("app.html"))
        try write(state, to: temp.appendingPathComponent("state.json"))
        try write(encode(manifest), to: temp.appendingPathComponent("manifest.json"))
        try FileManager.default.moveItem(at: temp, to: folder)
        return manifest
    }

    func nextOrder() -> Int { (spaces.map(\.order).max() ?? -1) + 1 }

    // A draft (its code and the data played with in the preview) becomes a Space in the sidebar.
    func adopt(draft: String, origin: UUID?) throws -> SpaceManifest {
        dispatchPrecondition(condition: .onQueue(.main))
        let folder = Self.draftFolder(draft)
        guard Self.validID(draft), let found = Self.manifest(at: folder) else { throw SpaceBad(reason: L("미리보기를 찾지 못했어요", "The preview is gone")) }
        let made = try Self.make(name: found.name, icon: found.icon, color: found.color, html: Self.html(folder), state: Self.state(folder),
                                 origin: origin?.uuidString, schedule: found.schedule, order: nextOrder())
        try? FileManager.default.removeItem(at: folder)
        reload()
        return made
    }

    // Previews nobody added or discarded (their chat was deleted, say) go after `days`.
    static func pruneDrafts(olderThan days: Double = 30, now: Date = Date()) {
        let dir = root.appendingPathComponent(".drafts")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let folder = dir.appendingPathComponent(name)
            let made = (try? FileManager.default.attributesOfItem(atPath: folder.path)[.modificationDate] as? Date) ?? now
            if now.timeIntervalSince(made) > days * 86400 { try? FileManager.default.removeItem(at: folder) }
        }
    }

    static func discardDraft(_ draft: String) {
        guard validID(draft) else { return }
        try? FileManager.default.removeItem(at: draftFolder(draft))
    }

    func makeFromTemplate(_ template: SpaceTemplate, state: Data? = nil, name: String? = nil, origin: UUID? = nil) throws -> SpaceManifest {
        let made = try Self.make(name: name ?? template.name, icon: template.icon, color: template.color, html: template.html,
                                 state: state ?? template.firstState(), origin: origin?.uuidString, template: template.rawValue, order: nextOrder())
        reload()
        return made
    }

    // MARK: Changing the code, keeping the versions before

    static func versions(_ id: String) -> [SpaceVersion] {
        let dir = folder(id).appendingPathComponent("versions")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name in
            (try? Data(contentsOf: dir.appendingPathComponent(name).appendingPathComponent("info.json"))).flatMap { try? JSONDecoder().decode(SpaceVersion.self, from: $0) }
        }.sorted { $0.version < $1.version }
    }

    // New code (and, after a migrate, new data): the code and data before go to versions/<version> first.
    func apply(_ id: String, html: String, state: Data? = nil, note: String, name: String? = nil, icon: String? = nil, color: String? = nil) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        if let problem = SpaceCheck.problem(html) { throw SpaceBad(reason: problem) }
        if let state { guard state.count <= SpaceLimits.state, (try? JSONSerialization.jsonObject(with: state)) is [String: Any] else { throw SpaceBad(reason: L("새 데이터가 JSON 객체가 아니거나 1MB를 넘어요", "The new data is not a JSON object or is over 1 MB")) } }
        let folder = Self.folder(id)
        guard var manifest = Self.manifest(at: folder) else { throw SpaceBad(reason: L("Space를 찾지 못했어요", "Space not found")) }
        let saved = folder.appendingPathComponent("versions").appendingPathComponent(String(manifest.version))
        try? FileManager.default.removeItem(at: saved)
        try Self.write(Data(Self.html(folder).utf8), to: saved.appendingPathComponent("app.html"))
        try Self.write(Self.state(folder), to: saved.appendingPathComponent("state.json"))
        try Self.write(Self.encode(SpaceVersion(version: manifest.version, at: Date(), note: note, migrated: state != nil)), to: saved.appendingPathComponent("info.json"))
        try Self.write(Self.encode(manifest), to: saved.appendingPathComponent("manifest.json"))   // its name, icon and color
        try Self.write(Data(html.utf8), to: folder.appendingPathComponent("app.html"))
        if let state { try Self.write(state, to: folder.appendingPathComponent("state.json")); stateVersion[id, default: 0] += 1 }
        manifest.version += 1; manifest.updatedAt = Date()
        if let name, !name.isEmpty { manifest.name = String(name.prefix(SpaceLimits.name)) }
        if let icon { manifest.icon = icon }
        if let color { manifest.color = color }
        try Self.write(Self.encode(manifest), to: folder.appendingPathComponent("manifest.json"))
        // Only the newest versions stay.
        for old in Self.versions(id).dropLast(SpaceLimits.versions) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("versions").appendingPathComponent(String(old.version)))
        }
        reload()
    }

    // Back to the code (and name, icon, color) before the last change; its data too when that change migrated the data.
    @discardableResult
    func undo(_ id: String) throws -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let last = Self.versions(id).last else { return false }
        let folder = Self.folder(id)
        let saved = folder.appendingPathComponent("versions").appendingPathComponent(String(last.version))
        guard var manifest = Self.manifest(at: folder) else { return false }
        try Self.write(Data(Self.html(saved).utf8), to: folder.appendingPathComponent("app.html"))
        if last.migrated { try Self.write(Self.state(saved), to: folder.appendingPathComponent("state.json")); stateVersion[id, default: 0] += 1 }
        if let before = Self.manifest(at: saved) { manifest.name = before.name; manifest.icon = before.icon; manifest.color = before.color }
        manifest.version = last.version; manifest.updatedAt = Date()
        try Self.write(Self.encode(manifest), to: folder.appendingPathComponent("manifest.json"))
        try? FileManager.default.removeItem(at: saved)
        reload()
        return true
    }

    // An older version's code and look back as a new change (so it can be undone too). The data stays as it is,
    // unless a later change moved it to other keys: then that version's data comes back with its code.
    func restore(_ id: String, to version: Int) throws {
        let saved = Self.folder(id).appendingPathComponent("versions").appendingPathComponent(String(version))
        let html = Self.html(saved)
        guard !html.isEmpty else { throw SpaceBad(reason: L("그 판을 찾지 못했어요", "That version is gone")) }
        let reshaped = Self.versions(id).contains { $0.version >= version && $0.migrated }
        let look = Self.manifest(at: saved)
        try apply(id, html: html, state: reshaped ? Self.state(saved) : nil, note: L("\(version)판으로 되돌림", "Back to version \(version)"),
                  name: look?.name, icon: look?.icon, color: look?.color)
    }

    // MARK: The sidebar's changes

    func update(_ id: String, _ body: (inout SpaceManifest) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        let folder = Self.folder(id)
        guard var manifest = Self.manifest(at: folder) else { return }
        body(&manifest)
        manifest.name = String(manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SpaceLimits.name))
        if manifest.name.isEmpty { manifest.name = "Space" }
        guard let data = try? Self.encode(manifest), (try? Self.write(data, to: folder.appendingPathComponent("manifest.json"))) != nil else { return }
        reload()
    }

    // One step up or down among the Spaces listed with it (orders are renumbered, so they stay distinct).
    func move(_ id: String, by step: Int, among listed: [String]) {
        guard let at = listed.firstIndex(of: id), listed.indices.contains(at + step) else { return }
        var ids = spaces.map(\.id)
        let other = listed[at + step]
        guard let a = ids.firstIndex(of: id), let b = ids.firstIndex(of: other) else { return }
        ids.swapAt(a, b)
        for (order, each) in ids.enumerated() { update(each) { $0.order = order } }
    }

    // To the Trash (the user confirms first).
    func delete(_ id: String) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        guard Self.validID(id) else { return }
        try FileManager.default.trashItem(at: Self.folder(id), resultingItemURL: nil)
        reload()
    }

    static func refineLog(_ id: String) -> [SpaceRefineEntry] {
        (try? Data(contentsOf: folder(id).appendingPathComponent("refine.json"))).flatMap { try? JSONDecoder().decode([SpaceRefineEntry].self, from: $0) } ?? []
    }
    static func addRefine(_ id: String, _ entry: SpaceRefineEntry) {
        let log = Array((refineLog(id) + [entry]).suffix(SpaceLimits.refine))
        if let data = try? encode(log) { try? write(data, to: folder(id).appendingPathComponent("refine.json")) }
    }

    // MARK: The old per-chat Spaces (<room>.work/space.json)

    // Each old space.json becomes Spaces made from the templates: decision logs (with their checklists as next steps)
    // in one, every other block in its own. Ids come from the chat and the block, so a run cut short makes no copies.
    // The old file is renamed space.json.migrated only when all of its Spaces are saved; a file that fails stays.
    @discardableResult
    static func migrateLegacy(chats: String = AccountStore.supportDir + "/chats") -> [String] {
        var made: [String] = []
        let names = (try? FileManager.default.contentsOfDirectory(atPath: chats)) ?? []
        for name in names.sorted() where name.hasSuffix(".work") {
            guard let room = UUID(uuidString: String(name.dropLast(5))) else { continue }
            let file = URL(fileURLWithPath: chats).appendingPathComponent(name).appendingPathComponent("space.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do {
                guard let data = try? Data(contentsOf: file), let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw SpaceBad(reason: "unreadable")
                }
                let ids = try migrate(doc, room: room)
                let moved = file.deletingLastPathComponent().appendingPathComponent("space.json.migrated")
                try? FileManager.default.removeItem(at: moved)
                try FileManager.default.moveItem(at: file, to: moved)
                made += ids
            } catch {
                NSLog("AI Illuminati: old Space \(file.path) was not moved: \((error as? SpaceBad)?.reason ?? error.localizedDescription)")
            }
        }
        return made
    }

    static func migrate(_ doc: [String: Any], room: UUID) throws -> [String] {
        let title = (doc["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Space"
        let goal = doc["goal"] as? String ?? ""
        let blocks = doc["blocks"] as? [[String: Any]] ?? []
        func items(_ block: [String: Any]) -> [[String: Any]] { block["items"] as? [[String: Any]] ?? [] }
        func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        var made: [String] = []
        func make(_ template: SpaceTemplate, _ name: String, _ state: [String: Any], _ n: Int) throws {
            let id = "legacy-" + room.uuidString + "-\(n)"
            if FileManager.default.fileExists(atPath: folder(id).path) { made.append(id); return }
            try Self.make(name: name, icon: template.icon, color: template.color, html: template.html, state: try json(state),
                          origin: room.uuidString, template: template.rawValue, id: id)
            made.append(id)
        }
        let logs = blocks.filter { $0["kind"] as? String == "decisionLog" }
        if !logs.isEmpty {
            let decisions: [[String: Any]] = logs.flatMap(items).map { item in
                var d: [String: Any] = ["id": item["id"] as? String ?? UUID().uuidString, "text": item["text"] as? String ?? "",
                                        "open": item["open"] as? Bool ?? false, "pro": item["pro"] as? [String] ?? [], "con": item["con"] as? [String] ?? [],
                                        "source": item["source"] as? String ?? "", "confirmed": item["status"] as? String == "confirmed"]
                if let chat = item["chat"] as? String { d["chat"] = chat }
                if let todo = item["todo"] as? String { d["todo"] = todo }
                return d
            }
            let next = blocks.filter { $0["kind"] as? String == "checklist" }.flatMap(items).map(checkItem)
            try make(.decisions, title, ["title": logs.count == 1 ? (logs[0]["title"] as? String ?? title) : title, "goal": goal, "decisions": decisions, "next": next], 0)
        }
        for (n, block) in blocks.enumerated() {
            let kind = block["kind"] as? String
            let name = (block["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title
            switch kind {
            case "checklist" where logs.isEmpty:
                try make(.checklist, name, ["title": name, "goal": goal, "items": items(block).map(checkItem)], n + 1)
            case "kanban":
                // Every lane is kept on its item; the last lane counts as done.
                let lanes = block["columns"] as? [String] ?? []
                let list: [[String: Any]] = items(block).map { item in
                    var c = checkItem(item)
                    let lane = item["lane"] as? String ?? ""
                    c["lane"] = lane; c["done"] = !lanes.isEmpty && lane == lanes.last
                    return c
                }
                try make(.checklist, name, ["title": name, "goal": goal, "lanes": lanes, "items": list], n + 1)
            case "table":
                let rows: [[String: Any]] = items(block).map { item in
                    var r: [String: Any] = ["id": item["id"] as? String ?? UUID().uuidString, "cells": item["cells"] as? [String] ?? [], "source": "", "checked": ""]
                    if let todo = item["todo"] as? String { r["todo"] = todo }
                    if let chat = item["chat"] as? String { r["chat"] = chat }
                    return r
                }
                try make(.compare, name, ["title": name, "columns": block["columns"] as? [String] ?? [], "rows": rows], n + 1)
            default: break
            }
        }
        if made.isEmpty { try make(.checklist, title, ["title": title, "goal": goal, "items": []], 0) }
        return made
    }

    private static func checkItem(_ item: [String: Any]) -> [String: Any] {
        var c: [String: Any] = ["id": item["id"] as? String ?? UUID().uuidString, "text": item["text"] as? String ?? "", "done": item["done"] as? Bool ?? false]
        if let todo = item["todo"] as? String { c["todo"] = todo }
        if let chat = item["chat"] as? String { c["chat"] = chat }
        return c
    }
}

// What is left of the old Space patch: older answers still carry <space-patch> blocks, and they stay hidden.
enum SpacePatch {
    static let openTag = "<space-patch", closeTag = "</space-patch>"

    static func split(_ text: String) -> (reply: String, raw: String?) {
        var rest = Substring(text), kept = "", raw: String?
        while let start = rest.range(of: openTag) {
            kept += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].range(of: closeTag) else { raw = String(rest[start.lowerBound...]); rest = ""; break }
            raw = String(rest[start.lowerBound..<end.upperBound])
            rest = rest[end.upperBound...]
        }
        kept += rest
        if let lt = kept.range(of: "<", options: .backwards) {
            let tail = kept[lt.lowerBound...]
            if tail.count >= 2 && openTag.hasPrefix(tail) { kept = String(kept[..<lt.lowerBound]); raw = raw ?? "" }
        }
        guard raw != nil else { return (text, nil) }
        return (kept.trimmingCharacters(in: .whitespacesAndNewlines), raw)
    }

    // A meeting's result (Discussion.meetingFinal headings) as the decision log template's data.
    static func meetingState(_ result: String, title: String, source: String, chat: UUID?) -> [String: Any] {
        enum Part { case conclusion, reasons, agreed, disputed, decide, next }
        let heads: [(Part, [String])] = [
            (.decide, ["네 결정이 필요한 것", "결정이 필요한 것", "결정 필요", "needs your decision"]), (.conclusion, ["결론", "conclusion"]),
            (.reasons, ["근거", "reasons"]), (.agreed, ["합의", "agreed", "agreement"]),
            (.disputed, ["이견", "disagreements", "disagreement"]), (.next, ["다음 행동", "next steps", "next step"])]
        func heading(_ name: String) -> Part? {
            let name = name.lowercased()
            return heads.first { entry in entry.1.contains { head in name == head || name.hasPrefix(head + " ") || name.hasPrefix(head + "(") } }?.0
        }
        func clean(_ text: String) -> String {
            String(text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").trimmingCharacters(in: .whitespaces).prefix(500))
        }
        var part: Part?, found: [Part: [String]] = [:]
        for line in result.components(separatedBy: .newlines) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, s != "---" else { continue }
            let bullet = s.range(of: #"^([-*•]|\d+[.)])\s+"#, options: .regularExpression)
            if bullet == nil {
                // "## 결론", "**합의**", "결론: …" (a heading with its first point after the colon)
                let head = clean(s.replacingOccurrences(of: #"^[#>\s]+"#, with: "", options: .regularExpression))
                let pieces = head.split(maxSplits: 1, whereSeparator: { $0 == ":" || $0 == "：" })
                if let first = pieces.first, let next = heading(first.trimmingCharacters(in: .whitespaces)) {
                    part = next
                    if pieces.count > 1 { let rest = clean(String(pieces[1])); if !rest.isEmpty { found[next, default: []].append(rest) } }
                    continue
                }
            }
            guard let part else { continue }
            let text = clean(bullet.map { String(s[$0.upperBound...]) } ?? s)
            if !text.isEmpty { found[part, default: []].append(text) }
        }
        var n = 0
        func decision(_ text: String, open: Bool) -> [String: Any] {
            n += 1
            var d: [String: Any] = ["id": "d\(n)", "text": text, "open": open, "pro": [String](), "con": [String](), "source": source, "confirmed": false]
            if let chat { d["chat"] = chat.uuidString }
            return d
        }
        var decisions = (found[.conclusion] ?? []).map { decision($0, open: false) } + (found[.agreed] ?? []).map { decision($0, open: false) }
        decisions += (found[.disputed] ?? []).map { decision(L("이견: ", "Disagreement: ") + $0, open: true) }
        decisions += (found[.decide] ?? []).map { decision($0, open: true) }
        if decisions.isEmpty, let first = result.components(separatedBy: "\n\n").map(clean).first(where: { !$0.isEmpty }) {
            decisions = [decision(first, open: false)]
        }
        let next: [[String: Any]] = (found[.next] ?? []).enumerated().map { ["id": "n\($0.offset + 1)", "text": $0.element, "done": false] }
        return ["title": title, "goal": "", "decisions": Array(decisions.prefix(200)), "next": Array(next.prefix(200))]
    }
}
