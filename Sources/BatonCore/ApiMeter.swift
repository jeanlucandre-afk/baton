import Foundation

/// Counts every request Baton sends to Jev and Gemini: per hour for poll.log, and a small total per day
/// kept in spend.json (last 31 days). Shown nowhere; it's there to see what Baton costs.
public final class ApiMeter: @unchecked Sendable {
    public static let shared = ApiMeter(file: Profiles.fileURL.deletingLastPathComponent().appending(path: "spend.json"))

    public struct Day: Codable, Equatable, Sendable {
        public var jevCalls = 0
        public var jevTokens = 0
        public var jevCost = 0.0
        public var geminiCalls = 0
        public var geminiTokens = 0
        /// Requests that came back with an error (they may still count against a quota).
        public var failed = 0
        public init() {}
    }

    public struct Hour: Equatable, Sendable {
        public var byKind: [String: Int] = [:]   // "jev classify", "jev choose", "gemini"
        public var total = Day()
        public var isEmpty: Bool { total == Day() }
    }

    private let lock = NSLock()
    private let file: URL?
    private var days: [String: Day] = [:]
    private var hour = Hour()
    private var dirty = false
    private let clock: @Sendable () -> Date

    public init(file: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        clock = now
        if let file, let saved = SavedFile.load([String: Day].self, from: file) {
            days = saved
        }
    }

    /// One Jev request: `kind` is "classify" or "choose"; `tokens` its input tokens (Jev bills input only).
    public func jev(_ kind: String, tokens: Int, failed: Bool = false) {
        add("jev \(kind)") { d in
            d.jevCalls += 1
            d.jevTokens += tokens
            d.jevCost += Double(tokens) * 0.042 / 1_000_000
            if failed { d.failed += 1 }
        }
    }

    /// One Gemini request.
    public func gemini(tokens: Int, failed: Bool = false) {
        add("gemini") { d in
            d.geminiCalls += 1
            d.geminiTokens += tokens
            if failed { d.failed += 1 }
        }
    }

    private func add(_ kind: String, _ change: (inout Day) -> Void) {
        let key = Self.dayKey(clock())
        lock.withLock {
            change(&days[key, default: Day()])
            change(&hour.total)
            hour.byKind[kind, default: 0] += 1
            dirty = true
        }
    }

    public func today() -> Day { lock.withLock { days[Self.dayKey(clock())] ?? Day() } }

    /// What was sent since the last call, then starts counting again. nil when nothing was sent.
    public func takeHour() -> Hour? {
        lock.withLock {
            defer { hour = Hour() }
            return hour.isEmpty ? nil : hour
        }
    }

    /// The poll.log line for an hour: "api last hour: jev 12 (classify 10, choose 2) 31k tok $0.0013 · gemini 3 2.1k tok · today: …"
    public static func line(_ h: Hour, today: Day) -> String {
        func k(_ n: Int) -> String { n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }
        let kinds = h.byKind.filter { $0.key.hasPrefix("jev ") }.sorted { $0.key < $1.key }
            .map { "\($0.key.dropFirst(4)) \($0.value)" }.joined(separator: ", ")
        var s = "api last hour: jev \(h.total.jevCalls)"
        if !kinds.isEmpty { s += " (\(kinds))" }
        s += " \(k(h.total.jevTokens)) tok $" + String(format: "%.4f", h.total.jevCost)
        s += " · gemini \(h.total.geminiCalls) \(k(h.total.geminiTokens)) tok"
        if h.total.failed > 0 { s += " · \(h.total.failed) failed" }
        s += " · today: jev \(today.jevCalls) $" + String(format: "%.4f", today.jevCost) + ", gemini \(today.geminiCalls) \(k(today.geminiTokens)) tok"
        return s
    }

    /// Writes the daily totals if they changed (keeps the last 31 days).
    public func save() {
        guard let file else { return }
        let data: Data? = lock.withLock {
            guard dirty else { return nil }
            dirty = false
            let keep = days.keys.sorted().suffix(31)
            days = days.filter { keep.contains($0.key) }
            return try? JSONEncoder().encode(days)
        }
        guard let data else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
