import Cocoa
import PDFKit
import ImageIO
import UniformTypeIdentifiers

struct MaterialUnit: Codable, Identifiable {
    var id: String
    var locator: String
    var text: String
    var images: [String] = []
}

private final class OfficeXML: NSObject, XMLParserDelegate {
    var text = "", capture = false
    var references: [String] = []
    var relations: [String: String] = [:]
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        if ["t", "v"].contains(local) { capture = true }
        if local == "sldId", let id = attributes["r:id"] { references.append(id) }
        if local == "Relationship", let id = attributes["Id"], let target = attributes["Target"], attributes["TargetMode"] != "External" { relations[id] = target }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if capture { text += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        if ["t", "v"].contains(local) { capture = false; text += " " }
        if ["p", "tr", "row"].contains(local) { text += "\n" }
    }
    static func parse(_ data: Data) throws -> OfficeXML {
        let result = OfficeXML(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = result
        guard parser.parse() else { throw MaterialReader.error("Office XML을 읽지 못했습니다.") }
        return result
    }
}

enum MaterialReader {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "bmp", "gif", "webp"]
    static let extensions = RoomDocuments.extensions.union(["docx", "pptx"]).union(imageExtensions)
    static func error(_ text: String) -> NSError { NSError(domain: "Materials", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    static func chunks(_ text: String, size: Int = 12000) -> [String] {
        var result: [String] = [], start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end])); start = end
        }
        return result.isEmpty ? [""] : result
    }
    static func zip(_ file: URL, _ entry: String? = nil) throws -> Data {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = entry.map { ["-p", file.path, $0] } ?? ["-Z1", file.path]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run()
        // The output is drained while unzip runs. Never extract arbitrary archive paths.
        var data = Data()
        while true {
            let block = out.fileHandleForReading.readData(ofLength: 65536)
            if block.isEmpty { break }
            guard data.count + block.count <= 128 * 1024 * 1024 else {
                DebateCancellation.end(p); try? out.fileHandleForReading.close(); p.waitUntilExit()
                throw error("Office 내부의 단일 항목이 128 MB를 넘어 처리를 중단했습니다. 파일을 나누어주세요.")
            }
            data.append(block)
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw error("Office 압축 항목을 읽지 못했습니다.") }
        return data
    }
    static func thumbnail(_ url: URL, to dest: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1800] as CFDictionary),
              let target = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw error("이미지 변환 실패: " + url.lastPathComponent) }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { throw error("이미지 저장 실패") }
    }
    static func read(_ source: URL, room: UUID) throws -> RoomDocument {
        let info = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else { throw error("일반 파일만 지원합니다: " + source.lastPathComponent) }
        guard (info.fileSize ?? Int.max) <= 1024 * 1024 * 1024 else { throw error("1 GB를 넘는 단일 파일은 나누어 넣어주세요: " + source.lastPathComponent) }
        let ext = source.pathExtension.lowercased()
        guard extensions.contains(ext) else { throw error("지원하지 않는 형식: " + source.lastPathComponent) }
        var document = RoomDocument(name: source.lastPathComponent, text: "")
        let folder = RoomDocuments.directory(room).appendingPathComponent(document.id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let file = folder.appendingPathComponent("original." + ext)
            try FileManager.default.copyItem(at: source, to: file)
            var units: [MaterialUnit] = []
            func append(_ text: String, _ locator: String, images: [String] = []) {
                for (index, part) in chunks(text).enumerated() {
                    units.append(MaterialUnit(id: "\(document.id.uuidString):\(units.count + 1)", locator: locator + (text.count > 12000 ? " part \(index + 1)" : ""), text: part, images: index == 0 ? images : []))
                }
            }
            if imageExtensions.contains(ext) {
                try thumbnail(file, to: folder.appendingPathComponent("figure.png"))
                append("User-provided photograph/figure. Read visually; do not infer unmeasured values.", "image", images: [document.id.uuidString + "/figure.png"])
            } else if ext == "pdf" {
                guard let pdf = PDFDocument(url: file), !pdf.isLocked else { throw error("암호화되었거나 손상된 PDF: " + source.lastPathComponent) }
                for i in 0..<pdf.pageCount {
                    guard let page = pdf.page(at: i) else { continue }
                    let image = page.thumbnail(of: NSSize(width: 1600, height: 1600), for: .mediaBox)
                    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { throw error("PDF 페이지 변환 실패") }
                    let name = "page-\(i + 1).png"
                    try data.write(to: folder.appendingPathComponent(name))
                    append(page.string ?? "[Scanned page: read image]", "p.\(i + 1)", images: [document.id.uuidString + "/" + name])
                }
            } else if ext == "docx" || ext == "pptx" {
                let entries = String(decoding: try zip(file), as: UTF8.self).split(separator: "\n").map(String.init)
                if ext == "docx" {
                    for entry in ["word/document.xml", "word/footnotes.xml", "word/endnotes.xml"] where entries.contains(entry) {
                        append(try OfficeXML.parse(zip(file, entry)).text, entry)
                    }
                } else {
                    let presentation = try OfficeXML.parse(zip(file, "ppt/presentation.xml"))
                    let relationships = try OfficeXML.parse(zip(file, "ppt/_rels/presentation.xml.rels"))
                    for (index, ref) in presentation.references.enumerated() {
                        guard let target = relationships.relations[ref] else { throw error("슬라이드 순서 정보를 읽지 못했습니다.") }
                        let entry = target.hasPrefix("/") ? String(target.dropFirst()) : "ppt/" + target
                        var text = try OfficeXML.parse(zip(file, entry)).text
                        let rel = "ppt/slides/_rels/" + URL(fileURLWithPath: entry).lastPathComponent + ".rels"
                        if entries.contains(rel) {
                            let links = try OfficeXML.parse(zip(file, rel))
                            for value in links.relations.values where value.contains("notesSlides/") {
                                let note = URL(fileURLWithPath: "/ppt/slides").appendingPathComponent(value).standardizedFileURL.path.dropFirst()
                                if entries.contains(String(note)) { text += "\n[Speaker notes]\n" + (try OfficeXML.parse(zip(file, String(note))).text) }
                            }
                        }
                        append(text, "slide \(index + 1)")
                    }
                }
                let prefix = ext == "docx" ? "word/" : "ppt/"
                for entry in entries.sorted() where entry.hasPrefix(prefix + "media/") && imageExtensions.contains(URL(fileURLWithPath: entry).pathExtension.lowercased()) {
                    let raw = folder.appendingPathComponent("embedded." + URL(fileURLWithPath: entry).pathExtension)
                    try zip(file, entry).write(to: raw)
                    let name = "embedded-\(units.count + 1).png"
                    try thumbnail(raw, to: folder.appendingPathComponent(name))
                    try FileManager.default.removeItem(at: raw)
                    append("Embedded image. Exact placement/layout has not been rendered; cite the media identifier, not a guessed slide/page.", entry, images: [document.id.uuidString + "/" + name])
                }
                for entry in entries.sorted() where entry.hasPrefix(prefix + "charts/") && entry.hasSuffix(".xml") {
                    append(try OfficeXML.parse(zip(file, entry)).text, entry + " (chart cached values; layout unavailable)")
                }
                document.notice = "Office: 본문·표 텍스트/노트·삽입 이미지·차트 캐시 추출. 원래 배치·수식·도형의 완전한 렌더링은 아님."
            } else { append(try String(contentsOf: file, encoding: .utf8), "text") }
            guard !units.isEmpty else { throw error("읽을 수 있는 내용이 없습니다: " + source.lastPathComponent) }
            document.units = units
            for url in (try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            return document
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
}
