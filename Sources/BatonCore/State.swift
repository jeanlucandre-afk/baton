import Foundation

public enum WindowState: String, Sendable, Codable, CaseIterable {
    case unknown
    case working = "ai_working"
    case needsYou = "needs_you"
    case finished = "ai_finished"
    case idle

    /// Higher wins when combining a task's windows: anything that needs you beats everything else.
    var priority: Int {
        switch self {
        case .needsYou: 4
        case .working: 3
        case .finished: 2
        case .idle: 1
        case .unknown: 0
        }
    }

    public static func combine(_ states: [WindowState]) -> WindowState {
        states.max(by: { $0.priority < $1.priority }) ?? .unknown
    }
}

/// Decides when a Jev answer is trustworthy enough to change a window's state.
public struct Hysteresis: Sendable {
    public enum Decision: Equatable, Sendable {
        case keep
        case flip(WindowState)
        case recheck(after: TimeInterval, candidate: WindowState?)
    }

    public var finishThreshold = 0.85
    public var needsYouThreshold = 0.6
    public var candidateThreshold = 0.5

    public init() {}

    public func decide(current: WindowState, candidate: WindowState?, answer: JevAnswer) -> Decision {
        let s = answer.status
        if s == current { return .keep }
        if s == .needsYou && answer.confidence >= needsYouThreshold { return .flip(s) }
        if answer.confidence >= finishThreshold { return .flip(s) }
        if candidate == s { return .flip(s) }   // two answers in a row agree
        if answer.confidence >= candidateThreshold { return .recheck(after: 3, candidate: s) }
        return .recheck(after: 5, candidate: nil)  // unsure: look again soon instead of dropping it
    }
}

/// Local signals that can only ever say "still working"; finished and needs-you always come from Jev.
public enum Rules {
    /// Words on the button that stops a reply. While it's there, the AI is working.
    static let stopButtons: Set<String> = ["stop", "stop generation", "stop generating", "stop response", "stop responding",
                                           "stop streaming", "stop answering", "cancel generation"]
    static let statusPhrases = ["is working", "getting it done", "thinking", "generating", "working on it", "running command", "searching the web", "is typing"]
    static let replyActions = ["copy", "regenerate", "retry", "read aloud", "good response", "bad response", "edit", "share", "copy markdown", "try again"]

    public static func working(_ s: Snapshot, changedTicks: Int) -> String? {
        if let b = s.buttons.first(where: { stopButtons.contains($0.lowercased()) }) { return "button \"\(b)\"" }
        if s.tail.suffix(400).lowercased().contains("esc to interrupt") { return "\"esc to interrupt\"" }
        let last = s.tail.suffix(60).lowercased()
        if let p = statusPhrases.first(where: { last.contains($0) }) { return "\"\(p)\"" }
        if changedTicks >= 3 { return "text changing for \(changedTicks)s" }
        return nil
    }

    /// True when the window's text changed so much it must be a different conversation, not new output in the same one.
    public static func isContextSwitch(old: String, new: String) -> Bool {
        func words(_ s: String) -> Set<String> {
            Set(s.suffix(800).lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 3 })
        }
        let a = words(old), b = words(new)
        guard a.count >= 15, b.count >= 15 else { return false }
        let overlap = Double(a.intersection(b).count) / Double(a.union(b).count)
        return overlap < 0.15
    }

    public static func replyActionsVisible(_ s: Snapshot) -> Bool {
        s.buttons.contains { b in replyActions.contains { b.lowercased().hasPrefix($0) } }
    }
}

/// Strips things that should never leave the Mac before any text is sent out.
public enum Redact {
    private static let patterns: [NSRegularExpression] = [
        #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,              // emails
        #"\b(sk|pk|rk|ghp|gho|xox[abp])[-_][A-Za-z0-9_-]{12,}"#,  // common API key prefixes
        #"\bAKIA[0-9A-Z]{16}\b"#,                                  // AWS access keys
        #"\b[A-Za-z0-9_\-]{32,}\b"#,                               // long opaque tokens
        #"\+?\d[\d \-()]{8,}\d"#                                   // phone numbers
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    public static func clean(_ s: String) -> String {
        var out = s
        for re in patterns {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "[redacted]")
        }
        return out
    }
}
