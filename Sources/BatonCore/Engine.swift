import Foundation

public enum EngineEvent: Sendable {
    /// A watched window changed state.
    case state(id: UUID, state: WindowState, source: String)
    /// Jev answered (or a cached answer was reused).
    case answer(id: UUID, answer: JevAnswer, reason: String, cached: Bool, chars: Int, axMillis: Double)
    /// A real transition to finished or needs-you. Sent once with the template line, then again with `refined: true`
    /// when the on-device summary is ready.
    case ping(id: UUID, app: String, status: WindowState, text: String, source: String, refined: Bool)
    case note(id: UUID, message: String)
    case lost(id: UUID)
    /// The window now shows something else entirely (e.g. you switched to another chat in the same app).
    case contextChanged(id: UUID, title: String, tail: String)
}

/// Watches windows and decides their state. All mutable state lives on one serial queue so slow
/// Accessibility calls never touch the main thread; results come out through `events`.
public final class DetectionEngine: @unchecked Sendable {
    public struct Config: Sendable {
        public var settle: TimeInterval = 2.5
        public var heartbeat: TimeInterval = 60
        public var tickBudgetMillis: Double = 400
        /// A window that hasn't changed for this long, and isn't working, is read every `quietEvery` seconds
        /// instead of every second. Any change, a recheck or typing in its app puts it back on every second.
        public var quietAfter: TimeInterval = 30
        public var quietEvery: TimeInterval = 3
        public var summaries = true
        public init() {}
    }

    // Only ever touched on the engine queue.
    final class Tracker: @unchecked Sendable {
        var win: AXWindow
        var lastHash = 0
        var lastChange: Date
        var busy = true
        var changedTicks = 0
        var state: WindowState = .unknown
        var candidate: WindowState?
        var lastAskedHash = 0
        var lastAskAt = Date.distantPast
        var recheckAt: Date?
        var inFlight = false
        var missingSince: Date?
        var lastSnapshot: Snapshot?
        var lastTail = ""
        /// What the user said this task is, so Jev judges the window against the goal, not in a vacuum.
        var context: String?
        /// The AI produced something since the last ping. Pings need this, so a window that was already done,
        /// or that only changed because you typed, never pings.
        var activity = false
        /// A quiet window isn't read again before this.
        var nextRead = Date.distantPast
        init(win: AXWindow, now: Date) { self.win = win; lastChange = now }
    }

    public let events: AsyncStream<EngineEvent>
    private let emit: AsyncStream<EngineEvent>.Continuation
    private let queue = DispatchQueue(label: "dev.baton.engine", qos: .utility)
    private let classifier: (any StateClassifier)?
    private var config: Config
    private let hysteresis = Hysteresis()
    private let snap: @Sendable (AXWindow) -> Snapshot?
    private let now: @Sendable () -> Date

    private var trackers: [UUID: Tracker] = [:]
    private var order: [UUID] = []
    private var cursor = 0
    private var timer: DispatchSourceTimer?
    /// The timer is suspended while there's nothing to read (no windows watched, or paused), so an idle
    /// engine doesn't wake every second. `wake()` resumes it.
    private var sleeping = false
    private var paused = false
    private var cache: [Int: JevAnswer] = [:]
    private var cacheOrder: [Int] = []
    private var calls = 0
    private var spent = 0.0
    private var typedAt: [pid_t: Date] = [:]

    public init(classifier: (any StateClassifier)?, config: Config = Config(),
                snapshot: @escaping @Sendable (AXWindow) -> Snapshot? = { AX.snapshot($0) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.classifier = classifier
        self.config = config
        self.snap = snapshot
        self.now = now
        (events, emit) = AsyncStream.makeStream(of: EngineEvent.self, bufferingPolicy: .bufferingNewest(500))
    }

    deinit {
        // Dispatch traps on releasing a suspended source.
        if sleeping { timer?.resume() }
        timer?.cancel()
    }

    public func watch(_ id: UUID, window: AXWindow, context: String? = nil) {
        queue.async {
            AX.enableTree(pid: window.pid)
            if self.trackers[id] == nil { self.order.append(id) }
            let t = Tracker(win: window, now: self.now())
            t.context = context
            self.trackers[id] = t
            self.wake()
        }
    }

    /// Updates which task's goal Jev should judge this window against (e.g. after switching chats).
    public func setContext(_ id: UUID, _ context: String?) {
        queue.async { self.trackers[id]?.context = context }
    }

    public func unwatch(_ id: UUID) {
        queue.async {
            self.trackers[id] = nil
            self.order.removeAll { $0 == id }
        }
    }

    /// Called on every key press in another app; changes in that app's windows right after are yours, not the AI's.
    public func noteTyping(pid: pid_t) {
        queue.async {
            self.typedAt[pid] = self.now()
            // Read its windows every second again, so what the typing changes is seen as yours.
            for t in self.trackers.values where t.win.pid == pid { t.nextRead = .distantPast }
        }
    }

    /// Whether pings get an on-device summary (off while Gemini writes them). Changes with the keys in Settings,
    /// from the next ping on, without a relaunch.
    public func setSummaries(_ on: Bool) {
        queue.async { self.config.summaries = on }
    }

    /// While you're away from the Mac, stop reading windows (no AX reads, no Jev calls).
    public func setPaused(_ p: Bool) {
        queue.async {
            self.paused = p
            if !p { self.wake() }
        }
    }

    public func start() {
        queue.async { [self] in
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            // 15% leeway: macOS can fold the tick into other wakeups.
            t.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(150))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    public func stats() async -> (calls: Int, spent: Double) {
        await withCheckedContinuation { c in queue.async { c.resume(returning: (self.calls, self.spent)) } }
    }

    /// When each watched window's text last changed, and how that text ends, as the last tick saw it.
    /// For the stuck check: no Accessibility read, just what the trackers already hold.
    public func screens() async -> [UUID: Stuck.Screen] {
        await withCheckedContinuation { c in
            queue.async {
                c.resume(returning: self.trackers.mapValues { Stuck.Screen(lastChange: $0.lastChange, tail: String($0.lastTail.suffix(400))) })
            }
        }
    }

    /// Runs one tick synchronously; tests drive the engine with this instead of the timer.
    func tickForTesting() { queue.sync { tick() } }

    /// Whether the timer is running (not suspended for lack of work), for tests.
    var tickingForTesting: Bool { queue.sync { timer != nil && !sleeping } }

    // MARK: - Queue-only

    private func wake() {
        guard sleeping, let timer else { return }
        sleeping = false
        timer.resume()
    }

    private func tick() {
        guard !paused, !order.isEmpty else {
            // Nothing to read: stop waking up until a window is watched or reading resumes.
            if let timer, !sleeping { sleeping = true; timer.suspend() }
            return
        }
        let start = Date()
        // Round-robin with a time budget so a hung app can't stall every other window.
        for _ in 0..<order.count {
            cursor = cursor % order.count
            let id = order[cursor]
            cursor += 1
            if let t = trackers[id] { process(id, t) }
            if Date().timeIntervalSince(start) * 1000 > config.tickBudgetMillis { break }
        }
    }

    private func process(_ id: UUID, _ t: Tracker) {
        let now = self.now()
        if now < t.nextRead { return }
        guard let s = snap(t.win) else {
            // A handle can go stale (Accessibility hiccup) while the window is still open: find it again first.
            if let fresh = AX.relink(t.win) {
                t.win = fresh
                t.missingSince = nil
                emit.yield(.note(id: id, message: "reconnected to window"))
                return
            }
            if t.missingSince == nil { t.missingSince = now }
            if let since = t.missingSince, now.timeIntervalSince(since) > 30 {
                trackers[id] = nil
                order.removeAll { $0 == id }
                emit.yield(.lost(id: id))
            }
            return
        }
        t.missingSince = nil
        t.lastSnapshot = s

        var h = Hasher()
        h.combine(s.title); h.combine(s.buttons); h.combine(s.tail)
        let hash = h.finalize()
        let first = t.lastHash == 0
        if !first && Rules.isContextSwitch(old: t.lastTail, new: s.tail) {
            // Different conversation on screen: start fresh so the old chat's state can't leak into this one.
            t.state = .unknown
            t.candidate = nil
            t.activity = false
            t.changedTicks = 0
            emit.yield(.contextChanged(id: id, title: s.title, tail: s.tail))
        }
        t.lastTail = s.tail
        if hash != t.lastHash {
            t.lastHash = hash
            t.lastChange = now
            t.busy = true
            let typing = typedAt[t.win.pid].map { now.timeIntervalSince($0) < 2.5 } ?? false
            if first || typing {
                t.changedTicks = 0
            } else {
                t.changedTicks += 1
                t.activity = true
            }
        } else {
            t.changedTicks = 0
        }
        let still = now.timeIntervalSince(t.lastChange)

        if let why = Rules.working(s, changedTicks: t.changedTicks) {
            if t.state != .working { flip(id, t, to: .working, source: "rule: \(why)", answer: nil) }
            return
        }

        var reason: String?
        if t.busy && still >= config.settle && hash != t.lastAskedHash { reason = String(format: "settled %.1fs", still) }
        else if let r = t.recheckAt, now >= r { reason = "recheck" }
        else if t.state == .working && now.timeIntervalSince(t.lastAskAt) >= config.heartbeat && still >= config.settle { reason = "heartbeat" }

        if let reason, !t.inFlight { ask(id, t, s, still: still, hash: hash, reason: reason) }
        let quiet = t.changedTicks == 0 && t.state != .working && t.recheckAt == nil && !t.inFlight && !t.busy
            && still >= config.quietAfter
        t.nextRead = quiet ? now.addingTimeInterval(config.quietEvery - 0.05) : .distantPast
    }

    private func ask(_ id: UUID, _ t: Tracker, _ s: Snapshot, still: Double, hash: Int, reason: String) {
        t.busy = false
        t.lastAskedHash = hash
        t.lastAskAt = now()
        t.recheckAt = nil

        // A recheck or heartbeat asks again on purpose: the screen is the same, but the time it has stood
        // still is not, and that's what tells a long-running reply from a finished one.
        if reason != "recheck", reason != "heartbeat", let cached = cache[hash] {
            emit.yield(.answer(id: id, answer: cached, reason: reason, cached: true, chars: s.tail.count, axMillis: s.millis))
            apply(id, t, cached)
            return
        }
        // No key yet (the app hands its Jev over keyless, so a key saved later works): asking would only
        // fail and schedule a recheck every 10 s, which keeps the window read every second forever.
        guard let classifier, classifier.isReady else {
            emit.yield(.note(id: id, message: "would ask Jev (\(reason)) · \(s.tail.count) chars, read in \(Int(s.millis)) ms"))
            return
        }
        // Give Jev the obvious signals as explicit fields instead of making it infer them from noisy text.
        var state: [String: any Sendable] = [
            "app": t.win.appName,
            "window_title": Redact.clean(s.title),
            "stop_button_visible": false,
            "reply_action_buttons_visible": Rules.replyActionsVisible(s),
            "text_still_changing": false,
            "seconds_without_change": Int(still.rounded()),
            "visible_buttons": Array(s.buttons.prefix(15).map(Redact.clean)),
            "latest_text": Redact.clean(s.tail),
            "last_line": Redact.clean(String(s.tail.suffix(120)))
        ]
        if let c = t.context { state["user_task"] = Redact.clean(c) }
        t.inFlight = true
        Task {
            let result: Result<JevAnswer, Error>
            do { result = .success(try await classifier.classify(state: state)) } catch { result = .failure(error) }
            self.queue.async {
                t.inFlight = false
                switch result {
                case .failure(let e):
                    t.recheckAt = self.now().addingTimeInterval(10)
                    self.emit.yield(.note(id: id, message: "Jev error: \(e)"))
                case .success(let a):
                    self.calls += 1
                    self.spent += a.cost
                    self.remember(hash, a)
                    self.emit.yield(.answer(id: id, answer: a, reason: reason, cached: false, chars: s.tail.count, axMillis: s.millis))
                    if self.trackers[id] === t { self.apply(id, t, a) }
                }
            }
        }
    }

    private func remember(_ hash: Int, _ a: JevAnswer) {
        cache[hash] = a
        cacheOrder.append(hash)
        if cacheOrder.count > 200 { cache[cacheOrder.removeFirst()] = nil }
    }

    private func apply(_ id: UUID, _ t: Tracker, _ a: JevAnswer) {
        switch hysteresis.decide(current: t.state, candidate: t.candidate, answer: a) {
        case .keep: t.candidate = nil
        case .flip(let s): flip(id, t, to: s, source: "jev", answer: a)
        case .recheck(let after, let cand):
            if let cand { t.candidate = cand }
            t.recheckAt = now().addingTimeInterval(after)
        }
    }

    private func flip(_ id: UUID, _ t: Tracker, to new: WindowState, source: String, answer: JevAnswer?) {
        let old = t.state
        t.state = new
        t.candidate = nil
        emit.yield(.state(id: id, state: new, source: source))

        // Ping only for real transitions, not for windows that were already done when watching started.
        let ping = (new == .finished || new == .needsYou) && t.activity && old != new
        guard ping else { return }
        t.activity = false
        let app = t.win.appName
        let asks = (answer?.asksYou ?? 0) >= 0.8
        // The template goes out immediately so the ping is never late; the summary replaces it when ready.
        emit.yield(.ping(id: id, app: app, status: new, text: Summarizer.template(app: app, status: new, asksYou: asks), source: "template", refined: false))
        guard config.summaries, let snap = t.lastSnapshot else { return }
        let emit = self.emit
        Task {
            let r = await Summarizer.summarize(app: app, title: snap.title, tail: snap.tail, status: new, asksYou: asks)
            if r.source == "on-device" {
                emit.yield(.ping(id: id, app: app, status: new, text: r.text, source: "on-device \(Int(r.millis)) ms", refined: true))
            }
        }
    }
}
