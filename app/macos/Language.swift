import Foundation

enum AppLanguage: String, CaseIterable {
    case english = "en"
    case korean = "ko"

    // The language macOS picked for this app (System Settings → General → Language & Region →
    // Applications can set it per app): the first Korean or English entry, English otherwise.
    // macOS restarts the app when it changes, so it is read once.
    static var current = resolve(Locale.preferredLanguages)

    static func resolve(_ preferred: [String]) -> AppLanguage {
        for id in preferred {
            if id.hasPrefix("ko") { return .korean }
            if id.hasPrefix("en") { return .english }
        }
        return .english
    }
    var locale: Locale { Locale(identifier: self == .korean ? "ko_KR" : "en_US") }
}

func L(_ korean: String, _ english: String) -> String {
    AppLanguage.current == .korean ? korean : english
}

// These are app-generated notices saved with a chat, never user or AI messages.
func localizedNotice(_ text: String) -> String {
    for prefix in ["다음 순서: ", "Next order: "] where text.hasPrefix(prefix) {
        return L("다음 순서: ", "Next order: ") + text.dropFirst(prefix.count)
    }
    let notices = [
        ("대표의 순서 지정에 실패해 기존 순서를 유지합니다.", "Scheduling failed. Keeping the current order."),
        ("대표가 발언하지 못해 기존 순서를 유지합니다.", "The moderator was unavailable. Keeping the current order.")
    ]
    for (ko, en) in notices where text == ko || text == en { return L(ko, en) }
    return text
}
