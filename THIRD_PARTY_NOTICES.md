# Third-party components and rights

This document describes the distribution scope reviewed for public release. Unverified external code is not relicensed under this project's MIT License.

| Component | Usage | Distribution and terms |
|---|---|---|
| Project Swift, Python, and shell source | Maintained in this repository | MIT notice in the root LICENSE |
| Cocoa/AppKit, SwiftUI, Foundation, Security, CryptoKit, PDFKit, ImageIO, and related APIs | Linked Apple system and SDK APIs | Apple frameworks and system fonts are not redistributed or relicensed under MIT |
| Python standard library, git, OpenSSL, and system commands | Uses installed programs and standard libraries | Their executables are not bundled; their respective licenses apply |
| Claude Code, OpenAI Codex, Antigravity CLI | Calls separately installed CLIs | Provider terms govern CLIs, models, services, and accounts independently of this app's MIT License |
| App and menu bar icons | Drawn using paths, colors, and shapes in Icon.swift | No downloaded banknote photographs, external logo image files, or font files are included |
| Documentation screenshots | Project UI rendered offscreen with fictional data | No real account, conversation, or user photograph is included; platform UI rights remain separate |

## Design references

Source comments credit [CodexBar](https://github.com/steipete/CodexBar) as inspiration for usage bars and reset indicators. [CodexBar is MIT-licensed](https://github.com/steipete/CodexBar/blob/main/LICENSE). No separately copied library or vendored source directory was identified among tracked files. A design reference does not replace copyright notices required for copied code. Preserve the original copyright and license if external code is introduced later.

## Review findings and limitations

- No package lockfiles, vendored external libraries, or external photo or font files intended for distribution were identified in the current repository. Swift/Python imports and build/install scripts were reviewed.
- No identifiable **additional bundled dependency** conflicting with MIT distribution was found within that scope. This is not a legal guarantee of every code fragment's provenance, AI-generated work's rights, or trademark use.
- Provider names and trademarks identify supported integrations. They do not imply official affiliation or endorsement.
- User-supplied pictures and documents and AI-generated images require their own rights and provider-term checks. This repository's LICENSE does not guarantee rights to all user content or generated output.

Reference: [MIT terms](https://choosealicense.com/licenses/mit/). If a conflict is identified later, notify the maintainer before deleting, replacing, or relicensing the affected material.
