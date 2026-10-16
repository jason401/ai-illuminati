// Opt-in live smoke test. Pass a disposable fixture directory, never research originals.
import Cocoa
let args = CommandLine.arguments
guard args.count == 2 else { fatalError("usage: disposable-fixture-folder") }
let root = URL(fileURLWithPath: args[1]).resolvingSymlinksInPath()
guard root.path.hasPrefix(URL(fileURLWithPath: "/private/tmp/illuminati-workspace-live").resolvingSymlinksInPath().path + "/") else { fatalError("Only dedicated disposable fixtures allowed") }
let model = AppModel()
let selected = ["claude-1792083351", "codex-1792083419"]
guard selected.allSatisfy({ id in model.accounts.contains { $0.id == id } }) else { fatalError("test accounts unavailable") }
let discussion = Discussion(model: model)
discussion.newConversation()
discussion.configure { $0.mode = 3; $0.accountIDs = selected; $0.leaderAccountID = selected[0]; $0.keepSessions = true }
discussion.change(discussion.currentID, save: true) { $0.workspace = WorkspaceBinding(roots: [WorkspaceRoot(path: root.path, directory: true)], level: .write) }
discussion.draft = "한국어로 보고서 report.md를 만들어줘. 두 작업만 배분해: 먼저 notes.txt와 paper07.pdf 3쪽만 읽어 calibration 수치와 쪽 표식을 확인, 다음 작업은 그 근거를 받아 보고서 작성. Python 공식 문서에서 pathlib.Path의 용도를 검색해서 짧게 설명하고 [source: URL]을 남겨. 다른 자료 전체를 읽을 필요 없어. 실험 사본이며 명령 실행은 금지. 짧은 한국어 최종 결과로 알려줘."
discussion.send()
let deadline = Date().addingTimeInterval(900)
while discussion.running && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
if discussion.running { discussion.stopDebate() }
let data = try JSONEncoder().encode(discussion.current)
FileHandle.standardOutput.write(data)
