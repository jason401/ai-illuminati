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
            if disconnect { change(currentID, save: true) { $0.documents = nil } }
            sessionNote = L("다음 질문에서 자료와 대화로 새 세션을 시작합니다.", "Next question starts fresh sessions from current materials and chat.")
        } catch { attachmentError = error.localizedDescription }
    }

    func chooseMaterials(folder: Bool) {
        guard !running else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder
        panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = !folder
        panel.message = L("원고·슬라이드·사진·PDF·텍스트를 사본으로 등록합니다. 큰 자료는 나누어 읽습니다. 원본은 수정하지 않습니다.", "Import document, slide, photo, PDF and text snapshots. Large materials are read in parts. Originals stay unchanged.")
        guard panel.runModal() == .OK else { return }
        let room = currentID
        var urls = panel.urls
        if folder, let root = urls.first {
            urls = []
            if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let url as URL in enumerator {
                    if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { enumerator.skipDescendants(); continue }
                    if MaterialReader.extensions.contains(url.pathExtension.lowercased()) { urls.append(url) }
                }
            }
        }
        guard !urls.isEmpty else { attachmentError = L("지원되는 자료가 없습니다.", "No supported materials found."); return }
        importingMaterials = true
        let files = urls
        DispatchQueue.global(qos: .userInitiated).async {
            var added: [RoomDocument] = [], failures: [String] = []
            for url in files {
                do { added.append(try MaterialReader.read(url, room: room)) }
                catch { failures.append(url.lastPathComponent + ": " + error.localizedDescription) }
            }
            DispatchQueue.main.async {
                self.importingMaterials = false
                do {
                    try self.nativeSessions.reset(room)
                    self.change(room, save: true) { $0.documents = ($0.documents ?? []) + added }
                    self.sessionNote = L("자료 \(added.count)개 등록. 협업 모드에서 분담해 읽고 결과물을 만듭니다.", "Imported \(added.count) materials. Collaboration reads them in parts and produces deliverables.")
                    self.attachmentError = failures.isEmpty ? nil : failures.joined(separator: "\n")
                } catch { self.attachmentError = error.localizedDescription }
            }
        }
    }
}
