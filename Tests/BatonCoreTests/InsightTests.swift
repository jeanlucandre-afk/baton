import ApplicationServices
import Foundation
import Testing
@testable import BatonCore

@Suite struct StuckTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func min(_ m: Double) -> TimeInterval { m * 60 }

    @Test func offWhenTheSettingIsZero() {
        #expect(Stuck.check(start: t0, screen: nil, now: t0 + min(500), minutes: 0, typical: nil) == nil)
    }

    @Test func chatWithNoHistoryIsStuckAfterTwiceTheSetting() {
        #expect(Stuck.check(start: t0, screen: nil, now: t0 + min(29), minutes: 15, typical: nil) == nil)
        let v = Stuck.check(start: t0, screen: nil, now: t0 + min(30), minutes: 15, typical: nil)
        #expect(v?.reason == .longRun)
        #expect(v?.ping(app: "Codex") == "Codex looks stuck · 30 min")
    }

    @Test func historySetsTheLimitButNeverUnderTheSetting() {
        // Runs usually take 4 min: twice that is under the setting, so the setting wins.
        #expect(Stuck.limit(minutes: 15, typical: min(4)) == min(15))
        // Runs usually take 20 min: up to 40 is normal.
        #expect(Stuck.limit(minutes: 15, typical: min(20)) == min(40))
        #expect(Stuck.check(start: t0, screen: nil, now: t0 + min(39), minutes: 15, typical: min(20)) == nil)
        #expect(Stuck.check(start: t0, screen: nil, now: t0 + min(40), minutes: 15, typical: min(20))?.reason == .longRun)
    }

    @Test func typicalNeedsEnoughRunsAndIgnoresOutliersBelowP90() {
        #expect(Stuck.typical([60, 120, 180, 240]) == nil)
        let runs: [TimeInterval] = [60, 60, 60, 60, 60, 60, 60, 60, 120, 3600]
        #expect(Stuck.typical(runs) == 120)
    }

    @Test func frozenScreenWhileWorking() {
        let screen = Stuck.Screen(lastChange: t0 + min(2), tail: "Writing the tests…")
        #expect(Stuck.check(start: t0, screen: screen, now: t0 + min(16), minutes: 15, typical: nil) == nil)
        let v = Stuck.check(start: t0, screen: screen, now: t0 + min(17), minutes: 15, typical: nil)
        #expect(v?.reason == .frozen)
        #expect(v?.why == "No change on screen for 15 min")
    }

    @Test func aChangeBeforeTheRunStartedDoesNotCount() {
        // The screen last changed an hour ago, but the run only started 5 minutes ago.
        let screen = Stuck.Screen(lastChange: t0 - min(60), tail: "")
        #expect(Stuck.check(start: t0, screen: screen, now: t0 + min(5), minutes: 15, typical: nil) == nil)
    }

    @Test func errorOnScreenIsStuckAfterTwoQuietMinutes() {
        let screen = Stuck.Screen(lastChange: t0, tail: "…\nSomething went wrong. Please try again.")
        #expect(Stuck.check(start: t0, screen: screen, now: t0 + 90, minutes: 15, typical: nil) == nil)
        #expect(Stuck.check(start: t0, screen: screen, now: t0 + 121, minutes: 15, typical: nil)?.reason == .error)
    }

    @Test func errorWordsEarlierInTheTextDontCount() {
        let old = "Network error" + String(repeating: " and then it carried on fine", count: 20)
        #expect(!Stuck.showsError(old))
        #expect(Stuck.showsError("Request failed with status 529: Overloaded"))
    }

    @Test func durations() {
        #expect(Stuck.duration(42) == "42 s")
        #expect(Stuck.duration(12 * 60 + 10) == "12 min")
        #expect(Stuck.duration(3600) == "1 h")
        #expect(Stuck.duration(3900) == "1 h 5 min")
    }

    @Test func runKeyIsPerRun() {
        let id = UUID()
        #expect(Stuck.runKey(id, start: t0) == Stuck.runKey(id, start: t0))
        #expect(Stuck.runKey(id, start: t0) != Stuck.runKey(id, start: t0 + 60))
    }

    @Test func engineHandsOverWhatItLastSaw() async {
        let clock = TestClock()
        let engine = DetectionEngine(classifier: nil, snapshot: { _ in
            Snapshot(title: "Doc", buttons: ["Stop"], tail: "Thinking hard", nodes: 1, millis: 1)
        }, now: { clock.now() })
        let me = ProcessInfo.processInfo.processIdentifier
        let id = UUID()
        engine.watch(id, window: AXWindow(element: AXUIElementCreateApplication(me), pid: me, appName: "Test", bundleID: "test", title: "Doc"))
        engine.tickForTesting()
        let changed = clock.now()
        for _ in 0..<5 { clock.advance(1); engine.tickForTesting() }
        let s = await engine.screens()[id]
        #expect(s?.lastChange == changed)
        #expect(s?.tail == "Thinking hard")
    }
}

@Suite struct ActivityLogTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func runsKeepTheirStartAndEndOnce() {
        var log = ActivityLog()
        let id = UUID()
        log.begin(task: id, title: "Deck", bundleID: "com.openai.codex", appName: "Codex", at: t0)
        log.begin(task: id, title: "Deck", bundleID: "com.openai.codex", appName: "Codex", at: t0 + 30)
        #expect(log.runs.count == 1)
        #expect(log.open(id)?.start == t0)
        let ended = log.end(task: id, at: t0 + 300, outcome: .finished)
        #expect(ended?.end == t0 + 300)
        #expect(log.end(task: id, at: t0 + 400, outcome: .finished) == nil)
        #expect(log.durations(bundleID: "com.openai.codex") == [300])
    }

    @Test func stuckRunsDontSetTheUsualLength() {
        var log = ActivityLog()
        let id = UUID()
        log.begin(task: id, title: "Deck", bundleID: "b", appName: "B", at: t0)
        log.markStuck(id)
        log.end(task: id, at: t0 + 5000, outcome: .idle)
        #expect(log.durations(bundleID: "b").isEmpty)
    }

    @Test func tidyDropsOpenAndOldRuns() {
        var log = ActivityLog()
        log.begin(task: UUID(), title: "Left open", bundleID: "b", appName: "B", at: t0)
        let old = UUID()
        log.begin(task: old, title: "Old", bundleID: "b", appName: "B", at: t0 - 20 * 86_400)
        log.end(task: old, at: t0 - 20 * 86_400 + 60, outcome: .finished)
        let kept = UUID()
        log.begin(task: kept, title: "Kept", bundleID: "b", appName: "B", at: t0 - 3600)
        log.end(task: kept, at: t0 - 3000, outcome: .finished)
        log.tidy(now: t0)
        #expect(log.runs.map(\.title) == ["Kept"])
    }

    @Test func savesAndLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("baton-activity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = ActivityFile(directory: dir)
        #expect(file.load() == ActivityLog())
        var log = ActivityLog()
        log.noteDone(task: UUID(), title: "Logo", at: t0)
        file.save(log)
        #expect(file.load() == log)
    }
}

@Suite struct RecapTests {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Berlin")!; return c }
    // 10 Oct 2026, 18:00 Berlin
    var evening: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 18))! }

    func item(_ title: String, _ kind: Recap.Item.Kind, minutesAgo: Double, next: String? = nil) -> Recap.Item {
        Recap.Item(id: UUID(), title: title, appName: "Claude", bundleID: "com.anthropic.claudefordesktop",
                   kind: kind, since: evening.addingTimeInterval(-minutesAgo * 60), next: next)
    }

    @Test func summarizesTheDay() {
        var log = ActivityLog()
        let a = UUID(), b = UUID(), y = UUID()
        // Yesterday's run doesn't count as finished today; the part of it after midnight is AI time.
        let midnight = cal.startOfDay(for: evening)
        log.begin(task: y, title: "Yesterday", bundleID: "com.openai.codex", appName: "Codex", at: midnight - 600)
        log.end(task: y, at: midnight + 600, outcome: .finished)
        log.begin(task: a, title: "Pitch deck", bundleID: "com.openai.codex", appName: "Codex", at: evening - 3600)
        log.end(task: a, at: evening - 1800, outcome: .finished)
        log.begin(task: a, title: "Pitch deck", bundleID: "com.openai.codex", appName: "Codex", at: evening - 1200)
        log.end(task: a, at: evening - 600, outcome: .needsYou)
        log.begin(task: b, title: "Logo", bundleID: "com.anthropic.claudefordesktop", appName: "Claude", at: evening - 300)
        log.noteDone(task: UUID(), title: "Invoice", at: evening - 60)

        let items = [item("Pitch deck", .needsYou, minutesAgo: 10), item("Logo", .running, minutesAgo: 5),
                     item("Moodboard", .idle, minutesAgo: 300, next: "Pick the palette"), item("Brief", .stuck, minutesAgo: 40)]
        let r = Recap.make(log: log, items: items, now: evening, calendar: cal)
        #expect(r.finished == ["Invoice", "Pitch deck", "Yesterday"])
        #expect(r.running.map(\.title) == ["Brief", "Logo"])
        #expect(r.waiting.map(\.title) == ["Pitch deck"])
        // Codex: 10 min after midnight + 30 + 10 = 50 min; Claude: the 5 minutes so far.
        #expect(r.appTime.map(\.appName) == ["Codex", "Claude"])
        #expect(r.appTime.first?.seconds == 3000)
        #expect(r.tomorrow.map(\.title) == ["Pitch deck", "Brief", "Moodboard"])
        #expect(r.headline == "One waits on you")
        #expect(r.counts == "3 finished · 2 running · 1 waiting")
    }

    @Test func textHasEverySection() {
        let r = Recap.make(log: ActivityLog(), items: [item("Logo", .ready, minutesAgo: 1, next: "Approve the mark")], now: evening, calendar: cal)
        let text = r.text(calendar: cal)
        #expect(text.hasPrefix("One waits on you — Saturday"))
        #expect(text.contains("Waiting on you\n- Logo (Claude)"))
        #expect(text.contains("Tomorrow\n1. Logo — Approve the mark"))
        #expect(!text.contains("AI time"))
    }

    @Test func templates() {
        #expect(Recap.template(finished: 0, running: 0, waiting: 0) == "Quiet day")
        #expect(Recap.template(finished: 3, running: 0, waiting: 2) == "2 wait on you")
        #expect(Recap.template(finished: 3, running: 1, waiting: 0) == "Still running")
        #expect(Recap.template(finished: 3, running: 0, waiting: 0) == "All wrapped up")
    }

    @Test func pickUpPrefersWaitingThenStuckThenNextSteps() {
        let items = [item("Running", .running, minutesAgo: 100), item("Idle, no next", .idle, minutesAgo: 500),
                     item("Idle, next", .idle, minutesAgo: 5, next: "Send it"), item("Ready new", .ready, minutesAgo: 1),
                     item("Ready old", .ready, minutesAgo: 60)]
        #expect(Recap.pickUp(items).map(\.title) == ["Ready old", "Ready new", "Idle, next"])
    }

    @Test func headlineFromGemini() {
        #expect(Recap.parseHeadline(#"{"headline": "Two decks, one logo."}"#) == "Two decks, one logo")
        #expect(Recap.parseHeadline(#"{"headline": "This is far too long to be a headline on a small card"}"#) == nil)
        #expect(Recap.parseHeadline("not json") == nil)
        #expect(Recap.parseHeadline(nil) == nil)
        let prompt = Recap.make(log: ActivityLog(), items: [item("Mail jane@example.com", .ready, minutesAgo: 1)], now: evening, calendar: cal).headlinePrompt()
        #expect(!prompt.contains("jane@example.com"))
    }

    @Test func dueOnceADayInsideItsWindow() {
        let six = 18 * 60
        #expect(!Recap.due(now: evening - 60, atMinutes: six, lastShown: nil, calendar: cal))
        #expect(Recap.due(now: evening + 30, atMinutes: six, lastShown: nil, calendar: cal))
        #expect(!Recap.due(now: evening + 30, atMinutes: six, lastShown: evening + 5, calendar: cal))
        #expect(Recap.due(now: evening + 30, atMinutes: six, lastShown: evening - 86_400, calendar: cal))
        // Mac was asleep all evening: not at 23:30.
        #expect(!Recap.due(now: evening + 5.5 * 3600, atMinutes: six, lastShown: nil, calendar: cal))
    }
}
