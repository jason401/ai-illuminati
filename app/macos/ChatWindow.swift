import Cocoa
import SwiftUI

// The chat window: pick which AIs take part, ask, and get one final answer. What the AIs said to
// each other (own answers, then reviews) is folded under the answer.
struct ChatView: View {
    @ObservedObject var discussion: Discussion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("참여").foregroundColor(.secondary)
                Toggle("Claude", isOn: $discussion.useClaude)
                Toggle("ChatGPT", isOn: $discussion.useCodex)
                Toggle("Gemini", isOn: $discussion.useGemini)
                Spacer()
                Button("새 대화") { discussion.reset() }.disabled(discussion.running || discussion.turns.isEmpty)
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if discussion.turns.isEmpty {
                            Text("질문을 입력하면 AI들이 각자 답하고, 서로 검토한 뒤, 한 명이 최종 답을 정리해 줘요.\n한 질문에 30초~1분쯤 걸리고, 그만큼 각 계정의 사용량이 쓰여요.")
                                .foregroundColor(.secondary)
                                .padding(.top, 40)
                                .frame(maxWidth: .infinity)
                                .multilineTextAlignment(.center)
                        }
                        ForEach(discussion.turns) { turn in
                            TurnView(turn: turn).id(turn.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: discussion.turns.count) { _ in
                    if let last = discussion.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } }
                }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("질문을 입력하세요", text: $discussion.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { discussion.send() }
                Button(discussion.running ? "토론 중…" : "보내기") { discussion.send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(discussion.running || discussion.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 480)
    }
}

private struct TurnView: View {
    let turn: ChatTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 80)
                Text(turn.question)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.18))
                    .cornerRadius(10)
            }
            if !turn.status.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(turn.status).foregroundColor(.secondary)
                }
            }
            if let error = turn.error {
                Text(error).foregroundColor(.red)
            }
            if let final = turn.final {
                VStack(alignment: .leading, spacing: 6) {
                    Text(markdown(final))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let by = turn.finalBy {
                        Text("정리: \(by)").font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(10)
            }
            if !turn.entries.isEmpty {
                DisclosureGroup("AI들의 대화 보기 (\(turn.entries.count))") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(turn.entries.sorted { $0.round < $1.round }) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(entry.round == 1 ? "각자 답" : "검토 후") · \(entry.speaker)")
                                    .font(.caption.bold())
                                    .foregroundColor(entry.failed ? .red : .secondary)
                                Text(markdown(entry.text))
                                    .textSelection(.enabled)
                                    .foregroundColor(entry.failed ? .secondary : .primary)
                            }
                        }
                    }
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
        }
    }

    // Bold, italics, code and links; line breaks are kept.
    private func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// One chat window, reused (closing it keeps the conversation until the app quits).
final class ChatWindow {
    private var window: NSWindow?

    func show(discussion: Discussion) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ChatView(discussion: discussion)))
            w.title = "AI Illuminati 채팅"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 720, height: 680))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
