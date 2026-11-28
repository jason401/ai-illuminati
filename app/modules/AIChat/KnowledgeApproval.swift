import Foundation
import AILocalization
import AIProjects

// 회의 3/3: a knowledge review's change to a 🔒 skill or to a fact the user made is never applied by the meeting
// (KnowledgeReview.apply keeps it `waiting` with its before and after). Each one is an Inbox item (Mac panel and the
// iPhone page) with the meeting's reason and a diff: [Apply] saves it by the meeting against the content the meeting saw
// (the skill stays 🔒, the fact stays the user's, history records it under the review's batch so its Undo takes it back
// too); [Reject] drops it. A skill or fact changed since is not applied: the item closes.
struct KnowledgeProposal: Codable, Equatable {
    var name: String? = nil, description: String? = nil, body: String? = nil   // skill: what the meeting would save
    var text: String? = nil                                                    // memory: the fact's new text
    var oldName: String? = nil, oldDescription: String? = nil, oldBody: String? = nil
    var oldText: String? = nil
    var hash: String? = nil   // the skill's content hash when the meeting decided
}

struct KnowledgeDiffLine: Equatable {
    enum Kind { case same, removed, added }
    let kind: Kind
    let text: String
    var marked: String { (kind == .removed ? "- " : kind == .added ? "+ " : "  ") + text }
}

struct KnowledgeApproval: Identifiable, Equatable {
    let review: UUID
    let at: Date
    let outcome: KnowledgeReviewRecord.Outcome
    var id: UUID { outcome.candidate }
    var isSkill: Bool { outcome.proposal?.text == nil }

    var title: String {
        isSkill ? L("🔒 스킬 \(outcome.skill ?? outcome.proposal?.oldName ?? "")", "🔒 Skill \(outcome.skill ?? outcome.proposal?.oldName ?? "")")
            : L("내 기억", "My memory")
    }
    var reason: String {
        let why = outcome.decision.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return L("회의 제안 · ", "Review suggests · ") + (why.isEmpty ? L("바꾸기", "a change") : why)
    }
    var diff: [KnowledgeDiffLine] {
        guard let p = outcome.proposal else { return [] }
        if !isSkill { return KnowledgeApproval.diff(p.oldText ?? "", p.text ?? "") }
        func page(_ name: String?, _ description: String?, _ body: String?) -> String {
            [name ?? "", description ?? "", "", body ?? ""].joined(separator: "\n")
        }
        return KnowledgeApproval.diff(page(p.oldName, p.oldDescription, p.oldBody), page(p.name, p.description, p.body))
    }

    // Line diff (Swift's Myers difference): unchanged lines once, removed before added.
    static func diff(_ old: String, _ new: String) -> [KnowledgeDiffLine] {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        let changes = b.difference(from: a)
        var removed = Set<Int>(), added = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        var out: [KnowledgeDiffLine] = [], i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { out.append(.init(kind: .removed, text: a[i])); i += 1 }
            else if j < b.count, added.contains(j) { out.append(.init(kind: .added, text: b[j])); j += 1 }
            else if i < a.count, j < b.count { out.append(.init(kind: .same, text: a[i])); i += 1; j += 1 }
            else { break }
        }
        return out
    }

    // Only the changed lines and one line around each, for the closed item.
    static func short(_ lines: [KnowledgeDiffLine]) -> [KnowledgeDiffLine] {
        let near = Set(lines.indices.filter { lines[$0].kind != .same }.flatMap { [$0 - 1, $0, $0 + 1] })
        return lines.indices.filter { near.contains($0) }.map { lines[$0] }
    }

    enum Decision: Equatable { case applied, rejected, changed, failed(String) }

    // The user's answer (main thread): Apply or Reject one waiting change. `.changed`: the skill or fact is no longer as
    // the meeting saw it, so nothing is applied and the item closes. `.failed`: nothing changed, the item stays.
    static func decide(_ candidate: UUID, apply: Bool, now: Date = Date()) -> Decision {
        precondition(Thread.isMainThread)
        var records = KnowledgeReview.records()
        guard let i = records.firstIndex(where: { $0.undoneAt == nil && $0.outcomes.contains { $0.candidate == candidate } }),
              let j = records[i].outcomes.firstIndex(where: { $0.candidate == candidate && $0.result == .waiting && $0.decidedAt == nil }),
              let proposal = records[i].outcomes[j].proposal
        else { return .failed(L("이미 처리된 항목이에요.", "This was already decided.")) }
        let review = records[i].id
        var outcome = records[i].outcomes[j]
        func close(_ result: KnowledgeReviewRecord.Result, _ decision: Decision, why: String? = nil) -> Decision {
            outcome.result = result; outcome.decidedAt = now
            if let why { outcome.reason = why }
            records[i].outcomes[j] = outcome
            let state: KnowledgeCandidate.State = result == .applied ? .applied : .dropped
            let settled = KnowledgeCandidates.shared.settle([candidate: state], from: .waiting)
            guard KnowledgeReview.write(records) else { return .failed(L("검토 기록을 저장하지 못했어요.", "The review record could not be saved.")) }
            return settled ? decision : .failed(L("후보함을 갱신하지 못했어요.", "The candidate inbox could not be updated."))
        }
        let changedSince = L("그 사이 바뀌어서 적용하지 않았어요.", "It changed since the review, so it was not applied.")
        guard apply else { return close(.dropped, .rejected, why: L("사용자가 거절함", "Rejected by the user")) }
        let by = L("지식 검토 회의 · 사용자 승인", "Knowledge review · approved by the user")
        if outcome.proposal?.text == nil {
            let project = outcome.project
            let current = proposal.oldName.flatMap { name in project.map { ProjectSkillStore.shared.read(name, project: $0) } ?? SkillStore.shared.read(name) }
            guard let current, let hash = proposal.hash, current.record.contentHash == hash,
                  outcome.skillID.map({ $0 == current.record.id }) ?? true,
                  let name = proposal.name, let description = proposal.description, let body = proposal.body
            else { return close(.refused, .changed, why: changedSince) }
            let result = project.map {
                ProjectSkillStore.shared.save(name: name, description: description, body: body, by: .meeting, project: $0,
                                              id: outcome.skillID, actor: by, isNew: false, now: now, batch: review, approved: hash)
            } ?? SkillStore.shared.save(name: name, description: description, body: body, by: .meeting, id: outcome.skillID,
                                        actor: by, isNew: false, now: now, batch: review, approved: hash)
            var saved: SkillRecord?
            switch result {
            case .saved(let skill): saved = skill
            case .updated(let skills): saved = skills.first
            case .needsApproval: return close(.refused, .changed, why: changedSince)
            case .refused(let why): return .failed(why)
            default: return .failed(L("스킬을 저장하지 못했어요.", "The skill was not saved."))
            }
            if let saved { outcome.skill = saved.name }
            if let project, !records[i].projects.contains(project) { records[i].projects.append(project) }
            return close(.applied, .applied)
        }
        guard let factID = outcome.fact, let fact = MemoryStore.shared.snapshot.items.first(where: { $0.id == factID }),
              fact.text == proposal.oldText, let text = proposal.text
        else { return close(.refused, .changed, why: changedSince) }
        // change() keeps the fact the user's (its `meeting` stays nil); the history entry carries the review for its Undo.
        switch MemoryStore.shared.change(fact.id.uuidString, to: text, room: nil, turn: nil, by: by, meeting: review) {
        case .changed: return close(.applied, .applied)
        case .refused(let why): return .failed(why)
        }
    }
}

// Every change still waiting for the user, newest review first; reloaded whenever the review file is written.
final class KnowledgeInbox: ObservableObject {
    static let shared = KnowledgeInbox()
    @Published private(set) var items: [KnowledgeApproval] = []

    private init() { items = Self.waiting(KnowledgeReview.records()) }

    func reload() {
        let next = Self.waiting(KnowledgeReview.records())
        if Thread.isMainThread { if next != items { items = next } } else { DispatchQueue.main.async { if next != self.items { self.items = next } } }
    }

    static func waiting(_ records: [KnowledgeReviewRecord]) -> [KnowledgeApproval] {
        records.filter { $0.undoneAt == nil }.reversed().flatMap { record in
            record.outcomes.filter { $0.result == .waiting && $0.decidedAt == nil && $0.proposal != nil }
                .map { KnowledgeApproval(review: record.id, at: record.at, outcome: $0) }
        }
    }
}
