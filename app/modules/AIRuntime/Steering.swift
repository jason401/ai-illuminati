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
    private(set) var results = 0         // results seen; when cut off, the answer is the one that set `answered`
    // Background agents or commands still running (their end wakes Claude again), counted two ways and the higher
    // one kept: one too many only waits longer, one too few at a cut-off would stop a running agent (end()).
    private var reported = 0             // as Claude last listed them (background_tasks_changed)
    private var pending: Set<String> = []          // tool calls started in the background, not ended yet
    private var taskTools: [String: String] = [:]  // task_id → tool_use id
    private var background: Int { max(reported, pending.count) }
    private var waiting = false          // a result came while they ran: the answer comes after they end
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
        let type = json["type"] as? String
        let content = (json["message"] as? [String: Any])?["content"]
        let blocks = content as? [[String: Any]] ?? []
        // Counted and read in every state, also while waiting: background work and replays are what Claude did.
        switch type {
        case "system": noteTask(json); return
        case "assistant":
            for block in blocks where block["type"] as? String == "tool_use"
                && (block["input"] as? [String: Any])?["run_in_background"] as? Bool == true {
                if let id = block["id"] as? String { pending.insert(id) }
            }
        case "user":
            // A message written before the input closed can be read on a wake-up after the first result.
            if json["isReplay"] as? Bool == true {
                channel.read((content as? String) ?? blocks.compactMap { $0["text"] as? String }.joined())
                return
            }
            for block in blocks where block["type"] as? String == "tool_result" && block["is_error"] as? Bool == true {
                if let id = block["tool_use_id"] as? String { pending.remove(id) }   // failed to start
            }
        default: break
        }
        // Between a result and the end of the background work Claude only reports on it: nothing is written in.
        if waiting && type != "result" { return }
        switch type {
        case "assistant":
            let started = blocks.filter { $0["type"] as? String == "tool_use" }.compactMap { $0["id"] as? String }
            guard !started.isEmpty else { return }
            running.formUnion(started)
            channel.tools { [weak self] text in SteerLink.line(text).map { self?.write($0) ?? false } ?? false }
        case "user":
            for block in blocks where block["type"] as? String == "tool_result" {
                if let id = block["tool_use_id"] as? String { running.remove(id) }
            }
            if running.isEmpty { channel.tools(nil) }
        case "result":
            results += 1
            channel.tools(nil)
            // Background agents still run: Claude wakes when each ends and writes again (the answer: answer(_:cutAt:)).
            // Ending the call now would stop them; a message not read yet goes back to the caller (detach).
            if background > 0 { waiting = true; closeInput(); return }
            // The answer is done. A message written but not read would become a second answer: end the call instead,
            // so it goes back to the caller (detach) and is sent as the next message.
            answered = true
            if channel.unread && !waiting { cutOff = true; closeInput(); end() } else { closeInput() }
        default: break
        }
    }

    // Claude's task events (Claude Code 2.1.x): started (a foreground command can move to the background), and ended.
    private func noteTask(_ json: [String: Any]) {
        let task = json["task_id"] as? String
        switch json["subtype"] as? String {
        case "background_tasks_changed": reported = (json["tasks"] as? [Any])?.count ?? 0
        case "task_started":
            guard let task, let tool = json["tool_use_id"] as? String else { return }
            taskTools[task] = tool
            if json["is_backgrounded"] as? Bool == true { pending.insert(tool) }
        case "task_notification", "task_updated":
            let status = (json["status"] as? String) ?? ((json["patch"] as? [String: Any])?["status"] as? String)
            guard let status, ["completed", "failed", "stopped", "killed"].contains(status),
                  let tool = (json["tool_use_id"] as? String) ?? task.flatMap({ taskTools[$0] }) else { return }
            pending.remove(tool)
        default: break
        }
    }

    /// The answer among one steered call's results. Cut off: the result that ended it. Otherwise Claude ran until it
    /// stopped, writing a result each time an ended background task woke it. Measured with Claude Code 2.1.x: those
    /// results come together at the end, after the tasks' events, an empty one can come first, and the last one can be
    /// a short note (a timer ended). So: the longest result written after the first (that one was written while the
    /// work still ran), and the last one after it when that came later.
    static func answer(_ results: [[String: Any]], cutAt: Int?) -> [String: Any]? {
        if let cutAt { return results.indices.contains(cutAt - 1) ? results[cutAt - 1] : results.first }
        func text(_ i: Int) -> String { ((results[i]["result"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let written = results.indices.filter { results[$0]["is_error"] as? Bool != true && !text($0).isEmpty }
        guard let last = written.last else { return results.last }
        let woke = written.contains { $0 > 0 } ? written.filter { $0 > 0 } : written
        let main = woke.dropFirst().reduce(woke[0]) { text($1).count > text($0).count ? $1 : $0 }
        guard main < last else { return results[last] }
        var joined = results[last]
        joined["result"] = text(main) + "\n\n" + text(last)
        return joined
    }
}
