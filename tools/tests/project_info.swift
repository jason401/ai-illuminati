import Foundation

// Project info (ProjectInfo.swift): the folders, files and links kept for a whole project, the file that is never
// overwritten when it cannot be read, and every chat of the project reading them read only.
func testProjectInfo() {
    let base = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("project-info-tests")
    try? FileManager.default.removeItem(at: base)
    try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let docs = base.appendingPathComponent("docs"), notes = base.appendingPathComponent("notes.txt"), alias = base.appendingPathComponent("docs-alias")
    try! FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try! "notes".write(to: notes, atomically: true, encoding: .utf8)
    try! FileManager.default.createSymbolicLink(at: alias, withDestinationURL: docs)
    let file = base.appendingPathComponent("project-info.json")
    let key = "/tmp/info-repo/.git"

    let store = ProjectInfoStore(url: file)
    let added = try! store.addFolders([docs, notes, alias, base.appendingPathComponent("gone")], to: key)
    let docsPath = docs.resolvingSymlinksInPath().path, notesPath = notes.resolvingSymlinksInPath().path
    expect(added == 2 && store.info(key).folders.map(\.path) == [docsPath, notesPath], "folders and files added once, a symlink as what it points at, a missing path skipped: \(store.info(key).folders)")
    expect(store.info(key).folders.map(\.directory) == [true, false], "folder or file kept")
    let link = try! store.addLink(title: "Design\ndoc", url: " example.com/spec ", to: key)
    expect(link.title == "Designdoc" && link.url == "https://example.com/spec", "a link is one line, https added: \(link)")
    for bad in ["javascript:alert(1)", "file:///etc/passwd", "ftp://x.org", "not a link"] {
        expect((try? store.addLink(title: "", url: bad, to: key)) == nil, "refused link: \(bad)")
    }
    expect(try! store.addLink(title: "", url: "https://example.com/spec", to: key).title == "example.com" && store.info(key).links.count == 1, "the same address is kept once; no title = the host")
    let reread = ProjectInfoStore(url: file)
    expect(reread.current == store.current, "saved and read back")
    try! store.removeFolder(notesPath, from: key)
    try! store.removeLink(link.id, from: key)
    expect(store.info(key).folders.map(\.path) == [docsPath] && store.info(key).links.isEmpty, "unlinked")
    expect(FileManager.default.fileExists(atPath: notes.path), "unlinking leaves the file")

    // A file it cannot read (broken, or from a newer app) is left as it is, and changes are refused.
    for raw in ["{ broken", #"{"version": 99, "projects": {}}"#,
                #"{"version": 1, "projects": {"k": {"folders": [{"path": "/x", "directory": "yes"}], "links": []}}}"#,
                #"{"version": 1, "projects": {"k": {"folders": [], "links": [{"title": "a"}]}}}"#] {
        try! raw.write(to: file, atomically: true, encoding: .utf8)
        let held = ProjectInfoStore(url: file)
        expect(held.saveError != nil && (try? held.addLink(title: "", url: "https://a.org", to: key)) == nil, "unreadable file: changes refused (\(raw))")
        expect((try? String(contentsOf: file, encoding: .utf8)) == raw, "unreadable file left as it is")
    }
    // A file that is there but cannot be opened is held too, never started over empty.
    try! FileManager.default.removeItem(at: file)
    try! FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)   // a folder in its place: reading fails
    let unopened = ProjectInfoStore(url: file)
    expect(unopened.saveError != nil && (try? unopened.addLink(title: "", url: "https://a.org", to: key)) == nil, "a file that cannot be opened: changes refused")
    try! FileManager.default.removeItem(at: file)
    expect(ProjectInfoStore(url: file).saveError == nil, "no file yet: starts empty")
    let old = base.appendingPathComponent("old.json")
    try! #"{"projects": {"k": {"links": [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "title": "a", "url": "https://a.org"}]}}}"#.write(to: old, atomically: true, encoding: .utf8)
    let partial = ProjectInfoStore(url: old)
    expect(partial.saveError == nil && partial.info("k").links.count == 1 && partial.info("k").folders.isEmpty, "missing fields read as empty")

    // Git remotes on the web: never with a password, only web addresses.
    expect(ProjectInfoStore.webURL("git@github.com:jason/app.git")?.absoluteString == "https://github.com/jason/app", "ssh remote")
    expect(ProjectInfoStore.webURL("https://user:secret@github.com/jason/app.git")?.absoluteString == "https://github.com/jason/app", "credentials dropped")
    expect(ProjectInfoStore.webURL("ssh://git@github.com/jason/app.git")?.absoluteString == "https://github.com/jason/app", "ssh:// remote")
    expect(ProjectInfoStore.webURL("/Users/me/origin") == nil && ProjectInfoStore.webURL("file:///x") == nil, "local remotes have no web page")

    // Every chat of the project reads them at the time of the answer, read only; a path the chat itself links keeps its access.
    let saved = ProjectInfoStore.shared
    defer { ProjectInfoStore.shared = saved }
    ProjectInfoStore.shared = ProjectInfoStore(url: file)
    let repo = ProjectBinding(root: base.appendingPathComponent("repo").path, common: key, remote: "origin", remoteURL: "")
    let mine = base.appendingPathComponent("mine")
    try! FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
    try! ProjectInfoStore.shared.addFolders([docs, notes, mine], to: key)
    try! ProjectInfoStore.shared.addLink(title: "Spec", url: "https://example.com/spec", to: key)
    let m = AppModel(); m.sharedFolders = []
    let d = Discussion(model: m)
    var chat = Conversation(); chat.turns = [ChatTurn(question: "hi")]
    chat.workspace = WorkspaceBinding(roots: [WorkspaceRoot(path: repo.root, directory: true, writable: true), WorkspaceRoot(path: mine.path, directory: true)], project: repo)
    var other = Conversation(); other.turns = [ChatTurn(question: "hi")]
    d.conversations = [chat, other]
    try! FileManager.default.removeItem(at: notes)   // gone: listed on the tab, not given to the AI
    let binding = d.soloBinding(chat.id)
    let docsRoot = binding.roots.first { $0.path == docsPath }
    expect(docsRoot != nil && docsRoot?.writable != true, "a project folder is given to the chat, read only")
    expect(!binding.roots.contains { $0.path == notesPath }, "a missing project file is not given to the AI")
    expect(binding.roots.filter { $0.path == mine.path }.count == 1 && binding.roots.first { $0.path == mine.path }?.writable == true, "the chat's own link keeps its access, once")
    expect(!d.soloBinding(other.id).roots.contains { $0.path == docsPath }, "a chat outside the project does not get them")
    let told = Discussion.soloFolders(binding, shared: [], project: repo.root)
    expect(told.contains(docsPath + " (project folder, shared by every chat of this project — read only)"), "the AI is told what the folder is: \(told)")
    expect(told.contains("[Project links") && told.contains("- Spec: https://example.com/spec"), "and the project's links")
    print("PASS: project info (folders, files, links, unreadable file kept, read only in every chat of the project)")
}
