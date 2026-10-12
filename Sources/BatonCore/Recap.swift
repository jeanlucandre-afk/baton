import Foundation

/// One stretch of an AI working on a task, from "working" to whatever came next.
public struct RunRecord: Codable, Equatable, Sendable {
    public var taskID: UUID
    public var title: String
    public var bundleID: String
    public var appName: String
    public var start: Date
    public var end: Date?
    /// What the run ended as (finished, needs you, idle). Nil while it runs.
    public var outcome: WindowState?
    /// Flagged as stuck at some point: left out of the app's usual run length.
    public var stuck = false

    public init(taskID: UUID, title: String, bundleID: String, appName: String, start: Date) {
        self.taskID = taskID; self.title = title; self.bundleID = bundleID; self.appName = appName; self.start = start
    }
}

/// A task you ticked off.
public struct DoneRecord: Codable, Equatable, Sendable {
    public var taskID: UUID
    public var title: String
    public var at: Date
    public init(taskID: UUID, title: String, at: Date) { self.taskID = taskID; self.title = title; self.at = at }
}

/// What happened lately, kept on the Mac for the stuck check (how long runs usually take) and the recap.
public struct ActivityLog: Codable, Equatable, Sendable {
    public var runs: [RunRecord] = []
    public var done: [DoneRecord] = []
    public init() {}

    public static let keepDays = 14

    public func open(_ task: UUID) -> RunRecord? { runs.last { $0.taskID == task && $0.end == nil } }

    /// A task started working. Already running: nothing changes, so the run keeps its start.
    public mutating func begin(task: UUID, title: String, bundleID: String, appName: String, at: Date) {
        guard open(task) == nil else { return }
        runs.append(RunRecord(taskID: task, title: title, bundleID: bundleID, appName: appName, start: at))
    }

    /// A task stopped working. Returns the run that ended, if one was open.
    @discardableResult
    public mutating func end(task: UUID, at: Date, outcome: WindowState) -> RunRecord? {
        guard let i = runs.lastIndex(where: { $0.taskID == task && $0.end == nil }) else { return nil }
        runs[i].end = max(at, runs[i].start)
        runs[i].outcome = outcome
        return runs[i]
    }

    public mutating func markStuck(_ task: UUID) {
        if let i = runs.lastIndex(where: { $0.taskID == task && $0.end == nil }) { runs[i].stuck = true }
    }

    /// A task removed without finishing: its open run goes, it says nothing about how long runs take.
    public mutating func drop(_ task: UUID) { runs.removeAll { $0.taskID == task && $0.end == nil } }

    public mutating func noteDone(task: UUID, title: String, at: Date) {
        if let i = runs.lastIndex(where: { $0.taskID == task && $0.end == nil }) { runs[i].end = at; runs[i].outcome = .finished }
        done.append(DoneRecord(taskID: task, title: title, at: at))
    }

    /// Recent run lengths for one app, stuck runs left out, newest last.
    public func durations(bundleID: String, limit: Int = 30) -> [TimeInterval] {
        runs.filter { $0.bundleID == bundleID && !$0.stuck && $0.end != nil }
            .suffix(limit)
            .map { $0.end!.timeIntervalSince($0.start) }
    }

    /// After a relaunch, runs left open can't be timed (Baton wasn't watching when they ended): they go.
    /// Anything older than two weeks goes too.
    public mutating func tidy(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
        runs.removeAll { $0.end == nil || $0.start < cutoff }
        done.removeAll { $0.at < cutoff }
    }
}

/// Saves the activity log as JSON next to tasks.json.
public struct ActivityFile: Sendable {
    public let url: URL
    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Baton", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("activity.json")
    }
    public func load() -> ActivityLog {
        guard let d = try? Data(contentsOf: url), let log = try? JSONDecoder().decode(ActivityLog.self, from: d) else { return ActivityLog() }
        return log
    }
    public func save(_ log: ActivityLog) {
        guard let d = try? JSONEncoder().encode(log) else { return }
        try? d.write(to: url, options: .atomic)
    }
}

/// The end-of-day card: what finished, what still runs, what waits on you, how long each AI worked,
/// and the three things to pick up tomorrow. Plain local data.
public struct Recap: Equatable, Sendable {
    /// A task as it stands now.
    public struct Item: Equatable, Sendable, Identifiable {
        public enum Kind: Int, Sendable, Comparable {
            case needsYou, ready, stuck, idle, running
            public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
        }
        public let id: UUID
        public let title: String
        public let appName: String
        public let bundleID: String
        public let kind: Kind
        /// When it last changed.
        public let since: Date
        /// The task's next action, if Baton knows one.
        public let next: String?
        public init(id: UUID, title: String, appName: String, bundleID: String, kind: Kind, since: Date, next: String?) {
            self.id = id; self.title = title; self.appName = appName; self.bundleID = bundleID
            self.kind = kind; self.since = since; self.next = next
        }
    }

    public struct AppTime: Equatable, Sendable {
        public let appName: String
        public let bundleID: String
        public let seconds: TimeInterval
    }

    public let date: Date
    /// Tasks an AI finished a run on today, or that you ticked off, newest first.
    public let finished: [String]
    public let running: [Item]
    public let waiting: [Item]
    /// How long each AI worked today, most first.
    public let appTime: [AppTime]
    public let tomorrow: [Item]
    /// Written from the numbers; Gemini may replace it with a better line.
    public let headline: String

    public static func make(log: ActivityLog, items: [Item], now: Date, calendar: Calendar = .current) -> Recap {
        let dayStart = calendar.startOfDay(for: now)
        // Finished today: AI runs that ended in a result (not stuck, not cut short) and tasks you ticked off.
        var finished: [(String, Date)] = []
        for r in log.runs where r.end.map({ $0 >= dayStart && $0 <= now }) ?? false
            && (r.outcome == .finished || r.outcome == .needsYou || r.outcome == .idle) {
            finished.append((r.title, r.end!))
        }
        for d in log.done where d.at >= dayStart && d.at <= now { finished.append((d.title, d.at)) }
        var seen = Set<String>()
        let finishedTitles = finished.sorted { $0.1 > $1.1 }.map(\.0).filter { seen.insert($0).inserted }

        let running = items.filter { $0.kind == .running || $0.kind == .stuck }.sorted { $0.since < $1.since }
        let waiting = items.filter { $0.kind == .needsYou || $0.kind == .ready }.sorted { ($0.kind, $0.since) < ($1.kind, $1.since) }

        // AI time: each run's overlap with today; runs still open count up to now.
        var time: [String: (String, TimeInterval)] = [:]
        for r in log.runs {
            let s = max(r.start, dayStart), e = min(r.end ?? now, now)
            guard e > s else { continue }
            time[r.bundleID, default: (r.appName, 0)].1 += e.timeIntervalSince(s)
        }
        let appTime = time.map { AppTime(appName: $0.value.0, bundleID: $0.key, seconds: $0.value.1) }
            .filter { $0.seconds >= 60 }
            .sorted { ($0.seconds, $1.appName) > ($1.seconds, $0.appName) }

        return Recap(date: now, finished: finishedTitles, running: running, waiting: waiting, appTime: appTime,
                     tomorrow: pickUp(items), headline: template(finished: finishedTitles.count, running: running.count, waiting: waiting.count))
    }

    /// The three to pick up first: what waits on you, then what looks stuck, then your own next steps,
    /// oldest first within each. A run still going is last: it may well be done by morning.
    public static func pickUp(_ items: [Item], count: Int = 3) -> [Item] {
        Array(items.sorted { a, b in
            if a.kind != b.kind { return a.kind < b.kind }
            if (a.next != nil) != (b.next != nil) { return a.next != nil }
            return a.since < b.since
        }.prefix(count))
    }

    /// Two or three words.
    public static func template(finished: Int, running: Int, waiting: Int) -> String {
        if finished == 0 && running == 0 && waiting == 0 { return "Quiet day" }
        if waiting == 1 { return "One waits on you" }
        if waiting > 1 { return "\(waiting) wait on you" }
        if running > 0 { return "Still running" }
        return "All wrapped up"
    }

    /// The numbers under the headline: "5 finished · 2 running · 1 waiting".
    public var counts: String {
        "\(finished.count) finished · \(running.count) running · \(waiting.count) waiting"
    }

    /// Everything on the card as plain text, for Copy.
    public func text(headline: String? = nil, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.setLocalizedDateFormatFromTemplate("EEEE d MMM")
        var out = ["\(headline ?? self.headline) — \(f.string(from: date))", counts]
        if !finished.isEmpty { out += ["", "Finished"] + finished.map { "- \($0)" } }
        if !waiting.isEmpty { out += ["", "Waiting on you"] + waiting.map { "- \($0.title) (\($0.appName))" } }
        if !running.isEmpty { out += ["", "Still running"] + running.map { "- \($0.title) (\($0.appName)\($0.kind == .stuck ? ", looks stuck" : ""))" } }
        if !appTime.isEmpty { out += ["", "AI time"] + appTime.map { "- \($0.appName): \(Stuck.duration($0.seconds))" } }
        if !tomorrow.isEmpty {
            out += ["", "Tomorrow"] + tomorrow.enumerated().map { i, t in "\(i + 1). \(t.title)\(t.next.map { " — \($0)" } ?? "")" }
        }
        return out.joined(separator: "\n")
    }

    // MARK: Headline from Gemini

    /// Only task names and counts go out, no conversation text.
    public func headlinePrompt() -> String {
        func names(_ xs: [String]) -> String { xs.prefix(8).map { Redact.clean($0) }.joined(separator: "; ") }
        return """
        Write a headline for someone's end-of-day recap of work they ran through AI assistants.
        Finished today (\(finished.count)): \(names(finished))
        Still running (\(running.count)): \(names(running.map(\.title)))
        Waiting on them (\(waiting.count)): \(names(waiting.map(\.title)))
        Rules: 2 to 5 words, calm and plain, sentence case, no emoji, no exclamation mark, no quotes, no final period.
        Answer as JSON: {"headline": "..."}
        """
    }

    /// The headline from Gemini's JSON answer, or nil when it isn't one short line.
    public static func parseHeadline(_ json: String?) -> String? {
        guard let json, let d = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              var h = obj["headline"] as? String else { return nil }
        h = h.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\".!")))
        let words = h.split(separator: " ").count
        guard !h.isEmpty, words <= 7, h.count <= 48, !h.contains("\n") else { return nil }
        return h
    }

    /// Whether the scheduled recap should open now: past today's time (minutes after midnight), within
    /// three hours of it, and not shown yet today.
    public static func due(now: Date, atMinutes: Int, lastShown: Date?, calendar: Calendar = .current) -> Bool {
        let dayStart = calendar.startOfDay(for: now)
        guard let at = calendar.date(byAdding: .minute, value: atMinutes, to: dayStart) else { return false }
        guard now >= at, now < at.addingTimeInterval(3 * 3600) else { return false }
        if let lastShown, calendar.isDate(lastShown, inSameDayAs: now) { return false }
        return true
    }
}
