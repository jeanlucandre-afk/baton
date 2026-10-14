import AppKit
import BatonCore
import CoreText
import Defaults
import KeyboardShortcuts
import SwiftUI
import UserNotifications

/// The first-run card: what Baton does, the apps it reads, the two permissions, the Jev key, and where the
/// notch is. A Liquid Glass card that drops out of the notch, each step led by a short looping film.
/// Opens on first launch (until `onboarded` is set) and again from Settings › General.
@MainActor
enum Onboarding {
    private static var panel: OnboardingPanel?
    static let cardSize = CGSize(width: 540, height: 672)
    /// Room around the card for its shadow.
    static let margin: CGFloat = 40
    /// How far the card steps down while a test ping shows under the notch.
    static let pingRoom: CGFloat = 110
    /// Help for a setup that isn't working, from Settings › General and the menu bar.
    static let troubleshootingURL = URL(string: "https://github.com/jeanlucandre-afk/baton/blob/main/docs/INSTALL.md#troubleshooting")!

    static func show() {
        Typeface.register()
        NSApp.activate()
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        // The notched screen if there is one, since the card comes out of the notch.
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let notch = screen.notchGeometry.rect
        let size = CGSize(width: cardSize.width + 2 * margin, height: cardSize.height + pingRoom + 2 * margin)
        let cardTop = notch.minY - 8
        let frame = CGRect(x: (notch.midX - size.width / 2).rounded(), y: cardTop + margin - size.height,
                           width: size.width, height: size.height)
        let p = OnboardingPanel(contentRect: frame)
        p.contentView = NSHostingView(rootView:
            OnboardingView { finish() }
                .padding(margin)
                .frame(width: size.width, height: size.height, alignment: .top))
        panel = p
        p.makeKeyAndOrderFront(nil)
    }

    /// Done or dismissed: either way it's in Settings when you want it back.
    static func finish() {
        guard let p = panel else { return }
        panel = nil
        Defaults[.onboarded] = true
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.18
            p.animator().alphaValue = 0
        }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            p.orderOut(nil)
        }
        askForNotificationsIfNeverAsked()
    }

    /// Launch only asks for notifications once onboarding is done; if the card closed before its
    /// notifications step was answered, ask now. The system shows that prompt only once.
    private static func askForNotificationsIfNeverAsked() {
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Someone who used Baton before onboarding existed (Accessibility on, a Jev key saved) is set up
    /// already: an update shouldn't greet them with the welcome card.
    static func markDoneIfAlreadySetUp() {
        guard !Defaults[.onboarded], AX.isTrusted(prompt: false), KeyStore.exists(KeyStore.jev) else { return }
        Defaults[.onboarded] = true
    }
}

/// A clear, borderless panel just under the notch panel, so a test ping lands over it. It takes the
/// keyboard (for the key field and Return), and Escape closes it.
final class OnboardingPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 7)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { Onboarding.finish() }
}

/// Geist and Geist Mono, bundled (SIL Open Font License, Fonts/Geist-OFL.txt). Falls back to the system
/// font if they didn't load.
enum Typeface {
    private static var registered = false

    static func register() {
        guard !registered else { return }
        registered = true
        // One at a time and synchronously, so the first frame already has them.
        for url in Bundle.main.urls(forResourcesWithExtension: "woff2", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name = weight == .semibold ? "Geist-SemiBold" : weight == .bold ? "Geist-Bold" : weight == .medium ? "Geist-Medium" : "Geist-Regular"
        return .custom(name, fixedSize: size)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(weight == .regular ? "GeistMono-Regular" : "GeistMono-Medium", fixedSize: size)
    }
}

/// White on glass; color only when it's a status (Palette), plus done green.
enum Tone {
    static let secondary = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.4)
    static let done = Color(red: 0.435, green: 0.827, blue: 0.604)
    /// The card's own curve: quick out, long settle.
    static let ease = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.42)
}

struct OnboardingView: View {
    let done: () -> Void

    enum Step: Int, CaseIterable { case welcome, apps, access, notify, keys, ready }
    /// `-onboardingStep 3` on the command line opens at that step, for checking each film.
    @State private var step = Step(rawValue: UserDefaults.standard.integer(forKey: "onboardingStep")) ?? .welcome
    @State private var shown = false
    @State private var notifyStatus: UNAuthorizationStatus = .notDetermined
    /// A Jev key is in the Keychain: without it there are no pings, so the keys step and the last step say so.
    @State private var jevSaved = KeyStore.exists(KeyStore.jev)
    /// Jev turned down the key just saved.
    @State private var jevProblem: String?
    /// After "Send a test ping": where to look, or why nothing showed.
    @State private var testNote: String?
    @Environment(\.accessibilityReduceMotion) private var reduce
    private let apps = SupportedApp.all
    private var model = AppModel.shared

    init(done: @escaping () -> Void) { self.done = done }

    var body: some View {
        let pinging = model.mode == .ping
        VStack(alignment: .leading, spacing: 0) {
            header
            ZStack(alignment: .topLeading) {
                page.id(step).transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 18)
            footer
        }
        .blur(radius: shown || reduce ? 0 : 6)
        .padding(EdgeInsets(top: 24, leading: 28, bottom: 22, trailing: 28))
        .frame(width: Onboarding.cardSize.width, height: Onboarding.cardSize.height)
        .background { glass }
        .font(Typeface.sans(13))
        .foregroundStyle(.white)
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .scaleEffect(shown || reduce ? 1 : 0.92, anchor: .top)
        .offset(y: (shown || reduce ? 0 : -14) + (pinging ? Onboarding.pingRoom : 0))
        .opacity(shown ? 1 : 0)
        .animation(reduce ? Motion.reduced : Tone.ease, value: pinging)
        .onAppear {
            withAnimation(reduce ? .easeOut(duration: 0.15) : Tone.ease) { shown = true }
        }
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

    private var glass: some View {
        SystemGlass(cornerRadius: 26)
            .overlay(
                // the bright top edge that makes glass read as glass
                RoundedRectangle(cornerRadius: 26)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.38), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 26))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome: welcome
        case .apps: worksWith
        case .access: access
        case .notify: notify
        case .keys: keys
        case .ready: ready
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stage(duration: 6, hold: 0.75) { WelcomeFilm(t: $0) }.modifier(Rise())
            headline("Meet Baton").modifier(Rise(index: 1))
            copy("Run your AI chats in parallel. Baton watches them and pings you from the notch the moment one finishes or needs you.").modifier(Rise(index: 2))
            copy("Two permissions and a key. About a minute.").foregroundStyle(.white.opacity(0.5)).modifier(Rise(index: 3))
        }
    }

    private var worksWith: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stage(duration: 3.2, hold: 0.7) { AppsFilm(t: $0, apps: Array(apps.prefix(5))) }.modifier(Rise())
            headline("Works with").modifier(Rise(index: 1))
            copy("Baton reads each app's chat list from its sidebar, on this Mac. \(installedLine)").modifier(Rise(index: 2))
            copy("Terminals, browsers and other AI windows can still be tracked as tasks, one window at a time.")
                .foregroundStyle(.white.opacity(0.5)).modifier(Rise(index: 3))
        }
    }

    /// "Claude and Codex are here; Cursor isn't installed."
    private var installedLine: String {
        func list(_ a: [SupportedApp]) -> String {
            let n = a.map(\.name)
            return n.count < 2 ? n.joined() : n.dropLast().joined(separator: ", ") + " and " + n.last!
        }
        let here = apps.filter(\.installed), missing = apps.filter { !$0.installed }
        if here.isEmpty { return "None of them are on this Mac yet." }
        let have = "\(list(here)) \(here.count == 1 ? "is" : "are") here"
        if missing.isEmpty { return have + "." }
        return "\(have); \(list(missing)) \(missing.count == 1 ? "isn't" : "aren't") installed."
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stage(duration: 3.6, hold: 0.8) { ReadFilm(t: $0) }.modifier(Rise())
            headline("Read windows").modifier(Rise(index: 1))
            copy("Accessibility lets Baton read the chat lists and replies in your AI apps.").modifier(Rise(index: 2))
            HStack(spacing: 12) {
                if model.axTrusted {
                    StatusLine(.on, "Accessibility is on")
                } else {
                    Button("Open Accessibility Settings") {
                        _ = AX.isTrusted(prompt: true)  // adds Baton to the list
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .buttonStyle(WhiteButton())
                    Text("Turn on Baton in the list, then come back.").font(Typeface.sans(12)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .animation(Motion.fade, value: model.axTrusted)
            .modifier(Rise(index: 3))
            // Checked against what the code sends: Engine and Tasks to Jev, Smart and ProfileRepair to
            // Gemini, Phone to ntfy. Nothing else makes a network request.
            Text("Text leaves this Mac only for what you turn on: Jev and Gemini get chat names and the end of a chat, with emails, keys and phone numbers removed. Phone pings go through ntfy.")
                .font(Typeface.sans(11)).lineSpacing(2).foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
                .modifier(Rise(index: 4))
        }
    }

    private var notify: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stage(duration: 5, hold: 0.5) { PingFilm(t: $0) }.modifier(Rise())
            headline("Get pinged").modifier(Rise(index: 1))
            copy("Baton pings in the notch. Notifications also reach you in full-screen apps and on the lock screen.").modifier(Rise(index: 2))
            HStack(spacing: 12) {
                switch notifyStatus {
                case .authorized, .provisional, .ephemeral:
                    StatusLine(.on, "Notifications are on")
                case .denied:
                    StatusLine(.off, "Turned off.")
                    Button("Open Notification Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "dev.baton.app")")!)
                    }
                    .buttonStyle(GlassButton())
                default:
                    Button("Allow Notifications") {
                        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
                    }
                    .buttonStyle(WhiteButton())
                    Text("Optional.").font(Typeface.sans(12)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .animation(Motion.fade, value: notifyStatus)
            .modifier(Rise(index: 3))
        }
    }

    private var keys: some View {
        VStack(alignment: .leading, spacing: 11) {
            Stage(duration: 2.4, height: 180, hold: 0.6) { JevFilm(t: $0, on: jevSaved) }.modifier(Rise())
            headline("Add your Jev key").modifier(Rise(index: 1))
            copy("Jev is what tells Baton a chat is finished or needs you. Without it you'll see your chats, but get no pings.").modifier(Rise(index: 2))
            Group {
                if jevSaved {
                    VStack(alignment: .leading, spacing: 6) {
                        StatusLine(.on, "Jev key saved. Pings are on.")
                        if let jevProblem { StatusLine(.attention, jevProblem) }
                    }
                } else {
                    JevKeyField { problem in
                        jevProblem = problem
                        jevSaved = KeyStore.exists(KeyStore.jev)
                    }
                }
            }
            .animation(Motion.fade, value: jevSaved)
            .modifier(Rise(index: 3))
            HStack {
                (Text("Gemini").foregroundStyle(.white).font(Typeface.sans(12, .semibold)) + Text(" · optional · writes the one-line pings"))
                Spacer()
                Text("Add it later in Settings › Keys")
            }
            .font(Typeface.sans(12))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.top, 10)
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
            .modifier(Rise(index: 4))
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stage(duration: 6, height: 176, hold: 0.5) { ReadyFilm(t: $0) }.modifier(Rise())
            headline("You're set").modifier(Rise(index: 1))
            copy("Baton lives in the notch. Hover it to see your chats. No Dock icon: Settings are in the menu bar.").modifier(Rise(index: 2))
            if !jevSaved {
                StatusLine(.attention, "No Jev key yet, so Baton won't ping when a chat is done.")
            }
            HStack(spacing: 12) {
                Button("Send a test ping") {
                    let app = apps.first(where: \.installed) ?? apps.first
                    let shown = model.testPing(app: app?.name ?? "Claude", bundleID: app?.id ?? "com.anthropic.claudefordesktop")
                    testNote = shown ? "Look at the notch." : "Pings are off in Settings › General."
                }
                .buttonStyle(GlassButton())
                if let testNote {
                    Text(testNote).font(Typeface.sans(13)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .modifier(Rise(index: 3))
            VStack(alignment: .leading, spacing: 8) {
                OpenAtLoginToggle(label: "Open at login")
                    .toggleStyle(.switch)
                    .tint(Tone.done)
                shortcut("New task", .newTask)
                shortcut("Jump to the next ready chat", .nextReady)
            }
            .modifier(Rise(index: 4))
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule()
                        .fill(s == step ? .white : .white.opacity(s.rawValue < step.rawValue ? 0.5 : 0.16))
                        .frame(width: s == step ? 20 : 6, height: 6)
                }
            }
            Spacer()
            Text("\(step.rawValue + 1) / \(Step.allCases.count)")
                .font(Typeface.mono(11)).foregroundStyle(Tone.faint)
                .contentTransition(.numericText())
        }
        .animation(reduce ? Motion.reduced : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3), value: step)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if step != .welcome {
                Button("Back") { move(-1) }.buttonStyle(QuietButton())
            }
            Spacer()
            if step == .keys, !jevSaved {
                Button("Skip for now") { move(1) }.buttonStyle(QuietButton())
            }
            Button(step == .ready ? "Start" : step == .welcome ? "Begin" : "Continue") {
                if step == .ready { done() } else { move(1) }
            }
            .buttonStyle(WhiteButton())
            .keyboardShortcut(.defaultAction)
        }
    }

    private func move(_ d: Int) {
        guard let s = Step(rawValue: step.rawValue + d) else { return }
        withAnimation(.easeOut(duration: 0.2)) { step = s }
    }

    private func headline(_ s: String) -> some View {
        Text(s).font(Typeface.sans(30, .semibold)).tracking(-0.8).padding(.top, 6)
    }

    private func copy(_ s: String) -> some View {
        Text(s).font(Typeface.sans(14)).lineSpacing(4).foregroundStyle(.white.opacity(0.88))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func shortcut(_ label: String, _ name: KeyboardShortcuts.Name) -> some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text(KeyboardShortcuts.getShortcut(for: name)?.description ?? "Not set")
                .font(Typeface.mono(11, .medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Components

/// Each line of a step arrives a beat after the one above: a short fade out of a blur.
struct Rise: ViewModifier {
    var index = 0
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .blur(radius: on || reduce ? 0 : 5)
            .offset(y: on || reduce ? 0 : -4)
            .onAppear {
                withAnimation(reduce ? .easeOut(duration: 0.15) : .easeOut(duration: 0.3).delay(0.06 * Double(index))) { on = true }
            }
    }
}

/// On (done green, check), off (dashed ring) or needs attention (ready yellow).
struct StatusLine: View {
    enum Kind { case on, off, attention }
    let kind: Kind
    let text: String
    init(_ kind: Kind, _ text: String) { self.kind = kind; self.text = text }

    var body: some View {
        HStack(spacing: 8) {
            switch kind {
            case .on: Image(systemName: "checkmark.circle.fill")
            case .off: Image(systemName: "circle.dashed")
            case .attention: Circle().frame(width: 6, height: 6)
            }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(Typeface.sans(13, kind == .attention ? .regular : .semibold))
        .foregroundStyle(kind == .on ? Tone.done : kind == .off ? Tone.secondary : Palette.ready)
    }
}

/// The primary action: white, dark text.
struct WhiteButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.sans(13, .semibold))
            .foregroundStyle(Color(white: 0.04))
            .padding(.horizontal, 16).frame(height: 34)
            .background(.white.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 9))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A secondary action on glass.
struct GlassButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.sans(13, .semibold))
            .padding(.horizontal, 16).frame(height: 34)
            .background(.white.opacity(configuration.isPressed ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.1)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Back and Skip: just words.
struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.sans(13, .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.9 : 0.55))
            .padding(.horizontal, 12).frame(height: 34)
            .contentShape(Rectangle())
    }
}

/// The Jev key: paste, Save, and a test against Jev. Reports the problem if Jev turns it down.
struct JevKeyField: View {
    var onSaved: (String?) -> Void
    @State private var text = ""
    @State private var busy: String?
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SecureField("Paste your Jev key", text: $text)
                    .textFieldStyle(.plain)
                    .font(Typeface.sans(13))
                    .focused($focused)
                    .onSubmit(save)
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(focused ? 0.7 : 0.12)))
                    .background(RoundedRectangle(cornerRadius: 10).stroke(Palette.now.opacity(focused ? 0.3 : 0), lineWidth: 6))
                    .animation(.easeOut(duration: 0.15), value: focused)
                Button("Save", action: save)
                    .buttonStyle(WhiteButton())
                    .disabled(busy != nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 6) {
                if let busy {
                    ProgressView().controlSize(.small)
                    Text(busy)
                } else if let problem {
                    StatusLine(.attention, problem)
                } else {
                    Text("No Jev key yet.")
                }
                Spacer()
                Link("Get one at typesafe.ai", destination: APIKey.jev.url).underline().foregroundStyle(.white.opacity(0.8))
            }
            .font(Typeface.sans(12))
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func save() {
        let k = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, busy == nil else { return }
        busy = "Saving…"
        problem = nil
        Task {
            // Keychain work runs `security`, off the main thread.
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do { try KeyStore.save(k, service: KeyStore.jev); return nil } catch { return "\(error)" }
            }.value
            if let failure {
                busy = nil
                problem = "Couldn't save the key: \(failure)"
                return
            }
            busy = "Testing…"
            let why = await APIKey.jev.test(k)
            busy = nil
            text = ""
            onSaved(why.map { "Saved, but Jev said: \($0)" })
        }
    }
}

// MARK: - Films

/// The moving picture at the top of each step: a loop with a slow push-in, darker edges and a scrubber,
/// driven by one clock so it can't drift. Reduce Motion holds one frame that tells the story.
struct Stage<Content: View>: View {
    let duration: Double
    var height: CGFloat = 214
    var hold: Double = 0.7
    @ViewBuilder let content: (Double) -> Content
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduce)) { ctx in
            let elapsed = ctx.date.timeIntervalSince(start)
            let t = reduce ? hold : elapsed.truncatingRemainder(dividingBy: duration) / duration
            let push = reduce ? 0 : (1 - cos(elapsed / 12 * .pi)) / 2
            ZStack(alignment: .topLeading) {
                content(t)
                    .frame(width: Film.width, height: height, alignment: .topLeading)
                    .scaleEffect(1 + 0.045 * push, anchor: UnitPoint(x: 0.5, y: 0.3))
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(.black.opacity(0.5), lineWidth: 22)
                    .blur(radius: 16)
                    .allowsHitTesting(false)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(.white.opacity(0.55)).frame(width: (Film.width - 28) * t)
                }
                .frame(height: 2)
                .padding(.horizontal, 14)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 9)
            }
            .frame(width: Film.width, height: height)
            .background(.black.opacity(0.34))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.07)))
        }
        .accessibilityHidden(true)
    }
}

enum Film {
    static let width = Onboarding.cardSize.width - 56

    static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
    /// 0 → 1 between a and b, eased.
    static func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let x = clamp((t - a) / (b - a))
        return x * x * (3 - 2 * x)
    }
    /// In between a and b, out between c and d.
    static func pulse(_ t: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
        ramp(t, a, b) * (1 - ramp(t, c, d))
    }
    /// Text arriving in steps, like typing.
    static func typed(_ x: Double, _ steps: Double) -> Double { (clamp(x) * steps).rounded(.down) / steps }

    static let light = Color(red: 0.945, green: 0.937, blue: 0.918)
    static let ink = Color(red: 0.106, green: 0.106, blue: 0.122)
}

/// The notch at the top of a film.
struct MiniNotch: View {
    var body: some View {
        UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8)
            .fill(.black)
            .frame(width: 92, height: 16)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// Glass drawn inside a film (the real glass can't sit inside another glass).
struct FilmGlass: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(Color(red: 0.11, green: 0.115, blue: 0.15).opacity(0.88), in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.38), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
    }
}

/// 1 · Three chats stream side by side; Claude's finishes, lights up and pings from the notch.
struct WelcomeFilm: View {
    let t: Double

    var body: some View {
        let finished = Film.ramp(t, 0.52, 0.56)
        let glow = Film.pulse(t, 0.54, 0.58, 0.90, 0.96)
        let ping = Film.pulse(t, 0.56, 0.62, 0.90, 0.96)
        let beat = 0.35 + 0.65 * (0.5 + 0.5 * cos(2 * .pi * 5 * t))
        let inner: CGFloat = 126
        ZStack(alignment: .top) {
            HStack(spacing: 10) {
                window(light: true, app: "com.anthropic.claudefordesktop", name: "Claude", title: "Pricing",
                       dot: finished > 0.5 ? Palette.ready : Palette.working, dotOpacity: 1, glow: glow) {
                    bar(inner * 0.7, light: true).frame(maxWidth: .infinity, alignment: .trailing)
                    bar(inner, light: true)
                    bar(inner * Film.typed(Film.ramp(t, 0, 0.5), 18), light: true)
                    bar(inner * 0.8 * Film.typed(Film.ramp(t, 0.07, 0.52), 14), light: true)
                    RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.1)).frame(height: 24).padding(.top, 4)
                }
                window(light: false, app: "com.openai.chat", name: "ChatGPT", title: "Email",
                       dot: Palette.working, dotOpacity: beat, glow: 0) {
                    bar(inner * 0.6, light: false).frame(maxWidth: .infinity, alignment: .trailing)
                    bar(inner * 0.92, light: false)
                    bar(inner * Film.typed(0.1 + 0.75 * t, 24), light: false)
                    RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.12)).frame(height: 24).padding(.top, 9)
                }
                window(light: false, app: "com.openai.codex", name: "Codex", title: "Tests",
                       dot: Palette.working, dotOpacity: 1.35 - beat, glow: 0, background: Color(red: 0.08, green: 0.086, blue: 0.1)) {
                    Group {
                        Text("$ swift test")
                        Text("✓ 212 passed").foregroundStyle(Tone.done)
                        Text("running TaskStoreTests…")
                            .lineLimit(1).fixedSize()
                            .frame(width: inner * (0.3 + 0.4 * Film.typed(t, 20)), alignment: .leading)
                            .clipped()
                    }
                    .font(Typeface.mono(7.5))
                    .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 66)

            MiniNotch()
            HStack(spacing: 7) {
                Circle().fill(Palette.ready).frame(width: 6, height: 6)
                Text("Claude finished").font(Typeface.sans(11, .semibold))
                Spacer()
                Text("Pricing page").font(Typeface.sans(9, .medium)).foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .frame(width: 192, height: 30)
            .modifier(FilmGlass(radius: 11))
            .scaleEffect(0.9 + 0.1 * ping, anchor: .top)
            .offset(y: 22 - 8 * (1 - ping))
            .opacity(ping)
        }
    }

    private func bar(_ w: CGFloat, light: Bool) -> some View {
        Capsule().fill(light ? .black.opacity(0.11) : .white.opacity(0.13)).frame(width: max(w, 0), height: 5)
    }

    private func window<C: View>(light: Bool, app: String, name: String, title: String, dot: Color, dotOpacity: Double,
                                 glow: Double, background: Color? = nil, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 6, height: 6).opacity(dotOpacity)
                    .shadow(color: dot == Palette.ready ? Palette.ready : .clear, radius: 4)
                AppIcon(bundleID: app, size: 11)
                Text(name).font(Typeface.sans(9, .semibold))
                Spacer()
                Text(title).font(Typeface.sans(9, .medium)).opacity(0.5)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(light ? .black.opacity(0.05) : .white.opacity(0.05))
            VStack(alignment: .leading, spacing: 5) { body() }
                .padding(9)
            Spacer(minLength: 0)
        }
        .foregroundStyle(light ? Film.ink : .white)
        .frame(height: 122)
        .frame(maxWidth: .infinity)
        .background(background ?? (light ? Film.light : Color(red: 0.125, green: 0.13, blue: 0.14)))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.ready.opacity(0.8 * glow), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
    }
}

/// 2 · The apps rise in, wires draw from each up into the notch, installed ones get a check.
struct AppsFilm: View {
    let t: Double
    let apps: [SupportedApp]

    var body: some View {
        let n = max(apps.count, 1)
        let span = Film.width - 44
        ZStack(alignment: .topLeading) {
            ForEach(Array(apps.enumerated()), id: \.element.id) { i, app in
                let x = 22 + span / CGFloat(n) * (CGFloat(i) + 0.5)
                let d = Double(i) * 0.047
                Path { p in
                    p.move(to: CGPoint(x: x, y: 114))
                    p.addCurve(to: CGPoint(x: Film.width / 2, y: 16),
                               control1: CGPoint(x: x, y: 70), control2: CGPoint(x: Film.width / 2, y: 70))
                }
                .trim(from: 0, to: Film.ramp(t, d, 0.45 + d))
                .stroke(.white.opacity(0.55 * (1 - Film.ramp(t, 0.85, 1))), lineWidth: 1.2)
            }
            MiniNotch()
            ForEach(Array(apps.enumerated()), id: \.element.id) { i, app in
                let x = 22 + span / CGFloat(n) * (CGFloat(i) + 0.5)
                let d = Double(i) * 0.047
                let check = Film.pulse(t, 0.42 + d, 0.5 + d, 0.88, 1)
                VStack(spacing: 7) {
                    AppIcon(bundleID: app.id, size: 44)
                        .overlay(alignment: .topTrailing) {
                            if app.installed {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .heavy))
                                    .foregroundStyle(.black)
                                    .frame(width: 16, height: 16)
                                    .background(Tone.done, in: Circle())
                                    .offset(x: 5, y: -5)
                                    .scaleEffect(0.3 + 0.7 * check)
                                    .opacity(check)
                            }
                        }
                    Text(app.name).font(Typeface.sans(11)).foregroundStyle(.white.opacity(0.75))
                }
                .opacity(app.installed ? 1 : 0.45)
                .modifier(Rise(index: i))
                .position(x: x, y: 146 + 1.5 * sin(2 * .pi * (t + Double(i) * 0.1)))
            }
        }
    }
}

/// 3 · A scan line reads a sidebar; each chat lights up and gets its status dot.
struct ReadFilm: View {
    let t: Double
    private let rows: [(String, Color)] = [
        ("Pricing page copy", Palette.working), ("Logo directions", Palette.ready), ("Trip to Lisbon", Palette.idle),
        ("Refactor the parser", Palette.working), ("Weekly notes", Palette.idle),
    ]

    var body: some View {
        let scan = Film.ramp(t, 0, 0.85)
        let scanOn = Film.pulse(t, 0, 0.08, 0.85, 1)
        HStack(spacing: 20) {
            HStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RECENTS").font(Typeface.sans(8, .bold)).tracking(0.6).opacity(0.45)
                            .padding(.leading, 4).padding(.bottom, 4)
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                            let at = (0.1 + 0.5 * Double(i)) / 3.6
                            HStack(spacing: 6) {
                                Circle().fill(row.1).frame(width: 6, height: 6)
                                    .scaleEffect(0.4 + 0.6 * Film.ramp(t, at, at + 0.05))
                                    .opacity(Film.pulse(t, at, at + 0.05, 0.92, 1))
                                Text(row.0).font(Typeface.sans(10)).lineLimit(1)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(Palette.now.opacity(0.24 * Film.pulse(t, at, at + 0.03, at + 0.03, at + 0.12)),
                                        in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    .padding(.top, 9).padding(.horizontal, 6)
                    Rectangle().fill(Palette.now).frame(height: 1.5)
                        .shadow(color: Palette.now.opacity(0.8), radius: 6)
                        .offset(y: 30 + 108 * scan)
                        .opacity(scanOn)
                }
                .frame(width: 140, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(.black.opacity(0.05))
                VStack(alignment: .leading, spacing: 7) {
                    Capsule().fill(.black.opacity(0.14)).frame(width: 110, height: 6).frame(maxWidth: .infinity, alignment: .trailing)
                    Capsule().fill(.black.opacity(0.09)).frame(width: 140, height: 6)
                    Capsule().fill(.black.opacity(0.09)).frame(width: 120, height: 6)
                    Capsule().fill(.black.opacity(0.09)).frame(width: 100, height: 6)
                }
                .padding(.horizontal, 12).padding(.vertical, 14)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .foregroundStyle(Film.ink)
            .frame(width: 310, height: 168)
            .background(Film.light)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.45), radius: 13, y: 8)
            VStack(alignment: .leading, spacing: 10) {
                Label("On this Mac", systemImage: "lock")
                    .font(Typeface.sans(12, .medium))
                Text("Reads text only.\nNo screenshots.")
                    .font(Typeface.sans(11)).lineSpacing(3).foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 20)
        .frame(maxHeight: .infinity)
    }
}

/// 4 · Over a full-screen app, a ping drops from the notch, then the system banner slides in.
struct PingFilm: View {
    let t: Double

    var body: some View {
        let pill = Film.pulse(t, 0.10, 0.18, 0.70, 0.78)
        let banner = Film.pulse(t, 0.30, 0.38, 0.78, 0.86)
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                Text("FULL-SCREEN APP").font(Typeface.mono(9, .medium)).foregroundStyle(.white.opacity(0.35))
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06))
                    RoundedRectangle(cornerRadius: 8).fill(Palette.working.opacity(0.18))
                    RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06))
                }
                .frame(height: 78)
                Capsule().fill(.white.opacity(0.1)).frame(width: 170, height: 8)
            }
            .padding(.horizontal, 26).padding(.top, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 0.09, green: 0.094, blue: 0.114))
            .brightness(-0.08 * pill)

            MiniNotch()
            HStack(spacing: 9) {
                AppIcon(bundleID: "com.openai.chat", size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ChatGPT needs you").font(Typeface.sans(11, .semibold))
                    Text("Pick between the two logos").font(Typeface.sans(9)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Circle().fill(Palette.ready).frame(width: 6, height: 6)
            }
            .padding(.horizontal, 11)
            .frame(width: 228, height: 42)
            .modifier(FilmGlass(radius: 14))
            .scaleEffect(0.9 + 0.1 * pill, anchor: .top)
            .offset(x: (Film.width - 228) / 2, y: 22 - 10 * (1 - pill))
            .opacity(pill)

            HStack(alignment: .top, spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Baton").font(Typeface.sans(10, .semibold))
                    Text("ChatGPT needs your input. Also on the lock screen.")
                        .font(Typeface.sans(10)).foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(width: 206, alignment: .leading)
            .modifier(FilmGlass(radius: 13))
            .offset(x: Film.width - 206 - 16 + 40 * (1 - banner), y: 108)
            .opacity(banner)
        }
    }
}

/// 5 · The end of a chat travels to Jev and a verdict comes out. Without a key: dashed, grey, no ping.
struct JevFilm: View {
    let t: Double
    let on: Bool

    var body: some View {
        let ring = (t - 0.46 + 1).truncatingRemainder(dividingBy: 1)
        let bump = (t - 0.67 + 1).truncatingRemainder(dividingBy: 1)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("END OF CHAT").font(Typeface.sans(8, .bold)).tracking(0.5).opacity(0.45)
                Text("Done. I rewrote the pricing headline and saved the file.").font(Typeface.sans(10)).lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Film.ink)
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(width: 118, alignment: .leading)
            .background(Film.light, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 6)

            wire(phase: t, color: .white)

            VStack(spacing: 1) {
                Text("Jev").font(Typeface.sans(14, .semibold))
                Text(on ? "on" : "no key").font(Typeface.mono(9, .medium)).opacity(0.7)
            }
            .foregroundStyle(on ? Palette.now : .white.opacity(0.5))
            .frame(width: 68, height: 68)
            .background(on ? Palette.now.opacity(0.14) : .white.opacity(0.04), in: Circle())
            .overlay(Circle().strokeBorder(on ? Palette.now : .white.opacity(0.22),
                                           style: StrokeStyle(lineWidth: 1.5, dash: on ? [] : [4, 3])))
            .background {
                if on {
                    Circle().stroke(Palette.now.opacity(0.5 * (1 - min(ring / 0.7, 1))), lineWidth: 2)
                        .padding(-16 * min(ring / 0.7, 1))
                }
            }

            wire(phase: (t + 0.5).truncatingRemainder(dividingBy: 1), color: Palette.ready)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle().fill(on ? Palette.ready : .white.opacity(0.3)).frame(width: 6, height: 6)
                    Text(on ? "Finished" : "Unknown").font(Typeface.sans(11, .semibold))
                }
                Text(on ? "Ping sent" : "No ping").font(Typeface.sans(10)).opacity(0.7)
            }
            .foregroundStyle(on ? .white : .white.opacity(0.45))
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(width: 100, alignment: .leading)
            .background(on ? Palette.ready.opacity(0.12) : .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Palette.ready.opacity(0.45) : .white.opacity(0.1)))
            .scaleEffect(on ? 1 + 0.06 * Film.pulse(bump, 0, 0.12, 0.12, 0.3) : 1)
        }
        .padding(.horizontal, 22)
        .frame(maxHeight: .infinity)
        .animation(Motion.fade, value: on)
    }

    private func wire(phase: Double, color: Color) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                if on {
                    Rectangle().fill(.white.opacity(0.28)).frame(height: 1.5)
                    Circle().fill(color).frame(width: 7, height: 7)
                        .shadow(color: color, radius: 5)
                        .offset(x: g.size.width * Film.ramp(phase, 0, 1) - 3.5)
                        .opacity(Film.pulse(phase, 0, 0.12, 0.88, 1))
                } else {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: g.size.height / 2))
                        p.addLine(to: CGPoint(x: g.size.width, y: g.size.height / 2))
                    }
                    .stroke(.white.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                }
            }
            .frame(height: g.size.height)
        }
        .frame(height: 8)
    }
}

/// 6 · The cursor finds the notch, the shelf opens, then ⌥ Tab.
struct ReadyFilm: View {
    let t: Double

    var body: some View {
        let shelf = Film.pulse(t, 0.26, 0.33, 0.74, 0.80)
        let away = 1 - Film.ramp(t, 0, 0.26) + Film.ramp(t, 0.74, 0.86)
        let cursor = Film.pulse(t, 0, 0.08, 0.86, 0.9)
        ZStack(alignment: .topLeading) {
            MiniNotch()
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    AppIcon(bundleID: "com.anthropic.claudefordesktop", size: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("READY").font(Typeface.sans(8, .bold)).tracking(0.5).foregroundStyle(Palette.ready)
                        Text("Pricing page").font(Typeface.sans(10, .semibold))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Palette.ready.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.ready.opacity(0.35)))
                dotLabel("Flaky tests", Palette.working)
                dotLabel("Launch email", Palette.now)
                VStack(spacing: 0) {
                    Text("1").font(Typeface.sans(14, .semibold))
                    Text("READY").font(Typeface.sans(7, .bold)).tracking(0.5).foregroundStyle(.white.opacity(0.5))
                }
                .padding(.leading, 8)
                .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.1)).frame(width: 1) }
            }
            .padding(.horizontal, 12)
            .frame(width: 380, height: 54)
            .modifier(FilmGlass(radius: 16))
            .scaleEffect(0.94 + 0.06 * shelf, anchor: .top)
            .offset(x: (Film.width - 380) / 2, y: 22 - 8 * (1 - shelf))
            .opacity(shelf)

            Image(systemName: "cursorarrow")
                .font(.system(size: 17))
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 1)
                .offset(x: Film.width / 2 + 130 * away, y: 8 + 100 * away)
                .opacity(cursor)

            HStack(spacing: 5) {
                key("⌥", press: Film.pulse(t, 0.84, 0.87, 0.92, 0.96))
                key("tab", press: Film.pulse(t, 0.86, 0.89, 0.94, 0.98))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 16).padding(.bottom, 20)
        }
    }

    private func dotLabel(_ s: String, _ c: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(s).font(Typeface.sans(10)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
        }
    }

    private func key(_ s: String, press: Double) -> some View {
        Text(s).font(Typeface.mono(11, .medium))
            .padding(.horizontal, 8).frame(minWidth: 28, minHeight: 26)
            .background(.white.opacity(0.08 + 0.2 * press), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.2)))
            .offset(y: 2 * press)
    }
}

/// An app Baton knows how to read (a built-in profile), and whether it's on this Mac.
struct SupportedApp: Identifiable {
    let id: String          // bundle ID
    let name: String
    let installed: Bool

    /// Baton's names for the apps it knows; others go by their own. Codex can live inside ChatGPT.app,
    /// whose own name would show it as a second ChatGPT.
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
            return SupportedApp(id: id, name: names[id] ?? own ?? id, installed: url != nil)
        }
        .sorted { ($0.installed ? 0 : 1, $0.name) < ($1.installed ? 0 : 1, $1.name) }
    }
}
