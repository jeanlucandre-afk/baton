# Pre-release test pass

Run through this before `Scripts/release.sh`. Automated parts first, then by hand on real Macs.
Mark each line ✅ / ❌ in the release notes draft if something is off.

## Automated
- [ ] `swift test` passes.
- [ ] `Scripts/package.sh` builds, and `codesign --verify --deep --strict dist/…/Baton.app` is clean.
- [ ] CI is green on `main`.

## Fresh install (the path a stranger takes)
Best on a second Mac or a new macOS user account (System Settings › Users & Groups), which has no
Keychain keys, no Accessibility grant and no `~/Library/Application Support/Baton`.
- [ ] Download `Baton.dmg` from the release page in Safari (so it gets the quarantine flag), drag to
      Applications, open: the Gatekeeper block appears, and **Open Anyway** gets past it as INSTALL.md says.
- [ ] The welcome window opens by itself. Every step reads right; Back / Continue / Skip work.
- [ ] Accessibility: the button adds Baton to the list; the step turns green within a second of switching it on.
- [ ] Notifications: Allow, then Deny on a second account; both states read right.
- [ ] Keys: "Get a key" links open the right pages; Test says OK for a good key and a clear error for a bad one;
      Skip works and Settings › Keys can add them later.
- [ ] Test ping on the last step shows a ping in the notch.
- [ ] Open at login: on, log out and back in, Baton is running.
- [ ] Quit and reopen: no welcome window the second time.

## Daily use
- [ ] ChatGPT, Codex, Claude and Cursor each: start a chat, it shows as working; it finishes, the notch pings
      within a few seconds; a question back shows "needs you".
- [ ] No keys at all: chats are listed, nothing crashes, nothing claims "finished".
- [ ] Only Jev, no Gemini: pings still have a sensible line (on-device model or plain text).
- [ ] ⌥Tab jumps to the next ready chat; ⌥N opens New Task.
- [ ] Hover opens, moving away closes; clicks outside the open card reach the app below.
- [ ] Dark theme: the card grows out of the notch, and with the shelf on, out of the shelf. Transparent theme too.
- [ ] Reduce Motion on (Accessibility › Display): everything fades, nothing springs.
- [ ] Phone pings (if used): QR subscribe, Test, a real ping arrives while away.

## Screens
- [ ] MacBook with a notch, built-in display only.
- [ ] External display without a notch: virtual notch, hover works, pings appear on the right screen.
- [ ] Two displays, unplug one while open: nothing stuck on screen.
- [ ] Menu bar auto-hide on: the thin lip opens on hover.
- [ ] Full-screen app in front: notification still arrives.

## Updates
- [ ] Install the previous release, grant Accessibility, then drag the new one over it: Accessibility still
      works (same certificate). If it doesn't, note it in the release notes.
- [ ] Settings, tasks and keys survive the update.

## Resource use
- [ ] Activity Monitor after 10 minutes with 3–4 AI apps open: CPU near idle when nothing changes,
      memory steady.
- [ ] Mac asleep / screen locked overnight: no runaway CPU, phone pings back off while away.
