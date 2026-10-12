import AppKit
import BatonCore
import SwiftUI

/// Under a ping: quick answers and a "Reply…" field. Clicking the field opens the reply card, which takes
/// the keyboard; a quick answer sends straight away.
struct ReplyBar: View {
    let target: Relay.ReplyTarget
    private var relay = Relay.shared
    @State private var hover = false

    init(target: Relay.ReplyTarget) { self.target = target }

    var body: some View {
        HStack(spacing: 8) {
            QuickChips(target: target)
            Button { relay.compose(target) } label: {
                HStack {
                    Text("Reply…").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    Spacer()
                    Text("⏎").font(.system(size: 11)).foregroundStyle(.white.opacity(hover ? 0.5 : 0.25))
                }
                .padding(.horizontal, 12).frame(height: 30)
                .background(.white.opacity(hover ? 0.1 : 0.06), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help("Reply without leaving what you're doing")
        }
        .task(id: target.id) { relay.refreshChips(target) }
    }
}

/// Yes / No / Continue when the chat ends on that kind of question. Fixed words, sent on click.
private struct QuickChips: View {
    let target: Relay.ReplyTarget
    private var relay = Relay.shared
    init(target: Relay.ReplyTarget) { self.target = target }

    var body: some View {
        ForEach(relay.chips[target.id] ?? [], id: \.self) { word in
            Button(word) { relay.reply(target, text: word) }
                .buttonStyle(PillButton(fill: .white.opacity(0.1), text: .white))
                .help("Send “\(word)” to \(target.chat.appName)")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}

/// The reply field itself: takes the keyboard as it shows, ⏎ sends, Esc closes.
private struct ReplyComposer: View {
    let target: Relay.ReplyTarget
    private var relay = Relay.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    init(target: Relay.ReplyTarget) { self.target = target }

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            QuickChips(target: target)
            HStack(spacing: 6) {
                TextField("Reply…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit(send)
                    .onExitCommand { relay.dismiss() }
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(empty ? .white.opacity(0.5) : .black)
                        .frame(width: 22, height: 22)
                        .background(empty ? .white.opacity(0.14) : Palette.ready, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(empty)
                .help("Send to \(target.chat.appName)")
            }
            .padding(.leading, 12).padding(.trailing, 4).frame(height: 30)
            .background(.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(focused ? 0.18 : 0), lineWidth: 1))
            .simultaneousGesture(TapGesture().onEnded { relay.takeKeyboard(); focused = true })
        }
        .task {
            relay.takeKeyboard()
            // The panel takes the keyboard on the next tick; focus once it has.
            try? await Task.sleep(for: .milliseconds(120))
            focused = true
        }
    }

    private func send() {
        guard !empty else { return }
        relay.reply(target, text: text)
    }
}

/// The card Reply and Pass show in the notch: the reply field, then what Baton is doing and how it went.
struct RelayView: View {
    private var relay = Relay.shared

    var body: some View {
        switch relay.phase {
        case .idle: EmptyView()
        case let .composing(t): composing(t)
        case let .working(bundleID, title): working(bundleID, title)
        case let .failed(bundleID, title, message): outcome(bundleID, title, message, ok: false)
        case let .done(bundleID, title, message): outcome(bundleID, title, message, ok: true)
        }
    }

    private func composing(_ t: Relay.ReplyTarget) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AppIcon(bundleID: t.chat.bundleID, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(t.line ?? t.chat.appName).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                TextButton("Cancel", color: Palette.secondary) { relay.dismiss() }
            }
            ReplyComposer(target: t)
            Text("⏎ send · esc cancel · Baton checks it's this chat before typing")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                .padding(.leading, 12)
        }
    }

    private func working(_ bundleID: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AppIcon(bundleID: bundleID, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("Hands off for a moment.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                ProgressView().controlSize(.small).tint(Palette.working)
            }
            WorkingBar(width: 500)
        }
    }

    private func outcome(_ bundleID: String, _ title: String, _ message: String, ok: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AppIcon(bundleID: bundleID, size: 28)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 13)).foregroundStyle(ok ? Palette.done : Palette.coral)
                            .background(Circle().fill(.black).padding(1))
                            .offset(x: 4, y: 4)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(message).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                TextButton(ok ? "Done" : "Close", color: ok ? Palette.ready : Palette.secondary) { relay.dismiss() }
            }
        }
    }
}

/// "Pass to ▸" in a task's right-click menu: a new chat in that app with the handoff typed in, not sent.
/// "Pass and send ▸" sends it too. Apps that aren't installed aren't listed.
struct PassMenu: View {
    let taskID: UUID

    var body: some View {
        let installed = PassTarget.allCases.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
        let later = { (f: @escaping () -> Void) in DispatchQueue.main.async { f() } }
        if Relay.canPass(taskID), !installed.isEmpty {
            Menu("Pass to") {
                ForEach(installed) { t in Button(t.name) { later { Relay.shared.pass(taskID, to: t, send: false) } } }
                Divider()
                Menu("Pass and send") {
                    ForEach(installed) { t in Button(t.name) { later { Relay.shared.pass(taskID, to: t, send: true) } } }
                }
            }
        }
    }
}

#if DEBUG
private let sampleTarget = Relay.ReplyTarget(
    id: UUID(), chat: ChatRecord(bundleID: PassTarget.claude.bundleID, appName: "Claude", name: "Pricing copy"),
    title: "Pricing copy", line: "Claude asks whether to apply the new pricing table")

#Preview("Reply bar") {
    ReplyBar(target: sampleTarget)
        .padding(20).frame(width: 520).background(.black).environment(\.colorScheme, .dark)
}

#Preview("Reply card") {
    ReplyComposer(target: sampleTarget)
        .padding(20).frame(width: 560).background(.black).environment(\.colorScheme, .dark)
}

#Preview("Card states") {
    @Previewable @State var step = 0
    let phases: [Relay.Phase] = [
        .working(bundleID: PassTarget.codex.bundleID, title: "Passing to Codex"),
        .done(bundleID: PassTarget.codex.bundleID, title: "Handoff ready in Codex", message: "Check it, then press Send there."),
        .failed(bundleID: PassTarget.claude.bundleID, title: "Couldn't send — opened the chat instead",
                message: "Claude is showing another chat. Your reply is on the clipboard."),
    ]
    VStack(spacing: 16) {
        RelayView().frame(width: 540)
        Button("Next state") { step = (step + 1) % phases.count; Relay.shared.preview(phases[step]) }
    }
    .padding(20).background(.black).environment(\.colorScheme, .dark)
    .onAppear { Relay.shared.preview(phases[0]) }
}
#endif
