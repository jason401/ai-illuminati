import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import AIAccounts
import AILocalization

public enum MacControl {
    @MainActor private static var capturing = false

    public static func enabled(_ account: Account?) -> Bool {
        guard let account, account.provider == .claude || account.provider == .codex else { return false }
        return AICapabilities.rule(account, .screen) == .on
    }

    public static func tools() -> [[String: Any]] {
        [["name": "mac_screenshot",
          "description": "View the primary display or one window from mac_windows. The image and its screen-coordinate scale are returned. AI Illuminati windows are excluded.",
          "inputSchema": ["type": "object", "properties": ["window_id": ["type": "integer", "minimum": 1]], "additionalProperties": false]],
         ["name": "mac_windows",
          "description": "List running apps, the frontmost app, and shareable windows with IDs for mac_screenshot. Hidden untitled windows are left out unless all is true.",
          "inputSchema": ["type": "object", "properties": ["all": ["type": "boolean"]], "additionalProperties": false]]]
    }

    @MainActor public static func perform(_ name: String, _ arguments: [String: Any]) async -> [String: Any] {
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
                return try await screenshot(filter, origin: origin, window: windowCapture)
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
    private static func screenshot(_ filter: SCContentFilter, origin: CGPoint, window: Bool) async throws -> [String: Any] {
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
        let mapping = "Screen points = (\(origin.x), \(origin.y)) + (image_x × \(x), image_y × \(y)); origin at top left."
        return ["content": [["type": "image", "mimeType": "image/png", "data": data.base64EncodedString()],
                            ["type": "text", "text": mapping]]]
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
