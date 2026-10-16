# Codex review: Redpen beta before public download

Redpen is a macOS menu-bar grammar checker (Swift, SwiftPM, macOS 26, Apple silicon). It reads and edits text in other apps through the Accessibility API, underlines mistakes, and shows a fix card. A signed, notarized beta download is about to be shared with strangers. Review the code as it is now in this folder. Do not edit any file; report only.

Read first: README.md, Package.swift, build.sh, release.sh, install.sh, Sources/Redpen/*.swift, Sources/RedpenCore/*.swift.

Look hardest at code that changed most recently (see `git log -8 --stat`):
- Sources/Redpen/GrammarEngine.swift: downloads LanguageTool and a Java runtime over HTTPS, unpacks with tar/ditto, runs java on port 8081. Check the download, unpack, and launch for safety (no checksum today), failure handling, and what happens when port 8081 is already taken by something that is not LanguageTool.
- Sources/Redpen/DeepCheck.swift and Sources/RedpenCore/DeepPrompt.swift: user text goes to `claude -p` on stdin. Confirm no user text ever reaches a shell or the argument list.
- Config.claudeExecutable and Helpers in MenuPanel.swift: finding Claude Code and Codex in several install locations.
- build.sh and release.sh: signing, notarizing, and the order of steps.

Then the whole app, for a stranger installing it fresh:
1. Bugs that crash, hang, lose or corrupt the user's text, or apply a fix to the wrong place.
2. Security and privacy: anything that sends text off the Mac without the user asking, runs untrusted input, or trusts a network response too much.
3. First-run problems: missing permission, missing Claude Code, no Homebrew, no LanguageTool, Apple Intelligence off.
4. Anything in README.md that is wrong about what the code does.

Report format, plain text:
- One line per finding, most severe first: severity (high, medium, low), file:line, what goes wrong, and a concrete case that triggers it.
- Say "verified" if you traced the code path, "suspected" if not.
- End with the three fixes you would make before sharing the download, and say plainly if you found nothing serious.
Skip style nits.
