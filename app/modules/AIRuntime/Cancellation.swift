import Foundation
import Darwin

// One token per debate. Cancelling also interrupts every CLI currently answering
// (several run at once during the opening round).
public final class DebateCancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var processes: [Process] = []
    private var children: [DebateCancellation] = []
    public init() {}

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    // A token that stops with this one (a meeting an answer convened stops with that answer), or on its own.
    public func child() -> DebateCancellation {
        let token = DebateCancellation()
        lock.lock(); let stop = cancelled; if !stop { children.append(token) }; lock.unlock()
        if stop { token.cancel() }
        return token
    }
    public func attach(_ process: Process) {
        lock.lock(); processes.append(process); let stop = cancelled; lock.unlock()
        if stop { Self.end(process) }
    }
    public func detach(_ process: Process) { lock.lock(); processes.removeAll { $0 === process }; lock.unlock() }
    public func cancel() {
        lock.lock(); cancelled = true; let active = processes, followers = children; children = []; lock.unlock()
        followers.forEach { $0.cancel() }
        active.forEach(Self.end)
    }
    public static func end(_ process: Process) {
        if process.environment?["AI_ILLUMINATI_PROJECT_PROCESS"] == "1" { kill(-process.processIdentifier, SIGKILL) }
        guard process.isRunning else { return }
        // Stop command/MCP descendants too, before collecting the final source diff.
        // Killing only the CLI can leave a Python writer running after Stop.
        let listing = Process(), pipe = Pipe()
        listing.executableURL = URL(fileURLWithPath: "/bin/ps")
        listing.arguments = ["-axo", "pid=,ppid="]; listing.standardOutput = pipe; listing.standardError = FileHandle.nullDevice
        var children: [Int32] = []
        if (try? listing.run()) != nil {
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            listing.waitUntilExit()
            let pairs = text.split(separator: "\n").compactMap { line -> (Int32, Int32)? in
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count == 2, let pid = Int32(parts[0]), let parent = Int32(parts[1]) else { return nil }
                return (pid, parent)
            }
            var parents: Set<Int32> = [process.processIdentifier]
            while true {
                let next = pairs.filter { parents.contains($0.1) && !parents.contains($0.0) }.map { $0.0 }
                if next.isEmpty { break }
                children += next; parents.formUnion(next)
            }
        }
        for child in children.reversed() { kill(child, SIGKILL) }
        if process.isRunning { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
