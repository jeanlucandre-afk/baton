import AppKit
@preconcurrency import ApplicationServices

/// AXUIElement is a CF reference that is safe to message from any thread; wrap it so it can cross isolation.
public struct AXWindow: @unchecked Sendable, Hashable {
    public let element: AXUIElement
    public let pid: pid_t
    public let appName: String
    public let bundleID: String
    public let title: String

    public static func == (a: AXWindow, b: AXWindow) -> Bool { CFEqual(a.element, b.element) }
    public func hash(into h: inout Hasher) { h.combine(pid); h.combine(CFHash(element)) }

    public var icon: NSImage? { NSRunningApplication(processIdentifier: pid)?.icon }
}

public struct Snapshot: Sendable {
    public let title: String
    public let buttons: [String]
    public let tail: String
    public let nodes: Int
    public let millis: Double
}

public enum AX {
    public static func isTrusted(prompt: Bool) -> Bool {
        let key = "AXTrustedCheckOptionPrompt"  // value of kAXTrustedCheckOptionPrompt
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    /// Electron and Chromium apps only build their accessibility tree once an assistive app asks.
    /// That costs them CPU and memory, so only do it for apps Baton actually watches.
    public static func enableTree(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// How long one Accessibility message to a window or its elements may block. The system default
    /// (about 6 s) would let one hung app stall every read; reads are budgeted in the hundreds of ms.
    public static let messagingTimeout: Float = 0.25

    public static func windows(pid: pid_t) -> [AXWindow] {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return [] }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &v) == .success,
              let wins = v as? [AXUIElement] else { return [] }
        return wins.compactMap { w in
            // The app element's timeout doesn't carry over to its windows.
            AXUIElementSetMessagingTimeout(w, messagingTimeout)
            // skip palettes, system dialogs and floating panels; keep normal windows and in-app dialogs
            let sub = string(w, kAXSubroleAttribute)
            if let sub, ![kAXStandardWindowSubrole as String, kAXDialogSubrole as String, "AXUnknown"].contains(sub) { return nil }
            return AXWindow(element: w, pid: pid, appName: app.localizedName ?? "?",
                            bundleID: app.bundleIdentifier ?? "", title: string(w, kAXTitleAttribute) ?? "")
        }
    }

    public static func listWindows(excludingSelf: Bool = true) -> [AXWindow] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && (!excludingSelf || $0.processIdentifier != me) }
            .flatMap { windows(pid: $0.processIdentifier) }
    }

    /// The window sits in the Dock. Its tree is still readable, so this is only informational.
    public static func isMinimized(_ w: AXWindow) -> Bool {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w.element, kAXMinimizedAttribute as CFString, &v) == .success else { return false }
        return (v as? Bool) ?? false
    }

    /// Finds a window again after its handle went stale, searching only its own app.
    public static func relink(_ old: AXWindow) -> AXWindow? {
        let same = windows(pid: old.pid)
        return same.first(where: { $0.title == old.title }) ?? (same.count == 1 ? same.first : nil)
    }

    /// The window you're working in right now (the front app's focused window).
    public static func focusedWindow() -> (pid: pid_t, element: AXUIElement)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.2)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &v) == .success, let w = v else { return nil }
        let win = w as! AXUIElement
        AXUIElementSetMessagingTimeout(win, messagingTimeout)
        return (app.processIdentifier, win)
    }

    /// Clicks an element with the mouse, then puts the pointer back. For web views that ignore
    /// AXPress. Scrolls it into view first; returns false if it has no on-screen frame.
    @discardableResult
    public static func click(_ el: AXUIElement) -> Bool {
        AXUIElementPerformAction(el, "AXScrollToVisible" as CFString)
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size) == .success else { return false }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        guard s.width > 2, s.height > 2 else { return false }
        // Left third of the row: clear of hover buttons (pin, menu) on the right.
        let target = CGPoint(x: p.x + min(s.width / 3, 60), y: p.y + s.height / 2)
        let back = CGEvent(source: nil)?.location
        let src = CGEventSource(stateID: .hidSystemState)
        // Move there first: web apps react to the pointer arriving, not just to the press.
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: target, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(type == .mouseMoved ? 80_000 : 40_000)
        }
        if let back { CGWarpMouseCursorPosition(back) }
        return true
    }

    public static func raise(_ w: AXWindow) {
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(w.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        // macOS often ignores activate() from a background app like Baton; through Accessibility the
        // app can be made frontmost reliably.
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(w.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: w.pid)?.activate()
    }

    nonisolated(unsafe) private static let wanted = [
        kAXRoleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute, kAXFocusedAttribute
    ] as CFArray

    /// Reads the window bottom-up so the newest content (end of a chat, the input area) comes first,
    /// and stops once it has enough text. Returns nil if the window is gone.
    public static func snapshot(_ win: AXWindow, wantChars: Int = 1400, maxNodes: Int = 5000, maxMillis: Double = 200) -> Snapshot? {
        let start = Date()
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(win.element, kAXRoleAttribute as CFString, &role) == .invalidUIElement { return nil }

        var texts: [String] = []
        var chars = 0
        var buttons: [String] = []
        var seen = Set<String>()
        var stack: [(AXUIElement, Int)] = [(win.element, 0)]
        var nodes = 0

        while let (el, depth) = stack.popLast() {
            nodes += 1
            if nodes > maxNodes || chars >= wantChars { break }
            if Date().timeIntervalSince(start) * 1000 > maxMillis { break }

            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, wanted, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let arr = values as? [Any], arr.count == 6 else { continue }
            let r = arr[0] as? String ?? ""
            let value = arr[1] as? String
            let title = arr[2] as? String
            let desc = arr[3] as? String

            switch r {
            case "AXButton", "AXMenuButton", "AXPopUpButton":
                if let label = [title, desc].compactMap({ $0 }).first(where: { !$0.isEmpty }),
                   label.count <= 60, seen.insert(label).inserted, buttons.count < 40 {
                    buttons.append(label)
                }
            case "AXStaticText", "AXTextArea", "AXTextField", "AXHeading":
                // Skip the box the user is typing in: their own typing must never look like the AI writing.
                let focused = (arr[5] as? Bool) ?? false
                if focused && r != "AXStaticText" && r != "AXHeading" { break }
                if let s = value ?? title {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        let piece = String(t.suffix(1500))
                        texts.append(piece)
                        chars += piece.count
                    }
                }
            default:
                break
            }
            // children pushed in order, so popLast walks the last child first (newest content)
            if depth < 80, let kids = arr[4] as? [AXUIElement] {
                for k in kids { AXUIElementSetMessagingTimeout(k, messagingTimeout); stack.append((k, depth + 1)) }
            }
        }

        // AX splits text into many small runs; join with spaces so Jev reads sentences, not fragments
        let joined = texts.reversed().joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return Snapshot(
            title: string(win.element, kAXTitleAttribute) ?? win.title,
            buttons: buttons,
            tail: String(joined.suffix(wantChars)),
            nodes: nodes,
            millis: Date().timeIntervalSince(start) * 1000
        )
    }
}
