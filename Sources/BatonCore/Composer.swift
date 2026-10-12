import AppKit
@preconcurrency import ApplicationServices

/// Typing into a chat app for you: its message box, its Send button, how full the chat's context is,
/// and the button that starts a new chat in the same project. Used by "Continue in new chat".
public enum Composer {
    /// A chat window's message box and Send button, from a captured tree.
    public struct Found: @unchecked Sendable {
        public let box: AXNode
        public let send: AXNode?
        /// What's typed in the box now ("" when empty). ChatGPT reports its placeholder ("Work with
        /// ChatGPT") as the empty box's value; that's empty too.
        public var text: String {
            let t = (box.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return [box.title, box.desc].contains { $0?.trimmingCharacters(in: .whitespacesAndNewlines) == t } ? "" : t
        }
    }

    /// Claude's box is an AXTextArea named "Prompt"; any other text area in the window comes second.
    public static func find(in root: AXNode) -> Found? {
        var box: AXNode?
        var fallback: AXNode?
        var send: AXNode?
        var stack = [root]
        while let n = stack.popLast() {
            if n.role == "AXTextArea" {
                if n.desc == "Prompt" || n.title == "Prompt" { box = n } else if fallback == nil { fallback = n }
            }
            if n.role == "AXButton", ["send", "send message", "send prompt"].contains(n.label.lowercased()) { send = n }
            stack.append(contentsOf: n.kids.reversed())
        }
        guard let b = box ?? fallback else { return nil }
        return Found(box: b, send: send)
    }

    /// How full the open chat's context is, in percent: Claude's "Usage: Context 552.7k / 1M (55%), …" button.
    public static func contextPercent(in root: AXNode) -> Int? {
        var stack = [root]
        while let n = stack.popLast() {
            if let d = n.desc ?? n.title, d.contains("Context"), let p = contextPercent(d) { return p }
            stack.append(contentsOf: n.kids)
        }
        return nil
    }

    public static func contextPercent(_ label: String) -> Int? {
        guard let r = label.range(of: #"Context[^()]*\((\d{1,3})%\)"#, options: .regularExpression) else { return nil }
        let digits = label[r].split(separator: "(").last?.prefix { $0.isNumber } ?? ""
        return Int(digits)
    }

    /// The "New session in <folder>" button of the folder a chat sits in, so the new chat opens in the same
    /// project (and finds the same handoff files). Falls back to the only such button, if there's one.
    public static func newChatButton(near chat: String, in root: AXNode) -> AXNode? {
        let target = chat.lowercased()
        func isNewChat(_ n: AXNode) -> Bool {
            n.role == "AXButton" && n.label.lowercased().hasPrefix("new session in ")
        }
        func firstNewChat(_ n: AXNode) -> AXNode? {
            if isNewChat(n) { return n }
            for k in n.kids { if let f = firstNewChat(k) { return f } }
            return nil
        }
        // Path from the root to the chat's row.
        var path: [AXNode] = []
        func walk(_ n: AXNode, _ trail: [AXNode]) -> Bool {
            let l = n.label.lowercased()
            if (n.role == "AXButton" || n.role == "AXLink" || n.role == "AXRow"), l == target || l.hasSuffix(" " + target) {
                path = trail + [n]; return true
            }
            for k in n.kids where walk(k, trail + [n]) { return true }
            return false
        }
        if walk(root, []) {
            // The nearest ancestor with a "New session in" button holds the chat's folder.
            for a in path.dropLast().reversed() { if let b = firstNewChat(a) { return b } }
        }
        var all: [AXNode] = []
        func collect(_ n: AXNode) { if isNewChat(n) { all.append(n) }; n.kids.forEach(collect) }
        collect(root)
        return all.count == 1 ? all[0] : nil
    }

    /// The handoff file a `/handoff` reply names ("docs/handoffs/2026-10-08-1712-baton-big-tasks.md"),
    /// as the name to resume with (no folder, no ".md"). The last one in the text, skipping any in `before`.
    public static func handoffName(in text: String, excluding before: Set<String> = []) -> String? {
        handoffNames(in: text).last { !before.contains($0) }
    }

    public static func handoffNames(in text: String) -> [String] {
        // Handoff files are named "2026-10-08-2301-slug.md". Matched by that shape wherever it appears: a
        // window's text can split a link into pieces ("docs/handoffs/ 2026-…md") or drop the folder.
        let pattern = #"(?<![A-Za-z0-9._-])(\d{4}-\d{2}-\d{2}-\d{4,6}(?:-[A-Za-z0-9._-]+)?)\.md"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
            .filter { $0.uppercased() != "INDEX" }
    }

    // MARK: Acting (live elements)

    /// Puts the keyboard focus in the box: through Accessibility, else by clicking it.
    @discardableResult
    public static func focus(_ box: AXNode) -> Bool {
        guard let el = box.element else { return false }
        if AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXFocusedAttribute as CFString, &v) == .success, (v as? Bool) == true { return true }
        }
        return AX.click(el)
    }

    /// Types text into whatever has the keyboard focus, as key events (the clipboard isn't touched).
    public static func type(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                chunk.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                e?.post(tap: .cghidEventTap)
            }
            usleep(25_000)
            i += 16
        }
    }

    /// Presses Send through Accessibility, else clicks it.
    @discardableResult
    public static func pressSend(_ send: AXNode) -> Bool {
        guard let el = send.element else { return false }
        if AXUIElementPerformAction(el, kAXPressAction as CFString) == .success { return true }
        return AX.click(el)
    }

    /// Presses a button (the new-chat one) through Accessibility, else clicks it.
    @discardableResult
    public static func press(_ node: AXNode) -> Bool {
        guard let el = node.element else { return false }
        if AXUIElementPerformAction(el, kAXPressAction as CFString) == .success { return true }
        return AX.click(el)
    }
}
