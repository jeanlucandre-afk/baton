import AppKit
@preconcurrency import ApplicationServices

/// A chat or agent as an app lists it in its sidebar, with the status the app itself shows.
/// Claude, ChatGPT and Grok Bot all expose this to Accessibility, for chats that aren't on screen too.
public struct ChatRow: Sendable, Hashable, Codable {
    public let name: String
    public let status: ChatStatus
    public init(name: String, status: ChatStatus) { self.name = name; self.status = status }
}

public enum ChatStatus: String, Sendable, Codable {
    case working, needsInput, unread, idle

    /// How a chat status reads as a Baton state.
    public var windowState: WindowState {
        switch self {
        case .working: .working
        case .needsInput: .needsYou
        case .unread: .finished
        case .idle: .idle
        }
    }
}

public enum Sidebar {
    // Words apps use for a chat's status. Checked as a leading word ("Running X"), a comma part
    // ("X, Unread activity") or a hidden screen-reader label inside the row ("Unread").
    static let vocabulary: [(ChatStatus, [String])] = [
        (.needsInput, ["needs input", "needs attention", "needs approval", "waiting for input", "awaiting input", "awaiting approval", "action required",
                       "awaiting your input", "waiting for your input", "needs your input", "awaiting your approval", "needs your approval"]),
        (.working, ["running", "working", "generating", "thinking", "responding", "in progress", "streaming", "busy", "typing", "loading"]),
        (.unread, ["unread activity", "unread response", "unread", "new messages", "new message", "new activity", "completed", "finished"]),
        (.idle, ["idle"])
    ]

    /// `exact`: only whole known words count, no "Running agent" prefix reading. For text that could be
    /// anything, like short labels inside a row ("Thinking about pricing" is a chat's name).
    static func status(of phrase: String, overrides: [String: ChatStatus] = [:], exact: Bool = false) -> ChatStatus? {
        // "Completed, unread": read each part and keep the strongest.
        let parts = phrase.components(separatedBy: ",")
        if parts.count > 1 { return strongest(parts.compactMap { status(of: $0, overrides: overrides, exact: exact) }) }
        let p = phrase.lowercased().trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        if let s = overrides[p] { return s }
        if let s = vocabulary.first(where: { $0.1.contains(p) })?.0 { return s }
        if let s = LearnedStatus.shared.status(of: p) { return s }
        // Short labels that lead with a working word: "Working…", "Running agent", "Generating response".
        guard !exact, p.count <= 24 else { return nil }
        return vocabulary.first(where: { $0.0 == .working })?.1.first(where: { p.hasPrefix($0 + " ") }).map { _ in .working }
    }

    /// A profile's leading words plus learned ones, longest first. Rebuilt only when either changes,
    /// not for every button of every poll.
    static func leadingWords(_ p: Profile) -> [String] {
        guard !p.leading.isEmpty else { return [] }
        let version = LearnedStatus.shared.version
        return leadingCache.lock.withLock {
            if let hit = leadingCache.words[p.leading], hit.version == version { return hit.words }
            let words = Set(p.leading.map { $0.lowercased() }).union(LearnedStatus.shared.all.keys)
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            if leadingCache.words.count > 16 { leadingCache.words.removeAll() }
            leadingCache.words[p.leading] = (version, words)
            return words
        }
    }

    private final class LeadingCache: @unchecked Sendable {
        let lock = NSLock()
        var words: [[String]: (version: Int, words: [String])] = [:]
    }
    private static let leadingCache = LeadingCache()

    /// The profile in use for an app (see `Profiles`).
    public static func profile(_ bundleID: String?) -> Profile { Profiles.shared.current.profile(bundleID) }

    /// Reads one sidebar row's label (and any short hidden labels inside it). Returns nil for rows that
    /// carry no status, so ordinary buttons are never mistaken for chats.
    public static func parse(label raw: String, hiddenLabels: [String] = [], bundleID: String? = nil) -> ChatRow? {
        parse(label: raw, hiddenLabels: hiddenLabels, profile: profile(bundleID))
    }

    public static func parse(label raw: String, hiddenLabels: [String] = [], profile p: Profile) -> ChatRow? {
        parse(label: raw, hiddenLabels: hiddenLabels, profile: p, leading: leadingWords(p))
    }

    /// `leading`: the profile's `leadingWords`, looked up once per walk instead of once per button.
    static func parse(label raw: String, hiddenLabels: [String], profile p: Profile, leading: [String]) -> ChatRow? {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 160 else { return nil }
        let lower = label.lowercased()
        func valid(_ name: String) -> Bool { name.filter(\.isLetter).count >= 2 }

        // Claude Code: a session with a pull request shows the PR's badge (purple merged, green open) where
        // the status dot goes, and its label starts with it: "#22, #23 · Merged Zupi · Part 3". The badge
        // means the session isn't running; a status word after it still counts.
        if !leading.isEmpty, let rest = strippingPullRequestBadge(label) {
            if let row = parse(label: rest, hiddenLabels: hiddenLabels, profile: p, leading: leading) { return row }
            if valid(rest) { return ChatRow(name: rest, status: .idle) }
        }

        // "Running Northwind task tracking LLM". Longest word first, so "unread response" beats "unread".
        for w in leading where lower.hasPrefix(w + " ") {
            guard let status = status(of: w, overrides: p.overrides) else { continue }
            let name = String(label.dropFirst(w.count + 1)).trimmingCharacters(in: .whitespaces)
            if valid(name) { return ChatRow(name: name, status: status) }
        }
        // "Planner, Main Bot, Unread activity"
        let parts = label.components(separatedBy: ", ")
        if p.comma, parts.count > 1, valid(parts[0]) {
            if let s = strongest(parts.dropFirst().compactMap { status(of: $0, overrides: p.overrides) }) { return ChatRow(name: parts[0], status: s) }
        }
        // ChatGPT: a hidden "Unread" label or a spinner inside the row. Grok Bot: its status dot.
        // The row's own title shows up among those labels too, so text that's part of the name is not a
        // status, and only whole status words count ("Thinking about pricing" is a name, not "thinking").
        let hidden = hiddenLabels.filter { h in
            let t = h.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return !t.isEmpty && !lower.contains(t)
        }
        if p.hidden, let s = strongest(hidden.compactMap { status(of: $0, overrides: p.overrides, exact: true) }) {
            let name = p.comma ? parts[0] : label
            if valid(name) { return ChatRow(name: name, status: s) }
        }
        return nil
    }

    /// Pull-request states Claude Code puts in a session's badge.
    static let pullRequestStates = ["changes requested", "ready for review", "in review", "merged", "open", "opened",
                                    "draft", "closed", "approved", "failing", "passing", "conflicts"]

    /// "#22, #23 · Merged Zupi · Part 3" → "Zupi · Part 3". Nil when the label doesn't start with a PR badge.
    static func strippingPullRequestBadge(_ label: String) -> String? {
        guard label.hasPrefix("#"),
              let dot = label.range(of: " · ") else { return nil }
        let numbers = label[label.startIndex..<dot.lowerBound]
        // "#22" or "#22, #23"
        guard numbers.components(separatedBy: ", ").allSatisfy({ $0.hasPrefix("#") && $0.dropFirst().allSatisfy(\.isNumber) && $0.count > 1 })
        else { return nil }
        let after = label[dot.upperBound...]
        let lower = after.lowercased()
        // Known states first (some are two words), longest first; otherwise one capitalised word.
        if let state = pullRequestStates.sorted(by: { $0.count > $1.count }).first(where: { lower.hasPrefix($0 + " ") }) {
            return String(after.dropFirst(state.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        guard let space = after.firstIndex(of: " "), after.first?.isUppercase == true,
              after[after.startIndex..<space].allSatisfy(\.isLetter) else { return nil }
        return String(after[after.index(after: space)...]).trimmingCharacters(in: .whitespaces)
    }

    static func strongest(_ s: [ChatStatus]) -> ChatStatus? {
        let order: [ChatStatus] = [.needsInput, .working, .unread, .idle]
        return order.first(where: s.contains)
    }

    /// All chat rows in a window. Bounded so a huge window can't stall the caller.
    public static func rows(in win: AXWindow, maxNodes: Int = 6000, maxMillis: Double = 250) -> [ChatRow] {
        let book = Profiles.shared.current
        let p = book.profile(win.bundleID)
        guard let root = AXNode.capture(win.element, maxNodes: maxNodes, maxMillis: maxMillis, prune: p.prune) else { return [] }
        return rows(in: root, profile: p, notChats: book.notChats)
    }

    /// Everything one poll needs from a window, from a single capture of its tree.
    public struct WindowRead: Sendable {
        public var rows: [ChatRow]
        public var openName: String?
        public var generating: Bool
        public var sections: [Section]
        /// The captured tree, for follow-up lookups (unknown status words) without reading again.
        public var root: AXNode?
        /// The capture hit its time or node limit, so missing rows prove nothing.
        public var truncated: Bool
        /// Every row's name in order, duplicates kept (two sessions both called "Handoff resume").
        public var names: [String] = []
        /// Folder headers ("baton" above its sessions in Claude Code): never chats.
        public var folders: [String] = []
    }

    public static func read(_ win: AXWindow) -> WindowRead {
        var truncated = false
        let book = Profiles.shared.current
        // 500 ms: an app busy streaming a reply (Cursor) answers slowly, and a read cut short misses its stop button.
        let root = AXNode.capture(win.element, maxNodes: 6000, maxMillis: 500, prune: book.profile(win.bundleID).prune, truncated: &truncated)
        return read(root, bundleID: win.bundleID, truncated: truncated, book: book)
    }

    /// The same from an already captured tree (a fixture in tests).
    public static func read(_ root: AXNode?, bundleID: String?, truncated: Bool = false, book: ProfileBook = Profiles.shared.current) -> WindowRead {
        let open = root.map { openChat(in: $0, bundleID: bundleID) } ?? (name: nil, generating: false)
        let p = book.profile(bundleID)
        // One walk for both: every row's name, and the rows themselves without repeats.
        var names: [String] = []
        var rows: [ChatRow] = []
        var seen = Set<String>()
        if let root {
            scan(root, profile: p, notChats: Set(book.notChats)) { _, row in
                names.append(row.name)
                if seen.insert(row.name).inserted { rows.append(row) }
                return false
            }
        }
        return WindowRead(rows: rows,
                          openName: open.name, generating: open.generating,
                          sections: root.map { sections(in: $0) } ?? [], root: root, truncated: truncated,
                          names: names, folders: root.map(folders(in:)) ?? [])
    }

    /// Folder headers: a "New session in X" button names folder X.
    public static func folders(in root: AXNode) -> [String] {
        var out: [String] = []
        var stack = [root]
        while let n = stack.popLast() {
            if n.role == "AXButton", let d = n.desc, d.hasPrefix("New session in ") { out.append(String(d.dropFirst(15))) }
            stack.append(contentsOf: n.kids)
        }
        return out
    }

    /// A chat renamed between two reads of the same list: exactly one name went away and exactly one
    /// name nobody had before came in ("Handoff resume" → "Baton · Part 4"). Nil when it's ambiguous
    /// (a chat closed while another started, or nothing changed).
    public static func rename(from before: [String], to after: [String]) -> (old: String, new: String)? {
        var count: [String: Int] = [:]
        for n in before { count[n, default: 0] += 1 }
        var added: [String] = []
        for n in after {
            if let c = count[n], c > 0 { count[n] = c - 1 } else { added.append(n) }
        }
        let gone = count.flatMap { name, c in Array(repeating: name, count: c) }
        guard gone.count == 1, added.count == 1, !before.contains(added[0]) else { return nil }
        return (gone[0], added[0])
    }

    /// All chat rows in a captured tree, read with one profile. Pure, so fixtures and repairs use it too.
    public static func rows(in root: AXNode, profile p: Profile, notChats: [String] = ProfileBook.builtIn.notChats) -> [ChatRow] {
        var out: [ChatRow] = []
        var seen = Set<String>()
        scan(root, profile: p, notChats: Set(notChats)) { _, row in
            if seen.insert(row.name).inserted { out.append(row) }
            return false
        }
        return out
    }

    /// Walks a tree and calls `visit` for each chat row's button; `visit` returns true to stop.
    /// For icon profiles, an icon's status applies to the button that shares its grandparent
    /// (row → icon wrapper → icon, row → button).
    private static func scan(_ root: AXNode, profile p: Profile, notChats: Set<String>, visit: (AXNode, ChatRow) -> Bool) {
        var stack: [(node: AXNode, parent: Int, grand: Int, inList: Bool, up: AXNode?)] = [(root, 0, 0, false, nil)]
        var nextGroup = 1
        var iconStatus: [Int: ChatStatus] = [:]
        let leading = leadingWords(p)
        while let (n, parent, grand, inList, up) = stack.popLast() {
            if p.skip?.matches(n) == true { continue }
            var kidsInList = inList || (p.list?.matches(n) ?? false)
            if p.icon, n.role == "AXImage", let d = n.desc, d.count <= 24, let s = status(of: d, overrides: p.overrides) {
                iconStatus[grand] = s
            }
            if n.role == "AXButton" || n.role == "AXLink" || n.role == "AXRow" {
                let label = n.label
                if isFolder(n, profile: p) || notChats.contains(label.lowercased().trimmingCharacters(in: .whitespaces))
                    || p.folderControls.contains(where: label.hasPrefix)
                    || (!p.notChatRows.isEmpty && up.map { hasButton($0, named: p.notChatRows) } == true) {
                    // A folder's own button and its controls aren't chats; the chats listed beside it are.
                    kidsInList = false
                } else {
                    var row = parse(label: label, hiddenLabels: p.hidden ? shortTexts(under: n.kids) : [], profile: p, leading: leading)
                    if row == nil, p.icon, let s = iconStatus[parent], label.filter(\.isLetter).count >= 2, label.count <= 160 {
                        row = ChatRow(name: label.trimmingCharacters(in: .whitespacesAndNewlines), status: s)
                    }
                    // Claude's chat tab: "More options for <name>" beside the button marks a chat; the status
                    // element beside it says how it stands, none = quiet. An unknown word: skip (learned later).
                    // A badge there ("15 · open") says nothing about the chat.
                    if row == nil, let menu = p.rowMenu, let up, hasRowMenu(up, menu + label) {
                        if let d = rowStatusDesc(up), LearnedStatus.isWord(d.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))) {
                            if let s = status(of: d, overrides: p.overrides) { row = ChatRow(name: label, status: s) }
                        } else if label.filter(\.isLetter).count >= 2 {
                            row = ChatRow(name: label, status: .idle)
                        }
                    }
                    // A chat in the app's chat list with no status is a quiet chat.
                    if row == nil, inList, n.role == "AXButton" {
                        let name = (p.comma ? label.components(separatedBy: ", ")[0] : label).trimmingCharacters(in: .whitespacesAndNewlines)
                        if name.filter(\.isLetter).count >= 2, name.count <= 160 { row = ChatRow(name: name, status: p.unmarked) }
                    }
                    if let row {
                        if visit(n, row) { return }
                        kidsInList = false   // buttons inside a chat row ("Pin chat") aren't chats
                    }
                }
            }
            let g = nextGroup; nextGroup += 1
            for k in n.kids.reversed() { stack.append((k, g, parent, kidsInList, n)) }
        }
    }

    /// The row holds a menu button with exactly this name (two levels down at most).
    static func hasRowMenu(_ row: AXNode, _ name: String) -> Bool {
        var level = row.kids.map { ($0, 0) }
        while let (k, d) = level.popLast() {
            if k.role == "AXPopUpButton", k.label == name { return true }
            if d < 2 { level.append(contentsOf: k.kids.map { ($0, d + 1) }) }
        }
        return false
    }

    /// The row holds a button with one of these names (two levels down at most).
    static func hasButton(_ row: AXNode, named names: [String]) -> Bool {
        var level = row.kids.map { ($0, 0) }
        while let (k, d) = level.popLast() {
            if k.role == "AXButton", names.contains(k.label) { return true }
            if d < 2 { level.append(contentsOf: k.kids.map { ($0, d + 1) }) }
        }
        return false
    }

    /// The status element beside a row's button ("Unread response"), if it says anything.
    static func rowStatusDesc(_ row: AXNode) -> String? {
        row.kids.first { $0.sub == "AXApplicationStatus" }?.desc.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Tabs

    /// An app tab that lists its own chats (Claude: "Claude" for chats, "Code" for sessions).
    public struct Section: Sendable, Equatable {
        public let name: String
        public let selected: Bool
        /// What the tab's button says about it: "working", "unread activity". Nil = nothing.
        public let activity: String?
        public var status: ChatStatus? { activity.flatMap { Sidebar.status(of: $0) } }
    }

    /// The app's tabs, from its "Mode" switch. Empty for apps without one.
    public static func sections(in root: AXNode) -> [Section] {
        var stack = [root]
        while let n = stack.popLast() {
            if n.role == "AXRadioGroup", n.desc == "Mode" {
                return n.kids.filter { $0.role == "AXRadioButton" }.compactMap { b in
                    let parts = (b.desc ?? b.title ?? "").components(separatedBy: ", ")
                    guard let name = parts.first, !name.isEmpty else { return nil }
                    return Section(name: name, selected: b.value == "true" || b.value == "1",
                                   activity: parts.count > 1 ? parts.dropFirst().joined(separator: ", ") : nil)
                }
            }
            stack.append(contentsOf: n.kids)
        }
        return []
    }

    public static func sections(in win: AXWindow) -> [Section] {
        guard let root = AXNode.capture(win.element, maxNodes: 600, maxMillis: 150) else { return [] }
        return sections(in: root)
    }

    /// Switches the app to a tab (presses its button in the "Mode" switch).
    @discardableResult
    public static func selectSection(_ name: String, in win: AXWindow) -> Bool {
        guard let root = AXNode.capture(win.element, maxNodes: 600, maxMillis: 300) else { return false }
        var stack = [root]
        while let n = stack.popLast() {
            if n.role == "AXRadioButton", (n.desc ?? n.title ?? "").components(separatedBy: ", ").first == name, let el = n.element {
                AXUIElementPerformAction(el, kAXPressAction as CFString)
                func selected() -> Bool { sections(in: win).first(where: \.selected)?.name == name }
                for _ in 0..<5 { Thread.sleep(forTimeInterval: 0.12); if selected() { return true } }
                // Ignored the press: click it like a person would (window forward first).
                AX.raise(win)
                Thread.sleep(forTimeInterval: 0.3)
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == win.pid, AX.click(el) else { return false }
                for _ in 0..<6 { Thread.sleep(forTimeInterval: 0.15); if selected() { return true } }
                return false
            }
            stack.append(contentsOf: n.kids)
        }
        return false
    }

    /// A folder or section header: it has a "Project actions for …" control inside, or a header class.
    private static func isFolder(_ n: AXNode, profile p: Profile) -> Bool {
        if let c = n.classes, p.folderClasses.contains(where: c.contains) { return true }
        guard !p.folderControls.isEmpty else { return false }
        var level = n.kids.map { ($0, 0) }
        while let (k, d) = level.popLast() {
            let name = k.label
            if p.folderControls.contains(where: { name.hasPrefix($0) }) { return true }
            if d < 2 { level.append(contentsOf: k.kids.map { ($0, d + 1) }) }
        }
        return false
    }

    /// Short labels up to three levels inside a row, where hidden status labels, status icons and
    /// spinners live. A spinner (busy or progress indicator) reads as "…busy": the ellipsis keeps it from
    /// being taken for part of a name like "Busy week".
    private static func shortTexts(under kids: [AXNode]) -> [String] {
        var out: [String] = []
        var level = kids.map { ($0, 0) }
        while let (n, d) = level.popLast() {
            if n.role == "AXBusyIndicator" || n.role == "AXProgressIndicator" { out.append("…busy") }
            if n.role == "AXStaticText", let s = n.value, s.count <= 24 { out.append(s) }
            if n.role == "AXImage", let s = n.desc, s.count <= 24 { out.append(s) }
            if n.sub == "AXApplicationStatus", let s = n.desc, s.count <= 24 { out.append(s) }
            if d < 2 { level.append(contentsOf: n.kids.map { ($0, d + 1) }) }
        }
        return out
    }

    /// The chat a window is showing right now, by the app's own title for it (ChatGPT's page title,
    /// Grok Bot's main pane). Nil for apps whose open chat can't be named this way.
    public static func currentChat(in win: AXWindow) -> String? {
        currentChat(element: win.element, bundleID: win.bundleID)
    }

    public static func currentChat(element: AXUIElement, bundleID: String?) -> String? {
        openChat(element: element, bundleID: bundleID, needGenerating: false).name
    }

    /// The chat a window has open, and whether that chat is generating right now (its stop button is
    /// showing). Cursor's sidebar keeps saying "Completed" while an agent runs, so this is how it's seen working.
    public static func openChat(in win: AXWindow) -> (name: String?, generating: Bool) {
        openChat(element: win.element, bundleID: win.bundleID)
    }

    /// How an app names its open chat: given an element's role, subrole and title, the chat's name or nil.
    /// Nil for apps whose open chat can't be named this way.
    static func openChatTitle(_ bundleID: String?) -> ((String, String?, String) -> String?)? {
        switch bundleID {
        case "com.anysphere.sand":
            return { role, sub, t in role == "AXGroup" && sub == "AXLandmarkMain" ? t : nil }
        case "com.openai.chat", "com.openai.codex", "com.anthropic.claudefordesktop":
            return { role, _, t in
                guard role == "AXWebArea" else { return nil }
                var t = t
                // Claude titles its page "<chat> - Claude Code" / "<chat> - Claude"
                for suffix in [" - Claude Code", " - Claude"] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
                return t == "ChatGPT" || t == "Claude" ? nil : t
            }
        case "com.todesktop.230313mzl4w4u92":
            // Cursor: the agent panel's "Chat title. <name>" button
            // An archived chat's title starts with its "archived" icon's label: "Chat title. archived <name>".
            return { role, _, t in
                guard role == "AXButton", t.hasPrefix("Chat title. ") else { return nil }
                let name = String(t.dropFirst("Chat title. ".count))
                return name.hasPrefix("archived ") ? String(name.dropFirst("archived ".count)) : name
            }
        default:
            return nil
        }
    }

    /// The same from a captured tree, so a poll reads the window once.
    public static func openChat(in root: AXNode, bundleID: String?) -> (name: String?, generating: Bool) {
        guard let title = openChatTitle(bundleID) else { return (nil, false) }
        var name: String?
        var generating = false
        var stack = [root]
        while let n = stack.popLast() {
            if name == nil, let t = n.title, let found = title(n.role, n.sub, t), found.filter(\.isLetter).count >= 2 { name = found }
            if n.role == "AXButton", Rules.stopButtons.contains(n.label.lowercased()) { generating = true }
            if name != nil && generating { break }
            stack.append(contentsOf: n.kids.reversed())
        }
        return (name, generating)
    }

    /// `needGenerating: false` stops as soon as the name is found, for callers that only want the name.
    public static func openChat(element: AXUIElement, bundleID: String?, maxMillis: Double = 250,
                                needGenerating: Bool = true) -> (name: String?, generating: Bool) {
        guard let title = openChatTitle(bundleID) else { return (nil, false) }
        nonisolated(unsafe) let keys = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXChildrenAttribute, kAXDescriptionAttribute] as CFArray
        let start = Date()
        var name: String?
        var generating = false
        var stack: [AXUIElement] = [element]
        var nodes = 0
        while let el = stack.popLast(), nodes < 6000, Date().timeIntervalSince(start) * 1000 < maxMillis {
            nodes += 1
            var v: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, keys, AXCopyMultipleAttributeOptions(rawValue: 0), &v) == .success,
                  let a = v as? [Any], a.count == 5 else { continue }
            let role = a[0] as? String ?? ""
            let t = a[2] as? String ?? ""
            if name == nil, !t.isEmpty, let n = title(role, a[1] as? String, t), n.filter(\.isLetter).count >= 2 { name = n }
            if role == "AXButton" {
                let label = (t.isEmpty ? a[4] as? String ?? "" : t).lowercased()
                if Rules.stopButtons.contains(label) { generating = true }
            }
            if name != nil && (generating || !needGenerating) { break }
            for k in (a[3] as? [AXUIElement] ?? []).reversed() {
                AXUIElementSetMessagingTimeout(k, AX.messagingTimeout)
                stack.append(k)
            }
        }
        return (name, generating)
    }

    /// The sidebar row for a chat, if the app lists it right now.
    public static func rowElement(_ name: String, in win: AXWindow) -> AXUIElement? {
        let book = Profiles.shared.current
        let p = book.profile(win.bundleID)
        guard let root = AXNode.capture(win.element, maxNodes: 6000, maxMillis: 1000, prune: p.prune) else { return nil }
        var found: AXUIElement?
        scan(root, profile: p, notChats: Set(book.notChats)) { n, row in
            guard find(name, in: [row]) != nil, let el = n.element else { return false }
            found = el
            return true
        }
        return found
    }

    /// The word an app shows in front of a chat that Baton couldn't read: "Awaiting input" in
    /// "Awaiting input Acme audit". Only for apps that put the status first (Claude); after the name,
    /// apps put tags too ("Planner, Main Bot"). Nil when the row isn't there, is just the name
    /// (no status shown, so the chat is quiet), or the word is one Baton knows.
    public static func unknownStatusWord(for name: String, in win: AXWindow) -> String? {
        guard let root = AXNode.capture(win.element, maxNodes: 6000, maxMillis: 400, prune: profile(win.bundleID).prune) else { return nil }
        return unknownStatusWord(for: name, in: root)
    }

    public static func unknownStatusWord(for name: String, in root: AXNode) -> String? {
        let n = name.lowercased()
        var stack = [root]
        while let node = stack.popLast() {
            // Claude's chat tab: the status element beside the row's button
            if node.kids.contains(where: { $0.role == "AXButton" && $0.label == name }),
               hasRowMenu(node, "More options for " + name), let d = rowStatusDesc(node) {
                // A badge like "15 · open" (a pull request's state) is not a status word to learn.
                let w = d.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
                if LearnedStatus.isWord(w), status(of: w) == nil { return w }
            }
            if ["AXButton", "AXLink", "AXRow"].contains(node.role) {
                for raw in [node.title, node.desc].compactMap({ $0?.trimmingCharacters(in: .whitespaces) }) where raw.count <= 160 {
                    let l = raw.lowercased()
                    var word: String?
                    if l.hasSuffix(" " + n) { word = String(raw.dropLast(name.count + 1)) }
                    guard let w = word?.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)),
                          !w.isEmpty, w.count <= 30, w.filter(\.isLetter).count >= 3, LearnedStatus.isWord(w) else { continue }
                    if status(of: w) == nil { return w }
                }
            }
            stack.append(contentsOf: node.kids)
        }
        return nil
    }

    /// Whether the window has this chat open.
    public static func isOpen(_ name: String, in win: AXWindow) -> Bool {
        guard let open = currentChat(in: win) else { return false }
        return find(name, in: [ChatRow(name: open, status: .idle)]) != nil
    }

    /// Apps whose sidebar rows ignore the accessibility press (ChatGPT): Baton clicks them straight away.
    static let pressIgnored: Set<String> = ["com.openai.chat", "com.openai.codex"]

    /// Opens a chat and checks it really opened. Some apps (ChatGPT) ignore the accessibility press on
    /// their sidebar rows; then Baton clicks the row like a person would and puts the pointer back.
    /// Blocks for up to a few seconds, so call it off the main thread.
    public static func openVerified(_ name: String, in win: AXWindow) -> Bool {
        if isOpen(name, in: win) { return true }
        func waitOpen(_ seconds: Double) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                Thread.sleep(forTimeInterval: 0.15)
                if isOpen(name, in: win) { return true }
            }
            return false
        }
        if !pressIgnored.contains(win.bundleID) {
            guard let el = rowElement(name, in: win) else { return false }
            AXUIElementPerformAction(el, kAXPressAction as CFString)
            if waitOpen(0.8) { return true }
        }
        // A real click lands on whatever is on top, so bring the window forward first.
        AX.raise(win)
        let frontBy = Date().addingTimeInterval(1.2)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != win.pid, Date() < frontBy {
            Thread.sleep(forTimeInterval: 0.1)
        }
        Thread.sleep(forTimeInterval: 0.15)
        for _ in 0..<2 {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == win.pid,
                  let el = rowElement(name, in: win), AX.click(el) else { return false }
            if waitOpen(2.5) { return true }
        }
        return false
    }

    /// Finds a task's chat among the rows: exact name, then, where an app cut a long name short with an
    /// ellipsis ("Refactor auth midd…"), the start of it. "Refactor auth" and "Refactor auth middleware"
    /// are two chats.
    public static func find(_ name: String, in rows: [ChatRow]) -> ChatRow? {
        let n = name.lowercased()
        if let r = rows.first(where: { $0.name.lowercased() == n }) { return r }
        let nStem = truncatedStem(n)
        return rows.first { r in
            let l = r.name.lowercased()
            if let stem = truncatedStem(l), n.hasPrefix(stem) { return true }
            if let nStem, l.hasPrefix(nStem) { return true }
            return false
        }
    }

    /// A name without the ellipsis an app put at its end, or nil if it isn't cut short (or too little is left).
    static func truncatedStem(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("…") { t.removeLast() } else if t.hasSuffix("...") { t.removeLast(3) } else { return nil }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.count >= 8 ? t : nil
    }
}
