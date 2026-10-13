import AppKit
import BatonCore
import SwiftUI

/// The end-of-day card: a short headline, three numbers, what to pick up tomorrow, how long each AI
/// worked, what finished. Copy puts it all on the clipboard as plain text.
struct RecapCard: View {
    let recap: Recap
    /// Gemini's line, when it has written one; the template until then.
    var headline: String?
    var onClose: () -> Void = {}
    @State private var copied = false

    static let ink = Color(white: 0.04)
    static let paper = Color(white: 0.94)
    private let grey = Color.white.opacity(0.5)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(recap.date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)).uppercased())
                    .font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(grey)
                Text(headline ?? recap.headline)
                    .font(.system(size: 24, weight: .semibold)).foregroundStyle(Self.paper)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.3), value: headline)
            }

            HStack(spacing: 0) {
                stat(recap.finished.count, "Finished", Self.paper)
                stat(recap.running.count, "Running", recap.running.contains { $0.kind == .stuck } ? Palette.ready : Palette.working)
                stat(recap.waiting.count, "Waiting", recap.waiting.isEmpty ? Self.paper : Palette.ready)
            }

            if !recap.tomorrow.isEmpty {
                section("Tomorrow") {
                    ForEach(Array(recap.tomorrow.enumerated()), id: \.element.id) { i, t in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(i + 1)").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(grey)
                                .frame(width: 12, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(t.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Self.paper).lineLimit(1)
                                    if t.kind == .stuck { StuckTag() }
                                }
                                Text(t.next ?? reason(t)).font(.system(size: 11)).foregroundStyle(grey).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            AppIcon(bundleID: t.bundleID, size: 18)
                        }
                    }
                }
            }

            if !recap.appTime.isEmpty {
                section("AI time") {
                    let most = recap.appTime.first?.seconds ?? 1
                    ForEach(recap.appTime, id: \.bundleID) { a in
                        HStack(spacing: 10) {
                            AppIcon(bundleID: a.bundleID, size: 16)
                            Text(a.appName).font(.system(size: 12)).foregroundStyle(Self.paper).frame(width: 70, alignment: .leading).lineLimit(1)
                            GeometryReader { g in
                                Capsule().fill(.white.opacity(0.08))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(.white.opacity(0.45)).frame(width: max(4, g.size.width * a.seconds / most))
                                    }
                            }
                            .frame(height: 4)
                            Text(Stuck.duration(a.seconds)).font(.system(size: 11)).monospacedDigit().foregroundStyle(grey)
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                }
            }

            if !recap.finished.isEmpty {
                section("Finished") {
                    let shown = recap.finished.prefix(4)
                    Text(shown.joined(separator: " · ") + (recap.finished.count > 4 ? " · +\(recap.finished.count - 4) more" : ""))
                        .font(.system(size: 12)).foregroundStyle(grey).lineLimit(3)
                }
            }

            HStack {
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(recap.text(headline: headline), forType: .string)
                    withAnimation(.easeOut(duration: 0.2)) { copied = true }
                }
                .buttonStyle(PillButton(fill: .white.opacity(0.1), text: Self.paper))
                Button("Done", action: onClose)
                    .buttonStyle(PillButton(fill: Self.paper, text: .black))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400, alignment: .leading)
        .background(Self.ink)
    }

    private func stat(_ n: Int, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(n)").font(.system(size: 28, weight: .semibold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.system(size: 11)).foregroundStyle(grey)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(grey)
            content()
        }
    }

    private func reason(_ t: Recap.Item) -> String {
        switch t.kind {
        case .needsYou: "\(t.appName) needs your input"
        case .ready: "\(t.appName) has a reply"
        case .stuck: "\(t.appName) looks stuck"
        case .running: "\(t.appName) still running"
        case .idle: "Your move"
        }
    }
}

/// The card with today's data, and Gemini's headline once it arrives.
private struct RecapScreen: View {
    @State private var recap = Insight.shared.recap()
    @State private var headline: String?
    let onClose: () -> Void

    var body: some View {
        RecapCard(recap: recap, headline: headline, onClose: onClose)
            .task {
                headline = await Insight.shared.smartHeadline(for: recap)
            }
    }
}

/// The recap's own small window, opened from the menu bar menu, Settings, or on its own at the chosen time.
enum RecapWindow {
    private static var window: NSWindow?

    /// `activate`: false when it opens on schedule, so it doesn't take the keyboard from what you're typing.
    static func show(activate: Bool = true) {
        window?.close()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(RecapCard.ink)
        w.isReleasedWhenClosed = false
        w.title = "Today"
        w.contentView = NSHostingView(rootView: RecapScreen { close() })
        w.center()
        // The observer goes with the window: left registered, it kept every recap window ever opened alive.
        nonisolated(unsafe) var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak w] _ in
            MainActor.assumeIsolated {
                if window === w { window = nil }
                if let token { NotificationCenter.default.removeObserver(token) }
            }
        }
        window = w
        if activate {
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
        } else {
            w.level = .floating
            w.orderFrontRegardless()
        }
    }

    static func close() { window?.close() }
}

#if DEBUG
private extension Recap {
    static var sample: Recap {
        var log = ActivityLog()
        let now = Date()
        let deck = UUID(), logo = UUID()
        log.begin(task: deck, title: "Pitch deck", bundleID: "com.openai.codex", appName: "Codex", at: now - 7200)
        log.end(task: deck, at: now - 3600, outcome: .finished)
        log.begin(task: logo, title: "Logo pass", bundleID: "com.anthropic.claudefordesktop", appName: "Claude", at: now - 2400)
        log.end(task: logo, at: now - 1500, outcome: .needsYou)
        log.noteDone(task: UUID(), title: "Invoice copy", at: now - 600)
        let items = [
            Recap.Item(id: logo, title: "Logo pass", appName: "Claude", bundleID: "com.anthropic.claudefordesktop",
                       kind: .needsYou, since: now - 1500, next: "Pick between the two marks"),
            Recap.Item(id: UUID(), title: "Pricing table", appName: "Codex", bundleID: "com.openai.codex",
                       kind: .stuck, since: now - 1800, next: nil),
            Recap.Item(id: UUID(), title: "Moodboard", appName: "ChatGPT", bundleID: "com.openai.chat",
                       kind: .idle, since: now - 9000, next: "Send the board to Ana")
        ]
        return Recap.make(log: log, items: items, now: now)
    }
}

#Preview("Recap") {
    RecapCard(recap: .sample)
}

#Preview("Recap, Gemini headline") {
    RecapCard(recap: .sample, headline: "Two decks closer")
}

#Preview("Quiet day") {
    RecapCard(recap: Recap.make(log: ActivityLog(), items: [], now: .now))
}
#endif
