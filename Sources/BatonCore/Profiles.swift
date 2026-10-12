import Foundation

/// How Baton reads one app's sidebar. Profiles are data, not code: when an app redesigns its sidebar,
/// a new profile (edited by hand, re-learned by `ProfileRepair`, or downloaded) fixes it without a rebuild.
public struct Profile: Codable, Sendable, Equatable {
    /// Status words allowed in front of a chat's name ("Running X").
    public var leading: [String] = []
    /// "X, Unread activity".
    public var comma = true
    /// A short hidden label, status icon or spinner inside the row ("Unread").
    public var hidden = true
    /// Status is an icon next to the row's button (Cursor: "Completed").
    public var icon = false
    /// Status words that are new or mean something else in this app ("completed" → idle in Cursor).
    public var overrides: [String: ChatStatus] = [:]
    /// The element that lists every chat. Buttons inside it with no status are quiet chats.
    public var list: NodeMatch?
    /// A row holding a control whose name starts with one of these is a folder or section, not a chat
    /// ("Project actions for NORTH STUDIO").
    public var folderControls: [String] = []
    /// DOM class substrings of rows that are headers, not chats ("section__header").
    public var folderClasses: [String] = []
    /// Where the app names the chat that's open (ChatGPT's page title).
    public var openChat: NodeMatch?
    /// Endings to strip from that name (" - Claude").
    public var titleSuffixes: [String] = []
    /// A chat row has a menu button named this plus the chat's name beside it ("More options for X");
    /// its status is the status element beside it, and no status means quiet (Claude's chat tab).
    public var rowMenu: String?
    /// A part of the window that never lists chats, skipped whole: Claude's conversation, where a step
    /// shows as "Running skill /design-shotgun running" and would read like a running chat.
    public var skip: NodeMatch?
    /// A part of the window not even copied when reading it, because nothing read from a window lives
    /// there: Claude's chat messages, most of a long chat's elements. The composer beside it, with its
    /// stop button, is still read.
    public var prune: NodeMatch?
    /// How a chat in the list that shows no status at all stands. Quiet by default; in Cursor every
    /// finished agent shows "Completed", and only a running one has no icon (its spinner is invisible to
    /// Accessibility), so there no status means working.
    public var unmarked: ChatStatus = .idle
    /// A row holding a button with one of these names is not a chat, whatever it shows: Cursor's
    /// suggested projects ("Remove Suggestion") carry no status icon, which `unmarked` would read as working.
    public var notChatRows: [String] = []

    public init(leading: [String] = [], comma: Bool = true, hidden: Bool = true, icon: Bool = false,
                overrides: [String: ChatStatus] = [:], list: NodeMatch? = nil,
                folderControls: [String] = [], folderClasses: [String] = [], openChat: NodeMatch? = nil, titleSuffixes: [String] = [],
                rowMenu: String? = nil, skip: NodeMatch? = nil, prune: NodeMatch? = nil, unmarked: ChatStatus = .idle,
                notChatRows: [String] = []) {
        self.leading = leading; self.comma = comma; self.hidden = hidden; self.icon = icon; self.overrides = overrides
        self.list = list; self.folderControls = folderControls; self.folderClasses = folderClasses
        self.openChat = openChat; self.titleSuffixes = titleSuffixes; self.rowMenu = rowMenu; self.skip = skip
        self.prune = prune; self.unmarked = unmarked; self.notChatRows = notChatRows
    }

    // Every field is optional in JSON, so hand-written or re-learned profiles can stay short.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        leading = try c.decodeIfPresent([String].self, forKey: .leading) ?? []
        comma = try c.decodeIfPresent(Bool.self, forKey: .comma) ?? true
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? true
        icon = try c.decodeIfPresent(Bool.self, forKey: .icon) ?? false
        overrides = try c.decodeIfPresent([String: ChatStatus].self, forKey: .overrides) ?? [:]
        list = try c.decodeIfPresent(NodeMatch.self, forKey: .list)
        folderControls = try c.decodeIfPresent([String].self, forKey: .folderControls) ?? []
        folderClasses = try c.decodeIfPresent([String].self, forKey: .folderClasses) ?? []
        openChat = try c.decodeIfPresent(NodeMatch.self, forKey: .openChat)
        titleSuffixes = try c.decodeIfPresent([String].self, forKey: .titleSuffixes) ?? []
        rowMenu = try c.decodeIfPresent(String.self, forKey: .rowMenu)
        skip = try c.decodeIfPresent(NodeMatch.self, forKey: .skip)
        prune = try c.decodeIfPresent(NodeMatch.self, forKey: .prune)
        unmarked = try c.decodeIfPresent(ChatStatus.self, forKey: .unmarked) ?? .idle
        notChatRows = try c.decodeIfPresent([String].self, forKey: .notChatRows) ?? []
    }
}

/// Every app's profile, plus names that are never chats.
public struct ProfileBook: Codable, Sendable, Equatable {
    public var version: Int
    public var apps: [String: Profile]
    /// Browsers and terminals: only the explicit "X, Unread activity" form, so a "Running …" button on a
    /// web page isn't read as a chat.
    public var fallback: Profile
    /// Sidebar controls that are never chats, in any app.
    public var notChats: [String]

    public func profile(_ bundleID: String?) -> Profile { bundleID.flatMap { apps[$0] } ?? fallback }

    public static let builtIn: ProfileBook = {
        let chatGPT = Profile(comma: false, hidden: true,
                              list: NodeMatch(role: "AXList", subrole: "AXContentList"),
                              folderControls: ["Project actions for", "Start new chat in"],
                              openChat: NodeMatch(role: "AXWebArea"),
                              // The conversation: a reply's bullet list is an AXContentList too.
                              skip: NodeMatch(role: "AXGroup", subrole: "AXLandmarkMain"))
        return ProfileBook(
            version: 1,
            apps: [
                "com.anthropic.claudefordesktop": Profile(
                    // "Awaiting input": a question or permission prompt is waiting on you (orange dot).
                    leading: ["running", "idle", "needs input", "needs attention", "needs approval", "waiting for input",
                              "awaiting input", "awaiting approval", "action required", "unread response", "unread",
                              "awaiting your input", "waiting for your input", "needs your input", "awaiting your approval"],
                    comma: false, hidden: false, openChat: NodeMatch(role: "AXWebArea"), titleSuffixes: [" - Claude Code", " - Claude"],
                    rowMenu: "More options for ",
                    // The conversation: chats are only ever listed in the sidebar.
                    skip: NodeMatch(role: "AXGroup", subrole: "AXLandmarkMain"),
                    prune: NodeMatch(role: "AXGroup", subrole: "AXApplicationGroup", desc: "Chat messages")),
                "com.openai.chat": chatGPT,
                "com.openai.codex": chatGPT,
                "com.anysphere.sand": Profile(
                    comma: true, hidden: true, list: NodeMatch(role: "AXGroup", desc: "Bot list"),
                    folderClasses: ["section__header"], openChat: NodeMatch(role: "AXGroup", subrole: "AXLandmarkMain")),
                // Cursor keeps "Completed" on every finished agent, so it means done-and-quiet, not new. A
                // running agent shows a spinner Accessibility can't see (no icon at all): every row in the
                // chat list counts, and the open chat's stop button says it's working.
                "com.todesktop.230313mzl4w4u92": Profile(comma: false, hidden: false, icon: true, overrides: ["completed": .idle, "archived": .idle],
                                                         // The sidebar's lists only: a reply's bullet list is an AXContentList too.
                                                         list: NodeMatch(role: "AXList", subrole: "AXContentList", classContains: "ui-sidebar-menu"),
                                                         skip: NodeMatch(classContains: "agent-panel"),
                                                         // The open agent's messages: two thirds of the window's tree, and
                                                         // nothing a poll reads is in there (the chat title, stop button and
                                                         // context meter sit above and below it).
                                                         prune: NodeMatch(classContains: "agent-conversation-composer__viewport"),
                                                         unmarked: .working,
                                                         notChatRows: ["Remove Suggestion"])
            ],
            fallback: Profile(comma: true, hidden: false),
            notChats: ["show more", "show less", "see all", "see more", "load more", "new chat", "new project", "new agent",
                       "recents", "projects", "chats", "library", "search", "search chats", "settings"] + controls)
    }()

    /// Window controls that are never chats: toolbar and message buttons a too-broad list would take for chats.
    static let controls = ["back", "forward", "send", "stop", "copy", "dismiss", "hide sidebar", "show sidebar", "new", "customize",
                           "artifacts", "send feedback", "read aloud", "fork from here", "rewind to here", "create pr", "terminal",
                           "copy code", "load earlier messages", "more", "pin", "unpin", "archive", "unarchive", "remove suggestion"]
    /// Starts of control names that carry a variable part ("Show message actions for …", "Ran 2 commands").
    static let controlPrefixes = ["show message actions", "remove ", "screenshot", "ran ", "new session in", "used ",
                                  "run in terminal", "deny ", "allow "]

    /// A name that belongs to a window control, not a chat.
    public static func isControl(_ name: String) -> Bool {
        let n = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return builtIn.notChats.contains(n) || controlPrefixes.contains(where: n.hasPrefix)
    }

    /// Built-in profiles with any saved ones on top (per app, a saved profile replaces the built-in one).
    /// A saved profile whose list matches nearly the whole window is ignored.
    public func merged(with other: ProfileBook) -> ProfileBook {
        var b = self
        b.version = max(version, other.version)
        b.apps.merge(other.apps.filter { !($0.value.list?.isTooLoose ?? false) }) { _, new in new }
        b.notChats = Array(Set(notChats + other.notChats)).sorted()
        return b
    }
}

/// The profiles in use. Loaded at launch from the built-in set plus
/// `~/Library/Application Support/Baton/profiles.json`, which repairs and updates write to.
public final class Profiles: @unchecked Sendable {
    public static let shared = Profiles()
    private let lock = NSLock()
    private var book = ProfileBook.builtIn

    public static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Baton")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "profiles.json")
    }

    public init() { reload() }

    public var current: ProfileBook { lock.withLock { book } }

    /// The saved profiles alone (not merged), or nil if there are none or the file doesn't parse.
    public var saved: ProfileBook? {
        guard let d = try? Data(contentsOf: Self.fileURL) else { return nil }
        return try? JSONDecoder().decode(ProfileBook.self, from: d)
    }

    public func reload() {
        let b = saved.map { ProfileBook.builtIn.merged(with: $0) } ?? .builtIn
        lock.withLock { book = b }
    }

    /// Saves one app's profile (a repair) and starts using it.
    public func save(_ p: Profile, for bundleID: String) throws {
        var s = saved ?? ProfileBook(version: 1, apps: [:], fallback: ProfileBook.builtIn.fallback, notChats: [])
        s.apps[bundleID] = p
        s.version += 1
        try write(s)
    }

    /// Drops a saved profile, going back to the built-in one.
    public func reset(_ bundleID: String) throws {
        guard var s = saved else { return }
        s.apps[bundleID] = nil
        try write(s)
    }

    private func write(_ s: ProfileBook) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(s).write(to: Self.fileURL, options: .atomic)
        reload()
    }
}
