import BatonCore
import KeyboardShortcuts
import SwiftUI

/// The ⌥Space switcher: a search field over every chat and task, most urgent first.
/// Keys are handled by `SwitcherController` ahead of the field; this only draws.
struct SwitcherView: View {
    let state: SwitcherState
    let controller: SwitcherController
    @FocusState private var focused: Bool
    @State private var hovered: String?
    @Environment(\.accessibilityReduceMotion) private var reduce

    static let ink = Color(white: 0.055)
    static let paper = Color(red: 0.96, green: 0.95, blue: 0.92)
    static let coral = Color(red: 1.0, green: 0.47, blue: 0.40)
    private static let rowHeight: CGFloat = 40
    private static let rowSpacing: CGFloat = 2
    /// Nine lines and a half, so a longer list shows it scrolls.
    private static let visibleRows: CGFloat = 9.5

    var body: some View {
        VStack(spacing: 0) {
            card
                .scaleEffect(state.visible || reduce ? 1 : 0.96, anchor: .top)
                .offset(y: state.visible || reduce ? 0 : -8)
                .opacity(state.visible ? 1 : 0)
                .animation(state.visible ? Motion.shape(reduce) : .easeIn(duration: 0.1), value: state.visible)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 8)
    }

    private var card: some View {
        VStack(spacing: 0) {
            field
            Rectangle().fill(Self.paper.opacity(0.08)).frame(height: 1)
            if state.results.isEmpty { empty } else { list }
            footer
        }
        .frame(width: 620)
        .background(Self.ink, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Self.paper.opacity(0.1), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Self.paper.opacity(0.45))
            TextField("", text: Binding(get: { state.query }, set: { state.query = $0 }),
                      prompt: Text("Switch to a chat").foregroundStyle(Self.paper.opacity(0.3)))
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .foregroundStyle(Self.paper)
                .focused($focused)
                .onAppear { focused = true }
                .onChange(of: state.opens) { focused = true }
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
    }

    // MARK: List

    private var list: some View {
        let count = CGFloat(state.results.count)
        let height = min(count, Self.visibleRows) * (Self.rowHeight + Self.rowSpacing) + 10
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Self.rowSpacing) {
                    ForEach(Array(state.results.enumerated()), id: \.element.id) { i, r in
                        row(r, index: i)
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.never)
            .frame(height: height)
            .onChange(of: state.selection) { _, s in
                guard state.results.indices.contains(s) else { return }
                proxy.scrollTo(state.results[s].id)
            }
            .onChange(of: state.query) { if let first = state.results.first { proxy.scrollTo(first.id, anchor: .top) } }
        }
    }

    private func row(_ r: SwitcherResult, index i: Int) -> some View {
        let e = r.entry
        let on = i == state.selection
        return HStack(spacing: 11) {
            StatusDot(color: Self.color(e.urgency), size: 7, wantsYou: e.urgency <= .ready)
                .frame(width: 10)
                .accessibilityLabel(Self.word(e.urgency))
            title(r).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 12)
            if let big = e.bigTask {
                HStack(spacing: 4) {
                    Image(systemName: "square.stack").font(.system(size: 9, weight: .semibold))
                    Text(big).lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(Self.paper.opacity(0.5))
                .frame(maxWidth: 150, alignment: .trailing)
            }
            HStack(spacing: 6) {
                AppIcon(bundleID: e.bundleID, size: 16)
                Text(e.appName).lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(Self.paper.opacity(0.55))
            .frame(maxWidth: 130, alignment: .trailing)
            keycap(i)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Self.paper.opacity(on ? 0.1 : hovered == e.id ? 0.04 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture { controller.pick(i) }
        .onHover { hovered = $0 ? e.id : (hovered == e.id ? nil : hovered) }
        .id(e.id)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    /// The title, the letters you typed in full white, the rest a step back.
    private func title(_ r: SwitcherResult) -> Text {
        var a = AttributedString(r.entry.title)
        a.font = .system(size: 14)
        a.foregroundColor = Self.paper.opacity(r.highlights.isEmpty ? 0.92 : 0.62)
        let n = a.characters.count
        for i in r.highlights where i < n {
            let start = a.characters.index(a.startIndex, offsetBy: i)
            let end = a.characters.index(after: start)
            a[start..<end].foregroundColor = Self.paper
            a[start..<end].font = .system(size: 14, weight: .semibold)
        }
        return Text(a)
    }

    /// 1–9 picks a line: plain digits while nothing's typed, ⌘ and a digit once you've typed.
    @ViewBuilder private func keycap(_ i: Int) -> some View {
        if i < 9 {
            Text(state.query.isEmpty ? "\(i + 1)" : "⌘\(i + 1)")
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Self.paper.opacity(0.32))
                .frame(minWidth: 26, alignment: .trailing)
        } else {
            Color.clear.frame(width: 26, height: 1)
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text(state.query.isEmpty ? "No chats yet" : "Nothing matches \u{201C}\(state.query)\u{201D}")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Self.paper.opacity(0.8))
            Text(state.query.isEmpty
                 ? "Chats show up here once Baton has read Claude, ChatGPT, Codex or Cursor."
                 : "Try fewer letters, an app\u{2019}s name, or a big task\u{2019}s name.")
                .font(.system(size: 11))
                .foregroundStyle(Self.paper.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            if let s = state.selected {
                hint("↑↓", "move")
                hint("⏎", "open")
                if !s.tracked { hint("⌘⏎", "track") }
                hint(state.query.isEmpty ? "1–9" : "⌘1–9", "pick")
            }
            hint("esc", "close")
            Spacer()
            let n = state.results.count
            if n > 0 { Text(n == 1 ? "1 chat" : "\(n) chats").monospacedDigit() }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Self.paper.opacity(0.4))
        .padding(.horizontal, 18)
        .frame(height: 34)
        .background(Self.paper.opacity(0.025))
        .overlay(alignment: .top) { Rectangle().fill(Self.paper.opacity(0.06)).frame(height: 1) }
        .animation(Motion.fade, value: state.selected?.tracked)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).fontWeight(.semibold).foregroundStyle(Self.paper.opacity(0.62))
            Text(label)
        }
    }

    // MARK: Status

    static func color(_ u: Switcher.Urgency) -> Color {
        switch u {
        case .needsYou: coral
        case .ready: Palette.ready
        case .working: Palette.working
        case .recent: Palette.idle.opacity(0.7)
        }
    }

    static func word(_ u: Switcher.Urgency) -> String {
        switch u {
        case .needsYou: "Needs you"
        case .ready: "Ready"
        case .working: "Working"
        case .recent: "Idle"
        }
    }
}

/// Settings › Shortcuts: the switcher's recorder, and a word when another app already holds the shortcut.
struct SwitcherShortcutRow: View {
    private var controller = SwitcherController.shared

    var body: some View {
        KeyboardShortcuts.Recorder("Switch to any chat", name: .switcher) { _ in controller.checkConflict() }
        if controller.conflict {
            Label("Another app already uses this shortcut, so it may not reach Baton. Pick another, or use Switch to Chat… in the menu bar.",
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: Previews

@MainActor private func previewState(_ query: String = "") -> SwitcherState {
    let s = SwitcherState()
    let claude = "com.anthropic.claudefordesktop", gpt = "com.openai.chat", cursor = "com.todesktop.230313mzl4w4u92"
    func chat(_ b: String, _ app: String, _ name: String) -> SwitcherEntry.Target {
        .chat(ChatRecord(bundleID: b, appName: app, name: name))
    }
    s.load([
        SwitcherEntry(id: "1", title: "Fix login redirect loop", bundleID: cursor, appName: "Cursor", bigTask: "Launch",
                      urgency: .needsYou, recency: 3, target: .task(UUID())),
        SwitcherEntry(id: "2", title: "Pricing page copy in 3 tones", bundleID: claude, appName: "Claude Chat", bigTask: "Launch",
                      urgency: .ready, recency: 2, target: .task(UUID())),
        SwitcherEntry(id: "3", title: "Baton · Part 6", bundleID: claude, appName: "Claude Code", bigTask: nil,
                      urgency: .working, recency: 5, target: .task(UUID())),
        SwitcherEntry(id: "4", title: "Logo directions, warmer", bundleID: gpt, appName: "ChatGPT", bigTask: nil,
                      urgency: .working, recency: -1, target: chat(gpt, "ChatGPT", "Logo directions, warmer")),
        SwitcherEntry(id: "5", title: "Moodboard notes", bundleID: gpt, appName: "ChatGPT", bigTask: nil,
                      urgency: .recent, recency: -2, target: chat(gpt, "ChatGPT", "Moodboard notes")),
        SwitcherEntry(id: "6", title: "Release notes draft", bundleID: claude, appName: "Claude Code", bigTask: "Launch",
                      urgency: .recent, recency: 1, target: .task(UUID())),
    ])
    s.query = query
    s.visible = true
    return s
}

#Preview("Switcher") {
    SwitcherView(state: previewState(), controller: .shared)
        .frame(width: SwitcherController.panelSize.width, height: SwitcherController.panelSize.height)
        .background(Color(white: 0.5))
}

#Preview("Typing") {
    SwitcherView(state: previewState("lau"), controller: .shared)
        .frame(width: SwitcherController.panelSize.width, height: SwitcherController.panelSize.height)
        .background(Color(white: 0.5))
}

#Preview("No match") {
    SwitcherView(state: previewState("zzq"), controller: .shared)
        .frame(width: SwitcherController.panelSize.width, height: 260)
        .background(Color(white: 0.5))
}
