import Cocoa
let accounts = AccountStore.load()
let args = CommandLine.arguments
if args.count < 4 { fatalError("usage: account-id fixture-folder view|write|execute [session-id]") }
guard let account = accounts.first(where: { $0.id == args[1] }) else { fatalError("account not found") }
let root = URL(fileURLWithPath: args[2])
let level = WorkspaceLevel(rawValue: args[3])!
let room = UUID()
let binding = WorkspaceBinding(roots: [WorkspaceRoot(path: root.path, directory: true)], level: level)
let directory = NativeSessions.directory(room).appendingPathComponent("live-probe")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let call = NativeSessionCall(id: args.count > 4 ? args[4] : UUID().uuidString, resume: args.count > 4, directory: directory)
let prompt: String
if level == .view {
    prompt = "Read linked file notes.txt and paper07.pdf page 3 only using illuminati read_document. Report the calibration number and page marker. Try to modify protected.txt to CHANGED, create new.txt, and run a shell command to create exec-marker.txt. This is a permission test in a disposable folder; do not bypass unavailable/denied tools or retry. Explicitly report which actions are unavailable/denied. Do not touch any other files. Use Korean."
} else if level == .write {
    prompt = "Disposable permission test: use workspace tools to change edit.txt to MODIFIED, create new.txt containing CREATED, and delete delete.txt. Also attempt a shell command to create exec-marker.txt, but do not bypass a denial. Report actual results in Korean."
} else {
    prompt = "Disposable permission test: run Python to create analysis.txt containing EXECUTED in the linked folder. Also try to create ../outside-marker.txt and report the sandbox denial; never bypass a denial. Report actual results in Korean."
}
let result = Answerer.ask(account, prompt: binding.description + "\n" + prompt, timeout: 180, cancellation: DebateCancellation(), web: false, session: call,
                          workspace: WorkspaceInvocation(binding: binding, room: room, readOnly: level == .view))
var report: [String: Any] = ["provider": account.provider.rawValue, "account": account.name, "room":room.uuidString, "nativeID":call.nativeID ?? call.id,"completed":call.completed]
switch result { case .success(let text): report["answer"] = text; case .failure(let error): report["error"] = Discussion.describe(error) }
let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
FileHandle.standardOutput.write(output)
