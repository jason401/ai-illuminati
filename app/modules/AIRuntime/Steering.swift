import Foundation

/// Messages the user sends while one Claude answer runs, written into that answer: Claude reads them after the tool
/// that is running (measured with Claude Code 2.1.300, `--replay-user-messages`; not a documented promise). Written
/// only while a tool runs: one written while the AI writes its reply is read after the reply, as a second answer.
/// What the answer did not read comes back from `close()`, so the caller sends it as the next message.
/// Any thread; `onRead` comes on a background thread.
public final class SteerChannel {
    private let lock = NSLock()
    private var held: [String] = []       // taken, not written yet
    private var written: [String] = []    // written, not read yet
    private var calls = 0                 // Claude calls running with this channel
    private var closed = false
    private var writer: ((String) -> Bool)?   // the running call's input, only while a tool runs
    /// Each message the running answer read, once, in order.
    public var onRead: ((String) -> Void)?
    public init() {}

    /// A Claude call with this channel is running: what is offered now can still reach the answer.
    public var live: Bool { lock.lock(); defer { lock.unlock() }; return !closed && calls > 0 }

    /// Takes a message for the running answer. false: no call can take it (none running, or closed); queue it instead.
    public func offer(_ text: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, calls > 0 else { return false }
        if let writer, writer(text) { written.append(text) } else { held.append(text) }
        return true
    }

    /// The answer is over: no more is taken; what it did not read, in the order it was sent.
    public func close() -> [String] {
        lock.lock(); defer { lock.unlock() }
        closed = true; writer = nil
        let left = written + held
        written = []; held = []
        return left
    }

    // Answerer: a call starts (false: closed, run without it) and ends.
    func attach() -> Bool { lock.lock(); defer { lock.unlock() }; guard !closed else { return false }; calls += 1; return true }
    func detach() {
        lock.lock(); defer { lock.unlock() }
        calls -= 1; writer = nil
        // Written but never read: that call is gone, so they wait for the next call or close().
        held = written + held; written = []
    }
    // A tool started (with the call's input) or every tool ended (nil). Held messages go in as the tool starts.
    func tools(_ write: ((String) -> Bool)?) {
        lock.lock(); defer { lock.unlock() }
        writer = closed ? nil : write
        guard let writer else { return }
        while let next = held.first, writer(next) { written.append(held.removeFirst()) }
    }
    func read(_ text: String) {
        lock.lock()
        guard let i = written.firstIndex(of: text) else { lock.unlock(); return }
        written.remove(at: i)
        let report = onRead
        lock.unlock()
        report?(text)
    }
    var unread: Bool { lock.lock(); defer { lock.unlock() }; return !written.isEmpty }
}

// One Claude call's side of a SteerChannel: watches its JSON events (tool calls, replayed user messages, the result)
// and writes into its input while a tool runs. Only the main conversation counts (`parent_tool_use_id` empty).
final class SteerLink {
    let channel: SteerChannel
    private let input: FileHandle
    private let lock = NSLock()
    private var running: Set<String> = []
    private var inputOpen = true
    private(set) var answered = false    // the first result came
    private(set) var cutOff = false      // ended by us after the result: a message written too late was not read
    var end: () -> Void = {}

    init(channel: SteerChannel, input: FileHandle) { self.channel = channel; self.input = input }

    static func line(_ text: String, images: [[String: Any]] = []) -> Data? {
        let blocks: [[String: Any]] = [["type": "text", "text": text]] + images
        guard var data = try? JSONSerialization.data(withJSONObject: ["type": "user", "message": ["role": "user", "content": blocks]]) else { return nil }
        data.append(0x0a)
        return data
    }

    func write(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard inputOpen else { return false }
        do { try input.write(contentsOf: data); return true } catch { inputOpen = false; return false }
    }

    func closeInput() {
        lock.lock(); defer { lock.unlock() }
        if inputOpen { inputOpen = false; try? input.close() }
    }

    func saw(_ json: [String: Any]) {
        guard !answered, json["parent_tool_use_id"] == nil || json["parent_tool_use_id"] is NSNull else { return }
        let content = (json["message"] as? [String: Any])?["content"]
        switch json["type"] as? String {
        case "assistant":
            let started = (content as? [[String: Any]] ?? []).filter { $0["type"] as? String == "tool_use" }.compactMap { $0["id"] as? String }
            guard !started.isEmpty else { return }
            running.formUnion(started)
            channel.tools { [weak self] text in SteerLink.line(text).map { self?.write($0) ?? false } ?? false }
        case "user":
            if json["isReplay"] as? Bool == true {
                let text = (content as? String) ?? (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
                channel.read(text)
                return
            }
            for block in content as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
                if let id = block["tool_use_id"] as? String { running.remove(id) }
            }
            if running.isEmpty { channel.tools(nil) }
        case "result":
            // The answer is done. A message written but not read would become a second answer: end the call instead,
            // so it goes back to the caller (detach) and is sent as the next message.
            answered = true
            channel.tools(nil)
            if channel.unread { cutOff = true; closeInput(); end() } else { closeInput() }
        default: break
        }
    }
}
