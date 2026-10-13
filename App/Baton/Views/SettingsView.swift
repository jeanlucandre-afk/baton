import BatonCore
import Defaults
import KeyboardShortcuts
import SwiftUI

/// The Settings window from the design: General, Notch, Shortcuts, Tracking, Phone, Keys.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralPane() }
            Tab("Notch", systemImage: "rectangle.topthird.inset.filled") { NotchPane() }
            Tab("Shortcuts", systemImage: "keyboard") { ShortcutsPane() }
            Tab("Tracking", systemImage: "eye") { TrackingPane() }
            Tab("Phone", systemImage: "iphone") { PhonePane() }
            Tab("Keys", systemImage: "key") { KeysPane() }
        }
        .frame(width: 620)
        .scenePadding()
    }
}

// MARK: General

private struct GeneralPane: View {
    @Default(.theme) private var theme
    @Default(.pings) private var pings
    @Default(.pingSeconds) private var pingSeconds
    @Default(.sound) private var sound
    @Default(.notifications) private var notifications

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ForEach(Theme.allCases, id: \.self) { t in
                        OptionCard(selected: theme == t, title: t.label,
                                   detail: t == .dark ? "Pure black. Grows out of the notch." : "Liquid Glass. Floats below the notch.") {
                            ThemePreview(theme: t)
                        } action: { theme = t }
                    }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("The collapsed notch always stays black so it melts into the hardware notch. The theme applies when it opens.")
                    .foregroundStyle(.secondary)
            }
            Section("Pings") {
                Toggle("Ping when an AI finishes", isOn: $pings)
                Group {
                    Picker("Close the ping after", selection: $pingSeconds) {
                        Text("4 seconds").tag(4.0)
                        Text("6 seconds").tag(6.0)
                        Text("10 seconds").tag(10.0)
                        Text("Never").tag(100_000.0)
                    }
                    Toggle("Play a sound", isOn: $sound)
                    Toggle("Also send a macOS notification", isOn: $notifications)
                }
                .disabled(!pings)
            }
            InsightSettingsSection()
            Section { OpenAtLoginToggle() }
            UpdateSettingsSection()
            Section {
                Button("Show Welcome Again…") { Onboarding.show() }
                Button("Troubleshooting…") { NSWorkspace.shared.open(Onboarding.troubleshootingURL) }
            } footer: {
                Text("The welcome walks through permissions and keys again. Troubleshooting opens the install guide on GitHub.")
                    .foregroundStyle(.secondary)
            }
            DebugLogSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: Notch

private struct NotchPane: View {
    @Default(.collapsedStyle) private var style
    @Default(.showOn) private var showOn
    @Default(.showShelf) private var showShelf
    @Default(.beltSpeed) private var beltSpeed

    /// With the shelf on, the notch shows the lane meter (Dark draws the black shelf in its place,
    /// Transparent keeps it above the glass shelf), so the collapsed style never shows.
    private var shelfReplacesNotch: Bool { showShelf }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    ForEach(CollapsedStyle.allCases, id: \.self) { s in
                        OptionCard(selected: style == s, title: s.label, detail: detail(s)) {
                            CollapsedPreview(style: s)
                        } action: { style = s }
                    }
                }
                .disabled(shelfReplacesNotch)
                .opacity(shelfReplacesNotch ? 0.5 : 1)
            } header: {
                Text("Collapsed notch")
            } footer: {
                if shelfReplacesNotch {
                    Text("With the shelf on, the notch shows a pill per AI chat. Turn the shelf off to use these.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Always-on shelf") {
                Toggle("Show the shelf under the notch", isOn: $showShelf)
                Picker("Belt speed", selection: $beltSpeed) {
                    ForEach(BeltSpeed.allCases, id: \.self) { Text($0.label) }
                }
                .disabled(!showShelf)
            }
            Section {
                Picker("Show Baton on", selection: $showOn) {
                    ForEach(ShowOn.allCases, id: \.self) { Text($0.label) }
                }
            } header: {
                Text("Displays")
            } footer: {
                Text("Screens without a notch get a virtual one. Pings always appear on the screen your pointer is on.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func detail(_ s: CollapsedStyle) -> String {
        switch s {
        case .iconsNext: "Every task as an icon, plus who's next. Default."
        case .readyCount: "Only the tasks waiting on you."
        case .progress: "A spinner on the busiest AI and its task."
        case .lanes: "A pill per AI chat, and how many are working."
        }
    }
}

// MARK: Shortcuts

private struct ShortcutsPane: View {
    var body: some View {
        Form {
            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Jump to next ready task", name: .nextReady)
                KeyboardShortcuts.Recorder("New task", name: .newTask)
                SwitcherShortcutRow()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Tracking

private struct TrackingPane: View {
    private var model = AppModel.shared
    @Default(.settle) private var settle
    @Default(.idlePauseMinutes) private var idlePause
    @Default(.autoRepair) private var autoRepair

    var body: some View {
        Form {
            Section {
                Picker("Pause reading after no mouse or keyboard for", selection: $idlePause) {
                    Text("30 minutes").tag(30.0)
                    Text("45 minutes").tag(45.0)
                    Text("1 hour").tag(60.0)
                    Text("Never").tag(0.0)
                }
                if model.idlePaused { Label("Paused now. Move the mouse to resume.", systemImage: "moon.zzz").foregroundStyle(.secondary) }
            } header: {
                Text("When you're away")
            } footer: {
                Text("Long enough that waiting on an AI doesn't count as away. When you're back, anything that finished pings straight away.")
                    .foregroundStyle(.secondary)
            }
            Section("Permissions") {
                LabeledContent("Accessibility") {
                    if model.axTrusted {
                        Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Turn On…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
            }
            Section {
                ForEach(model.readers, id: \.bundle) { r in
                    LabeledContent {
                        HStack(spacing: 8) {
                            if model.repairing.contains(r.bundle) {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Repair") { model.repairReader(r.bundle, force: true) }
                                if r.custom { Button("Reset") { model.resetReader(r.bundle) } }
                            }
                        }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name)
                                Text(r.note ?? readerLine(r.verdict, r.count)).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: r.verdict == .blind ? "exclamationmark.triangle.fill" : r.verdict == .reading ? "checkmark.circle.fill" : "circle.dotted")
                                .foregroundStyle(r.verdict == .blind ? .orange : r.verdict == .reading ? .green : .secondary)
                        }
                    }
                }
                Toggle("Re-learn a sidebar on its own when an app changes it", isOn: $autoRepair)
            } header: {
                Text("Reading apps")
            } footer: {
                Text("Apps change their sidebars in updates. When Baton can't read one, it watches the window instead and re-learns the sidebar: first on your Mac, then, if needed, by sending the sidebar's layout (no conversation text) to Gemini. A new reading is only kept if it finds your chats again.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Finished or needs you", value: model.jevReady ? "Jev" : "No Jev key (Settings › Keys)")
                LabeledContent("Summaries, names and steps", value: model.smartReady ? "Gemini 3.5 Flash-Lite" : (Summarizer.onDeviceAvailability == "available" ? "Apple on-device model" : "Plain text"))
                LabeledContent("Jev spend this session", value: String(format: "$%.4f", model.spent))
            } header: {
                Text("Detection")
            } footer: {
                Text("Window text is read on your Mac. Only the end of attached windows is sent to Jev, with emails, keys and phone numbers removed.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Ask Jev after a window is still for") {
                    HStack {
                        Slider(value: $settle, in: 1.5...6, step: 0.5).frame(width: 180)
                        Text(String(format: "%.1f s", settle)).monospacedDigit().frame(width: 44)
                    }
                }
            } footer: {
                Text("Shorter pings sooner but can catch a pause mid-reply. Applies after restarting Baton.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func readerLine(_ v: ReaderHealth.Verdict, _ count: Int) -> String {
        switch v {
        case .reading: "Reading \(count) chats"
        case .blind: "Can't read the sidebar. Watching the window instead."
        case .unknown: "Not read yet"
        }
    }
}

// MARK: Pieces

private struct OptionCard<Preview: View>: View {
    let selected: Bool
    let title: String
    let detail: String
    @ViewBuilder let preview: () -> Preview
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                preview()
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 8))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ready) }
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Palette.ready : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ThemePreview: View {
    let theme: Theme
    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) { Color(red: 0.79, green: 0.54, blue: 0.32); Color(red: 0.18, green: 0.42, blue: 0.88) }
            if theme == .dark {
                NotchShape(topRadius: 6, bottomRadius: 10).fill(.black).frame(width: 150, height: 40)
            } else {
                VStack(spacing: 4) {
                    UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6).fill(.black).frame(width: 70, height: 10)
                    RoundedRectangle(cornerRadius: 10).fill(.clear).frame(width: 150, height: 36)
                        .glassEffect(.regular, in: .rect(cornerRadius: 10))
                }
            }
        }
    }
}

private struct CollapsedPreview: View {
    let style: CollapsedStyle
    var body: some View {
        VStack {
            HStack(spacing: 4) {
                switch style {
                case .iconsNext:
                    ForEach(0..<4, id: \.self) { i in Circle().fill([Palette.idle, Palette.ready, Palette.ready, Palette.working][i]).frame(width: 7, height: 7) }
                    Spacer()
                    Text("next").font(.system(size: 8)).foregroundStyle(.white.opacity(0.6))
                case .readyCount:
                    Circle().fill(Palette.ready).frame(width: 8, height: 8)
                    Spacer()
                    Text("2 ready").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.ready)
                case .progress:
                    Circle().trim(from: 0, to: 0.65).stroke(Palette.working, lineWidth: 2).frame(width: 9, height: 9)
                    Spacer()
                    Text("Codex 2m").font(.system(size: 8, weight: .semibold)).foregroundStyle(.white)
                case .lanes:
                    ForEach(0..<5, id: \.self) { i in
                        Capsule().fill([Palette.ready, Palette.ready, Palette.working, Palette.working, Palette.now][i]).frame(width: 3, height: 8)
                    }
                    Spacer()
                    Text("2/5 working").font(.system(size: 8, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 8)
            .frame(width: 150, height: 18)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8).fill(.black))
            Spacer()
        }
    }
}
