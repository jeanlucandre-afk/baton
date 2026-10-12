import Foundation

/// Notices an AI that says it's working but probably isn't getting anywhere. Built only from what Baton
/// already knows (when the run started, when its window's text last changed, the end of that text):
/// no Accessibility read and no API call of its own.
public enum Stuck {
    public enum Reason: String, Equatable, Sendable {
        /// The window's text hasn't changed for a long time while the app still says working.
        case frozen
        /// Working far longer than this app's runs usually take.
        case longRun
        /// An error is on screen and nothing has moved since.
        case error
    }

    public struct Verdict: Equatable, Sendable {
        public let reason: Reason
        /// How long the run has been working.
        public let working: TimeInterval
        /// How long its screen has stood still (nil when Baton can't see the screen, e.g. a chat followed by sidebar).
        public let quiet: TimeInterval?
        public init(reason: Reason, working: TimeInterval, quiet: TimeInterval?) {
            self.reason = reason; self.working = working; self.quiet = quiet
        }

        /// Why, in a few words, for the row's tooltip and the ping card.
        public var why: String {
            switch reason {
            case .frozen: "No change on screen for \(Stuck.duration(quiet ?? working))"
            case .longRun: "Working \(Stuck.duration(working)), longer than usual"
            case .error: "An error is on screen, still says working"
            }
        }

        /// The ping line: "Codex looks stuck · 12 min".
        public func ping(app: String) -> String { "\(app) looks stuck · \(Stuck.duration(working))" }
    }

    /// What the detection engine last saw in a watched window.
    public struct Screen: Equatable, Sendable {
        public let lastChange: Date
        public let tail: String
        public init(lastChange: Date, tail: String) { self.lastChange = lastChange; self.tail = tail }
    }

    /// An error with no movement after it counts as stuck this soon, whatever the setting.
    public static let errorQuiet: TimeInterval = 120
    /// Runs needed before an app's own history sets the long-run limit.
    public static let minSamples = 5

    /// How long this app's runs usually take: the 90th percentile of recent runs, once there are enough.
    public static func typical(_ durations: [TimeInterval]) -> TimeInterval? {
        let d = durations.filter { $0 > 0 }.sorted()
        guard d.count >= minSamples else { return nil }
        let i = Int((Double(d.count - 1) * 0.9).rounded())
        return d[i]
    }

    /// Working longer than this is a long run: twice what's usual for the app, never under the setting.
    /// With no history yet, twice the setting (a Codex task can honestly take half an hour).
    public static func limit(minutes: Double, typical: TimeInterval?) -> TimeInterval {
        let setting = minutes * 60
        guard let typical else { return 2 * setting }
        return max(setting, 2 * typical)
    }

    /// `minutes`: the setting, 0 = off. `screen`: nil when the screen isn't watched.
    public static func check(start: Date, screen: Screen?, now: Date, minutes: Double, typical: TimeInterval?) -> Verdict? {
        guard minutes > 0 else { return nil }
        let working = now.timeIntervalSince(start)
        guard working > 0 else { return nil }
        if let screen {
            // A change before the run started says nothing about this run.
            let quiet = now.timeIntervalSince(max(screen.lastChange, start))
            if quiet >= errorQuiet && showsError(screen.tail) { return Verdict(reason: .error, working: working, quiet: quiet) }
            if quiet >= minutes * 60 { return Verdict(reason: .frozen, working: working, quiet: quiet) }
            if working >= limit(minutes: minutes, typical: typical) { return Verdict(reason: .longRun, working: working, quiet: quiet) }
            return nil
        }
        if working >= limit(minutes: minutes, typical: typical) { return Verdict(reason: .longRun, working: working, quiet: nil) }
        return nil
    }

    static let errorPhrases = [
        "something went wrong", "an error occurred", "error occurred", "network error", "connection error",
        "connection lost", "lost connection", "request failed", "rate limit", "try again later", "please try again",
        "internal server error", "timed out", "overloaded", "unable to connect", "failed to respond", "stream error"
    ]

    /// The end of the window's text shows an error.
    public static func showsError(_ tail: String) -> Bool {
        let end = tail.suffix(300).lowercased()
        return errorPhrases.contains { end.contains($0) }
    }

    /// "45 s", "12 min", "1 h 5 min".
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h) h" : "\(h) h \(r) min"
    }

    /// One ping per run: a run is its task and when it started working.
    public static func runKey(_ task: UUID, start: Date) -> String { "\(task.uuidString)|\(Int(start.timeIntervalSince1970))" }
}
