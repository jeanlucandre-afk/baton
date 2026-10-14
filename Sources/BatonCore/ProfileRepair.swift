import Foundation

/// Re-learns how to read an app's sidebar after an update broke its profile.
///
/// 1. **Find the list again (free, on the Mac):** look for the element whose buttons carry the chat
///    names Baton saw before, and point the profile's `list` at it.
/// 2. **Ask Gemini:** if that isn't enough, send a compact outline of the window (no long text) with the
///    current profile and ask for a corrected one.
///
/// Either way, a candidate is only accepted if it reads the live window back into chats Baton already
/// knows. A bad guess can't replace a working profile.
public enum ProfileRepair {
    public struct Outcome: Sendable {
        public let profile: Profile
        public let rows: [ChatRow]
        public let knownFound: Int
        public let via: String     // "list search" or "Gemini"
        /// Statuses the window shows ("Running") that these rows don't carry: names read, statuses lost.
        public var missedStatuses = 0
        /// The profile in use already read this well: nothing to save.
        public var unchanged = false
    }

    public static func repair(root: AXNode, bundleID: String, appName: String, known: [String], usual: Int,
                              smart: Smart?, book: ProfileBook = Profiles.shared.current, localSearch: Bool = true,
                              log: (@Sendable (String) -> Void)? = nil) async -> Outcome? {
        let current = book.profile(bundleID)
        if localSearch, let o = findList(root: root, current: current, known: known, usual: usual, notChats: book.notChats) {
            return checked(o, root: root, current: current, notChats: book.notChats)
        }
        guard let smart else { return nil }
        let prompt = request(appName: appName, current: current, known: known, outline: outline(root))
        log?("List search found nothing; asking Gemini (\(prompt.count) chars)")
        guard let raw = await smart.json(prompt, maxTokens: 800) else { log?("No answer from Gemini"); return nil }
        log?("Gemini: \(raw)")
        guard let p = try? JSONDecoder().decode(Profile.self, from: Data(raw.utf8)) else { log?("Not a profile"); return nil }
        for v in variants(of: p) {
            let rows = Sidebar.rows(in: root, profile: v, notChats: book.notChats)
            log?("  comma=\(v.comma) hidden=\(v.hidden): \(rows.count) rows, e.g. \(rows.prefix(3).map(\.name))")
        }
        return best(variants(of: p).compactMap { validate($0, root: root, known: known, usual: usual, notChats: book.notChats, via: "Gemini") }, known: known)
            .map { checked($0, root: root, current: current, notChats: book.notChats) }
    }

    /// Notes whether the repair changed anything and whether its rows still miss statuses.
    static func checked(_ o: Outcome, root: AXNode, current: Profile, notChats: [String]) -> Outcome {
        var o = o
        o.missedStatuses = missedStatuses(root: root, rows: o.rows, skip: o.profile.skip)
        o.unchanged = o.profile == current
            || Set(Sidebar.rows(in: root, profile: current, notChats: notChats)) == Set(o.rows)
        return o
    }

    /// How many active statuses (running, needs you, unread) the window's status elements show beyond
    /// those the rows carry. Above zero, names are read but statuses are lost: the row's status element
    /// moved somewhere the reader doesn't look, which a profile can't fix.
    public static func missedStatuses(root: AXNode, rows: [ChatRow], skip: NodeMatch? = nil) -> Int {
        var shown = 0
        var stack = [root]
        while let n = stack.popLast() {
            if skip?.matches(n) == true { continue }   // the conversation: a step there isn't a chat's status
            if n.sub == "AXApplicationStatus" {
                let text = n.desc ?? n.title ?? n.kids.compactMap(\.value).joined(separator: " ")
                if text.count <= 40, let s = Sidebar.status(of: text, exact: true), s != .idle { shown += 1 }
            }
            stack.append(contentsOf: n.kids)
        }
        return max(0, shown - rows.filter { $0.status != .idle }.count)
    }

    // MARK: Checking a candidate

    public static func validate(_ p: Profile, root: AXNode, known: [String], usual: Int, notChats: [String], via: String) -> Outcome? {
        if p.list?.isTooLoose == true { return nil }
        let rows = Sidebar.rows(in: root, profile: p, notChats: notChats)
        guard rows.count >= max(2, Int(Double(usual) * 0.5)), rows.count <= 400 else { return nil }
        // Far more chats than the app ever listed: the list takes in the rest of the window.
        if usual > 0, rows.count > Int(Double(usual) * 1.5) + 5 { return nil }
        // Toolbar and message buttons ("Back", "Copy", "Ran 2 commands") read as chats: wrong element.
        if rows.filter({ ProfileBook.isControl($0.name) }).count >= 2 { return nil }
        // Lots of rows with the same few names means it latched onto buttons, not chats.
        guard Double(Set(rows.map(\.name)).count) >= Double(rows.count) * 0.8 else { return nil }
        let found = known.filter { Sidebar.find($0, in: rows) != nil }.count
        if !known.isEmpty, found < min(3, known.count) { return nil }
        return Outcome(profile: p, rows: rows, knownFound: found, via: via)
    }

    // MARK: 1. Find the list again

    /// Finds the kind of element that holds the known chats (apps often split chats across several lists,
    /// one per folder), preferring the tightest one: most known chats inside, fewest other buttons.
    static func findList(root: AXNode, current: Profile, known: [String], usual: Int, notChats: [String]) -> Outcome? {
        guard known.count >= 3 else { return nil }
        let lowered = known.map { $0.lowercased() }
        func isKnown(_ label: String) -> Bool {
            let l = label.lowercased()
            return lowered.contains { l == $0 || l.hasPrefix($0) || $0.hasPrefix(l) || l.hasSuffix(" " + $0) }
        }
        func isRow(_ n: AXNode) -> Bool { n.role == "AXButton" || n.role == "AXLink" || n.role == "AXRow" }

        // Status words now written in front of known names ("Idle Handoff resume").
        var leading = Set(current.leading.map { $0.lowercased() })
        func collectLeading(_ n: AXNode) {
            if isRow(n) {
                let l = n.label.lowercased()
                for k in lowered where l.count > k.count + 1 && l.hasSuffix(" " + k) {
                    let word = String(l.dropLast(k.count + 1))
                    if word.count <= 24, Sidebar.status(of: word) != nil { leading.insert(word) }
                }
            }
            n.kids.forEach(collectLeading)
        }
        collectLeading(root)

        // For each kind of container near a known chat: how many known chats it covers.
        var coverage: [NodeMatch: Int] = [:]
        var totalKnown = 0
        func walk(_ n: AXNode, ancestors: [AXNode]) {
            if isRow(n), isKnown(n.label) {
                totalKnown += 1
                for m in Set(ancestors.suffix(6).compactMap(NodeMatch.describing)) { coverage[m, default: 0] += 1 }
            }
            for k in n.kids { walk(k, ancestors: ancestors + [n]) }
        }
        walk(root, ancestors: [])
        guard totalKnown >= 3 else { return nil }

        // Buttons inside matching containers that aren't known chats: the lower, the tighter.
        func spill(_ m: NodeMatch) -> Int {
            var extra = 0
            func count(_ n: AXNode, inside: Bool) {
                let inside = inside || m.matches(n)
                if inside, isRow(n), !isKnown(n.label) { extra += 1 }
                for k in n.kids { count(k, inside: inside) }
            }
            count(root, inside: false)
            return extra
        }
        let matches = coverage.filter { Double($0.value) >= Double(totalKnown) * 0.6 }.keys
            .map { (m: $0, cover: coverage[$0]!, spill: spill($0)) }
            .sorted { ($0.spill, -$0.cover) < ($1.spill, -$1.cover) }
            .prefix(3)

        var base = current
        base.leading = leading.sorted()
        // With the status words back, the list may not have moved at all.
        let candidates = variants(of: base) + matches.flatMap { m -> [Profile] in
            var p = base
            p.list = m.m
            return variants(of: p)
        }
        return best(candidates.compactMap { validate($0, root: root, known: known, usual: usual, notChats: notChats, via: "list search") }, known: known)
    }

    /// A profile as given, plus the other ways a row can carry its status.
    static func variants(of p: Profile) -> [Profile] {
        var out = [p]
        for (comma, hidden) in [(true, true), (false, true), (true, false)] {
            var v = p
            v.comma = comma
            v.hidden = hidden
            if !out.contains(v) { out.append(v) }
        }
        return out
    }

    /// The candidate that finds the most known chats with the fewest unknown rows, and whose names are
    /// clean (no ", Unread activity" left in a name).
    static func best(_ outcomes: [Outcome], known: [String]) -> Outcome? {
        // Ties go to the profile that still sees statuses (unread, running), which is the point of reading.
        func score(_ o: Outcome) -> (Int, Int, Int) {
            let dirty = o.rows.filter { $0.name.contains(", ") && Sidebar.status(of: $0.name) != nil }.count
            let extras = o.rows.filter { r in !known.contains { Sidebar.find($0, in: [r]) != nil } }.count
            return (o.knownFound, -(extras + dirty * 3), o.rows.filter { $0.status != .idle }.count)
        }
        return outcomes.max { score($0) < score($1) }
    }

    // MARK: 2. Ask Gemini

    /// One line per element: role, subrole, short names and classes. Long text (conversation content) is left out.
    public static func outline(_ root: AXNode, maxLines: Int = 1200) -> String {
        var lines: [String] = []
        func short(_ s: String?, _ n: Int = 40) -> String? { s.flatMap { $0.count <= n ? $0 : nil } }
        func walk(_ n: AXNode, _ d: Int) {
            guard lines.count < maxLines else { return }
            var parts = ["role=\(n.role)"]
            if let s = n.sub { parts.append("sub=\(s)") }
            if let t = short(n.title) { parts.append("title=\(t)") }
            if let t = short(n.desc), t != n.title { parts.append("desc=\(t)") }
            if let v = short(n.value) { parts.append("val=\(v)") }
            if let c = n.classes { parts.append("class=\(c.prefix(48))") }
            lines.append(String(repeating: " ", count: min(d, 30)) + parts.joined(separator: " "))
            for k in n.kids { walk(k, d + 1) }
        }
        walk(root, 0)
        return lines.joined(separator: "\n")
    }

    static func request(appName: String, current: Profile, known: [String], outline: String) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let cur = (try? enc.encode(current)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return """
        Baton reads the chat list in \(appName)'s sidebar through macOS Accessibility. An app update broke it: \
        the profile below no longer finds the chats. Fix the profile so it does.

        How a profile is used:
        - Chat rows are AXButton, AXLink or AXRow elements; a row's name is its title, else its desc.
        - "list": the element that lists every chat (fields role, subrole, title, desc, classContains; all set fields must match; \
        copy role and subrole values exactly as they appear after role= and sub= in the window). \
        Buttons inside it with no status are quiet chats. Pick the closest element that contains all the chat rows.
        - "leading": status words in front of a name ("Running My chat").
        - "comma": true if rows read "Name, Status".
        - "hidden": true if status sits in short text, an image or a spinner inside the row.
        - "icon": true if status is an image next to the row's button.
        - "overrides": status words mapped to working, needsInput, unread or idle.
        - "folderControls": name prefixes of controls inside folder rows ("Project actions for"), so folders aren't chats.
        - "folderClasses": class substrings of section headers.
        - "openChat": the element whose title names the open chat. "titleSuffixes": endings to remove from it.

        Current profile:
        \(cur)

        Chats Baton saw before (they may have changed a little): \(known.prefix(25).joined(separator: " | "))

        The window, one element per line (indent = depth):
        <window>
        \(outline)
        </window>

        Return only the corrected profile as JSON, with the same fields.
        """
    }
}

extension NodeMatch {
    /// A match for this element by its stable traits (role with subrole, desc or a class), or nil if it has none.
    static func describing(_ n: AXNode) -> NodeMatch? {
        let cls = n.classes?.split(separator: ".").map(String.init).first { $0.count >= 4 && $0.count <= 48 && !isGeneric($0) }
        let desc = n.desc.flatMap { $0.count <= 40 ? $0 : nil }
        if n.sub == nil && desc == nil && cls == nil { return nil }
        return NodeMatch(role: n.role, subrole: n.sub, desc: desc, classContains: n.sub == nil && desc == nil ? cls : nil)
    }
}
