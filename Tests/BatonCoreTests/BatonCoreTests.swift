import CoreGraphics
import Foundation
import Testing
@testable import BatonCore

@Suite struct HysteresisTests {
    let h = Hysteresis()

    @Test func confidentFinishFlips() {
        let d = h.decide(current: .working, candidate: nil, answer: JevAnswer(status: .finished, confidence: 0.91))
        #expect(d == .flip(.finished))
    }

    @Test func unsureFinishWaitsForASecondAnswer() {
        let first = h.decide(current: .working, candidate: nil, answer: JevAnswer(status: .finished, confidence: 0.7))
        #expect(first == .recheck(after: 3, candidate: .finished))
        let second = h.decide(current: .working, candidate: .finished, answer: JevAnswer(status: .finished, confidence: 0.7))
        #expect(second == .flip(.finished))
    }

    @Test func needsYouFlipsEarly() {
        #expect(h.decide(current: .working, candidate: nil, answer: JevAnswer(status: .needsYou, confidence: 0.62)) == .flip(.needsYou))
    }

    @Test func veryUnsureLooksAgainLater() {
        // the Grok Bot miss from the first probe run: 0.33 used to be dropped
        #expect(h.decide(current: .unknown, candidate: nil, answer: JevAnswer(status: .working, confidence: 0.33)) == .recheck(after: 5, candidate: nil))
    }

    @Test func sameStateKeeps() {
        #expect(h.decide(current: .finished, candidate: nil, answer: JevAnswer(status: .finished, confidence: 0.2)) == .keep)
    }
}

@Suite struct TaskStateTests {
    @Test func needsYouBeatsEverything() {
        #expect(WindowState.combine([.finished, .working, .needsYou]) == .needsYou)
        #expect(WindowState.combine([.finished, .working]) == .working)
        #expect(WindowState.combine([]) == .unknown)
    }
}

@Suite struct RedactTests {
    @Test func stripsSecrets() {
        let s = Redact.clean("mail jean@example.com key sk-abc123def456ghi789 call +49 151 2345 6789")
        #expect(!s.contains("example.com"))
        #expect(!s.contains("sk-abc123"))
        #expect(!s.contains("2345"))
    }

    @Test func keepsNormalText() {
        #expect(Redact.clean("Claude saved 15 programs to accelerators.md") == "Claude saved 15 programs to accelerators.md")
    }
}

@Suite struct RulesTests {
    func snap(buttons: [String] = [], tail: String = "") -> Snapshot {
        Snapshot(title: "t", buttons: buttons, tail: tail, nodes: 1, millis: 1)
    }

    @Test func stopButtonMeansWorking() { #expect(Rules.working(snap(buttons: ["Stop"]), changedTicks: 0) != nil) }
    @Test func statusLineMeansWorking() { #expect(Rules.working(snap(tail: "… 3:28 AM Planner is working"), changedTicks: 0) != nil) }
    @Test func streamingMeansWorking() { #expect(Rules.working(snap(), changedTicks: 3) != nil) }
    @Test func switchingChatsIsAContextSwitch() {
        let a = "Here are the role descriptions for the operations lead position including responsibilities requirements salary range reporting lines hiring timeline interview stages onboarding plan and probation period expectations for candidates"
        let b = "Graduation portrait prompt ideas golden hour campus steps cap and gown bokeh background natural smile parents hugging confetti throw diploma closeup black and white candid moments soft light"
        #expect(Rules.isContextSwitch(old: a, new: b))
        #expect(!Rules.isContextSwitch(old: a, new: a + " and a note about relocation support and remote days"))
    }

    @Test func quietWindowIsNotRuledWorking() { #expect(Rules.working(snap(buttons: ["Copy"], tail: "Here you go."), changedTicks: 0) == nil) }
}

@Suite struct JevParsingTests {
    @Test func parsesRecordedResponse() throws {
        let raw = #"{"model":"jev-1.13.0","answers":{"status":{"type":"choice","choice":"ai_finished","confidence":0.85,"probabilities":{"idle":0.02,"ai_working":0.07,"ai_finished":0.89,"needs_you":0.02}},"asks_you":{"type":"noul","noul":0.97}},"usage":{"input_tokens":524,"output_tokens":69}}"#
        let json = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let a = try Jev.parseStatus(json, millis: 240)
        #expect(a.status == .finished)
        #expect(a.confidence == 0.85)
        #expect(a.asksYou == 0.97)
        #expect(a.inputTokens == 524)
    }
}

@Suite struct SummarizerTests {
    @Test func rejectsEchoedInstructions() {
        #expect(Summarizer.echoesInstructions("Describe the concrete result using only facts"))
        #expect(!Summarizer.echoesInstructions("Cursor rewrote meta titles for 14 routes"))
    }
}

@Suite struct NotchGeometryTests {
    // 14" MacBook Pro at default scaling: 1512×982 points, notch about 185 pt wide, 32 pt tall
    let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func hardwareNotch() {
        let g = NotchGeometry.make(frame: builtIn, visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950), safeAreaTop: 32,
                                   auxLeft: CGRect(x: 0, y: 950, width: 663, height: 32), auxRight: CGRect(x: 849, y: 950, width: 663, height: 32), scale: 2)
        #expect(g.kind == .hardware)
        #expect(g.rect == CGRect(x: 663, y: 950, width: 186, height: 32))
    }

    @Test func externalToTheLeftWithNegativeX() {
        // BenQ 1080p at 1x placed left of the MacBook
        let f = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let g = NotchGeometry.make(frame: f, visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055), safeAreaTop: 0, auxLeft: nil, auxRight: nil, scale: 1)
        #expect(g.kind == .virtual)
        #expect(abs(g.rect.midX - f.midX) <= 1)  // centred, give or take pixel rounding
        #expect(g.rect.height == 25)
        #expect(g.rect.maxY == 1080)
    }

    @Test func externalAboveTheMacBook() {
        let f = CGRect(x: -200, y: 982, width: 1920, height: 1080)
        let g = NotchGeometry.make(frame: f, visibleFrame: CGRect(x: -200, y: 982, width: 1920, height: 1055), safeAreaTop: 0, auxLeft: nil, auxRight: nil, scale: 1)
        #expect(g.rect.maxY == f.maxY)
    }

    @Test func autoHiddenMenuBarUsesLip() {
        let f = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let g = NotchGeometry.make(frame: f, visibleFrame: f, safeAreaTop: 0, auxLeft: nil, auxRight: nil, scale: 1)
        #expect(g.kind == .lip)
        #expect(g.rect.height == NotchGeometry.lipHeight)
    }
}


@Suite struct SidebarTests {
    init() { _ = Isolated.learned }

    @Test func claudeLeadingStatus() {
        #expect(Sidebar.parse(label: "Running Northwind task tracking LLM", profile: ProfileBook.builtIn.profile("com.anthropic.claudefordesktop")) == ChatRow(name: "Northwind task tracking LLM", status: .working))
        #expect(Sidebar.parse(label: "Idle Archive past Claude sessions", profile: ProfileBook.builtIn.profile("com.anthropic.claudefordesktop")) == ChatRow(name: "Archive past Claude sessions", status: .idle))
        #expect(Sidebar.parse(label: "Unread response Northwind task tracking LLM", profile: ProfileBook.builtIn.profile("com.anthropic.claudefordesktop")) == ChatRow(name: "Northwind task tracking LLM", status: .unread))
    }

    @Test func grokCommaStatus() {
        #expect(Sidebar.parse(label: "Planner, Main Bot, Unread activity", profile: ProfileBook.builtIn.profile("com.anysphere.sand")) == ChatRow(name: "Planner", status: .unread))
    }

    @Test func chatGPTHiddenLabel() {
        #expect(Sidebar.parse(label: "Resume onboarding flow prototype", hiddenLabels: ["Unread"], profile: ProfileBook.builtIn.profile("com.openai.codex")) == ChatRow(name: "Resume onboarding flow prototype", status: .unread))
    }

    @Test func cursorCompletedMeansQuiet() {
        let o = ProfileBook.builtIn.profile("com.todesktop.230313mzl4w4u92").overrides
        #expect(Sidebar.status(of: "Completed,", overrides: o) == .idle)
        #expect(Sidebar.status(of: "Running", overrides: o) == .working)
        #expect(Sidebar.status(of: "Completed, unread", overrides: o) == .unread)
        #expect(Sidebar.status(of: "Working…", overrides: o) == .working)
        #expect(Sidebar.status(of: "Running agent", overrides: o) == .working)
    }

    @Test func ordinaryButtonsAreNotChats() {
        #expect(Sidebar.parse(label: "New chat", profile: ProfileBook.builtIn.fallback) == nil)
        #expect(Sidebar.parse(label: "Plan a team offsite day", profile: ProfileBook.builtIn.fallback) == nil)
        #expect(Sidebar.parse(label: "Running", profile: ProfileBook.builtIn.fallback) == nil)
        #expect(Sidebar.parse(label: "Finished 47", profile: ProfileBook.builtIn.profile("com.anthropic.claudefordesktop")) == nil)
        #expect(Sidebar.parse(label: "Working Landing hero v2", profile: ProfileBook.builtIn.profile("com.anthropic.claudefordesktop")) == nil)
        // Cursor: transcript headers like "Finished 2 subagents" are not chats
        #expect(Sidebar.parse(label: "Finished 2 subagents", profile: ProfileBook.builtIn.profile("com.todesktop.230313mzl4w4u92")) == nil)
        // Browsers and terminals: a "Running …" button on a page is not a chat
        #expect(Sidebar.parse(label: "Running tests in CI", profile: ProfileBook.builtIn.profile("com.google.Chrome")) == nil)
    }

    @Test func findsTruncatedNames() {
        let rows = [ChatRow(name: "Northwind task tracking LLM", status: .working)]
        #expect(Sidebar.find("northwind task tracking llm", in: rows) != nil)
        // A shorter name is another chat unless the app cut the row's name short.
        #expect(Sidebar.find("Northwind task tracking", in: rows) == nil)
        #expect(Sidebar.find("Northwind task tracking LLM", in: [ChatRow(name: "Northwind task tra…", status: .idle)]) != nil)
        #expect(Sidebar.find("Northwind task tra...", in: rows) != nil)
    }

    @Test func aShorterNameIsAnotherChat() {
        let rows = [ChatRow(name: "Refactor auth middleware", status: .working)]
        #expect(Sidebar.find("Refactor auth", in: rows) == nil)
        #expect(Sidebar.find("Refactor auth middleware", in: [ChatRow(name: "Refactor auth", status: .idle)]) == nil)
        #expect(Sidebar.find("Refactor auth middleware", in: [ChatRow(name: "Refactor auth midd…", status: .idle)]) != nil)
        // Too little left before the ellipsis to say which chat it is.
        #expect(Sidebar.find("Refactor auth middleware", in: [ChatRow(name: "Refac…", status: .idle)]) == nil)
    }

    let chatGPT = ProfileBook.builtIn.profile("com.openai.codex")

    @Test func aRowsOwnTitleIsNotItsStatus() {
        #expect(Sidebar.parse(label: "Thinking about pricing", hiddenLabels: ["Thinking about pricing"], profile: chatGPT) == nil)
        #expect(Sidebar.parse(label: "Pricing ideas", hiddenLabels: ["Pricing"], profile: chatGPT) == nil)
        // Hidden labels must be whole status words: no "Thinking …" prefix reading.
        #expect(Sidebar.parse(label: "Pricing ideas", hiddenLabels: ["Thinking about it"], profile: chatGPT) == nil)
        #expect(Sidebar.parse(label: "Pricing ideas", hiddenLabels: ["Thinking"], profile: chatGPT) == ChatRow(name: "Pricing ideas", status: .working))
    }

    @Test func aChatTitledLikeAStatusReadsAsQuiet() {
        func row(_ name: String, _ kids: [AXNode]) -> AXNode { AXNode(role: "AXButton", title: name, kids: kids) }
        let list = AXNode(role: "AXList", sub: "AXContentList", kids: [
            row("Thinking about pricing", [AXNode(role: "AXStaticText", value: "Thinking about pricing")]),
            row("Busy week planning", [AXNode(role: "AXBusyIndicator")]),
        ])
        let rows = Sidebar.rows(in: AXNode(role: "AXWindow", kids: [list]), profile: chatGPT)
        #expect(rows.contains(ChatRow(name: "Thinking about pricing", status: .idle)))
        // A spinner still says working, even when "busy" is part of the name.
        #expect(rows.contains(ChatRow(name: "Busy week planning", status: .working)))
    }

    @Test func newlyLearnedWordsReachTheParser() {
        let claude = ProfileBook.builtIn.profile("com.anthropic.claudefordesktop")
        #expect(Sidebar.parse(label: "Percolating Acme audit", profile: claude) == nil)
        LearnedStatus.shared.learn("Percolating", .working)
        #expect(Sidebar.parse(label: "Percolating Acme audit", profile: claude) == ChatRow(name: "Acme audit", status: .working))
    }

    @Test func openChatComesFromTheSameRead() {
        let root = AXNode(role: "AXWindow", kids: [
            AXNode(role: "AXGroup", kids: [AXNode(role: "AXWebArea", title: "Acme audit - Claude")]),
            AXNode(role: "AXButton", desc: "Stop response"),
        ])
        let r = Sidebar.read(root, bundleID: "com.anthropic.claudefordesktop", truncated: true)
        #expect(r.openName == "Acme audit")
        #expect(r.generating)
        #expect(r.truncated)
        #expect(Sidebar.read(root, bundleID: "com.example.notes").openName == nil)
    }
}

/// The user's own learned words (learned-status.json) must not change what tests read. Runs once.
enum Isolated {
    static let learned: Void = LearnedStatus.shared.resetForTesting()
}

// MARK: Sidebars from saved windows (BatonProbe capture <n> <file>)

private func fixture(_ name: String) throws -> AXNode {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name).json")
    return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
}

private func read(_ name: String, _ bundleID: String) throws -> [ChatRow] {
    Sidebar.rows(in: try fixture(name), profile: ProfileBook.builtIn.profile(bundleID))
}

@Suite struct SidebarFixtureTests {
    init() { _ = Isolated.learned }

    @Test func chatGPTListsChatsNotFolders() throws {
        let rows = try read("chatgpt", "com.openai.codex")
        #expect(rows.count >= 40)
        #expect(rows.contains(ChatRow(name: "Resume onboarding flow prototype", status: .unread)))
        for fake in ["NORTH STUDIO", "BLUE ADS", "Side Project", "Newsletter", "Show more"] {
            #expect(!rows.contains { $0.name == fake }, "\(fake) is a folder or control")
        }
        #expect(!rows.contains { $0.name.hasPrefix("Start new chat in") })
    }

    @Test func grokListsBotsNotSections() throws {
        let rows = try read("grok", "com.anysphere.sand")
        #expect(rows.contains(ChatRow(name: "Mail Desk", status: .unread)))
        #expect(rows.contains { $0.name == "Planner" })
        for header in ["Ops", "Dev", "Unassigned"] { #expect(!rows.contains { $0.name == header }) }
    }

    @Test func claudeAndCursorStillRead() throws {
        #expect(try read("claude", "com.anthropic.claudefordesktop").count >= 3)
        let cursor = try read("cursor", "com.todesktop.230313mzl4w4u92")
        #expect(cursor.count >= 10)
        #expect(!cursor.contains { $0.name.hasPrefix("Finished") })
    }
}

// MARK: When an app update breaks a profile

@Suite struct RepairTests {
    init() { _ = Isolated.learned }

    /// What an app update looks like: the list moved and the status labels changed shape.
    func broken(_ p: Profile) -> Profile {
        var b = p
        b.list = NodeMatch(role: "AXList", desc: "Old chat list")
        b.comma = false
        b.hidden = false
        return b
    }

    @Test(arguments: [("chatgpt", "com.openai.codex"), ("grok", "com.anysphere.sand")])
    func listSearchRecoversABrokenProfile(app: (String, String)) throws {
        let root = try fixture(app.0)
        let good = ProfileBook.builtIn.profile(app.1)
        let truth = Sidebar.rows(in: root, profile: good)
        #expect(Sidebar.rows(in: root, profile: broken(good)).count < truth.count / 3)
        let o = try #require(ProfileRepair.findList(root: root, current: broken(good), known: truth.map(\.name),
                                                     usual: truth.count, notChats: ProfileBook.builtIn.notChats))
        #expect(o.knownFound == truth.count)
        // Statuses come back too, not just names.
        for r in truth where r.status != .idle { #expect(o.rows.contains(r)) }
    }

    @Test func statusWordsInFrontOfNamesAreRelearned() throws {
        let root = try fixture("claude")
        let good = ProfileBook.builtIn.profile("com.anthropic.claudefordesktop")
        let truth = Sidebar.rows(in: root, profile: good)
        var broken = good
        broken.leading = []
        #expect(Sidebar.rows(in: root, profile: broken).isEmpty)
        let o = try #require(ProfileRepair.findList(root: root, current: broken, known: truth.map(\.name),
                                                     usual: truth.count, notChats: ProfileBook.builtIn.notChats))
        #expect(Set(o.rows) == Set(truth))
    }

    @Test func aBadGuessIsRejected() throws {
        let root = try fixture("chatgpt")
        let known = Sidebar.rows(in: root, profile: ProfileBook.builtIn.profile("com.openai.codex")).map(\.name)
        // Every button in the window as a chat: lots of rows, few known chats.
        let loose = Profile(comma: false, hidden: false, list: NodeMatch(role: "AXWindow"))
        let tight = Profile(list: NodeMatch(role: "AXList", desc: "Nothing"))
        #expect(ProfileRepair.validate(tight, root: root, known: known, usual: known.count, notChats: [], via: "test") == nil)
        if let o = ProfileRepair.validate(loose, root: root, known: known, usual: known.count, notChats: [], via: "test") {
            #expect(ProfileRepair.best([o], known: known).map { $0.rows.count > known.count } == true)
        }
    }

    @Test func outlineLeavesOutLongText() throws {
        let text = ProfileRepair.outline(AXNode(role: "AXGroup", kids: [
            AXNode(role: "AXStaticText", value: String(repeating: "private conversation ", count: 5)),
            AXNode(role: "AXButton", title: "My chat")
        ]))
        #expect(text.contains("title=My chat"))
        #expect(!text.contains("private conversation"))
    }
}

@Suite struct ProfileTests {
    @Test func shortJSONFillsDefaults() throws {
        let p = try JSONDecoder().decode(Profile.self, from: Data(#"{"list": {"role": "AXList", "sub": "AXContentList"}}"#.utf8))
        #expect(p.comma && p.hidden && !p.icon)
        #expect(p.list == NodeMatch(role: "AXList", subrole: "AXContentList"))
    }

    @Test func savedProfilesReplaceBuiltInOnes() throws {
        let saved = ProfileBook(version: 3, apps: ["com.openai.chat": Profile(comma: true)], fallback: Profile(), notChats: ["archive"])
        let book = ProfileBook.builtIn.merged(with: saved)
        #expect(book.profile("com.openai.chat").comma)
        #expect(book.profile("com.anysphere.sand") == ProfileBook.builtIn.profile("com.anysphere.sand"))
        #expect(book.notChats.contains("archive") && book.notChats.contains("show more"))
        let round = try JSONDecoder().decode(ProfileBook.self, from: JSONEncoder().encode(book))
        #expect(round == book)
    }
}

@Suite struct ReaderHealthTests {
    let chats = (1...20).map { ChatRow(name: "Chat \($0)", status: .idle) }

    @Test func emptyReadsGoBlindAfterThreePolls() {
        var h = ReaderHealth()
        #expect(h.record("app", rows: chats) == .reading)
        #expect(h.record("app", rows: []) == .reading)
        #expect(h.record("app", rows: []) == .reading)
        #expect(h.record("app", rows: []) == .blind)
        #expect(h.record("app", rows: chats) == .reading)
    }

    @Test func aFewChatsWhenThereAreUsuallyManyIsAMiss() {
        var h = ReaderHealth()
        h.record("app", rows: chats)
        for _ in 0..<3 { h.record("app", rows: Array(chats.prefix(2))) }
        #expect(h.verdict("app") == .blind)
        // Deleting a few chats is normal.
        var g = ReaderHealth()
        g.record("app", rows: chats)
        for _ in 0..<5 { g.record("app", rows: Array(chats.prefix(15))) }
        #expect(g.verdict("app") == .reading)
    }

    @Test func remembersKnownChatsForRepairs() {
        var h = ReaderHealth()
        h.record("app", rows: chats)
        #expect(h.known("app").count == 20)
        h.record("app", rows: [])
        #expect(h.known("app").count == 20)
    }
}

@Suite struct ReaderTrustTests {
    @Test func onlyANormalReadIsTrusted() {
        var h = ReaderHealth()
        let chats = (1...10).map { ChatRow(name: "Chat \($0)", status: .idle) }
        #expect(!h.trusted("app"))
        h.record("app", rows: chats)
        #expect(h.trusted("app"))
        // The very first miss already stops "missing means quiet", before the app counts as blind.
        h.record("app", rows: [])
        #expect(!h.trusted("app"))
    }
}

@Suite struct TaskTreeTests {
    func task(_ t: String) -> BatonTask { BatonTask(title: t, windows: []) }

    @Test func groupingTwoTasksMakesABigTask() {
        var tasks = [task("Acme rebrand"), task("Acme audit")]
        let (a, b) = (tasks[0].id, tasks[1].id)
        TaskTree.group(&tasks, b, with: a)
        let g = tasks.first(where: \.isGroup)
        #expect(g?.title == "Acme rebrand")
        let kids: Set<UUID> = Set(tasks.filter { $0.parentID == g?.id }.map(\.id))
        #expect(kids == Set([a, b]))
        #expect(tasks.count == 3)
    }

    @Test func addingToASubtaskJoinsItsBigTask() {
        var tasks = [task("A"), task("B"), task("C")]
        let (a, b, c) = (tasks[0].id, tasks[1].id, tasks[2].id)
        TaskTree.group(&tasks, b, with: a)
        TaskTree.group(&tasks, c, with: b)
        let g = tasks.first(where: \.isGroup)!
        #expect(tasks.filter { $0.parentID == g.id }.count == 3)
        #expect(tasks.filter(\.isGroup).count == 1)
    }

    @Test func emptyBigTaskGoesAway() {
        var tasks = [task("A"), task("B")]
        let (a, b) = (tasks[0].id, tasks[1].id)
        TaskTree.group(&tasks, b, with: a)
        TaskTree.ungroup(&tasks, a)
        #expect(tasks.filter(\.isGroup).count == 1)   // B still inside
        TaskTree.ungroup(&tasks, b)
        #expect(tasks.filter(\.isGroup).isEmpty)
        #expect(tasks.allSatisfy { $0.parentID == nil })
    }

    @Test func mergingBigTasks() {
        var tasks = [task("A"), task("B"), task("C"), task("D")]
        let ids = tasks.map(\.id)
        TaskTree.group(&tasks, ids[1], with: ids[0])
        TaskTree.group(&tasks, ids[3], with: ids[2])
        let g2 = tasks.first { $0.isGroup && $0.title == "C" }!.id
        let g1 = tasks.first { $0.isGroup && $0.title == "A" }!.id
        TaskTree.group(&tasks, g2, with: g1)
        #expect(tasks.filter(\.isGroup).map(\.id) == [g1])
        #expect(tasks.filter { $0.parentID == g1 }.count == 4)
    }

    @Test func makeBigTaskFromOneTask() {
        var tasks = [task("Pitch deck"), task("Other")]
        let a = tasks[0].id
        let g = TaskTree.makeGroup(&tasks, from: a)
        #expect(tasks.count == 3)
        #expect(tasks[0].id == g && tasks[0].isGroup && tasks[0].title == "Pitch deck")
        #expect(tasks.first { $0.id == a }?.parentID == g)
        // Again on the subtask, or on the big task itself: nothing new.
        #expect(TaskTree.makeGroup(&tasks, from: a) == g)
        #expect(TaskTree.makeGroup(&tasks, from: g!) == g)
        #expect(tasks.filter(\.isGroup).count == 1)
    }

    @Test func addUnderABigTask() {
        var tasks = [task("A")]
        let g = TaskTree.makeGroup(&tasks, from: tasks[0].id)!
        let new = task("B")
        TaskTree.add(&tasks, new, under: g)
        #expect(tasks.last?.id == new.id && tasks.last?.parentID == g)
        // Not a big task (a plain task, or gone): it lands on its own.
        let loose = task("C")
        TaskTree.add(&tasks, loose, under: new.id)
        #expect(tasks.last?.parentID == nil)
        TaskTree.add(&tasks, task("D"), under: UUID())
        #expect(tasks.last?.parentID == nil)
    }

    @Test func moveBetweenBigTasks() {
        var tasks = [task("A"), task("B")]
        let (a, b) = (tasks[0].id, tasks[1].id)
        let g1 = TaskTree.makeGroup(&tasks, from: a)!
        let g2 = TaskTree.makeGroup(&tasks, from: b)!
        TaskTree.move(&tasks, a, under: g2)
        #expect(tasks.first { $0.id == a }?.parentID == g2)
        #expect(!tasks.contains { $0.id == g1 })   // left empty, gone
        // Onto a plain task or a big task onto another: ignored.
        TaskTree.move(&tasks, a, under: b)
        #expect(tasks.first { $0.id == a }?.parentID == g2)
        let loose = task("C"); tasks.append(loose)
        TaskTree.move(&tasks, loose.id, under: g2)
        #expect(tasks.filter { $0.parentID == g2 }.count == 3)
    }

    @Test func ungroupAllKeepsTheTasks() {
        var tasks = [task("A"), task("B"), task("C")]
        let ids = tasks.map(\.id)
        TaskTree.group(&tasks, ids[1], with: ids[0])
        let g = tasks.first(where: \.isGroup)!.id
        TaskTree.ungroupAll(&tasks, g)
        #expect(tasks.map(\.id) == ids)
        #expect(tasks.allSatisfy { $0.parentID == nil && !$0.isGroup })
        // A plain task's id does nothing.
        TaskTree.ungroupAll(&tasks, ids[0])
        #expect(tasks.count == 3)
    }

    @Test func oldTaskFilesStillLoad() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Old","windows":[]}]"#
        let t = try JSONDecoder().decode([BatonTask].self, from: Data(json.utf8))
        #expect(t.first?.parentID == nil && t.first?.isGroup == false)
    }
}

@Suite struct ClaudeStatusTests {
    init() { _ = Isolated.learned }

    @Test func awaitingInputNeedsYou() {
        #expect(Sidebar.parse(label: "Awaiting input Acme project audit against handoff", bundleID: "com.anthropic.claudefordesktop")
                == ChatRow(name: "Acme project audit against handoff", status: .needsInput))
    }
}

@Suite struct UnknownStatusTests {
    init() { _ = Isolated.learned }

    func row(_ title: String) -> AXNode { AXNode(role: "AXGroup", kids: [AXNode(role: "AXButton", title: title)]) }

    @Test func findsTheWordInFrontOfTheName() {
        #expect(Sidebar.unknownStatusWord(for: "Acme audit", in: row("Snoozing Acme audit")) == "Snoozing")
        // tags after the name are not statuses
        #expect(Sidebar.unknownStatusWord(for: "Planner", in: row("Planner, Main Bot")) == nil)
    }

    @Test func nameAloneOrKnownWordIsNotUnknown() {
        #expect(Sidebar.unknownStatusWord(for: "Acme audit", in: row("Acme audit")) == nil)
        #expect(Sidebar.unknownStatusWord(for: "Acme audit", in: row("Running Acme audit")) == nil)
    }

    @Test func learnedWordsAreRemembered() {
        let store = LearnedStatus(url: nil)
        store.learn("Snoozing", .idle)
        #expect(store.status(of: "snoozing") == .idle)
    }
}

/// Claude's chat tab, shaped like the real one: a row is a button with "More options for <name>" beside
/// it and, when there's something to say, a status element ("Unread response").
@Suite struct ClaudeChatTabTests {
    init() { _ = Isolated.learned }

    func chatRow(_ name: String, status: String? = nil) -> AXNode {
        var kids = [AXNode(role: "AXButton", title: name, kids: [AXNode(role: "AXStaticText", value: name)])]
        if let status { kids.append(AXNode(role: "AXGroup", sub: "AXApplicationStatus", desc: status)) }
        kids.append(AXNode(role: "AXGroup", kids: [AXNode(role: "AXPopUpButton", desc: "More options for \(name)")]))
        return AXNode(role: "AXGroup", kids: kids)
    }
    var window: AXNode {
        AXNode(role: "AXWindow", kids: [
            AXNode(role: "AXRadioGroup", desc: "Mode", kids: [
                AXNode(role: "AXRadioButton", desc: "Claude", value: "1"),
                AXNode(role: "AXRadioButton", desc: "Code, working", value: "0"),
            ]),
            AXNode(role: "AXButton", title: "Projects"),
            AXNode(role: "AXGroup", kids: [AXNode(role: "AXButton", title: "Artifacts"),
                                           AXNode(role: "AXPopUpButton", desc: "New from a template")]),
            chatRow("Shirt sales outreach", status: "Unread response"),
            chatRow("Recovering a chat"),
            chatRow("Pricing copy", status: "Snoozing"),
            chatRow("Morning brief setup", status: "Running"),   // the orange dot while a chat answers
        ])
    }

    @Test func readsChatTabRows() {
        let rows = Sidebar.rows(in: window, profile: ProfileBook.builtIn.profile("com.anthropic.claudefordesktop"))
        #expect(rows.contains(ChatRow(name: "Shirt sales outreach", status: .unread)))
        #expect(rows.contains(ChatRow(name: "Recovering a chat", status: .idle)))
        #expect(rows.contains(ChatRow(name: "Morning brief setup", status: .working)))
        #expect(!rows.contains { $0.name == "Projects" || $0.name == "Artifacts" })
        // an unknown status isn't guessed; it's left for learning
        #expect(!rows.contains { $0.name == "Pricing copy" })
        #expect(Sidebar.unknownStatusWord(for: "Pricing copy", in: window) == "Snoozing")
    }

    @Test func readsTabs() {
        let tabs = Sidebar.sections(in: window)
        #expect(tabs.map(\.name) == ["Claude", "Code"])
        #expect(tabs.first?.selected == true)
        #expect(tabs.last?.status == .working)
    }
}
