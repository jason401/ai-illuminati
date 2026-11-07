import Foundation

// The app itself must use the real home folder and settings; this only reads the chosen paths.
AccountStore.useRealHome()
let real = FileManager.default.homeDirectoryForCurrentUser.path
guard AccountStore.home == real, AccountStore.supportDir == real + "/Library/Application Support/AI Illuminati",
      AccountStore.accountsDir == real + "/.ai-illuminati/accounts", UserDefaults.app === UserDefaults.standard else {
    fatalError("the app must use the real home folder and settings after useRealHome()")
}
print("PASS: the app uses the real home folder and settings")
