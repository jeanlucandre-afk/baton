import Foundation
import FoundationModels

/// One short line for the ping. Apple's on-device model first (free, private); a plain template if it's
/// unavailable, refuses (e.g. under memory pressure), or echoes its own instructions.
public enum Summarizer {
    public static func template(app: String, status: WindowState, asksYou: Bool) -> String {
        switch status {
        case .needsYou: return "\(app) needs you"
        default: return asksYou ? "\(app) finished and is asking you something" : "\(app) finished"
        }
    }

    public static var onDeviceAvailability: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "available"
        case .unavailable(let reason): return "unavailable (\(reason))"
        @unknown default: return "unknown"
        }
    }

    // No example sentences here: the model copied one verbatim into a real ping during testing.
    static let instructions = """
    You write one status line of at most 12 words about what an AI assistant in a window just produced, or what it needs from the user.
    Begin with the app name. Describe the concrete result using only facts that appear in the provided window text.
    Never write only that it finished. Plain text, no quotes, no emoji.
    """

    public struct Result: Sendable { public let text: String; public let source: String; public let millis: Double }

    public static func summarize(app: String, title: String, tail: String, status: WindowState, asksYou: Bool) async -> Result {
        let fallback = template(app: app, status: status, asksYou: asksYou)
        guard case .available = SystemLanguageModel.default.availability else { return Result(text: fallback, source: "template", millis: 0) }
        let start = Date()
        let session = LanguageModelSession(instructions: instructions)
        let prompt = """
        App: \(app)
        Window: \(title)
        State: \(status == .needsYou ? "waiting for the user" : "finished")
        Window text (newest last):
        \(String(tail.suffix(3000)))
        """
        do {
            let r = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 40))
            let line = r.content.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
            let ms = Date().timeIntervalSince(start) * 1000
            if line.isEmpty || echoesInstructions(line) { return Result(text: fallback, source: "template (rejected summary)", millis: ms) }
            return Result(text: line, source: "on-device", millis: ms)
        } catch {
            return Result(text: fallback, source: "template (on-device unavailable)", millis: Date().timeIntervalSince(start) * 1000)
        }
    }

    /// A short name (2 to 5 words) for what the user is doing in a window, used to suggest tasks.
    /// Falls back to the window title when the on-device model isn't available.
    public static func taskName(app: String, title: String, tail: String) async -> String {
        let fallback: String = {
            let t = title.trimmingCharacters(in: .whitespaces)
            return (t.isEmpty || t == app) ? "Work in \(app)" : String(t.prefix(48))
        }()
        guard case .available = SystemLanguageModel.default.availability, tail.count > 80 else { return fallback }
        let session = LanguageModelSession(instructions: """
        Name the task the user is working on in this window in 2 to 5 words, like a to-do item.
        Use only what the window text shows. Plain text, no quotes, no punctuation at the end.
        """)
        do {
            let r = try await session.respond(to: "App: \(app)\nWindow: \(title)\nWindow text:\n\(String(tail.suffix(2000)))",
                                              options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 16))
            let name = r.content.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\".")))
            return (name.isEmpty || name.count > 60) ? fallback : name
        } catch {
            return fallback
        }
    }

    /// True when the line is mostly words from the instructions rather than from the window.
    static func echoesInstructions(_ line: String) -> Bool {
        let words = { (s: String) in Set(s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count > 3 }) }
        let l = words(line), i = words(instructions)
        guard !l.isEmpty else { return true }
        return Double(l.intersection(i).count) / Double(l.count) > 0.6
    }
}
