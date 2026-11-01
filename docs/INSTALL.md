# Installation and macOS security prompts

## Distribution format

The current release is a **source installation package**. It contains public app source, build and test tools, documentation, MIT notices, and an installer launcher. It contains no maintainer app data, CLI credentials, or signing private keys. It is not a prebuilt app or DMG.

Download these assets from the official [Releases page](https://github.com/jason401/ai-illuminati/releases):

- `AI-Illuminati-0.2.0-source.zip`
- `SHA256SUMS`

GitHub's automatically generated `Source code (zip)` does not include Git metadata. **Do not run the existing build_app.sh directly from an extracted source ZIP.** The build requires a Git revision, so the installer clones the official release tag into a fresh checkout.

## Requirements

- macOS 13 or later, Xcode Command Line Tools (Apple Swift compiler, git, and system SDKs), and Python 3.
- GitHub access for installation and updates; provider connectivity for AI features.
- The CLI and an eligible account for each AI you want to use. External tools are not bundled.
- Write access to the installation directory. The default is `/Applications`. If that location is restricted, review the error. To explicitly choose a per-user installation, run the following before installing:

```bash
defaults write local.aiilluminati installInUserApplications -bool true
```

This selects `~/Applications`. The installer does not require unnecessary Full Disk Access or an administrator service.

## Verify the checksum

Place the ZIP and SHA256SUMS in the same folder, then run this command from that folder:

```bash
shasum -a 256 -c SHA256SUMS
```

Confirm that it reports `OK`. If it fails, do not run the download; obtain it again from the official release. A checksum detects corruption. It is not a signature that protects against an attacker replacing both the download and checksum at their source.

## Installation steps

1. Finish active chats, file work, and games, then quit any existing AI Illuminati app.
2. Extract the ZIP, inspect `Install AI Illuminati.command`, and run it. If its executable permission was lost, and you trust the file, run `zsh "Install AI Illuminati.command"` from Terminal instead.
3. The launcher clones the `v0.2.0` tag into a separate cache folder. It does not overwrite developer projects.
4. An existing `AI Illuminati Local Signing` identity is reused. If none exists, setup_signing.sh from the official checkout creates a local code-signing identity. Approve macOS authentication prompts yourself.
5. The app is compiled for this Mac's CPU architecture. The candidate migrates to the normal installation location on first launch. Add AI accounts separately afterward.

The exact source cache path is printed in Terminal. Do not remove the cache or candidate before installation completes. The binary is **built for your Mac**, not a universal Apple Silicon/Intel binary. Not every macOS and CPU combination has been tested on real hardware.

## If macOS blocks execution

A paid Apple Developer account and Developer ID notarization are not used. Local signing does not mean Apple verified the developer or guarantees the app's safety.

1. Verify the official repository, tag, and download checksum.
2. Try opening the file once and read the macOS message.
3. Only if you trust its source, approve the specific item in **System Settings → Privacy & Security → Open Anyway**. Complete any requested authentication yourself.
4. Stop if macOS reports malware, an unexpected damaged file, or a checksum mismatch. Do not force an exception. Managed Macs may prohibit exceptions under organizational policy.

Do not disable Gatekeeper or SIP, enable all apps globally, or remove quarantine attributes in bulk with `xattr`.

Reference: [Apple — Safely open apps on your Mac](https://support.apple.com/en-us/102445).

## Updates

Automatic checking is separate from installation. Click **Update Now** to install an available version. Updates still use git, Python, Command Line Tools, and the existing local signing identity on your Mac. They do not download a maintainer certificate or private key.

Prebuilt-app-only downloads or a Developer ID/Sparkle update system would require additional implementation and validation. The documentation and packaging work does not change app features.

## If an old installation rejects an update

An installation from before the public history cleanup may report divergent update-source history. Finish your work, quit the app, and use the new release's installer launcher. It locks and refreshes only the dedicated update-source checkout from stable, preserving the previous source in local migration-backups. Accounts, conversations, and signing keys remain untouched. If the source has local edits, the launcher stops rather than overwriting them.
