# Security and privacy

This app handles local authentication information, AI accounts, and files linked by the user. Publishing its source does not by itself grant access to another user's Keychain, account folders, or conversations. Source review is not a guarantee that the app has no security vulnerabilities.

## Reporting an issue

Do not post passwords, OAuth tokens, auth.json, cookies, Keychain dumps, signing private keys, or real user conversations or documents in public issues, attachments, or pull requests. Use GitHub's private vulnerability reporting if it is enabled. Otherwise, ask the maintainer for a private contact method without disclosing sensitive details publicly.

Use fictional accounts and files in reproductions. Redact personal emails and home directory paths. If a real credential is exposed, removing a Git file is not sufficient: revoke the credential with its provider.

## Local storage

- `~/Library/Application Support/AI Illuminati`: account lists, conversations, image copies, deliverables, backups, update state, and update source.
- `~/.ai-illuminati`: app-specific CLI accounts and sessions.
- macOS Keychain: some CLI credentials and the local code-signing identity.
- External CLIs may also store records in their own locations.

Never include these folders or Keychain contents in a distribution package. The project's .gitignore is a precaution; it cannot remove already published Git history or protect files explicitly force-added to Git.

Internal development notes and the previous public history have been removed from public branch history. Previously downloaded copies, forks, and GitHub caches are separate: rewriting history does not guarantee the removal of external copies.
