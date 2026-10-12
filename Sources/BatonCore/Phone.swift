import Foundation

// Phone pings through ntfy (https://ntfy.sh): a plain HTTP POST to <server>/<topic>, no account. The topic
// is a long random name only this Mac and your phone know. Only an app name, a state and (unless hidden)
// task names are sent: never conversation text.

/// One push as ntfy shows it: a title line, a body, and how loud.
public struct PhonePush: Sendable, Equatable {
    public var title: String
    public var body: String
    public var tags: [String]
    /// ntfy priority, 1 (min) to 5 (max); 3 is the default.
    public var priority: Int
    public var click: URL?

    public init(title: String, body: String, tags: [String] = [], priority: Int = 3, click: URL? = nil) {
        self.title = title; self.body = body; self.tags = tags; self.priority = priority; self.click = click
    }

    /// Settings › Phone › Send test.
    public static let test = PhonePush(title: "Baton is connected", body: "Pings land here when you're away from your Mac.",
                                       tags: ["baton"])
}

/// Something a notch ping said, as the phone hears it.
public struct PhoneEvent: Sendable, Equatable {
    public enum Kind: String, Sendable { case finished, needsYou, stuck }
    /// Which task or chat it is (dedupe: the same one with the same news is sent once).
    public var key: String
    public var app: String
    /// The task or chat name; nil when there is none.
    public var name: String?
    public var kind: Kind

    public init(key: String, app: String, name: String?, kind: Kind) {
        self.key = key; self.app = app; self.name = name; self.kind = kind
    }

    var dedupeKey: String { "\(key)|\(kind.rawValue)" }
}

/// Groups pings that come close together into one push, drops repeats, and keeps pushes at least
/// `minGap` apart. Pure: the caller owns the clock and the one timer that fires at `dueAt`.
public struct PhonePinger: Sendable {
    /// Wait this long after the latest event for more to arrive…
    public var settle: TimeInterval = 15
    /// …but never longer than this after the first one.
    public var maxWait: TimeInterval = 60
    /// Never two pushes closer than this.
    public var minGap: TimeInterval = 30
    /// The same task with the same news within this long is a repeat.
    public var dedupe: TimeInterval = 300

    public private(set) var pending: [PhoneEvent] = []
    public private(set) var lastSent: Date?
    private var firstAt: Date?
    private var lastAt: Date?
    private var seen: [String: Date] = [:]

    public init() {}

    /// Queues an event; false when it's a repeat (nothing to do).
    @discardableResult
    public mutating func add(_ e: PhoneEvent, at now: Date) -> Bool {
        seen = seen.filter { now.timeIntervalSince($0.value) < dedupe }
        guard seen[e.dedupeKey] == nil else { return false }
        seen[e.dedupeKey] = now
        // Newer news about the same task replaces the older (finished, then needs you: needs you).
        pending.removeAll { $0.key == e.key }
        pending.append(e)
        if firstAt == nil { firstAt = now }
        lastAt = now
        return true
    }

    /// When the queued events should go out; nil with nothing queued.
    public var dueAt: Date? {
        guard !pending.isEmpty, let f = firstAt, let l = lastAt else { return nil }
        var due = min(l.addingTimeInterval(settle), f.addingTimeInterval(maxWait))
        if let s = lastSent { due = max(due, s.addingTimeInterval(minGap)) }
        return due
    }

    /// The push for everything queued, once it's due; clears the queue.
    public mutating func take(now: Date, hideNames: Bool) -> PhonePush? {
        guard let due = dueAt, now >= due else { return nil }
        let push = Self.message(pending, hideNames: hideNames)
        drop()
        lastSent = now
        return push
    }

    /// You're back at the Mac (or turned it off): the notch has it, the phone doesn't need it.
    public mutating func drop() {
        pending = []; firstAt = nil; lastAt = nil
    }

    // MARK: Words

    /// "Claude finished" / "Acme rebrand"; several: "3 ready" / one line each (or "Codex, Claude ×2").
    public static func message(_ events: [PhoneEvent], hideNames: Bool) -> PhonePush {
        let order: [PhoneEvent.Kind] = [.needsYou, .finished, .stuck]
        let sorted = order.flatMap { k in events.filter { $0.kind == k } }
        let priority = events.contains { $0.kind == .needsYou } ? 4 : 3
        let tags = order.filter { k in events.contains { $0.kind == k } }.map(tag)
        func name(_ e: PhoneEvent) -> String? { hideNames ? nil : clean(e.name) }

        if sorted.count == 1, let e = sorted.first {
            let app = clean(e.app) ?? "An AI"
            let n = name(e)
            switch e.kind {
            case .finished:
                return PhonePush(title: "\(app) finished", body: n ?? "A task is ready for you.", tags: tags, priority: priority)
            case .needsYou:
                return PhonePush(title: "\(app) needs you", body: n.map { "\($0) · waiting on you" } ?? "One of your tasks is waiting on you.",
                                 tags: tags, priority: priority)
            case .stuck:
                return PhonePush(title: "\(app) looks stuck", body: n.map { "\($0) · no change for a while" } ?? "One of your tasks may be stuck.",
                                 tags: tags, priority: priority)
            }
        }

        let counts: [String] = order.compactMap { k in
            let c = events.filter { $0.kind == k }.count
            guard c > 0 else { return nil }
            switch k {
            case .needsYou: return "\(c) need\(c == 1 ? "s" : "") you"
            case .finished: return "\(c) ready"
            case .stuck: return "\(c) stuck"
            }
        }
        let title = counts.joined(separator: " · ")

        if hideNames {
            var apps: [(String, Int)] = []
            for e in sorted {
                let a = clean(e.app) ?? "An AI"
                if let i = apps.firstIndex(where: { $0.0 == a }) { apps[i].1 += 1 } else { apps.append((a, 1)) }
            }
            let body = apps.map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 }.joined(separator: ", ")
            return PhonePush(title: title, body: body, tags: tags, priority: priority)
        }

        let limit = 6
        var lines: [String] = sorted.prefix(limit).map { e in
            let app = clean(e.app) ?? "An AI"
            let head: String = switch e.kind {
            case .finished: app
            case .needsYou: "\(app) needs you"
            case .stuck: "\(app) looks stuck"
            }
            if let n = name(e) { return "\(head) · \(n)" }
            return e.kind == .finished ? "\(app) finished" : head
        }
        if sorted.count > limit { lines.append("and \(sorted.count - limit) more") }
        return PhonePush(title: title, body: lines.joined(separator: "\n"), tags: tags, priority: priority)
    }

    static func tag(_ k: PhoneEvent.Kind) -> String {
        switch k { case .finished: "finished"; case .needsYou: "needs-you"; case .stuck: "stuck" }
    }

    /// One line, emails, keys and phone numbers removed, at most 60 characters.
    static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        let one = Redact.clean(s).split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !one.isEmpty else { return nil }
        return one.count > 60 ? String(one.prefix(59)) + "…" : one
    }
}

// MARK: Channel

/// Where pushes go: the server, the secret topic, and the links your phone subscribes with.
public enum PhoneChannel {
    public static let defaultServer = "https://ntfy.sh"
    static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    /// "baton-" and 24 random base32 characters (120 bits): unguessable, and fine as an ntfy topic.
    public static func newTopic<G: RandomNumberGenerator>(using g: inout G) -> String {
        "baton-" + String((0..<24).map { _ in alphabet.randomElement(using: &g)! })
    }

    public static func newTopic() -> String {
        var g = SystemRandomNumberGenerator()
        return newTopic(using: &g)
    }

    /// ntfy topics: 1–64 of letters, digits, `-` and `_`.
    public static func isValidTopic(_ t: String) -> Bool {
        !t.isEmpty && t.count <= 64 && t.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// The server as typed in Settings: empty is ntfy.sh, a bare host gets https. Nil when it isn't one.
    public static func server(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = defaultServer }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = u.host(), !host.isEmpty, !host.contains(" "), u.query == nil, u.fragment == nil else { return nil }
        return u
    }

    public static func publishURL(server: URL, topic: String) -> URL {
        server.appending(path: topic)
    }

    /// The https link: opens the channel in a browser, or paste it into ntfy.
    public static func webURL(server: URL, topic: String) -> String {
        publishURL(server: server, topic: topic).absoluteString
    }

    /// What the QR code holds: `ntfy://<host>/<topic>`, which the ntfy app opens as a subscription.
    public static func subscribeURL(server: URL, topic: String) -> String {
        var host = server.host() ?? "ntfy.sh"
        if let p = server.port { host += ":\(p)" }
        let insecure = server.scheme?.lowercased() == "http"
        return "ntfy://\(host)/\(topic)" + (insecure ? "?secure=false" : "")
    }

    /// For poll.log: enough to tell channels apart, never the whole secret.
    public static func logTag(_ topic: String) -> String {
        let rest = topic.hasPrefix("baton-") ? String(topic.dropFirst(6)) : topic
        return String(rest.prefix(6)) + "…"
    }

    /// The POST ntfy expects: the body is the message, the rest are headers.
    public static func request(_ push: PhonePush, server: URL, topic: String, timeout: TimeInterval = 10) -> URLRequest {
        var r = URLRequest(url: publishURL(server: server, topic: topic), cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                           timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.httpBody = Data(push.body.utf8)
        r.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.setValue(header(push.title), forHTTPHeaderField: "Title")
        if !push.tags.isEmpty { r.setValue(push.tags.joined(separator: ","), forHTTPHeaderField: "Tags") }
        r.setValue(String(min(5, max(1, push.priority))), forHTTPHeaderField: "Priority")
        if let c = push.click { r.setValue(c.absoluteString, forHTTPHeaderField: "Click") }
        return r
    }

    /// Header values must be plain ASCII on the wire; anything else ("·", "×", accents) goes as RFC 2047,
    /// which ntfy decodes.
    static func header(_ s: String) -> String {
        let one = s.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
        if one.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F }) { return one }
        return "=?UTF-8?B?\(Data(one.utf8).base64EncodedString())?="
    }
}

// MARK: Delivery

/// Sends a request; tests use a fake one, so nothing reaches ntfy.sh.
public protocol PhoneTransport: Sendable {
    /// The HTTP status code.
    func send(_ request: URLRequest) async throws -> Int
}

/// An ephemeral session (no cookies, no cache) with a short timeout.
public struct URLSessionPhoneTransport: PhoneTransport {
    let session: URLSession

    public init(timeout: TimeInterval = 10) {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout * 2
        c.waitsForConnectivity = false
        c.httpCookieStorage = nil
        c.urlCache = nil
        session = URLSession(configuration: c)
    }

    public func send(_ request: URLRequest) async throws -> Int {
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

public enum PhoneDelivery {
    public enum Outcome: Sendable, Equatable { case sent, failed(String) }

    /// Tries once, and once more after `retryAfter` if that failed in a way a retry can fix
    /// (network, 5xx, 429). Never more.
    public static func deliver(_ request: URLRequest, via transport: some PhoneTransport,
                               retryAfter: Duration = .seconds(5)) async -> Outcome {
        var reason = ""
        for attempt in 0..<2 {
            if attempt > 0 {
                try? await Task.sleep(for: retryAfter)
                if Task.isCancelled { break }
            }
            do {
                let code = try await transport.send(request)
                if (200..<300).contains(code) { return .sent }
                reason = "HTTP \(code)"
                if (400..<500).contains(code) && code != 429 { break }
            } catch {
                reason = (error as? URLError).map(describe) ?? "\(error)"
            }
        }
        return .failed(reason)
    }

    static func describe(_ e: URLError) -> String {
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost: "offline"
        case .timedOut: "timed out"
        case .cannotFindHost, .dnsLookupFailed: "server not found"
        case .cannotConnectToHost: "can't reach the server"
        case .secureConnectionFailed, .serverCertificateUntrusted: "secure connection failed"
        default: "network error \(e.code.rawValue)"
        }
    }
}

/// While you're away for long (the idle pause) and phone pings are on, chats are still read, but further
/// and further apart: 30 s, 1 min, 2, 4, 8, then every 15 min. A reply that finishes while you're gone
/// still reaches your phone, at a fraction of the cost of reading every few seconds.
public enum AwayCadence {
    public static let first: Double = 30
    public static let longest: Double = 15 * 60

    /// Seconds to wait after the `n`th read since the pause began (0-based).
    public static func interval(afterRead n: Int) -> Double {
        min(longest, first * pow(2, Double(min(max(n, 0), 16))))
    }
}
