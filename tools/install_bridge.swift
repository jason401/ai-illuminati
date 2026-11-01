import Cocoa

// Compatibility with the old updater: it calls --install-staged only after its idle check.
// Terminate exactly the running app at the expected path, with the normal quit event.
let args = CommandLine.arguments
if args.count != 3 || Int32(args[1]) == nil { exit(2) }
let pid = Int32(args[1])!
let expected = URL(fileURLWithPath: args[2]).standardizedFileURL
if let app = NSRunningApplication(processIdentifier: pid),
   app.bundleURL?.standardizedFileURL == expected,
   app.bundleIdentifier == "local.aiilluminati" {
    exit(app.terminate() ? 0 : 1)
}
exit(1)
