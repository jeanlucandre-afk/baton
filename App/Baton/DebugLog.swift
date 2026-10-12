import AppKit

/// What each sidebar poll read and decided, in ~/Library/Application Support/Baton/poll.log. For "Baton
/// didn't notice" bugs: shows what the app said and why a status did or didn't change. Only changes are
/// written (see `changed`), off the main thread; past 1 MB the log moves to poll.log.1 and starts over.
enum DebugLog {
    nonisolated static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Baton/poll.log")
    nonisolated private static let queue = DispatchQueue(label: "dev.baton.pollog", qos: .background)
    nonisolated private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    /// The last line written per key (only touched on `queue`).
    nonisolated(unsafe) private static var last: [String: String] = [:]

    nonisolated static func log(_ line: String) {
        let now = Date()
        queue.async { write(line, at: now) }
    }

    /// Logs `line` only when it differs from the last line logged under `key`, so a state read every poll
    /// is written once, when it changes.
    nonisolated static func changed(_ key: String, _ line: String) {
        let now = Date()
        queue.async {
            guard last[key] != line else { return }
            last[key] = line
            write(line, at: now)
        }
    }

    nonisolated private static func write(_ line: String, at now: Date) {
        let text = "\(stamp.string(from: now)) \(line)\n"
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(text.utf8))
    }

    static var front: String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "-" }
}
