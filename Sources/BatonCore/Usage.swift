import Foundation

/// One usage limit: how much is used and when it resets.
public struct Limit: Codable, Sendable, Equatable {
    public var percent: Double
    public var resetsAt: Date?
    public init(percent: Double, resetsAt: Date? = nil) { self.percent = Self.sane(percent); self.resetsAt = resetsAt }

    /// Percents come from other apps' logs and windows and are shown as `Int(percent)`, which traps on NaN,
    /// infinity or anything past Int.max: those read as 0, and the rest is kept to 0...1000.
    static func sane(_ p: Double) -> Double { p.isFinite ? min(max(p, 0), 1000) : 0 }

    enum CodingKeys: String, CodingKey { case percent, resetsAt }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(percent: try c.decode(Double.self, forKey: .percent), resetsAt: try c.decodeIfPresent(Date.self, forKey: .resetsAt))
    }
}

/// An AI app's limits as last seen: the 5-hour window, the week, or (Cursor) one plan allowance.
public struct AppUsage: Codable, Sendable, Equatable {
    public var five: Limit?
    public var week: Limit?
    public var plan: Limit?
    /// When each was last read, so the notch can say how fresh it is.
    public var fiveSeen: Date?
    public var weekSeen: Date?
    public var planSeen: Date?
    public init() {}

    /// Adds a newer reading; limits it doesn't mention keep their last value.
    public mutating func merge(_ r: AppUsage) {
        if let v = r.five { five = v; fiveSeen = r.fiveSeen ?? Date() }
        if let v = r.week { week = v; weekSeen = r.weekSeen ?? Date() }
        if let v = r.plan { plan = v; planSeen = r.planSeen ?? Date() }
    }

    /// A limit whose reset time has passed is back at 0 until the app says otherwise.
    public func current(at now: Date = Date()) -> AppUsage {
        var u = self
        if let r = u.five?.resetsAt, r <= now { u.five = Limit(percent: 0, resetsAt: nil) }
        if let r = u.week?.resetsAt, r <= now { u.week = Limit(percent: 0, resetsAt: nil) }
        if let r = u.plan?.resetsAt, r <= now { u.plan = Limit(percent: 0, resetsAt: nil) }
        return u
    }
}

public enum UsageReader {
    // MARK: Codex: its own session log

    /// Codex writes its limits into each session log ("rate_limits": primary = 5 hours, secondary = week).
    /// Reads the newest log's last mention.
    public static func codex(sessions: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions"),
                             now: Date = Date()) -> AppUsage? {
        // A session that just started hasn't logged its limits yet: fall back to the next newest log.
        for file in recentLogs(in: sessions, now: now).prefix(8) {
            guard let tail = readTail(file, bytes: 256 * 1024), let u = codex(fromLog: tail, seen: (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) else { continue }
            return u
        }
        return nil
    }

    public static func codex(fromLog text: String, seen: Date? = nil) -> AppUsage? {
        guard let r = text.range(of: "\"rate_limits\":", options: .backwards),
              let obj = jsonObject(startingAt: text[r.upperBound...]),
              let dict = try? JSONSerialization.jsonObject(with: Data(obj.utf8)) as? [String: Any] else { return nil }
        var u = AppUsage()
        for key in ["primary", "secondary"] {
            guard let w = dict[key] as? [String: Any], let pct = number(w["used_percent"]) else { continue }
            let minutes = number(w["window_minutes"]) ?? (key == "primary" ? 300 : 10080)
            let reset = number(w["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            let limit = Limit(percent: pct, resetsAt: reset)
            if minutes <= 24 * 60 { u.five = limit; u.fiveSeen = seen } else { u.week = limit; u.weekSeen = seen }
        }
        return u.five == nil && u.week == nil ? nil : u
    }

    /// Session logs from the last few days' folders (sessions/2026/10/10/…), newest first.
    static func recentLogs(in root: URL, now: Date) -> [URL] {
        let fm = FileManager.default
        var found: [(URL, Date)] = []
        for back in 0..<4 {
            let d = Calendar.current.dateComponents([.year, .month, .day], from: now.addingTimeInterval(-Double(back) * 86400))
            let dir = root.appending(path: String(format: "%04d/%02d/%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0))
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where f.pathExtension == "jsonl" {
                found.append((f, (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast))
            }
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    static func readTail(_ url: URL, bytes: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return (try? h.readToEnd()).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The balanced {...} at the start of `s`.
    static func jsonObject(startingAt s: Substring) -> String? {
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { return String(s[start...i]) } }
            i = s.index(after: i)
        }
        return nil
    }

    static func number(_ v: Any?) -> Double? {
        var d: Double?
        if let x = v as? Double { d = x }
        else if let i = v as? Int { d = Double(i) }
        else if let n = v as? NSNumber { d = n.doubleValue }
        else if let s = v as? String { d = Double(s) }
        // "nan" and "inf" parse as numbers, but no limit, window or reset time is one.
        return d.flatMap { $0.isFinite ? $0 : nil }
    }

    // MARK: Claude: its usage button ("Usage: Context 351k / 1M (35%), Weekly · all models: 39%, Resets Tue 10:00 AM")

    /// Claude shows whichever limit is closer: the session (5 hours) or the week. Each read fills in that one.
    public static func claude(label: String, now: Date = Date()) -> AppUsage? {
        var u = AppUsage()
        let reset = resetDate(in: label, now: now)
        if let p = firstNumber(in: label, pattern: #"(\d{1,3})%\s+of\s+session\s+limit"#) {
            u.five = Limit(percent: p, resetsAt: reset); u.fiveSeen = now
        }
        if let p = firstNumber(in: label, pattern: #"Weekly[^:]*:\s*(\d{1,3})%"#) ?? firstNumber(in: label, pattern: #"(\d{1,3})%\s+of\s+weekly\s+limit"#) {
            u.week = Limit(percent: p, resetsAt: reset); u.weekSeen = now
        }
        return u.five == nil && u.week == nil ? nil : u
    }

    /// "Resets in 3 hr 54 min", "Resets in 45 min", "Resets Tue 10:00 AM", "Resets 10:00 AM".
    public static func resetDate(in label: String, now: Date = Date()) -> Date? {
        guard let r = label.range(of: #"Resets\s+[^,]+"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let text = String(label[r]).replacingOccurrences(of: "Resets", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("in ") {
            let h = firstNumber(in: text, pattern: #"(\d+)\s*(?:hr|hour|h)\b"#) ?? 0
            let m = firstNumber(in: text, pattern: #"(\d+)\s*(?:min|minute|m)\b"#) ?? 0
            let d = firstNumber(in: text, pattern: #"(\d+)\s*(?:day|d)\b"#) ?? 0
            return now.addingTimeInterval(d * 86400 + h * 3600 + m * 60)
        }
        // A weekday and/or a clock time.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        var cal = Calendar.current
        cal.locale = f.locale
        for format in ["EEE h:mm a", "EEE h a", "h:mm a", "h a", "EEE HH:mm", "HH:mm"] {
            f.dateFormat = format
            guard let parsed = f.date(from: text) else { continue }
            let hm = cal.dateComponents([.hour, .minute], from: parsed)
            var match = DateComponents(hour: hm.hour, minute: hm.minute)
            if format.hasPrefix("EEE") { match.weekday = cal.component(.weekday, from: parsed) }
            return cal.nextDate(after: now, matching: match, matchingPolicy: .nextTime)
        }
        return nil
    }

    // MARK: Cursor: Settings › Plan & Usage, "Cursor Models" (its own models' allowance)

    /// From the Plan & Usage page: the "Cursor Models" bar ("Cursor Models 47%") and "Usage limits reset on
    /// Oct 24 (14 days left)". Only Cursor Models: the Agents window's "Usage N%" button shows whichever
    /// bucket is fullest (Other Models), so it isn't used.
    public static func cursor(labels: [String], now: Date = Date()) -> AppUsage? {
        guard let p = labels.lazy.compactMap({ firstNumber(in: $0, pattern: #"^Cursor Models (\d{1,3})%$"#) }).first else { return nil }
        var u = AppUsage()
        u.plan = Limit(percent: p, resetsAt: labels.lazy.compactMap { cursorReset(in: $0, now: now) }.first)
        u.planSeen = now
        return u
    }

    /// "Usage limits reset on Oct 24 (14 days left)" → the next Oct 24, at midnight.
    public static func cursorReset(in label: String, now: Date = Date()) -> Date? {
        guard let r = label.range(of: #"reset on ([A-Za-z]{3,9} \d{1,2})"#, options: .regularExpression) else { return nil }
        let text = label[r].replacingOccurrences(of: "reset on ", with: "")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["MMM d", "MMMM d"] {
            f.dateFormat = format
            guard let parsed = f.date(from: text) else { continue }
            let c = Calendar.current.dateComponents([.month, .day], from: parsed)
            return Calendar.current.nextDate(after: now.addingTimeInterval(-86400), matching: DateComponents(month: c.month, day: c.day, hour: 0, minute: 0), matchingPolicy: .nextTime)
        }
        return nil
    }

    /// The usage labels in a captured window: Claude's "Usage: …" button; on Cursor's Plan & Usage page the
    /// "Cursor Models" bar (as "Cursor Models 47%") and the reset line.
    public static func labels(in root: AXNode) -> [String] {
        var out: [String] = []
        var stack = [root]
        while let n = stack.popLast() {
            if n.role == "AXButton" || n.role == "AXPopUpButton", let d = n.desc ?? n.title, d.hasPrefix("Usage:") { out.append(d) }
            // The value is the app's: "nan" or "1e300" would trap in Int().
            if n.role == "AXProgressIndicator", n.desc == "Cursor Models", let v = n.value, let p = Double(v), p.isFinite, abs(p) < 1e6 {
                out.append("Cursor Models \(Int(p.rounded()))%")
            }
            if n.role == "AXStaticText", let v = n.value, v.hasPrefix("Usage limits reset on") { out.append(v) }
            stack.append(contentsOf: n.kids)
        }
        return out
    }

    static func firstNumber(in text: String, pattern: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return Double(text[r])
    }
}

/// Codex's limits, read the cheap way every 30 s: a log that hasn't changed since the last read isn't opened
/// again, and one that grew is read only from where the last read stopped (the logs run to megabytes; the old
/// way read the last 256 KB of the newest one each time). Same answer as `UsageReader.codex()`, except that
/// a mention cut off mid-line is never taken for the last one.
public final class CodexUsageLog: @unchecked Sendable {
    private struct Seen {
        var size: UInt64
        var modified: Date?
        /// Read up to here: the end of the last whole line.
        var offset: UInt64
        var usage: AppUsage?
    }
    private let lock = NSLock()
    private var seen: [URL: Seen] = [:]
    private let sessions: URL
    /// Bytes read by the last `read()`, for tests and benchmarks.
    public private(set) var lastBytesRead = 0

    public init(sessions: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions")) {
        self.sessions = sessions
    }

    public func read(now: Date = Date()) -> AppUsage? {
        lock.lock(); defer { lock.unlock() }
        lastBytesRead = 0
        var keep: [URL: Seen] = [:]
        defer { seen = keep }
        // A session that just started hasn't logged its limits yet: fall back to the next newest log.
        for file in UsageReader.recentLogs(in: sessions, now: now).prefix(8) {
            let v = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = UInt64(v?.fileSize ?? 0), modified = v?.contentModificationDate
            var s: Seen
            if let old = seen[file], old.size == size, old.modified == modified {
                s = old
            } else if let old = seen[file], size >= old.offset, size - old.offset <= Self.window {
                // Grew: only what was added since.
                s = old
                let (text, whole) = lines(file, from: old.offset, to: size)
                if let u = UsageReader.codex(fromLog: text, seen: modified) { s.usage = u }
                s.offset = old.offset + whole
            } else {
                // New, replaced, or grown by more than one read takes: its end, as before.
                let from = size > Self.window ? size - Self.window : 0
                let (text, whole) = lines(file, from: from, to: size)
                s = Seen(size: size, modified: modified, offset: from + whole,
                         usage: UsageReader.codex(fromLog: text, seen: modified))
            }
            s.size = size
            s.modified = modified
            keep[file] = s
            if var u = s.usage {
                // Stamped with the log's time, as a full read would have.
                if u.five != nil { u.fiveSeen = modified }
                if u.week != nil { u.weekSeen = modified }
                return u
            }
        }
        return nil
    }

    static let window: UInt64 = 256 * 1024

    /// The whole lines in [from, to): their text, and how many bytes they take (a line still being written
    /// is left for the next read).
    private func lines(_ url: URL, from: UInt64, to: UInt64) -> (String, UInt64) {
        guard to > from, let h = try? FileHandle(forReadingFrom: url) else { return ("", 0) }
        defer { try? h.close() }
        try? h.seek(toOffset: from)
        guard let data = try? h.read(upToCount: Int(to - from)) else { return ("", 0) }
        lastBytesRead += data.count
        guard let nl = data.lastIndex(of: 0x0A) else { return ("", 0) }
        let whole = data[data.startIndex...nl]
        return (String(decoding: whole, as: UTF8.self), UInt64(whole.count))
    }
}
