import AppKit
import BatonCore
import Defaults
import Observation

extension Defaults.Keys {
    /// A run counts as stuck after this many minutes without a change on screen (or twice the app's usual
    /// run length, never under this). 0 = off.
    static let stuckMinutes = Key<Double>("stuckMinutes", default: 15)
    /// Open the day's recap on its own at `recapMinutes` (minutes after midnight).
    static let recapScheduled = Key<Bool>("recapScheduled", default: false)
    static let recapMinutes = Key<Int>("recapMinutes", default: 18 * 60)
    /// When the scheduled recap last opened (seconds since 1970; 0 = never).
    static let recapLastShown = Key<Double>("recapLastShown", default: 0)
}

/// Stuck runs and the day's recap. Lives beside AppModel and only reads what it already has: task
/// states, when each run started, and what the detection engine last saw in watched windows.
@Observable
final class Insight {
    static let shared = Insight()

    /// Tasks that look stuck right now.
    private(set) var stuck: [UUID: Stuck.Verdict] = [:]
    @ObservationIgnored private(set) var log: ActivityLog
    @ObservationIgnored private let file = ActivityFile()
    /// Runs already pinged as stuck (see `Stuck.runKey`): one ping per run, never again.
    @ObservationIgnored private var pinged: Set<String> = []
    @ObservationIgnored private var loop: Task<Void, Never>?

    private init() {
        var l = file.load()
        l.tidy(now: Date())
        log = l
    }

    /// Every 20 s: cheap, and a stuck run is measured in minutes.
    func start() {
        guard loop == nil else { return }
        file.save(log)
        loop = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                await check()
            }
        }
    }

    private func save() { file.save(log) }

    // MARK: Runs

    /// Every task state change (AppModel.setState): a run starts when a task starts working and ends
    /// when it stops.
    func noteState(_ task: UUID, _ state: WindowState) {
        let m = AppModel.shared
        if state == .working {
            guard log.open(task) == nil, let t = m.tasks.first(where: { $0.id == task }), !t.isGroup else { return }
            let bundle = t.chat?.bundleID ?? t.windows.first?.bundleID ?? ""
            let app = t.chat?.appName ?? t.windows.first?.appName ?? ""
            log.begin(task: task, title: t.title, bundleID: bundle, appName: app, at: Date())
            save()
        } else if log.open(task) != nil {
            log.end(task: task, at: Date(), outcome: state)
            if stuck[task] != nil { stuck[task] = nil }
            save()
        }
    }

    /// You ticked a task off (AppModel.complete), before it leaves the list.
    func noteDone(_ task: UUID) {
        guard let t = AppModel.shared.tasks.first(where: { $0.id == task }) else { return }
        log.noteDone(task: task, title: t.title, at: Date())
        if stuck[task] != nil { stuck[task] = nil }
        save()
    }

    // MARK: Stuck

    func check() async {
        let m = AppModel.shared
        // A task removed while its AI ran: its run can't be timed.
        let ids = Set(m.tasks.map(\.id))
        let orphans = Set(log.runs.filter { $0.end == nil && !ids.contains($0.taskID) }.map(\.taskID))
        if !orphans.isEmpty { orphans.forEach { log.drop($0) }; save() }
        openScheduledRecap()

        let minutes = Defaults[.stuckMinutes]
        let working = m.rows.filter { $0.state == .working }
        // Away from the Mac nothing is read, so nothing on screen can be said to have stood still.
        guard minutes > 0, !working.isEmpty, !m.idlePaused, m.axTrusted else {
            if !stuck.isEmpty { stuck = [:] }
            return
        }
        // What the engine last saw in each watched window, by the task on screen there.
        let screens = await m.engine.screens()
        var byTask: [UUID: Stuck.Screen] = [:]
        for (tid, l) in m.live {
            guard let s = screens[tid] else { continue }
            if let c = l.current { byTask[c] = s } else if l.taskIDs.count == 1 { byTask[l.taskIDs[0]] = s }
        }
        let now = Date()
        var found: [UUID: Stuck.Verdict] = [:]
        for r in working {
            let start = log.open(r.id)?.start ?? r.updated
            // The screen only counts for a window Baton watches itself, with Jev there to end the run;
            // a chat followed by its sidebar has no screen, only how long it has run.
            let screen = m.followsChat(r.id) || !m.jevReady ? nil : byTask[r.id]
            let typical = Stuck.typical(log.durations(bundleID: r.apps.first ?? ""))
            guard let v = Stuck.check(start: start, screen: screen, now: now, minutes: minutes, typical: typical) else { continue }
            found[r.id] = v
            if pinged.count > 500 { pinged.removeAll() }
            if pinged.insert(Stuck.runKey(r.id, start: start)).inserted {
                log.markStuck(r.id)
                save()
                m.pingStuck(r, v)
            }
        }
        // Redraw only when what's stuck (or why) changes, not every time the minutes tick on.
        if found.mapValues(\.reason) != stuck.mapValues(\.reason) { stuck = found }
    }

    // MARK: Recap

    /// Today so far, from the log and the tasks as they stand.
    func recap(now: Date = Date()) -> Recap {
        let m = AppModel.shared
        let items: [Recap.Item] = m.rows.map { r in
            let kind: Recap.Item.Kind = stuck[r.id] != nil ? .stuck
                : r.state == .needsYou ? .needsYou
                : r.group == .ready ? .ready
                : r.state == .working ? .running : .idle
            return Recap.Item(id: r.id, title: r.title, appName: r.appNames.first ?? "", bundleID: r.apps.first ?? "",
                              kind: kind, since: r.updated, next: m.tasks.first(where: { $0.id == r.id })?.next)
        }
        return Recap.make(log: log, items: items, now: now)
    }

    /// A one-line headline from Gemini when there's a key; nil otherwise (the card keeps its template).
    /// Only task names and counts are sent.
    func smartHeadline(for recap: Recap) async -> String? {
        guard let smart = AppModel.shared.smart else { return nil }
        return Recap.parseHeadline(await smart.json(recap.headlinePrompt(), maxTokens: 40))
    }

    private func openScheduledRecap() {
        guard Defaults[.recapScheduled] else { return }
        let last = Defaults[.recapLastShown]
        let now = Date()
        guard Recap.due(now: now, atMinutes: Defaults[.recapMinutes], lastShown: last > 0 ? Date(timeIntervalSince1970: last) : nil) else { return }
        Defaults[.recapLastShown] = now.timeIntervalSince1970
        // Opens beside what you're doing without taking the keyboard.
        RecapWindow.show(activate: false)
    }
}

extension AppModel {
    /// One calm ping for a run that looks stuck: a soft sound, a notification ("Codex looks stuck · 12 min")
    /// and the card, which says why.
    func pingStuck(_ r: TaskRow, _ v: Stuck.Verdict) {
        guard Defaults[.pings], tasks.first(where: { $0.id == r.id })?.pingWhenDone ?? true else { return }
        let app = r.appNames.first ?? "The AI"
        if Defaults[.sound] { NSSound(named: "Tink")?.play() }
        notifyText(title: r.title, body: v.ping(app: app))
        show(Ping(taskID: r.id, app: app, bundleID: r.apps.first ?? "", text: v.why, status: .working, at: Date()), announce: false)
    }
}

extension Ping {
    /// A ping about a run that's still working can only be the stuck one.
    var looksStuck: Bool { status == .working }
    var headline: String {
        status == .needsYou ? "\(app) needs you" : looksStuck ? "\(app) still working" : "\(app) finished"
    }
    var badge: String { status == .needsYou ? "NEEDS YOU" : looksStuck ? "STUCK?" : "READY FOR YOU" }
}
