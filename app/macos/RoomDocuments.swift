import Cocoa
import PDFKit
import AILocalization
import AIWorkspace
import AIProjects

struct RoomDocument: Codable, Identifiable {
    var id = UUID()
    var name: String
    var text: String
    var units: [MaterialUnit]?
    var notice: String?
}

enum RoomDocuments {
    static func directory(_ id: UUID) -> URL {
        URL(fileURLWithPath: ChatStore.dir).appendingPathComponent("\(id.uuidString).documents")
    }
    // Dropped files that only exist in a temporary folder (promised by Mail and others) are copied into
    // the chat's folder, removed with the chat, so they can be linked. Pictures are read at once and stay put.
    static func keepDropped(_ urls: [URL], room: UUID) throws -> [URL] {
        try urls.map { url in
            if (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true { return url }
            let folder = directory(room).appendingPathComponent("Dropped " + String(UUID().uuidString.prefix(8)))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let copy = folder.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        }
    }
    static let extensions: Set<String> = ["pdf", "txt", "md", "csv", "tsv", "tex", "json", "py", "m", "swift"]
    static func read(_ url: URL) throws -> RoomDocument {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true,
              (info.fileSize ?? Int.max) <= 10 * 1024 * 1024,
              extensions.contains(url.pathExtension.lowercased()) else {
            throw NSError(domain: "Materials", code: 1, userInfo: [NSLocalizedDescriptionKey: "지원하지 않거나 10 MB를 넘는 파일: \(url.lastPathComponent)"])
        }
        let text: String
        if url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: url) {
            text = (0..<pdf.pageCount).map { "[p.\($0 + 1)]\n" + (pdf.page(at: $0)?.string ?? "") }.joined(separator: "\n")
            guard text.filter({ !$0.isWhitespace }).count > pdf.pageCount * 8 else {
                throw NSError(domain: "Materials", code: 2, userInfo: [NSLocalizedDescriptionKey: "텍스트 없는 PDF입니다. 필요한 페이지를 이미지로 첨부하세요: \(url.lastPathComponent)"])
            }
        } else { text = try String(contentsOf: url, encoding: .utf8) }
        return RoomDocument(name: url.lastPathComponent, text: text)
    }
}

extension Discussion {
    func restartRoomSessions(disconnect: Bool = false) {
        do {
            try nativeSessions.reset(currentID)
            if disconnect { change(currentID, save: true) { $0.documents = nil; $0.workspace = nil } }
            sessionNote = L("다음 질문에서 자료와 대화로 새 세션을 시작합니다.", "Next question starts fresh sessions from current materials and chat.")
        } catch { attachmentError = error.localizedDescription }
    }

    func chooseMaterials(folder: Bool) {
        guard !running && !importingMaterials else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder; panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = !folder
        panel.message = L("경로와 파일 목록만 연결합니다. AI가 필요할 때 파일을 직접 읽습니다.", "Link paths and file names only. AIs open needed files on demand.")
        guard panel.runModal() == .OK else { return }
        do {
            let roots = try panel.urls.map { url -> WorkspaceRoot in
                let path = url.resolvingSymlinksInPath()
                let info = try path.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                guard info.isDirectory == true || info.isRegularFile == true else { throw MaterialReader.error("일반 파일이나 폴더를 선택하세요.") }
                return WorkspaceRoot(path: path.path, directory: info.isDirectory == true)
            }
            try nativeSessions.reset(currentID)
            // One "Link folder": a top-level Git folder with a remote becomes project work (Git tools, push);
            // any other folder gets the same full access with the Undo backup. Both are full auto unless turned off.
            let project = folder && configuration.mode == 0 ? roots.first.flatMap { try? ProjectProcess.inspect($0.path) } : nil
            change(currentID, save: true) { conversation in
                var binding = WorkspaceBinding(roots: project.map { [WorkspaceRoot(path: $0.root, directory: true, writable: true)] } ?? roots)
                binding.project = project
                conversation.workspace = binding
            }
            sessionNote = folder
                ? (project != nil ? L("Git 프로젝트 연결됨 · 완전 자동 (stable 배포만 허용 카드)", "Git project linked · full auto (only stable publishing asks)")
                                  : L("폴더 연결됨 · 완전 자동 (답할 때마다 백업, Undo 가능)", "Folder linked · full auto (backed up before each answer, Undo available)"))
                : L("경로 연결됨 · 보기. 원문은 요청할 때만 읽습니다.", "Linked · View. Contents are read only on demand.")
            attachmentError = nil
        } catch { attachmentError = error.localizedDescription }
    }

    // One "Attach file": pictures go into the question (the AI sees them); other files are linked by path
    // (read only, opened on demand) next to any folder already linked to this chat.
    func chooseFiles() {
        guard !running && !importingMaterials else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.message = L("사진은 질문에 바로 붙이고, 다른 파일은 AI가 필요할 때 열어 봐요.", "Pictures go into the question; other files are opened by the AI when needed.")
        guard panel.runModal() == .OK else { return }
        attachFiles(panel.urls)
    }

    // Shared by Attach file, drag and drop and paste. A PDF is not a picture: rendering it as one kept
    // only its first page, so it is linked like any other file and the AI reads all of it.
    func attachFiles(_ urls: [URL]) {
        guard !running && !importingMaterials else { return }
        let isImage = { (url: URL) in (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true }
        for url in urls where isImage(url) { importImageFile(url) }
        let others = urls.filter { !isImage($0) }
        guard !others.isEmpty else { return }
        do {
            let roots = try others.map { url -> WorkspaceRoot in
                let path = url.resolvingSymlinksInPath()
                guard (try path.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw MaterialReader.error("일반 파일을 선택하세요.") }
                return WorkspaceRoot(path: path.path, directory: false)
            }
            try nativeSessions.reset(currentID)
            change(currentID, save: true) { conversation in
                var binding = conversation.workspace ?? WorkspaceBinding(roots: [])
                for root in roots where !binding.roots.contains(where: { $0.path == root.path }) { binding.roots.append(root) }
                conversation.workspace = binding
            }
            sessionNote = L("파일 연결됨 · 필요할 때 AI가 열어 봐요.", "Files linked · the AI opens them when needed.")
            attachmentError = nil
        } catch { attachmentError = error.localizedDescription }
    }
}
