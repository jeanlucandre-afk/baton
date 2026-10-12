import Foundation
import Testing
@testable import BatonCore

/// /handoff continues a chat in a new one ("Baton · Part 5" → "Baton · Part 6"): its task moves on.
@Suite struct HandoffTests {
    let claude = "com.anthropic.claudefordesktop"
    func chat(_ name: String, _ section: String? = "Code") -> ChatRecord {
        ChatRecord(bundleID: claude, appName: "Claude", name: name, section: section)
    }
    func task(_ title: String, chat name: String?) -> BatonTask {
        var t = BatonTask(title: title, windows: [])
        t.chat = name.map { chat($0) }
        return t
    }

    @Test func namesAreRead() {
        #expect(Handoff.parse("Baton · Part 6 — screen test")! == ("baton", 6))
        #expect(Handoff.parse("Acme · Part 2")! == ("acme", 2))
        #expect(Handoff.parse("Big · Idea · Part 3")! == ("big · idea", 3))
        #expect(Handoff.parse("Handoff resume") == nil)
        #expect(Handoff.parse("Partly cloudy") == nil)
    }

    @Test func theTaskMovesToTheNewChat() {
        var old = task("baton", chat: "Baton · Part 4 — screen test")
        old.next = "Send works"
        var tasks = [old, task("Acme", chat: "Acme · Part 2")]
        #expect(Handoff.follow(&tasks, newChat: chat("Baton · Part 5 — big tasks")) == "Baton · Part 4 — screen test")
        #expect(tasks.count == 2)
        #expect(tasks[0].id == old.id && tasks[0].title == "baton")   // its own title stays
        #expect(tasks[0].chat?.name == "Baton · Part 5 — big tasks" && tasks[0].next == nil)
        #expect(tasks[1].chat?.name == "Acme · Part 2")
    }

    @Test func aTitleThatWasTheChatNameFollowsIt() {
        var tasks = [task("Baton · Part 4", chat: "Baton · Part 4")]
        Handoff.follow(&tasks, newChat: chat("Baton · Part 5"))
        #expect(tasks[0].title == "Baton · Part 5")
    }

    @Test func anAlreadyTrackedNewChatReplacesTheOldTaskInItsBigTask() {
        var group = BatonTask(title: "NEW FEATURES", windows: [])
        group.isGroup = true
        var old = task("baton", chat: "Baton · Part 4")
        old.parentID = group.id
        let new = task("Baton · Part 5", chat: "Baton · Part 5")
        var tasks = [group, old, new]
        Handoff.follow(&tasks, newChat: chat("Baton · Part 5"))
        #expect(tasks.map(\.id) == [group.id, new.id])
        #expect(tasks[1].parentID == group.id)
    }

    @Test func onlyAnEarlierPartOfTheSameProjectInTheSameAppMoves() {
        var other = task("Cursor baton", chat: "Baton · Part 4")
        other.chat = ChatRecord(bundleID: "com.todesktop.230313mzl4w4u92", appName: "Cursor", name: "Baton · Part 4")
        var tasks = [task("later", chat: "Baton · Part 7"), task("acme", chat: "Acme · Part 4"), other, task("plain", chat: "NEW FEATURES")]
        let before = tasks
        #expect(Handoff.follow(&tasks, newChat: chat("Baton · Part 6")) == nil)
        #expect(tasks == before)
        #expect(Handoff.follow(&tasks, newChat: chat("Handoff resume")) == nil)
    }

    @Test func theLatestEarlierPartIsTheOneContinued() {
        var tasks = [task("three", chat: "Baton · Part 3"), task("five", chat: "Baton · Part 5")]
        Handoff.follow(&tasks, newChat: chat("Baton · Part 6"))
        #expect(tasks.map { $0.chat?.name } == ["Baton · Part 3", "Baton · Part 6"])
    }
}
