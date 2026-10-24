import Cocoa

// Pictures the AIs make during a chat.
// - ChatGPT (Codex) has an image generation tool; Codex saves each image in its account folder under
//   generated_images/<thread>/…png. New files there after a call started are that call's pictures.
// - Claude and Gemini draw by writing SVG in a ```svg code block (Gemini's own image tool fails or
//   finishes after the one-shot call ends). The app renders the SVG to PNG and puts a short
//   "[그림 N]" marker in the text instead of the code.
// Pictures are stored with the chat like attached photos (chats/<id>.assets, deleted with the chat)
// and are passed to every AI that speaks afterwards, so they can look at and critique them.
enum Pictures {
    // What each AI is told about making pictures.
    static func rule(for provider: Account.Provider) -> String {
        let how: String
        switch provider {
        case .codex:
            how = "Make it with your image generation tool (do not run other commands for it)."
        case .claude, .gemini:
            how = "Draw it as one SVG inside a ```svg code block (it is shown to the user as an image). Keep each SVG under 20 KB, give it a viewBox, and use simple shapes and text."
        }
        return """
        Pictures: only when the user asks for a picture, drawing, diagram, chart, logo or other visual, include one. \(how)
        Pictures by the user or other AIs are attached as images, in order (Image 1, Image 2, …); look at them before you comment on them.
        Never claim you made or saw a picture you did not.
        """
    }

    struct Harvest {
        var text: String
        var images: [ChatImage]
    }

    // Collects the pictures from one AI reply. `number` is the next picture number in this chat.
    static func harvest(_ text: String, account: Account, since: Date, conversationID: UUID, number: Int) -> Harvest {
        var result = Harvest(text: text, images: [])
        var next = number
        // SVG drawings in the text: each one is replaced by its marker, in place.
        var cleaned = "", cursor = text.startIndex
        for block in svgBlocks(in: text) {
            cleaned += text[cursor..<block.range.lowerBound]
            if let png = render(svg: block.svg),
               let image = try? ImageStore.importImage(png, name: "picture-\(next).png", conversationID: conversationID) {
                result.images.append(image)
                cleaned += L("[그림 \(next)]", "[Picture \(next)]")
                next += 1
            } else {
                cleaned += text[block.range]
            }
            cursor = block.range.upperBound
        }
        cleaned += text[cursor...]
        result.text = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // Image files Codex generated during this call.
        if account.provider == .codex {
            for url in newCodexImages(account, since: since) {
                guard let data = try? Data(contentsOf: url),
                      let image = try? ImageStore.importImage(data, name: "picture-\(next).png", conversationID: conversationID) else { continue }
                result.images.append(image)
                result.text += (result.text.hasSuffix("]") ? " " : "\n\n") + L("[그림 \(next)]", "[Picture \(next)]")
                next += 1
            }
        }
        return result
    }

    static func newCodexImages(_ account: Account, since: Date) -> [URL] {
        let folder = URL(fileURLWithPath: account.codexHome).appendingPathComponent("generated_images")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return [] }
        var found: [(URL, Date)] = []
        for case let url as URL in walker where ["png", "jpg", "jpeg", "webp"].contains(url.pathExtension.lowercased()) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true, let date = values?.contentModificationDate, date >= since.addingTimeInterval(-2) {
                found.append((url, date))
            }
        }
        return found.sorted { $0.1 < $1.1 }.map(\.0)
    }

    // ```svg … ``` blocks (also ```xml/```html holding an <svg>), or a bare <svg>…</svg>.
    static func svgBlocks(in text: String) -> [(range: Range<String.Index>, svg: String)] {
        var blocks: [(Range<String.Index>, String)] = []
        let fence = try! NSRegularExpression(pattern: "```[ \\t]*(svg|xml|html)?[^\\n]*\\n([\\s\\S]*?)```", options: [.caseInsensitive])
        let bare = try! NSRegularExpression(pattern: "<svg[\\s\\S]*?</svg>", options: [.caseInsensitive])
        let ns = text as NSString
        var covered: [NSRange] = []
        for match in fence.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let body = ns.substring(with: match.range(at: 2))
            guard let svgRange = body.range(of: "<svg[\\s\\S]*</svg>", options: [.regularExpression, .caseInsensitive]),
                  let range = Range(match.range, in: text) else { continue }
            blocks.append((range, String(body[svgRange])))
            covered.append(match.range)
        }
        for match in bare.matches(in: text, range: NSRange(location: 0, length: ns.length))
            where !covered.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
            if let range = Range(match.range, in: text) { blocks.append((range, String(text[range]))) }
        }
        return blocks.sorted { $0.0.lowerBound < $1.0.lowerBound }
    }

    // SVG → PNG at most 1600 px on the long side, on a white background.
    static func render(svg: String) -> Data? {
        var source = svg
        if !source.contains("xmlns=") { source = source.replacingOccurrences(of: "<svg", with: "<svg xmlns=\"http://www.w3.org/2000/svg\"", options: [.caseInsensitive], range: source.range(of: "<svg", options: .caseInsensitive)) }
        guard source.utf8.count <= 200_000, let image = NSImage(data: Data(source.utf8)),
              image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1600 / max(image.size.width, image.size.height), 4)
        let width = max(1, Int(image.size.width * scale)), height = max(1, Int(image.size.height * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
