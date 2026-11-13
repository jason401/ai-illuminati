import Foundation
import AILocalization

// The promises of the AILocalization module, checked from outside it with only its public API (run_mode2.sh).
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("FAIL: " + message) }
}
// The first Korean or English entry wins; anything else is English.
expect(AppLanguage.resolve(["ko-KR", "en-US"]) == .korean, "Korean first picks Korean")
expect(AppLanguage.resolve(["fr-FR", "en-GB", "ko"]) == .english, "the first Korean or English entry wins")
expect(AppLanguage.resolve(["ja-JP"]) == .english && AppLanguage.resolve([]) == .english, "no Korean or English means English")
expect(AppLanguage(rawValue: "ko") == .korean && AppLanguage.english.rawValue == "en", "saved raw values stay en/ko")
expect(AppLanguage.korean.locale.identifier == "ko_KR" && AppLanguage.english.locale.identifier == "en_US", "locales")
// L() follows `current`, which tests may switch and put back.
let saved = AppLanguage.current
AppLanguage.current = .korean
expect(L("한국어", "English") == "한국어", "L() gives Korean when current is Korean")
AppLanguage.current = .english
expect(L("한국어", "English") == "English", "L() gives English when current is English")
AppLanguage.current = saved
print("PASS: AILocalization contract")
