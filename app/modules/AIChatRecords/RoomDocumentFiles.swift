import Cocoa
import PDFKit
import AILocalization
import AIWorkspace

public enum RoomDocuments {
    public static func directory(_ id: UUID) -> URL {
        URL(fileURLWithPath: ChatPaths.dir).appendingPathComponent("\(id.uuidString).documents")
    }
    // Dropped files that only exist in a temporary folder (promised by Mail and others) are copied into
    // the chat's folder, removed with the chat, so they can be linked. Pictures are read at once and stay put.
    public static func keepDropped(_ urls: [URL], room: UUID) throws -> [URL] {
        try urls.map { url in
            if (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true { return url }
            let folder = directory(room).appendingPathComponent("Dropped " + String(UUID().uuidString.prefix(8)))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let copy = folder.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        }
    }
    public static let extensions: Set<String> = ["pdf", "txt", "md", "csv", "tsv", "tex", "json", "py", "m", "swift"]
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
