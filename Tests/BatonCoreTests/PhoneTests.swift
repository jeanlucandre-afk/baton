import Foundation
import Testing
@testable import BatonCore

private func ev(_ key: String, _ app: String, _ name: String?, _ kind: PhoneEvent.Kind) -> PhoneEvent {
    PhoneEvent(key: key, app: app, name: name, kind: kind)
}

@Suite struct PhonePingerTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func oneEventWaitsTheSettleThenGoes() {
        var p = PhonePinger()
        let r1 = p.add(ev("a", "Claude", "Acme rebrand", .finished), at: t0)
        #expect(r1)
        #expect(p.dueAt == t0 + 15)
        let r2 = p.take(now: t0 + 14, hideNames: false)
        #expect(r2 == nil)
        let push = p.take(now: t0 + 15, hideNames: false)
        #expect(push?.title == "Claude finished")
        #expect(push?.body == "Acme rebrand")
        #expect(p.pending.isEmpty && p.dueAt == nil)
    }

    @Test func eventsCloseTogetherBecomeOnePush() {
        var p = PhonePinger()
        p.add(ev("a", "Codex", "Pricing", .finished), at: t0)
        p.add(ev("b", "Claude", "Acme", .finished), at: t0 + 10)
        p.add(ev("c", "Claude", "Deck", .finished), at: t0 + 20)
        // Debounced from the latest event…
        #expect(p.dueAt == t0 + 35)
        let push = p.take(now: t0 + 35, hideNames: true)
        #expect(push?.title == "3 ready")
        #expect(push?.body == "Codex, Claude ×2")
    }

    @Test func aSteadyTrickleStillGoesWithinAMinute() {
        var p = PhonePinger()
        for i in 0..<8 { p.add(ev("t\(i)", "Codex", nil, .finished), at: t0 + Double(i) * 10) }
        #expect(p.dueAt == t0 + 60)
    }

    @Test func neverTwoPushesWithin30Seconds() {
        var p = PhonePinger()
        p.add(ev("a", "Codex", nil, .finished), at: t0)
        let r3 = p.take(now: t0 + 15, hideNames: false)
        #expect(r3 != nil)
        p.add(ev("b", "Claude", nil, .needsYou), at: t0 + 16)
        // Settle says +31, the gap says +45.
        #expect(p.dueAt == t0 + 45)
        let r4 = p.take(now: t0 + 40, hideNames: false)
        #expect(r4 == nil)
        let r5 = p.take(now: t0 + 45, hideNames: false)
        #expect(r5?.title == "Claude needs you")
    }

    @Test func theSameNewsTwiceIsSentOnce() {
        var p = PhonePinger()
        let r6 = p.add(ev("a", "Codex", "X", .stuck), at: t0)
        #expect(r6)
        let r7 = p.add(ev("a", "Codex", "X", .stuck), at: t0 + 5)
        #expect(!r7)
        _ = p.take(now: t0 + 60, hideNames: false)
        // Still a repeat a few minutes later…
        let r8 = p.add(ev("a", "Codex", "X", .stuck), at: t0 + 200)
        #expect(!r8)
        #expect(p.pending.isEmpty)
        // …but news again after the dedupe window, and different news at once.
        let r9 = p.add(ev("a", "Codex", "X", .stuck), at: t0 + 400)
        #expect(r9)
        let r10 = p.add(ev("a", "Codex", "X", .finished), at: t0 + 401)
        #expect(r10)
        // Newer news about the same task replaces the older.
        #expect(p.pending.count == 1 && p.pending[0].kind == .finished)
    }

    @Test func comingBackDropsWhatWasQueued() {
        var p = PhonePinger()
        p.add(ev("a", "Codex", nil, .finished), at: t0)
        p.drop()
        #expect(p.dueAt == nil)
        let r11 = p.take(now: t0 + 100, hideNames: false)
        #expect(r11 == nil)
    }
}

@Suite struct PhoneMessageTests {
    @Test func singleMessagesSayAppStateAndTask() {
        let n = PhonePinger.message([ev("a", "Claude", "Acme rebrand", .needsYou)], hideNames: false)
        #expect(n.title == "Claude needs you")
        #expect(n.body == "Acme rebrand · waiting on you")
        #expect(n.priority == 4)
        #expect(n.tags == ["needs-you"])
        let s = PhonePinger.message([ev("a", "Codex", "Pricing", .stuck)], hideNames: false)
        #expect(s.title == "Codex looks stuck")
        #expect(s.priority == 3)
    }

    @Test func hideNamesLeavesOnlyAppAndState() {
        let one = PhonePinger.message([ev("a", "Codex", "Secret launch", .finished)], hideNames: true)
        #expect(one.title == "Codex finished")
        #expect(!one.body.contains("Secret"))
        let many = PhonePinger.message([ev("a", "Claude", "Secret", .needsYou), ev("b", "Codex", "Plan", .finished),
                                        ev("c", "Claude", "Deck", .finished)], hideNames: true)
        #expect(many.title == "1 needs you · 2 ready")
        #expect(many.body == "Claude ×2, Codex")
        #expect(!many.body.contains("Secret") && !many.title.contains("Secret"))
    }

    @Test func groupedWithNamesListsEachOneNeedsYouFirst() {
        let m = PhonePinger.message([ev("a", "Cursor", "landing redesign", .finished), ev("b", "Claude", "Acme", .needsYou),
                                     ev("c", "Codex", nil, .stuck)], hideNames: false)
        #expect(m.title == "1 needs you · 1 ready · 1 stuck")
        #expect(m.body == "Claude needs you · Acme\nCursor · landing redesign\nCodex looks stuck")
        #expect(m.priority == 4)
        #expect(m.tags == ["needs-you", "finished", "stuck"])
    }

    @Test func longListsAreCut() {
        let evs = (0..<9).map { ev("t\($0)", "Codex", "Task \($0)", .finished) }
        let m = PhonePinger.message(evs, hideNames: false)
        #expect(m.title == "9 ready")
        #expect(m.body.split(separator: "\n").count == 7)
        #expect(m.body.hasSuffix("and 3 more"))
    }

    @Test func namesAreRedactedAndKeptShort() {
        let m = PhonePinger.message([ev("a", "Claude", "Reply to jane@acme.com\nwith sk-abcdefghijklmnop1234", .finished)], hideNames: false)
        #expect(!m.body.contains("jane@acme.com"))
        #expect(!m.body.contains("sk-abcdef"))
        #expect(!m.body.contains("\n"))
        let long = PhonePinger.message([ev("a", "Claude", String(repeating: "word ", count: 40), .finished)], hideNames: false)
        #expect(long.body.count == 60 && long.body.hasSuffix("…"))
    }
}

@Suite struct PhoneChannelTests {
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
    }

    @Test func topicsAreLongRandomAndValid() {
        var g = Seeded(state: 42)
        let a = PhoneChannel.newTopic(using: &g), b = PhoneChannel.newTopic(using: &g)
        #expect(a.hasPrefix("baton-") && a.count == 30)
        #expect(a != b)
        #expect(PhoneChannel.isValidTopic(a))
        #expect(a.dropFirst(6).allSatisfy { "abcdefghijklmnopqrstuvwxyz234567".contains($0) })
        #expect(PhoneChannel.newTopic() != PhoneChannel.newTopic())
        #expect(!PhoneChannel.isValidTopic("has space"))
        #expect(!PhoneChannel.isValidTopic(""))
    }

    @Test func serversNormalize() {
        #expect(PhoneChannel.server("")?.absoluteString == "https://ntfy.sh")
        #expect(PhoneChannel.server("  ntfy.example.com/ ")?.absoluteString == "https://ntfy.example.com")
        #expect(PhoneChannel.server("http://10.0.0.2:8080")?.absoluteString == "http://10.0.0.2:8080")
        #expect(PhoneChannel.server("ftp://x.com") == nil)
        #expect(PhoneChannel.server("https://x.com/?a=1") == nil)
    }

    @Test func linksForThePhone() {
        let s = PhoneChannel.server("")!
        #expect(PhoneChannel.subscribeURL(server: s, topic: "baton-abc") == "ntfy://ntfy.sh/baton-abc")
        #expect(PhoneChannel.webURL(server: s, topic: "baton-abc") == "https://ntfy.sh/baton-abc")
        let local = PhoneChannel.server("http://mac.local:8080")!
        #expect(PhoneChannel.subscribeURL(server: local, topic: "t") == "ntfy://mac.local:8080/t?secure=false")
    }

    @Test func logsNeverHoldTheWholeTopic() {
        let t = "baton-abcdefghijklmnopqrstuvwx"
        #expect(PhoneChannel.logTag(t) == "abcdef…")
        #expect(!PhoneChannel.logTag(t).contains("ghijkl"))
    }

    @Test func requestIsAPlainNtfyPost() {
        let push = PhonePush(title: "3 ready · Codex", body: "Codex · Plan\nClaude · Acme", tags: ["finished"], priority: 4,
                             click: URL(string: "https://example.com"))
        let r = PhoneChannel.request(push, server: PhoneChannel.server("")!, topic: "baton-xyz")
        #expect(r.httpMethod == "POST")
        #expect(r.url?.absoluteString == "https://ntfy.sh/baton-xyz")
        #expect(r.httpBody == Data("Codex · Plan\nClaude · Acme".utf8))
        #expect(r.value(forHTTPHeaderField: "Tags") == "finished")
        #expect(r.value(forHTTPHeaderField: "Priority") == "4")
        #expect(r.value(forHTTPHeaderField: "Click") == "https://example.com")
        #expect(r.timeoutInterval == 10)
        // Non-ASCII titles go as RFC 2047; plain ones as they are.
        let title = r.value(forHTTPHeaderField: "Title") ?? ""
        #expect(title.hasPrefix("=?UTF-8?B?") && title.hasSuffix("?="))
        let b64 = String(title.dropFirst(10).dropLast(2))
        #expect(String(data: Data(base64Encoded: b64)!, encoding: .utf8) == "3 ready · Codex")
        #expect(PhoneChannel.header("Codex finished") == "Codex finished")
        #expect(PhoneChannel.request(.test, server: PhoneChannel.server("")!, topic: "t").value(forHTTPHeaderField: "Click") == nil)
    }
}

@Suite struct PhoneDeliveryTests {
    /// Never touches the network: answers from a script and counts calls.
    actor Fake: PhoneTransport {
        var script: [Result<Int, URLError>]
        private(set) var calls = 0
        init(_ script: [Result<Int, URLError>]) { self.script = script }
        func send(_ request: URLRequest) async throws -> Int {
            calls += 1
            return try script.removeFirst().get()
        }
    }

    let req = PhoneChannel.request(.test, server: URL(string: "https://ntfy.invalid")!, topic: "t")

    @Test func sentFirstTime() async {
        let f = Fake([.success(200)])
        #expect(await PhoneDelivery.deliver(req, via: f, retryAfter: .zero) == .sent)
        #expect(await f.calls == 1)
    }

    @Test func retriesOnceThenSucceeds() async {
        let f = Fake([.failure(URLError(.timedOut)), .success(200)])
        #expect(await PhoneDelivery.deliver(req, via: f, retryAfter: .zero) == .sent)
        #expect(await f.calls == 2)
    }

    @Test func givesUpAfterTheRetry() async {
        let f = Fake([.success(503), .failure(URLError(.notConnectedToInternet)), .success(200)])
        #expect(await PhoneDelivery.deliver(req, via: f, retryAfter: .zero) == .failed("offline"))
        #expect(await f.calls == 2)
    }

    @Test func clientErrorsAreNotRetried() async {
        let f = Fake([.success(403), .success(200)])
        #expect(await PhoneDelivery.deliver(req, via: f, retryAfter: .zero) == .failed("HTTP 403"))
        #expect(await f.calls == 1)
        let limited = Fake([.success(429), .success(200)])
        #expect(await PhoneDelivery.deliver(req, via: limited, retryAfter: .zero) == .sent)
    }
}

@Suite struct AwayCadenceTests {
    @Test func readsGetFurtherApartUpToFifteenMinutes() {
        let gaps = (0..<8).map { AwayCadence.interval(afterRead: $0) }
        #expect(gaps == [30, 60, 120, 240, 480, 900, 900, 900])
        #expect(AwayCadence.interval(afterRead: -1) == 30)
        #expect(AwayCadence.interval(afterRead: 10_000) == 900)
    }
}
