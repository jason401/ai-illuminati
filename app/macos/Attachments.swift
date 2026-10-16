import Cocoa
import ImageIO
import UniformTypeIdentifiers

struct ChatImage: Identifiable, Codable, Equatable {
    var id = UUID()
    var conversationID: UUID
    var name: String
    var url: URL {
        URL(fileURLWithPath: ChatStore.dir).appendingPathComponent(conversationID.uuidString + ".assets")
            .appendingPathComponent(id.uuidString + ".png")
    }
}

enum ImageStore {
    static func importImage(_ data: Data, name: String, conversationID: UUID, maxEdge: Int = 1600) throws -> ChatImage {
        guard data.count <= 25 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxEdge
              ] as CFDictionary) else { throw Failure.invalid }
        let item = ChatImage(conversationID: conversationID, name: name)
        try FileManager.default.createDirectory(at: item.url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoded = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else { throw Failure.invalid }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { throw Failure.invalid }
        if encoded.length > 4_500_000 {
            guard maxEdge > 1024 else { throw Failure.invalid }
            return try importImage(data, name: name, conversationID: conversationID, maxEdge: 1024)
        }
        try (encoded as Data).write(to: item.url, options: .atomic)
        return item
    }
    enum Failure: Error { case invalid }
    static func remove(_ item: ChatImage) throws {
        if FileManager.default.fileExists(atPath: item.url.path) { try FileManager.default.removeItem(at: item.url) }
    }
}

extension Discussion {
    var hasImages: Bool { !pendingImages.isEmpty || current.turns.contains { !($0.images ?? []).isEmpty } }
    var canSend: Bool { !running && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty) }

    func chooseImages() {
        guard !running else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { importImageFile(url) }
    }

    func importImageFile(_ url: URL) {
        guard !running else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 25 * 1024 * 1024 else { throw ImageStore.Failure.invalid }
            try addImage(Data(contentsOf: url), name: url.lastPathComponent)
        } catch { attachmentError = L("이미지를 열 수 없습니다. 25MB 이하의 사진을 선택하세요.", "Could not open image. Choose an image under 25 MB.") }
    }

    func addPastedImages(_ pasteboard: NSPasteboard) -> Bool {
        guard !running else { return false }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let images = urls.filter { (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true }
            if !images.isEmpty { images.forEach(importImageFile); return true }
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            do { try addImage(data, name: L("붙여넣은 이미지", "Pasted image")) }
            catch { attachmentError = L("이미지를 첨부할 수 없습니다.", "Could not attach image.") }
            return true
        }
        return false
    }

    func addImage(_ data: Data, name: String) throws {
        guard !running else { return }
        guard pendingImages.count < 4, current.turns.flatMap({ $0.images ?? [] }).count + pendingImages.count < 12 else {
            attachmentError = L("한 메시지에 4장, 한 대화에 12장까지 첨부할 수 있습니다.", "Attach up to 4 images per message and 12 per chat.")
            return
        }
        let item = try ImageStore.importImage(data, name: name, conversationID: currentID)
        pendingImages.append(item)
        attachmentError = nil
        if configuration.leader == .gemini {
            configure { config in config.leader = config.participants.contains(.claude) ? .claude : .codex }
        }
    }

    func removePendingImage(_ item: ChatImage) {
        do { try ImageStore.remove(item); pendingImages.removeAll { $0.id == item.id } }
        catch { attachmentError = L("첨부 파일을 지우지 못했습니다.", "Could not remove attachment.") }
    }

    func discardPendingImages() {
        for item in pendingImages { try? ImageStore.remove(item) }
        pendingImages = []
        attachmentError = nil
        draft = ""
    }

    func request(_ account: Account, prompt: String, timeout: TimeInterval = 240) -> Result<String, Answerer.Failure> {
        if activeImages.isEmpty { return answer(account, prompt, timeout) }
        return Answerer.ask(account, prompt: imageContext + "\n" + prompt, timeout: timeout, images: activeImages)
    }

    func requestDebate(_ account: Account, _ prompt: String, _ timeout: TimeInterval, _ token: DebateCancellation, web: Bool = false) -> Result<String, Answerer.Failure> {
        if activeImages.isEmpty { return debateAnswer(account, prompt, timeout, token, web) }
        return Answerer.ask(account, prompt: imageContext + "\n" + prompt, timeout: timeout, cancellation: token, images: activeImages, web: web)
    }
}
