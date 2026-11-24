import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import AIAccounts
import AILocalization

public enum MacControl {
    @MainActor private static var capturing = false

    static let screenNames: Set<String> = ["mac_screenshot", "mac_windows"]
    static let inputNames: Set<String> = ["mac_click", "mac_drag", "mac_scroll", "mac_type", "mac_key"]
    public static let handNames: Set<String> = inputNames.union(["mac_open"])

    /// Any Mac tool for this account: viewing (on), or hands (ask or on). Ollama has none.
    public static func enabled(_ account: Account?) -> Bool {
        guard let account, account.provider != .ollama else { return false }
        return AICapabilities.rule(account, .screen) == .on || AICapabilities.rule(account, .input) != .off
            || AICapabilities.rule(account, .apps) != .off
    }

    static func allowed(_ name: String, _ account: Account?) -> Bool {
        guard enabled(account), let account else { return false }
        if screenNames.contains(name) { return AICapabilities.rule(account, .screen) == .on }
        if inputNames.contains(name) { return AICapabilities.rule(account, .input) != .off }
        return name == "mac_open" && AICapabilities.rule(account, .apps) != .off
    }

    public static func tools(_ account: Account?) -> [[String: Any]] {
        let point: [String: Any] = ["type": "number", "minimum": 0]
        let all: [[String: Any]] = [
            ["name": "mac_screenshot",
             "description": "View the primary display or one window from mac_windows. The image and its screen-coordinate scale are returned. AI Illuminati windows are excluded. Coordinates for mac_click, mac_drag and mac_scroll are pixels of the newest screenshot of this answer.",
             "inputSchema": ["type": "object", "properties": ["window_id": ["type": "integer", "minimum": 1]], "additionalProperties": false]],
            ["name": "mac_windows",
             "description": "List running apps, the frontmost app, and shareable windows with IDs for mac_screenshot. Hidden untitled windows are left out unless all is true.",
             "inputSchema": ["type": "object", "properties": ["all": ["type": "boolean"]], "additionalProperties": false]],
            ["name": "mac_click",
             "description": "Click at x, y: pixels of the newest mac_screenshot of this answer (screen points when there is none). Take a new screenshot after the screen changes. AI Illuminati's own windows and password fields are refused; the user may be asked first.",
             "inputSchema": ["type": "object", "properties": ["x": point, "y": point, "button": ["type": "string", "enum": ["left", "right"]],
                                                             "double": ["type": "boolean"]], "required": ["x", "y"], "additionalProperties": false]],
            ["name": "mac_drag",
             "description": "Drag with the left button from x, y to to_x, to_y (pixels of the newest mac_screenshot).",
             "inputSchema": ["type": "object", "properties": ["x": point, "y": point, "to_x": point, "to_y": point],
                             "required": ["x", "y", "to_x", "to_y"], "additionalProperties": false]],
            ["name": "mac_scroll",
             "description": "Scroll at x, y (pixels of the newest mac_screenshot) by amount lines (default 3).",
             "inputSchema": ["type": "object", "properties": ["x": point, "y": point, "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                                                             "amount": ["type": "integer", "minimum": 1, "maximum": 50]],
                             "required": ["x", "y", "direction"], "additionalProperties": false]],
            ["name": "mac_type",
             "description": "Type text into the frontmost app's focused field (at most 1000 characters; newline presses Return). Password fields are refused.",
             "inputSchema": ["type": "object", "properties": ["text": ["type": "string", "maxLength": 1000]], "required": ["text"], "additionalProperties": false]],
            ["name": "mac_key",
             "description": "Press one key or shortcut in the frontmost app, e.g. \"return\", \"escape\", \"cmd+s\", \"cmd+shift+t\", \"down\".",
             "inputSchema": ["type": "object", "properties": ["keys": ["type": "string"]], "required": ["keys"], "additionalProperties": false]],
            ["name": "mac_open",
             "description": "Open an app by name or bundle ID (app), or an http(s) address in its default browser (url). Give one of them.",
             "inputSchema": ["type": "object", "properties": ["app": ["type": "string"], "url": ["type": "string"]], "additionalProperties": false]]]
        return all.filter { allowed($0["name"] as? String ?? "", account) }
    }

    @MainActor public static func perform(_ name: String, _ arguments: [String: Any], scope: UUID? = nil) async -> [String: Any] {
        if handNames.contains(name) { return await hand(name, arguments, session: scope.flatMap(session)) }
        guard CGPreflightScreenCaptureAccess() else { return permissionFailure() }
        let wantsScreenshot = name == "mac_screenshot"
        if wantsScreenshot {
            guard !capturing else {
                return failure(L("스크린샷을 찍는 중이에요. 잠시 후 다시 시도해 주세요.",
                                 "A screenshot is in progress. Try again shortly."))
            }
            capturing = true
        }
        // The capture may outlive the socket timeout. Keep the slot until ScreenCaptureKit returns.
        defer { if wantsScreenshot { capturing = false } }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            try Task.checkCancellation()
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let ownBundle = Bundle.main.bundleIdentifier
            let excluded = content.applications.filter { app in
                app.processID == ownPID || (ownBundle != nil && app.bundleIdentifier == ownBundle)
            }
            let windows = content.windows.filter { window in
                guard window.windowLayer == 0, !window.frame.isEmpty, let owner = window.owningApplication else { return false }
                return owner.processID != ownPID && owner.bundleIdentifier != ownBundle
            }
            switch name {
            case "mac_windows":
                return try windowList(windows, all: arguments["all"] as? Bool == true)
            case "mac_screenshot":
                guard #available(macOS 14.0, *) else {
                    return failure(L("스크린샷은 macOS 14 이상에서 쓸 수 있어요.", "Screenshots require macOS 14 or later."))
                }
                let filter: SCContentFilter
                let origin: CGPoint
                let windowCapture = arguments["window_id"] != nil
                if windowCapture {
                    guard let value = arguments["window_id"] as? NSNumber,
                          CFGetTypeID(value) != CFBooleanGetTypeID(),
                          let id = CGWindowID(exactly: value.doubleValue), id != 0 else {
                        return failure(L("창 ID는 양의 정수여야 해요.", "The window ID must be a positive integer."))
                    }
                    guard let window = windows.first(where: { $0.windowID == id }) else {
                        return failure(L("볼 수 있는 창이 아니에요. mac_windows로 창 목록을 다시 확인해 주세요.",
                                         "This window cannot be captured. Refresh the list with mac_windows."))
                    }
                    filter = SCContentFilter(desktopIndependentWindow: window)
                    origin = window.frame.origin
                } else {
                    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                        return failure(L("기본 화면을 찾을 수 없어요.", "The primary display is unavailable."))
                    }
                    filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
                    origin = display.frame.origin
                }
                let (result, mapping) = try await screenshot(filter, origin: origin, window: windowCapture)
                scope.flatMap(session)?.mapping = mapping
                return result
            default:
                return failure(L("쓸 수 없는 화면 도구예요.", "This screen tool is unavailable."))
            }
        } catch {
            if !CGPreflightScreenCaptureAccess() || (error as NSError).domain == SCStreamErrorDomain && (error as NSError).code == -3801 {
                return permissionFailure()
            }
            return failure(L("화면 정보를 가져오지 못했어요.", "Could not get screen information."))
        }
    }

    @MainActor private static func windowList(_ windows: [SCWindow], all: Bool) throws -> [String: Any] {
        func app(_ running: NSRunningApplication) -> [String: Any] {
            ["pid": running.processIdentifier, "name": running.localizedName ?? "", "bundle_id": running.bundleIdentifier ?? ""]
        }
        let workspace = NSWorkspace.shared
        // Hidden untitled windows are app internals (about 290 of 316 on a real Mac, ~27k characters): list only what a person could pick, unless asked for all
        // (an untitled window on another Space).
        let listed: [[String: Any]] = windows.filter { all || $0.isOnScreen || !($0.title ?? "").isEmpty }.map { window in
            ["window_id": window.windowID, "title": window.title ?? "", "app": window.owningApplication?.applicationName ?? "",
             "pid": window.owningApplication?.processID ?? 0, "on_screen": window.isOnScreen]
        }
        let frontmost: Any = workspace.frontmostApplication.map { app($0) as Any } ?? NSNull()
        let data = try JSONSerialization.data(withJSONObject: ["apps": workspace.runningApplications.filter { $0.activationPolicy == .regular }.map(app),
                                                               "frontmost_app": frontmost, "windows": listed], options: [.sortedKeys])
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
    }

    @available(macOS 14.0, *)
    private static func screenshot(_ filter: SCContentFilter, origin: CGPoint, window: Bool) async throws -> ([String: Any], Mapping) {
        let size = filter.contentRect.size
        guard size.width > 0, size.height > 0 else { throw CaptureError.unavailable }
        let scale = min(CGFloat(filter.pointPixelScale), 1360 / max(size.width, size.height))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((size.width * scale).rounded()))
        configuration.height = max(1, Int((size.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = window
        configuration.ignoreGlobalClipSingleWindow = window
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let data = NSMutableData()
        guard let png = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CaptureError.unavailable }
        CGImageDestinationAddImage(png, image, nil)
        guard CGImageDestinationFinalize(png) else { throw CaptureError.unavailable }
        let x = size.width / CGFloat(image.width), y = size.height / CGFloat(image.height)
        let mapping = "Screen points = (\(origin.x), \(origin.y)) + (image_x × \(x), image_y × \(y)); origin at top left. Mouse tools take image pixels of this screenshot."
        return (["content": [["type": "image", "mimeType": "image/png", "data": data.base64EncodedString()],
                             ["type": "text", "text": mapping]]],
                Mapping(origin: origin, scale: CGSize(width: x, height: y), size: CGSize(width: image.width, height: image.height)))
    }

    private enum CaptureError: Error { case unavailable }

    private static func permissionFailure() -> [String: Any] {
        failure(L("화면 기록 권한이 꺼져 있어요: AI별 설정에서 켜 주세요",
                  "Screen Recording access is off. Use AI Settings to turn it on."))
    }

    private static func failure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }
}

// MARK: Hands: click, drag, scroll, type, keys and opening apps (docs/MODULES.md "MacControl").
// Clicks cannot be undone like file edits, so: one answer at a time (InputLock), Esc or the band's Stop ends the answer,
// the user's own mouse or keys pause the AI, AI Illuminati's windows and password fields are always refused, and an app
// is asked about once per answer (rule "ask", or always for settings, keychain, terminals and IDEs).
extension MacControl {
    /// One answer's use of the Mac, from the app's per-answer screen grant until the answer ends (`begin`/`end`).
    public final class Session: @unchecked Sendable {
        let account: Account
        let room: UUID?
        let speaker: String
        let stop: () -> Void
        let note: (String) -> Void
        // Main actor only.
        var mapping: Mapping?               // the newest mac_screenshot of this answer
        var allowedApps: Set<String> = []   // bundle IDs allowed on a card in this answer
        var refusedApps: Set<String> = []   // refused or unanswered: not asked again in this answer
        // Read from any thread too: a card waiting off the main thread ends when the answer stops.
        private let flag = NSLock()
        private var ended = false
        var stopped: Bool {
            get { flag.withLock { ended } }
            set { flag.withLock { ended = newValue } }
        }
        /// `stop` ends the answer (Esc, the band's Stop); `note` adds a line to the answer's action log.
        public init(account: Account, room: UUID?, speaker: String, stop: @escaping () -> Void = {}, note: @escaping (String) -> Void = { _ in }) {
            self.account = account; self.room = room; self.speaker = speaker; self.stop = stop; self.note = note
        }
    }

    /// One approval card: the app shows it in the chat and the inbox and returns the user's answer (no answer in
    /// `approvalWait` = no). Called off the main thread; it may block.
    public struct Approval: Sendable {
        public let room: UUID?
        public let title: String
        public let detail: String
        /// true once the answer stopped (Esc, Stop, its end): the card goes at once instead of waiting out its time.
        public var ended: @Sendable () -> Bool = { false }
    }
    public static var approve: (Approval) -> Bool = { _ in false }
    public static var approvalWait: TimeInterval = 60

    private static let sessionLock = NSLock()
    private static var sessions: [UUID: Session] = [:]
    public static func begin(_ scope: UUID, _ session: Session) { sessionLock.withLock { sessions[scope] = session } }
    /// The answer ended: its grant, the input lock and the band go.
    public static func end(_ scope: UUID) {
        guard let session = sessionLock.withLock({ sessions.removeValue(forKey: scope) }) else { return }
        Task { @MainActor in session.stopped = true; Hands.shared.release(session) }
    }
    static func session(_ scope: UUID) -> Session? { sessionLock.withLock { sessions[scope] } }

    // MARK: Pure rules (tested)

    struct Mapping: Equatable {
        var origin: CGPoint   // screen point of the image's top left
        var scale: CGSize     // screen points per image pixel
        var size: CGSize      // image pixels
    }

    /// Image pixels of the newest screenshot → screen points (top-left origin, as CGEvent takes them). nil: outside it.
    /// Without a screenshot the numbers are screen points already.
    static func screenPoint(_ x: Double, _ y: Double, _ mapping: Mapping?) -> CGPoint? {
        guard x.isFinite, y.isFinite, x >= 0, y >= 0 else { return nil }
        guard let mapping else { return CGPoint(x: x, y: y) }
        guard x <= mapping.size.width, y <= mapping.size.height else { return nil }
        return CGPoint(x: mapping.origin.x + x * mapping.scale.width, y: mapping.origin.y + y * mapping.scale.height)
    }

    enum Verdict: Equatable { case allow, ask, block(String) }

    // Asked every answer even when the rule is On: settings, the keychain, terminals and IDEs.
    static let alwaysAsk: Set<String> = [
        "com.apple.systempreferences", "com.apple.Settings", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "org.alacritty", "io.alacritty", "co.zeit.hyper", "com.github.wez.wezterm", "com.apple.dt.Xcode", "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed", "com.sublimetext.4",
        "com.panic.Nova", "com.apple.ScriptEditor2", "com.apple.Automator", "com.apple.ActivityMonitor"]
    static func asksAlways(_ bundle: String) -> Bool {
        alwaysAsk.contains(bundle) || bundle.hasPrefix("com.jetbrains.") || bundle.hasPrefix("com.google.android.studio")
    }

    /// What one action may do. own: the target is AI Illuminati; secure: typing would go into a password field.
    static func verdict(rule: CapabilityRule, bundle: String, own: Bool, secure: Bool, allowed: Set<String>, refused: Set<String>) -> Verdict {
        if rule == .off { return .block(L("이 AI는 이 기능이 꺼져 있어요(AI별 설정).", "This AI has this feature off (AI Settings).")) }
        if own {
            return .block(L("AI Illuminati 자기 창은 누르거나 입력할 수 없어요. 다른 앱을 쓰세요.",
                            "AI Illuminati's own windows cannot be clicked or typed into. Use another app."))
        }
        if secure { return .block(L("비밀번호 칸에는 입력할 수 없어요. 사용자에게 직접 입력해 달라고 하세요.",
                                    "Password fields cannot be typed into. Ask the user to type it themselves.")) }
        if refused.contains(bundle) {
            return .block(L("이 답에서 사용자가 이 앱 사용을 허락하지 않았어요. 다시 시도하지 말고 결과에 남기세요.",
                            "The user did not allow this app in this answer. Do not retry; say so in your result."))
        }
        if allowed.contains(bundle) { return .allow }
        return rule == .ask || asksAlways(bundle) ? .ask : .allow
    }

    /// One answer holds the mouse and keyboard at a time.
    final class InputLock {
        private(set) var holder: Session?
        /// nil: this session holds it now. Otherwise the session that holds it.
        func claim(_ session: Session) -> Session? {
            if let holder, holder !== session { return holder }
            holder = session
            return nil
        }
        func release(_ session: Session) { if holder === session { holder = nil } }
    }

    /// Korean subject particle for a name like "Claude (개인)": 이 after a final consonant, else 가.
    static func subject(_ name: String) -> String {
        guard let last = name.unicodeScalars.last(where: { CharacterSet.alphanumerics.contains($0) }) else { return name + "이(가)" }
        guard (0xAC00...0xD7A3).contains(last.value) else { return name + "이(가)" }
        return name + ((last.value - 0xAC00) % 28 == 0 ? "가" : "이")
    }

    // MARK: Tool calls

    @MainActor static func hand(_ name: String, _ arguments: [String: Any], session: Session?) async -> [String: Any] {
        guard let session, !session.stopped else { return failure(L("이 답의 맥 조작이 끝났어요.", "Mac control for this answer has ended.")) }
        guard allowed(name, session.account) else { return failure(L("이 AI는 이 기능이 꺼져 있어요(AI별 설정).", "This AI has this feature off (AI Settings).")) }
        guard AXIsProcessTrusted() else {
            return failure(L("손쉬운 사용 권한이 꺼져 있어요: AI별 설정 ▸ 손쉬운 사용에서 AI Illuminati를 켜 주세요.",
                             "Accessibility access is off. In AI Settings, turn on Accessibility for AI Illuminati."))
        }
        let hands = Hands.shared
        if let other = hands.lock.claim(session) {
            return failure(L("다른 AI(\(other.speaker))가 화면을 쓰는 중이에요. 그 답이 끝난 뒤 다시 시도하세요.",
                             "Another AI (\(other.speaker)) is using the screen. Try again after its answer ends."))
        }
        hands.show(session)
        do {
            switch name {
            case "mac_open": return try await open(arguments, session)
            default: return try await input(name, arguments, session)
            }
        } catch {
            return failure((error as? HandError)?.message ?? L("맥 조작을 하지 못했어요.", "Could not control the Mac."))
        }
    }

    struct HandError: Error { let message: String }

    private struct Target { let app: NSRunningApplication?; let bundle: String; let name: String; let own: Bool }

    @MainActor private static func target(_ app: NSRunningApplication?) -> Target {
        let own = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            || (app?.bundleIdentifier != nil && app?.bundleIdentifier == Bundle.main.bundleIdentifier)
        let bundle = app?.bundleIdentifier ?? "com.apple.finder"
        return Target(app: app, bundle: bundle, name: app?.localizedName ?? L("데스크톱", "Desktop"), own: own)
    }

    // The app that gets a click at a screen point. Accessibility's hit test first: the window list alone is fooled by
    // see-through windows (the Dock keeps one over the whole main display, layer 20). Then normal windows front to back;
    // the desktop is Finder's.
    @MainActor private static func app(at point: CGPoint) -> NSRunningApplication? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1)
        var element: AXUIElement?, pid: pid_t = 0
        if AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success, let element,
           AXUIElementGetPid(element, &pid) == .success, let app = NSRunningApplication(processIdentifier: pid) { return app }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard (window[kCGWindowAlpha as String] as? Double ?? 1) > 0, window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(point),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if let app = NSRunningApplication(processIdentifier: pid) { return app }
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
    }

    // A password field has the focus: AX says so, or macOS turned on secure input.
    static func secureFocus() -> Bool {
        if IsSecureEventInputEnabled() { return true }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return false }
        for attribute in [kAXSubroleAttribute, kAXRoleAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element as! AXUIElement, attribute as CFString, &value) == .success,
               value as? String == "AXSecureTextField" { return true }
        }
        return false
    }

    private static func number(_ arguments: [String: Any], _ key: String) -> Double? {
        guard let value = arguments[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue
    }

    @MainActor private static func point(_ arguments: [String: Any], _ x: String, _ y: String, _ session: Session) throws -> CGPoint {
        guard let px = number(arguments, x), let py = number(arguments, y),
              let point = screenPoint(px, py, session.mapping) else {
            throw HandError(message: L("좌표가 최근 스크린샷 밖이에요. mac_screenshot을 다시 찍고 그 그림의 픽셀로 주세요.",
                                       "The point is outside the newest screenshot. Take mac_screenshot again and use its pixels."))
        }
        guard NSScreen.screens.contains(where: { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return id.map { CGDisplayBounds(CGDirectDisplayID($0.uint32Value)).insetBy(dx: -1, dy: -1).contains(point) } ?? false
        }) else { throw HandError(message: L("그 좌표는 화면 밖이에요.", "That point is off the screen.")) }
        return point
    }

    // Waits for a clear yes before acting: the user's own input to settle, then the rule and, when asked, the card.
    @MainActor private static func permit(_ session: Session, capability: AICapability, action: String, verb: (String) -> String,
                                          detail: String, typing: Bool, resolve: @escaping () -> Target) async throws -> Target {
        try await Hands.shared.waitForQuiet(session)
        var target = resolve()
        var asked = false
        while true {
            let rule = AICapabilities.rule(session.account, capability)
            switch verdict(rule: rule, bundle: target.bundle, own: target.own, secure: typing && secureFocus(),
                           allowed: session.allowedApps, refused: session.refusedApps) {
            case .allow: return target
            case .block(let why):
                session.note(L("막음 · ", "Refused · ") + action + " · " + target.name)
                throw HandError(message: why)
            case .ask:
                guard !asked else { throw HandError(message: L("허락을 받지 못했어요.", "Not allowed.")) }
                asked = true
                var card = Approval(room: session.room, title: verb(target.name),
                                    detail: action + "\n" + L("앱: ", "App: ") + target.name + " (" + target.bundle + ")\n" + detail)
                card.ended = { [session] in session.stopped }
                let before = target
                let yes = await withCheckedContinuation { done in
                    DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: approve(card)) }
                }
                guard !session.stopped else { throw HandError(message: L("사용자가 멈췄어요.", "The user stopped it.")) }
                guard yes else {
                    session.refusedApps.insert(before.bundle)
                    session.note(L("허락 못 받음 · ", "Not allowed · ") + action + " · " + before.name)
                    throw HandError(message: L("허락을 못 받았어요(거절 또는 \(Int(approvalWait))초 무응답). 다시 시도하지 말고 결과에 \"허락을 못 받았다\"고 남기세요.",
                                               "Not allowed (refused or no answer in \(Int(approvalWait)) seconds). Do not retry; say in your result that permission was not given."))
                }
                session.allowedApps.insert(before.bundle)
                // Answering the card brought AI Illuminati forward: give the keys back to the app that was asked about.
                if typing, let app = before.app, NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                    app.activate()
                    try await Task.sleep(nanoseconds: 400_000_000)
                }
                try await Hands.shared.waitForQuiet(session)
                target = resolve()
                if target.bundle != before.bundle { asked = false }
            }
        }
    }

    @MainActor private static func input(_ name: String, _ arguments: [String: Any], _ session: Session) async throws -> [String: Any] {
        let say = session.speaker
        switch name {
        case "mac_click":
            let at = try point(arguments, "x", "y", session)
            let right = arguments["button"] as? String == "right", twice = arguments["double"] as? Bool == true
            let kind = right ? L("오른쪽 클릭", "Right-click") : twice ? L("두 번 클릭", "Double-click") : L("클릭", "Click")
            let action = kind + " (\(Int(at.x)), \(Int(at.y)))"
            let target = try await permit(session, capability: .input, action: action,
                                          verb: { L(subject(say) + " \($0)에서 클릭하려고 해요", "\(say) wants to click in \($0)") },
                                          detail: "", typing: false, resolve: { self.target(app(at: at)) })
            try Hands.shared.check(session)
            Hands.click(at, right: right, count: twice ? 2 : 1)
            session.note(action + " · " + target.name)
            return done(action + " · " + target.name)
        case "mac_drag":
            let from = try point(arguments, "x", "y", session), to = try point(arguments, "to_x", "to_y", session)
            let action = L("끌기", "Drag") + " (\(Int(from.x)), \(Int(from.y))) → (\(Int(to.x)), \(Int(to.y)))"
            // Both ends count: the app it starts in and the app it drops onto are each checked (and asked) on their own.
            let verb: (String) -> String = { L(subject(say) + " \($0)에서 끌어 옮기려고 해요", "\(say) wants to drag in \($0)") }
            let target = try await permit(session, capability: .input, action: action, verb: verb, detail: "", typing: false,
                                          resolve: { self.target(app(at: from)) })
            let drop = try await permit(session, capability: .input, action: action, verb: verb, detail: L("놓는 곳", "Drop target"), typing: false,
                                        resolve: { self.target(app(at: to)) })
            let apps = target.bundle == drop.bundle ? target.name : target.name + " → " + drop.name
            try Hands.shared.check(session)
            try await Hands.drag(from, to, session)
            session.note(action + " · " + apps)
            return done(action + " · " + apps)
        case "mac_scroll":
            let at = try point(arguments, "x", "y", session)
            let direction = arguments["direction"] as? String ?? ""
            guard ["up", "down", "left", "right"].contains(direction) else { throw HandError(message: L("방향은 up, down, left, right 중 하나예요.", "Direction must be up, down, left or right.")) }
            let amount = Int(max(1, min(50, (number(arguments, "amount") ?? 3).rounded())))   // clamped before Int: a huge number must not crash
            let action = L("스크롤", "Scroll") + " \(direction) \(amount) (\(Int(at.x)), \(Int(at.y)))"
            let target = try await permit(session, capability: .input, action: action,
                                          verb: { L(subject(say) + " \($0)에서 스크롤하려고 해요", "\(say) wants to scroll in \($0)") },
                                          detail: "", typing: false, resolve: { self.target(app(at: at)) })
            try Hands.shared.check(session)
            Hands.scroll(at, direction: direction, amount: amount)
            session.note(action + " · " + target.name)
            return done(action + " · " + target.name)
        case "mac_type":
            guard let text = arguments["text"] as? String, !text.isEmpty else { throw HandError(message: L("입력할 글자가 없어요.", "There is no text to type.")) }
            guard text.count <= 1000 else { throw HandError(message: L("한 번에 1000자까지 입력할 수 있어요.", "Up to 1000 characters at a time.")) }
            // Only the length: what is typed may be secret, so neither the card nor the log keeps it.
            let action = L("글자 입력 \(text.count)자", "Type \(text.count) characters")
            let target = try await permit(session, capability: .input, action: action,
                                          verb: { L(subject(say) + " \($0)에 글자를 입력하려고 해요", "\(say) wants to type in \($0)") },
                                          detail: "", typing: true, resolve: { self.target(NSWorkspace.shared.frontmostApplication) })
            try await Hands.type(text, session)
            session.note(action + " · " + target.name)
            return done(action + " · " + target.name)
        case "mac_key":
            guard let keys = arguments["keys"] as? String, let combo = Hands.combo(keys) else {
                throw HandError(message: L("모르는 키예요. 예: return, escape, tab, cmd+s, cmd+shift+t, down", "Unknown key. Examples: return, escape, tab, cmd+s, cmd+shift+t, down"))
            }
            let action = L("키", "Key") + " " + keys.lowercased()
            let target = try await permit(session, capability: .input, action: action,
                                          verb: { L(subject(say) + " \($0)에서 키를 누르려고 해요", "\(say) wants to press keys in \($0)") },
                                          detail: "", typing: true, resolve: { self.target(NSWorkspace.shared.frontmostApplication) })
            try Hands.shared.check(session)
            Hands.press(combo.key, flags: combo.flags)
            session.note(action + " · " + target.name)
            return done(action + " · " + target.name)
        default:
            throw HandError(message: L("쓸 수 없는 맥 도구예요.", "This Mac tool is unavailable."))
        }
    }

    @MainActor private static func open(_ arguments: [String: Any], _ session: Session) async throws -> [String: Any] {
        let say = session.speaker
        let workspace = NSWorkspace.shared
        if let address = arguments["url"] as? String, !address.isEmpty {
            // Only web pages: a file or custom scheme could run anything.
            guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw HandError(message: L("http 또는 https 주소만 열 수 있어요.", "Only http or https addresses can be opened."))
            }
            guard let handler = workspace.urlForApplication(toOpen: url) else { throw HandError(message: L("이 주소를 열 앱이 없어요.", "No app opens this address.")) }
            let bundle = Bundle(url: handler)?.bundleIdentifier ?? handler.lastPathComponent
            let name = FileManager.default.displayName(atPath: handler.path).replacingOccurrences(of: ".app", with: "")
            let action = L("주소 열기", "Open address") + " " + String(address.prefix(120))
            let target = try await permit(session, capability: .apps, action: action,
                                          verb: { L(subject(say) + " \($0)에서 주소를 열려고 해요", "\(say) wants to open an address in \($0)") },
                                          detail: address, typing: false, resolve: {
                Target(app: nil, bundle: bundle, name: name, own: bundle == Bundle.main.bundleIdentifier)
            })
            try Hands.shared.check(session)
            guard workspace.open(url) else { throw HandError(message: L("주소를 열지 못했어요.", "Could not open the address.")) }
            session.note(action + " · " + target.name)
            return done(action + " · " + target.name)
        }
        guard let wanted = (arguments["app"] as? String)?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty else {
            throw HandError(message: L("app이나 url 중 하나를 주세요.", "Give app or url."))
        }
        guard let location = application(wanted) else {
            throw HandError(message: L("'\(wanted)' 앱을 찾지 못했어요. mac_windows로 이름을 확인하세요.", "Could not find the app '\(wanted)'. Check its name with mac_windows."))
        }
        let bundle = Bundle(url: location)?.bundleIdentifier ?? location.lastPathComponent
        let name = FileManager.default.displayName(atPath: location.path).replacingOccurrences(of: ".app", with: "")
        let action = L("앱 열기", "Open app")
        let target = try await permit(session, capability: .apps, action: action,
                                      verb: { L(subject(say) + " \($0)을(를) 열려고 해요", "\(say) wants to open \($0)") },
                                      detail: location.path, typing: false, resolve: {
            Target(app: nil, bundle: bundle, name: name, own: bundle == Bundle.main.bundleIdentifier)
        })
        try Hands.shared.check(session)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do { _ = try await workspace.openApplication(at: location, configuration: configuration) }
        catch { throw HandError(message: L("앱을 열지 못했어요.", "Could not open the app.")) }
        session.note(action + " · " + target.name)
        return done(action + " · " + target.name + L(". 화면이 바뀌었으니 mac_screenshot을 다시 찍으세요.", ". The screen changed: take mac_screenshot again."))
    }

    // An app by bundle ID, running name or file name in the usual folders.
    @MainActor private static func application(_ wanted: String) -> URL? {
        let workspace = NSWorkspace.shared
        if wanted.contains("."), let url = workspace.urlForApplication(withBundleIdentifier: wanted) { return url }
        let lower = wanted.lowercased().replacingOccurrences(of: ".app", with: "")
        if let running = workspace.runningApplications.first(where: { $0.activationPolicy == .regular && $0.localizedName?.lowercased() == lower }),
           let url = running.bundleURL { return url }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for folder in ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities", home + "/Applications"] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            if let hit = names.first(where: { $0.lowercased() == lower + ".app" }) { return URL(fileURLWithPath: folder).appendingPathComponent(hit) }
        }
        return nil
    }

    private static func done(_ text: String) -> [String: Any] { ["content": [["type": "text", "text": text]]] }
}

// The live side of the hands: the lock, the band on top of the screen, Esc and the user's own input, and the events.
@MainActor final class Hands {
    static let shared = Hands()
    let lock = MacControl.InputLock()
    // Our own events carry this, so watching the user's input never sees them.
    static let marker: Int64 = 0x4149_4C4C
    private var monitors: [Any] = []
    private var band: NSPanel?
    private var label: NSTextField?
    private var lastUserInput = Date.distantPast

    func show(_ session: MacControl.Session) {
        guard lock.holder === session else { return }
        if monitors.isEmpty { watch() }
        if band == nil { makeBand() }
        label?.stringValue = L(MacControl.subject(session.speaker) + " 화면을 쓰는 중 · Esc로 멈추기", "\(session.speaker) is using the screen · Esc to stop")
        place()
        band?.orderFrontRegardless()
    }

    func release(_ session: MacControl.Session) {
        guard lock.holder === session else { return }
        lock.release(session)
        band?.orderOut(nil)
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    // Esc or Stop: the answer ends at once and no more actions run.
    func stopCurrent() {
        guard let session = lock.holder else { return }
        session.stopped = true
        session.note(L("사용자가 멈춤", "Stopped by the user"))
        release(session)
        session.stop()
    }

    func check(_ session: MacControl.Session) throws {
        if session.stopped || lock.holder !== session { throw MacControl.HandError(message: L("사용자가 멈췄어요.", "The user stopped it.")) }
    }

    // Pauses while the user moves the mouse or types, until 1.5 seconds pass without it (at most 30 seconds).
    func waitForQuiet(_ session: MacControl.Session) async throws {
        let started = Date()
        while Date().timeIntervalSince(lastUserInput) < 1.5 {
            try check(session)
            if Date().timeIntervalSince(started) > 30 {
                throw MacControl.HandError(message: L("사용자가 마우스·키보드를 계속 쓰고 있어 기다리다 멈췄어요. 잠시 뒤 다시 시도하세요.",
                                                      "The user kept using the mouse or keyboard. Try again a little later."))
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        try check(session)
    }

    private func watch() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged,
                                           .rightMouseDragged, .scrollWheel, .keyDown]
        let seen: (NSEvent) -> Void = { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Hands.marker else { return }
            self?.lastUserInput = Date()
            if event.type == .keyDown && event.keyCode == UInt16(kVK_Escape) { self?.stopCurrent() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: seen) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { seen($0); return $0 }) { monitors.append(local) }
    }

    private func makeBand() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 34), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.borderColor = NSColor.systemRed.cgColor
        background.layer?.borderWidth = 1.5
        let dot = NSTextField(labelWithString: "●")
        dot.textColor = .systemRed
        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 12, weight: .semibold)
        text.lineBreakMode = .byTruncatingTail
        let stop = NSButton(title: L("멈추기", "Stop"), target: self, action: #selector(stopPressed))
        stop.bezelStyle = .rounded
        stop.controlSize = .small
        let row = NSStackView(views: [dot, text, stop])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: background.leadingAnchor), row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
                                     row.topAnchor.constraint(equalTo: background.topAnchor), row.bottomAnchor.constraint(equalTo: background.bottomAnchor)])
        panel.contentView = background
        band = panel; label = text
    }

    private func place() {
        guard let band, let screen = NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        band.setFrameOrigin(NSPoint(x: frame.midX - band.frame.width / 2, y: frame.maxY - band.frame.height - 6))
    }

    @objc private func stopPressed() { stopCurrent() }

    // MARK: Events (CGEvent, posted at the HID level with our marker)

    private static let source = CGEventSource(stateID: .hidSystemState)
    private static func post(_ event: CGEvent?) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cghidEventTap)
    }

    static func click(_ point: CGPoint, right: Bool, count: Int) {
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
        let button: CGMouseButton = right ? .right : .left
        for n in 1...count {
            for type in right ? [CGEventType.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
                let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                post(event)
            }
        }
    }

    static func drag(_ from: CGPoint, _ to: CGPoint, _ session: MacControl.Session) async throws {
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: from, mouseButton: .left))
        post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left))
        // Stopped halfway: back to where it started and let go there, so nothing is dropped on the way.
        var finished = false
        defer {
            let end = finished ? to : from
            if !finished { post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: from, mouseButton: .left)) }
            post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left))
        }
        for step in 1...12 {
            try await Task.sleep(nanoseconds: 25_000_000)
            try shared.check(session)
            let t = CGFloat(step) / 12
            let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left))
        }
        finished = true
    }

    static func scroll(_ point: CGPoint, direction: String, amount: Int) {
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
        let vertical = direction == "up" ? amount : direction == "down" ? -amount : 0
        let horizontal = direction == "left" ? amount : direction == "right" ? -amount : 0
        let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: Int32(vertical), wheel2: Int32(horizontal), wheel3: 0)
        event?.location = point
        post(event)
    }

    // Character by character, checking Stop, the user's input and the target between them.
    static func type(_ text: String, _ session: MacControl.Session) async throws {
        let wanted = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for character in text {
            try shared.check(session)
            if Date().timeIntervalSince(shared.lastUserInput) < 1.5 { try await shared.waitForQuiet(session) }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == wanted, !MacControl.secureFocus() else {
                throw MacControl.HandError(message: L("입력하던 앱이 바뀌었거나 비밀번호 칸이 되어 멈췄어요.", "Stopped: the app changed or a password field took the focus."))
            }
            switch character {
            case "\n", "\r\n": press(CGKeyCode(kVK_Return), flags: [])
            case "\t": press(CGKeyCode(kVK_Tab), flags: [])
            default:
                let units = Array(String(character).utf16)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    event?.flags = []
                    event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    post(event)
                }
            }
            try await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    static func press(_ key: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            post(event)
        }
    }

    // "cmd+shift+t" → the key and its modifiers (US layout key codes).
    nonisolated static func combo(_ text: String) -> (key: CGKeyCode, flags: CGEventFlags)? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else { return nil }
        var flags: CGEventFlags = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "alt", "option", "opt", "⌥": flags.insert(.maskAlternate)
            case "fn": flags.insert(.maskSecondaryFn)
            default: return nil
            }
        }
        guard let key = keyCodes[last] else { return nil }
        return (CGKeyCode(key), flags)
    }

    nonisolated static let keyCodes: [String: Int] = {
        var codes: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
            "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
            "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
            "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6,
            "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, ";": kVK_ANSI_Semicolon,
            "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
            "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, "delete": kVK_Delete, "backspace": kVK_Delete,
            "forwarddelete": kVK_ForwardDelete, "escape": kVK_Escape, "esc": kVK_Escape, "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "up": kVK_UpArrow, "down": kVK_DownArrow, "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown]
        let functions = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (i, code) in functions.enumerated() { codes["f\(i + 1)"] = code }
        return codes
    }()
}
