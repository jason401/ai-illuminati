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
    var hasImages: Bool { !pendingImages.isEmpty || current.turns.contains { !($0.images ?? []).isEmpty } || (current.documents ?? []).contains { ($0.units ?? []).contains { !$0.images.isEmpty } } }
    var canSend: Bool { !running && runningRooms.count < Self.maxRunning && !importingMaterials && current.meetingOf == nil && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty) }

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
        // The AIs get only this message's photos and the latest few (Discussion.recentImages), so a chat can hold many.
        guard pendingImages.count < 4, current.turns.flatMap({ $0.images ?? [] }).count + pendingImages.count < 200 else {
            attachmentError = L("한 메시지에 4장, 한 대화에 200장까지 첨부할 수 있습니다.", "Attach up to 4 images per message and 200 per chat.")
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
        guard permits(account, room: currentID) else { return .failure(Enterprise.blocked(account)) }
        if activeImages.isEmpty { return answer(account, activeDocumentText + "\n" + prompt, timeout) }
        return Answerer.ask(account, prompt: activeDocumentText + "\n" + imageContext + "\n" + prompt, timeout: timeout, images: activeImages)
    }

    // fresh: a shorter prompt (summary + recent turns) for an AI that starts without a session it can resume.
    func requestDebate(_ account: Account, _ prompt: String, _ timeout: TimeInterval, _ token: DebateCancellation, web: Bool = false,
                       fresh: String? = nil, workspace: WorkspaceBinding? = nil,
                       progress: ((AnswerProgress) -> Void)? = nil) -> Result<String, Answerer.Failure> {
        // `workspace` replaces the chat's folders for this one request (a read-only view for a second AI).
        let activeWorkspace = workspace ?? self.activeWorkspace
        guard permits(account, room: activeSessionRoom ?? currentID) else { return .failure(Enterprise.blocked(account)) }
        let selected: [MaterialContext.Part] = []
        let materialText = selected.isEmpty ? "" : "\n[Selected source excerpts; not an exhaustive review. Use Collaboration for full coverage.]\n" + MaterialContext.quote(selected)
        pictureLock.lock(); let shared = activeImages, sharedContext = imageContext; pictureLock.unlock()
        let pictures = shared + selected.flatMap(\.images)
        func wrap(_ text: String) -> String { materialText + (activeDocumentText.isEmpty ? "" : activeDocumentText + "\n") + text + (sharedContext.isEmpty ? "" : "\n" + sharedContext) }
        let full = wrap(prompt)
        let start = fresh.map(wrap) ?? full
        // Only dedicated Claude / ChatGPT accounts keep sessions; others (Gemini) take the normal path.
        if let room = activeSessionRoom, NativeSessions.eligible(account) {
            return nativeSessions.ask(account, room: room, prompt: full, images: pictures, timeout: timeout,
                                      token: token, web: web, speaker: label(account), fresh: fresh.map(wrap), invoke: { text, images, session in
                Answerer.ask(account, prompt: text, timeout: timeout, cancellation: token, images: images, web: web, session: session, workspace: activeWorkspace.map { WorkspaceInvocation(binding: $0, room: room) }, progress: progress)
            }, note: { text in DispatchQueue.main.async { self.sessionNote = text } })
        }
        if let workspaceAnswer, let binding = activeWorkspace { return workspaceAnswer(account, start, binding, token, progress) }
        if pictures.isEmpty && activeWorkspace == nil { return debateAnswer(account, start, timeout, token, web) }
        if let pictureAnswer, activeWorkspace == nil { return pictureAnswer(account, start, pictures, timeout, token, web) }
        return Answerer.ask(account, prompt: start, timeout: timeout, cancellation: token, images: pictures, web: web, workspace: activeWorkspace.map { WorkspaceInvocation(binding: $0, room: activeSessionRoom ?? currentID) }, progress: progress)
    }
}

/// Pictures from a drop (same as AI Face's PictureDrop). Finder hands over file URLs; the Photos app and
/// screenshot thumbnails hand over promised files (written when dropped, after an iCloud download if
/// needed) or only image data. Those are copied into a temporary folder first: `done(urls, folder)` runs on
/// the main thread, and the caller removes `folder` once it has read the files.
enum PictureDrop {
    // Promised files (the Photos app, screenshot thumbnails) are on the drag pasteboard, not in the item types.
    static func hasPromises(_ pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> Bool {
        pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }

    static func receive(_ providers: [NSItemProvider], pasteboard: NSPasteboard = NSPasteboard(name: .drag),
                        done: @escaping ([URL], URL?) -> Void) {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty { done(files, nil); return }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AI Illuminati drop " + UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var found: [URL] = []
        let lock = NSLock()
        let group = DispatchGroup()
        func keep(_ url: URL) { lock.lock(); found.append(url); lock.unlock() }

        let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        if !promises.isEmpty {
            let queue = OperationQueue()
            for promise in promises {
                var waiting = max(1, promise.fileTypes.count)   // the reader runs once per promised file
                for _ in 0..<waiting { group.enter() }
                promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in
                    if error == nil { keep(url) }
                    lock.lock(); let leave = waiting > 0; waiting -= 1; lock.unlock()
                    if leave { group.leave() }
                }
            }
        } else {
            for provider in providers {
                guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else { continue }
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                    defer { group.leave() }
                    guard let url else { return }   // removed when this returns: copy it now
                    let ext = UTType(type)?.preferredFilenameExtension ?? url.pathExtension
                    let name = (provider.suggestedName ?? url.deletingPathExtension().lastPathComponent) + "." + ext
                    let copy = folder.appendingPathComponent(String(UUID().uuidString.prefix(8)) + " " + name)
                    if (try? FileManager.default.copyItem(at: url, to: copy)) != nil { keep(copy) }
                }
            }
        }
        // Give up on anything that has not arrived after a minute (a stuck iCloud download).
        var finished = false
        let finish = {
            if finished { return }
            finished = true
            lock.lock(); let urls = found; lock.unlock()
            done(urls, folder)
        }
        group.notify(queue: .main, execute: finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: finish)
    }
}
