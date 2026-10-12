import AppKit
import BatonCore

/// Typing into a chat app for you, shared by "Continue in new chat", Reply and Pass. Every route brings the
/// window forward first and checks, right before each keystroke or paste, that this very window takes the
/// keyboard (another app, another window of the same app, or Baton's own panel holding it stops it).
/// Text only ever goes into an empty box.
enum ChatTyper {
    enum Stop: Error { case failed(String) }

    static func checkCancelled() throws { if Task.isCancelled { throw CancellationError() } }

    /// Reads a window off the main thread (a read can take most of a second), then stops if the flow
    /// was cancelled meanwhile.
    static func read<T: Sendable>(_ work: @escaping @Sendable () -> T) async throws -> T {
        let v = await Task.detached(priority: .userInitiated, operation: work).value
        try checkCancelled()
        return v
    }

    /// Polls every half second until `check` returns something, or fails with `message`.
    static func waitFor<T>(_ message: String, seconds: Double, _ check: () async throws -> T?) async throws -> T {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try checkCancelled()
            if let v = try await check() { return v }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw Stop.failed(message)
    }

    /// Whether `w` is the window that takes keystrokes and clicks right now. Not while one of Baton's own
    /// windows holds the keyboard: a non-activating panel can, with another app in front.
    static func isFront(_ w: AXWindow) -> Bool {
        guard NSApp.keyWindow == nil, let f = AX.focusedWindow() else { return false }
        return f.pid == w.pid && CFEqual(f.element, w.element)
    }

    static func bringToFront(_ w: AXWindow, app: String) async throws {
        AX.raise(w)
        _ = try await waitFor("\(app) didn't come to the front.", seconds: 4) { isFront(w) ? true : nil }
    }

    // MARK: Typing and sending (Continue in new chat)

    /// Types into the window's message box and sends it. Only into an empty box, and only while that very
    /// window takes keystrokes (the app in front isn't enough: another of its windows would get the text).
    static func send(_ text: String, in w: AXWindow, app: String) async throws {
        try checkCancelled()
        try await bringToFront(w, app: app)
        let found = try await read { AXNode.capture(w.element, maxNodes: 8000, maxMillis: 600).flatMap { Composer.find(in: $0) } }
        guard let box = found else { throw Stop.failed("Couldn't find \(app)'s message box.") }
        guard box.text.isEmpty else { throw Stop.failed("Your message box in \(app) has text in it. Clear it, then try again.") }
        guard Composer.focus(box.box) else { throw Stop.failed("Couldn't click into \(app)'s message box.") }
        try await Task.sleep(for: .milliseconds(200))
        // Last check before typing: still this window in front (you may have switched apps).
        guard isFront(w) else { throw Stop.failed("\(app) went to the background, so Baton stopped before typing.") }
        Composer.type(text)
        let typed = try await waitFor("The text didn't arrive in \(app)'s message box.", seconds: 3) {
            try await read { () -> Composer.Found? in
                guard let r = AXNode.capture(w.element, maxNodes: 8000, maxMillis: 400), let c = Composer.find(in: r),
                      c.text.contains(text) else { return nil }
                return c
            }
        }
        guard let sendButton = typed.send else { throw Stop.failed("Couldn't find \(app)'s Send button.") }
        Composer.pressSend(sendButton)
        try await waitUntilSent(in: w, app: app, send: sendButton) { Composer.find(in: $0) }
    }

    /// Sent once the box is empty again; if the press was ignored, click Send once more. That's a real
    /// click, so only while the window is still in front.
    private static func waitUntilSent(in w: AXWindow, app: String, send: AXNode?,
                                      find: @escaping @Sendable (AXNode) -> Composer.Found?) async throws {
        func sent() async throws -> Bool? {
            try await read { () -> Bool? in
                guard let r = AXNode.capture(w.element, maxNodes: 8000, maxMillis: 400), let c = find(r) else { return nil }
                return c.text.isEmpty ? true : nil
            }
        }
        do {
            _ = try await waitFor("", seconds: 2.5) { try await sent() }
        } catch Stop.failed {
            guard isFront(w) else { throw Stop.failed("\(app) went to the background before the message was sent.") }
            guard let el = send?.element else { throw Stop.failed("\(app) didn't send it. It's in the box: press Send there.") }
            AX.click(el)
            _ = try await waitFor("\(app) didn't send it. It's in the box: press Send there.", seconds: 3) { try await sent() }
        }
    }

    // MARK: Pasting and sending (Reply, Pass)

    /// Puts the text on the clipboard, so it's never lost whatever happens next.
    static func putOnClipboard(_ text: String) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return pb.changeCount
    }

    /// Pastes `text` (already on the clipboard as `clip`) into the window's message box, after checking the
    /// window shows the chat `expect` names and its box is empty. Pasting keeps line breaks as line breaks
    /// (typed, a line break could send the message). Returns once the box holds the text; doesn't send.
    @discardableResult
    static func paste(_ text: String, clip: Int, in w: AXWindow, app: String, expect: TypingTarget.Expect) async throws -> Composer.Found {
        try checkCancelled()
        try await bringToFront(w, app: app)
        let found = try await verified(w, app: app, expect: expect)
        // Focusing may fall back to a real click: only into this window, in front.
        guard isFront(w) else { throw Stop.failed("\(app) went to the background, so Baton stopped.") }
        guard Composer.focus(found.box) else { throw Stop.failed("Couldn't click into \(app)'s message box.") }
        try await Task.sleep(for: .milliseconds(200))
        // Last checks before pasting: still that chat with an empty box (a click could have changed it),
        // this window in front, its box holding the keyboard, the clipboard still ours.
        let box = try await verified(w, app: app, expect: expect).box
        guard isFront(w), hasFocus(box, pid: w.pid) else { throw Stop.failed("\(app)'s message box lost the keyboard, so Baton stopped.") }
        guard NSPasteboard.general.changeCount == clip else { throw Stop.failed("The clipboard changed, so Baton stopped.") }
        guard pasteFromMenu(pid: w.pid) else { throw Stop.failed("Couldn't paste into \(app).") }
        return try await waitFor("The text didn't arrive in \(app)'s message box.", seconds: 3) {
            try await read { () -> Composer.Found? in
                guard let r = AXNode.capture(w.element, maxNodes: 8000, maxMillis: 400), let c = Composer.chatBox(in: r),
                      Composer.holds(c.text, text) else { return nil }
                return c
            }
        }
    }

    /// The window's message box, after checking it shows the expected chat and the box is empty.
    private static func verified(_ w: AXWindow, app: String, expect: TypingTarget.Expect) async throws -> Composer.Found {
        let bundle = w.bundleID
        let checked = try await read { AXNode.capture(w.element, maxNodes: 8000, maxMillis: 600).map { TypingTarget.check($0, bundleID: bundle, expect: expect) } }
        switch checked {
        case .success(let f)?: return f
        case .failure(.noBox)?: throw Stop.failed("Couldn't find \(app)'s message box.")
        case .failure(.boxNotEmpty)?: throw Stop.failed("The message box in \(app) has text in it.")
        case .failure(.wrongChat)?: throw Stop.failed(expect == .fresh ? "\(app) didn't open a new chat." : "\(app) is showing another chat.")
        case nil: throw Stop.failed("Couldn't read \(app)'s window.")
        }
    }

    /// Sends what `paste` put in the box: its Send button, else Return in the box. Only while the window
    /// still shows the expected chat, its box holds exactly that text, and it's in front.
    static func submit(_ text: String, in w: AXWindow, app: String, expect: TypingTarget.Expect) async throws {
        let bundle = w.bundleID
        let seen = try await read { () -> (box: Composer.Found?, wrong: TypingTarget.Problem?)? in
            guard let r = AXNode.capture(w.element, maxNodes: 8000, maxMillis: 600) else { return nil }
            return (Composer.chatBox(in: r), TypingTarget.wrongChat(r, bundleID: bundle, expect: expect))
        }
        guard let seen, seen.wrong == nil else { throw Stop.failed("\(app) is showing another chat now, so Baton didn't send.") }
        guard let found = seen.box, Composer.holds(found.text, text) else { throw Stop.failed("The text in \(app)'s message box changed, so Baton didn't send it.") }
        guard isFront(w) else { throw Stop.failed("\(app) went to the background before Baton could send.") }
        if let send = found.send {
            Composer.pressSend(send)
        } else {
            guard hasFocus(found.box, pid: w.pid) || (Composer.focus(found.box) && hasFocus(found.box, pid: w.pid)), isFront(w) else {
                throw Stop.failed("\(app)'s message box lost the keyboard, so Baton didn't send.")
            }
            pressReturn()
        }
        try await waitUntilSent(in: w, app: app, send: found.send) { Composer.chatBox(in: $0) }
    }

    /// Whether the app's keyboard focus is the box (or inside it).
    static func hasFocus(_ box: AXNode, pid: pid_t) -> Bool {
        guard let el = box.element else { return false }
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXFocusedAttribute as CFString, &v) == .success, (v as? Bool) == true { return true }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &v) == .success, let f = v else { return false }
        var cur = f as! AXUIElement
        for _ in 0..<6 {
            if CFEqual(cur, el) { return true }
            var p: CFTypeRef?
            guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &p) == .success, let parent = p else { return false }
            cur = parent as! AXUIElement
        }
        return false
    }

    /// The app's own Edit › Paste (the menu item on ⌘V), pressed through Accessibility: it pastes into
    /// the app's focused box whatever the keyboard layout.
    static func pasteFromMenu(pid: pid_t) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        func kids(_ el: AXUIElement) -> [AXUIElement] {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
            return v as? [AXUIElement] ?? []
        }
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &bar) == .success, let bar else { return false }
        for top in kids(bar as! AXUIElement) {
            for menu in kids(top) {
                for item in kids(menu) {
                    var ch: CFTypeRef?, mods: CFTypeRef?, enabled: CFTypeRef?
                    AXUIElementCopyAttributeValue(item, kAXMenuItemCmdCharAttribute as CFString, &ch)
                    AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &mods)
                    AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &enabled)
                    // ⌘V alone (modifiers 0 = just ⌘), not Paste and Match Style.
                    guard (ch as? String)?.uppercased() == "V", (mods as? Int) ?? -1 == 0, (enabled as? Bool) ?? true else { continue }
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    private static func pressReturn() {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] { CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: down)?.post(tap: .cghidEventTap) }
    }

    // MARK: Where you were

    /// The app and window you were in, to go back to once Baton has sent something for you.
    struct Origin {
        let app: NSRunningApplication
        let window: AXUIElement?

        static func current() -> Origin? {
            guard let app = NSWorkspace.shared.frontmostApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
            let w = AX.focusedWindow().flatMap { $0.pid == app.processIdentifier ? $0.element : nil }
            return Origin(app: app, window: w)
        }
    }

    /// Back to where you were, unless that was the app Baton just typed in (its chat has changed anyway).
    static func restore(_ o: Origin?, unless pid: pid_t) {
        guard let o, !o.app.isTerminated, o.app.processIdentifier != pid else { return }
        if let w = o.window {
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(o.app.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        o.app.activate()
    }
}
