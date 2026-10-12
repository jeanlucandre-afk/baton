@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import BatonCore

/// Pull request badges ("15 · open") sit where Claude shows a chat's status. They're not statuses.
@Suite struct BadgeTests {
    init() { _ = Isolated.learned }

    @Test func aBadgeIsNotAStatusToLearn() {
        let window = AXNode(role: "AXWindow", kids: [ClaudeChatTabTests().chatRow("PR review", status: "15 · open")])
        #expect(Sidebar.rows(in: window, profile: ProfileBook.builtIn.profile("com.anthropic.claudefordesktop"))
                == [ChatRow(name: "PR review", status: .idle)])
        #expect(Sidebar.unknownStatusWord(for: "PR review", in: window) == nil)
        let row = AXNode(role: "AXGroup", kids: [AXNode(role: "AXButton", title: "15 · merged Acme audit")])
        #expect(Sidebar.unknownStatusWord(for: "Acme audit", in: row) == nil)
    }

    @Test func badgesAreNeverLearnedAndOldOnesAreDropped() throws {
        let store = LearnedStatus(url: nil)
        store.learn("15 · open", .unread)
        store.learn("Pre-flight", .working)
        #expect(store.status(of: "15 · open") == nil)
        #expect(store.status(of: "pre-flight") == .working)

        let url = FileManager.default.temporaryDirectory.appending(path: "baton-learned-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        store.learn("New session in", .unread)
        #expect(store.status(of: "new session in") == nil)
        try Data(#"{"15 · open": "unread", "15 · merged": "unread", "new session in": "unread", "snoozing": "idle"}"#.utf8).write(to: url)
        #expect(LearnedStatus(url: url).all == ["snoozing": .idle])
    }
}

/// The saved Claude profile that took the whole window for its chat list.
@Suite struct LooseProfileTests {
    init() { _ = Isolated.learned }

    let claude = ProfileBook.builtIn.profile("com.anthropic.claudefordesktop")
    let chats = ["Acme audit", "Pricing copy", "Partner outreach"]

    var window: AXNode {
        let controls = ["Back", "Forward", "Send", "Copy", "Dismiss", "Stop", "Deny 1", "Create PR", "Screenshot 2026-10-08.png",
                        "Show message actions for Acme audit", "Ran 2 commands"]
        return AXNode(role: "AXWindow", kids: [AXNode(role: "AXGroup", desc: "Main", classes: "relative.flex", kids:
            controls.map { AXNode(role: "AXButton", title: $0) } + [
                AXNode(role: "AXButton", title: "Running Acme audit"),
                AXNode(role: "AXButton", title: "Idle Pricing copy"),
                AXNode(role: "AXButton", title: "Unread response Partner outreach"),
            ])])
    }

    @Test func aWholeWindowListIsRejected() {
        var bad = claude
        bad.list = NodeMatch(role: "AXGroup", classContains: "relative")
        #expect(bad.list!.isTooLoose)
        #expect(ProfileRepair.validate(bad, root: window, known: chats, usual: 3, notChats: [], via: "test") == nil)
        // Even a list that names its element is wrong when toolbar and message buttons read as chats.
        var whole = claude
        whole.list = NodeMatch(role: "AXGroup", desc: "Main")
        #expect(!whole.list!.isTooLoose)
        #expect(ProfileRepair.validate(whole, root: window, known: chats, usual: 10, notChats: [], via: "test") == nil)
        #expect(ProfileRepair.validate(claude, root: window, known: chats, usual: 3, notChats: [], via: "test") != nil)
    }

    @Test func farMoreChatsThanUsualIsRejected() {
        let names = (1...30).map { "Project chat number \($0)" }
        let list = AXNode(role: "AXList", desc: "Chats", kids: names.map { AXNode(role: "AXButton", title: $0) })
        let p = Profile(comma: false, hidden: false, list: NodeMatch(role: "AXList", desc: "Chats"))
        let root = AXNode(role: "AXWindow", kids: [list])
        #expect(ProfileRepair.validate(p, root: root, known: Array(names.prefix(5)), usual: 10, notChats: [], via: "test") == nil)
        #expect(ProfileRepair.validate(p, root: root, known: Array(names.prefix(5)), usual: 25, notChats: [], via: "test") != nil)
    }

    @Test func aSavedLooseProfileIsIgnored() {
        var bad = claude
        bad.list = NodeMatch(role: "AXGroup", classContains: "relative")
        let saved = ProfileBook(version: 4, apps: ["com.anthropic.claudefordesktop": bad], fallback: Profile(), notChats: [])
        #expect(ProfileBook.builtIn.merged(with: saved).profile("com.anthropic.claudefordesktop") == claude)
    }

    @Test func layoutClassesDontDescribeAList() {
        #expect(NodeMatch.describing(AXNode(role: "AXGroup", classes: "relative.chat-list"))?.classContains == "chat-list")
        #expect(NodeMatch.describing(AXNode(role: "AXGroup", classes: "relative.flex")) == nil)
    }

    @Test func controlsAreKnownByName() {
        for c in ["Back", "copy", "Show message actions for Acme audit", "Ran 2 commands", "Screenshot 2026-10-08.png",
                  "New session in Baton", "Used 3 tools", "Remove attachment", "Run in terminal…"] {
            #expect(ProfileBook.isControl(c), "\(c)")
        }
        #expect(!ProfileBook.isControl("Acme audit"))
    }
}

@Suite struct ReaderHealthAuditTests {
    let chats = (1...20).map { ChatRow(name: "Chat \($0)", status: .idle) }

    @Test func archivingMostChatsBecomesTheNewNormal() {
        var h = ReaderHealth()
        h.record("app", rows: chats)
        let few = Array(chats.prefix(2))
        for _ in 0..<(ReaderHealth.steadyToRebaseline - 1) { h.record("app", rows: few) }
        #expect(h.verdict("app") == .blind)
        h.record("app", rows: few)
        #expect(h.verdict("app") == .reading)
        #expect(h.trusted("app"))
        #expect(h.apps["app"]?.usual == 2)
    }

    @Test func anEmptySidebarNeverBecomesNormal() {
        var h = ReaderHealth()
        h.record("app", rows: chats)
        for _ in 0..<30 { h.record("app", rows: []) }
        #expect(h.verdict("app") == .blind)
    }

    @Test func resetForgetsTheUsualCount() {
        var h = ReaderHealth()
        h.record("app", rows: chats)
        h.reset("app")
        #expect(h.apps["app"]?.usual == 0)
        #expect(h.record("app", rows: Array(chats.prefix(2))) == .reading)
        #expect(h.known("app").count == 20)
    }

    @Test func controlsNeverBecomeKnownChats() {
        var h = ReaderHealth()
        let rows = ["Back", "Copy", "Show message actions for Acme audit", "Ran 2 commands", "Acme audit"].map { ChatRow(name: $0, status: .idle) }
        h.record("app", rows: rows)
        #expect(h.known("app") == ["Acme audit"])
    }

    @Test func savedControlsAreDroppedOnLaunch() throws {
        // Saved by an older version: no "steady" field, junk in "known".
        let json = #"{"apps":{"app":{"usual":5,"misses":0,"verdict":"reading","known":["Back","Acme audit","Screenshot 2026-10-08.png"],"lastCount":5}}}"#
        let h = try JSONDecoder().decode(ReaderHealth.self, from: Data(json.utf8)).relaunched()
        #expect(h.known("app") == ["Acme audit"])
        #expect(h.verdict("app") == .unknown)
        #expect(h.apps["app"]?.usual == 5)
    }
}

// MARK: The engine asks Jev again on a heartbeat

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_000_000)
    func now() -> Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t += s } }
}

final class FakeJev: StateClassifier, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [JevAnswer]
    private var seen: [Int] = []
    init(_ answers: [JevAnswer]) { self.answers = answers }

    var stillness: [Int] { lock.withLock { seen } }

    func classify(state: [String: any Sendable]) async throws -> JevAnswer {
        lock.withLock {
            seen.append(state["seconds_without_change"] as? Int ?? -1)
            return answers.isEmpty ? JevAnswer(status: .working, confidence: 0.95) : answers.removeFirst()
        }
    }

    func choose(state: [String: any Sendable], instructions: String, options: [String: String]) async throws -> [String: Double] { [:] }
}

private func waitUntil(_ ok: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await ok() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Suite struct EngineHeartbeatTests {
    @Test func aStillWorkingWindowIsAskedAgainNotAnsweredFromCache() async throws {
        let clock = TestClock()
        let jev = FakeJev([JevAnswer(status: .working, confidence: 0.95), JevAnswer(status: .finished, confidence: 0.95)])
        var config = DetectionEngine.Config()
        config.summaries = false
        let screen = Snapshot(title: "Report", buttons: [], tail: "Here is the draft of the quarterly report so far", nodes: 1, millis: 1)
        let engine = DetectionEngine(classifier: jev, config: config, snapshot: { _ in screen }, now: { clock.now() })
        let me = ProcessInfo.processInfo.processIdentifier
        engine.watch(UUID(), window: AXWindow(element: AXUIElementCreateApplication(me), pid: me, appName: "Test", bundleID: "test", title: "Report"))

        engine.tickForTesting()
        clock.advance(3)
        engine.tickForTesting()                      // settled: asks Jev, which says working
        try await waitUntil { await engine.stats().calls == 1 }
        clock.advance(61)
        engine.tickForTesting()                      // same screen a minute later: the heartbeat asks again
        try await waitUntil { await engine.stats().calls == 2 }
        #expect(await engine.stats().calls == 2)
        // Jev sees how long the screen has stood still, which is what tells it the reply is done.
        #expect(jev.stillness == [3, 64])
    }
}

// MARK: Gemini: one request at a time, and a rest after "too many requests"

final class StubGemini: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hits: [String: Int] = [:]
    nonisolated(unsafe) private static var active: [String: Int] = [:]
    nonisolated(unsafe) private static var peak: [String: Int] = [:]

    static func hits(_ key: String) -> Int { lock.withLock { hits[key] ?? 0 } }
    static func peak(_ key: String) -> Int { lock.withLock { peak[key] ?? 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "key" }?.value ?? ""
        Self.lock.withLock {
            Self.hits[key, default: 0] += 1
            Self.active[key, default: 0] += 1
            Self.peak[key] = max(Self.peak[key] ?? 0, Self.active[key]!)
        }
        let limited = key.hasSuffix("429")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            Self.lock.withLock { Self.active[key, default: 1] -= 1 }
            let body = limited ? #"{"error":{"code":429}}"# : #"{"candidates":[{"content":{"parts":[{"text":"{\"status\":\"working\"}"}]}}]}"#
            let resp = HTTPURLResponse(url: url, statusCode: limited ? 429 : 200, httpVersion: nil,
                                       headerFields: limited ? ["Retry-After": "120"] : [:])!
            self.client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubGemini.self]
        return URLSession(configuration: cfg)
    }
}

@Suite struct SmartGateTests {
    @Test func requestsGoOutOneAtATime() async {
        let key = "serial-\(UUID().uuidString)"
        let smart = Smart(key: key, session: StubGemini.session())
        async let a = smart.classifyStatus(word: "Snoozing", app: "Claude")
        async let b = smart.classifyStatus(word: "Dozing", app: "Claude")
        async let c = smart.classifyStatus(word: "Napping", app: "Claude")
        let all = await [a, b, c]
        #expect(all == [.working, .working, .working])
        #expect(StubGemini.hits(key) == 3)
        #expect(StubGemini.peak(key) == 1)
    }

    @Test func tooManyRequestsRestsTheKey() async {
        let key = "limited-\(UUID().uuidString)-429"
        let smart = Smart(key: key, session: StubGemini.session())
        #expect(await smart.classifyStatus(word: "Snoozing", app: "Claude") == nil)
        #expect(await smart.coolingDown)
        // While resting, calls give up at once without touching the network.
        #expect(await smart.classifyStatus(word: "Dozing", app: "Claude") == nil)
        #expect(await smart.json("{}", maxTokens: 10) == nil)
        #expect(StubGemini.hits(key) == 1)
        // Another key is not held back.
        let other = Smart(key: "free-\(UUID().uuidString)", session: StubGemini.session())
        #expect(await other.classifyStatus(word: "Snoozing", app: "Claude") == .working)
    }
}

/// "/handoff resume" starts as "Handoff resume", then Claude renames it: the task follows the rename.
@Suite struct RenameTests {
    @Test func aRenamedChatIsFollowed() {
        let r = Sidebar.rename(from: ["Acme audit", "Handoff resume", "NEW FEATURES"],
                               to: ["Acme audit", "Baton · Part 4", "NEW FEATURES"])
        #expect(r?.old == "Handoff resume" && r?.new == "Baton · Part 4")
    }

    @Test func twoChatsWithTheSameNameStillCount() {
        // An older "Handoff resume" stays; the new one is renamed.
        let r = Sidebar.rename(from: ["Handoff resume", "Acme audit", "Handoff resume"],
                               to: ["Baton · Part 4", "Acme audit", "Handoff resume"])
        #expect(r?.old == "Handoff resume" && r?.new == "Baton · Part 4")
    }

    @Test func nothingOrTooMuchChangedIsNoRename() {
        #expect(Sidebar.rename(from: ["A chat", "B chat"], to: ["A chat", "B chat"]) == nil)
        #expect(Sidebar.rename(from: ["A chat"], to: ["A chat", "New one"]) == nil)            // a new chat
        #expect(Sidebar.rename(from: ["A chat", "B chat"], to: ["C chat", "D chat"]) == nil)  // two changed
        #expect(Sidebar.rename(from: ["A chat", "B chat"], to: ["A chat", "A chat"]) == nil)  // not a new name
    }

    @Test func folderHeadersAreNotChats() {
        let code = AXNode(role: "AXGroup", kids: [
            AXNode(role: "AXButton", title: "baton"),
            AXNode(role: "AXButton", desc: "New session in baton"),
            AXNode(role: "AXGroup", kids: [
                AXNode(role: "AXButton", title: "Running Baton · Part 4"),
                AXNode(role: "AXPopUpButton", desc: "More options for Baton · Part 4"),
            ]),
        ])
        let read = Sidebar.read(code, bundleID: "com.anthropic.claudefordesktop", book: .builtIn)
        #expect(read.folders == ["baton"])
        #expect(read.rows.map(\.name) == ["Baton · Part 4"])
        #expect(read.names == ["Baton · Part 4"])
    }
}

/// A step running in Claude's conversation ("Running skill /design-shotgun running") reads like a
/// running chat. Chats are only ever listed in the sidebar, so the conversation is skipped.
@Suite struct ClaudeConversationTests {
    init() { _ = Isolated.learned }

    @Test func aRunningStepInTheConversationIsNotAChat() {
        let window = AXNode(role: "AXWindow", kids: [AXNode(role: "AXWebArea", title: "Baton · Part 4 - Claude", kids: [
            AXNode(role: "AXGroup", sub: "AXLandmarkComplementary", desc: "Sidebar", kids: [
                AXNode(role: "AXButton", title: "Running Baton · Part 4"),
            ]),
            AXNode(role: "AXGroup", sub: "AXLandmarkMain", kids: [
                AXNode(role: "AXGroup", sub: "AXApplicationGroup", desc: "Chat messages", kids: [
                    AXNode(role: "AXButton", title: "Running skill /design-shotgun running"),
                ]),
            ]),
        ])])
        let rows = Sidebar.rows(in: window, profile: ProfileBook.builtIn.profile("com.anthropic.claudefordesktop"))
        #expect(rows == [ChatRow(name: "Baton · Part 4", status: .working)])
    }
}

/// Cursor shows a running agent with a spinner Accessibility can't see: its row has no status icon,
/// while every finished one says "Completed". So no icon means working. The Pin / Archive buttons
/// beside rows and "More" are not chats.
@Suite struct CursorRunningRowTests {
    init() { _ = Isolated.learned }

    func row(_ name: String, icon: String?, pin: String = "Pin") -> AXNode {
        AXNode(role: "AXGroup", classes: "ui-sidebar-menu-item", kids: [
            AXNode(role: "AXGroup", classes: "ui-sidebar-menu-button", kids: [
                AXNode(role: "AXGroup", classes: "ui-sidebar-menu-button-icon-wrapper",
                       kids: icon.map { [AXNode(role: "AXImage", desc: $0)] } ?? []),
                AXNode(role: "AXButton", title: name),
                AXNode(role: "AXGroup", kids: [AXNode(role: "AXStaticText", value: "1m"),
                                               AXNode(role: "AXButton", desc: pin), AXNode(role: "AXButton", desc: "Archive")]),
            ]),
        ])
    }

    @Test func aRunningAgentWithoutAnIconIsStillListed() {
        let window = AXNode(role: "AXWindow", kids: [AXNode(role: "AXList", sub: "AXContentList", classes: "ui-sidebar-menu", kids: [
            row("Acme.dev rebranding", icon: "Completed", pin: "Unpin"),
            row("Search console verification", icon: "Completed, unread"),
            row("Daily digest cron workflow", icon: nil),
            AXNode(role: "AXGroup", kids: [AXNode(role: "AXButton", title: "More")]),
        ])])
        let rows = Sidebar.rows(in: window, profile: ProfileBook.builtIn.profile("com.todesktop.230313mzl4w4u92"))
        #expect(rows == [ChatRow(name: "Acme.dev rebranding", status: .idle),
                         ChatRow(name: "Search console verification", status: .unread),
                         ChatRow(name: "Daily digest cron workflow", status: .working)])
    }
}

/// Claude's tab button says "awaiting your input" when a session in the hidden tab waits on you.
@Suite struct AwaitingYourInputTests {
    init() { _ = Isolated.learned }

    @Test func theYourFormsMeanNeedsInput() {
        #expect(Sidebar.Section(name: "Code", selected: false, activity: "awaiting your input").status == .needsInput)
        #expect(Sidebar.parse(label: "Awaiting your input Acme audit", profile: ProfileBook.builtIn.profile("com.anthropic.claudefordesktop"))
                == ChatRow(name: "Acme audit", status: .needsInput))
    }
}

/// Reading a window copies its whole tree, one Accessibility call per element; in Claude most of those are
/// the conversation, which nothing reads. Its messages are left out of the copy, and the read is the same.
@Suite struct PruneTests {
    init() { _ = Isolated.learned }
    let claude = "com.anthropic.claudefordesktop"

    @Test func claudesMessagesAreNotCopiedAndNothingIsLost() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/claude.json")
        let root = try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
        let prune = try #require(ProfileBook.builtIn.profile(claude).prune)
        let small = root.pruned(prune)
        #expect(small.count * 2 < root.count)   // 448 elements → 174
        let full = Sidebar.read(root, bundleID: claude, book: .builtIn)
        let cut = Sidebar.read(small, bundleID: claude, book: .builtIn)
        #expect(cut.rows == full.rows && cut.names == full.names && cut.folders == full.folders)
        #expect(cut.openName == full.openName && cut.generating == full.generating && cut.sections == full.sections)
        #expect(!full.rows.isEmpty && full.openName == "Handoff resume")
    }

    @Test func theStopButtonBesideTheMessagesIsStillSeen() {
        let window = AXNode(role: "AXWindow", kids: [AXNode(role: "AXWebArea", title: "Fix login - Claude", kids: [
            AXNode(role: "AXGroup", sub: "AXLandmarkComplementary", desc: "Sidebar", kids: [
                AXNode(role: "AXGroup", kids: [AXNode(role: "AXButton", title: "Running Other chat")]),
            ]),
            AXNode(role: "AXGroup", sub: "AXLandmarkMain", kids: [
                AXNode(role: "AXGroup", sub: "AXApplicationGroup", desc: "Chat messages", kids: [
                    AXNode(role: "AXGroup", kids: [AXNode(role: "AXButton", title: "Edited Fix login")]),
                ]),
                AXNode(role: "AXGroup", kids: [AXNode(role: "AXTextArea", desc: "Prompt"), AXNode(role: "AXButton", desc: "Stop")]),
            ]),
        ])])
        let small = window.pruned(ProfileBook.builtIn.profile(claude).prune)
        let read = Sidebar.read(small, bundleID: claude, book: .builtIn)
        #expect(read.openName == "Fix login" && read.generating)
        #expect(read.rows == [ChatRow(name: "Other chat", status: .working)])
        // A step in the conversation ("Edited Fix login") is no longer taken for a status word to learn.
        #expect(Sidebar.unknownStatusWord(for: "Fix login", in: window) == "Edited")
        #expect(Sidebar.unknownStatusWord(for: "Fix login", in: small) == nil)
    }
}

/// A reply's bullet list in Cursor is an AXContentList too, and its links have no status icon: they
/// were read as running chats ("https://example.com/internships"). Only the sidebar's lists count.
@Suite struct CursorReplyListTests {
    init() { _ = Isolated.learned }

    @Test func linksInAReplyAreNotChats() {
        let reply = AXNode(role: "AXGroup", classes: "agent-panel", kids: [
            AXNode(role: "AXList", sub: "AXContentList", classes: "ui-markdown__list", kids: [
                AXNode(role: "AXGroup", kids: [AXNode(role: "AXButton", title: "https://example.com/internships")]),
            ]),
        ])
        let sidebar = AXNode(role: "AXList", sub: "AXContentList", classes: "ui-sidebar-menu", kids: [
            AXNode(role: "AXGroup", kids: [AXNode(role: "AXButton", title: "Search console verification")]),
        ])
        let window = AXNode(role: "AXWindow", kids: [sidebar, reply])
        let rows = Sidebar.rows(in: window, profile: ProfileBook.builtIn.profile("com.todesktop.230313mzl4w4u92"))
        #expect(rows.map(\.name) == ["Search console verification"])
    }
}
