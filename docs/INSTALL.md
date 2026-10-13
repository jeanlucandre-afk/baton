# Installing Baton

Baton lives in your Mac's notch and pings you when an AI chat (ChatGPT, Claude, Cursor, Codex, …)
finishes or needs you. Needs macOS 26 or later.

## 1. Install
1. Download **Baton.dmg** from [Releases](https://github.com/jeanlucandre-afk/baton/releases/latest),
   open it and drag **Baton** onto **Applications**.
   (Got the `.zip` instead? Double-click it and move `Baton.app` to Applications.)
2. Open Baton from Applications.

## 2. The first open
This build isn't notarized by Apple yet, so macOS stops the first open with a warning
("Apple could not verify Baton…"). Either:

- Click **Done**, then go to **System Settings › Privacy & Security**, scroll down and click
  **Open Anyway** next to Baton. (On older macOS: right-click Baton › **Open** › **Open**.)
- Or in Terminal:
  ```
  xattr -dr com.apple.quarantine /Applications/Baton.app
  ```

You only do this once.

## 3. Setup
Baton opens a short welcome window:

1. **Accessibility.** Click *Open Accessibility Settings* and turn on Baton. This lets it read the
   chat lists in your AI apps. Everything is read on your Mac.
2. **Notifications.** Optional; pings in the notch work without them.
3. **Keys.** Optional, and you can add them later in **Settings › Keys**:
   - **Jev** ([typesafe.ai](https://typesafe.ai)) tells when a reply is finished or needs you.
     Without it Baton lists your chats but can't tell when one is done.
   - **Gemini** ([aistudio.google.com/apikey](https://aistudio.google.com/apikey)) writes the one-line
     pings, task names and steps. Without it Apple's on-device model writes them, or plain text.

   Keys are kept in your login Keychain. Each has a **Test** button.

Then hover the notch at the top of your screen. Baton has no Dock icon; its menu is in the menu bar,
and Settings live there too.

## Updating
Baton updates itself: it checks once a day, installs new versions in the background, and the new
version starts the next time Baton opens. **Check for Updates…** is in its menu; Settings › General
turns automatic checks and installs on or off. (Version 0.1.0 had no updater: install 0.2.0 or later
by hand once.) If Accessibility stops working after an update, turn Baton off and on again in
System Settings › Privacy & Security › Accessibility.

## Troubleshooting
- **"Apple could not verify Baton" / "Baton is damaged".** The build isn't notarized. Use **Open Anyway**
  (step 2) or the `xattr` command above. "Damaged" usually means the quarantine flag; the `xattr` command
  clears it.
- **The notch never opens, or lists no chats.** Check **System Settings › Privacy & Security ›
  Accessibility**: Baton must be on. After an update, turn it off and on again.
- **Chats show up but never turn "finished".** That's the Jev key: add it in **Settings › Keys** and press
  **Test**.
- **An AI app updated and Baton stopped reading it.** Open **Settings › Tracking › Reading apps** and press
  **Repair** next to that app (works best with a Gemini key). **Reset** goes back to the built-in profile.
- **No notch on this screen.** Baton draws a virtual one at the top centre; hover there. With the menu bar
  hidden it's a thin sliver that opens on hover.
- **Nothing happens on hover.** Baton has no Dock icon. Look for its menu bar icon; if it isn't there,
  open Baton from Applications again.
- **Reporting a bug.** Turn on **Settings › General › Write a debug log**, reproduce it, then
  **Reveal Log in Finder** and attach `poll.log` (it contains chat names; skim it first).
- **Still stuck?** [Open an issue](https://github.com/jeanlucandre-afk/baton/issues) with your macOS
  version, the AI app and what you see.

## Uninstall
Quit Baton from its menu, delete it from Applications, and optionally remove
`~/Library/Application Support/Baton`, its keys (`jev-api-key`, `gemini-api-key`) in Keychain Access, and
Baton in System Settings › Privacy & Security › Accessibility.

## For the person sharing it
`Scripts/release.sh` tags, packages and publishes a GitHub release (it asks first);
`Scripts/package.sh` alone builds `dist/Baton-<version>.dmg` and `.zip`. It signs with the best certificate
on the Mac: today that's an *Apple Development* certificate, which is why friends see the warning above.
A warning-free install needs a **Developer ID Application** certificate (Apple Developer Program,
$99/year) and notarization; the script switches to it on its own once the certificate is in the
Keychain, and the `notarytool` step in it is ready to uncomment.
