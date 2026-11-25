import Foundation

// Which per-feature rules one answer's instruction carries (composeInstruction). A rule the message has no use for is
// left out so the ones that matter are not buried; when in doubt a rule stays in (a missing rule silently turns its
// feature off). Always in, whatever the message: identity, project, folder rights, safety, web, face, chat state,
// notes, memory. Spaces decide for themselves (Discussion.spaceRule).
struct InstructionNeeds: Equatable {
    var picture = true   // making pictures, and reading the attached ones
    var peer = true      // the full ask_ai / meeting rule (otherwise a one-line reminder that they exist)

    static let all = InstructionNeeds()

    // `question`: the newest user message. `images`: pictures are attached or already in this chat.
    // `project`: Git or documents project work (reviewers, designs and research live there).
    init(question: String, images: Bool = false, project: Bool = false, documents: Bool = false) {
        let text = question.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        picture = images || documents || has(Self.pictureWords)
        peer = project || documents || text.count >= Self.longQuestion || has(Self.peerWords)
    }
    private init() {}

    // A question this long is real work, so other AIs' views may help.
    static let longQuestion = 160
    static let pictureWords = ["그림", "그려", "그리", "이미지", "사진", "일러스트", "삽화", "아이콘", "로고", "도식", "도표", "다이어그램",
                               "차트", "그래프", "스케치", "목업", "시각화", "포스터", "썸네일", "배너", "캐릭터", "만화", "개념도", "흐름도",
                               "순서도", "구조도", "디자인", "화면", "스크린샷", "picture", "image", "draw", "diagram", "chart", "graph", "plot",
                               "icon", "logo", "sketch", "mockup", "illustrat", "figure", "svg", "png", "jpg", "visual", "poster", "banner",
                               "thumbnail", "photo", "screenshot", "design"]
    static let peerWords = ["확인", "맞아", "맞나", "맞는", "사실", "출처", "인용", "근거", "숫자", "통계", "수치", "비교", "추천", "장단점",
                            "어느", "어떤 게", "뭐가 나", "골라", "고르", "고를", " 중 ", "나아", "낫", " vs", "설계", "계획", "결정", "선택",
                            "의견", "생각", "검토", "리뷰", "검수", "조사", "연구", "논문", "분석", "평가", "회의", "토론", "다른 ai", "gpt",
                            "chatgpt", "챗gpt", "챗지피티", "gemini", "제미나이",
                            "claude", "클로드", "codex", "코덱스", "fact", "source", "cite", "verify", "check", "compare", "recommend", "review",
                            "opinion", "research", "design", "plan", "decide", "decision", "meeting", "analy", "evaluat", "which", "should",
                            "choose", "pick", "better"]
}
