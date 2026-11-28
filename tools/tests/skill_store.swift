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
    memory.update { $0 = MemoryData() }
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
    func call(_ token: String, _ name: String, _ args: [String: String]) -> (ok: Bool, text: String) {
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

    let plainToken = token(plain), projectToken = token(linked), enterpriseToken = token(enterprise, school)
    let todoToken = token(todoRoom, run: run), both: Set = ["skill_propose", "memory_propose"]
    expect(names(plainToken) == both && names(projectToken) == both && names(todoToken) == both
           && names(enterpriseToken) == ["skill_propose"] && names(token(enterprise)).isEmpty,
           "plain, project and TODO get both tools; Enterprise gets only skills for its own accounts")
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
    memory.update { $0.autoSave = false }
    expect(names(plainToken) == ["skill_propose"] && !call(plainToken, "memory_propose", fact).ok,
           "the candidate setting can turn off user memory proposals")
    memory.update { $0.autoSave = true }
    expect(call(plainToken, "memory_propose", fact).ok, "memory proposal with evidence succeeds")
    let duplicate = call(plainToken, "skill_propose", skill("global"))
    expect(!duplicate.ok && duplicate.text.contains(L("한 답", "per answer")), "the two tools share one quota per turn")
    expect(call(enterpriseToken, "skill_propose", skill("project")).ok, "Enterprise skill proposals reach the project inbox")
    expect(call(todoToken, "skill_propose", skill("project")).ok, "a project TODO writes its candidate")
    let rows = lines(projectFile), globalRows = lines(globalFile)
    expect(rows.count == 2 && globalRows.count == 1, "submissions preserve earlier JSONL lines in each scope")
    let memoryRow = globalRows[0]
    let todoRow = rows[1], todoTurn = todoRoom.turns[0].id
    expect(rows[0]["accountID"] as? String == school.id && todoRow["todoID"] as? String == todo.id.uuidString
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
    expect(receipt.uuidString == todoRow["id"] as? String && !reopened.drop(receipt, chat: plain.id, turn: todoTurn)
           && reopened.drop(receipt, chat: todoRoom.id, turn: todoTurn)
           && reopened.pending(chat: todoRoom.id, turn: todoTurn) == nil && lines(projectFile)[1]["state"] as? String == "dropped",
           "the saved receipt survives reopening and cancellation persists dropped")
    discussion.conversations[3].turns.append(turn())
    let retried = call(token(todoRoom, run: run), "memory_propose", fact)
    expect(!retried.ok && retried.text.contains(L("TODO 하나", "per TODO")) && lines(globalFile).count == 1,
           "a later TODO turn in another scope cannot replace its dropped candidate")
    expect(!call(todoToken, "skill_propose", skill("project")).ok, "the earlier TODO session is closed")
    try! TodoStore.shared.change(todo.id) { $0.state = .done }
    discussion.conversations[3].turns.append(turn())
    expect(call(token(todoRoom), "memory_propose", fact).ok && lines(globalFile).last?["todoID"] == nil,
           "an ordinary follow-up in a finished TODO's chat has its own quota")
    discussion.conversations[0].turns.append(turn("기억하지 마"))
    expect(names(plainToken).isEmpty && names(token(plain)) == ["skill_propose"],
           "an older session expires and the user's do-not-remember instruction is respected")
}

