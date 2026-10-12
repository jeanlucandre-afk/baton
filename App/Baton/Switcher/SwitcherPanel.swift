import AppKit
import BatonCore
import Carbon.HIToolbox
import KeyboardShortcuts
import Observation
import SwiftUI

extension KeyboardShortcuts.Name {
    /// ⌥Space: every chat and task across the AI apps, Spotlight-style.
    static let switcher = Self("switcher", default: .init(.space, modifiers: [.option]))
}

// MARK: Entries

/// One line in the switcher: a task Baton follows, or a chat it has read in an app's sidebar.
struct SwitcherEntry: Identifiable, Equatable {
    enum Target: Equatable {
        case task(UUID)
        case chat(ChatRecord)
    }

    let id: String
    let title: String
    let bundleID: String
    let appName: String
    let bigTask: String?
    let urgency: Switcher.Urgency
    let recency: Double
    let target: Target

    var tracked: Bool { if case .task = target { true } else { false } }

    var candidate: Switcher.Candidate {
        .init(id: id, title: title, app: appName, bigTask: bigTask, urgency: urgency, recency: recency)
    }
}

extension AppModel {
    /// Every task, then every other chat the apps' sidebars listed at the last read. Memory only: no
    /// window is read and nothing is asked, so the switcher opens at once.
    var switcherEntries: [SwitcherEntry] {
        var out: [SwitcherEntry] = []
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var followed: [String: [String]] = [:]   // bundle → followed chat names
        for r in rows {
            let chat = byID[r.id]?.chat
            if let chat { followed[chat.bundleID, default: []].append(chat.name) }
            let urgency: Switcher.Urgency = r.state == .needsYou ? .needsYou
                : r.group == .ready ? .ready
                : r.state == .working ? .working : .recent
            out.append(SwitcherEntry(
                id: "task:\(r.id)", title: r.title,
                bundleID: r.apps.first ?? "",
                appName: chat.map(Self.switcherAppName) ?? r.appNames.joined(separator: " + "),
                bigTask: r.parentID.flatMap { byID[$0]?.title },
                urgency: urgency, recency: r.updated.timeIntervalSince1970, target: .task(r.id)))
        }
        var seen = Set<String>()
        for (bundle, list) in chatRows {
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName ?? bundle
            let tab = appTabs[bundle]?.first(where: \.selected)?.name
            let mine = followed[bundle] ?? []
            for (i, row) in list.enumerated() where !Self.isPlaceholder(row.name) {
                // Already a task (names can be cut short in a sidebar, so the same lookup the tasks use).
                guard !mine.contains(where: { Sidebar.find($0, in: [row]) != nil }),
                      seen.insert("\(bundle)|\(row.name.lowercased())").inserted else { continue }
                let record = ChatRecord(bundleID: bundle, appName: app, name: row.name, section: tab)
                let urgency: Switcher.Urgency = switch row.status {
                case .needsInput: .needsYou
                case .unread: .ready
                case .working: .working
                case .idle: .recent
                }
                // Sidebars list the latest chat first; below the tasks of the same urgency.
                out.append(SwitcherEntry(
                    id: "chat:\(bundle)|\(row.name)", title: row.name, bundleID: bundle,
                    appName: Self.switcherAppName(record), bigTask: nil,
                    urgency: urgency, recency: -Double(i) - 1, target: .chat(record)))
            }
        }
        return out
    }

    /// "Claude Code" / "Claude Chat" for Claude's two tabs; the app's own name otherwise.
    static func switcherAppName(_ c: ChatRecord) -> String {
        c.bundleID == claude ? claudeTabName(c.section) : c.appName
    }
}

// MARK: State

struct SwitcherResult: Identifiable, Equatable {
    let entry: SwitcherEntry
    let highlights: [Int]
    var id: String { entry.id }
}

/// What the switcher shows: a snapshot of the entries taken as it opens (so nothing moves under your
/// keys), the query, and which line is selected.
@Observable
final class SwitcherState {
    var query = "" {
        didSet { if query != oldValue { refilter() } }
    }
    private(set) var results: [SwitcherResult] = []
    var selection = 0
    /// Drives the open and close animation.
    var visible = false
    /// Bumped on every open, so the field takes focus again.
    private(set) var opens = 0
    @ObservationIgnored private var entries: [SwitcherEntry] = []
    @ObservationIgnored private var byID: [String: SwitcherEntry] = [:]

    func load(_ entries: [SwitcherEntry]) {
        self.entries = entries
        byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        query = ""
        refilter()
        opens += 1
    }

    var selected: SwitcherEntry? { results.indices.contains(selection) ? results[selection].entry : nil }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    private func refilter() {
        results = Switcher.rank(entries.map(\.candidate), query: query).compactMap { r in
            byID[r.candidate.id].map { SwitcherResult(entry: $0, highlights: r.highlights) }
        }
        selection = 0
    }
}

// MARK: Panel

/// Borderless and non-activating, like Spotlight: it takes the keyboard without bringing Baton forward,
/// so the app you were in stays the active one and gets the keyboard back when it closes.
final class SwitcherPanel: NSPanel {
    var onEscape: () -> Void = {}

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: SwitcherController.panelSize),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false               // the card draws its own
        level = .modalPanel
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        isMovable = false
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape() }
}

/// Opens and closes the switcher, owns its keys, and does what you pick.
@MainActor @Observable
final class SwitcherController: NSObject, NSWindowDelegate {
    static let shared = SwitcherController()
    static let panelSize = CGSize(width: 680, height: 560)

    let state = SwitcherState()
    /// Another app already holds the shortcut (best guess, see `checkConflict`).
    private(set) var conflict = false
    @ObservationIgnored private var panel: SwitcherPanel?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var closeToken = 0

    var isOpen: Bool { panel?.isVisible == true && keyMonitor != nil }

    /// Called once at launch, next to the other shortcuts.
    func register() {
        checkConflict()
        KeyboardShortcuts.onKeyDown(for: .switcher) { [weak self] in self?.toggle() }
        // Built now, so the first ⌥Space doesn't pay for it.
        _ = makePanel()
    }

    func toggle() { isOpen ? close() : open() }

    func open() {
        let started = Date()
        let panel = makePanel()
        closeToken += 1   // a close still fading out doesn't order the panel out now
        state.load(AppModel.shared.switcherEntries)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            let size = Self.panelSize
            // Upper middle, like Spotlight; the card hangs from the top of the panel.
            let top = f.maxY - f.height * 0.16
            panel.setFrame(NSRect(x: f.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        // On the next turn, so the first frame is drawn closed and the card springs open from it
        // (the very first open included, whose view has never drawn).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel?.isVisible == true, self.keyMonitor != nil else { return }
            self.state.visible = true
        }
        startKeys()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if ms >= 100 { DebugLog.log("switcher: slow open \(ms)ms (\(state.results.count) entries)") }
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        stopKeys()
        state.visible = false
        closeToken += 1
        let token = closeToken
        // Let the fade play, then really go (ordering out also hands the keyboard back).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.closeToken == token else { return }
            self.panel?.orderOut(nil)
        }
    }

    /// Return: go to the chat. ⌘Return on a chat Baton doesn't follow yet: go there and offer to track it
    /// (add it to the task it belongs to, or make it a new one), the same card as for a chat you just started.
    func activate(_ entry: SwitcherEntry?, track: Bool = false) {
        guard let entry else { return }
        close()
        let model = AppModel.shared
        switch entry.target {
        case .task(let id):
            model.jump(id)
        case .chat(let chat):
            model.openChat(chat)
            if track { Task { await model.suggestTask(for: chat) } }
        }
    }

    func pick(_ index: Int) {
        guard state.results.indices.contains(index) else { return }
        state.selection = index
        activate(state.results[index].entry)
    }

    // MARK: Keys

    private func startKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func stopKeys() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    /// The list's keys, ahead of the search field. Anything else types into it.
    private func handle(_ e: NSEvent) -> Bool {
        // Mid-composition (Japanese, Chinese, accents): Return and the arrows belong to the input method.
        if let editor = panel?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(e.keyCode) {
        case kVK_Escape: close(); return true
        case kVK_UpArrow: state.move(-1); return true
        case kVK_DownArrow: state.move(1); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            activate(state.selected, track: mods.contains(.command)); return true
        default: break
        }
        if mods == .control, let c = e.charactersIgnoringModifiers {
            if c == "p" { state.move(-1); return true }
            if c == "n" { state.move(1); return true }
        }
        // 1–9: pick that line. Plain digits only while nothing's typed (a chat can be called "Part 6"); ⌘ always.
        if let c = e.charactersIgnoringModifiers, c.count == 1, let n = Int(c), (1...9).contains(n),
           mods == .command || (mods.isEmpty && state.query.isEmpty) {
            pick(n - 1)
            return true
        }
        return false
    }

    // MARK: Panel

    private func makePanel() -> SwitcherPanel {
        if let panel { return panel }
        let p = SwitcherPanel()
        p.delegate = self
        p.onEscape = { [weak self] in self?.close() }
        let host = NSHostingView(rootView: SwitcherView(state: state, controller: self))
        host.sizingOptions = []
        p.contentView = host
        panel = p
        return p
    }

    /// Clicked into another app, or another window took the keyboard: gone, like Spotlight.
    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { close() }
    }

    // MARK: Shortcut conflicts

    /// Whether another app already holds the switcher's shortcut (ChatGPT, Raycast and Alfred all like ⌥Space).
    /// Asks the system for the hotkey exclusively for a moment: it refuses when someone else has it.
    /// A best guess: apps that watch the keyboard another way don't show up.
    func checkConflict() {
        guard let s = KeyboardShortcuts.getShortcut(for: .switcher) else { conflict = false; return }
        // Our own registration would count as someone else's.
        KeyboardShortcuts.disable(.switcher)
        var ref: EventHotKeyRef?
        let err = RegisterEventHotKey(UInt32(s.carbonKeyCode), UInt32(s.carbonModifiers),
                                      EventHotKeyID(signature: 0x4254_5357, id: 1),   // "BTSW"
                                      GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        if let ref { UnregisterEventHotKey(ref) }
        KeyboardShortcuts.enable(.switcher)
        let taken = err == OSStatus(eventHotKeyExistsErr)
        if taken != conflict { conflict = taken }
        if taken { DebugLog.log("switcher: \(s) is already taken by another app") }
    }
}
