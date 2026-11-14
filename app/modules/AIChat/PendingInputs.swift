import Foundation
import AILocalization

// Messages sent while a chat answers (Discussion.enqueue): they wait together and go as one message when the answer
// ends, not one turn each. A message that picks its own way (@ names, /work or the chip, a meeting) starts a new batch,
// so one batch never mixes two ways: [a, b, @X c, d] goes as [a, b], then [@X c, d].
enum PendingInputs {
    // One queued message read the way send() reads the message box.
    struct Ready {
        var question: String
        var mentioned: [String]
        var picked: RouteChoice?
        var images: [ChatImage]
        var ownWay: Bool { !mentioned.isEmpty || picked != nil || Route.asksMeeting(question) }
    }

    // How many messages from the front go in the next batch.
    static func batchSize(_ queue: [Ready]) -> Int {
        guard !queue.isEmpty else { return 0 }
        var n = 1
        while n < queue.count && !queue[n].ownWay { n += 1 }
        return n
    }

    // The batch as one message: alone as it was, several numbered in the order they were sent.
    static func merged(_ questions: [String]) -> String {
        guard questions.count > 1 else { return questions.first ?? "" }
        return L("답하는 동안 이어서 보낸 메시지 \(questions.count)개예요. 보낸 순서대로 읽고 한 번에 답해 주세요.",
                 "\(questions.count) messages sent in a row while you answered. Read them in order and answer them together.")
            + "\n\n" + questions.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n\n")
    }

    // What the running answer reads (steering): marked, so the AI knows it came in the middle of its answer.
    static func steerText(_ question: String) -> String {
        L("[답하는 중에 사용자가 추가로 보낸 메시지입니다. 지금 하는 일에 반영하고, 답에서 이 메시지에도 답해 주세요.]\n",
          "[The user sent this while you were answering. Take it into account in what you are doing, and answer it in your reply.]\n") + question
    }
}
