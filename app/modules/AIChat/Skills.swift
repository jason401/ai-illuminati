import Foundation
import AIAccounts
import AIProjects

// Global skills store under <support>/skills/<name>/SKILL.md (paired with AIProjects' ProjectSkillStore).
// Uses SkillDocument and SkillDirectory from AIProjects so SKILL.md parsing, locking, history and tombstones stay in
// one place without a shared "Common" module.
public final class SkillStore: ObservableObject {
    public static let shared = SkillStore()

    @Published public private(set) var revision = 0
    private let directory: SkillDirectory

    public static var folder: URL {
        URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("skills", isDirectory: true)
    }

    public init(folder: (() -> URL)? = nil) {
        var bump: (() -> Void)?
        self.directory = SkillDirectory(folder: folder ?? { Self.folder }, onChange: { bump?() })
        bump = { [weak self] in
            guard let self else { return }
            let update = { self.revision += 1 }
            if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
        }
    }

    public func list() -> [SkillSummary] { directory.list() }
    public func read(_ name: String) -> SkillDetail? { directory.read(name) }
    public func tombstones() -> [SkillTombstone] { directory.tombstones() }
    public func history() -> [SkillHistoryEntry] { directory.history() }

    public func save(name: String, description: String, body: String, by: SkillAuthor,
                     id: UUID? = nil, actor: String? = nil, isNew: Bool? = nil, now: Date = Date()) -> SkillOutcome {
        directory.save(name: name, description: description, body: body, by: by, id: id, actor: actor, isNew: isNew, now: now)
    }

    public func setEnabled(_ name: String, _ enabled: Bool, by: SkillAuthor = .user,
                           actor: String? = nil, now: Date = Date()) -> SkillOutcome {
        directory.setEnabled(name, enabled, by: by, actor: actor, now: now)
    }

    public func setAllEnabled(_ enabled: Bool, by: SkillAuthor = .user,
                              actor: String? = nil, now: Date = Date()) -> SkillOutcome {
        directory.setAllEnabled(enabled, by: by, actor: actor, now: now)
    }

    public func delete(_ name: String, by: SkillAuthor = .user,
                       actor: String? = nil, now: Date = Date()) -> SkillOutcome {
        directory.delete(name, by: by, actor: actor, now: now)
    }

    public func undo(by: SkillAuthor = .user, actor: String? = nil, now: Date = Date()) -> SkillOutcome {
        directory.undo(by: by, actor: actor, now: now)
    }
}
