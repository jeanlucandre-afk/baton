import AppKit
import BatonCore
import Defaults
import KeyboardShortcuts
import SwiftUI
import UserNotifications

/// The first-run window: what Baton does, the apps it reads, the two permissions, optional keys, and
/// where the notch is. Opens on first launch (until `onboarded` is set) and again from Settings › General.
@MainActor
enum Onboarding {
    private static var window: NSWindow?
    static let size = CGSize(width: 520, height: 540)
    /// Help for a setup that isn't working, from Settings › General and the menu bar.
    static let troubleshootingURL = URL(string: "https://github.com/jeanlucandre-afk/baton/blob/main/docs/INSTALL.md#troubleshooting")!

    static func show() {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(OnboardingView.ink)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: OnboardingView { close() })
        w.center()
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                // Closing it early counts too: it's in Settings when you want it back.
                Defaults[.onboarded] = true
                window = nil
                if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
                closeObserver = nil
                askForNotificationsIfNeverAsked()
            }
        }
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    private static var closeObserver: NSObjectProtocol?

    static func close() { window?.close() }

    /// Launch only asks for notifications once onboarding is done; if the window closed before its
    /// notifications step was answered, ask now. The system shows that prompt only once.
    private static func askForNotificationsIfNeverAsked() {
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Someone who used Baton before onboarding existed (Accessibility on, a Jev key saved) is set up
    /// already: an update shouldn't greet them with the welcome window.
    static func markDoneIfAlreadySetUp() {
        guard !Defaults[.onboarded], AX.isTrusted(prompt: false), KeyStore.exists(KeyStore.jev) else { return }
        Defaults[.onboarded] = true
    }
}

struct OnboardingView: View {
    static let ink = Color(white: 0.05)
    static let paper = Color(red: 0.96, green: 0.95, blue: 0.92)
    static let coral = Color(red: 1.0, green: 0.47, blue: 0.40)

    let done: () -> Void

    enum Step: Int, CaseIterable { case welcome, apps, access, notify, keys, ready }
    @State private var step = Step.welcome
    @State private var notifyStatus: UNAuthorizationStatus = .notDetermined
    /// After "Send a test ping": where to look, or why nothing showed.
    @State private var testNote: String?
    /// A Jev key is in the Keychain: without it there are no pings, so the keys step and the last step say so.
    @State private var jevSaved = KeyStore.exists(KeyStore.jev)
    private let apps = SupportedApp.all
    private var model = AppModel.shared

    init(done: @escaping () -> Void) { self.done = done }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            dots.padding(.top, 34)
            Group {
                switch step {
                case .welcome: welcome
                case .apps: worksWith
                case .access: access
                case .notify: notify
                case .keys: keys
                case .ready: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 28)
            .transition(.opacity)
            footer
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 28)
        .frame(width: Onboarding.size.width, height: Onboarding.size.height)
        .background(Self.ink)
        .foregroundStyle(Self.paper)
        .tint(Self.coral)
        .animation(.easeOut(duration: 0.2), value: step)
        .task(id: step) {
            // Live checks while a permission or key step is showing.
            jevSaved = KeyStore.exists(KeyStore.jev)
            while !Task.isCancelled, step == .access || step == .notify || step == .keys {
                model.recheckAccessibility()
                notifyStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                jevSaved = KeyStore.exists(KeyStore.jev)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            headline("Meet Baton")
            copy("Baton watches your AI chats and pings you from the notch the moment one finishes or needs you.")
            copy("Two permissions and a key. About a minute.").foregroundStyle(Self.paper.opacity(0.55))
        }
    }

    private var worksWith: some View {
        VStack(alignment: .leading, spacing: 14) {
            headline("Works with")
            copy("Baton reads each app's chat list from its sidebar, on this Mac. It knows how to read these:")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(apps) { app in
                    HStack(spacing: 10) {
                        AppIcon(bundleID: app.id, size: 26).opacity(app.installed ? 1 : 0.45)
                        Text(app.name).font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Self.paper.opacity(app.installed ? 1 : 0.55))
                        Spacer()
                        Label(app.installed ? "On this Mac" : "Not installed",
                              systemImage: app.installed ? "checkmark.circle.fill" : "circle.dashed")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(app.installed ? Color.green : Self.paper.opacity(0.45))
                    }
                }
            }
            .padding(.vertical, 2)
            copy("Terminals, browsers and other AI windows can still be tracked as tasks, one window at a time.")
                .foregroundStyle(Self.paper.opacity(0.55))
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 14) {
            headline("Read windows")
            copy("Accessibility lets Baton read the chat lists and replies in your AI apps.")
            status(model.axTrusted, on: "Accessibility is on", off: "Turn on Baton in the list, then come back.")
            if !model.axTrusted {
                Button("Open Accessibility Settings") {
                    _ = AX.isTrusted(prompt: true)  // adds Baton to the list
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer().frame(height: 4)
            // Checked against what the code sends: Engine and Tasks to Jev, Smart and ProfileRepair to
            // Gemini, Phone to ntfy. Nothing else makes a network request.
            Label {
                Text("Windows are read on this Mac. Text leaves it only for what you turn on: Jev and Gemini get chat and task names and the end of a chat, with emails, keys and phone numbers removed. To re-learn a sidebar after an app update, Gemini may get an outline of that window with short labels only. Phone pings go through ntfy.")
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.fill")
            }
            .font(.system(size: 12))
            .foregroundStyle(Self.paper.opacity(0.55))
        }
    }

    private var notify: some View {
        VStack(alignment: .leading, spacing: 14) {
            headline("Get pinged")
            copy("Baton pings in the notch. Notifications also reach you in full-screen apps and on the lock screen.")
            status(notifyStatus == .authorized || notifyStatus == .provisional, on: "Notifications are on",
                   off: notifyStatus == .denied ? "Turned off. You can allow them in System Settings." : "Optional.")
            if notifyStatus == .notDetermined {
                Button("Allow Notifications") {
                    Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
                }
                .buttonStyle(.borderedProminent)
            } else if notifyStatus == .denied {
                Button("Open Notification Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "dev.baton.app")")!)
                }
            }
        }
    }

    private var keys: some View {
        VStack(alignment: .leading, spacing: 12) {
            headline("Add your Jev key")
            copy("Jev is what tells Baton a chat is finished or needs you. Without it you'll see your chats, but get no pings.")
            status(jevSaved, on: "Jev key saved. Pings are on.", off: "No Jev key yet. Get one at typesafe.ai.")
            copy("Gemini is optional. Keys stay in your login Keychain; change them any time in Settings › Keys.")
                .foregroundStyle(Self.paper.opacity(0.55))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(APIKey.all) { KeyRow(key: $0, compact: true) }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 14) {
            headline("You're set")
            notchSketch
            copy("Baton lives in the notch at the top of your screen. Hover it to see your chats. There's no Dock icon: Settings and Troubleshooting are in the menu bar.")
            HStack(spacing: 12) {
                Button("Send a test ping") {
                    let app = apps.first(where: \.installed) ?? apps.first
                    let shown = model.testPing(app: app?.name ?? "Claude", bundleID: app?.id ?? "com.anthropic.claudefordesktop")
                    testNote = shown ? "Look at the notch." : "Pings are off in Settings › General."
                }
                if let testNote {
                    Text(testNote).font(.system(size: 13)).foregroundStyle(Self.paper.opacity(0.55))
                }
            }
            if !jevSaved {
                Label("No Jev key yet, so Baton won't ping when a chat is done. Add it in Settings › Keys.",
                      systemImage: "exclamationmark.circle")
                    .font(.system(size: 13)).foregroundStyle(Self.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }
            OpenAtLoginToggle()
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 6) {
                shortcut("New task", .newTask)
                shortcut("Jump to the next ready chat", .nextReady)
            }
            .padding(.top, 2)
        }
    }

    // MARK: Pieces

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule().fill(s == step ? Self.coral : Self.paper.opacity(0.18))
                    .frame(width: s == step ? 18 : 6, height: 6)
            }
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { move(-1) }.buttonStyle(.plain).foregroundStyle(Self.paper.opacity(0.55))
            }
            Spacer()
            if step == .keys {
                Button(jevSaved ? "Skip Gemini" : "Skip for now") { move(1) }.buttonStyle(.plain).foregroundStyle(Self.paper.opacity(0.55)).padding(.trailing, 12)
            }
            Button(step == .ready ? "Start" : step == .welcome ? "Begin" : "Continue") {
                if step == .ready {
                    Defaults[.onboarded] = true
                    done()
                } else {
                    move(1)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func move(_ d: Int) {
        if let s = Step(rawValue: step.rawValue + d) { step = s }
    }

    private func headline(_ s: String) -> some View {
        Text(s).font(.system(size: 28, weight: .semibold)).tracking(-0.4)
    }

    private func copy(_ s: String) -> some View {
        Text(s).font(.system(size: 14)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }

    private func status(_ ok: Bool, on: String, off: String) -> some View {
        Label(ok ? on : off, systemImage: ok ? "checkmark.circle.fill" : "circle.dashed")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(ok ? Color.green : Self.paper.opacity(0.55))
            .contentTransition(.symbolEffect(.replace))
    }

    private func shortcut(_ label: String, _ name: KeyboardShortcuts.Name) -> some View {
        HStack {
            Text(label).foregroundStyle(Self.paper.opacity(0.7))
            Spacer()
            Text(KeyboardShortcuts.getShortcut(for: name)?.description ?? "Not set")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Self.paper.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
        .font(.system(size: 13))
    }

    /// A screen edge with the notch and a ping waiting in it.
    private var notchSketch: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 10).fill(Self.paper.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Self.paper.opacity(0.12)))
            NotchShape(topRadius: 6, bottomRadius: 12).fill(.black)
                .overlay(alignment: .trailing) {
                    Circle().fill(Self.coral).frame(width: 7, height: 7).padding(.trailing, 18).padding(.bottom, 2)
                }
                .frame(width: 170, height: 30)
        }
        .frame(height: 74)
    }
}

/// An app Baton knows how to read (a built-in profile), and whether it's on this Mac.
struct SupportedApp: Identifiable {
    let id: String          // bundle ID
    let name: String
    let installed: Bool

    /// Names for apps that aren't installed; an installed app's own name wins.
    private static let names = [
        "com.anthropic.claudefordesktop": "Claude",
        "com.openai.chat": "ChatGPT",
        "com.openai.codex": "Codex",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.anysphere.sand": "Grok Bot",
    ]

    /// Every app with a built-in profile, those on this Mac first.
    static var all: [SupportedApp] {
        ProfileBook.builtIn.apps.keys.map { id in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let own = url.flatMap { Bundle(url: $0) }.flatMap {
                ($0.object(forInfoDictionaryKey: "CFBundleDisplayName") ?? $0.object(forInfoDictionaryKey: "CFBundleName")) as? String
            }
            return SupportedApp(id: id, name: own ?? names[id] ?? id, installed: url != nil)
        }
        .sorted { ($0.installed ? 0 : 1, $0.name) < ($1.installed ? 0 : 1, $1.name) }
    }
}
