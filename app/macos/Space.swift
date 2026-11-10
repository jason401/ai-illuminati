import Foundation

// A chat's Space: one goal and a structured result kept beside the chat (checklists, tables, kanban, a decision log).
// It lives next to the chat folder, not in it (<room>.work/space.json), so an AI cannot write it; an AI changes it only
// with a <space-patch base=N> block at the end of a reply, which the app checks. A patch made on an older version,
// or one that touches something the user changed (userLocked), becomes a proposal the user accepts or rejects, whole.
// Every change keeps the version before it (history, in the same file) for Undo. Only the main thread changes it.

enum SpaceKind: String, Codable, CaseIterable { case checklist, table, kanban, decisionLog }

struct SpaceItem: Codable, Equatable, Identifiable {
    var id: String
    var text: String = ""
    var done: Bool?            // checklist
    var cells: [String]?       // table: one per column
    var lane: String?          // kanban: one of the block's columns
    var open: Bool?            // decisionLog: still to decide (else decided)
    var pro: [String]?         // decisionLog: the AIs for it …
    var con: [String]?         // … and against
    var source: String?        // decisionLog: where it came from (a meeting's turn)
    var status: String?        // decisionLog: "proposed" (an AI's summary) or "confirmed" (the user's decision)
    var todo: String?          // links, navigation only: a TODO …
    var chat: String?          // … or a chat
    var userLocked: Bool?      // the user changed it: an AI patch cannot
    var locked: Bool { userLocked == true }
    var confirmed: Bool { status == "confirmed" }
}

struct SpaceBlock: Codable, Equatable, Identifiable {
    var id: String
    var kind: SpaceKind
    var title: String
    var columns: [String]?     // table headers, kanban lanes
    var items: [SpaceItem]
    var userLocked: Bool?      // the user renamed it
    var locked: Bool { userLocked == true || items.contains(where: \.locked) }
}

struct SpaceContent: Codable, Equatable {
    var title: String
    var goal: String
    var blocks: [SpaceBlock]
    var userLocked: Bool?      // the user edited the title or goal
}

// One change of a patch, already checked against the schema (SpacePatch.parse).
struct SpaceOp: Codable, Equatable {
    enum Kind: String, Codable { case add, update, remove, setStatus }
    var op: Kind
    var target: String?        // add: the block `item` goes in; update/remove/setStatus: an item, a block or "space"
    var item: SpaceItem?
    var block: SpaceBlock?
    var set: SpaceFields?
    var status: String?
}

struct SpaceFields: Codable, Equatable {
    var title, goal, text, source, todo, chat: String?
    var columns, cells, pro, con: [String]?
}

struct SpaceProposal: Codable, Equatable, Identifiable {
    var id: String
    var by: String
    var base: Int
    var reason: String
    var ops: [SpaceOp]
    var at: Date
}

struct SpaceSnapshot: Codable, Equatable {
    var version: Int
    var content: SpaceContent
    var note: String
    var at: Date
}

struct SpaceDoc: Codable, Equatable {
    var version: Int
    var title: String
    var goal: String
    var blocks: [SpaceBlock]
    var userLocked: Bool?
    var updatedAt: Date
    var nextID = 0                     // ids are never reused, so an old patch cannot hit a newer item
    var proposals: [SpaceProposal] = []
    var notices: [String] = []         // patches that were dropped, and why
    var history: [SpaceSnapshot] = []  // the versions before, newest last
    var applied: [String] = []         // the answers whose patch was handled (one answer is not applied twice)

    static let historyLimit = 30, noticeLimit = 5, proposalLimit = 10, appliedLimit = 50

    static func new(title: String, goal: String, now: Date = Date()) -> SpaceDoc {
        SpaceDoc(version: 1, title: String(title.prefix(SpacePatch.textLimit)), goal: String(goal.prefix(SpacePatch.textLimit)), blocks: [], updatedAt: now)
    }

    var content: SpaceContent {
        get { SpaceContent(title: title, goal: goal, blocks: blocks, userLocked: userLocked) }
        set { title = newValue.title; goal = newValue.goal; blocks = newValue.blocks; userLocked = newValue.userLocked }
    }

    mutating func newID(_ prefix: String) -> String { nextID += 1; return prefix + String(nextID) }

    // Makes `content` the current version, keeping the one before for Undo. Nothing changes when it is the same.
    mutating func commit(_ next: SpaceContent, note: String, now: Date = Date()) {
        guard next != content else { return }
        history.append(SpaceSnapshot(version: version, content: content, note: note, at: now))
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        content = next; version += 1; updatedAt = now
    }

    // Back to the version before the last change. The number still goes up, so a patch made on the undone version
    // (or the restored one) is a proposal, never applied unseen.
    @discardableResult mutating func undo(now: Date = Date()) -> Bool {
        guard let last = history.popLast() else { return false }
        content = last.content; version += 1; updatedAt = now
        return true
    }

    mutating func notice(_ text: String) {
        notices.append(text)
        if notices.count > Self.noticeLimit { notices.removeFirst(notices.count - Self.noticeLimit) }
    }

    func find(_ id: String) -> (block: Int, item: Int?)? {
        for (b, block) in blocks.enumerated() {
            if block.id == id { return (b, nil) }
            if let i = block.items.firstIndex(where: { $0.id == id }) { return (b, i) }
        }
        return nil
    }

    // New blocks (from a meeting, or the user): fresh ids for them and their items.
    mutating func withIDs(_ added: [SpaceBlock]) -> [SpaceBlock] {
        added.map { block in
            var block = block
            block.id = newID("b")
            block.items = block.items.map { var item = $0; item.id = newID("i"); return item }
            return block
        }
    }
}

// The user's own changes: each marks what it touched userLocked, so an AI patch cannot undo it unseen.
extension SpaceDoc {
    mutating func userChange(_ id: String, note: String = L("직접 수정", "Edited"), _ body: (inout SpaceItem, SpaceBlock) -> Void) {
        guard let at = find(id), let i = at.item else { return }
        var next = content
        body(&next.blocks[at.block].items[i], next.blocks[at.block])
        next.blocks[at.block].items[i].userLocked = true
        commit(next, note: note)
    }

    // A line typed under a block (table cells split by "|"). A decision the user writes is theirs: confirmed.
    @discardableResult mutating func userAdd(_ text: String, to blockID: String) -> Bool {
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SpacePatch.textLimit))
        guard !text.isEmpty, let at = find(blockID), at.item == nil, blocks[at.block].items.count < SpacePatch.itemLimit else { return false }
        let block = blocks[at.block]
        var item = SpaceItem(id: "", text: text, userLocked: true)
        if block.kind == .table { item.cells = text.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }; item.text = "" }
        if block.kind == .decisionLog { item.status = "confirmed" }
        guard var fitted = try? SpacePatch.fitted(item, in: block, id: newID("i")) else { return false }
        fitted.status = item.status
        var next = content
        next.blocks[at.block].items.append(fitted)
        commit(next, note: L("항목 추가", "Added an item"))
        return true
    }

    @discardableResult mutating func userAddBlock(_ kind: SpaceKind, title: String) -> Bool {
        guard blocks.count < SpacePatch.blockLimit else { return false }
        let columns: [String]? = kind == .table ? [L("항목", "Item"), L("내용", "Details")]
            : kind == .kanban ? [L("할 일", "To do"), L("하는 중", "Doing"), L("끝", "Done")] : nil
        var next = content
        next.blocks.append(SpaceBlock(id: newID("b"), kind: kind, title: title, columns: columns, items: [], userLocked: true))
        commit(next, note: L("블록 추가", "Added a block"))
        return true
    }
}

enum SpacePatch {
    static let openTag = "<space-patch", closeTag = "</space-patch>"
    static let rawLimit = 20_000, opLimit = 50, textLimit = 500, blockLimit = 12, itemLimit = 200, columnLimit = 8, nameLimit = 12
    static let promptLimit = 6_000

    struct Raw: Equatable {
        var header: String     // what follows "<space-patch" up to ">", e.g. " base=3"
        var body: String?      // nil: not closed
        var count: Int         // blocks in the reply (only one is allowed)
    }

    struct Bad: Error { let reason: String }

    // The reply without its <space-patch> blocks (also one still being written), and the block.
    static func split(_ text: String) -> (reply: String, raw: Raw?) {
        var rest = Substring(text), kept = "", raw: Raw?
        var count = 0
        while let start = rest.range(of: openTag) {
            kept += rest[..<start.lowerBound]
            count += 1
            let after = rest[start.upperBound...]
            guard let headerEnd = after.firstIndex(of: ">") else { raw = Raw(header: String(after), body: nil, count: count); rest = ""; break }
            let inside = after[after.index(after: headerEnd)...]
            guard let end = inside.range(of: closeTag) else { raw = Raw(header: String(after[..<headerEnd]), body: nil, count: count); rest = ""; break }
            raw = Raw(header: String(after[..<headerEnd]), body: String(inside[..<end.lowerBound]), count: count)
            rest = inside[end.upperBound...]
        }
        kept += rest
        // A tag still arriving at the end of a streamed reply ("<space-pa…") is not shown either.
        if let lt = kept.range(of: "<", options: .backwards) {
            let tail = kept[lt.lowerBound...]
            if tail.count >= 2 && openTag.hasPrefix(tail) { kept = String(kept[..<lt.lowerBound]); if raw == nil { return (kept.trimmingCharacters(in: .whitespacesAndNewlines), nil) } }
        }
        guard var found = raw else { return (text, nil) }
        found.count = count
        return (kept.trimmingCharacters(in: .whitespacesAndNewlines), found)
    }

    // The block's base version and its changes, or why it was dropped. Only what the schema allows passes.
    static func parse(_ raw: Raw) -> Result<(base: Int, ops: [SpaceOp]), Bad> {
        do {
            guard raw.count == 1 else { throw Bad(reason: L("변경 블록이 \(raw.count)개예요 (하나만 돼요)", "\(raw.count) patch blocks (only one is allowed)")) }
            guard var body = raw.body else { throw Bad(reason: L("변경 블록이 닫히지 않았어요", "The patch block is not closed")) }
            guard let match = raw.header.range(of: #"^\s*base\s*=\s*"?(\d{1,9})"?\s*$"#, options: .regularExpression),
                  let base = Int(raw.header[match].filter(\.isNumber)) else { throw Bad(reason: L("base 버전이 없어요", "No base version")) }
            guard body.count <= rawLimit else { throw Bad(reason: L("변경 블록이 너무 길어요", "The patch block is too long")) }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasPrefix("```") {   // a fenced block: its JSON
                body = body.components(separatedBy: .newlines).dropFirst().filter { !$0.hasPrefix("```") }.joined(separator: "\n")
            }
            guard let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else {
                throw Bad(reason: L("JSON이 아니에요", "Not JSON"))
            }
            let list: Any?
            if let object = json as? [String: Any] {
                guard Set(object.keys) == ["ops"] else { throw Bad(reason: L("\"ops\" 말고 다른 키가 있어요", "Keys other than \"ops\"")) }
                list = object["ops"]
            } else { list = json }
            guard let entries = list as? [Any], !entries.isEmpty else { throw Bad(reason: L("변경(ops)이 없어요", "No ops")) }
            guard entries.count <= opLimit else { throw Bad(reason: L("변경이 \(opLimit)개를 넘어요", "More than \(opLimit) ops")) }
            return .success((base, try entries.enumerated().map { try op($0.element, number: $0.offset + 1) }))
        } catch let bad as Bad {
            return .failure(bad)
        } catch {
            return .failure(Bad(reason: error.localizedDescription))
        }
    }

    private static func op(_ value: Any, number: Int) throws -> SpaceOp {
        func bad(_ ko: String, _ en: String) -> Bad { Bad(reason: L("\(number)번째 변경: ", "Op \(number): ") + L(ko, en)) }
        guard let dict = value as? [String: Any], let name = dict["op"] as? String, let kind = SpaceOp.Kind(rawValue: name) else {
            throw bad("op는 add, update, remove, setStatus 중 하나예요", "op must be add, update, remove or setStatus")
        }
        func only(_ keys: Set<String>) throws {
            let extra = Set(dict.keys).subtracting(keys).sorted()
            if !extra.isEmpty { throw bad("모르는 키 " + extra.joined(separator: ", "), "unknown keys " + extra.joined(separator: ", ")) }
        }
        func id(_ key: String) throws -> String {
            guard let text = dict[key] as? String, !text.isEmpty, text.count <= 40 else { throw bad("\(key)가 없어요", "missing \(key)") }
            return text
        }
        do {
            switch kind {
            case .add:
                if let block = dict["block"] {
                    try only(["op", "block"])
                    return SpaceOp(op: .add, block: try Self.block(block))
                }
                try only(["op", "to", "item"])
                guard let item = dict["item"] else { throw bad("item이나 block이 없어요", "missing item or block") }
                return SpaceOp(op: .add, target: try id("to"), item: try Self.item(item))
            case .update:
                try only(["op", "id", "set"])
                return SpaceOp(op: .update, target: try id("id"), set: try fields(dict["set"]))
            case .remove:
                try only(["op", "id"])
                return SpaceOp(op: .remove, target: try id("id"))
            case .setStatus:
                try only(["op", "id", "status"])
                guard let status = dict["status"] as? String, !status.isEmpty, status.count <= 60 else { throw bad("status가 없어요", "missing status") }
                guard status != "confirmed" else { throw bad("확정은 사용자만 해요", "only the user confirms") }
                return SpaceOp(op: .setStatus, target: try id("id"), status: status)
            }
        } catch let inner as Bad where !inner.reason.hasPrefix(L("\(number)번째", "Op \(number)")) {
            throw bad(inner.reason, inner.reason)
        }
    }

    private static func text(_ value: Any?, _ key: String, limit: Int = textLimit) throws -> String? {
        guard let value else { return nil }
        guard let text = value as? String else { throw Bad(reason: L("\(key)는 글이어야 해요", "\(key) must be text")) }
        guard text.count <= limit else { throw Bad(reason: L("\(key)가 \(limit)자를 넘어요", "\(key) is over \(limit) characters")) }
        return text
    }

    private static func texts(_ value: Any?, _ key: String, most: Int) throws -> [String]? {
        guard let value else { return nil }
        guard let list = value as? [Any], list.count <= most else { throw Bad(reason: L("\(key)는 \(most)개까지의 글 목록이에요", "\(key) must be a list of at most \(most) texts")) }
        return try list.map { try text($0, key) ?? "" }
    }

    private static func link(_ value: Any?, _ key: String) throws -> String? {
        guard let value else { return nil }
        guard let text = value as? String, UUID(uuidString: text) != nil else { throw Bad(reason: L("\(key)는 UUID여야 해요", "\(key) must be a UUID")) }
        return text
    }

    private static func flag(_ value: Any?, _ key: String) throws -> Bool? {
        guard let value else { return nil }
        // JSONSerialization gives numbers for true/false too: only real booleans pass.
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw Bad(reason: L("\(key)는 true/false예요", "\(key) must be true or false")) }
        return number.boolValue
    }

    static func item(_ value: Any) throws -> SpaceItem {
        guard let dict = value as? [String: Any] else { throw Bad(reason: L("item은 객체여야 해요", "item must be an object")) }
        let allowed: Set<String> = ["id", "text", "done", "cells", "lane", "open", "pro", "con", "source", "status", "todo", "chat"]
        let extra = Set(dict.keys).subtracting(allowed).sorted()
        if !extra.isEmpty { throw Bad(reason: L("item의 모르는 키 ", "unknown item keys ") + extra.joined(separator: ", ")) }
        if let status = dict["status"] { guard status as? String == "proposed" else { throw Bad(reason: L("item status는 proposed만 돼요", "item status may only be proposed")) } }
        // The app gives the id.
        return SpaceItem(id: "", text: try text(dict["text"], "text") ?? "", done: try flag(dict["done"], "done"),
                         cells: try texts(dict["cells"], "cells", most: columnLimit), lane: try text(dict["lane"], "lane", limit: 60),
                         open: try flag(dict["open"], "open"), pro: try texts(dict["pro"], "pro", most: nameLimit),
                         con: try texts(dict["con"], "con", most: nameLimit), source: try text(dict["source"], "source"),
                         todo: try link(dict["todo"], "todo"), chat: try link(dict["chat"], "chat"))
    }

    static func block(_ value: Any) throws -> SpaceBlock {
        guard let dict = value as? [String: Any] else { throw Bad(reason: L("block은 객체여야 해요", "block must be an object")) }
        let extra = Set(dict.keys).subtracting(["id", "kind", "title", "columns", "items"]).sorted()
        if !extra.isEmpty { throw Bad(reason: L("block의 모르는 키 ", "unknown block keys ") + extra.joined(separator: ", ")) }
        guard let name = dict["kind"] as? String, let kind = SpaceKind(rawValue: name) else {
            throw Bad(reason: L("kind는 checklist, table, kanban, decisionLog 중 하나예요", "kind must be checklist, table, kanban or decisionLog"))
        }
        var items: [Any] = []
        if let value = dict["items"] {
            guard let list = value as? [Any], list.count <= itemLimit else { throw Bad(reason: L("items는 \(itemLimit)개까지의 목록이에요", "items must be a list of at most \(itemLimit)")) }
            items = list
        }
        return SpaceBlock(id: "", kind: kind, title: try text(dict["title"], "title", limit: 120) ?? "",
                          columns: try texts(dict["columns"], "columns", most: columnLimit), items: try items.map(item))
    }

    private static func fields(_ value: Any?) throws -> SpaceFields {
        guard let dict = value as? [String: Any], !dict.isEmpty else { throw Bad(reason: L("set이 없어요", "missing set")) }
        let extra = Set(dict.keys).subtracting(["title", "goal", "text", "source", "todo", "chat", "columns", "cells", "pro", "con"]).sorted()
        if !extra.isEmpty { throw Bad(reason: L("set의 모르는 키 ", "unknown set keys ") + extra.joined(separator: ", ")) }
        return SpaceFields(title: try text(dict["title"], "title", limit: 120), goal: try text(dict["goal"], "goal"), text: try text(dict["text"], "text"),
                           source: try text(dict["source"], "source"), todo: try link(dict["todo"], "todo"), chat: try link(dict["chat"], "chat"),
                           columns: try texts(dict["columns"], "columns", most: columnLimit), cells: try texts(dict["cells"], "cells", most: columnLimit),
                           pro: try texts(dict["pro"], "pro", most: nameLimit), con: try texts(dict["con"], "con", most: nameLimit))
    }

    // Would any change reach what the user changed (an item, a renamed block, the title or goal)?
    static func touchesLocked(_ ops: [SpaceOp], _ doc: SpaceDoc) -> Bool {
        ops.contains { op in
            guard op.op != .add, let target = op.target else { return false }
            if target == "space" { return doc.userLocked == true }
            guard let at = doc.find(target) else { return false }
            let block = doc.blocks[at.block]
            if let i = at.item { return block.items[i].locked }
            switch op.op {
            case .remove: return block.locked
            case .update: return (block.userLocked == true && op.set?.title != nil) || (op.set?.columns != nil && block.items.contains(where: \.locked))
            default: return false
            }
        }
    }

    // A checked item for `block`: fields of other kinds are left out, the ones it needs are there.
    static func fitted(_ item: SpaceItem, in block: SpaceBlock, id: String) throws -> SpaceItem {
        var out = SpaceItem(id: id, text: item.text, todo: item.todo, chat: item.chat, userLocked: item.userLocked)
        switch block.kind {
        case .checklist: out.done = item.done ?? false
        case .table:
            let columns = block.columns?.count ?? 0
            var cells = item.cells ?? (item.text.isEmpty ? [] : [item.text])
            guard !cells.isEmpty, cells.count <= columns else { throw Bad(reason: L("표 줄의 칸(cells)은 1~\(columns)개예요", "a table row needs 1 to \(columns) cells")) }
            cells += Array(repeating: "", count: columns - cells.count)
            out.cells = cells; out.text = ""
        case .kanban:
            let lanes = block.columns ?? []
            let lane = item.lane ?? lanes.first ?? ""
            guard lanes.contains(lane) else { throw Bad(reason: L("없는 칸반 열 ", "unknown kanban lane ") + lane) }
            out.lane = lane
        case .decisionLog:
            out.open = item.open ?? false; out.pro = item.pro; out.con = item.con; out.source = item.source
            out.status = item.status == "confirmed" ? "confirmed" : "proposed"
        }
        if block.kind != .table && out.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw Bad(reason: L("항목 글(text)이 비었어요", "the item has no text")) }
        return out
    }

    // The patch applied to a copy, all or nothing; an error says why. Locks are checked before (touchesLocked).
    static func apply(_ ops: [SpaceOp], to doc: SpaceDoc) throws -> SpaceDoc {
        var d = doc
        func missing(_ id: String) -> Bad { Bad(reason: L("없는 id ", "unknown id ") + id) }
        for op in ops {
            switch op.op {
            case .add:
                if var block = op.block {
                    guard d.blocks.count < blockLimit else { throw Bad(reason: L("블록은 \(blockLimit)개까지예요", "at most \(blockLimit) blocks")) }
                    if [.table, .kanban].contains(block.kind) {
                        guard let columns = block.columns, !columns.isEmpty, !columns.contains(where: { $0.isEmpty }) else { throw Bad(reason: L("표·칸반은 열(columns)이 필요해요", "a table or kanban needs columns")) }
                        guard Set(columns).count == columns.count else { throw Bad(reason: L("열 이름이 겹쳐요", "duplicate columns")) }
                    } else { block.columns = nil }
                    block.id = d.newID("b"); block.userLocked = nil
                    let shape = block
                    block.items = try block.items.map { try fitted($0, in: shape, id: d.newID("i")) }
                    d.blocks.append(block)
                } else if let item = op.item, let to = op.target {
                    guard let at = d.find(to), at.item == nil else { throw missing(to) }
                    guard d.blocks[at.block].items.count < itemLimit else { throw Bad(reason: L("블록 항목은 \(itemLimit)개까지예요", "at most \(itemLimit) items in a block")) }
                    let fresh = try fitted(item, in: d.blocks[at.block], id: d.newID("i"))
                    d.blocks[at.block].items.append(fresh)
                }
            case .update:
                guard let target = op.target, let set = op.set else { continue }
                if target == "space" {
                    guard set == SpaceFields(title: set.title, goal: set.goal) else { throw Bad(reason: L("Space에는 title, goal만 바꿀 수 있어요", "only title and goal can change on the Space")) }
                    if let title = set.title { d.title = String(title.prefix(120)) }
                    if let goal = set.goal { d.goal = goal }
                    continue
                }
                guard let at = d.find(target) else { throw missing(target) }
                if let i = at.item {
                    guard set.title == nil, set.goal == nil, set.columns == nil else { throw Bad(reason: L("항목에는 text, cells, pro, con, source, todo, chat만 바꿀 수 있어요", "items only take text, cells, pro, con, source, todo and chat")) }
                    let block = d.blocks[at.block]
                    var item = block.items[i]
                    if let text = set.text { item.text = text }
                    if let cells = set.cells { item.cells = cells }
                    if let pro = set.pro { item.pro = pro }
                    if let con = set.con { item.con = con }
                    if let source = set.source { item.source = source }
                    if let todo = set.todo { item.todo = todo }
                    if let chat = set.chat { item.chat = chat }
                    d.blocks[at.block].items[i] = try fitted(item, in: block, id: item.id)
                } else {
                    guard set == SpaceFields(title: set.title, columns: set.columns) else { throw Bad(reason: L("블록에는 title, columns만 바꿀 수 있어요", "blocks only take title and columns")) }
                    if let title = set.title { d.blocks[at.block].title = String(title.prefix(120)) }
                    if let columns = set.columns {
                        var block = d.blocks[at.block]
                        guard [.table, .kanban].contains(block.kind), !columns.isEmpty, Set(columns).count == columns.count, !columns.contains(where: { $0.isEmpty }) else {
                            throw Bad(reason: L("열은 표·칸반에만, 겹치지 않게", "columns only on tables and kanbans, without duplicates"))
                        }
                        for (i, item) in block.items.enumerated() {
                            if block.kind == .kanban {
                                guard columns.contains(item.lane ?? "") else { throw Bad(reason: L("항목이 있는 칸반 열은 지울 수 없어요", "a kanban lane with items cannot go")) }
                            } else {
                                let cells = item.cells ?? []
                                guard !cells.dropFirst(columns.count).contains(where: { !$0.isEmpty }) else { throw Bad(reason: L("내용이 있는 표 열은 지울 수 없어요", "a table column with content cannot go")) }
                                block.items[i].cells = Array(cells.prefix(columns.count)) + Array(repeating: "", count: max(0, columns.count - cells.count))
                            }
                        }
                        block.columns = columns
                        d.blocks[at.block] = block
                    }
                }
            case .remove:
                guard let target = op.target, let at = d.find(target) else { throw missing(op.target ?? "") }
                if let i = at.item { d.blocks[at.block].items.remove(at: i) } else { d.blocks.remove(at: at.block) }
            case .setStatus:
                guard let target = op.target, let status = op.status, let at = d.find(target), let i = at.item else { throw missing(op.target ?? "") }
                let block = d.blocks[at.block]
                switch (block.kind, status) {
                case (.checklist, "done"), (.checklist, "todo"): d.blocks[at.block].items[i].done = status == "done"
                case (.decisionLog, "open"), (.decisionLog, "decided"): d.blocks[at.block].items[i].open = status == "open"
                case (.kanban, _) where block.columns?.contains(status) == true: d.blocks[at.block].items[i].lane = status
                default: throw Bad(reason: L("\(block.kind.rawValue)에 맞지 않는 status ", "status not valid for \(block.kind.rawValue): ") + status)
                }
            }
        }
        return d
    }

    enum Outcome: Equatable { case applied, proposed, dropped(String), duplicate }

    // An AI's patch from answer `key`: applied, kept as a proposal, or dropped with the reason in the notices.
    @discardableResult
    static func receive(_ raw: Raw, by: String, key: String, into doc: inout SpaceDoc, now: Date = Date()) -> Outcome {
        guard !doc.applied.contains(key) else { return .duplicate }
        doc.applied.append(key)
        if doc.applied.count > SpaceDoc.appliedLimit { doc.applied.removeFirst(doc.applied.count - SpaceDoc.appliedLimit) }
        let parsed: (base: Int, ops: [SpaceOp])
        switch parse(raw) {
        case .failure(let bad):
            doc.notice(L("\(by)의 변경을 버렸어요: ", "Dropped \(by)'s change: ") + bad.reason)
            return .dropped(bad.reason)
        case .success(let ok): parsed = ok
        }
        func propose(_ reason: String) -> Outcome {
            doc.proposals.append(SpaceProposal(id: UUID().uuidString, by: by, base: parsed.base, reason: reason, ops: parsed.ops, at: now))
            if doc.proposals.count > SpaceDoc.proposalLimit { doc.proposals.removeFirst(doc.proposals.count - SpaceDoc.proposalLimit) }
            return .proposed
        }
        if parsed.base != doc.version {
            return propose(L("버전 \(parsed.base)을 보고 만든 변경이에요 (지금은 \(doc.version))", "Made on version \(parsed.base) (now \(doc.version))"))
        }
        if touchesLocked(parsed.ops, doc) { return propose(L("내가 고친 항목을 바꾸려 해요", "It changes items you edited")) }
        do {
            let next = try apply(parsed.ops, to: doc)
            doc.nextID = next.nextID
            doc.commit(next.content, note: by, now: now)
            return .applied
        } catch {
            let reason = (error as? Bad)?.reason ?? error.localizedDescription
            doc.notice(L("\(by)의 변경을 버렸어요: ", "Dropped \(by)'s change: ") + reason)
            return .dropped(reason)
        }
    }

    // The user accepts a proposal: all of it on the current version (locks stay), or nothing with the reason.
    static func accept(_ id: String, in doc: inout SpaceDoc, now: Date = Date()) -> Bool {
        guard let index = doc.proposals.firstIndex(where: { $0.id == id }) else { return false }
        let proposal = doc.proposals[index]
        do {
            let next = try apply(proposal.ops, to: doc)
            doc.proposals.remove(at: index)
            doc.nextID = next.nextID
            doc.commit(next.content, note: L("변경안 수락 · ", "Accepted · ") + proposal.by, now: now)
            return true
        } catch {
            doc.notice(L("변경안을 적용하지 못했어요: ", "Could not apply the proposal: ") + ((error as? Bad)?.reason ?? error.localizedDescription))
            return false
        }
    }

    // One line per change, for the proposal card.
    static func describe(_ op: SpaceOp, in doc: SpaceDoc) -> String {
        func name(_ id: String?) -> String {
            guard let id else { return "?" }
            if id == "space" { return L("Space", "the Space") }
            guard let at = doc.find(id) else { return id + L(" (없어짐)", " (gone)") }
            let block = doc.blocks[at.block]
            guard let i = at.item else { return "“\(block.title)”" }
            let item = block.items[i]
            return "“" + String((item.text.isEmpty ? (item.cells ?? []).joined(separator: " | ") : item.text).prefix(40)) + "”" + (item.locked ? " 🔒" : "")
        }
        switch op.op {
        case .add:
            if let block = op.block { return L("블록 추가: ", "Add block: ") + block.title + " (\(block.kind.rawValue), \(block.items.count))" }
            return L("추가 → ", "Add → ") + name(op.target) + ": " + String((op.item?.text ?? op.item?.cells?.joined(separator: " | ") ?? "").prefix(60))
        case .update:
            let set = op.set
            let value = [set?.title, set?.goal, set?.text, set?.cells?.joined(separator: " | "), set?.columns?.joined(separator: " | ")].compactMap { $0 }.first ?? ""
            return L("수정: ", "Edit: ") + name(op.target) + (value.isEmpty ? "" : " → " + String(value.prefix(60)))
        case .remove: return L("삭제: ", "Remove: ") + name(op.target)
        case .setStatus: return L("상태: ", "Status: ") + name(op.target) + " → " + (op.status ?? "")
        }
    }

    // What an answer reads: the Space with its ids, and how to change it. About `promptLimit` characters at most.
    static func rule(_ doc: SpaceDoc) -> String {
        var lines = ["Title: " + doc.title + (doc.userLocked == true ? " (locked)" : ""), "Goal: " + doc.goal]
        for block in doc.blocks {
            lines.append("## \(block.id) \(block.kind.rawValue) \"\(block.title)\"" + (block.columns.map { " columns: " + $0.joined(separator: " | ") } ?? "") + (block.userLocked == true ? " (locked)" : ""))
            for item in block.items {
                var line = "- \(item.id) "
                switch block.kind {
                case .checklist: line += (item.done == true ? "[x] " : "[ ] ") + item.text
                case .table: line += (item.cells ?? []).joined(separator: " | ")
                case .kanban: line += "[\(item.lane ?? "")] " + item.text
                case .decisionLog:
                    line += (item.open == true ? "open" : "decided") + " · " + (item.confirmed ? "confirmed by user" : "proposed") + " · " + item.text
                    if let pro = item.pro, !pro.isEmpty { line += " · pro: " + pro.joined(separator: ", ") }
                    if let con = item.con, !con.isEmpty { line += " · con: " + con.joined(separator: ", ") }
                    if let source = item.source, !source.isEmpty { line += " · source: " + source }
                }
                if item.locked { line += " (locked)" }
                lines.append(line)
            }
        }
        var board = ""
        for line in lines {
            if board.count + line.count + 1 > promptLimit { board += "… (cut: the Space is longer)\n"; break }
            board += line + "\n"
        }
        return """
            [Space]
            This chat has a Space (version \(doc.version)): a board the user keeps beside the chat. Only the app writes it.
            When the user asks, or your reply settles something it tracks, change it with ONE block at the very end of your
            reply (the user does not see it); otherwise add none. JSON only, in the user's language:
            <space-patch base=\(doc.version)>{"ops":[…]}</space-patch>
            Ops: {"op":"add","to":"<block id>","item":{"text":"…"}} · {"op":"add","block":{"kind":"checklist|table|kanban|decisionLog","title":"…","columns":["…"],"items":[…]}}
            · {"op":"update","id":"<item id>","set":{"text":"…"}} (items: text, cells, pro, con, source, todo, chat; blocks: title, columns; "space": title, goal)
            · {"op":"remove","id":"<id>"} · {"op":"setStatus","id":"<item id>","status":"done|todo (checklist), open|decided (decisionLog), a lane (kanban)"}
            Item fields: checklist text, done; table cells (one per column); kanban text, lane; decisionLog text, open, pro/con (AI names), source.
            Never set "confirmed" or ids: only the user confirms a decision, the app gives ids. Items marked (locked) were changed by
            the user: a patch touching them, or one made on an older version, becomes a proposal the user must accept.
            TODOs are not Space items: link one with "todo":"<TODO id>" instead.
            \(board)[End of the Space]
            """
    }

    // A meeting's result (Discussion.meetingFinal headings) as a decision log and its next steps. Ids are given later.
    static func meetingBlocks(_ result: String, title: String, source: String, chat: UUID?) -> [SpaceBlock] {
        enum Part { case conclusion, reasons, agreed, disputed, decide, next }
        let heads: [(Part, [String])] = [
            (.decide, ["네 결정이 필요한 것", "결정이 필요한 것", "결정 필요", "needs your decision"]), (.conclusion, ["결론", "conclusion"]),
            (.reasons, ["근거", "reasons"]), (.agreed, ["합의", "agreed", "agreement"]),
            (.disputed, ["이견", "disagreements", "disagreement"]), (.next, ["다음 행동", "next steps", "next step"])]
        func heading(_ name: String) -> Part? {
            let name = name.lowercased()
            return heads.first { entry in entry.1.contains { head in name == head || name.hasPrefix(head + " ") || name.hasPrefix(head + "(") } }?.0
        }
        func clean(_ text: String) -> String {
            String(text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
                .trimmingCharacters(in: .whitespaces).prefix(textLimit))
        }
        var part: Part?, found: [Part: [String]] = [:]
        for line in result.components(separatedBy: .newlines) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, s != "---" else { continue }
            let bullet = s.range(of: #"^([-*•]|\d+[.)])\s+"#, options: .regularExpression)
            if bullet == nil {
                // "## 결론", "**합의**", "결론: …" (a heading with its first point after the colon)
                let head = clean(s.replacingOccurrences(of: #"^[#>\s]+"#, with: "", options: .regularExpression))
                let pieces = head.split(maxSplits: 1, whereSeparator: { $0 == ":" || $0 == "：" })
                if let first = pieces.first, let next = heading(first.trimmingCharacters(in: .whitespaces)) {
                    part = next
                    if pieces.count > 1 { let rest = clean(String(pieces[1])); if !rest.isEmpty { found[next, default: []].append(rest) } }
                    continue
                }
            }
            guard let part else { continue }
            let text = clean(bullet.map { String(s[$0.upperBound...]) } ?? s)
            if !text.isEmpty { found[part, default: []].append(text) }
        }
        let link = chat?.uuidString
        func decision(_ text: String, open: Bool) -> SpaceItem {
            SpaceItem(id: "", text: text, open: open, source: source, status: "proposed", chat: link)
        }
        var items = (found[.conclusion] ?? []).map { decision($0, open: false) } + (found[.agreed] ?? []).map { decision($0, open: false) }
        items += (found[.disputed] ?? []).map { decision(L("이견: ", "Disagreement: ") + $0, open: true) }
        items += (found[.decide] ?? []).map { decision($0, open: true) }
        if items.isEmpty, let first = result.components(separatedBy: "\n\n").map(clean).first(where: { !$0.isEmpty }) {
            items = [decision(first, open: false)]
        }
        var blocks = [SpaceBlock(id: "", kind: .decisionLog, title: title, items: Array(items.prefix(itemLimit)))]
        let next = (found[.next] ?? []).prefix(itemLimit).map { SpaceItem(id: "", text: $0, done: false) }
        if !next.isEmpty { blocks.append(SpaceBlock(id: "", kind: .checklist, title: L("다음 행동", "Next steps"), items: Array(next))) }
        return blocks
    }
}

// The Spaces on disk and the open one. Every change runs on the main thread, in order: an answer finishing on
// another thread hands its patch over (deliver) with the room it was asked in.
final class SpaceStore: ObservableObject {
    static let shared = SpaceStore()
    @Published private(set) var room: UUID?
    @Published private(set) var doc: SpaceDoc?
    @Published private(set) var broken = false            // space.json is there but cannot be read: nothing overwrites it
    @Published private(set) var titles: [UUID: String] = [:]   // every chat with a Space (the sidebar's Spaces)

    static func file(_ room: UUID) -> URL {
        URL(fileURLWithPath: ChatStore.dir).appendingPathComponent("\(room.uuidString).work/space.json")
    }

    enum Loaded: Equatable { case none, doc(SpaceDoc), broken }

    static func load(_ room: UUID) -> Loaded {
        guard let data = try? Data(contentsOf: file(room)) else {
            return FileManager.default.fileExists(atPath: file(room).path) ? .broken : .none
        }
        let decoder = JSONDecoder()
        return (try? decoder.decode(SpaceDoc.self, from: data)).map { .doc($0) } ?? .broken
    }

    static func save(_ doc: SpaceDoc, room: UUID) -> Bool {
        let url = file(room)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(doc) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    // What an answer reads (any thread): the Space rule, or nothing when the chat has none.
    static func rule(for room: UUID) -> String {
        guard case .doc(let doc) = load(room) else { return "" }
        return SpacePatch.rule(doc)
    }

    func open(_ room: UUID) {
        self.room = room
        reload()
    }

    private func reload() {
        guard let room else { doc = nil; broken = false; return }
        switch Self.load(room) {
        case .none: doc = nil; broken = false
        case .doc(let found): doc = found; broken = false
        case .broken: doc = nil; broken = true
        }
    }

    // Reads, changes and saves chat `room`'s Space (nil: it has none yet; setting one makes it). False when it could
    // not be read or saved, or `body` changed nothing.
    @discardableResult
    func change(_ room: UUID, _ body: (inout SpaceDoc?) -> Void) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        var current: SpaceDoc?
        switch Self.load(room) {
        case .broken: return false
        case .none: current = nil
        case .doc(let found): current = found
        }
        let before = current
        body(&current)
        guard let next = current, next != before, Self.save(next, room: room) else { return false }
        titles[room] = next.title
        if room == self.room { doc = next; broken = false }
        return true
    }

    // A user's edit: the version before is kept for Undo.
    @discardableResult
    func edit(_ room: UUID, note: String = L("직접 수정", "Edited"), _ body: (inout SpaceContent) -> Void) -> Bool {
        change(room) { doc in
            guard var d = doc else { return }
            var next = d.content
            body(&next)
            d.commit(next, note: note)
            doc = d
        }
    }

    // An answer's patch, from any thread.
    static func deliver(_ raw: SpacePatch.Raw, room: UUID, by: String, key: String) {
        DispatchQueue.main.async { shared.receive(raw, room: room, by: by, key: key) }
    }

    @discardableResult
    func receive(_ raw: SpacePatch.Raw, room: UUID, by: String, key: String) -> SpacePatch.Outcome? {
        var outcome: SpacePatch.Outcome?
        change(room) { doc in
            guard var d = doc else { return }   // no Space: the AI was not told about one
            outcome = SpacePatch.receive(raw, by: by, key: key, into: &d)
            doc = d
        }
        return outcome
    }

    private var scanned = false
    func scanOnce() { if !scanned { scanned = true; scan() } }

    // The chats with a Space, read once from disk; later changes update it as they happen.
    func scan() {
        let dir = URL(fileURLWithPath: ChatStore.dir)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var found: [UUID: String] = [:]
        for name in names where name.hasSuffix(".work") {
            guard let room = UUID(uuidString: String(name.dropLast(5))), case .doc(let doc) = Self.load(room) else { continue }
            found[room] = doc.title
        }
        titles = found
    }

    // A stable key for one answer's patch (a retried answer has other text, so it is not taken for the same).
    static func key(turn: Int, by: String, raw: SpacePatch.Raw) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in ((raw.body ?? "") + raw.header).utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "\(turn)|\(by)|" + String(hash, radix: 16)
    }
}
