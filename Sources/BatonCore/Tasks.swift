import Foundation

/// What Baton remembers about a window across launches: AX handles and pids don't survive a relaunch,
/// so windows are re-matched by app and title.
public struct WindowRecord: Codable, Hashable, Sendable {
    public var bundleID: String
    public var appName: String
    public var title: String

    public init(bundleID: String, appName: String, title: String) {
        self.bundleID = bundleID; self.appName = appName; self.title = title
    }

    public init(_ w: AXWindow) { self.init(bundleID: w.bundleID, appName: w.appName, title: w.title) }
}

/// A specific chat inside an app (a Claude session, a ChatGPT chat, a Grok Bot agent), tracked through
/// the app's own sidebar status.
public struct ChatRecord: Codable, Hashable, Sendable {
    public var bundleID: String
    public var appName: String
    public var name: String
    /// The app tab the chat lives in, for apps with tabs that each list their own chats
    /// (Claude: "Claude" for chats, "Code" for Claude Code sessions). Nil = the app has no tabs.
    public var section: String?
    public init(bundleID: String, appName: String, name: String, section: String? = nil) {
        self.bundleID = bundleID; self.appName = appName; self.name = name; self.section = section
    }
    // Same chat whatever tab was noted.
    public static func == (a: ChatRecord, b: ChatRecord) -> Bool { a.bundleID == b.bundleID && a.name == b.name }
    public func hash(into h: inout Hasher) { h.combine(bundleID); h.combine(name) }
}

public struct BatonTask: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var title: String
    public var windows: [WindowRecord]
    public var chat: ChatRecord?
    public var steps: [TaskStep] = []
    public var next: String?
    public var createdAt = Date()
    public var pingWhenDone = true
    /// Lets Gemini read the chat to write the ping summary, steps and next action.
    public var readScreen = true
    /// The big task this one sits under, if any.
    public var parentID: UUID?
    /// A big task: a container for subtasks, with no chat or windows of its own.
    public var isGroup = false

    public init(title: String, windows: [WindowRecord]) {
        self.title = title; self.windows = windows
    }

    // Tolerant decoding: tasks saved by older builds lack newer keys.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        windows = try c.decodeIfPresent([WindowRecord].self, forKey: .windows) ?? []
        chat = try c.decodeIfPresent(ChatRecord.self, forKey: .chat)
        steps = try c.decodeIfPresent([TaskStep].self, forKey: .steps) ?? []
        next = try c.decodeIfPresent(String.self, forKey: .next)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        pingWhenDone = try c.decodeIfPresent(Bool.self, forKey: .pingWhenDone) ?? true
        readScreen = try c.decodeIfPresent(Bool.self, forKey: .readScreen) ?? true
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        isGroup = try c.decodeIfPresent(Bool.self, forKey: .isGroup) ?? false
    }
}

/// Saves tasks as JSON in Application Support.
public struct TaskFile: Sendable {
    public let url: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Baton", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("tasks.json")
    }

    /// One task that no longer reads mustn't cost the rest (the next save would write the list back
    /// without them): the file is copied aside as tasks.json.bad-<time>, and every task that reads is kept.
    public func load() -> [BatonTask] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        if let all = try? JSONDecoder().decode([BatonTask].self, from: d) { return Self.tidy(all) }
        let stamp = Int(Date().timeIntervalSince1970)
        try? FileManager.default.copyItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent("tasks.json.bad-\(stamp)"))
        return Self.tidy(((try? JSONDecoder().decode([Lenient].self, from: d)) ?? []).compactMap(\.task))
    }

    /// Big tasks are one level deep. A file edited by hand (or damaged) could say otherwise: a big task
    /// under itself, or two under each other, made deleting one recurse until the stack ran out; a
    /// repeated id shows one task twice. Those are straightened out as the file loads.
    static func tidy(_ tasks: [BatonTask]) -> [BatonTask] {
        var seen = Set<UUID>()
        return tasks.compactMap { t in
            guard seen.insert(t.id).inserted else { return nil }
            var t = t
            if t.isGroup || t.parentID == t.id { t.parentID = nil }
            return t
        }
    }

    /// A task, or nil when that one entry doesn't decode.
    private struct Lenient: Decodable {
        let task: BatonTask?
        init(from decoder: any Decoder) throws { task = try? BatonTask(from: decoder) }
    }

    public func save(_ tasks: [BatonTask]) {
        guard let d = try? JSONEncoder().encode(tasks) else { return }
        try? d.write(to: url, options: .atomic)
    }

    /// Finds the live window for a saved record: same app, same title first, then the app's only window.
    public static func match(_ r: WindowRecord, in live: [AXWindow]) -> AXWindow? {
        let same = live.filter { $0.bundleID == r.bundleID }
        return same.first(where: { $0.title == r.title }) ?? (same.count == 1 ? same.first : nil)
    }
}

/// Asks Jev which open windows belong to a task the user just typed.
public enum WindowMatcher {
    public static func suggest(task: String, windows: [AXWindow], using classifier: any StateClassifier) async -> [AXWindow] {
        guard !windows.isEmpty, task.trimmingCharacters(in: .whitespaces).count >= 3 else { return [] }
        var options: [String: String] = [:]
        for (i, w) in windows.enumerated() {
            options["w\(i)"] = "\(w.appName) window titled \"\(Redact.clean(w.title))\""
        }
        options["none"] = "None of the open windows fit this task"
        let state: [String: any Sendable] = ["task_the_user_is_starting": Redact.clean(task)]
        guard let probs = try? await classifier.choose(
            state: state,
            instructions: "Which open window is the user most likely to use for this task?",
            options: options
        ) else { return [] }
        // Keep every window that's clearly in the running, best first, at most three.
        let ranked = probs.filter { $0.key != "none" && $0.value >= 0.2 }.sorted { $0.value > $1.value }.prefix(3)
        return ranked.compactMap { k, _ in Int(k.dropFirst()).flatMap { windows.indices.contains($0) ? windows[$0] : nil } }
    }
}
