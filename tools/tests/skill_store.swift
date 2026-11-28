import Foundation
import AIAccounts
import AILocalization
@testable import AIRuntime
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

    // Standard YAML compatibility: numeric/boolean/date scalars are quoted; inline comments are stripped on parse.
    for (slug, desc) in [("123", "456"), ("true", "3.14"), ("2026-11-28", "0x10"), ("1e5", "no")] {
        let out = SkillDocument.render(name: slug, description: desc, body: "body")
        expect(out.contains("name: \"\(slug)\"\n") && out.contains("description: \"\(desc)\"\n")
               && SkillDocument.parse(out) == SkillDocument(name: slug, description: desc, body: "body"),
               "numeric/keyword/date YAML scalar is quoted and round-trips: \(slug) / \(desc)")
    }
    let commentedYAML = """
        ---
        name: review # inline comment on plain scalar
        description: Use C# and F# tools # trailing comment
        ---

        Check everything.
        """
    expect(SkillDocument.parse(commentedYAML) == SkillDocument(name: "review", description: "Use C# and F# tools", body: "Check everything."),
           "plain YAML scalars strip inline comments while preserving # inside words")
    let quotedCommentYAML = """
        ---
        name: "123" # quoted numeric slug
        description: 'it''s # literal' # real comment
        ---

        Body
        """
    expect(SkillDocument.parse(quotedCommentYAML) == SkillDocument(name: "123", description: "it's # literal", body: "Body"),
           "quoted YAML scalars ignore # inside quotes and strip trailing comments")
    let blockCommentYAML = """
        ---
        name: block-test # comment
        description: > # folded comment
          First line
          second line
        ---

        Done
        """
    expect(SkillDocument.parse(blockCommentYAML) == SkillDocument(name: "block-test", description: "First line second line", body: "Done"),
           "block scalar headers allow trailing inline comments")

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
    // Opening a skill in Settings clears "new" without a history line, so the AI's add can still be undone.
    expect(saved(global.save(name: "seen-check", description: "Added by an AI", body: "x", by: .ai))?.isNew == true,
           "an AI's new skill starts with the new badge")
    let beforeSeen = global.history().count
    expect(global.markSeen("seen-check") && global.read("seen-check")?.record.isNew == false
           && global.read("seen-check")?.record.userLocked == false && global.history().count == beforeSeen
           && !global.markSeen("seen-check") && !global.markSeen("no-such-skill"),
           "markSeen clears isNew once, keeps the lock as it was, and logs no history")
    expect(undone(global.undo()) != nil && global.read("seen-check") == nil, "undo after markSeen still removes the AI's add")
    // An AI's second edit before the user first looks: undoing that edit keeps the badge the user already cleared.
    _ = global.save(name: "seen-twice", description: "Added by an AI", body: "v1", by: .ai)
    _ = global.save(name: "seen-twice", description: "Added by an AI", body: "v2", by: .ai)
    expect(global.markSeen("seen-twice") && undone(global.undo()) != nil
           && global.read("seen-twice")?.document.body == "v1" && global.read("seen-twice")?.record.isNew == false,
           "undoing an edit after markSeen does not bring the new badge back")
    // Files next to SKILL.md go with a rename and its Undo, and stay through a delete so its Undo restores the whole skill.
    guard let kit = saved(global.save(name: "kit-a", description: "With a script", body: "Run run.sh", by: .user)) else {
        expect(false, "kit-a saved"); return
    }
    try! Data("echo hi".utf8).write(to: globalFolder.appendingPathComponent("kit-a/run.sh"))
    expect(saved(global.save(name: "kit-b", description: "With a script", body: "Run run.sh", by: .user, id: kit.id)) != nil
           && fm.fileExists(atPath: globalFolder.appendingPathComponent("kit-b/run.sh").path)
           && !fm.fileExists(atPath: globalFolder.appendingPathComponent("kit-a").path),
           "a rename moves the whole skill folder")
    expect(undone(global.undo()) != nil && fm.fileExists(atPath: globalFolder.appendingPathComponent("kit-a/run.sh").path)
           && global.read("kit-a") != nil && !fm.fileExists(atPath: globalFolder.appendingPathComponent("kit-b").path),
           "undoing a rename moves the whole folder back")
    expect(deleted(global.delete("kit-a", by: .user)) != nil && global.read("kit-a") == nil
           && fm.fileExists(atPath: globalFolder.appendingPathComponent("kit-a/run.sh").path)
           && undone(global.undo()) != nil && global.read("kit-a")?.document.body == "Run run.sh"
           && fm.fileExists(atPath: globalFolder.appendingPathComponent("kit-a/run.sh").path),
           "a user's delete keeps the files next to SKILL.md and its Undo restores the whole skill")
    expect(undone(global.undo()) != nil && undone(global.undo()) != nil && global.read("kit-a") == nil
           && global.read("seen-twice") == nil && !fm.fileExists(atPath: globalFolder.appendingPathComponent("kit-a").path),
           "undoing the kit's and seen-twice's adds clears them")

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

    // Delete again permanently (no undo) and verify recreating with same slug keeps old tombstone and uses a new UUID,
    // while explicitly reusing a tombstoned UUID in save(id:) is refused.
    guard let tomb2 = deleted(global.delete("paper-review", by: .user, now: t0.addingTimeInterval(120))) else {
        expect(false, "second delete"); return
    }
    expect(refused(global.save(name: "revived-slug", description: "Should not reuse deleted UUID",
                               body: "nope", by: .user, id: tomb2.id, now: t0.addingTimeInterval(125)))
           && global.read("revived-slug") == nil,
           "save(id:) refuses to reuse a tombstoned UUID")
    guard let recreated = saved(global.save(name: "paper-review", description: "Fresh review skill",
                                            body: "New body", by: .user, now: t0.addingTimeInterval(130))) else {
        expect(false, "recreate with same slug"); return
    }
    expect(recreated.id != userSkill.id && global.tombstones().contains(tomb2),
           "recreating a deleted slug gets a fresh UUID while preserving the old tombstone")

    // 7b. Non-UTF-8 (UTF-16) external edit on an unlocked AI skill is detected by raw byte hash before decoding.
    guard saved(global.save(name: "utf16-skill", description: "AI created", body: "v1", by: .ai, now: t0.addingTimeInterval(140))) != nil else {
        expect(false, "utf16-skill saved"); return
    }
    let utf16URL = globalFolder.appendingPathComponent("utf16-skill/SKILL.md")
    let utf16Bytes = "---\nname: utf16-skill\ndescription: UTF-16 user edit\n---\n\nEdited in UTF-16\n".data(using: .utf16)!
    try! utf16Bytes.write(to: utf16URL, options: .atomic)
    expect(global.list().first(where: { $0.name == "utf16-skill" })?.record.userLocked == true
           && global.list().first(where: { $0.name == "utf16-skill" })?.externallyModified == true,
           "UTF-16 external edit is listed as userLocked and externallyModified")
    expect(needsApproval(global.save(name: "utf16-skill", description: "AI overwrite", body: "clobber", by: .ai))
           && needsApproval(global.setEnabled("utf16-skill", false, by: .ai))
           && needsApproval(global.setAllEnabled(false, by: .ai))
           && needsApproval(global.delete("utf16-skill", by: .ai))
           && needsApproval(global.undo(by: .ai))
           && refused(global.undo(by: .user))
           && (try? Data(contentsOf: utf16URL)) == utf16Bytes,
           "UTF-16 external edit blocks AI save/toggle/delete/undo and user content undo without altering raw bytes")
    expect(deleted(global.delete("utf16-skill", by: .user)) != nil, "user can clean up UTF-16 external skill")

    // 8. Project store (AIProjects ProjectSkillStore) + undo lock checks + chained undo + crash/rollback handling.
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
    expect(needsApproval(proj.save(name: "build-stage", description: "AI", body: "bad", by: .ai, project: projectKey))
           && needsApproval(proj.undo(project: projectKey, by: .ai))
           && needsApproval(proj.undo(project: projectKey, by: .meeting))
           && proj.read("build-stage", project: projectKey)?.document.body == "Run build --stage && check_modules",
           "ProjectSkillStore refuses AI/meeting save and undo on userLocked skill with Inbox approval required")
    // Chained undo: user undoes user edit -> back to p1 (unlocked); AI can undo its own unlocked add; third undo -> refused.
    expect(undone(proj.undo(project: projectKey, by: .user)) != nil
           && proj.read("build-stage", project: projectKey)?.record.userLocked == false
           && proj.read("build-stage", project: projectKey)?.document.body == "Run build --stage",
           "first undo by user restores AI v1 and unlocked state")
    expect(undone(proj.undo(project: projectKey, by: .ai)) != nil
           && proj.read("build-stage", project: projectKey) == nil
           && proj.list(projectKey).isEmpty,
           "second undo by AI removes its own unlocked add")
    expect(refused(proj.undo(project: projectKey)), "third undo refuses when nothing left to undo")

    // User delete of an unlocked AI skill cannot be undone by AI without Inbox approval.
    _ = proj.save(name: "ai-only", description: "Temp AI skill", body: "steps", by: .ai, project: projectKey)
    _ = proj.delete("ai-only", project: projectKey, by: .user)
    expect(needsApproval(proj.undo(project: projectKey, by: .ai))
           && proj.read("ai-only", project: projectKey) == nil,
           "AI cannot undo a user deletion without Inbox approval")

    // Crash resilience: a cut-off last line in skills-history.jsonl (even > 64 KiB) is ignored and truncated on next save;
    // corrupted skills.json refuses writes without overwriting; mid-save index failure rolls back SKILL.md and history.
    _ = proj.save(name: "test-skill", description: "Crash check", body: "ok", by: .ai, project: projectKey)
    let projHistURL = projectFolder.appendingPathComponent("skills-history.jsonl")
    let projIndexURL = projectFolder.appendingPathComponent("skills.json")
    if let h = try? FileHandle(forWritingTo: projHistURL) {
        h.seekToEndOfFile()
        let bigTruncated = "{\"action\":\"add\",\"pad\":\"" + String(repeating: "x", count: 100_000)
        h.write(Data(bigTruncated.utf8))
        h.closeFile()
    }
    let countBeforeRecover = proj.history(projectKey).count
    expect(saved(proj.save(name: "test-skill", description: "Crash check 2", body: "ok2", by: .ai, project: projectKey)) != nil
           && proj.history(projectKey).count == countBeforeRecover + 1,
           "truncated tail line > 64 KiB in skills-history.jsonl is recovered on next save")

    // Rollback on mid-persist failure: make root read-only (0500) so SKILL.md (inside 0700 subdir) and in-place
    // history append succeed, while atomic skills.json write fails -> both SKILL.md and history must roll back!
    let testSkillFile = projectFolder.appendingPathComponent("test-skill/SKILL.md")
    let priorSkillBytes = try! Data(contentsOf: testSkillFile)
    let priorHistBytes = try! Data(contentsOf: projHistURL)
    let priorIndexBytes = try! Data(contentsOf: projIndexURL)
    try! fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: projectFolder.path)
    let failOutcome = proj.save(name: "test-skill", description: "Must rollback", body: "must not persist", by: .user, project: projectKey)
    try! fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: projectFolder.path)
    expect(refused(failOutcome)
           && (try? Data(contentsOf: testSkillFile)) == priorSkillBytes
           && (try? Data(contentsOf: projHistURL)) == priorHistBytes
           && (try? Data(contentsOf: projIndexURL)) == priorIndexBytes,
           "mid-save failure on skills.json rolls back SKILL.md and skills-history.jsonl together")

    let goodIndex = try! Data(contentsOf: projIndexURL)
    try! Data("{ broken json".utf8).write(to: projIndexURL)
    expect(refused(proj.save(name: "test-skill", description: "Should fail", body: "x", by: .user, project: projectKey))
           && (try? Data(contentsOf: projIndexURL)) == Data("{ broken json".utf8),
           "damaged skills.json refuses mutations and is never overwritten")
    try! goodIndex.write(to: projIndexURL)

    print("PASS: skill store (SKILL.md frontmatter, YAML compatibility, global/project stores, user lock + UTF-16 external edit, rename UUID, setEnabled/setAllEnabled, tombstone reuse guard, undo lock check, rollback & >64 KiB crash safety)")
}

func testSkillRead() {
    let fm = FileManager.default
    let global = SkillStore.shared, projects = ProjectSkillStore.shared
    expect(ProcessInfo.processInfo.environment["AI_ILLUMINATI_TEST_HOME"] == AccountStore.home
           && global.list().isEmpty, "skill prompt test starts with an empty store in the test home")
    let own = ProjectBinding(root: "", common: "", remote: "", remoteURL: "", kind: "folderless", id: ProjectBinding.newID())
    let other = ProjectBinding(root: "", common: "", remote: "", remoteURL: "", kind: "folderless", id: ProjectBinding.newID())
    defer {
        try? fm.removeItem(at: SkillStore.folder)
        try? fm.removeItem(at: ProjectMemoryStore.folder(own.groupKey))
        try? fm.removeItem(at: ProjectMemoryStore.folder(other.groupKey))
    }

    let providers: [Account.Provider] = [.claude, .codex, .gemini, .ollama]
    let accounts = providers.map { Account(id: "skill-\($0.rawValue)", provider: $0, name: $0.title) }
    let school = Account(id: "skill-school", provider: .codex, name: "ChatGPT (School)", school: true)
    let model = AppModel()
    let discussion = Discussion(model: model)
    func room(_ project: ProjectBinding? = nil, schoolLocked: Bool = false) -> Conversation {
        var chat = Conversation()
        chat.workspace = project.map { WorkspaceBinding(roots: [], project: $0) }
        if schoolLocked { chat.enterpriseLock = Enterprise.organizations([school]).first }
        chat.turns = [ChatTurn(question: "piezoresonance")]
        return chat
    }
    let plain = room(), linked = room(own), schoolRoom = room(own, schoolLocked: true)
    discussion.conversations = [plain, linked, schoolRoom]
    func prompt(_ account: Account, _ chat: Conversation, binding: WorkspaceBinding? = nil) -> String {
        discussion.soloInstruction(account, binding: binding ?? WorkspaceBinding(roots: [], project: chat.workspace?.project, face: true),
                                   helper: "", chat: chat.id)
    }
    let empty = prompt(accounts[0], plain)
    expect(!empty.contains("[Skills]") && !empty.contains("skill_read"), "no enabled skills leaves the prompt unchanged")

    func saveGlobal(_ name: String, _ description: String, _ body: String, date: TimeInterval = 1) {
        if case .saved = global.save(name: name, description: description, body: body, by: .user, actor: school.name,
                                     now: Date(timeIntervalSince1970: date)) { return }
        fatalError("could not save test skill \(name)")
    }
    func saveProject(_ name: String, _ description: String, _ body: String, in project: ProjectBinding? = nil) {
        if case .saved = projects.save(name: name, description: description, body: body, by: .user, project: (project ?? own).groupKey) { return }
        fatalError("could not save project test skill \(name)")
    }
    saveGlobal("shared-procedure", "Check the result", "GLOBAL BODY")
    saveGlobal("collision", "Global version", "GLOBAL COLLISION BODY")
    saveGlobal("hidden-global", "Disabled reference", "DISABLED GLOBAL BODY")
    _ = global.setEnabled("hidden-global", false)
    saveProject("project-procedure", "Project naming guide", "PROJECT BODY")
    saveProject("collision", "Project version", "PROJECT COLLISION BODY")
    saveProject("hidden-project", "Disabled project", "DISABLED PROJECT BODY")
    _ = projects.setEnabled("hidden-project", false, project: own.groupKey)
    saveProject("other-procedure", "Other project guide", "OTHER PROJECT BODY", in: other)

    let foreign = ProjectSkillStore.folder(other.groupKey).appendingPathComponent("other-procedure")
    let alias = SkillStore.folder.appendingPathComponent("foreign-alias")
    try! fm.createSymbolicLink(at: alias, withDestinationURL: foreign)
    let catalogAlias = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("skill-catalog-alias")
    try! fm.createSymbolicLink(at: catalogAlias, withDestinationURL: SkillStore.folder)
    defer { try? fm.removeItem(at: catalogAlias) }
    expect(global.read("foreign-alias")?.document.body == "OTHER PROJECT BODY"
           && SkillStore(folder: { catalogAlias }).list().contains { $0.name == "shared-procedure" },
           "the user store still reads a manually linked skill and lists a symlinked catalog")

    for account in accounts + [school] {
        let instruction = prompt(account, account.id == school.id ? schoolRoom : linked)
        expect(instruction.contains("[Skills] " + SkillLink.warning)
               && instruction.contains("- shared-procedure — Check the result")
               && instruction.contains("- project-procedure — Project naming guide")
               && instruction.contains("- collision — Project version")
               && !instruction.contains("Global version") && !instruction.contains(" BODY")
               && !instruction.contains("hidden-global") && !instruction.contains("hidden-project")
               && !instruction.contains("other-procedure") && !instruction.contains("foreign-alias"),
               "\(account.provider) gets only enabled metadata for the current scope")
    }
    expect(!prompt(accounts[1], plain).contains("project-procedure") && prompt(accounts[1], plain).contains("Global version"),
           "plain chats only list global skills, including ones saved by a school account")
    let fileOnly = WorkspaceBinding(roots: [])
    expect(!prompt(accounts[0], linked, binding: fileOnly).contains("[Skills]")
           && !prompt(accounts[1], schoolRoom).contains("[Skills]")
           && !prompt(accounts[3], linked, binding: fileOnly.consulted).contains("[Skills]")
           && RunConditions.app(accounts[3]).readSkill == nil,
           "the skill prompt requires a reachable tool for this chat and the local reader requires a workspace")
    expect(prompt(accounts[0], linked, binding: fileOnly.side).contains("[Skills]"),
           "a side answer's read-only gateway provides skill_read")

    let hub = ToolHub(providers: { ToolHub.appProviders }, listenOnRegister: false)
    func token(_ chat: Conversation, _ account: Account, origin: ToolOrigin = .member) -> String {
        hub.register(room: chat.id, roots: [], asker: account, origin: origin)
    }
    func open(_ slug: String, token: String) -> [String: Any] {
        hub.handle(["op": "call", "session": token, "name": "skill_read", "arguments": ["name": slug]])
    }
    func body(_ slug: String, token: String) -> String {
        (open(slug, token: token)["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    }
    let member = token(linked, accounts[0]), side = token(linked, accounts[1], origin: .side)
    let enterprise = token(schoolRoom, school), personal = token(plain, accounts[2])
    let definition = (hub.handle(["op": "tools", "session": member])["tools"] as? [[String: Any]])?.first { $0["name"] as? String == "skill_read" }
    expect((definition?["inputSchema"] as? [String: Any])?["required"] as? [String] == ["name"], "MCP lists the skill tool by name")
    let projectResult = body("project-procedure", token: member)
    expect(projectResult.hasPrefix(SkillLink.warning) && projectResult.hasSuffix(SkillLink.warning)
           && projectResult.contains("\nPROJECT BODY\n") && !projectResult.contains("Project naming guide"),
           "skill_read wraps the body in the same prompt warning")
    expect(body("collision", token: side).contains("PROJECT COLLISION BODY")
           && body("collision", token: personal).contains("GLOBAL COLLISION BODY")
           && body("shared-procedure", token: enterprise).contains("GLOBAL BODY")
           && body("shared-procedure", token: personal).contains("GLOBAL BODY"),
           "side, project, personal and school answers resolve skills in their own scopes")
    for slug in ["hidden-global", "hidden-project", "other-procedure", "foreign-alias", "../project-procedure"] {
        expect(open(slug, token: member)["isError"] as? Bool == true, "\(slug) is unavailable to the project session")
    }
    expect(open("project-procedure", token: personal)["isError"] as? Bool == true
           && open("project-procedure", token: token(linked, accounts[0], origin: .consulted))["isError"] as? Bool == true
           && open("shared-procedure", token: token(schoolRoom, accounts[1]))["isError"] as? Bool == true,
           "plain, consulted and out-of-lock sessions cannot read outside their scope")
    _ = projects.setEnabled("collision", false, project: own.groupKey)
    expect(body("collision", token: member).contains("GLOBAL COLLISION BODY")
           && !prompt(accounts[0], linked).contains("Project version"),
           "disabling the project entry takes effect immediately and exposes the enabled global entry")

    let local = accounts[3]
    let localPrompt = prompt(local, linked)
    let localRun = RunConditions.app(local, WorkspaceInvocation(binding: linked.workspace!, room: linked.id))
    let call = #"{"skill_read":{"name":"project-procedure"}}"#
    for toolReply in [call, "I’ll read the procedure first.\n```json\n\(call)\n```\n"] {
        var localPrompts: [String] = []
        Answerer.replyForTests = { text in
            localPrompts.append(text)
            return .success(localPrompts.count == 1 ? toolReply : "Local final answer")
        }
        defer { Answerer.replyForTests = nil }
        let result = Answerer.ask(local, prompt: localPrompt, run: localRun)
        expect((try? result.get()) == "Local final answer" && localPrompts.count == 2
               && localPrompts[0].contains(#"{"skill_read":{"name":"the-skill-name"}}"#)
               && !localPrompts[0].contains("PROJECT BODY")
               && localPrompts[1].contains(projectResult),
               "Ollama reads the same wrapped body whether the JSON is bare or fenced after prose")
    }

    let filler = String(repeating: "z", count: 800)
    saveGlobal("matched-entry", "piezoresonance " + filler, "MATCHED BODY", date: 10)
    saveGlobal("older-entry", filler, "OLDER BODY", date: 20)
    saveGlobal("newest-entry", filler, "NEWEST BODY", date: 30)
    let limited = SkillLink.rule(project: own.groupKey, question: "piezoresonance", local: false)
    expect(limited.count <= 2_000 && limited.contains("matched-entry") && limited.contains("newest-entry")
           && !limited.contains("older-entry") && limited.contains("(1 omitted from the list.)"),
           "the budget includes the notice and ranks exact matches ahead of newer skills, then fills by recency")
    let justNewest = SkillLink.rule(project: own.groupKey, question: "", local: true)
    expect(justNewest.count <= 2_000 && justNewest.contains("newest-entry") && justNewest.contains("older-entry")
           && !justNewest.contains("matched-entry"), "without a match, Ollama's list fits its longer header and prioritizes recency")

    _ = try! ProjectMemoryStore.shared.accessLock(own.groupKey, protecting: schoolRoom.enterpriseLock!)
    let personalRule = prompt(accounts[0], linked), schoolRule = prompt(school, schoolRoom)
    expect(personalRule.contains("shared-procedure") && !personalRule.contains("project-procedure")
           && schoolRule.contains("shared-procedure") && schoolRule.contains("project-procedure")
           && open("project-procedure", token: member)["isError"] as? Bool == true
           && body("project-procedure", token: enterprise).contains("PROJECT BODY")
           && body("shared-procedure", token: member).contains("GLOBAL BODY"),
           "the project's saved Enterprise audience filters metadata and live reads while global skills remain shared")

    discussion.conversations[1].turns.append(ChatTurn(question: "next"))
    expect(open("shared-procedure", token: member)["isError"] as? Bool == true, "a tool session expires when a new turn starts")
}

func testSkillSave() {
    let requests = ["이걸 스킬로 만들어 줘", "이 스킬을 고쳐 줄래?", "스킬 지워", "스킬을 삭제해 주세요.",
                    "Make this a skill.", "Could you update the `paper-review` skill?", "Please delete the project skill.",
                    "스킬 수정 해줘", "스킬로 저장 해 줘", "스킬 삭제 해줘", "스킬로 저장 좀 해줘", "스킬 하나 만들어줘",
                    "OK, make this a skill", "Now make this a skill", "Let's make this a skill",
                    "Also update the skill", "Add this to my skills"]
    let other = ["스킬을 만들어 주지 마", "스킬을 삭제하지 마.", "Don't update the skill.", "How do I make this a skill?",
                 "Explain how to update the skill.", "Please update the skill detector.", "Make this a skill test.",
                 "스킬을 만드는 법 알려줘", "스킬 저장 구현해 줘", "> 스킬을 지워",
                 "스킬을 수정했어.", "스킬 수정 하지 마", "스킬로 저장 좀 하지 마", "OK, don't make this a skill",
                 "Now explain how to add this to my skills", "예: “스킬로 만들어”", "Example: `make this a skill`",
                 "~~~\nDelete the skill.\n~~~", "스킬 도구는 \"스킬 지워\" 요청에서만 노출해 줘"]
    expect(requests.allSatisfy(SkillLink.asksToEdit) && !other.contains(where: SkillLink.asksToEdit),
           "explicit Korean and English skill edits open the gate, advice, examples and negatives do not")
    // A "~지 마" about something else, joined by a comma or "근데/but", leaves the skill request standing.
    let mixed = ["이거 스킬로 만들어, 근데 파일은 건드리지 마", "이거 스킬로 만들어 근데 코드는 고치지 마", "스킬로 저장해 줘, 하지만 커밋은 하지 마",
                 "파일은 건드리지 마, 스킬로 만들어 줘", "스킬로 만들어 줘 단, 다른 파일은 수정하지 마", "스킬로 만들어 줘 단 테스트는 돌리지 마",
                 "이 스킬 지워 줘, 다만 다른 스킬은 지우지 마", "Make this a skill, but don't change the code.",
                 "Make this a skill and don't edit any files", "Don't change any files, but make this a skill.",
                 "Save this as a skill; do not commit", "Delete the old skill though don't remove the notes"]
    let forbidden = ["스킬 만들지 마", "스킬로 저장하지 말고 답만 해", "don't save it as a skill", "스킬 지우지 마",
                     "Don't make this a skill, just answer.", "스킬로 만들지 마, 그냥 설명만 해", "스킬로 만들어, 아니 만들지 마",
                     "스킬로 만들어 줘, 아니 그냥 하지 마", "Make this a skill, actually don't.", "Do not, under any circumstances, make this a skill",
                     "Never, make this a skill", "파일은 건드리지 마, 예: \"스킬로 만들어\"", "Don't touch anything; `make this a skill` is just an example"]
    expect(mixed.allSatisfy(SkillLink.asksToEdit) && !forbidden.contains(where: SkillLink.asksToEdit),
           "a negation stops only its own part of the sentence, unless it takes the whole request back")
    expect(MemoryStore.asksToRemember("이거 기억해 줘, 근데 파일은 건드리지 마") && MemoryStore.asksToRemember("내가 COMSOL 쓰는 거 기억해, 그건 기억하지 마")
           && MemoryStore.asksToRemember("I don't remember the name, but remember that I use COMSOL")
           && !MemoryStore.asksToRemember("기억해 줘, 아니 기억하지 마") && !MemoryStore.asksToRemember("이건 기억하지 마")
           && !MemoryStore.asksToRemember("Remember this, actually don't") && !MemoryStore.asksToRemember("Don't remember that, just answer")
           && MemoryStore.asksNotToSave("내가 COMSOL 쓰는 거 기억해, 그건 기억하지 마"),
           "memory saving uses the same parts; a \"기억하지 마\" anywhere still stops auto proposals")
    expect(MemoryStore.asksToChangeMemory("그 기억 고쳐 줘, 근데 파일은 지우지 마") && MemoryStore.asksToChangeMemory("Update your memory, but don't touch the code")
           && !MemoryStore.asksToChangeMemory("파일 고쳐 줘, 근데 지우지 마") && !MemoryStore.asksToChangeMemory("그 기억은 지우지 마"),
           "memory change tools still need a memory word, and a nearby negation does not hide one")

    let global = SkillStore.shared, projects = ProjectSkillStore.shared
    let fm = FileManager.default
    let project = ProjectBinding(root: "", common: "", remote: "", remoteURL: "", kind: "folderless", id: ProjectBinding.newID())
    expect(ProcessInfo.processInfo.environment["AI_ILLUMINATI_TEST_HOME"] == AccountStore.home && global.list().isEmpty,
           "skill edit tools only exercise an empty test catalog")
    defer {
        try? fm.removeItem(at: SkillStore.folder)
        try? fm.removeItem(at: ProjectMemoryStore.folder(project.groupKey))
    }

    let discussion = Discussion(model: AppModel(persist: false))
    let member = Account(id: "skill-writer", provider: .codex, name: "Codex")
    let local = Account(id: "skill-local", provider: .ollama, name: "Ollama")
    let school = Account(id: "skill-enterprise", provider: .codex, name: "ChatGPT (School)", school: true)
    var plain = Conversation(), linked = Conversation(), enterprise = Conversation()
    linked.workspace = WorkspaceBinding(roots: [], project: project, face: true)
    enterprise.enterpriseLock = Enterprise.organizations([school]).first
    func turn(_ question: String) -> ChatTurn {
        var turn = ChatTurn(question: question)
        turn.mode = 0
        return turn
    }
    plain.turns = [turn(requests[0])]
    linked.turns = [turn(requests[5])]
    enterprise.turns = [turn(requests[0])]
    discussion.conversations = [plain, linked, enterprise]
    let hub = ToolHub(providers: { ToolHub.appProviders }, listenOnRegister: false)
    func token(_ chat: Conversation, _ account: Account = member, origin: ToolOrigin = .member, allowsSkillEdits: Bool = true) -> String {
        hub.register(room: chat.id, roots: [], asker: account, origin: origin, allowsSkillEdits: allowsSkillEdits)
    }
    func definitions(_ token: String) -> [[String: Any]] {
        hub.handle(["op": "tools", "session": token])["tools"] as? [[String: Any]] ?? []
    }
    func toolNames(_ token: String) -> [String] { definitions(token).compactMap { $0["name"] as? String } }
    func response(_ token: String, _ name: String, _ args: [String: String]) -> [String: Any] {
        hub.handle(["op": "call", "session": token, "name": name, "arguments": args])
    }
    func call(_ token: String, _ name: String, _ args: [String: String]) -> Bool {
        response(token, name, args)["isError"] as? Bool == false
    }
    func args(_ name: String, _ scope: String = "global", _ body: String = "Check the assumptions.") -> [String: String] {
        ["name": name, "description": "Review the result", "body": body, "scope": scope]
    }

    let initial = token(plain)
    let definition = definitions(initial).first { $0["name"] as? String == "skill_save" }
    let schema = definition?["inputSchema"] as? [String: Any]
    expect((schema?["required"] as? [String]) == ["name", "description", "body", "scope"]
           && (definition?["description"] as? String)?.contains("reusable procedures only") == true
           && !toolNames(initial).contains("skill_delete"),
           "save is offered even with an empty catalog and advertises the global data rule")
    expect(!call(initial, "skill_save", args("review", "project"))
           && !call(initial, "skill_save", args("review", "other"))
           && !call(initial, "skill_save", args("review", "global", " "))
           && !call(initial, "skill_delete", ["name": "review"]),
           "plain project scope, invalid scope, empty bodies and unrequested deletion are refused")
    expect(!toolNames(token(plain, origin: .side)).contains("skill_save")
           && !toolNames(token(plain, origin: .consulted)).contains("skill_save")
           && !toolNames(token(enterprise, school)).contains("skill_save"),
           "side answers, consulted AIs and Enterprise chats cannot write skills")
    // "건드리지 말고" makes the route ONE (Route.adjust): that answer runs in the read-only opinion view, and the save stays open.
    let readOnly = "이거 스킬로 만들어 줘, 근데 파일은 건드리지 말고"
    var opinion = Conversation()
    opinion.workspace = WorkspaceBinding(roots: [], project: project, face: true)
    opinion.turns = [turn(readOnly)]
    discussion.conversations.append(opinion)
    let view = opinion.workspace!.opinion(chatFolder: AccountStore.home)
    let routed = hub.register(room: opinion.id, roots: view.roots, projectRun: view.projectRunID, asker: member,
                              origin: view.origin ?? .member, allowsSkillEdits: view.allowsSkillEdits != false)
    expect(Route.adjust(.work, question: readOnly) == .one && view.offersChatTools && toolNames(routed).contains("skill_save"),
           "a message routed to one AI by \"건드리지 말고\" still offers the requested skill save")
    expect(call(initial, "skill_save", args("review"))
           && global.read("review")?.record.createdBy == .user && global.read("review")?.record.userLocked == true,
           "a direct save is attributed to the user and locked")
    let creation = SkillLink.changes(global.history(), for: plain.turns[0].id).first!
    expect(creation.action == .add && creation.name == "review", "the save is attached to the answer")
    let companion = SkillStore.folder.appendingPathComponent("review/worksheet.txt")
    try! Data("Useful worksheet".utf8).write(to: companion)
    let otherFolder = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("skill-save-link-target")
    try! fm.createDirectory(at: otherFolder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: otherFolder) }
    try! fm.createSymbolicLink(at: SkillStore.folder.appendingPathComponent("link-to-other"), withDestinationURL: otherFolder)
    expect(!call(initial, "skill_save", args("link-to-other"))
           && !fm.fileExists(atPath: otherFolder.appendingPathComponent("SKILL.md").path),
           "saving cannot create a document through a symlinked skill folder")

    let projectToken = token(linked)
    _ = projects.save(name: "work-review", description: "Review a draft", body: "Original.", by: .meeting, project: project.groupKey)
    let reviewer = token(linked, allowsSkillEdits: false)
    expect(toolNames(reviewer).contains("skill_read") && !toolNames(reviewer).contains("skill_save")
           && !call(reviewer, "skill_save", args("work-review", "project"))
           && call(reviewer, "skill_read", ["name": "work-review"]),
           "a supplemental reviewer can read skills while the requested write belongs to the answering AI")
    var reviewBinding = linked.workspace!
    reviewBinding.allowsSkillEdits = false
    let reviewRun = RunConditions.app(local, WorkspaceInvocation(binding: reviewBinding, room: linked.id))
    expect(reviewRun.readSkill?("work-review").contains("Original.") == true && reviewRun.editSkill == nil,
           "the local reviewer can also read skills")
    let updated = response(projectToken, "skill_save", args("work-review", "project", "Updated."))
    expect(updated["isError"] as? Bool == false
           && (updated["content"] as? [[String: String]])?.first?["text"] == L("스킬 고침 · ", "Skill updated · ") + "work-review"
           && projects.read("work-review", project: project.groupKey)?.record.createdBy == .user
           && projects.read("work-review", project: project.groupKey)?.record.userLocked == true,
           "updates keep their project scope and claim the user lock, including for AI-authored skills")
    let update = SkillLink.changes(projects.history(project.groupKey), for: linked.turns[0].id).first!
    expect(update.action == .update, "the reply gets an update receipt")
    if case .undone = SkillLink.undo(update, project: project.groupKey) {} else { fatalError("update Undo failed") }
    expect(projects.read("work-review", project: project.groupKey)?.document.body == "Original."
           && projects.read("work-review", project: project.groupKey)?.record.createdBy == .meeting
           && SkillLink.changes(projects.history(project.groupKey), for: linked.turns[0].id).isEmpty,
           "Undo restores body and attribution, and removes the receipt")

    discussion.conversations[0].turns.append(turn("Delete the skill."))
    let removing = token(plain)
    expect(!call(initial, "skill_save", args("stale")) && !toolNames(removing).contains("skill_save")
           && call(removing, "skill_delete", ["name": "review"]), "stale save sessions close and a direct delete succeeds")
    let deletionTurn = discussion.conversations[0].turns.last!.id
    let deletion = SkillLink.changes(global.history(), for: deletionTurn).first!
    expect(deletion.action == .delete && global.read("review") == nil && global.tombstones().contains { $0.name == "review" }
           && fm.fileExists(atPath: companion.path), "delete leaves a tombstone and keeps companion files for Undo")
    if case .refused = global.save(name: "review", description: "New procedure", body: "Different.", by: .user) {}
    else { fatalError("a replacement must not adopt files from the deleted skill") }
    if case .refused = SkillLink.undo(creation, project: nil) {} else { fatalError("older Undo must refuse a newer same-skill delete") }
    _ = global.save(name: "unrelated", description: "Another procedure", body: "Continue.", by: .user)
    if case .undone = SkillLink.undo(deletion, project: nil) {} else { fatalError("delete Undo failed after an unrelated save") }
    expect(global.read("review")?.record.userLocked == true && global.tombstones().isEmpty && global.read("unrelated") != nil,
           "Undo restores the right locked skill and clears its tombstone")
    if case .undone = SkillLink.undo(creation, project: nil) {} else { fatalError("creation Undo failed") }
    expect(global.read("review") == nil && global.read("unrelated") != nil && fm.fileExists(atPath: companion.path),
           "creation Undo removes only the skill document it saved")
    discussion.conversations[0].turns[1].answeredAt = Date()
    expect(!toolNames(removing).contains("skill_delete") && !call(removing, "skill_delete", ["name": "unrelated"]),
           "the completed answer's session loses write tools")
    discussion.conversations[0].turns.append(turn("OK, make this a skill."))
    expect(!call(token(plain), "skill_save", args("review")) && global.read("review") == nil
           && (try? String(contentsOf: companion, encoding: .utf8)) == "Useful worksheet",
           "saving after creation Undo refuses the occupied directory and preserves its files")
    discussion.conversations[0].turns.append(turn("How do I save this as a skill?"))
    let advice = token(plain)
    expect(!toolNames(advice).contains("skill_save") && !call(advice, "skill_save", args("unrequested")),
           "ordinary questions leave the tools closed")

    discussion.conversations[1].turns.append(turn("Save this as a project skill."))
    let invocation = WorkspaceInvocation(binding: linked.workspace!, room: linked.id)
    let instruction = discussion.soloInstruction(local, binding: linked.workspace!, helper: "", chat: linked.id)
    let run = RunConditions.app(local, invocation)
    var prompts: [String] = []
    Answerer.replyForTests = { text in
        prompts.append(text)
        switch prompts.count {
        case 1: return .success(#"{"skill_save":{"name":"local-review","description":"Review","body":"Check the work.","scope":"project"}}"#)
        case 2: return .success(#"{"skill_save":{"name":"local-review","description":"Review","body":"Do something else.","scope":"project"}}"#)
        default: return .success("Saved")
        }
    }
    defer { Answerer.replyForTests = nil }
    expect((try? Answerer.ask(local, prompt: instruction, run: run).get()) == "Saved"
           && instruction.contains("\"skill_save\"") && prompts.count == 3
           && prompts[1].contains("local-review") && prompts[2].contains("local-review")
           && projects.read("local-review", project: project.groupKey)?.document.body == "Check the work."
           && projects.read("local-review", project: project.groupKey)?.record.userLocked == true
           && SkillLink.changes(projects.history(project.groupKey), for: discussion.conversations[1].turns.last!.id).map(\.action) == [.add],
           "Ollama receives the first result again after trying a write with different arguments")

    _ = projects.save(name: "unrelated", description: "Project-only variant", body: "Check.", by: .user, project: project.groupKey)
    discussion.conversations[1].turns.append(turn("Delete the project skill."))
    let projectDelete = token(linked)
    expect(!call(projectDelete, "skill_delete", ["name": "unrelated"])
           && global.read("unrelated") != nil && projects.read("unrelated", project: project.groupKey) != nil,
           "an ambiguous name leaves both scopes intact")
    expect(call(projectDelete, "skill_delete", ["name": "local-review"])
           && projects.read("local-review", project: project.groupKey) == nil,
           "a project answer can delete a uniquely named project skill")
}

func testKnowledgeCandidates() {
    let home = URL(fileURLWithPath: AccountStore.home, isDirectory: true)
    expect(ProcessInfo.processInfo.environment["AI_ILLUMINATI_TEST_HOME"] == home.path, "candidates use the isolated test home")
    let project = ProjectBinding(root: "", common: "", remote: "", remoteURL: "", kind: "folderless", id: ProjectBinding.newID())
    let projectFile = ProjectMemoryStore.folder(project.groupKey).appendingPathComponent("knowledge-candidates.jsonl")
    let globalFile = URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("knowledge-candidates.jsonl")
    let todoFile = home.appendingPathComponent("knowledge-candidates-todos.json")
    let fm = FileManager.default, previousTodos = TodoStore.shared, memory = MemoryStore.shared
    let previousMemory = memory.snapshot
    TodoStore.shared = TodoStore(url: todoFile)
    let legacy = try! JSONDecoder().decode(MemoryData.self, from: Data(#"{"autoSave":false,"enabled":true}"#.utf8))
    memory.update { $0 = legacy }
    defer {
        TodoStore.shared = previousTodos
        memory.update { $0 = previousMemory }
        for file in [globalFile, projectFile.deletingLastPathComponent(), todoFile] { try? fm.removeItem(at: file) }
    }

    let member = Account(id: "proposer", provider: .codex, name: "ChatGPT")
    let school = Account(id: "school-proposer", provider: .gemini, name: "Gemini (School)", school: true)
    let local = Account(id: "local-proposer", provider: .ollama, name: "Ollama")
    func turn(_ question: String = "Check the result.") -> ChatTurn {
        var turn = ChatTurn(question: question)
        turn.mode = 0
        return turn
    }
    let binding = WorkspaceBinding(roots: [], project: project, face: true)
    let plain = Conversation(turns: [turn()])
    let linked = Conversation(turns: [turn()], workspace: binding)
    let enterprise = Conversation(turns: [turn()], workspace: binding, enterpriseLock: Enterprise.organizations([school]).first)
    let todoRoom = Conversation(turns: [turn()], workspace: binding)
    let list = TodoList(title: "Candidate tests", project: project)
    var todo = TodoItem(listID: list.id, title: "Check the result")
    todo.room = todoRoom.id
    todo.state = .running
    try! TodoStore.shared.update { $0.lists = [list]; $0.items = [todo] }
    let discussion = Discussion(model: AppModel(persist: false))
    discussion.conversations = [plain, linked, enterprise, todoRoom]
    let hub = ToolHub(providers: { ToolHub.appProviders }, listenOnRegister: false)
    let run = ProjectRun(room: todoRoom.id, binding: project, token: DebateCancellation())
    ProjectWork.register(run)
    defer { ProjectWork.finish(run) }

    func token(_ chat: Conversation, _ account: Account = member, origin: ToolOrigin = .member,
               allowsSkillEdits: Bool = true, run: ProjectRun? = nil) -> String {
        hub.register(room: chat.id, roots: [], projectRun: run?.id, generation: run?.generation,
                     asker: account, origin: origin, allowsSkillEdits: allowsSkillEdits)
    }
    func tools(_ token: String) -> [[String: Any]] {
        (hub.handle(["op": "tools", "session": token])["tools"] as? [[String: Any]] ?? [])
            .filter { ($0["name"] as? String)?.hasSuffix("_propose") == true }
    }
    func names(_ token: String) -> Set<String> { Set(tools(token).compactMap { $0["name"] as? String }) }
    func call(_ token: String, _ name: String, _ args: [String: Any]) -> (ok: Bool, text: String) {
        let reply = hub.handle(["op": "call", "session": token, "name": name, "arguments": args])
        return (reply["isError"] as? Bool == false, (reply["content"] as? [[String: String]])?.first?["text"] ?? "")
    }
    func skill(_ scope: String) -> [String: String] {
        ["name": "verify-result", "description": "Use when reviewing output", "body": "Check assumptions.\nRun the relevant tests.",
         "scope": scope, "evidence": "Regression test passed at commit 0123456789abcdef0123456789abcdef01234567.", "replaces": "verify-output"]
    }
    let fact = ["text": "사용자는 결과를 표로 정리하는 걸 선호한다.", "evidence": "User corrected the result format.", "replaces_id": "a1b2c3d4"]
    func lines(_ file: URL) -> [[String: Any]] {
        (try! String(contentsOf: file, encoding: .utf8)).split(separator: "\n").map {
            try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }
    func permissions(_ file: URL) -> Int? {
        (try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions] as? Int
    }

    let plainToken = token(plain), projectToken = token(linked), enterpriseToken = token(enterprise, school)
    let todoToken = token(todoRoom, run: run), both: Set = ["skill_propose", "memory_propose"]
    expect(names(plainToken) == both && names(projectToken) == both && names(todoToken) == both
           && names(enterpriseToken) == ["skill_propose"] && names(token(enterprise)).isEmpty,
           "old settings still enable both tools for plain, project and TODO answers; Enterprise gets only skills")
    expect(names(token(plain, local)).isEmpty && names(token(plain, origin: .side)).isEmpty
           && names(token(plain, origin: .consulted)).isEmpty && names(token(linked, allowsSkillEdits: false)).isEmpty,
           "local models, helpers and supplemental reviewers do not get proposal tools")
    for definition in tools(plainToken) {
        let schema = definition["inputSchema"] as? [String: Any]
        expect((schema?["required"] as? [String])?.contains("evidence") == true, "evidence is required in both tool schemas")
    }
    let missing = call(plainToken, "memory_propose", ["text": fact["text"]!])
    let blank = call(projectToken, "skill_propose", skill("project").merging(["evidence": " \n "]) { _, new in new })
    expect(!missing.ok && !blank.ok && missing.text == blank.text
           && !fm.fileExists(atPath: globalFile.path) && !fm.fileExists(atPath: projectFile.path),
           "missing or whitespace evidence never saves or takes the quota")
    expect(!call(enterpriseToken, "memory_propose", fact).ok && !call(plainToken, "skill_propose", skill("project")).ok,
           "direct calls cannot bypass Enterprise or project scope")
    memory.update { $0.autoPropose = false }
    expect(names(plainToken) == ["skill_propose"] && !call(plainToken, "memory_propose", fact).ok,
           "the candidate setting can turn off user memory proposals")
    memory.update { $0.autoPropose = true }
    var wrongType: [String: Any] = fact
    wrongType["replaces_id"] = 123
    expect(!call(plainToken, "memory_propose", wrongType).ok, "a replacement ID of the wrong type is refused")
    expect(call(plainToken, "memory_propose", fact).ok, "memory proposal with evidence succeeds")
    let duplicate = call(plainToken, "skill_propose", skill("global"))
    expect(!duplicate.ok && duplicate.text.contains(L("한 답", "per answer")), "the two tools share one quota per turn")
    var enterpriseSkill: [String: Any] = skill("project")
    enterpriseSkill["replaces"] = NSNull()
    expect(call(enterpriseToken, "skill_propose", enterpriseSkill).ok, "Enterprise skill proposals accept null replacements")
    expect(call(todoToken, "skill_propose", skill("project")).ok, "a project TODO writes its candidate")
    let rows = lines(projectFile), globalRows = lines(globalFile)
    expect(rows.count == 2 && globalRows.count == 1, "submissions preserve earlier JSONL lines in each scope")
    expect(permissions(globalFile) == 0o600 && permissions(projectFile) == 0o600,
           "both inbox files are readable and writable by their owner only")
    let memoryRow = globalRows[0]
    let todoRow = rows[1], todoTurn = todoRoom.turns[0].id
    expect(rows[0]["accountID"] as? String == school.id && (rows[0]["content"] as? [String: String])?["replaces"] == nil
           && todoRow["todoID"] as? String == todo.id.uuidString
           && todoRow["chatID"] as? String == todoRoom.id.uuidString && todoRow["turnID"] as? String == todoTurn.uuidString
           && todoRow["createdAt"] is String && todoRow["kind"] as? String == "skill" && todoRow["state"] as? String == "pending"
           && (todoRow["content"] as? [String: String])?["body"] == skill("project")["body"]
           && (todoRow["content"] as? [String: String])?["replaces"] == "verify-output"
           && todoRow["evidence"] as? String == skill("project")["evidence"],
           "project JSONL carries scope, source, metadata, evidence and a multiline body on one line per candidate")
    expect(memoryRow["kind"] as? String == "memory" && memoryRow["accountName"] as? String == member.name
           && (memoryRow["content"] as? [String: String])?["replaces_id"] == "a1b2c3d4" && memory.snapshot.items.isEmpty
           && ProjectSkillStore.shared.read("verify-result", project: project.groupKey) == nil,
           "the global JSONL carries memory content and neither candidate activated")
    let reopened = KnowledgeCandidates()
    let receipt = reopened.pending(chat: todoRoom.id, turn: todoTurn)!
    try! fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: projectFile.path)
    expect(receipt.uuidString == todoRow["id"] as? String && !reopened.drop(receipt, chat: plain.id, turn: todoTurn)
           && reopened.drop(receipt, chat: todoRoom.id, turn: todoTurn)
           && reopened.pending(chat: todoRoom.id, turn: todoTurn) == nil && lines(projectFile)[1]["state"] as? String == "dropped"
           && permissions(projectFile) == 0o600, "reopening preserves the receipt and dropping it rewrites the file privately")
    discussion.conversations[3].turns.append(turn())
    let retried = call(token(todoRoom, run: run), "memory_propose", fact)
    expect(!retried.ok && retried.text.contains(L("TODO 하나", "per TODO")) && lines(globalFile).count == 1,
           "a later TODO turn in another scope cannot replace its dropped candidate")
    expect(!call(todoToken, "skill_propose", skill("project")).ok, "the earlier TODO session is closed")
    try! TodoStore.shared.change(todo.id) { $0.state = .done }
    discussion.conversations[3].turns.append(turn())
    let followUp = fact.merging(["replaces_id": " \n "]) { _, new in new }
    expect(call(token(todoRoom), "memory_propose", followUp).ok, "a follow-up can propose a memory with a blank replacement ID")
    let nextRow = lines(globalFile).last
    expect(nextRow?["todoID"] == nil && (nextRow?["content"] as? [String: String])?["replaces_id"] == nil,
           "an ordinary follow-up has its own quota and a blank replacement ID is omitted")
    discussion.conversations[0].turns.append(turn("기억하지 마"))
    expect(names(plainToken).isEmpty && names(token(plain)) == ["skill_propose"],
           "an older session expires and the user's do-not-remember instruction is respected")
}


// Knowledge review (회의 1/3): a fake meeting decides the pending candidates; the app checks the JSON, applies add/modify
// for skills and memory, keeps 🔒 skills and the user's own facts for approval, records the review and undoes it whole.
func testKnowledgeReview() {
    let home = URL(fileURLWithPath: AccountStore.home, isDirectory: true)
    expect(ProcessInfo.processInfo.environment["AI_ILLUMINATI_TEST_HOME"] == home.path, "the review uses the isolated test home")
    let fm = FileManager.default, memory = MemoryStore.shared, previousMemory = memory.snapshot
    let aside = home.appendingPathComponent("review-aside-\(UUID().uuidString.prefix(8))")
    let moved = [SkillStore.folder, KnowledgeCandidates.file(nil), KnowledgeReview.file,
                 KnowledgeReview.attemptFile, KnowledgeReview.logFile]
    try? fm.createDirectory(at: aside, withIntermediateDirectories: true)
    for (i, url) in moved.enumerated() where fm.fileExists(atPath: url.path) {
        try! fm.moveItem(at: url, to: aside.appendingPathComponent("\(i)"))
    }
    let project = ProjectBinding(root: "", common: "", remote: "", remoteURL: "", kind: "folderless", id: ProjectBinding.newID())
    let key = project.groupKey
    defer {
        memory.update { $0 = previousMemory }
        try? fm.removeItem(at: ProjectMemoryStore.folder(key))
        for (i, url) in moved.enumerated() {
            try? fm.removeItem(at: url)
            if fm.fileExists(atPath: aside.appendingPathComponent("\(i)").path) { try? fm.moveItem(at: aside.appendingPathComponent("\(i)"), to: url) }
        }
        try? fm.removeItem(at: aside)
    }
    memory.update { $0 = MemoryData() }

    let global = SkillStore.shared, scoped = ProjectSkillStore.shared
    _ = global.save(name: "locked-steps", description: "Steps the user wrote", body: "User body", by: .user)
    _ = global.save(name: "review-output", description: "Use when reviewing generated output", body: "Old body", by: .meeting, isNew: false)
    guard case .saved(let userFact) = memory.remember("사용자는 표 정리를 선호한다", room: nil, turn: nil, roomTitle: nil, by: "Claude"),
          case .saved(let reviewFact) = memory.remember("답은 짧게 쓴다", room: nil, turn: nil, roomTitle: nil, by: "Review", meeting: UUID())
    else { expect(false, "memory fixtures saved"); return }
    let lockedBefore = global.read("locked-steps")

    let plain = Conversation(turns: [ChatTurn(question: "q")])
    let linked = Conversation(turns: [ChatTurn(question: "q")], workspace: WorkspaceBinding(roots: [], project: project, face: true))
    let school = Account(id: "review-school", provider: .gemini, name: "Gemini (School)", school: true)
    let locked = Conversation(turns: [ChatTurn(question: "q")], enterpriseLock: Enterprise.organizations([school]).first)
    let inbox = KnowledgeCandidates.shared
    func propose(_ kind: KnowledgeCandidate.Kind, _ content: [String: String], chat: Conversation, project: String? = nil) {
        let row = KnowledgeCandidate(kind: kind, content: content, evidence: "test passed", accountID: "a", accountName: "ChatGPT",
                                     chatID: chat.id, turnID: UUID(), todoID: nil)
        expect(inbox.submit(row, project: project) == nil, "candidate submitted")
    }
    func skill(_ name: String, _ body: String, scope: String = "global") -> [String: String] {
        ["name": name, "description": "Use when \(name.replacingOccurrences(of: "-", with: " "))", "body": body, "scope": scope]
    }
    propose(.skill, skill("first-steps", "Write the plan first."), chat: plain)
    propose(.skill, skill("review-output-better", "Check the diff, then run the tests."), chat: plain)
    propose(.skill, skill("locked-steps", "AI body"), chat: plain)
    propose(.skill, skill("plot-results", "Open result.csv and plot it."), chat: linked)
    propose(.skill, skill("tune-drive", "Drive the transducer at 2 MHz."), chat: plain)
    propose(.memory, ["text": "사용자는 드립 커피를 좋아한다"], chat: plain)
    propose(.memory, ["text": "사용자는 표보다 목록을 선호한다", "replaces_id": userFact.shortID], chat: plain)
    propose(.memory, ["text": "답은 짧고 직설적으로 쓴다"], chat: plain)
    propose(.memory, ["text": "오늘 점심은 국수"], chat: plain)
    propose(.skill, skill("secret-org-steps", "Enterprise only"), chat: locked)
    propose(.skill, skill("project-build", "Build with the project's script.", scope: "project"), chat: linked, project: key)
    propose(.memory, ["text": "아직 정하지 못한 후보"], chat: plain)
    let rows = (try? inbox.pendingRows().map(\.candidate)) ?? []
    func id(_ value: String) -> String {
        let row = rows.first { $0.content["name"] == value || $0.content["text"] == value }!
        return "c:" + String(row.id.uuidString.prefix(8)).lowercased()
    }
    let reviewSkill = global.list().first { $0.name == "review-output" }!
    let locks = global.list().first { $0.name == "locked-steps" }!
    let decisions = """
    The meeting agreed:
    ```json
    [{"candidate":"\(id("first-steps"))","action":"add","scope":"global","name":"first-steps","description":"Use before coding","body":"Write the plan first.","reason":"반복 절차"},
     {"candidate":"\(id("review-output-better"))","action":"modify","target":"s:\(String(reviewSkill.id.uuidString.prefix(8)))","scope":"global","name":"review-output","description":"Use when reviewing generated output","body":"Check the diff, then run the tests.","reason":"기존 스킬과 합침"},
     {"candidate":"\(id("locked-steps"))","action":"modify","target":"\(locks.id.uuidString)","scope":"global","name":"locked-steps","description":"Steps the user wrote","body":"AI body","reason":"개선"},
     {"candidate":"\(id("plot-results"))","action":"add","scope":"global","reason":"전역으로"},
     {"candidate":"\(id("tune-drive"))","action":"add","scope":"global","reason":"전역으로"},
     {"candidate":"\(id("사용자는 드립 커피를 좋아한다"))","action":"add","text":"사용자는 드립 커피를 선호한다","reason":"취향"},
     {"candidate":"\(id("사용자는 표보다 목록을 선호한다"))","action":"modify","target":"m:\(userFact.shortID)","text":"사용자는 표보다 목록을 선호한다","reason":"정정"},
     {"candidate":"\(id("답은 짧고 직설적으로 쓴다"))","action":"modify","target":"m:\(reviewFact.shortID)","text":"답은 짧고 직설적으로 쓴다","reason":"합침"},
     {"candidate":"\(id("오늘 점심은 국수"))","action":"drop","reason":"일회성"},
     {"candidate":"\(id("project-build"))","action":"add","scope":"project","reason":"프로젝트 절차"},
     {"candidate":"\(id("first-steps"))","action":"drop","reason":"a second decision is ignored"}]
    ```
    """
    expect(KnowledgeReview.decisions(from: #"[{"candidate":"c:1","action":"merge","reason":"x"}]"#) == nil
           && KnowledgeReview.decisions(from: "no list") == nil && KnowledgeReview.decisions(from: decisions)?.count == 11,
           "an unknown action or missing list decodes to nothing; a fenced list decodes")

    let model = AppModel(persist: false)
    model.accounts = [Account(id: "review-claude", provider: .claude, name: "Claude"), Account(id: "review-codex", provider: .codex, name: "ChatGPT")]
    let discussion = Discussion(model: model)
    discussion.conversations = [plain, linked, locked]
    let promptLock = NSLock()
    var speeches: [String] = []
    var answer = "not JSON at all"
    discussion.workspaceAnswer = { _, prompt, _, _, _ in
        if prompt.contains("[MEETING RESULT]") { return .success(answer) }
        if prompt.contains("[MODE3 MODERATION]") { return .success(#"{"action":"finish","reason":"enough"}"#) }
        if prompt.contains("[MODE3 SPEECH]") { promptLock.lock(); speeches.append(prompt); promptLock.unlock() }
        return .success("Merge where a saved skill covers it.")
    }
    func waitForMeeting() {
        let deadline = Date().addingTimeInterval(20)
        while (discussion.anyRunning || KnowledgeReviewLink.running) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        expect(!discussion.anyRunning && !KnowledgeReviewLink.running, "the background review finished")
    }
    model.accounts.removeLast()
    expect(!KnowledgeReviewLink.run(in: discussion), "one AI cannot hold a review")
    model.accounts.append(Account(id: "review-codex", provider: .codex, name: "ChatGPT"))

    expect(KnowledgeReviewLink.run(in: discussion) && !KnowledgeReviewLink.run(in: discussion), "one review runs at a time")
    waitForMeeting()
    expect(KnowledgeReview.records().isEmpty && global.read("first-steps") == nil && memory.snapshot.items.count == 2
           && ((try? inbox.pendingRows().count) ?? 0) == 12, "a broken result applies nothing and leaves every candidate pending")
    expect(speeches.count == 2 && speeches.allSatisfy { p in
        ["[Review material]", id("first-steps"), "Write the plan first.", "[s:\(String(reviewSkill.id.uuidString.prefix(8)).lowercased())]",
         "locked-steps 🔒", "[m:\(userFact.shortID)]", "the user's", "no data", "project-build"].allSatisfy(p.contains)
            && !p.contains("Enterprise only") && !p.contains("[User]")
    }, "both AIs see candidates, similar saved skills and facts and the rules, never an Enterprise chat's candidate")

    answer = decisions
    expect(KnowledgeReviewLink.run(in: discussion), "the second review starts")
    waitForMeeting()
    guard let record = KnowledgeReview.records().last else { expect(false, "the review is recorded"); return }
    func outcome(_ value: String) -> KnowledgeReviewRecord.Outcome? {
        let candidate = rows.first { $0.content["name"] == value || $0.content["text"] == value }!.id
        return record.outcomes.first { $0.candidate == candidate }
    }
    let added = global.read("first-steps")
    expect(added?.record.createdBy == .meeting && added?.record.enabled == true && added?.record.isNew == true
           && added?.record.userLocked == false && added?.document.description == "Use before coding",
           "an added global skill is by the meeting, on and new, with the meeting's wording")
    expect(global.read("review-output")?.document.body == "Check the diff, then run the tests." && global.read("review-output-better") == nil
           && outcome("review-output-better")?.result == .applied, "modify merges into the existing skill instead of adding one")
    expect(global.read("locked-steps") == lockedBefore && outcome("locked-steps")?.result == .waiting,
           "a 🔒 skill is never changed: the decision waits for approval")
    expect(global.read("plot-results") == nil && scoped.read("plot-results", project: key)?.record.createdBy == .meeting
           && outcome("plot-results")?.project == key, "a global skill with a file name goes to the proposing chat's project")
    expect(global.read("tune-drive") == nil && outcome("tune-drive")?.result == .refused,
           "a global skill with a measurement and no project is not saved")
    expect(scoped.read("project-build", project: key) != nil && record.projects == [key], "a project inbox candidate is saved in its project")
    let facts = memory.snapshot.items
    expect(facts.contains { $0.text == "사용자는 드립 커피를 선호한다" && $0.meeting == record.id }
           && facts.contains { $0.id == userFact.id && $0.text == userFact.text } && outcome("사용자는 표보다 목록을 선호한다")?.result == .waiting
           && facts.contains { $0.id == reviewFact.id && $0.text == "답은 짧고 직설적으로 쓴다" },
           "memory adds and modifies a review's fact through remember/change; the user's own fact waits")
    expect(outcome("오늘 점심은 국수")?.result == .dropped && outcome("오늘 점심은 국수")?.reason == "일회성"
           && outcome("first-steps")?.result == .applied && record.outcomes.count == 10
           && Set(record.attendees) == Set(model.accounts.map(discussion.label)) && record.candidates.count == 11,
           "the record keeps attendees, candidates, decisions and why a candidate was dropped")
    let left = (try? inbox.pendingRows().map(\.candidate)) ?? []
    expect(Set(left.compactMap { $0.content["name"] ?? $0.content["text"] }) == ["secret-org-steps", "아직 정하지 못한 후보"],
           "undecided and Enterprise candidates stay pending; decided ones leave the inbox")
    let history = global.history().filter { $0.batch == record.id }
    expect(history.count == 2 && scoped.history(key).filter { $0.batch == record.id }.count == 2, "each store's history marks the meeting's batch")

    _ = global.setEnabled("first-steps", false)
    expect(KnowledgeReview.undo(record.id) != nil && global.read("first-steps") != nil && KnowledgeReview.records().last?.undoneAt == nil,
           "a later user change to one of its skills blocks undoing the review, and nothing is undone")
    _ = global.undo()
    expect(KnowledgeReview.undo(record.id) == nil, "the whole review undoes")
    expect(global.read("first-steps") == nil && global.read("review-output")?.document.body == "Old body"
           && scoped.read("plot-results", project: key) == nil && scoped.read("project-build", project: key) == nil
           && global.read("locked-steps") == lockedBefore, "every skill the review saved or changed is back as before")
    expect(!memory.snapshot.items.contains { $0.text == "사용자는 드립 커피를 선호한다" }
           && memory.snapshot.items.contains { $0.id == reviewFact.id && $0.text == "답은 짧게 쓴다" },
           "the review's facts are taken back")
    expect(KnowledgeReview.undo(record.id) != nil && KnowledgeReview.records().last?.undoneAt != nil, "a review undoes once")

    // Guards (review fixes): applied straight, with the candidates as the meeting saw them.
    _ = global.save(name: "shared-steps", description: "Use when sharing steps", body: "Shared body", by: .meeting, isNew: false)
    guard case .saved(let edited) = memory.remember("회의가 넣은 사실", room: nil, turn: nil, roomTitle: nil, by: "Review", meeting: UUID())
    else { expect(false, "a review's fact saved"); return }
    memory.setItem(edited.id, text: "사용자가 고친 사실")
    expect(memory.snapshot.items.first { $0.id == edited.id }?.meeting == nil, "a review's fact the user edits becomes the user's")
    propose(.skill, skill("fresh-add", "Fresh body."), chat: plain)
    propose(.skill, skill("same-name", "Another body."), chat: plain)
    propose(.skill, skill("shared-better", "Not used."), chat: plain)
    propose(.skill, skill("shared-again", "Not used."), chat: plain)
    propose(.skill, skill("blank-body", "Not used."), chat: plain)
    propose(.skill, skill("project-merge", "Not used.", scope: "project"), chat: linked)
    propose(.skill, skill("dropped-meanwhile", "Dropped body."), chat: plain)
    propose(.memory, ["text": "사용자가 고친 사실 정정", "replaces_id": edited.shortID], chat: plain)
    let fresh = (try? inbox.pendingRows().map(\.candidate)) ?? []
    func row(_ value: String) -> KnowledgeCandidate { fresh.first { $0.content["name"] == value || $0.content["text"] == value }! }
    func cid(_ value: String) -> String { "c:" + String(row(value).id.uuidString.prefix(8)).lowercased() }
    let shared = global.list().first { $0.name == "shared-steps" }!
    let sid = "s:" + String(shared.id.uuidString.prefix(8)).lowercased()
    let gone = row("dropped-meanwhile")
    let names: Set = ["fresh-add", "same-name", "shared-better", "shared-again", "blank-body", "project-merge", "dropped-meanwhile", "사용자가 고친 사실 정정"]
    let shown = KnowledgeReviewLink.eligible(discussion).filter { names.contains($0.row.content["name"] ?? $0.row.content["text"] ?? "") }
    expect(shown.count == 8, "the meeting is shown every new candidate")
    expect(inbox.drop(gone.id, chat: gone.chatID, turn: gone.turnID), "a candidate is dropped in its chat while the meeting runs")
    let guards: [KnowledgeDecision] = KnowledgeReview.decisions(from: """
    Agreed:
    ```json
    [{"candidate":"\(cid("fresh-add"))","action":"add","scope":"global","body":"Fresh body.\\n```\\nrun it\\n```","reason":"새 절차"},
     {"candidate":"\(cid("same-name"))","action":"add","scope":"global","name":"shared-steps","reason":"같은 이름"},
     {"candidate":"\(cid("shared-better"))","action":"modify","target":"\(sid)","description":"Use when sharing steps with others","reason":"설명만"},
     {"candidate":"\(cid("shared-again"))","action":"modify","target":"\(sid)","body":"Second body","reason":"또 고침"},
     {"candidate":"\(cid("blank-body"))","action":"add","scope":"global","body":"   ","reason":"빈 본문"},
     {"candidate":"\(cid("project-merge"))","action":"modify","target":"review-output","scope":"project","body":"Merged from the project","reason":"전역에 합침"},
     {"candidate":"c:\(String(gone.id.uuidString.prefix(8)))","action":"add","scope":"global","reason":"이미 버림"},
     {"candidate":"\(cid("사용자가 고친 사실 정정"))","action":"modify","target":"M: \(edited.shortID.uppercased())","text":"사용자가 고친 사실 정정","reason":"정정"}]
    ```
    """) ?? []
    expect(guards.count == 8, "a list whose skill body has its own code fence still decodes")
    let meetingID = UUID()
    guard case .applied(let second) = KnowledgeReview.apply(guards, meeting: meetingID, attendees: ["a", "b"], candidates: shown)
    else { expect(false, "the guard review applies"); return }
    func result(_ value: String) -> KnowledgeReviewRecord.Outcome? { second.outcomes.first { $0.candidate == row(value).id } }
    let stillPending = Set(((try? inbox.pendingRows().map(\.candidate.id)) ?? []))
    expect(global.read("review-output")?.document.body == "Merged from the project" && result("project-merge")?.result == .applied
           && result("project-merge")?.project == nil, "a project candidate can modify the similar global skill it was shown")
    expect(result("fresh-add")?.result == .applied && global.read("fresh-add")?.document.body.contains("```\nrun it") == true,
           "an added skill keeps the code fence in its body")
    expect(result("same-name")?.result == .refused && stillPending.contains(row("same-name").id)
           && global.read("shared-steps")?.document.body == "Shared body",
           "add never overwrites a saved skill of that name; the candidate waits for the next review")
    expect(global.read("shared-steps")?.document.description == "Use when sharing steps with others"
           && global.read("shared-steps")?.document.body == "Shared body" && global.read("shared-steps")?.record.name == "shared-steps",
           "modify keeps the saved name and body where the decision leaves them out")
    expect(result("shared-again")?.result == .refused && stillPending.contains(row("shared-again").id),
           "a second change to the same skill in one review is not applied, and its candidate stays pending")
    expect(result("blank-body")?.result == .refused && global.read("blank-body") == nil && !stillPending.contains(row("blank-body").id),
           "a skill with an empty body is refused")
    expect(result("dropped-meanwhile") == nil && global.read("dropped-meanwhile") == nil
           && (try? inbox.pendingRows())?.contains { $0.candidate.id == gone.id } == false,
           "a candidate dropped while the meeting ran is not applied")
    expect(result("사용자가 고친 사실 정정")?.result == .waiting && memory.snapshot.items.first { $0.id == edited.id }?.text == "사용자가 고친 사실",
           "an \"M: <ID>\" target is found, and a fact the user edited waits for approval")

    let file = SkillStore.folder.appendingPathComponent("fresh-add/SKILL.md")
    let raw = try! Data(contentsOf: file)
    try! Data("---\nname: fresh-add\ndescription: edited\n---\nEdited outside\n".utf8).write(to: file)
    expect(KnowledgeReview.undo(meetingID) != nil && global.history().filter { $0.batch == meetingID && $0.action == .undo }.isEmpty
           && KnowledgeReview.records().last?.undoneAt == nil,
           "a skill edited on disk blocks the whole undo before anything changes, and the review can be undone later")
    try! raw.write(to: file)
    expect(KnowledgeReview.undo(meetingID) == nil && global.read("fresh-add") == nil
           && global.read("shared-steps")?.document.description == "Use when sharing steps" && global.read("review-output")?.document.body == "Old body",
           "the review undoes once the file is back")

    // Memory turned off, or a project with an Enterprise audience: their candidates wait.
    propose(.memory, ["text": "꺼진 동안의 후보"], chat: plain)
    propose(.skill, skill("locked-project", "Body."), chat: linked, project: key)
    memory.update { $0.enabled = false }
    var waiting = KnowledgeReviewLink.eligible(discussion)
    expect(!waiting.contains { $0.row.kind == .memory } && waiting.contains { $0.row.content["name"] == "locked-project" },
           "memory candidates wait while memory is off")
    memory.update { $0.enabled = true }
    _ = try! ProjectMemoryStore.shared.accessLock(key, protecting: locked.enterpriseLock!)
    waiting = KnowledgeReviewLink.eligible(discussion)
    expect(!waiting.contains { $0.project == key } && waiting.contains { $0.row.content["text"] == "꺼진 동안의 후보" },
           "a project with a saved Enterprise audience keeps its candidates and skills out of the review")

    testKnowledgeApproval()
    testKnowledgeReviewIdleScheduling()
}

// Approving a review's change in the Inbox (회의 3/3): a 🔒 skill and the user's own fact wait with a diff; Apply saves
// by the meeting and keeps them the user's, Reject drops, and one changed since closes without applying.
private func testKnowledgeApproval() {
    let global = SkillStore.shared, memory = MemoryStore.shared, inbox = KnowledgeCandidates.shared
    let chat = UUID()
    func propose(_ kind: KnowledgeCandidate.Kind, _ content: [String: String]) -> KnowledgeCandidate {
        let row = KnowledgeCandidate(kind: kind, content: content, evidence: "seen twice", accountID: "a", accountName: "ChatGPT",
                                     chatID: chat, turnID: UUID(), todoID: nil)
        expect(inbox.submit(row, project: nil) == nil, "approval candidate submitted")
        return row
    }
    func cid(_ row: KnowledgeCandidate) -> String { "c:" + String(row.id.uuidString.prefix(8)).lowercased() }
    for name in ["mine-apply", "mine-reject", "mine-changed"] {
        _ = global.save(name: name, description: "Steps for \(name)", body: "line 1\nline 2", by: .user)
    }
    func sid(_ name: String) -> String { "s:" + String(global.list().first { $0.name == name }!.id.uuidString.prefix(8)).lowercased() }
    guard case .saved(let keep) = memory.remember("사용자는 아침에 집중한다", room: nil, turn: nil, roomTitle: nil, by: "Claude"),
          case .saved(let edit) = memory.remember("사용자는 녹차를 마신다", room: nil, turn: nil, roomTitle: nil, by: "Claude")
    else { expect(false, "approval facts saved"); return }
    let rows = [propose(.skill, ["name": "mine-apply"]), propose(.skill, ["name": "mine-reject"]), propose(.skill, ["name": "mine-changed"]),
                propose(.memory, ["text": "사용자는 아침 일찍 집중한다", "replaces_id": keep.shortID]),
                propose(.memory, ["text": "사용자는 홍차를 마신다", "replaces_id": edit.shortID])]
    let json = """
    [{"candidate":"\(cid(rows[0]))","action":"modify","target":"\(sid("mine-apply"))","body":"line 1\\nline 2 better\\nline 3","reason":"보완"},
     {"candidate":"\(cid(rows[1]))","action":"modify","target":"\(sid("mine-reject"))","body":"AI rewrite","reason":"다시 씀"},
     {"candidate":"\(cid(rows[2]))","action":"modify","target":"\(sid("mine-changed"))","body":"AI change","reason":"정리"},
     {"candidate":"\(cid(rows[3]))","action":"modify","target":"m:\(keep.shortID)","text":"사용자는 아침 일찍 집중한다","reason":"정정"},
     {"candidate":"\(cid(rows[4]))","action":"modify","target":"m:\(edit.shortID)","text":"사용자는 홍차를 마신다","reason":"정정"}]
    """
    let meeting = UUID()
    guard let decisions = KnowledgeReview.decisions(from: json),
          case .applied(let record) = KnowledgeReview.apply(decisions, meeting: meeting, attendees: ["a", "b"],
                                                            candidates: rows.map { KnowledgeReview.Candidate(row: $0, project: nil, inProject: false) })
    else { expect(false, "the approval review applies"); return }
    expect(record.waiting == 5 && global.read("mine-apply")?.document.body == "line 1\nline 2"
           && memory.snapshot.items.first { $0.id == keep.id }?.text == keep.text, "every change to the user's skills and facts waits")

    let waiting = KnowledgeInbox.shared.items.filter { $0.review == meeting }
    expect(waiting.count == 5 && Set(waiting.map(\.id)) == Set(rows.map(\.id)), "each waiting change is one inbox item")
    let applyItem = waiting.first { $0.id == rows[0].id }!
    expect(applyItem.title.contains("mine-apply") && applyItem.reason.contains("보완")
           && applyItem.diff.contains(.init(kind: .removed, text: "line 2")) && applyItem.diff.contains(.init(kind: .added, text: "line 2 better"))
           && applyItem.diff.contains(.init(kind: .added, text: "line 3")) && applyItem.diff.contains(.init(kind: .same, text: "line 1")),
           "the item has the skill's name, the meeting's reason and a line diff of old and new")
    let factItem = waiting.first { $0.id == rows[3].id }!
    expect(!factItem.isSkill && factItem.diff == [.init(kind: .removed, text: keep.text), .init(kind: .added, text: "사용자는 아침 일찍 집중한다")],
           "a fact's item diffs the old and new line")
    let model = AppModel(persist: false)
    let discussion = Discussion(model: model)
    let board = Inbox.make(requests: [], todos: TodoData(), conversations: [], running: [], knowledge: KnowledgeInbox.shared.items)
    expect(rows.allSatisfy { row in board.check.contains { $0.id == row.id } } && board.blocked.isEmpty,
           "the Mac inbox lists them to review, not as blocked")
    let phone = RemoteChats.inbox(discussion).filter { ($0["kind"] as? String) == "knowledge" }
    expect(rows.allSatisfy { row in phone.contains { $0["approval"] as? String == row.id.uuidString } }
           && phone.contains { ($0["detail"] as? String)?.contains("+ line 2 better") == true && $0["allowLabel"] != nil },
           "the iPhone page's inbox gets the same items with their diff and Apply / Reject")
    if case .needsApproval = global.save(name: "mine-apply", description: "x", body: "y", by: .meeting, approved: "not-the-hash") {} else {
        expect(false, "a meeting save against another hash still waits")
    }

    // Apply: saved by the meeting, still 🔒 and the user's, in history under the review.
    expect(KnowledgeApproval.decide(rows[0].id, apply: true) == .applied, "Apply saves the skill")
    let applied = global.read("mine-apply")
    expect(applied?.document.body == "line 1\nline 2 better\nline 3" && applied?.record.userLocked == true && applied?.record.createdBy == .user,
           "the approved skill has the new body and stays locked and the user's")
    let entry = global.history().last
    expect(entry?.by == .meeting && entry?.batch == meeting && entry?.name == "mine-apply", "history records the meeting's change under the review")
    expect(KnowledgeApproval.decide(rows[0].id, apply: true) != .applied && !KnowledgeInbox.shared.items.contains { $0.id == rows[0].id },
           "an applied item leaves the inbox and cannot be applied twice")

    // Reject: nothing changes, the candidate is dropped.
    expect(KnowledgeApproval.decide(rows[1].id, apply: false) == .rejected && global.read("mine-reject")?.document.body == "line 1\nline 2",
           "Reject leaves the skill as it was")

    // Changed since: the user edited the skill, the fact; Apply closes the item without applying.
    _ = global.save(name: "mine-changed", description: "Steps for mine-changed", body: "user edit", by: .user)
    memory.setItem(edit.id, text: "사용자는 보리차를 마신다")
    expect(KnowledgeApproval.decide(rows[2].id, apply: true) == .changed && global.read("mine-changed")?.document.body == "user edit",
           "a skill changed since the review is not applied")
    expect(KnowledgeApproval.decide(rows[4].id, apply: true) == .changed
           && memory.snapshot.items.first { $0.id == edit.id }?.text == "사용자는 보리차를 마신다", "a fact changed since is not applied")

    // A fact: changed, still the user's.
    expect(RemoteChats.decideKnowledge(rows[3].id, apply: true) == "" && RemoteChats.decideKnowledge(UUID(), apply: true) == nil,
           "the phone's Allow applies a waiting fact; an unknown id is not a knowledge item")
    let fact = memory.snapshot.items.first { $0.id == keep.id }
    expect(fact?.text == "사용자는 아침 일찍 집중한다" && fact?.meeting == nil, "the approved fact has the new text and stays the user's")
    expect(!KnowledgeInbox.shared.items.contains { $0.review == meeting }, "nothing of the review waits any more")
    let outcomes = KnowledgeReview.records().first { $0.id == meeting }?.outcomes ?? []
    expect(outcomes.map(\.result) == [.applied, .dropped, .refused, .applied, .refused] && outcomes.allSatisfy { $0.decidedAt != nil },
           "the record keeps each answer and when it was given")

    // The review's Undo takes the approved changes back too.
    expect(KnowledgeReview.undo(meeting) == nil && global.read("mine-apply")?.document.body == "line 1\nline 2"
           && global.read("mine-apply")?.record.userLocked == true && memory.snapshot.items.first { $0.id == keep.id }?.text == keep.text,
           "undoing the review restores the approved skill and fact")

    // An older review refused the same candidate (it stayed pending): the later review's waiting change is the one decided.
    _ = global.save(name: "mine-later", description: "Steps for mine-later", body: "first", by: .user)
    _ = global.save(name: "mine-retry", description: "Steps for mine-retry", body: "first", by: .user)
    guard case .saved(let retryFact) = memory.remember("사용자는 저녁에 걷는다", room: nil, turn: nil, roomTitle: nil, by: "Claude")
    else { expect(false, "retry fact saved"); return }
    let later = propose(.skill, ["name": "mine-later"]), retrySkill = propose(.skill, ["name": "mine-retry"])
    let retryRow = propose(.memory, ["text": "사용자는 저녁에 오래 걷는다", "replaces_id": retryFact.shortID])
    func review(_ json: String, _ rows: [KnowledgeCandidate]) -> UUID? {
        let id = UUID()
        guard let decisions = KnowledgeReview.decisions(from: json),
              case .applied = KnowledgeReview.apply(decisions, meeting: id, attendees: ["a", "b"],
                                                    candidates: rows.map { KnowledgeReview.Candidate(row: $0, project: nil, inProject: false) })
        else { return nil }
        return id
    }
    let first = review("[{\"candidate\":\"\(cid(later))\",\"action\":\"add\",\"name\":\"mine-later\",\"body\":\"again\"}]", [later])
    let second = review("""
    [{"candidate":"\(cid(later))","action":"modify","target":"\(sid("mine-later"))","body":"later body"},
     {"candidate":"\(cid(retrySkill))","action":"modify","target":"\(sid("mine-retry"))","body":"retried body"},
     {"candidate":"\(cid(retryRow))","action":"modify","target":"m:\(retryFact.shortID)","text":"사용자는 저녁에 오래 걷는다"}]
    """, [later, retrySkill, retryRow])
    expect(first != nil && second != nil && KnowledgeReview.records().first { $0.id == first }?.outcomes.first?.result == .refused
           && KnowledgeInbox.shared.items.filter { $0.review == second }.count == 3, "the later review waits after an earlier refusal")
    expect(KnowledgeApproval.decide(later.id, apply: true) == .applied && global.read("mine-later")?.document.body == "later body",
           "Apply finds the later review's waiting change, not the earlier refused one")

    // Apply saved the change but not its record: the next Apply finishes it instead of calling it changed since.
    let retryItem = KnowledgeInbox.shared.items.first { $0.id == retrySkill.id }!
    if case .saved = global.save(name: "mine-retry", description: "Steps for mine-retry", body: "retried body", by: .meeting,
                                 id: retryItem.outcome.skillID, actor: "x", isNew: false, batch: second, approved: retryItem.outcome.proposal?.hash) {} else {
        expect(false, "the half-done Apply saved the skill")
    }
    _ = memory.change(retryFact.id.uuidString, to: "사용자는 저녁에 오래 걷는다", room: nil, turn: nil, by: "x", meeting: second,
                      expected: retryFact.text)
    expect(KnowledgeApproval.decide(retrySkill.id, apply: true) == .applied && KnowledgeApproval.decide(retryRow.id, apply: true) == .applied
           && global.read("mine-retry")?.document.body == "retried body", "a retried Apply closes the item as applied")
    expect(KnowledgeReview.undo(second!) == nil && global.read("mine-retry")?.document.body == "first"
           && memory.snapshot.items.first { $0.id == retryFact.id }?.text == retryFact.text, "and the review's Undo still takes it back")

    // The fact's old text is compared inside the same write.
    if case .refused(let why) = memory.change(retryFact.id.uuidString, to: "다른 문장", room: nil, turn: nil, by: "x", expected: "옛 문장") {
        expect(why == MemoryStore.changedSince && memory.snapshot.items.first { $0.id == retryFact.id }?.text == retryFact.text,
               "a fact that no longer says what was expected is not changed")
    } else { expect(false, "a fact that no longer says what was expected is not changed") }

    // A waiting decision saved before approvals kept a diff goes back to the next review.
    _ = global.save(name: "mine-legacy", description: "Steps for mine-legacy", body: "first", by: .user)
    let legacy = propose(.skill, ["name": "mine-legacy"])
    let old = review("[{\"candidate\":\"\(cid(legacy))\",\"action\":\"modify\",\"target\":\"\(sid("mine-legacy"))\",\"body\":\"x\"}]", [legacy])
    var stripped = KnowledgeReview.records()
    if let i = stripped.firstIndex(where: { $0.id == old }) { stripped[i].outcomes[0].proposal = nil }
    _ = KnowledgeReview.write(stripped)
    let pendingBefore = (try? inbox.pendingRows().contains { $0.candidate.id == legacy.id }) ?? true
    expect(KnowledgeApproval.releaseLegacy() && !pendingBefore && (try? inbox.pendingRows().contains { $0.candidate.id == legacy.id }) == true
           && KnowledgeReview.records().first { $0.id == old }?.outcomes.first.map { $0.result == .refused && $0.decidedAt != nil } == true,
           "a legacy waiting decision closes and its candidate is pending again")

    // An untracked 🔒 SKILL.md renamed by a meeting waits, and the approved rename moves it and keeps it locked.
    let outside = SkillStore.folder.appendingPathComponent("outside-skill", isDirectory: true)
    try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try? SkillDocument.render(name: "outside-skill", description: "Made outside", body: "hand written")
        .write(to: outside.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    let synthetic = global.list().first { $0.name == "outside-skill" }!.record
    if case .needsApproval = global.save(name: "outside-renamed", description: "Made outside", body: "AI", by: .meeting, id: synthetic.id) {} else {
        expect(false, "renaming an untracked locked skill waits for approval")
    }
    expect(global.read("outside-renamed") == nil && global.read("outside-skill")?.document.body == "hand written",
           "nothing is created or changed while it waits")
    if case .saved(let renamed) = global.save(name: "outside-renamed", description: "Made outside", body: "AI", by: .meeting,
                                              id: synthetic.id, approved: synthetic.contentHash) {
        expect(renamed.id == synthetic.id && renamed.userLocked && global.read("outside-skill") == nil
               && global.read("outside-renamed")?.document.body == "AI", "the approved rename moves the untracked skill and keeps it locked")
    } else { expect(false, "the approved rename moves the untracked skill and keeps it locked") }
}

// Automatic idle review scheduling (회의 2/3): busy guards, iCloud host hook, >= 2 companies vs 1 company waiting for
// usage reset (with resetsAt log), minInterval cooldown, 24h partial review (same-company accounts + Ollama, 1-AI and
// Ollama-only partial reviews, 0-AI wait), backward-compatible decoding, and TodoScheduler.onTick hook.
private func testKnowledgeReviewIdleScheduling() {
    let home = URL(fileURLWithPath: AccountStore.home, isDirectory: true)
    expect(ProcessInfo.processInfo.environment["AI_ILLUMINATI_TEST_HOME"] == home.path, "idle review uses isolated test home")
    let fm = FileManager.default, memory = MemoryStore.shared, previousMemory = memory.snapshot
    let previousTodos = TodoStore.shared, previousHost = KnowledgeReviewLink.isReviewHost
    let todoFile = home.appendingPathComponent("idle-review-todos-\(UUID().uuidString.prefix(8)).json")
    let aside = home.appendingPathComponent("idle-review-aside-\(UUID().uuidString.prefix(8))")
    let moved = [SkillStore.folder, KnowledgeCandidates.file(nil), KnowledgeReview.file,
                 KnowledgeReview.attemptFile, KnowledgeReview.logFile]
    try? fm.createDirectory(at: aside, withIntermediateDirectories: true)
    for (i, url) in moved.enumerated() where fm.fileExists(atPath: url.path) {
        try! fm.moveItem(at: url, to: aside.appendingPathComponent("\(i)"))
    }
    TodoStore.shared = TodoStore(url: todoFile)
    memory.update { $0 = MemoryData() }
    defer {
        KnowledgeReviewLink.isReviewHost = previousHost
        TodoStore.shared = previousTodos
        memory.update { $0 = previousMemory }
        try? fm.removeItem(at: todoFile)
        for (i, url) in moved.enumerated() {
            try? fm.removeItem(at: url)
            if fm.fileExists(atPath: aside.appendingPathComponent("\(i)").path) {
                try? fm.moveItem(at: aside.appendingPathComponent("\(i)"), to: url)
            }
        }
        try? fm.removeItem(at: aside)
    }

    // Legacy knowledge-reviews.json without `partial` decodes cleanly as partial == false.
    let legacyJSON = #"[{"id":"00000000-0000-0000-0000-000000000001","at":"2026-11-01T00:00:00Z","attendees":["Claude","ChatGPT"],"candidates":[],"outcomes":[],"projects":[]}]"#
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    let legacyDecoded = try? dec.decode([KnowledgeReviewRecord].self, from: Data(legacyJSON.utf8))
    expect(legacyDecoded?.count == 1 && legacyDecoded?.first?.partial == false,
           "older review records without partial decode with partial == false")

    expect(KnowledgeReview.minInterval == 3_600 && KnowledgeReview.partialAfter == 86_400,
           "timing policy lives in single named constants")

    let plain = Conversation(turns: [ChatTurn(question: "q")])
    let inbox = KnowledgeCandidates.shared
    func submitSkill(_ name: String, at date: Date) -> KnowledgeCandidate {
        var row = KnowledgeCandidate(kind: .skill,
                                     content: ["name": name, "description": "Use for \(name)", "body": "Do \(name).", "scope": "global"],
                                     evidence: "verified", accountID: "a", accountName: "Claude",
                                     chatID: plain.id, turnID: UUID(), todoID: nil)
        row.createdAt = date
        expect(inbox.submit(row, project: nil) == nil, "idle candidate submitted")
        return row
    }

    let claudeSchool = Account(id: "idle-claude-school", provider: .claude, name: "Claude (학교)", school: true)
    let claudePersonal = Account(id: "idle-claude-personal", provider: .claude, name: "Claude (개인)", school: false)
    let codex = Account(id: "idle-codex", provider: .codex, name: "ChatGPT")
    let ollama = Account(id: "idle-ollama", provider: .ollama, name: "Gemma")

    func usage(_ account: Account, fiveHourUsed: Double, resetsAt: Date? = nil, weeklyUsed: Double = 10) -> AIUsage {
        var u = AIUsage(name: account.name, account: account)
        u.fiveHour = UsageWindow(usedPercent: fiveHourUsed, resetsAt: resetsAt)
        u.weekly = UsageWindow(usedPercent: weeklyUsed, resetsAt: nil)
        return u
    }

    let model = AppModel(persist: false)
    model.localEnabled = true
    model.accounts = [claudeSchool, claudePersonal, codex, ollama]
    let discussion = Discussion(model: model)
    discussion.conversations = [plain]

    let promptLock = NSLock()
    var speakers = Set<String>()
    var nextDecisionJSON = "[]"
    discussion.workspaceAnswer = { account, prompt, _, _, _ in
        if prompt.contains("[MEETING RESULT]") { return .success(nextDecisionJSON) }
        if prompt.contains("[MODE3 MODERATION]") { return .success(#"{"action":"finish","reason":"enough"}"#) }
        if prompt.contains("[MODE3 SPEECH]") { promptLock.lock(); speakers.insert(account.id); promptLock.unlock() }
        return .success("Looks good.")
    }
    func waitForMeeting() {
        let deadline = Date().addingTimeInterval(20)
        while (discussion.anyRunning || KnowledgeReviewLink.running) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        expect(!discussion.anyRunning && !KnowledgeReviewLink.running, "idle background review finished")
    }
    func addDecision(_ row: KnowledgeCandidate) -> String {
        #"[{"candidate":"c:\#(String(row.id.uuidString.prefix(8)).lowercased())","action":"add","scope":"global","reason":"유용함"}]"#
    }

    // 0) Empty inbox: never runs.
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    expect(!KnowledgeReviewLink.runIfIdle(in: discussion, now: t0), "no pending candidates does not start a review")

    // 1) Busy guards & iCloud host hook.
    let c1 = submitSkill("idle-first", at: t0)
    nextDecisionJSON = addDecision(c1)
    model.latestUsage = [
        claudeSchool.id: usage(claudeSchool, fiveHourUsed: 20),
        claudePersonal.id: usage(claudePersonal, fiveHourUsed: 20),
        codex.id: usage(codex, fiveHourUsed: 20),
    ]
    discussion.runningRooms.insert(plain.id)
    expect(!KnowledgeReviewLink.runIfIdle(in: discussion, now: t0.addingTimeInterval(60)), "an answering chat blocks automatic review")
    discussion.runningRooms.remove(plain.id)

    discussion.importingMaterials = true
    expect(!KnowledgeReviewLink.runIfIdle(in: discussion, now: t0.addingTimeInterval(60)), "importing materials blocks automatic review")
    discussion.importingMaterials = false

    discussion.stoppingRooms.insert(plain.id)
    expect(!KnowledgeReviewLink.runIfIdle(in: discussion, now: t0.addingTimeInterval(60)), "stopping rooms blocks automatic review")
    discussion.stoppingRooms.remove(plain.id)

    let list = TodoList(title: "Busy", project: nil)
    var runningTodo = TodoItem(listID: list.id, title: "Running task")
    runningTodo.state = .running
    try! TodoStore.shared.update { $0.lists = [list]; $0.items = [runningTodo] }
    expect(!KnowledgeReviewLink.runIfIdle(in: discussion, now: t0.addingTimeInterval(60)), "a running TODO blocks automatic review")
    try! TodoStore.shared.change(runningTodo.id) { $0.state = .done }

    KnowledgeReviewLink.isReviewHost = { false }
    expect(!KnowledgeReviewLink.runIfIdle(in: discussion, now: t0.addingTimeInterval(60)), "non-host Mac skips automatic review")
    KnowledgeReviewLink.isReviewHost = { true }

    // 2) Only 1 company available (even with 2 accounts of that company) and < 24h: waits and logs resetsAt.
    let resetAt = t0.addingTimeInterval(2 * 3_600)
    model.latestUsage = [
        claudeSchool.id: usage(claudeSchool, fiveHourUsed: 20),
        claudePersonal.id: usage(claudePersonal, fiveHourUsed: 30),
        codex.id: usage(codex, fiveHourUsed: 100, resetsAt: resetAt),
    ]
    let computedReset = KnowledgeReviewLink.nextReset(accounts: model.accounts, usage: model.latestUsage,
                                                      picks: model.autoTeamPicks, excluding: [.claude], now: t0.addingTimeInterval(3_600))
    expect(computedReset == resetAt, "nextReset returns the earliest blocking window reset of another company")
    expect(!KnowledgeReviewLink.runIfIdle(in: discussion, now: t0.addingTimeInterval(3_600)),
           "single company (even 2 Claude accounts) waits while oldest candidate is under 24h")
    let logText = (try? String(contentsOf: KnowledgeReview.logFile, encoding: .utf8)) ?? ""
    expect(logText.contains(ISO8601DateFormatter().string(from: resetAt)), "wait log records next usage resetsAt")

    // 2b) Under 10% left counts as out for reviews (like chats): ChatGPT with 5% left still shows up in `meetingTeam`
    // (meetings the user opens are unchanged) but not in `reviewTeam`, so only Claude is left and the review waits.
    let lowReset = t0.addingTimeInterval(2 * 3_600 + 600)
    model.latestUsage[codex.id] = usage(codex, fiveHourUsed: 95, resetsAt: lowReset)
    let tLow = t0.addingTimeInterval(5_400)
    let userTeam = Discussion.meetingTeam(model.accounts, usage: model.latestUsage, most: KnowledgeReviewLink.most,
                                          picks: model.autoTeamPicks, now: tLow) { Discussion.meets($0) }
    let lowTeam = KnowledgeReviewLink.reviewTeam(in: discussion, now: tLow)
    expect(userTeam.contains(where: { $0.id == codex.id }), "meetingTeam still takes an account with 5% left")
    expect(!lowTeam.contains(where: { $0.id == codex.id }) && Set(lowTeam.map(\.provider)) == [.claude],
           "reviewTeam leaves out an account under 10%, leaving one company")
    expect(KnowledgeReviewLink.nextReset(accounts: model.accounts, usage: model.latestUsage, picks: model.autoTeamPicks,
                                         excluding: [.claude], now: tLow) == lowReset,
           "nextReset counts a window under 10% as blocking")
    expect(!KnowledgeReviewLink.runIfIdle(in: discussion, now: tLow),
           "an account under 10% does not make a second company: automatic review waits")
    let lowLog = (try? String(contentsOf: KnowledgeReview.logFile, encoding: .utf8)) ?? ""
    expect(lowLog.contains(ISO8601DateFormatter().string(from: lowReset)), "wait log records when the low account is back above 10%")
    // Weekly under 10% too; the manual review then has only one AI and does not start. `run` reads the real clock, so
    // ChatGPT gets no reset time here (one in the past would count as reset and let it back in).
    model.latestUsage[claudePersonal.id] = usage(claudePersonal, fiveHourUsed: 30, weeklyUsed: 92)
    model.latestUsage[codex.id] = usage(codex, fiveHourUsed: 95)
    expect(KnowledgeReviewLink.reviewTeam(in: discussion, now: tLow).map(\.id) == [claudeSchool.id],
           "weekly under 10% leaves an account out too")
    expect(!KnowledgeReviewLink.run(in: discussion) && !KnowledgeReviewLink.running,
           "manual review uses the same 10% rule and needs two AIs")
    model.latestUsage[claudePersonal.id] = usage(claudePersonal, fiveHourUsed: 30)
    model.latestUsage[codex.id] = usage(codex, fiveHourUsed: 100, resetsAt: resetAt)

    // 3) After codex resets (2 companies available): runs full review (partial == false).
    speakers.removeAll()
    let tReset = t0.addingTimeInterval(3 * 3_600)
    var doneLine: String?
    expect(KnowledgeReviewLink.runIfIdle(in: discussion, now: tReset, done: { doneLine = $0 }),
           "two companies after usage reset start a full review")
    waitForMeeting()
    let rec1 = KnowledgeReview.records().last
    expect(rec1?.partial == false && rec1?.at == tReset && SkillStore.shared.read("idle-first") != nil
           && speakers.contains(codex.id) && (speakers.contains(claudeSchool.id) || speakers.contains(claudePersonal.id))
           && !speakers.contains(ollama.id),
           "full review marks partial=false, applies skill, uses cloud companies (no Ollama)")

    // 4) Minimum interval: too soon after last review skips; after minInterval proceeds.
    let tSoon = tReset.addingTimeInterval(1_800)
    let c2 = submitSkill("idle-second", at: tSoon)
    nextDecisionJSON = addDecision(c2)
    expect(!KnowledgeReviewLink.runIfIdle(in: discussion, now: tSoon),
           "within minInterval (30 min) automatic review waits")
    let tAfterInterval = tReset.addingTimeInterval(KnowledgeReview.minInterval + 60)
    expect(KnowledgeReviewLink.runIfIdle(in: discussion, now: tAfterInterval),
           "after minInterval automatic review proceeds")
    waitForMeeting()
    expect(KnowledgeReview.records().last?.partial == false && SkillStore.shared.read("idle-second") != nil,
           "second full review succeeds after minInterval")

    // 5) 24h elapsed with only 1 company (Claude school + personal) + Ollama enabled: partial review runs with all 3.
    // Even with default autoTeamPicks (Ollama off for normal automatic teams), 24h fallback includes enabled Ollama (like Solo.lastResort).
    expect(!Discussion.autoPicked(ollama, picks: model.autoTeamPicks),
           "Ollama defaults to off in autoTeamPicks")
    let t1 = tAfterInterval.addingTimeInterval(2 * 3_600)
    let c3 = submitSkill("idle-partial-team", at: t1)
    nextDecisionJSON = addDecision(c3)
    model.latestUsage = [
        claudeSchool.id: usage(claudeSchool, fiveHourUsed: 20),
        claudePersonal.id: usage(claudePersonal, fiveHourUsed: 30),
        codex.id: usage(codex, fiveHourUsed: 100, resetsAt: t1.addingTimeInterval(48 * 3_600)),
    ]
    model.localEnabled = true
    expect(!KnowledgeReviewLink.runIfIdle(in: discussion, now: t1.addingTimeInterval(KnowledgeReview.partialAfter - 60)),
           "just under 24h still waits with 1 company")
    speakers.removeAll(); doneLine = nil
    let tPartial1 = t1.addingTimeInterval(KnowledgeReview.partialAfter + 60)
    expect(KnowledgeReviewLink.runIfIdle(in: discussion, now: tPartial1, done: { doneLine = $0 }),
           "past 24h starts partial review with same-company accounts + Ollama")
    waitForMeeting()
    let recPartial1 = KnowledgeReview.records().last
    expect(recPartial1?.partial == true && SkillStore.shared.read("idle-partial-team") != nil
           && speakers == [claudeSchool.id, claudePersonal.id, ollama.id]
           && (doneLine?.contains("부분 검토") == true || doneLine?.contains("Partial review") == true),
           "partial review includes same-company accounts and enabled Ollama, and marks record & summary as partial")

    // 6) 24h elapsed with only 1 AI (Ollama off, single Claude account): still runs partial review (minSpeakers=1).
    let t2 = tPartial1.addingTimeInterval(2 * 3_600)
    let c4 = submitSkill("idle-single-ai", at: t2)
    nextDecisionJSON = addDecision(c4)
    model.accounts = [claudePersonal, codex, ollama]
    model.localEnabled = false
    model.latestUsage = [
        claudePersonal.id: usage(claudePersonal, fiveHourUsed: 10),
        codex.id: usage(codex, fiveHourUsed: 100, resetsAt: t2.addingTimeInterval(48 * 3_600)),
    ]
    speakers.removeAll()
    let tPartial2 = t2.addingTimeInterval(KnowledgeReview.partialAfter + 60)
    expect(KnowledgeReviewLink.runIfIdle(in: discussion, now: tPartial2),
           "past 24h with 1 remaining AI runs partial review")
    waitForMeeting()
    let recPartial2 = KnowledgeReview.records().last
    expect(recPartial2?.partial == true && speakers == [claudePersonal.id] && SkillStore.shared.read("idle-single-ai") != nil,
           "single-AI partial review completes synthesis and marks partial=true")

    // 7) 24h elapsed with 0 AIs available: waits; turning Ollama on allows Ollama-only partial review.
    let t3 = tPartial2.addingTimeInterval(2 * 3_600)
    let c5 = submitSkill("idle-zero-then-ollama", at: t3)
    nextDecisionJSON = addDecision(c5)
    model.latestUsage = [
        claudePersonal.id: usage(claudePersonal, fiveHourUsed: 100, resetsAt: t3.addingTimeInterval(48 * 3_600)),
        codex.id: usage(codex, fiveHourUsed: 100, resetsAt: t3.addingTimeInterval(48 * 3_600)),
    ]
    model.localEnabled = false
    let tZero = t3.addingTimeInterval(KnowledgeReview.partialAfter + 60)
    expect(!KnowledgeReviewLink.runIfIdle(in: discussion, now: tZero), "0 AIs available still waits even past 24h")
    model.localEnabled = true
    speakers.removeAll()
    expect(KnowledgeReviewLink.runIfIdle(in: discussion, now: tZero.addingTimeInterval(60)),
           "enabling Ollama allows Ollama-only partial review past 24h")
    waitForMeeting()
    expect(KnowledgeReview.records().last?.partial == true && speakers == [ollama.id]
           && SkillStore.shared.read("idle-zero-then-ollama") != nil,
           "Ollama-only partial review applies and marks partial=true")

    // 8) Undecided candidate does not re-trigger reviews hourly or age the 24h clock for new candidates; alone it comes back daily.
    model.accounts = [claudeSchool, claudePersonal, codex, ollama]
    model.latestUsage = [
        claudeSchool.id: usage(claudeSchool, fiveHourUsed: 10),
        claudePersonal.id: usage(claudePersonal, fiveHourUsed: 10),
        codex.id: usage(codex, fiveHourUsed: 10),
    ]
    let t4 = tZero.addingTimeInterval(3 * 3_600)
    let cUndecided = submitSkill("idle-undecided", at: t4)
    nextDecisionJSON = "[]"   // meeting returns empty decisions: cUndecided remains pending
    expect(KnowledgeReviewLink.runIfIdle(in: discussion, now: t4),
           "new candidate opens a review even when meeting leaves it undecided")
    waitForMeeting()
    expect((try? inbox.pendingRows())?.contains(where: { $0.candidate.id == cUndecided.id }) == true,
           "undecided candidate stays pending")
    expect(!KnowledgeReviewLink.runIfIdle(in: discussion, now: t4.addingTimeInterval(KnowledgeReview.minInterval + 60)),
           "undecided candidate alone does not reopen automatic review after minInterval")
    expect(!KnowledgeReviewLink.runIfIdle(in: discussion, now: t4.addingTimeInterval(KnowledgeReview.partialAfter - 60)),
           "undecided candidate alone does not reopen automatic review before 24h")
    expect(KnowledgeReviewLink.runIfIdle(in: discussion, now: t4.addingTimeInterval(KnowledgeReview.partialAfter + 60)),
           "undecided candidate alone reopens automatic review once 24h passed, so it never waits forever")
    waitForMeeting()   // still "[]": cUndecided stays pending for the next case

    // With 1 company and a fresh candidate arriving after >24h, the 24h clock uses the fresh candidate, not cUndecided.
    let tFresh = t4.addingTimeInterval(KnowledgeReview.partialAfter + 2 * 3_600)
    let cFresh = submitSkill("idle-fresh-after-undecided", at: tFresh)
    model.latestUsage = [
        claudeSchool.id: usage(claudeSchool, fiveHourUsed: 10),
        claudePersonal.id: usage(claudePersonal, fiveHourUsed: 10),
        codex.id: usage(codex, fiveHourUsed: 100, resetsAt: tFresh.addingTimeInterval(6 * 3_600)),
    ]
    expect(!KnowledgeReviewLink.runIfIdle(in: discussion, now: tFresh.addingTimeInterval(3_600)),
           "old undecided candidate does not force immediate partial review for a fresh candidate under 24h")
    // When usage resets, the new review includes both the fresh and previously-undecided candidates.
    model.latestUsage[codex.id] = usage(codex, fiveHourUsed: 10)
    nextDecisionJSON = """
    [{"candidate":"c:\(String(cFresh.id.uuidString.prefix(8)).lowercased())","action":"add","scope":"global","reason":"신규"},
     {"candidate":"c:\(String(cUndecided.id.uuidString.prefix(8)).lowercased())","action":"drop","reason":"재검토 버림"}]
    """
    expect(KnowledgeReviewLink.runIfIdle(in: discussion, now: tFresh.addingTimeInterval(2 * 3_600)),
           "fresh candidate triggers review once 2 companies are available")
    waitForMeeting()
    expect(SkillStore.shared.read("idle-fresh-after-undecided") != nil
           && (try? inbox.pendingRows())?.contains(where: { $0.candidate.id == cUndecided.id }) == false,
           "previously undecided candidate is reconsidered alongside the new candidate")

    // 9) Repeated broken-JSON failures back off exponentially (1h -> 2h) and reset on success.
    let tFail = tFresh.addingTimeInterval(5 * 3_600)
    let cFail = submitSkill("idle-backoff", at: tFail)
    nextDecisionJSON = "not valid json"
    expect(KnowledgeReviewLink.runIfIdle(in: discussion, now: tFail), "first broken-JSON attempt starts")
    waitForMeeting()
    expect(!KnowledgeReviewLink.runIfIdle(in: discussion, now: tFail.addingTimeInterval(1_800)),
           "first failure respects 1h cooldown")
    let tFail2 = tFail.addingTimeInterval(KnowledgeReview.minInterval + 60)
    expect(KnowledgeReviewLink.runIfIdle(in: discussion, now: tFail2), "second attempt runs after 1h")
    waitForMeeting()
    expect(!KnowledgeReviewLink.runIfIdle(in: discussion, now: tFail2.addingTimeInterval(KnowledgeReview.minInterval + 60)),
           "second consecutive failure backs off to 2h cooldown")
    let tFail3 = tFail2.addingTimeInterval(2 * KnowledgeReview.minInterval + 60)
    nextDecisionJSON = addDecision(cFail)
    expect(KnowledgeReviewLink.runIfIdle(in: discussion, now: tFail3), "third attempt runs after 2h backoff")
    waitForMeeting()
    expect(SkillStore.shared.read("idle-backoff") != nil && KnowledgeReview.lastAttempt()?.failures == 0,
           "successful review applies and resets failure backoff")

    // 10) Manual run keeps minSpeakers=2 (even for same-company accounts) and records completion time (not start time).
    let cManual = submitSkill("idle-manual-guard", at: tFail3.addingTimeInterval(60))
    model.accounts = [claudeSchool, claudePersonal]
    model.latestUsage = [
        claudeSchool.id: usage(claudeSchool, fiveHourUsed: 10),
        claudePersonal.id: usage(claudePersonal, fiveHourUsed: 10),
    ]
    nextDecisionJSON = addDecision(cManual)
    var failSecond = true
    var answerDelay: TimeInterval = 0
    discussion.workspaceAnswer = { account, prompt, _, _, _ in
        if answerDelay > 0 { Thread.sleep(forTimeInterval: answerDelay) }
        if failSecond && account.id == claudePersonal.id { return .failure(.failed("simulated failure")) }
        if prompt.contains("[MEETING RESULT]") { return .success(nextDecisionJSON) }
        if prompt.contains("[MODE3 MODERATION]") { return .success(#"{"action":"finish","reason":"enough"}"#) }
        if prompt.contains("[MODE3 SPEECH]") { promptLock.lock(); speakers.insert(account.id); promptLock.unlock() }
        return .success("Looks good.")
    }
    let countBeforeManual = KnowledgeReview.records().count
    expect(KnowledgeReviewLink.run(in: discussion), "manual review starts with 2 same-company accounts")
    waitForMeeting()
    expect(KnowledgeReview.records().count == countBeforeManual && SkillStore.shared.read("idle-manual-guard") == nil,
           "manual review with only 1 successful speaker does not synthesize or apply (minSpeakers=2)")

    failSecond = false
    answerDelay = 1.05   // records keep whole seconds (ISO 8601), so the meeting must outlast one to tell end from start
    let beforeManualRun = Date()
    expect(KnowledgeReviewLink.run(in: discussion), "manual review succeeds when both speakers answer")
    waitForMeeting()
    let manualRec = KnowledgeReview.records().last
    expect(SkillStore.shared.read("idle-manual-guard") != nil,
           "manual review with both speakers applies: \(KnowledgeReview.records().count - countBeforeManual) new record(s)")
    expect(manualRec?.partial == true, "same-company manual review is marked partial: \(String(describing: manualRec?.partial))")
    expect((manualRec?.at.timeIntervalSince(beforeManualRun) ?? 0) >= 0.05,
           "manual review records completion timestamp (after meeting work), not start timestamp: \(manualRec?.at.timeIntervalSince(beforeManualRun) ?? -1) s")

    // 11) TodoScheduler.onTick fires only on periodic scheduled timer wake, not on tick()/startNow().
    let scheduler = TodoScheduler(discussion: discussion, store: TodoStore.shared)
    var ticked = 0
    scheduler.onTick = { ticked += 1 }
    scheduler.tick()
    scheduler.startNow()
    expect(ticked == 0, "TodoScheduler.tick and startNow do not fire onTick")
    scheduler.scheduledTick()
    expect(ticked == 1, "TodoScheduler.scheduledTick invokes onTick hook")
}
