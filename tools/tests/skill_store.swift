import Foundation
import AIAccounts
@testable import AIWorkspace
@testable import AIProjects
@testable import AIChat

// Skill storage (TODO 1/4): SKILL.md frontmatter + body, global (<support>/skills) and project
// (<support>/projects/<id>/skills) stores, userLocked + external edit detection, history, undo, tombstones,
// and strict AI_ILLUMINATI_TEST_HOME isolation.
func testSkillStore() {
    let fm = FileManager.default
    let real = NSHomeDirectory() + "/Library/Application Support/AI Illuminati"

    // 1. Test home isolation for both global and project skill folders.
    let projectRoot = URL(fileURLWithPath: AccountStore.home).resolvingSymlinksInPath()
        .appendingPathComponent("skill-proj-\(UUID().uuidString.prefix(8))").path
    let binding = ProjectBinding(root: projectRoot, common: projectRoot + "/.git", remote: "origin", remoteURL: "")
    let projectKey = binding.groupKey
    let globalFolder = SkillStore.folder
    let projectFolder = ProjectSkillStore.folder(projectKey)
    expect(ProcessInfo.processInfo.environment["AI_ILLUMINATI_TEST_HOME"] != nil
           && globalFolder.path == AccountStore.supportDir + "/skills"
           && projectFolder.path == ProjectMemoryStore.folder(projectKey).path + "/skills"
           && !globalFolder.path.hasPrefix(real) && !projectFolder.path.hasPrefix(real),
           "global and project skill folders stay strictly under AI_ILLUMINATI_TEST_HOME")
    try? fm.removeItem(at: globalFolder)
    try? fm.removeItem(at: ProjectMemoryStore.folder(projectKey))
    defer {
        try? fm.removeItem(at: globalFolder)
        try? fm.removeItem(at: ProjectMemoryStore.folder(projectKey))
    }

    // 2. Slug validation and SKILL.md frontmatter parsing / rendering.
    expect(SkillDocument.isValidSlug("a") && SkillDocument.isValidSlug("my-skill")
           && SkillDocument.isValidSlug("swift-5-check")
           && SkillDocument.isValidSlug(String(repeating: "a", count: SkillDocument.maxSlugLength)),
           "valid lowercase-hyphen slugs pass")
    for bad in ["", "-lead", "trail-", "double--hyphen", "Upper", "under_score", "a/b", "../escape", "한글",
                String(repeating: "a", count: SkillDocument.maxSlugLength + 1)] {
        expect(!SkillDocument.isValidSlug(bad), "invalid slug rejected: \(bad)")
    }
    let trickyDesc = #"Use when reviewing: "quotes", #tags, back\slash & 한글 (true)"#
    let trickyBody = "# Steps\n\n1. Check `git status`\n2. Run tests\n\n  indented line"
    let rendered = SkillDocument.render(name: "code-review", description: trickyDesc, body: trickyBody)
    let parsed = SkillDocument.parse(rendered)
    expect(parsed == SkillDocument(name: "code-review", description: trickyDesc, body: trickyBody),
           "SKILL.md round-trips special YAML characters, Korean text and markdown body")
    let blockScalar = """
        ---
        name: release-check
        license: MIT
        description: >
          Verify release build
          and check signatures
        ---

        Run the release script.
        """
    let parsedBlock = SkillDocument.parse(blockScalar)
    expect(parsedBlock?.name == "release-check"
           && parsedBlock?.description == "Verify release build and check signatures"
           && parsedBlock?.body == "Run the release script.",
           "SKILL.md parses YAML folded block scalars and ignores extra frontmatter keys")
    expect(SkillDocument.parse("no frontmatter") == nil
           && SkillDocument.parse("---\nname: only-name\n---\nbody") == nil
           && SkillDocument.parse("---\nname: BadSlug\ndescription: ok\n---\nbody") == nil
           && SkillDocument.parse("---\nname: ok\ndescription:   \n---\nbody") == nil,
           "invalid frontmatter returns nil")

    func saved(_ o: SkillOutcome) -> SkillRecord? { if case .saved(let r) = o { return r }; return nil }
    func deleted(_ o: SkillOutcome) -> SkillTombstone? { if case .deleted(let t) = o { return t }; return nil }
    func needsApproval(_ o: SkillOutcome) -> Bool {
        if case .needsApproval(_, let msg) = o { return msg.contains("Inbox") }
        return false
    }
    func refused(_ o: SkillOutcome) -> Bool { if case .refused = o { return true }; return false }
    func undone(_ o: SkillOutcome) -> SkillHistoryEntry? { if case .undone(let e) = o { return e }; return nil }

    // 3. Global store (AIChat SkillStore): save, read, list, permissions, user lock, AI/meeting refusal.
    let global = SkillStore.shared
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    guard let userSkill = saved(global.save(name: "paper-review", description: "논문 초고 검토 절차",
                                            body: "1. 논리 점검\n2. Control 누락 확인", by: .user, now: t0)) else {
        expect(false, "user skill saved"); return
    }
    expect(userSkill.name == "paper-review" && userSkill.createdBy == .user && userSkill.userLocked
           && userSkill.enabled && !userSkill.isNew && userSkill.updatedAt == t0,
           "user-created skill metadata: locked, enabled, not new")
    let skillPath = globalFolder.appendingPathComponent("paper-review/SKILL.md").path
    let indexPath = globalFolder.appendingPathComponent("skills.json").path
    let historyPath = globalFolder.appendingPathComponent("skills-history.jsonl").path
    expect(fm.fileExists(atPath: skillPath) && fm.fileExists(atPath: indexPath) && fm.fileExists(atPath: historyPath),
           "SKILL.md, skills.json and skills-history.jsonl are created under <support>/skills/")
    for file in [skillPath, indexPath, historyPath] {
        let perm = (try? fm.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber)?.intValue
        expect(perm == 0o600, "skill file is private 0600: \(file)")
    }
    let detail = global.read("paper-review")
    expect(detail?.record == userSkill && detail?.document.description == "논문 초고 검토 절차"
           && detail?.document.body == "1. 논리 점검\n2. Control 누락 확인" && detail?.externallyModified == false,
           "read(name) returns parsed SKILL.md and metadata")
    expect(global.list().map(\.name) == ["paper-review"] && global.list().first?.description == "논문 초고 검토 절차",
           "list() returns skill summary")
    expect(refused(global.save(name: "Bad_Slug", description: "desc", body: "body", by: .user))
           && refused(global.save(name: "good-slug", description: "  \n ", body: "body", by: .user)),
           "invalid slug or empty description is refused")

    // AI and meeting cannot overwrite, toggle or delete a user-locked skill.
    let historyBeforeRefusal = global.history().count
    expect(needsApproval(global.save(name: "paper-review", description: "AI rewrite", body: "overwritten", by: .ai, actor: "Claude"))
           && needsApproval(global.save(name: "paper-review", description: "Meeting rewrite", body: "overwritten", by: .meeting))
           && needsApproval(global.delete("paper-review", by: .ai))
           && needsApproval(global.setEnabled("paper-review", false, by: .meeting)),
           "AI and meeting mutations on a userLocked skill return needsApproval (Inbox)")
    expect(global.read("paper-review")?.document.body == "1. 논리 점검\n2. Control 누락 확인"
           && global.history().count == historyBeforeRefusal,
           "needsApproval leaves SKILL.md and history untouched")

    // 4. AI/meeting skill lifecycle: unlocked -> AI update -> external edit locks it -> AI refused!
    guard let aiSkill = saved(global.save(name: "daily-quest", description: "Daily schedule builder",
                                          body: "Step 1", by: .ai, actor: "Codex", now: t0.addingTimeInterval(10))) else {
        expect(false, "AI skill saved"); return
    }
    expect(aiSkill.createdBy == .ai && !aiSkill.userLocked && aiSkill.isNew && aiSkill.enabled,
           "AI-created skill starts unlocked and isNew=true")
    guard let aiUpdated = saved(global.save(name: "daily-quest", description: "Daily schedule builder v2",
                                            body: "Step 1\nStep 2", by: .meeting, now: t0.addingTimeInterval(20))) else {
        expect(false, "meeting updates unlocked AI skill"); return
    }
    expect(aiUpdated.id == aiSkill.id && aiUpdated.createdBy == .ai && !aiUpdated.userLocked
           && aiUpdated.contentHash != aiSkill.contentHash,
           "meeting update preserves id and createdBy, updates contentHash")

    // Simulate external edit directly on SKILL.md outside the app.
    let externalText = "---\nname: daily-quest\ndescription: Hand-edited outside app\n---\n\nMy custom step\n"
    try! externalText.write(toFile: globalFolder.appendingPathComponent("daily-quest/SKILL.md").path, atomically: true, encoding: .utf8)
    let afterExt = global.read("daily-quest")
    expect(afterExt?.record.userLocked == true && afterExt?.externallyModified == true
           && afterExt?.document.body == "My custom step"
           && global.list().first(where: { $0.name == "daily-quest" })?.record.userLocked == true,
           "external edit changes contentHash and marks skill userLocked")
    expect(needsApproval(global.save(name: "daily-quest", description: "AI overwrite", body: "nope", by: .ai)),
           "AI save is refused with Inbox approval required after external edit")
    expect(global.read("daily-quest")?.document.body == "My custom step",
           "external edit is preserved when AI save is refused")
    // Undo of a content change is also refused when the file was externally modified after that change.
    expect(refused(global.undo()) && global.read("daily-quest")?.document.body == "My custom step",
           "undo refuses to overwrite an externally modified SKILL.md")

    // User editing an externally edited skill captures the external version in history so undo restores it!
    guard let userTookOver = saved(global.save(name: "daily-quest", description: "User formal edit",
                                               body: "Formal step", by: .user, now: t0.addingTimeInterval(30))) else {
        expect(false, "user edits externally modified skill"); return
    }
    expect(userTookOver.id == aiSkill.id && userTookOver.userLocked && !userTookOver.isNew,
           "user edit preserves id, sets userLocked=true and clears isNew")
    expect(undone(global.undo()) != nil && global.read("daily-quest")?.document.body == "My custom step",
           "undo after editing an externally modified skill restores the external file")

    // Untracked external skill folder dropped directly on disk is treated as userLocked.
    let untrackedFile = globalFolder.appendingPathComponent("hand-placed/SKILL.md")
    try! fm.createDirectory(at: untrackedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! "---\nname: hand-placed\ndescription: Dropped by user\n---\n\nManual body\n".write(to: untrackedFile, atomically: true, encoding: .utf8)
    expect(global.list().first(where: { $0.name == "hand-placed" })?.record.userLocked == true
           && needsApproval(global.save(name: "hand-placed", description: "AI", body: "x", by: .ai)),
           "untracked SKILL.md on disk is discovered as userLocked and protected from AI")
    expect(deleted(global.delete("hand-placed", by: .user)) != nil && global.read("hand-placed") == nil,
           "user can delete an untracked external skill")

    // 5. Rename preserves UUID, moves folder, updates frontmatter, and undo moves it back.
    guard let renamed = saved(global.save(name: "manuscript-review", description: "논문 초고 검토 (이름 변경)",
                                          body: "1. 논리 점검\n2. Control 누락 확인\n3. 그림 점검",
                                          by: .user, id: userSkill.id, now: t0.addingTimeInterval(40))) else {
        expect(false, "rename skill"); return
    }
    expect(renamed.id == userSkill.id && renamed.name == "manuscript-review"
           && global.read("paper-review") == nil && global.read("manuscript-review")?.record.id == userSkill.id
           && !fm.fileExists(atPath: globalFolder.appendingPathComponent("paper-review").path),
           "rename keeps UUID, moves folder and updates frontmatter name")
    expect(refused(global.save(name: "daily-quest", description: "collide", body: "x", by: .user, id: userSkill.id)),
           "renaming onto an existing skill name is refused")
    expect(undone(global.undo()) != nil && global.read("paper-review")?.record.id == userSkill.id
           && global.read("manuscript-review") == nil
           && !fm.fileExists(atPath: globalFolder.appendingPathComponent("manuscript-review").path),
           "undoing a rename restores the old folder, frontmatter and UUID")

    // 6. setEnabled, setAllEnabled and undo.
    let beforeToggle = global.history().count
    expect(saved(global.setEnabled("paper-review", true))?.enabled == true
           && global.history().count == beforeToggle, "no-op setEnabled appends no history line")
    expect(saved(global.setEnabled("paper-review", false))?.enabled == false
           && global.history().last?.action == .disable
           && global.read("paper-review")?.record.enabled == false, "setEnabled(false) disables and logs disable")
    expect(saved(global.setEnabled("paper-review", true))?.enabled == true
           && global.history().last?.action == .enable, "setEnabled(true) re-enables and logs enable")
    // Now set paper-review=false, leave daily-quest=true, then setAllEnabled(false) and undo!
    _ = global.setEnabled("paper-review", false)
    let beforeAll = global.history().count
    if case .updated(let allOff) = global.setAllEnabled(false) {
        expect(allOff.allSatisfy { !$0.enabled } && global.history().count == beforeAll + 1
               && global.history().last?.action == .setAllEnabled,
               "setAllEnabled(false) turns off all skills in one history entry")
    } else { expect(false, "setAllEnabled(false) returned .updated") }
    expect(undone(global.undo()) != nil
           && global.read("paper-review")?.record.enabled == false
           && global.read("daily-quest")?.record.enabled == true,
           "undo of setAllEnabled restores each skill's prior enabled state")

    // 7. Delete, tombstone persistence, undo of delete, and recreating same slug with fresh UUID.
    let deleteTime = t0.addingTimeInterval(100)
    guard let tomb = deleted(global.delete("paper-review", by: .user, now: deleteTime)) else {
        expect(false, "delete skill"); return
    }
    expect(tomb.id == userSkill.id && tomb.name == "paper-review" && tomb.deletedAt == deleteTime
           && global.read("paper-review") == nil
           && !fm.fileExists(atPath: globalFolder.appendingPathComponent("paper-review").path)
           && global.tombstones().contains(tomb),
           "delete removes folder and records tombstone (id + deletedAt) in skills.json")
    let rawIndex = try! String(contentsOfFile: indexPath, encoding: .utf8)
    expect(rawIndex.contains(userSkill.id.uuidString) && rawIndex.contains("\"tombstones\""),
           "tombstone is persisted on disk in skills.json")

    // Undo delete restores SKILL.md, UUID, and removes that tombstone.
    expect(undone(global.undo()) != nil && global.read("paper-review")?.record.id == userSkill.id
           && !global.tombstones().contains(tomb),
           "undo of delete restores SKILL.md, metadata and removes its tombstone")

    // Delete again permanently (no undo) and verify recreating with same slug keeps old tombstone and uses a new UUID.
    guard let tomb2 = deleted(global.delete("paper-review", by: .user, now: t0.addingTimeInterval(120))) else {
        expect(false, "second delete"); return
    }
    guard let recreated = saved(global.save(name: "paper-review", description: "Fresh review skill",
                                            body: "New body", by: .user, now: t0.addingTimeInterval(130))) else {
        expect(false, "recreate with same slug"); return
    }
    expect(recreated.id != userSkill.id && global.tombstones().contains(tomb2),
           "recreating a deleted slug gets a fresh UUID while preserving the old tombstone")

    // 8. Project store (AIProjects ProjectSkillStore) + chained undo + crash/corruption handling.
    let proj = ProjectSkillStore.shared
    guard let p1 = saved(proj.save(name: "build-stage", description: "Stage build check",
                                   body: "Run build --stage", by: .ai, project: projectKey, now: t0)),
          let p2 = saved(proj.save(name: "build-stage", description: "Stage build check v2",
                                   body: "Run build --stage && check_modules", by: .user, project: projectKey, now: t0.addingTimeInterval(5))) else {
        expect(false, "project skills saved"); return
    }
    expect(p1.id == p2.id && !p1.userLocked && p2.userLocked
           && proj.read("build-stage", project: projectKey)?.document.body == "Run build --stage && check_modules"
           && fm.fileExists(atPath: projectFolder.appendingPathComponent("build-stage/SKILL.md").path),
           "ProjectSkillStore stores under projects/<id>/skills and upgrades lock on user edit")
    expect(needsApproval(proj.save(name: "build-stage", description: "AI", body: "bad", by: .ai, project: projectKey)),
           "ProjectSkillStore refuses AI save on userLocked skill with Inbox approval required")
    // Chained undo: undo user edit -> back to p1 (unlocked); undo add -> removed; third undo -> refused.
    expect(undone(proj.undo(project: projectKey)) != nil
           && proj.read("build-stage", project: projectKey)?.record.userLocked == false
           && proj.read("build-stage", project: projectKey)?.document.body == "Run build --stage",
           "first undo restores AI v1 and unlocked state")
    expect(undone(proj.undo(project: projectKey)) != nil
           && proj.read("build-stage", project: projectKey) == nil
           && proj.list(projectKey).isEmpty,
           "second undo removes the added skill")
    expect(refused(proj.undo(project: projectKey)), "third undo refuses when nothing left to undo")

    // Crash resilience: a cut-off last line in skills-history.jsonl is ignored and overwritten on next save;
    // corrupted skills.json refuses writes without overwriting.
    _ = proj.save(name: "test-skill", description: "Crash check", body: "ok", by: .ai, project: projectKey)
    let projHistURL = projectFolder.appendingPathComponent("skills-history.jsonl")
    let projIndexURL = projectFolder.appendingPathComponent("skills.json")
    if let h = try? FileHandle(forWritingTo: projHistURL) {
        h.seekToEndOfFile(); h.write(Data("{\"action\":\"add".utf8)); h.closeFile()
    }
    let countBeforeRecover = proj.history(projectKey).count
    expect(saved(proj.save(name: "test-skill", description: "Crash check 2", body: "ok2", by: .ai, project: projectKey)) != nil
           && proj.history(projectKey).count == countBeforeRecover + 1,
           "truncated tail line in skills-history.jsonl is recovered on next save")
    let goodIndex = try! Data(contentsOf: projIndexURL)
    try! Data("{ broken json".utf8).write(to: projIndexURL)
    expect(refused(proj.save(name: "test-skill", description: "Should fail", body: "x", by: .user, project: projectKey))
           && (try? Data(contentsOf: projIndexURL)) == Data("{ broken json".utf8),
           "damaged skills.json refuses mutations and is never overwritten")
    try! goodIndex.write(to: projIndexURL)

    print("PASS: skill store (SKILL.md frontmatter, global/project stores, user lock + external edit, rename UUID, setEnabled/setAllEnabled, tombstone, chained undo, crash safety)")
}
