import Foundation

/// Status words Baton learned on its own: when an app shows a word next to a chat that Baton doesn't
/// know ("Awaiting input"), it asks Gemini once what it means and keeps the answer here.
public final class LearnedStatus: @unchecked Sendable {
    public static let shared = LearnedStatus()

    private let lock = NSLock()
    private var words: [String: ChatStatus] = [:]
    private var url: URL?
    private var changes = 0

    public init(url: URL? = LearnedStatus.defaultURL) {
        self.url = url
        if let url, let d = try? Data(contentsOf: url), let w = try? JSONDecoder().decode([String: ChatStatus].self, from: d) {
            // Older versions learned PR badges ("15 · open") as statuses; those are dropped.
            words = w.filter { Self.isWord($0.key) }
        }
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Baton").appending(path: "learned-status.json")
    }

    /// A status is letters, spaces and hyphens only ("Awaiting input", "Pre-flight"). Counts, dots and
    /// symbols ("15 · open") are badges, not statuses.
    public static func isWord(_ w: String) -> Bool {
        let t = w.trimmingCharacters(in: .whitespaces)
        // "New session in baton" is a button, so "New session in" is never a status.
        return t.contains(where: \.isLetter) && t.allSatisfy { $0.isLetter || $0 == " " || $0 == "-" }
            && !ProfileBook.isControl(t + " x")
    }

    public func status(of word: String) -> ChatStatus? {
        lock.lock(); defer { lock.unlock() }
        return words[word.lowercased()]
    }

    public var all: [String: ChatStatus] {
        lock.lock(); defer { lock.unlock() }
        return words
    }

    /// Goes up whenever the learned words change, so readers can cache what they build from them.
    public var version: Int { lock.withLock { changes } }

    public func learn(_ word: String, _ status: ChatStatus) {
        guard Self.isWord(word) else { return }
        lock.lock()
        words[word.lowercased()] = status
        changes += 1
        let snapshot = words
        let url = self.url
        lock.unlock()
        guard let url, let d = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }

    /// Forgets the saved file and starts from these words, kept in memory only. For tests, so they never
    /// read or write the user's learned words.
    public func resetForTesting(_ start: [String: ChatStatus] = [:]) {
        lock.withLock {
            url = nil
            words = start.filter { Self.isWord($0.key) }
            changes += 1
        }
    }
}
