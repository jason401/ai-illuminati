import Cocoa
import PDFKit
import ImageIO
import UniformTypeIdentifiers
let args = CommandLine.arguments
if args.count < 5 { exit(2) }
let url = URL(fileURLWithPath: args[1])
if url.pathExtension.lowercased() != "pdf" {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways:true, kCGImageSourceCreateThumbnailWithTransform:true, kCGImageSourceThumbnailMaxPixelSize:1600] as CFDictionary) else { exit(4) }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let png = bitmap.representation(using: .png, properties: [:]),
          let data = try? JSONSerialization.data(withJSONObject: ["page_count":1,"pages":[["page":1,"text":"Image: " + url.lastPathComponent,"image":png.base64EncodedString()]]]) else { exit(4) }
    FileHandle.standardOutput.write(data); exit(0)
}
guard let pdf = PDFDocument(url: url), !pdf.isLocked else { exit(3) }
let first = max(1, Int(args[2]) ?? 1), last = min(pdf.pageCount, Int(args[3]) ?? first)
var pages: [[String: Any]] = []
if first <= last {
    for i in first...last {
        guard let page = pdf.page(at: i - 1) else { continue }
        var entry: [String: Any] = ["page": i, "text": page.string ?? ""]
        if args[4] == "images" {
            let preview = page.thumbnail(of: NSSize(width: 1600, height: 1600), for: .mediaBox)
            if let tiff = preview.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) { entry["image"] = png.base64EncodedString() }
        }
        pages.append(entry)
    }
}
let result: [String: Any] = ["page_count": pdf.pageCount, "pages": pages]
if let data = try? JSONSerialization.data(withJSONObject: result) { FileHandle.standardOutput.write(data) }
