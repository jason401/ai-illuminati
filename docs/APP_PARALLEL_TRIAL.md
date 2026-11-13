# App A: final parallel trial contract (2026-11-12)

Base: main at 2ceaf41 plus the A tool-order/dependency-check changes. Trial changes never belong to main.

| Worker | Owned source | Owned test | Small behavior change |
|---|---|---|---|
| Accounts | app/modules/AIAccounts/Accounts.swift | tools/tests/accounts_contract.swift | Gemini's display title becomes "Google Gemini"; saved AccountStore.gemini stays "Gemini" |
| Localization | app/modules/AILocalization/Language.swift | tools/tests/localization_trial.swift (trial only) | resolve accepts uppercase language identifiers, preserving first-supported-language order and English fallback |

The two leaf modules have no dependencies. No public declaration, storage key, permission or guard changes.
Workers start at one barrier, edit isolated copies and compile/run only their own module and contract.
Record overlapping execution intervals, changed paths, then combine and rerun both contracts.
Verify with the full run_mode2.sh and link every app source against the combined modules.
A module-only pass is evidence for that module's cases, not a general replacement for consumer tests.
Store reproducible results under ignored .ai-illuminati/a-trial; compare the original app source hashes after the run.

Tool constraint: the connected git_* tools provide branch/switch/commit but no worktree or merge operation.
Unlike earlier trials by two AIs in worktrees, this experiment uses two concurrent script workers in copies.
Preserve separate accounts/localization/combined trial branch snapshots with native git_* tools.
The initial manual composition alone did not establish Git conflict behavior. Review follow-up used a temporarily
registered `git merge-tree --write-tree` check on the two preserved branch snapshots: exit 0, result tree
`d384cac44f05839dba761f7e35c35b2568bbb0cb`, identical to `28beee3^{tree}`. Git objects were written; the working tree and branch refs
were not updated and no merge commit was made. The temporary command was removed from shared configuration.
Localization-only follow-up consumer validation also passed the full run_mode2.sh. It did not repeat the parallel trial.
Do not delete any trial branch, force push, publish stable, or retain trial behavior on main.
