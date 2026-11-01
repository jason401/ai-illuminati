import Foundation

enum AppLanguage: String, CaseIterable {
    case english = "en"
    case korean = "ko"

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "en") ?? .english
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
