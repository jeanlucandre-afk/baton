import AppKit
import BatonCore
import Defaults
import Observation

extension Defaults.Keys {
    /// Settings › Phone: send pings to your phone through ntfy while you're away.
    static let phoneOn = Key<Bool>("phoneOn", default: false)
    /// The secret ntfy topic, made once (Settings › Phone › New channel makes another).
    static let phoneTopic = Key<String>("phoneTopic", default: "")
    /// Empty = ntfy.sh.
    static let phoneServer = Key<String>("phoneServer", default: "")
    /// Pings say only the app and the state, no task or chat names.
    static let phoneHideNames = Key<Bool>("phoneHideNames", default: false)
    /// Away after this many minutes without mouse or keyboard; 0 = only a locked or sleeping screen counts.
    static let phoneAwayMinutes = Key<Double>("phoneAwayMinutes", default: 2)
}

/// Phone pings: the queue (BatonCore's PhonePinger), its one timer, and the test button's result.
/// Off, it does nothing at all: no timer, no session, no requests.
@Observable
final class Phone {
    static let shared = Phone()

    enum TestState: Equatable { case idle, sending, sent(Date), failed(String) }
    var test: TestState = .idle

    @ObservationIgnored private var pinger = PhonePinger()
    /// The single coalescing delay: sleeps until the queue is due, then sends.
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// One line in poll.log per run of failures, not one per push.
    @ObservationIgnored private var failureLogged = false
    /// Made on the first send, never while phone pings are off.
    private static let transport = URLSessionPhoneTransport(timeout: 10)

    private init() {}

    var server: URL? { PhoneChannel.server(Defaults[.phoneServer]) }

    /// The topic, made the first time it's needed.
    @discardableResult
    func ensureTopic() -> String {
        let t = Defaults[.phoneTopic]
        if PhoneChannel.isValidTopic(t) { return t }
        let fresh = PhoneChannel.newTopic()
        Defaults[.phoneTopic] = fresh
        return fresh
    }

    /// A fresh channel: the phone has to scan the new code; the old one gets nothing more.
    func newChannel() {
        Defaults[.phoneTopic] = PhoneChannel.newTopic()
        test = .idle
        DebugLog.log("phone: new channel \(PhoneChannel.logTag(Defaults[.phoneTopic]))")
    }

    func note(_ e: PhoneEvent) {
        guard pinger.add(e, at: Date()) else { return }
        schedule()
    }

    /// Turned off: forget what was queued.
    func stop() {
        timer?.cancel()
        timer = nil
        pinger.drop()
    }

    private func schedule() {
        timer?.cancel()
        guard let due = pinger.dueAt else { timer = nil; return }
        let wait = max(0, due.timeIntervalSinceNow)
        timer = Task {
            try? await Task.sleep(for: .seconds(wait), tolerance: .seconds(1))
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    private func flush() {
        timer = nil
        // Back at the Mac before it went: the notch already told you.
        guard Defaults[.phoneOn], AppModel.shared.phoneAway else { pinger.drop(); return }
        let count = pinger.pending.count
        guard let push = pinger.take(now: Date(), hideNames: Defaults[.phoneHideNames]) else { schedule(); return }
        Task { _ = await deliver(push, what: "\(count) event\(count == 1 ? "" : "s")") }
    }

    func sendTest() {
        test = .sending
        Task {
            switch await deliver(.test, what: "test") {
            case .sent: test = .sent(Date())
            case .failed(let why): test = .failed(why)
            }
        }
    }

    private func deliver(_ push: PhonePush, what: String) async -> PhoneDelivery.Outcome {
        guard let server else { return .failed("the server address isn't valid") }
        let topic = ensureTopic()
        let where_ = "\(server.host() ?? "?")/\(PhoneChannel.logTag(topic))"
        let outcome = await PhoneDelivery.deliver(PhoneChannel.request(push, server: server, topic: topic), via: Self.transport)
        switch outcome {
        case .sent:
            failureLogged = false
            DebugLog.log("phone: sent \(what) to \(where_)")
        case .failed(let why):
            if !failureLogged { DebugLog.log("phone: couldn't send \(what) to \(where_): \(why)") }
            failureLogged = true
        }
        return outcome
    }
}

extension AppModel {
    /// Away, as Settings › Phone counts it: the screen locked or asleep, or no mouse or keyboard for the
    /// chosen minutes. At the Mac the notch is enough.
    var phoneAway: Bool {
        if screensOff || Self.screenLocked { return true }
        let minutes = Defaults[.phoneAwayMinutes]
        return minutes > 0 && secondsSinceInput >= minutes * 60
    }

    static var screenLocked: Bool {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow" { return true }
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) == true || (d["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    /// From `show`: a ping the notch shows also goes to your phone while you're away. Only the app, the
    /// state and the task or chat name (none with Hide task names), never what the AI wrote.
    func phonePing(_ p: Ping) {
        guard Defaults[.phoneOn], phoneAway else { return }
        let kind: PhoneEvent.Kind = p.status == .needsYou ? .needsYou : p.looksStuck ? .stuck : .finished
        let task = tasks.first { $0.id == p.taskID }
        // A waiting chat you don't track gets a new ping id each time: key it by the chat instead.
        let key = task != nil ? p.taskID.uuidString
            : "chat|\(p.bundleID)|\(p.waiting?.section ?? "")|\(p.waiting?.name ?? p.app)"
        let name = task?.title ?? p.waiting.flatMap { $0.name.isEmpty ? nil : $0.name }
        Phone.shared.note(PhoneEvent(key: key, app: p.app, name: name, kind: kind))
    }
}
