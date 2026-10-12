import Foundation

/// The ⌥Space switcher's brain: a fuzzy matcher and the order chats are listed in. Pure, so the app and
/// the tests share it. Nothing here reads a window or calls anything: the app hands in what it already knows.
public enum Switcher {
    /// How much a chat wants you, most first. With nothing typed, the list goes in this order.
    public enum Urgency: Int, Sendable, Comparable, CaseIterable {
        case needsYou, ready, working, recent
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// One chat or task in the list.
    public struct Candidate: Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        /// The app it lives in ("Claude Code", "ChatGPT"); typing it finds the app's chats.
        public var app: String
        /// The big task it sits under, if any; typing it finds every subtask.
        public var bigTask: String?
        public var urgency: Urgency
        /// Larger is more recent. Only orders items of the same urgency.
        public var recency: Double

        public init(id: String, title: String, app: String, bigTask: String? = nil, urgency: Urgency, recency: Double = 0) {
            self.id = id; self.title = title; self.app = app; self.bigTask = bigTask
            self.urgency = urgency; self.recency = recency
        }
    }

    /// A candidate that matched, with the title's matched characters (offsets) to highlight.
    public struct Ranked: Sendable, Hashable {
        public var candidate: Candidate
        public var score: Int
        public var highlights: [Int]
    }

    /// One query matched against one text.
    public struct Match: Sendable, Hashable {
        public var score: Int
        /// Character offsets in the text that matched, in order.
        public var indices: [Int]
    }

    // MARK: Ranking

    /// Every candidate matching `query`, best first. Empty query: all of them, needs-you → ready →
    /// working → recent, most recent first within each. Typed: best match first; ties go by urgency.
    /// Each word of the query has to match the title, the big task or the app.
    public static func rank(_ items: [Candidate], query: String) -> [Ranked] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let indexed = Array(items.enumerated())
        guard !words.isEmpty else {
            return indexed
                .sorted { a, b in
                    (a.element.urgency, -a.element.recency, a.offset) < (b.element.urgency, -b.element.recency, b.offset)
                }
                .map { Ranked(candidate: $0.element, score: 0, highlights: []) }
        }
        var out: [(offset: Int, ranked: Ranked)] = []
        for (i, c) in indexed {
            guard let (score, marks) = score(words, c) else { continue }
            out.append((i, Ranked(candidate: c, score: score, highlights: marks)))
        }
        return out
            .sorted { a, b in
                let x = a.ranked, y = b.ranked
                return (-x.score, x.candidate.urgency, -x.candidate.recency, a.offset)
                     < (-y.score, y.candidate.urgency, -y.candidate.recency, b.offset)
            }
            .map(\.ranked)
    }

    /// The title counts most; a big task's name next; the app least (typing "cursor" lists Cursor's chats
    /// but shouldn't outrank a chat called "Cursor rules"). A whole-query hit in the title wins outright.
    private static func score(_ words: [String], _ c: Candidate) -> (Int, [Int])? {
        var total = 0
        var marks = Set<Int>()
        for w in words {
            let title = match(w, in: c.title)
            // A big task or an app is typed from the start of one of its words ("cla", "code"), not from
            // the middle ("lau" isn't Claude).
            let big = c.bigTask.flatMap { fromWordStart(w, in: $0) }
            let app = fromWordStart(w, in: c.app)
            guard let best = [title?.score, big.map { $0.score * 7 / 10 }, app.map { $0.score / 2 }].compactMap({ $0 }).max()
            else { return nil }
            total += best
            if let title, title.score == best { marks.formUnion(title.indices) }
        }
        // The whole phrase, spaces and all, in the title.
        if words.count > 1, let phrase = match(words.joined(separator: " "), in: c.title) {
            total += phrase.score / 2
            marks.formUnion(phrase.indices)
        }
        return (total, marks.sorted())
    }

    private static func fromWordStart(_ query: String, in text: String) -> Match? {
        guard let m = match(query, in: text), let first = m.indices.first else { return nil }
        return isWordStart(Array(text), first) ? m : nil
    }

    // MARK: Fuzzy matching

    /// Whether every character of `query` appears in `text` in order (case and accents ignored), and how
    /// well: letters starting words and runs of consecutive letters score high, gaps and a late start low.
    /// Nil when it doesn't match, or only as letters scattered through the middle of words.
    public static func match(_ query: String, in text: String) -> Match? {
        let q = fold(query)
        let t = fold(text)
        guard !q.isEmpty else { return Match(score: 0, indices: []) }
        guard q.count <= t.count else { return nil }
        let original = Array(text)
        var best: Match?
        // Try each place the first letter appears and keep the best run from there; titles are short.
        for start in t.indices where t[start] == q[0] {
            guard let m = greedy(q, t, original, from: start) else { break }  // no full match from here on
            if best == nil || m.score > best!.score { best = m }
        }
        // Letters picked out of the middle of unrelated words ("lau" in "Older chat about") aren't a match.
        guard let best, best.score >= 12 * q.count else { return nil }
        return best
    }

    private static func greedy(_ q: [Character], _ t: [Character], _ original: [Character], from start: Int) -> Match? {
        var indices: [Int] = []
        indices.reserveCapacity(q.count)
        var qi = 0, ti = start
        while qi < q.count, ti < t.count {
            // First fit from each start point: good enough for chat titles, and cheap.
            if t[ti] == q[qi] { indices.append(ti); qi += 1 }
            ti += 1
        }
        guard qi == q.count else { return nil }
        var score = 0
        for (k, i) in indices.enumerated() {
            score += 16
            if i == 0 { score += 32 }
            else if isWordStart(original, i) { score += 24 }
            if k > 0 {
                let gap = i - indices[k - 1] - 1
                if gap == 0 { score += 20 } else { score -= min(gap * 3, 15) }
            }
        }
        score -= min(indices[0], 10)
        // The query as one unbroken run ("pag" in "Landing page"), which beats initials scattered across words.
        if q.count >= 2, indices.last! - indices.first! == q.count - 1 { score += 12 * q.count }
        // The query is the whole title, or how it starts.
        if indices.first == 0 && indices.last == q.count - 1 { score += q.count == t.count ? 60 : 40 }
        return Match(score: score, indices: indices)
    }

    /// A letter after a space or punctuation, or a capital after a lowercase letter ("newTask").
    private static func isWordStart(_ s: [Character], _ i: Int) -> Bool {
        guard i > 0, i < s.count else { return i == 0 }
        let prev = s[i - 1], cur = s[i]
        if !(prev.isLetter || prev.isNumber) { return cur.isLetter || cur.isNumber }
        if prev.isLowercase && cur.isUppercase { return true }
        if prev.isLetter && cur.isNumber { return true }
        return false
    }

    /// Lowercased, accents off, one folded character per original character so offsets line up.
    private static func fold(_ s: String) -> [Character] {
        s.map { ch in
            let f = String(ch).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            return f.first ?? ch
        }
    }
}
