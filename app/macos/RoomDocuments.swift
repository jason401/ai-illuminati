import Cocoa
import PDFKit

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
            change(currentID, save: true) { $0.workspace = WorkspaceBinding(roots: roots) }
            sessionNote = L("경로 연결됨 · 보기. 원문은 요청할 때만 읽습니다.", "Linked · View. Contents are read only on demand.")
            attachmentError = nil
        } catch { attachmentError = error.localizedDescription }
    }
}
