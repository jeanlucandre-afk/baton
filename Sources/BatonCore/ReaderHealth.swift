import Foundation

/// Notices when Baton stops being able to read an app's sidebar: an app update changed it, or the
/// sidebar is hidden. A blind reader must never be taken as "every chat went quiet", which would ping
/// "done" for chats that are still running and then go silent.
public struct ReaderHealth: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable { case unknown, reading, blind }

    public struct App: Codable, Sendable, Equatable {
        /// About how many chats this app usually lists.
        public var usual = 0
        /// Polls in a row with far fewer chats than usual.
        public var misses = 0
        public var verdict = Verdict.unknown
        /// Chats seen while reading worked, to check a repaired profile against.
        public var known: [String] = []
        public var lastCount = 0
        public var since: Date?
        /// Reads in a row that found exactly `lastCount` chats.
        public var steady = 0

        public init() {}

        // Every field may be missing, so files saved by older versions still load.
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            usual = try c.decodeIfPresent(Int.self, forKey: .usual) ?? 0
            misses = try c.decodeIfPresent(Int.self, forKey: .misses) ?? 0
            verdict = try c.decodeIfPresent(Verdict.self, forKey: .verdict) ?? .unknown
            known = try c.decodeIfPresent([String].self, forKey: .known) ?? []
            lastCount = try c.decodeIfPresent(Int.self, forKey: .lastCount) ?? 0
            since = try c.decodeIfPresent(Date.self, forKey: .since)
            steady = try c.decodeIfPresent(Int.self, forKey: .steady) ?? 0
        }
    }

    public private(set) var apps: [String: App] = [:]

    /// Polls in a row before an app counts as blind (2 s apart, so about 6 s).
    public static let missesToBlind = 3
    /// Polls in a row with the same, lower count before that count becomes the new usual (chats archived).
    public static let steadyToRebaseline = 10

    public init() {}

    public func verdict(_ bundleID: String) -> Verdict { apps[bundleID]?.verdict ?? .unknown }
    public func known(_ bundleID: String) -> [String] { apps[bundleID]?.known ?? [] }

    /// The latest read looked normal, so a chat missing from it really went quiet.
    public func trusted(_ bundleID: String) -> Bool {
        guard let a = apps[bundleID] else { return false }
        return a.verdict == .reading && a.misses == 0 && a.lastCount > 0
    }

    /// Records one read of an app's sidebar and returns the verdict. A read counts as a miss when it
    /// finds no chats, or under a third of the usual number.
    @discardableResult
    public mutating func record(_ bundleID: String, rows: [ChatRow], at now: Date = Date()) -> Verdict {
        var a = apps[bundleID] ?? App()
        let n = rows.count
        a.steady = n == a.lastCount ? a.steady + 1 : 1
        a.lastCount = n
        // The same few chats, read after read: most were archived, so that's the new normal.
        if n > 0, a.steady >= Self.steadyToRebaseline, n < a.usual { a.usual = n }
        let floor = max(1, Int((Double(a.usual) * 0.33).rounded(.up)))
        if n >= floor {
            a.misses = 0
            // Follows the real count down slowly (chats get deleted) and up at once.
            a.usual = n >= a.usual ? n : max(n, Int(Double(a.usual) * 0.9))
            // Window controls a broken profile took for chats must never become "known" chats.
            let names = rows.map(\.name).filter { !ProfileBook.isControl($0) }
            a.known = Array((names + a.known.filter { !names.contains($0) }).prefix(40))
            if a.verdict != .reading { a.since = now }
            a.verdict = .reading
        } else {
            a.misses += 1
            if a.misses >= Self.missesToBlind, a.verdict != .blind {
                a.verdict = .blind
                a.since = now
            }
        }
        apps[bundleID] = a
        return a.verdict
    }

    /// After a repair, the next read decides again from scratch, usual count included (known chats are kept).
    public mutating func reset(_ bundleID: String) {
        guard var a = apps[bundleID] else { return }
        a.misses = 0
        a.usual = 0
        a.steady = 0
        a.verdict = .unknown
        apps[bundleID] = a
    }

    // MARK: Saved between launches, so a reader broken by an update is caught right after launch too.

    public static var fileURL: URL { Profiles.fileURL.deletingLastPathComponent().appending(path: "reader-health.json") }

    public static func load() -> ReaderHealth {
        guard let d = try? Data(contentsOf: fileURL), let h = try? JSONDecoder().decode(ReaderHealth.self, from: d) else { return ReaderHealth() }
        return h.relaunched()
    }

    /// A new launch re-checks every app; only what's usual and known carries over, minus any window
    /// controls an earlier version saved as chats.
    func relaunched() -> ReaderHealth {
        var h = self
        for k in h.apps.keys {
            h.apps[k]?.verdict = .unknown
            h.apps[k]?.misses = 0
            h.apps[k]?.known.removeAll(where: ProfileBook.isControl)
        }
        return h
    }

    public func save() { try? JSONEncoder().encode(self).write(to: Self.fileURL, options: .atomic) }
}
