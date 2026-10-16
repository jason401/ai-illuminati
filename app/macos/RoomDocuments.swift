import Cocoa
import PDFKit

struct RoomDocument: Codable, Identifiable {
    var id = UUID()
    var name: String
    var text: String
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
        panel.message = L("자료 사본을 이 방에 저장합니다. PDF는 텍스트만 읽으며, 그림은 이미지로 따로 첨부하세요. 최대 20개·총 12만 자.", "Save material snapshots in this chat. PDFs provide text only; attach figures as images. Up to 20 files / 120,000 characters.")
        guard panel.runModal() == .OK else { return }
        do {
            var urls = panel.urls
            if folder, let root = urls.first {
                urls = []
                if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                    for case let url as URL in enumerator {
                        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { enumerator.skipDescendants(); continue }
                        if RoomDocuments.extensions.contains(url.pathExtension.lowercased()) { urls.append(url) }
                        if urls.count > 20 { break }
                    }
                }
            }
            guard !urls.isEmpty, urls.count + (current.documents?.count ?? 0) <= 20 else {
                throw NSError(domain: "Materials", code: 3, userInfo: [NSLocalizedDescriptionKey: "PDF·텍스트 파일을 1~20개 선택하세요. 이미지는 입력창의 +를 이용하세요."])
            }
            let added = try urls.map(RoomDocuments.read)
            let all = (current.documents ?? []) + added
            guard all.reduce(0, { $0 + $1.text.count }) <= 120_000 else {
                throw NSError(domain: "Materials", code: 4, userInfo: [NSLocalizedDescriptionKey: "자료가 총 12만 자를 넘어요. 필요한 파일만 선택하세요."])
            }
            let dir = RoomDocuments.directory(currentID)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (url, doc) in zip(urls, added) {
                let dest = dir.appendingPathComponent(doc.id.uuidString + "." + url.pathExtension)
                try FileManager.default.copyItem(at: url, to: dest)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
            }
            try nativeSessions.reset(currentID)
            change(currentID, save: true) { $0.documents = all }
            sessionNote = L("자료 사본 저장됨. 다음 질문부터 참여 AI에게 전달돼요.", "Snapshots saved. Participating AIs receive them with your next question.")
            attachmentError = nil
        } catch { attachmentError = error.localizedDescription }
    }
}
