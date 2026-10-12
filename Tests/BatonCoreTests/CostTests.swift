@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import BatonCore

/// Reading less of a window (pruning) must never change what a poll gets out of it.
@Suite struct PrunedReadTests {
    init() { _ = Isolated.learned }

    private func fixture(_ name: String) throws -> AXNode {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name).json")
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    @Test(arguments: [("cursor", "com.todesktop.230313mzl4w4u92"), ("claude", "com.anthropic.claudefordesktop"),
                      ("chatgpt", "com.openai.codex"), ("grok", "com.anysphere.sand")])
    func prunedReadMatchesFullRead(app: (String, String)) throws {
        let full = try fixture(app.0)
        let pruned = full.pruned(ProfileBook.builtIn.profile(app.1).prune)
        let a = Sidebar.read(full, bundleID: app.1, book: .builtIn)
        let b = Sidebar.read(pruned, bundleID: app.1, book: .builtIn)
        #expect(a.rows == b.rows)
        #expect(a.names == b.names)
        #expect(a.openName == b.openName)
        #expect(a.generating == b.generating)
        #expect(a.sections == b.sections)
        #expect(a.folders == b.folders)
        #expect(UsageReader.labels(in: full) == UsageReader.labels(in: pruned))
    }

    @Test func cursorSkipsTheOpenAgentsMessages() throws {
        let full = try fixture("cursor")
        let pruned = full.pruned(ProfileBook.builtIn.profile("com.todesktop.230313mzl4w4u92").prune)
        #expect(pruned.count < full.count)
        // A stop button below the messages (the composer's) still shows the agent working.
        var composer = AXNode(role: "AXGroup", classes: "agent-panel-followup-input")
        composer.kids = [AXNode(role: "AXButton", desc: "Stop")]
        var window = pruned
        window.kids.append(composer)
        #expect(Sidebar.read(window, bundleID: "com.todesktop.230313mzl4w4u92", book: .builtIn).generating)
    }
}

/// A second progress request for the same window text reuses the answer instead of calling Gemini.
@Suite struct ProgressMemoTests {
    let asked = [TaskStep(text: "Draft", done: false)]
    let answer = TaskProgress(summary: "Claude wrote the draft", steps: [TaskStep(text: "Draft", done: true)], next: "Read it")

    @Test func sameTextSameAnswer() {
        var m = ProgressMemo()
        m.remember(task: "Essay", steps: asked, app: "Claude", tail: "…the end", status: .finished, answer)
        #expect(m.answer(task: "Essay", steps: asked, app: "Claude", tail: "…the end", status: .finished) == answer)
        // The caller saved the answer's steps: still the same question.
        #expect(m.answer(task: "Essay", steps: answer.steps, app: "Claude", tail: "…the end", status: .finished) == answer)
    }

    @Test func anythingNewAsksAgain() {
        var m = ProgressMemo()
        m.remember(task: "Essay", steps: asked, app: "Claude", tail: "…the end", status: .finished, answer)
        #expect(m.answer(task: "Essay", steps: asked, app: "Claude", tail: "…a new end", status: .finished) == nil)
        #expect(m.answer(task: "Essay", steps: asked, app: "Claude", tail: "…the end", status: .needsYou) == nil)
        #expect(m.answer(task: "Novel", steps: asked, app: "Claude", tail: "…the end", status: .finished) == nil)
        // You edited the steps in between: ask again.
        #expect(m.answer(task: "Essay", steps: [TaskStep(text: "Outline", done: false)], app: "Claude", tail: "…the end", status: .finished) == nil)
    }

    @Test func staysSmall() {
        var m = ProgressMemo()
        for i in 0..<40 { m.remember(task: "t\(i)", steps: [], app: "a", tail: "x", status: .finished, answer) }
        #expect(m.answer(task: "t0", steps: [], app: "a", tail: "x", status: .finished) == nil)
        #expect(m.answer(task: "t39", steps: [], app: "a", tail: "x", status: .finished) == answer)
    }
}

/// A window that has stood still for a while is read less often; any sign of life brings it back to every second.
@Suite struct QuietWindowTests {
    final class Screen: @unchecked Sendable {
        private let lock = NSLock()
        private var text = "The draft is done. Anything else?"
        private var count = 0
        var reads: Int { lock.withLock { count } }
        func set(_ t: String) { lock.withLock { text = t } }
        func read() -> Snapshot { lock.withLock { count += 1; return Snapshot(title: "Doc", buttons: [], tail: text, nodes: 1, millis: 1) } }
    }

    @Test func stillWindowsAreReadEveryFewSeconds() {
        let clock = TestClock()
        let screen = Screen()
        let engine = DetectionEngine(classifier: nil, snapshot: { _ in screen.read() }, now: { clock.now() })
        let me = ProcessInfo.processInfo.processIdentifier
        engine.watch(UUID(), window: AXWindow(element: AXUIElementCreateApplication(me), pid: me, appName: "Test", bundleID: "test", title: "Doc"))
        func run(_ seconds: Int) -> Int {
            let before = screen.reads
            for _ in 0..<seconds { engine.tickForTesting(); clock.advance(1) }
            return screen.reads - before
        }
        #expect(run(31) == 31)            // every second until it has stood still 30 s
        #expect(run(30) == 10)            // then every 3 s
        engine.noteTyping(pid: me)
        #expect(run(1) == 1)              // typing in its app: read straight away
        screen.set("Working on the next part…")
        #expect(run(3) >= 1)              // a change is seen within 3 s…
        #expect(run(3) == 3)              // …and from then on it's read every second
    }

    /// The app always hands the engine its Jev, keyless until you add a key. Without a key it must act as
    /// if there were no Jev: no failing calls, no 10 s rechecks, and still windows go quiet.
    @Test func aKeylessJevLetsWindowsGoQuiet() async throws {
        let clock = TestClock()
        let screen = Screen()
        let engine = DetectionEngine(classifier: Jev(key: nil), snapshot: { _ in screen.read() }, now: { clock.now() })
        let me = ProcessInfo.processInfo.processIdentifier
        engine.watch(UUID(), window: AXWindow(element: AXUIElementCreateApplication(me), pid: me, appName: "Test", bundleID: "test", title: "Doc"))
        for _ in 0..<31 {
            engine.tickForTesting()
            clock.advance(1)
            try await Task.sleep(for: .milliseconds(2))   // lets a failed call's recheck land, if one was made
        }
        let before = screen.reads
        for _ in 0..<30 { engine.tickForTesting(); clock.advance(1) }
        #expect(screen.reads - before == 10)
        #expect(await engine.stats().calls == 0)
    }
}

/// Cursor's sidebar also lists suggested projects and archived chats. Neither has a "Completed" icon,
/// and a row with no icon reads as a running agent, so both used to show as working (and "stuck").
@Suite struct CursorNotRunningTests {
    init() { _ = Isolated.learned }
    let cursor = "com.todesktop.230313mzl4w4u92"

    private func fixture(_ name: String) throws -> AXNode {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name).json")
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    @Test func suggestionsAndArchivedChatsAreNotWorking() throws {
        let read = Sidebar.read(try fixture("cursor-archived"), bundleID: cursor, book: .builtIn)
        let names = read.rows.map(\.name)
        // Suggested projects and row buttons aren't chats.
        for notChat in ["Glossary Draft", "Timezone Fixes", "Remove Suggestion", "Unarchive"] {
            #expect(!names.contains(notChat), "\(notChat) read as a chat")
        }
        // The archived (pinned) chat is quiet, and so is every other chat in this window.
        #expect(read.rows.first { $0.name == "API development for Acme" }?.status == .idle)
        #expect(read.rows.allSatisfy { $0.status != .working })
        // Its title drops the "archived" icon's label.
        #expect(read.openName == "API development for Acme")
    }
}
