import AppKit
import BatonCore
import Defaults
import KeyboardShortcuts
import SwiftUI

@main
struct BatonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            MenuLabel()
        }
        .menuBarExtraStyle(.menu)

        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Onboarding.markDoneIfAlreadySetUp()  // before start(), which asks for permissions only once onboarded
        let model = AppModel.shared
        model.start()
        Insight.shared.start()
        UsageMonitor.shared.start()
        DisplayManager.shared.start()
        KeyboardShortcuts.onKeyUp(for: .newTask) { AppModel.shared.openNewTask() }
        KeyboardShortcuts.onKeyUp(for: .nextReady) { AppModel.shared.jumpToNextReady() }
        SwitcherController.shared.register()
        // The Accessibility switch is re-checked by AppModel's ticker (every 2 s until it's on).
        if !Defaults[.onboarded] { Onboarding.show() }
        Task {
            for await _ in Defaults.updates(.showOn, initial: false) { DisplayManager.shared.rebuild() }
        }
    }
}

struct MenuLabel: View {
    private var model = AppModel.shared
    var body: some View {
        let n = model.readyRows.count
        HStack(spacing: 3) {
            Image(systemName: n > 0 ? "circle.inset.filled" : "circle.dashed")
            if n > 0 { Text("\(n)") }
        }
    }
}

struct MenuContent: View {
    private var model = AppModel.shared
    @Environment(\.openSettings) private var openSettings
    @Default(.theme) private var theme
    @Default(.showOn) private var showOn
    @Default(.collapsedStyle) private var style
    @Default(.notifications) private var notifications

    var body: some View {
        if !model.axTrusted {
            Button("Turn on Accessibility for Baton…") {
                // Adds Baton to the list. Launch only prompts once onboarding is done, so closing the
                // welcome window early would otherwise leave Baton missing from the pane this opens.
                _ = AX.isTrusted(prompt: true)
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            Divider()
        }
        if !model.jevReady {
            Button("Add a Jev Key in Settings…") {
                NSApp.activate()
                openSettings()
            }
            Divider()
        }
        let rows = model.rows
        if rows.isEmpty {
            Text("No tasks yet")
        } else {
            ForEach(rows) { r in
                Button("\(r.group == .ready ? "● " : r.group == .working ? "◌ " : "   ")\(r.title)") { model.jump(r.id) }
            }
        }
        Divider()
        Button("New Task…") { model.openNewTask() }
        Button("Jump to Next Ready") { model.jumpToNextReady() }.disabled(model.nextReady == nil)
        Button("Switch to Chat…") { SwitcherController.shared.open() }
        Button("Today's Recap…") { RecapWindow.show() }
        Divider()
        Toggle("Always-On Shelf", isOn: Binding(get: { Defaults[.showShelf] }, set: { Defaults[.showShelf] = $0 }))
        Picker("Theme", selection: $theme) { ForEach(Theme.allCases, id: \.self) { Text($0.label) } }
        Picker("Collapsed Notch", selection: $style) { ForEach(CollapsedStyle.allCases, id: \.self) { Text($0.label) } }
        Picker("Show On", selection: $showOn) { ForEach(ShowOn.allCases, id: \.self) { Text($0.label) } }
        Toggle("Also Send Notifications", isOn: $notifications)
        Divider()
        Text(String(format: "Jev spend this session: $%.4f", model.spent))
        Button("Troubleshooting…") { NSWorkspace.shared.open(Onboarding.troubleshootingURL) }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit Baton") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
