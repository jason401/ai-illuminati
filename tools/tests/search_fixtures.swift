import Foundation
import AIAccounts
import AIWorkspace

// Chats for the search tests and the sidebar preview.
func searchFixtures() -> [Conversation] {
    func chat(_ title: String, _ pairs: [(String, String)], _ edit: (inout Conversation) -> Void = { _ in }) -> Conversation {
        var c = Conversation(); c.title = title
        c.turns = pairs.map { var t = ChatTurn(question: $0.0); t.mode = 0; t.final = $0.1; return t }
        edit(&c); return c
    }
    let schoolLock = EnterpriseLock(organization: "학교", name: "학교", lockedAt: Date())
    return [
        chat("영화 이야기", [("주말에 뭐 볼까", "극장 추천"), ("청룡영화제는 언제야?", "청룡영화제는 11월 말에 열려요.")]),
        chat("청룡영화제 후보", [("후보 정리", "작품상 후보 다섯 편")]),
        chat("앱 아이콘", [("아이콘 색", "파란색이 좋아요")]),
        chat("AI Illuminati 작업", [("청룡영화제에서 쓴 화면", "그 화면은 고쳤어요")]) { $0.workspace = WorkspaceBinding(roots: [], project: ProjectBinding(root: "/tmp/p", common: "", remote: "", remoteURL: "")) },
        chat("연구 노트", [("트랜스듀서 공진", "청룡영화제와는 무관한 측정 3.2 MHz")]) { $0.enterpriseLock = schoolLock },
        chat("날씨", [("내일 비 와?", "맑아요")]),
    ]
}
