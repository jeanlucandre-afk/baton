import ApplicationServices
import Foundation
import Testing
@testable import BatonCore

// Saved files that don't read, numbers from other apps that can't be shown, and Jev failing for good.

@Suite struct SavedFileTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("baton-saved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func badCopies(_ dir: URL, _ name: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("\(name).bad-") }
    }

    @Test func aCorruptFileIsMovedAsideNotOverwritten() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("activity.json")
        let junk = Data(#"{"runs": [{"taskID": "#.utf8)   // cut short mid-write
        try junk.write(to: url)
        let file = ActivityFile(directory: dir)
        #expect(file.load() == ActivityLog())
        // Gone from where the next save writes, kept byte for byte beside it.
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let copies = try badCopies(dir, "activity.json")
        #expect(copies.count == 1)
        #expect(try Data(contentsOf: dir.appendingPathComponent(copies[0])) == junk)
    }

    @Test func aMissingFileIsJustEmpty() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ActivityFile(directory: dir).load() == ActivityLog())
        #expect(try badCopies(dir, "activity.json").isEmpty)
    }

    @Test func oneUnreadableRunKeepsTheRest() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        // An old run without "stuck", a run with an outcome from a newer build, one with no start, and a null.
        let json = """
        {"runs": [
          {"taskID": "\(id)", "title": "Old", "bundleID": "b", "appName": "A", "start": 100, "end": 200, "outcome": "ai_finished"},
          {"taskID": "\(id)", "title": "Newer", "bundleID": "b", "appName": "A", "start": 300, "outcome": "ai_daydreaming", "stuck": true},
          {"taskID": "\(id)", "title": "Broken"},
          null
        ],
         "done": [{"taskID": "\(id)", "title": "Shipped", "at": 400}, {"title": "no id"}]}
        """
        let url = dir.appendingPathComponent("activity.json")
        try Data(json.utf8).write(to: url)
        let log = ActivityFile(directory: dir).load()
        #expect(log.runs.map(\.title) == ["Old", "Newer"])
        #expect(log.runs[0].stuck == false && log.runs[0].outcome == .finished)
        #expect(log.runs[1].outcome == nil && log.runs[1].stuck)
        #expect(log.done.map(\.title) == ["Shipped"])
        #expect(try badCopies(dir, "activity.json").isEmpty)
    }

    @Test func aProfileFromANewerBuildDropsAloneNotTheBook() throws {
        let json = """
        {"version": 7,
         "apps": {"com.openai.chat": {"comma": false, "leading": ["running"]},
                  "com.example.new": {"overrides": {"done": "someNewStatus"}}},
         "notChats": ["archive all"]}
        """
        let book = try JSONDecoder().decode(ProfileBook.self, from: Data(json.utf8))
        #expect(book.version == 7)
        #expect(Set(book.apps.keys) == ["com.openai.chat"])
        #expect(book.apps["com.openai.chat"]?.leading == ["running"])
        #expect(book.fallback == ProfileBook.builtIn.fallback)   // missing: the built-in one
        #expect(book.notChats == ["archive all"])
        // And it still round-trips as written.
        let again = try JSONDecoder().decode(ProfileBook.self, from: JSONEncoder().encode(book))
        #expect(again == book)
    }

    @Test func tasksFileWithLoopsAndRepeatsIsStraightenedOut() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = UUID(), b = UUID(), c = UUID()
        // Two big tasks under each other, a task under itself, and one id twice.
        let json = """
        [{"id": "\(a)", "title": "A", "windows": [], "isGroup": true, "parentID": "\(b)"},
         {"id": "\(b)", "title": "B", "windows": [], "isGroup": true, "parentID": "\(a)"},
         {"id": "\(c)", "title": "C", "windows": [], "parentID": "\(c)"},
         {"id": "\(c)", "title": "C again", "windows": []}]
        """
        let file = TaskFile(directory: dir)
        try Data(json.utf8).write(to: file.url)
        let tasks = file.load()
        #expect(tasks.map(\.title) == ["A", "B", "C"])
        #expect(tasks.allSatisfy { $0.parentID == nil })
    }

    @Test func learnedWordsSurviveOneUnknownStatus() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("learned-status.json")
        try Data(#"{"awaiting input": "needsInput", "pondering": "someNewStatus"}"#.utf8).write(to: url)
        let learned = LearnedStatus(url: url)
        #expect(learned.all == ["awaiting input": .needsInput])
    }

    @Test func aCorruptLearnedFileIsMovedAside() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("learned-status.json")
        try Data("not json".utf8).write(to: url)
        #expect(LearnedStatus(url: url).all.isEmpty)
        #expect(try badCopies(dir, "learned-status.json").count == 1)
    }
}

@Suite struct UntrustedNumberTests {
    @Test func impossiblePercentsAreKeptShowable() throws {
        // Shown as Int(percent): NaN, infinity or a huge value would trap.
        #expect(Limit(percent: .nan).percent == 0)
        #expect(Limit(percent: .infinity).percent == 0)
        #expect(Limit(percent: 1e300).percent == 1000)
        #expect(Limit(percent: -5).percent == 0)
        #expect(Limit(percent: 42.5).percent == 42.5)
        let saved = try JSONDecoder().decode(Limit.self, from: Data(#"{"percent": 1e300}"#.utf8))
        #expect(saved.percent == 1000)
    }

    @Test func codexLogWithNonsenseNumbers() {
        let log = """
        {"rate_limits":{"primary":{"used_percent":"nan","window_minutes":300},"secondary":{"used_percent":"1e300","window_minutes":10080}}}
        """
        let u = UsageReader.codex(fromLog: log)
        #expect(u?.five == nil)                  // not a number at all: no limit
        #expect(u?.week?.percent == 1000)
    }

    @Test func cursorBarWithNonsenseValueIsSkipped() {
        for v in ["nan", "inf", "-inf", "1e300"] {
            let root = AXNode(role: "AXWindow", kids: [AXNode(role: "AXProgressIndicator", desc: "Cursor Models", value: v)])
            #expect(UsageReader.labels(in: root).isEmpty, "\(v)")
        }
    }
}

final class FailingJev: StateClassifier, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var attempts: Int { lock.withLock { n } }
    func classify(state: [String: any Sendable]) async throws -> JevAnswer {
        lock.withLock { n += 1 }
        throw URLError(.notConnectedToInternet)
    }
    func choose(state: [String: any Sendable], instructions: String, options: [String: String]) async throws -> [String: Double] { [:] }
}

@Suite struct JevBackoffTests {
    @Test func retryDelayDoublesUpToFiveMinutes() {
        #expect((1...7).map { DetectionEngine.retryDelay(afterFailures: $0) } == [10, 20, 40, 80, 160, 300, 300])
        #expect(DetectionEngine.retryDelay(afterFailures: 1000) == 300)
    }

    @Test func offlineJevIsAskedLessAndLessOften() async throws {
        let clock = TestClock()
        let jev = FailingJev()
        var config = DetectionEngine.Config()
        config.summaries = false
        let screen = Snapshot(title: "Report", buttons: [], tail: "Here is the draft of the quarterly report so far", nodes: 1, millis: 1)
        let engine = DetectionEngine(classifier: jev, config: config, snapshot: { _ in screen }, now: { clock.now() })
        let me = ProcessInfo.processInfo.processIdentifier
        engine.watch(UUID(), window: AXWindow(element: AXUIElementCreateApplication(me), pid: me, appName: "Test", bundleID: "test", title: "Report"))

        func settle(_ attempts: Int) async throws {
            for _ in 0..<200 where jev.attempts < attempts { try await Task.sleep(for: .milliseconds(10)) }
            try await Task.sleep(for: .milliseconds(50))   // the failure lands on the engine's queue
        }
        engine.tickForTesting()
        clock.advance(3)
        engine.tickForTesting()                 // settled: asks, fails
        try await settle(1)
        clock.advance(11)
        engine.tickForTesting()                 // 10 s later: asks again, fails again
        try await settle(2)
        clock.advance(11)
        engine.tickForTesting()                 // only 11 s after the second failure: waits (20 s now)
        try await Task.sleep(for: .milliseconds(50))
        #expect(jev.attempts == 2)
        clock.advance(10)
        engine.tickForTesting()
        try await settle(3)
        #expect(jev.attempts == 3)
    }
}
