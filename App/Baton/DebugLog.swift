import AppKit
import Defaults
import SwiftUI

extension Defaults.Keys {
    /// Settings › General › Debug log. Off for everyone by default (the log holds chat names); on in
    /// Debug builds. Read through `DebugLog.enabled` on any thread.
    static let debugLog = Key<Bool>(DebugLog.enabledKey, default: DebugLog.onByDefault)
}

/// What each sidebar poll read and decided, in ~/Library/Application Support/Baton/poll.log. For "Baton
/// didn't notice" bugs: shows what the app said and why a status did or didn't change. Only changes are
/// written (see `changed`), off the main thread; past 1 MB the log moves to poll.log.1 and starts over.
/// It lists the names of your chats, so it's only written once turned on (Settings › General).
enum DebugLog {
    nonisolated static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Baton/poll.log")
    nonisolated static let enabledKey = "debugLog"
    #if DEBUG
    nonisolated static let onByDefault = true
    #else
    nonisolated static let onByDefault = false
    #endif

    /// Straight from UserDefaults (where the Settings toggle writes it), so any thread can ask cheaply.
    nonisolated static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? onByDefault
    }

    nonisolated private static let queue = DispatchQueue(label: "dev.baton.pollog", qos: .background)
    nonisolated private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    /// The last line written per key (only touched on `queue`).
    nonisolated(unsafe) private static var last: [String: String] = [:]

    /// The line is only built when the log is on: the poll builds several every few seconds.
    nonisolated static func log(_ line: @autoclosure () -> String) {
        guard enabled else { return }
        let text = line()
        let now = Date()
        queue.async { write(text, at: now) }
    }

    /// Logs `line` only when it differs from the last line logged under `key`, so a state read every poll
    /// is written once, when it changes.
    nonisolated static func changed(_ key: String, _ line: @autoclosure () -> String) {
        guard enabled else { return }
        let text = line()
        let now = Date()
        queue.async {
            guard last[key] != text else { return }
            last[key] = text
            write(text, at: now)
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
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(text.utf8))
    }

    static var front: String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "-" }

    /// Shows the log in Finder (the folder, if nothing has been written yet).
    static func reveal() {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let dir = url.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(dir)
        }
    }
}

/// Settings › General: the debug log switch, for bug reports.
struct DebugLogSection: View {
    @Default(.debugLog) private var on

    var body: some View {
        Section {
            Toggle("Write a debug log", isOn: $on)
            Button("Reveal Log in Finder") { DebugLog.reveal() }
        } footer: {
            Text("For bug reports: poll.log records what Baton reads from each app, chat names included, and why a status changed. It stays on this Mac and is capped at about 2 MB.")
                .foregroundStyle(.secondary)
        }
    }
}
