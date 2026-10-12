@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import BatonCore

/// Codex's limits read from where the last read stopped give what reading the log's end every time gave.
@Suite struct CodexUsageLogTests {
    let now = Date()

    private func limits(_ five: Int, _ week: Int) -> String {
        #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\#(five).0,"window_minutes":300,"resets_at":1791610078},"secondary":{"used_percent":\#(week).0,"window_minutes":10080,"resets_at":1791968918}}}}"#
            + "\n"
    }
    private let chatter = #"{"type":"response_item","payload":{"type":"message","content":"working on it"}}"# + "\n"

    private func sessions() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "codex-\(UUID().uuidString)")
        let d = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let dir = root.appending(path: String(format: "%04d/%02d/%02d", d.year!, d.month!, d.day!))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (root, dir)
    }

    private func append(_ text: String, to url: URL, at time: Date) throws {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
        try h.close()
        try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: url.path)
    }

    @Test func readsOnlyWhatsNewAndAgreesWithAFullRead() throws {
        let (root, dir) = try sessions()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = CodexUsageLog(sessions: root)
        let a = dir.appending(path: "rollout-a.jsonl")
        try append(String(repeating: chatter, count: 2000) + limits(10, 30), to: a, at: now.addingTimeInterval(-60))

        let first = log.read(now: now)
        #expect(first?.five?.percent == 10 && first?.week?.percent == 30)
        #expect(first == UsageReader.codex(sessions: root, now: now))

        // Nothing changed: the log isn't opened.
        #expect(log.read(now: now) == first)
        #expect(log.lastBytesRead == 0)

        // Chatter without limits: only the new lines are read, the limits stand (stamped with the new time).
        try append(chatter, to: a, at: now.addingTimeInterval(-50))
        let second = log.read(now: now)
        #expect(log.lastBytesRead == chatter.utf8.count)
        #expect(second == UsageReader.codex(sessions: root, now: now))

        // New limits.
        try append(chatter + limits(12, 31), to: a, at: now.addingTimeInterval(-40))
        let third = log.read(now: now)
        #expect(third?.five?.percent == 12 && third?.week?.percent == 31)
        #expect(third == UsageReader.codex(sessions: root, now: now))
    }

    @Test func aLineStillBeingWrittenWaits() throws {
        let (root, dir) = try sessions()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = CodexUsageLog(sessions: root)
        let a = dir.appending(path: "rollout-a.jsonl")
        try append(limits(10, 30), to: a, at: now.addingTimeInterval(-60))
        _ = log.read(now: now)
        let line = limits(55, 60)
        let cut = line.index(line.startIndex, offsetBy: line.count / 2)
        try append(String(line[..<cut]), to: a, at: now.addingTimeInterval(-50))
        #expect(log.read(now: now)?.five?.percent == 10)      // the half line isn't taken for the last mention
        try append(String(line[cut...]), to: a, at: now.addingTimeInterval(-40))
        #expect(log.read(now: now)?.five?.percent == 55)
    }

    @Test func aSessionWithoutLimitsYetFallsBackToTheLastOne() throws {
        let (root, dir) = try sessions()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = CodexUsageLog(sessions: root)
        try append(limits(20, 40), to: dir.appending(path: "rollout-old.jsonl"), at: now.addingTimeInterval(-600))
        try append(chatter, to: dir.appending(path: "rollout-new.jsonl"), at: now.addingTimeInterval(-10))
        let u = log.read(now: now)
        #expect(u?.five?.percent == 20)
        #expect(u == UsageReader.codex(sessions: root, now: now))
        // The new session logs its limits: it wins.
        try append(limits(21, 41), to: dir.appending(path: "rollout-new.jsonl"), at: now.addingTimeInterval(-5))
        #expect(log.read(now: now)?.five?.percent == 21)
    }
}

/// The engine's timer stops while it has nothing to read, and starts again as soon as it does.
@Suite struct IdleEngineTests {
    @Test func sleepsWithNoWindowsOrWhilePaused() async throws {
        let engine = DetectionEngine(classifier: nil, snapshot: { _ in Snapshot(title: "", buttons: [], tail: "", nodes: 1, millis: 1) })
        engine.start()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!engine.tickingForTesting)            // nothing watched: no wakeups

        let me = ProcessInfo.processInfo.processIdentifier
        let id = UUID()
        engine.watch(id, window: AXWindow(element: AXUIElementCreateApplication(me), pid: me, appName: "Test", bundleID: "test", title: "Doc"))
        #expect(engine.tickingForTesting)

        engine.setPaused(true)
        try await Task.sleep(for: .milliseconds(1300))
        #expect(!engine.tickingForTesting)            // away: no wakeups
        engine.setPaused(false)
        #expect(engine.tickingForTesting)

        engine.unwatch(id)
        try await Task.sleep(for: .milliseconds(1300))
        #expect(!engine.tickingForTesting)
    }
}

/// What Baton sends to Jev and Gemini is counted per hour (poll.log) and per day (spend.json).
@Suite struct ApiMeterTests {
    @Test func countsPerHourAndKeepsTheDay() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "spend-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let clock = TestClock()
        let m = ApiMeter(file: file, now: { clock.now() })
        #expect(m.takeHour() == nil)
        m.jev("classify", tokens: 1000)
        m.jev("classify", tokens: 500)
        m.jev("choose", tokens: 200, failed: true)
        m.gemini(tokens: 1200)
        let h = try #require(m.takeHour())
        #expect(h.total.jevCalls == 3 && h.total.jevTokens == 1700 && h.total.geminiCalls == 1 && h.total.failed == 1)
        #expect(h.byKind == ["jev classify": 2, "jev choose": 1, "gemini": 1])
        #expect(abs(h.total.jevCost - 1700 * 0.042 / 1_000_000) < 1e-12)
        #expect(m.takeHour() == nil)                     // the hour starts over
        let line = ApiMeter.line(h, today: m.today())
        #expect(line.contains("jev 3 (choose 1, classify 2)") && line.contains("gemini 1 1.2k tok") && line.contains("1 failed"))
        m.save()
        // The day's totals survive a relaunch; the next day starts at zero.
        #expect(ApiMeter(file: file, now: { clock.now() }).today() == m.today())
        clock.advance(86400)
        #expect(m.today() == ApiMeter.Day())
    }
}
