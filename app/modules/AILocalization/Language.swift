import Foundation

// Its own module (AILocalization): every part of the app uses L(), so it depends on nothing of the app.
public enum AppLanguage: String, CaseIterable {
    case english = "en"
    case korean = "ko"

    // The language macOS picked for this app (System Settings → General → Language & Region →
    // Applications can set it per app): the first Korean or English entry, English otherwise.
    // macOS restarts the app when it changes, so it is read once.
    // Settable from outside: tests switch the language and put it back.
    public static var current = resolve(Locale.preferredLanguages)

    public static func resolve(_ preferred: [String]) -> AppLanguage {
        for id in preferred {
            if id.hasPrefix("ko") { return .korean }
            if id.hasPrefix("en") { return .english }
        }
        return .english
    }
    public var locale: Locale { Locale(identifier: self == .korean ? "ko_KR" : "en_US") }
}

public func L(_ korean: String, _ english: String) -> String {
    AppLanguage.current == .korean ? korean : english
}
