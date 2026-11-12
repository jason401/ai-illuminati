import Foundation
import AIAccounts
import AILocalization

// The Spaces folder as the user's shelf of small apps: a plain chat's AI gets spaces/ as a folder it may change
// (Discussion.soloBinding) and edits a Space's app.html, manifest.json and state.json directly, or adds a new folder.
// sync() runs after each such answer and when the app comes back to the front: a good page becomes a new version
// (Undo), one that fails SpaceCheck is put back, and a new Space whose page fails is set aside in spaces/.rejected/.
// What was last accepted is kept out of the AIs' folder, in spaces-sync/<id>/.

// What sync() did to one Space, shown under the answer that made the change.
public struct SpaceSyncNote: Codable, Equatable {
    public var space: String
    public var name: String
    public var kind: String          // "added", "changed", "refused", "set-aside", "removed"
    public var reason: String?
    public var version: Int?
}

// Pictures as files: spaces/<id>/assets/<name>, written in the page as assets/<name>. The web view reads no files: they
// load through space-asset:// (served, SpaceAssetServer), and go in as data: URLs only for a one-file export (inline).
// Pictures the app gets as data: URLs (a ChatGPT drawing, an older page) are moved out to files when the page is saved
// (extract). app.html stays small enough to edit, and a Space may hold up to SpaceLimits.total of files.
public enum SpaceAssets {
    static let folder = "assets", scheme = "space-asset"
    static let shrinkFrom = 20_000_000
    // assets/name after a quote, "(", "=" or a space, and before a quote, ")", a space or ">".
    private static let reference = try! NSRegularExpression(pattern: #"(?<=["'(=\s])(?:\./)?assets/([A-Za-z0-9_-][A-Za-z0-9._-]{0,99})(?=["')\s>])"#)

    static func names(in html: String) -> Set<String> {
        Set(reference.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { Range($0.range(at: 1), in: html).map { String(html[$0]) } })
    }

    // The type from the bytes, not the file name (a shrunk picture keeps its name).
    static func mime(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(16))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if head.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if head.count >= 12, head.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(head[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        if let text = String(data: data.prefix(512), encoding: .utf8), text.range(of: "<svg", options: .caseInsensitive) != nil { return "image/svg+xml" }
        return nil
    }

    public static func dataURL(_ name: String, folder: URL) -> String? {
        guard let url = file(name, folder: folder), let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let type = mime(data) else { return nil }
        return "data:\(type);base64," + data.base64EncodedString()
    }

    static func inline(_ html: String, folder: URL) -> String {
        var text = "", last = html.startIndex, cache: [String: String] = [:]
        for match in reference.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html), let nameRange = Range(match.range(at: 1), in: html) else { continue }
            let name = String(html[nameRange])
            if cache[name] == nil { cache[name] = dataURL(name, folder: folder) }
            guard let url = cache[name] else { continue }   // missing: left as it is, and the picture shows broken
            text += String(html[last..<range.lowerBound]) + url
            last = range.upperBound
        }
        return text + String(html[last...])
    }

    // The page as the web view loads it: each assets/name as space-asset://local/name.
    static func served(_ html: String) -> String {
        reference.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: scheme + "://local/$1")
    }

    // A picture file's name as the page may name it (no hidden files, no folders).
    static func file(_ name: String, folder: URL) -> URL? {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), name.utf8.count <= 100 else { return nil }
        return folder.appendingPathComponent(Self.folder).appendingPathComponent(name)
    }

    // What a Space's files take: its assets/ folder (versions share them; they hold only code and data).
    static func bytes(_ folder: URL) -> Int {
        let dir = folder.appendingPathComponent(Self.folder)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
        return files.reduce(0) { sum, url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            return sum + (values?.isRegularFile == true ? values?.fileSize ?? 0 : 0)
        }
    }

    // Why `html` with `folder`'s files is over the whole limit, or nil.
    static func overLimit(_ html: String, folder: URL) -> String? {
        let total = html.utf8.count + bytes(folder)
        guard total > SpaceLimits.total else { return nil }
        return L("그림 파일까지 합쳐 1GB를 넘어요 (\(total / 1_000_000)MB)", "It is over 1 GB with its picture files (\(total / 1_000_000) MB)")
    }

    // The picture files `html` names, copied from one Space's folder to another (a new Space made from it). On APFS a
    // copy is a clone, so big files cost nothing until one changes.
    static func copy(for html: String, from source: URL, to target: URL) throws {
        let fm = FileManager.default
        for name in names(in: html) {
            guard let from = file(name, folder: source), let to = file(name, folder: target), fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.copyItem(at: from, to: to)
        }
    }

    static func extract(_ html: String, into folder: URL) -> String {
        var text = "", last = html.startIndex
        for match in SpacePictures.dataURL.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            let url = html[range]
            guard let comma = url.firstIndex(of: ","), let data = Data(base64Encoded: String(url[url.index(after: comma)...])), let type = mime(data) else { continue }
            let ext = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp", "image/svg+xml": "svg"][type] ?? "img"
            let name = "picture-\(hash(data)).\(ext)"
            let file = folder.appendingPathComponent(Self.folder).appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: file.path) { guard (try? SpaceStore.write(data, to: file)) != nil else { continue } }
            text += String(html[last..<range.lowerBound]) + "assets/" + name
            last = range.upperBound
        }
        return text + String(html[last...])
    }

    static func hash(_ data: Data) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in data { h ^= UInt64(byte); h = h &* 0x100000001b3 }
        return String(format: "%016llx", h)
    }

    // Pictures the app put in (picture-…) that neither the page nor a kept version uses any more. Files the user or an
    // AI put there stay: a page may build their names in code.
    static func prune(_ id: String) {
        let folder = SpaceStore.folder(id), dir = folder.appendingPathComponent(Self.folder)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard files.contains(where: { $0.hasPrefix("picture-") }) else { return }
        var used = names(in: SpaceStore.html(folder))
        for version in SpaceStore.versions(id) {
            used.formUnion(names(in: SpaceStore.html(folder.appendingPathComponent("versions").appendingPathComponent(String(version.version)))))
        }
        for file in files where file.hasPrefix("picture-") && !used.contains(file) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(file)) }
    }
}

public enum SpaceLibrary {
    static var syncRoot: URL { URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("spaces-sync") }
    static func kept(_ id: String) -> URL { syncRoot.appendingPathComponent(id) }
    static var rejected: URL { SpaceStore.root.appendingPathComponent(".rejected") }

    private static let lock = NSLock()
    private static var stamps: [String: Date] = [:]   // state.json as the app last wrote or accepted it
    private static var answering = 0

    private static func modified(_ url: URL) -> Date? { (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }

    static func noteStateWritten(_ folder: URL) {
        let date = modified(folder.appendingPathComponent("state.json"))
        lock.lock(); stamps[folder.lastPathComponent] = date; lock.unlock()
    }
    private static func stateMoved(_ id: String) -> Bool {
        let now = modified(SpaceStore.folder(id).appendingPathComponent("state.json"))
        lock.lock(); defer { lock.unlock() }
        guard let known = stamps[id] else { stamps[id] = now; return false }   // first look since launch
        return known != now
    }

    // An answer that may write in the Spaces folder is running: the sync on coming to the front waits for it, so a
    // page still being written is not put back. Its data as it was before is kept, for Undo after the answer.
    public static func beginAnswer() {
        lock.lock(); answering += 1; lock.unlock()
        for manifest in all() {
            let state = SpaceStore.folder(manifest.id).appendingPathComponent("state.json")
            if let data = try? Data(contentsOf: state), (try? JSONSerialization.jsonObject(with: data)) is [String: Any] {
                try? SpaceStore.write(data, to: kept(manifest.id).appendingPathComponent("state.json"))
            }
            _ = stateMoved(manifest.id)
        }
    }
    public static func endAnswer() { lock.lock(); answering = max(0, answering - 1); lock.unlock() }
    public static var busy: Bool { lock.lock(); defer { lock.unlock() }; return answering > 0 }

    public static func all() -> [SpaceManifest] {
        ((try? FileManager.default.contentsOfDirectory(atPath: SpaceStore.root.path)) ?? []).filter { !$0.hasPrefix(".") && SpaceStore.validID($0) }
            .compactMap { SpaceStore.manifest(at: SpaceStore.folder($0)) }
    }

    // What the app itself has just written becomes the accepted copy (its pictures moved out to assets/ first).
    static func settle(_ id: String) {
        let folder = SpaceStore.folder(id), kept = kept(id)
        let html = SpaceStore.html(folder), stored = SpaceAssets.extract(html, into: folder)
        if stored != html { try? SpaceStore.write(Data(stored.utf8), to: folder.appendingPathComponent("app.html")) }
        try? SpaceStore.write(Data(stored.utf8), to: kept.appendingPathComponent("app.html"))
        if let manifest = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) { try? SpaceStore.write(manifest, to: kept.appendingPathComponent("manifest.json")) }
        try? SpaceStore.write(SpaceStore.state(folder), to: kept.appendingPathComponent("state.json"))
        noteStateWritten(folder)
        SpaceAssets.prune(id)
    }

    static func forget(_ id: String) {
        try? FileManager.default.removeItem(at: kept(id))
        lock.lock(); stamps[id] = nil; lock.unlock()
    }

    // `shrink`: a picture file over SpaceAssets.shrinkFrom made smaller (nil keeps it). Returns what changed and the
    // Spaces whose data changed outside the bridge (open pages load again). Main thread (the caller reloads the list).
    public static func sync(shrink: ((URL) -> Data?)? = nil) -> (notes: [SpaceSyncNote], reshaped: [String]) {
        let fm = FileManager.default, root = SpaceStore.root
        let names = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        let ready = syncRoot.appendingPathComponent(".ready")
        if !fm.fileExists(atPath: ready.path) {
            // The first run of this build: every Space as it is now is accepted.
            for name in names where SpaceStore.validID(name) && SpaceStore.manifest(at: SpaceStore.folder(name)) != nil { settle(name) }
            try? SpaceStore.write(Data(), to: ready)
            return ([], [])
        }
        var notes: [SpaceSyncNote] = [], reshaped: [String] = []
        var order = (all().map(\.order).max() ?? -1) + 1
        for name in names {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: root.appendingPathComponent(name).path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            var id = name, title: String?
            if !SpaceStore.validID(name) {
                // A new folder named in words ("커피 트래커"): it gets an id, and the words become its name.
                guard fm.fileExists(atPath: root.appendingPathComponent(name).appendingPathComponent("app.html").path) else { continue }
                id = UUID().uuidString
                guard (try? fm.moveItem(at: root.appendingPathComponent(name), to: SpaceStore.folder(id))) != nil else { continue }
                title = name
            }
            if let note = syncOne(id, title: title, order: &order, shrink: shrink, reshaped: &reshaped) { notes.append(note) }
        }
        // Spaces gone from the folder (an AI moved one to the Trash); the app's own Delete forgets them first.
        for id in ((try? fm.contentsOfDirectory(atPath: syncRoot.path)) ?? []).sorted() where !id.hasPrefix(".") && !fm.fileExists(atPath: SpaceStore.folder(id).path) {
            let name = SpaceStore.manifest(at: kept(id))?.name ?? "Space"
            forget(id)
            notes.append(SpaceSyncNote(space: id, name: name, kind: "removed"))
        }
        return (notes, reshaped)
    }

    private static func syncOne(_ id: String, title: String?, order: inout Int, shrink: ((URL) -> Data?)?, reshaped: inout [String]) -> SpaceSyncNote? {
        let fm = FileManager.default, folder = SpaceStore.folder(id), kept = kept(id)
        let known = fm.fileExists(atPath: kept.appendingPathComponent("app.html").path) ? SpaceStore.html(kept) : nil
        let old = known == nil ? nil : SpaceStore.manifest(at: kept)
        let rawManifest = try? Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        guard known != nil || fm.fileExists(atPath: folder.appendingPathComponent("app.html").path) else { return nil }   // not a Space (yet)

        // The manifest: what the AI may change (name, look, schedule, pin) kept, the app's own keys from before.
        var manifest = SpaceStore.manifest(at: folder) ?? old ?? SpaceManifest(id: id, name: title ?? "Space")
        manifest.id = id
        manifest.name = String(manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SpaceLimits.name))
        if manifest.name.isEmpty || (rawManifest == nil && old == nil) { manifest.name = String((title ?? old?.name ?? "Space").prefix(SpaceLimits.name)) }
        if !SpaceManifest.colors.contains(manifest.color) { manifest.color = old?.color ?? "blue" }
        if manifest.icon.range(of: #"^[a-z0-9]+(\.[a-z0-9]+)*$"#, options: .regularExpression) == nil || manifest.icon.count > 60 { manifest.icon = old?.icon ?? "square.grid.2x2" }
        if manifest.schedule?.valid == false { manifest.schedule = old?.schedule }
        if let old {
            manifest.version = old.version; manifest.createdAt = old.createdAt; manifest.originChat = old.originChat
            manifest.template = old.template; manifest.order = old.order; manifest.worker = old.worker
            manifest.lock = old.lock ?? manifest.lock   // a lock is never taken off by an edit (adding one only narrows)
        } else {
            manifest.version = 1; manifest.createdAt = Date(); manifest.originChat = nil; manifest.template = nil; manifest.order = order
        }

        // Very big picture files are made smaller before the Space is checked against its 1 GB.
        let html = SpaceAssets.extract(SpaceStore.html(folder), into: folder)
        for name in SpaceAssets.names(in: html) {
            let file = folder.appendingPathComponent(SpaceAssets.folder).appendingPathComponent(name)
            guard let shrink, let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > SpaceAssets.shrinkFrom,
                  let data = try? Data(contentsOf: file), ["image/png", "image/jpeg", "image/webp"].contains(SpaceAssets.mime(data) ?? ""),
                  let small = shrink(file), small.count < size else { continue }
            try? SpaceStore.write(small, to: file)
        }
        let problem = html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L("app.html이 비어 있어요", "app.html is empty")
            : SpaceCheck.problem(html) ?? (html != known ? SpaceAssets.overLimit(html, folder: folder) : nil)

        // The data: one JSON object within 10 MB, else what was there before comes back.
        let stateFile = folder.appendingPathComponent("state.json")
        let moved = known == nil || stateMoved(id)
        var stateProblem: String?
        if moved, fm.fileExists(atPath: stateFile.path) || known != nil {
            let data = try? Data(contentsOf: stateFile)
            if data == nil || data!.count > SpaceLimits.state || !((try? JSONSerialization.jsonObject(with: data!)) is [String: Any]) {
                stateProblem = L("state.json이 10MB 안의 JSON 객체가 아니어서 전의 데이터로 되돌렸어요", "state.json was not a JSON object within 10 MB, so the data before came back")
                if let data { try? SpaceStore.write(data, to: folder.appendingPathComponent("state.broken.json")) }
                try? SpaceStore.write(known == nil ? Data("{}".utf8) : SpaceStore.state(kept), to: stateFile)
            }
        }

        guard known != nil else {
            if let problem {
                // A new Space that fails: set aside (hidden) with the reason, so it can be fixed and moved back.
                try? fm.createDirectory(at: rejected, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try? fm.removeItem(at: rejected.appendingPathComponent(id))
                try? fm.moveItem(at: folder, to: rejected.appendingPathComponent(id))
                return SpaceSyncNote(space: id, name: manifest.name, kind: "set-aside", reason: problem + " (" + rejected.appendingPathComponent(id).path + ")")
            }
            if !fm.fileExists(atPath: stateFile.path) { try? SpaceStore.write(Data("{}".utf8), to: stateFile) }
            if html != SpaceStore.html(folder) { try? SpaceStore.write(Data(html.utf8), to: folder.appendingPathComponent("app.html")) }
            try? SpaceStore.write(SpaceStore.encode(manifest), to: folder.appendingPathComponent("manifest.json"))
            order += 1
            settle(id)
            return SpaceSyncNote(space: id, name: manifest.name, kind: "added", version: 1)
        }

        var note: SpaceSyncNote?
        let pageChanged = html != known && problem == nil
        if html != known, let problem {
            try? SpaceStore.write(Data(known!.utf8), to: folder.appendingPathComponent("app.html"))
            note = SpaceSyncNote(space: id, name: manifest.name, kind: "refused", reason: problem)
        }
        let dataChanged = moved && stateProblem == nil
        if moved { reshaped.append(id) }
        if pageChanged || dataChanged {
            // The page and data before go to versions/<version>, as for a change made in the app.
            let saved = folder.appendingPathComponent("versions").appendingPathComponent(String(manifest.version))
            try? fm.removeItem(at: saved)
            try? SpaceStore.write(Data(known!.utf8), to: saved.appendingPathComponent("app.html"))
            try? SpaceStore.write(dataChanged ? SpaceStore.state(kept) : SpaceStore.state(folder), to: saved.appendingPathComponent("state.json"))
            try? SpaceStore.write(SpaceStore.encode(SpaceVersion(version: manifest.version, at: Date(), note: L("채팅에서 직접 고침", "Edited from a chat"), migrated: dataChanged)),
                                  to: saved.appendingPathComponent("info.json"))
            if let old { try? SpaceStore.write(SpaceStore.encode(old), to: saved.appendingPathComponent("manifest.json")) }
            if pageChanged, html != SpaceStore.html(folder) { try? SpaceStore.write(Data(html.utf8), to: folder.appendingPathComponent("app.html")) }
            manifest.version += 1; manifest.updatedAt = Date()
            SpaceStore.trimVersions(id)
            note = SpaceSyncNote(space: id, name: manifest.name, kind: note == nil ? "changed" : "refused", reason: note?.reason, version: manifest.version)
        }
        if let stateProblem { note = SpaceSyncNote(space: id, name: manifest.name, kind: "refused", reason: [note?.reason, stateProblem].compactMap { $0 }.joined(separator: " · "), version: note?.version) }
        let lookChanged = old.map { $0.name != manifest.name || $0.icon != manifest.icon || $0.color != manifest.color } ?? false
        if (try? SpaceStore.encode(manifest)) != rawManifest { try? SpaceStore.write(SpaceStore.encode(manifest), to: folder.appendingPathComponent("manifest.json")) }
        if note == nil && lookChanged { note = SpaceSyncNote(space: id, name: manifest.name, kind: "changed", version: manifest.version) }
        settle(id)
        return note
    }

    // Painted pictures through a block (a ChatGPT account draws them; the user previews and applies the result).
    public static let pictureBlockRule = """
        [Space pictures through a block] Only for painted pictures (illustration, character, background, art), add to your reply,
        hidden from the user: <space-build for="its id"> to change a Space (or <space-build> with <space-manifest>{"name","icon","color"}
        </space-manifest> for a new one) holding <space-html> with the whole page, where space-image:1, space-image:2 … stand for the
        pictures to draw (an <img> src or CSS url()), and <space-picture n="1">what to draw: subject, style, colors, aspect ratio
        </space-picture> for each, at most \(SpacePictures.perAnswer). To redraw a picture of the Space, use <space-picture n="1"
        from="assets/name.png">how to change it</space-picture> and write space-image:1 where it was: the drawer works from that
        picture; say in words what stays. Keep the other assets/ references as they are. Do not also edit the files for that change.
        """

    // The rule a chat's AI gets with the Spaces folder (`spaces`: every Space now, for its folder name).
    public static func rule(root: String, spaces: [SpaceManifest], draws: Bool) -> String {
        """
        [Spaces folder] \(root)
        The user's Spaces live here: small apps this app runs (sidebar → Spaces). When the user asks, change a Space or add a
        new one by editing these files directly; the user does not need to open the Space or apply anything.
        - One folder per Space, named by its id (letters, digits, hyphens): app.html (the page; rules below), manifest.json
          ({"name", "icon": SF Symbol name, "color": blue|purple|pink|red|orange|yellow|green|teal|gray}; leave its other keys),
          state.json (the user's data: one JSON object, at most 10 MB) and assets/ (picture files).
        - Change: edit app.html, and manifest.json for its name, icon or color. Keep the data keys the page reads. Edit state.json
          only when the user asks to change their data or the page needs the data in another shape, and keep every value.
        - New: make a new folder (an English id such as coffee-tracker) with app.html and manifest.json, and state.json for first data.
        - Pictures: put files in the Space's assets/ and write assets/name.png in the page (src, CSS url() or a JS string); file
          names of letters, digits, . _ -. The app loads them from the files (at most 1 GB for a Space with its files).
        - Never touch versions/, refine.json or hidden files; delete a Space only when asked.
        - After your answer the app checks each changed page. A page that breaks the rules is put back (a new Space is set aside
          in .rejected/), the user sees why; a good change becomes a new version the user can undo. Say in a line what you changed.
        \(draws ? "- A painted picture you cannot make yourself: use a <space-build for=\"id\"> block with <space-picture> (below) instead of editing the files; the user previews and applies it."
                : "- Painted pictures: no ChatGPT account can draw here, so draw with inline SVG or CSS.")
        [Space page rules]
        \(SpaceBuilder.pageRule)
        [Spaces now: name — folder]
        \(spaces.isEmpty ? "(none yet)" : spaces.map { "\($0.name) — \($0.id)" }.joined(separator: "\n"))
        """
    }
}

// A Space as one HTML file that runs in any browser, apart from this app: its pictures inside, and a stand-in for
// window.space that keeps the data in that browser (localStorage), starting from the data it has now. A Space with
// more files than `oneFile` goes out as a folder instead (index.html beside a copy of assets/): a browser chokes on a
// page of hundreds of MB of data: URLs.
public enum SpaceExport {
    static let oneFile = 50_000_000

    public static func fitsOneFile(_ id: String) -> Bool {
        let folder = SpaceStore.folder(id)
        return SpaceStore.html(folder).utf8.count + SpaceAssets.bytes(folder) * 4 / 3 <= oneFile
    }

    // `target`: a new folder (it must not be there yet).
    public static func folder(_ id: String, to target: URL) throws {
        let fm = FileManager.default, folder = SpaceStore.folder(id)
        guard let manifest = SpaceStore.manifest(at: folder) else { throw SpaceBad(reason: L("Space를 찾지 못했어요", "Space not found")) }
        let html = SpaceStore.html(folder)
        guard !html.isEmpty else { throw SpaceBad(reason: L("app.html이 비어 있어요", "app.html is empty")) }
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        let assets = folder.appendingPathComponent(SpaceAssets.folder)
        if fm.fileExists(atPath: assets.path) { try fm.copyItem(at: assets, to: target.appendingPathComponent(SpaceAssets.folder)) }
        try Data(document(page: html, manifest: manifest, state: SpaceStore.state(folder)).utf8).write(to: target.appendingPathComponent("index.html"), options: .atomic)
    }

    public static func document(_ id: String) -> String? {
        let folder = SpaceStore.folder(id)
        guard let manifest = SpaceStore.manifest(at: folder) else { return nil }
        let page = SpaceStore.page(folder)
        guard !page.isEmpty else { return nil }
        return document(page: page, manifest: manifest, state: SpaceStore.state(folder))
    }

    static func document(page: String, manifest: SpaceManifest, state: Data) -> String {
        func json(_ value: Any) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data("null".utf8)
            return (String(data: data, encoding: .utf8) ?? "null").replacingOccurrences(of: "<", with: "\\u003c")
        }
        let seed = (String(data: state, encoding: .utf8) ?? "{}").replacingOccurrences(of: "<", with: "\\u003c")
        let title = manifest.name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        var body = Substring(page)
        while let first = body.first, first.isWhitespace || first == "\u{FEFF}" { body = body.dropFirst() }
        if body.lowercased().hasPrefix("<!doctype"), let end = body.firstIndex(of: ">") { body = body[body.index(after: end)...] }
        return """
            <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><meta name="color-scheme" content="light dark">
            <title>\(title)</title>
            <script>
            (() => {
              const key = 'space:' + \(json(manifest.id)), seed = \(seed);
              let data;
              try { data = JSON.parse(localStorage.getItem(key)); } catch (e) {}
              if (!data || typeof data !== 'object' || Array.isArray(data)) data = seed;
              const subs = new Set();
              const copy = v => v === undefined ? undefined : JSON.parse(JSON.stringify(v));
              const save = () => { try { localStorage.setItem(key, JSON.stringify(data)); return true; } catch (e) { return false; } };
              const tell = (k, v) => { for (const f of subs) { try { f(k, copy(v)); } catch (e) {} } };
              save();
              window.addEventListener('storage', e => {
                if (e.key !== key || !e.newValue) return;
                let next; try { next = JSON.parse(e.newValue); } catch (x) { return; }
                for (const k of new Set([...Object.keys(data), ...Object.keys(next)])) if (JSON.stringify(data[k]) !== JSON.stringify(next[k])) { data[k] = next[k]; if (next[k] === undefined) delete data[k]; tell(k, next[k]); }
              });
              const toast = text => {
                const n = document.createElement('div');
                n.textContent = String(text).slice(0, 300);
                n.style.cssText = 'position:fixed;left:50%;bottom:24px;transform:translateX(-50%);padding:8px 14px;border-radius:10px;background:rgba(40,40,40,.92);color:#fff;font:13px system-ui;z-index:2147483647';
                (document.body || document.documentElement).appendChild(n);
                setTimeout(() => n.remove(), 3000);
              };
              const dark = window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches;
              const space = Object.freeze({
                state: Object.freeze({
                  get: k => Object.prototype.hasOwnProperty.call(data, String(k)) ? copy(data[String(k)]) : undefined,
                  keys: () => Object.keys(data),
                  set: (k, value) => {
                    k = String(k);
                    let json; try { json = value === undefined ? null : JSON.stringify(value); } catch (e) { return Promise.resolve(false); }
                    if (json === undefined) return Promise.resolve(false);
                    const had = Object.prototype.hasOwnProperty.call(data, k), old = data[k];
                    if (json === null) delete data[k]; else data[k] = JSON.parse(json);
                    if (!save()) { if (had) data[k] = old; else delete data[k]; return Promise.resolve(false); }
                    tell(k, data[k]);
                    return Promise.resolve(true);
                  },
                  subscribe: f => { if (typeof f !== 'function') return () => {}; subs.add(f); return () => { subs.delete(f); }; }
                }),
                theme: Object.freeze({dark: dark, accent: \(json(manifest.hex)), color: \(json(manifest.color))}),
                open: target => {
                  const url = target && typeof target.url === 'string' ? target.url : '';
                  if (/^https?:\\/\\//i.test(url)) { window.open(url, '_blank', 'noopener'); return Promise.resolve(true); }
                  toast(\(json(L("이 링크는 AI Illuminati 안에서만 열려요", "This link opens only inside AI Illuminati"))));
                  return Promise.resolve(false);
                },
                notify: text => toast(text)
              });
              Object.defineProperty(window, 'space', {value: space, writable: false, configurable: false});
            })();
            </script>
            """ + body
    }
}
