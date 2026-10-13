import AppKit
import BatonCore
import Defaults
import SwiftUI

/// Claude, Codex and Cursor usage: Codex from its log every 30 s, Claude and Cursor from the usage buttons
/// in their windows whenever the sidebar poll reads them; kept between launches, shown in the expanded notch's header, and pinged at 90% and on resets.
@Observable
final class UsageMonitor {
    static let shared = UsageMonitor()

    enum App: String, CaseIterable, Codable {
        case claude, codex, cursor
        var name: String { rawValue.capitalized }
        var bundleID: String {
            switch self {
            case .claude: "com.anthropic.claudefordesktop"
            case .codex: "com.openai.codex"
            case .cursor: "com.todesktop.230313mzl4w4u92"
            }
        }
    }

    private(set) var usage: [App: AppUsage] = [:]
    /// A usage card for the notch (90% or a reset), shown like a ping.
    private(set) var alert: Alert?
    private var timer: Timer?
    private var reading = false
    /// Codex's log, read from where the last read stopped (see CodexUsageLog).
    private let codexLog = CodexUsageLog()
    private var lastCodex: AppUsage?
    /// Limits already pinged at 90%, so each crossing pings once ("claude.five").
    private var warned: Set<String> = []

    struct Alert: Equatable {
        let app: App
        let title: String
        let line: String
        let foot: String
        let reset: Bool
        let percent: Double
    }

    static var fileURL: URL { Profiles.fileURL.deletingLastPathComponent().appending(path: "usage.json") }

    func start() {
        guard timer == nil else { return }
        if let saved = SavedFile.load([App: AppUsage].self, from: Self.fileURL) {
            usage = saved
            // Already at 90% when Baton starts: don't ping again for it.
            for (app, u) in saved {
                if (u.five?.percent ?? 0) >= 90 { warned.insert("\(app.rawValue).five") }
                if (u.week?.percent ?? 0) >= 90 { warned.insert("\(app.rawValue).week") }
                if (u.plan?.percent ?? 0) >= 90 { warned.insert("\(app.rawValue).plan") }
            }
        }
        read()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { UsageMonitor.shared.read() }
        }
        timer?.tolerance = 5
    }

    /// The app's usage now: a limit whose reset time has passed counts as 0 until the app says otherwise.
    func current(_ app: App) -> AppUsage? { usage[app]?.current() }

    /// Apps whose usage is read from their windows, during the sidebar poll that already captures them.
    nonisolated static let windowApps: Set<String> = ["com.anthropic.claudefordesktop", "com.todesktop.230313mzl4w4u92"]

    /// Codex, from its log file (cheap, so on its own timer).
    private func read() {
        guard !reading else { return }
        reading = true
        Task {
            let log = codexLog
            let codex = await Task.detached(priority: .utility) { log.read() }.value
            reading = false
            // The same reading as last time changes nothing (only its "seen" time moved, which Codex doesn't show).
            guard let codex, codex != lastCodex else { return }
            lastCodex = codex
            update(.codex, with: codex, replace: true)
        }
    }

    /// Claude's and Cursor's usage buttons, from the sidebar poll's own capture of their windows.
    func note(bundle: String, labels: [String]) {
        guard let app = App.allCases.first(where: { $0.bundleID == bundle }) else { return }
        if app == .cursor {
            if let u = UsageReader.cursor(labels: labels) { update(.cursor, with: u, replace: false) }
            return
        }
        var merged = AppUsage()
        var any = false
        for l in labels {
            if let u = UsageReader.claude(label: l) { merged.merge(u); any = true }
        }
        if any { update(app, with: merged, replace: false) }
    }

    private func update(_ app: App, with reading: AppUsage, replace: Bool) {
        let before = usage[app]?.current()
        var u = usage[app] ?? AppUsage()
        if replace { u = reading } else { u.merge(reading) }
        // Same numbers as before: only the "last seen" times moved. Keep them fresh without rewriting the file each poll.
        let changed = u.five != usage[app]?.five || u.week != usage[app]?.week || u.plan != usage[app]?.plan
        // A write through the subscript invalidates every view reading usage, even an identical one.
        if usage[app] != u { usage[app] = u }
        check(app, before: before, after: u.current())
        if changed { try? JSONEncoder().encode(usage).write(to: Self.fileURL, options: .atomic) }
    }

    // MARK: Pings

    private func check(_ app: App, before: AppUsage?, after: AppUsage) {
        let windows: [(String, Limit?, Limit?, String)] = [
            ("five", before?.five, after.five, "5-hour"),
            ("week", before?.week, after.week, "weekly"),
            ("plan", before?.plan, after.plan, "plan")
        ]
        for (key, old, new, label) in windows {
            guard let new else { continue }
            let id = "\(app.rawValue).\(key)"
            if new.percent >= 90, !warned.contains(id) {
                warned.insert(id)
                let resets = new.resetsAt.map { " Resets \(Self.when($0))." } ?? ""
                show(Alert(app: app, title: "\(app.name) is at \(Int(new.percent))% of your \(label) limit", line: resets.trimmingCharacters(in: .whitespaces),
                           foot: roomElsewhere(than: app), reset: false, percent: new.percent))
            } else if new.percent < 50 {
                warned.remove(id)
                // Back down after being high: the limit reset.
                if let old, old.percent >= 70, new.percent < 10, key != "plan" {
                    let other = key == "five" ? after.week.map { "The weekly one is at \(Int($0.percent))%." } : nil
                    show(Alert(app: app, title: "\(app.name) is back to \(Int(new.percent))%", line: "Your \(label) limit reset.",
                               foot: other ?? "", reset: true, percent: new.percent))
                }
            }
        }
    }

    /// "Codex has room: 15% of its 5-hour limit." for the 90% card.
    private func roomElsewhere(than app: App) -> String {
        let best = App.allCases.filter { $0 != app && $0 != .cursor }
            .compactMap { a in current(a)?.five.map { (a, $0.percent) } }
            .min { $0.1 < $1.1 }
        guard let best, best.1 < 60 else { return "" }
        return "\(best.0.name) has room: \(Int(best.1))% of its 5-hour limit."
    }

    private func show(_ a: Alert) {
        let model = AppModel.shared
        model.notifyText(title: a.title, body: [a.line, a.foot].filter { !$0.isEmpty }.joined(separator: " "))
        // The notch card only when nothing else is open (a ping, the list, the new-task box).
        guard model.mode == .collapsed, !ContinueFlow.shared.showing else { return }
        alert = a
        model.openScreen = DisplayManager.shared.screenUnderPointer()
        model.mode = .ping
        model.cardDeadline = Date().addingTimeInterval(10)
        Task {
            try? await Task.sleep(for: .seconds(10))
            guard self.alert == a else { return }
            if !model.hoveringContent { self.dismiss() }
        }
    }

    func dismiss() {
        alert = nil
        if AppModel.shared.mode == .ping { AppModel.shared.collapse() }
    }

    func open(_ app: App) {
        dismiss()
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    static func when(_ d: Date) -> String {
        let s = d.timeIntervalSinceNow
        if s < 3600 { return "in \(max(1, Int(s / 60))) min" }
        if s < 6 * 3600 { return "in \(Int(s / 3600)) h \(Int(s.truncatingRemainder(dividingBy: 3600) / 60)) m" }
        if Calendar.current.isDateInToday(d) { return "at " + d.formatted(date: .omitted, time: .shortened) }
        return d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func color(_ p: Double, quiet: Color = .white.opacity(0.9)) -> Color {
        p >= 90 ? Palette.coral : p >= 70 ? Palette.context : quiet
    }
}

extension Palette {
    static let coral = Color(red: 1.0, green: 0.54, blue: 0.42)
}

// MARK: The header line

/// "Claude 29% ◔ · Codex 15% ◔ · Cursor 100%": the number is the 5-hour limit (Cursor: its plan),
/// the wheel is the week. Hover for both, and when they reset.
struct UsageLine: View {
    private var monitor = UsageMonitor.shared
    @State private var hovered: UsageMonitor.App?

    var body: some View {
        let apps = UsageMonitor.App.allCases.filter { monitor.current($0) != nil }
        if apps.isEmpty {
            Text("Baton").font(.system(size: 13, weight: .semibold))
        } else {
            HStack(spacing: 16) {
                ForEach(apps, id: \.self) { app in
                    item(app, monitor.current(app)!)
                        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovered = h ? app : (hovered == app ? nil : hovered) } }
                        .overlay(alignment: .topLeading) {
                            if hovered == app { UsageTip(app: app, usage: monitor.current(app)!, seen: monitor.usage[app]).offset(y: 22).zIndex(5) }
                        }
                        .zIndex(hovered == app ? 5 : 0)
                }
            }
            .font(.system(size: 12))
        }
    }

    private func item(_ app: UsageMonitor.App, _ u: AppUsage) -> some View {
        let main = app == .cursor ? u.plan : u.five
        return HStack(spacing: 5) {
            AppIcon(bundleID: app.bundleID, size: 13)
            Text(app.name).foregroundStyle(Palette.secondary)
            Text(main.map { "\(Int($0.percent))%" } ?? "–")
                .monospacedDigit()
                .foregroundStyle(main.map { UsageMonitor.color($0.percent) } ?? Palette.secondary)
                .contentTransition(.numericText())
            if let week = u.week { Wheel(percent: week.percent) }
        }
        .contentShape(Rectangle())
    }
}

/// The week, as a small ring that fills clockwise.
private struct Wheel: View {
    let percent: Double
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.16), lineWidth: 2)
            Circle().trim(from: 0, to: min(1, percent / 100))
                .stroke(UsageMonitor.color(percent, quiet: .white.opacity(0.6)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: percent)
        .accessibilityLabel("Week \(Int(percent))%")
    }
}

private struct UsageTip: View {
    let app: UsageMonitor.App
    let usage: AppUsage
    let seen: AppUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(app.name).fontWeight(.semibold)
            if app == .cursor {
                Text(line("Plan", usage.plan, seen?.planSeen))
            } else {
                Text(line("5 hours", usage.five, seen?.fiveSeen))
                Text(line("Week", usage.week, seen?.weekSeen))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.12)))
        .fixedSize()
        .allowsHitTesting(false)
    }

    private func line(_ name: String, _ l: Limit?, _ seenAt: Date?) -> String {
        guard let l else { return "\(name): not seen yet" }
        var s = "\(name): \(Int(l.percent))%"
        if let r = l.resetsAt { s += " · resets \(UsageMonitor.when(r))" }
        if let seenAt, app != .codex, Date().timeIntervalSince(seenAt) > 300 {
            s += " · as of \(seenAt.formatted(.relative(presentation: .named)))"
        }
        return s
    }
}

// MARK: The 90% / reset card

struct UsageAlertView: View {
    private var monitor = UsageMonitor.shared

    var body: some View {
        if let a = monitor.alert {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.12), lineWidth: 3)
                        Circle().trim(from: 0, to: max(0.001, a.percent / 100))
                            .stroke(a.reset ? Palette.done : Palette.coral, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        AppIcon(bundleID: a.app.bundleID, size: 24)
                    }
                    .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(a.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            Text(a.reset ? "RESET" : "USAGE").font(.system(size: 10, weight: .semibold)).tracking(0.8)
                                .foregroundStyle(a.reset ? Palette.done : Palette.coral)
                        }
                        if !a.line.isEmpty { Text(a.line).font(.system(size: 12)).foregroundStyle(Palette.secondary) }
                    }
                }
                Divider().overlay(.white.opacity(0.13))
                HStack {
                    Text(a.foot).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
                    Spacer()
                    TextButton("OK", color: Palette.secondary) { monitor.dismiss() }
                    if a.reset {
                        TextButton("Open \(a.app.name)", color: Palette.done) { monitor.open(a.app) }
                    } else if let other = otherApp(a) {
                        TextButton("Open \(other.name)", color: Palette.coral) { monitor.open(other) }
                    }
                }
            }
        }
    }

    private func otherApp(_ a: UsageMonitor.Alert) -> UsageMonitor.App? {
        guard !a.foot.isEmpty else { return nil }
        return UsageMonitor.App.allCases.first { a.foot.hasPrefix($0.name) }
    }
}
