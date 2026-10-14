import Foundation
import Testing
@testable import BatonCore

@Suite struct UsageTests {
    let now = Date(timeIntervalSince1970: 1_791_600_000)

    @Test func codexLogGivesFiveHoursAndWeek() {
        let log = """
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1791600100}}}}
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":15.0,"window_minutes":300,"resets_at":1791610078},"secondary":{"used_percent":34.0,"window_minutes":10080,"resets_at":1791968918},"credits":{"has_credits":false,"unlimited":false,"balance":"0"}}}}
        """
        let u = UsageReader.codex(fromLog: log)
        #expect(u?.five?.percent == 15)
        #expect(u?.week?.percent == 34)
        #expect(u?.five?.resetsAt == Date(timeIntervalSince1970: 1_791_610_078))
    }

    @Test func claudeShowsSessionOrWeek() {
        let session = UsageReader.claude(label: "Usage: Context 552.7k / 1M (55%), 29% of session limit, Resets in 3 hr 54 min", now: now)
        #expect(session?.five?.percent == 29)
        #expect(session?.week == nil)
        #expect(session?.five?.resetsAt == now.addingTimeInterval(3 * 3600 + 54 * 60))

        let week = UsageReader.claude(label: "Usage: Context 351k / 1M (35%), Weekly · all models: 39%, Resets Tue 10:00 AM", now: now)
        #expect(week?.week?.percent == 39)
        #expect(week?.five == nil)
        let reset = try! #require(week?.week?.resetsAt)
        #expect(Calendar.current.component(.weekday, from: reset) == 3)    // Tuesday
        #expect(Calendar.current.component(.hour, from: reset) == 10)
        #expect(reset > now)

        #expect(UsageReader.claude(label: "Usage: Context 12k / 200k (6%)", now: now) == nil)
    }

    @Test func readingsMergeAndResetsPassToZero() {
        var u = AppUsage()
        u.merge(UsageReader.claude(label: "Usage: 29% of session limit, Resets in 1 hr", now: now)!)
        u.merge(UsageReader.claude(label: "Usage: Weekly · all models: 39%, Resets Tue 10:00 AM", now: now)!)
        #expect(u.five?.percent == 29 && u.week?.percent == 39)
        let later = u.current(at: now.addingTimeInterval(2 * 3600))
        #expect(later.five?.percent == 0)
        #expect(later.week?.percent == 39)
    }

    @Test func aLimitOlderThanItsWindowWithNoResetTimeCountsAsReset() {
        var u = AppUsage()
        u.merge(UsageReader.claude(label: "Usage: 100% of session limit", now: now)!)
        u.fiveSeen = now
        #expect(u.current(at: now.addingTimeInterval(4 * 3600)).five?.percent == 100)
        #expect(u.current(at: now.addingTimeInterval(6 * 3600)).five?.percent == 0)
    }

    @Test func cursorModelsFromPlanAndUsage() {
        let u = UsageReader.cursor(labels: ["Usage limits reset on Oct 24 (14 days left)", "Cursor Models 47%"], now: now)
        #expect(u?.plan?.percent == 47)
        let reset = try! #require(u?.plan?.resetsAt)
        #expect(Calendar.current.component(.month, from: reset) == 10)
        #expect(Calendar.current.component(.day, from: reset) == 24)
        // The Agents window's button is the fullest bucket (Other Models): never used.
        #expect(UsageReader.cursor(labels: ["Usage 100%"], now: now) == nil)
    }

    @Test func findsUsageLabelsInAWindow() {
        let root = AXNode(role: "AXWindow", kids: [
            AXNode(role: "AXButton", desc: "Usage 100%"),
            AXNode(role: "AXButton", desc: "Context 25%"),
            AXNode(role: "AXPopUpButton", desc: "Usage: Context 351k / 1M (35%), Weekly · all models: 39%, Resets Tue 10:00 AM"),
            AXNode(role: "AXStaticText", value: "Usage limits reset on Oct 24 (14 days left)"),
            AXNode(role: "AXProgressIndicator", desc: "Cursor Models", value: "47"),
            AXNode(role: "AXProgressIndicator", desc: "Other Models", value: "100")
        ])
        let labels = UsageReader.labels(in: root)
        #expect(labels.count == 3)
        #expect(labels.contains("Cursor Models 47%"))
        #expect(!labels.contains("Usage 100%"))
    }
}
