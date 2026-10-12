import Foundation
import Testing
@testable import BatonCore

@Suite struct SwitcherMatchTests {
    @Test func matchesLettersInOrderOnly() {
        #expect(Switcher.match("prc", in: "Pricing page copy") != nil)
        #expect(Switcher.match("cpr", in: "Pricing") == nil)
        #expect(Switcher.match("pricingx", in: "Pricing") == nil)
    }

    @Test func ignoresCaseAndAccents() {
        #expect(Switcher.match("CAFE", in: "Café menu") != nil)
        #expect(Switcher.match("résumé", in: "Resume rewrite") != nil)
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(Switcher.match("", in: "Anything")?.indices == [])
    }

    @Test func highlightsTheMatchedLetters() {
        let m = Switcher.match("bp", in: "Baton part")
        #expect(m?.indices == [0, 6])
    }

    @Test func wordStartsBeatTheMiddleOfWords() {
        // "pc" as the starts of "pricing copy" beats p…c buried inside words.
        let starts = Switcher.match("pc", in: "pricing copy")!.score
        let buried = Switcher.match("pc", in: "spice")!.score
        #expect(starts > buried)
    }

    @Test func consecutiveLettersBeatScatteredOnes() {
        #expect(Switcher.match("pag", in: "Landing page")!.score > Switcher.match("pag", in: "Pricing a guide")!.score)
    }

    @Test func aPrefixBeatsTheSameLettersLater() {
        #expect(Switcher.match("log", in: "Logo ideas")!.score > Switcher.match("log", in: "New logo ideas")!.score)
        #expect(Switcher.match("logo", in: "Logo")!.score > Switcher.match("logo", in: "Logo ideas")!.score)
    }

    @Test func findsTheBestStartNotTheFirst() {
        // The first "s" is in "Ask"; the strong match is "Sales deck".
        let m = Switcher.match("sales", in: "Ask about Sales deck")!
        #expect(m.indices == [10, 11, 12, 13, 14])
    }

    @Test func camelCaseCountsAsAWordStart() {
        #expect(Switcher.match("nt", in: "openNewTask")!.score > (Switcher.match("nt", in: "opennewtask")?.score ?? 0))
    }

    @Test func lettersScatteredThroughWordsDontCount() {
        #expect(Switcher.match("lau", in: "Older chat about lighting") == nil)
        #expect(Switcher.match("lau", in: "Launch plan") != nil)
    }
}

@Suite struct SwitcherRankTests {
    let items: [Switcher.Candidate] = [
        .init(id: "a", title: "Logo ideas", app: "ChatGPT", urgency: .recent, recency: 5),
        .init(id: "b", title: "Pricing page copy", app: "Claude", bigTask: "Launch", urgency: .working, recency: 3),
        .init(id: "c", title: "Fix login bug", app: "Cursor", urgency: .needsYou, recency: 1),
        .init(id: "d", title: "Release notes", app: "Claude Code", bigTask: "Launch", urgency: .ready, recency: 4),
        .init(id: "e", title: "Old chat", app: "ChatGPT", urgency: .recent, recency: 9),
        .init(id: "f", title: "Another working one", app: "Codex", urgency: .working, recency: 8),
    ]

    @Test func emptyQueryGoesNeedsYouReadyWorkingRecent() {
        let ids = Switcher.rank(items, query: "").map(\.candidate.id)
        #expect(ids == ["c", "d", "f", "b", "e", "a"])
    }

    @Test func whitespaceOnlyIsEmpty() {
        #expect(Switcher.rank(items, query: "   ").count == items.count)
    }

    @Test func typingFiltersAndPutsTheBestMatchFirst() {
        let r = Switcher.rank(items, query: "logo")
        #expect(r.first?.candidate.id == "a")
        #expect(!r.contains { $0.candidate.id == "e" })
    }

    @Test func aBigTaskNameFindsItsSubtasks() {
        let ids = Set(Switcher.rank(items, query: "launch").map(\.candidate.id))
        #expect(ids == ["b", "d"])
    }

    @Test func anAppNameFindsItsChats() {
        let ids = Switcher.rank(items, query: "cursor").map(\.candidate.id)
        #expect(ids == ["c"])
    }

    @Test func everyWordHasToMatchSomewhere() {
        #expect(Switcher.rank(items, query: "notes claude").map(\.candidate.id) == ["d"])
        #expect(Switcher.rank(items, query: "notes cursor").isEmpty)
    }

    @Test func appsAndBigTasksMatchFromAWordStart() {
        let list: [Switcher.Candidate] = [
            .init(id: "claude", title: "Weekly plan", app: "Claude Code", urgency: .recent),
            .init(id: "launch", title: "Notes", app: "ChatGPT", bigTask: "Launch", urgency: .recent),
        ]
        #expect(Switcher.rank(list, query: "lau").map(\.candidate.id) == ["launch"])
        #expect(Switcher.rank(list, query: "code").map(\.candidate.id) == ["claude"])
    }

    @Test func titleMatchesOutrankAppMatches() {
        let list: [Switcher.Candidate] = [
            .init(id: "app", title: "Weekly plan", app: "Cursor", urgency: .needsYou),
            .init(id: "title", title: "Cursor rules", app: "Claude", urgency: .recent),
        ]
        #expect(Switcher.rank(list, query: "cursor").map(\.candidate.id) == ["title", "app"])
    }

    @Test func tiesGoByUrgency() {
        let list: [Switcher.Candidate] = [
            .init(id: "idle", title: "Deck", app: "Claude", urgency: .recent, recency: 10),
            .init(id: "waiting", title: "Deck", app: "ChatGPT", urgency: .needsYou, recency: 1),
        ]
        #expect(Switcher.rank(list, query: "deck").map(\.candidate.id) == ["waiting", "idle"])
    }

    @Test func highlightsOnlyTitleLetters() {
        let r = Switcher.rank(items, query: "rel")
        #expect(r.first?.candidate.id == "d")
        #expect(r.first?.highlights == [0, 1, 2])
        // Matched through the big task only: nothing in the title lights up.
        let viaTask = Switcher.rank(items, query: "launch").first { $0.candidate.id == "b" }
        #expect(viaTask?.highlights == [])
    }
}
