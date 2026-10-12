import AppKit
import BatonCore
import Observation

/// Reply from the notch and "Pass to": Baton types into a chat for you, only after you click or press ⏎
/// in Baton. It brings the chat forward, checks the box is that chat's and empty, pastes, and sends (a pass
/// is only typed, unless you chose "Pass and send"). Anything off and it stops, opens the chat instead,
/// and the text waits on the clipboard.
@Observable
final class Relay {
    static let shared = Relay()

    /// The chat a reply goes to.
    struct ReplyTarget: Equatable {
        /// The task (or, for a chat you don't track, the ping's own id).
        let id: UUID
        let chat: ChatRecord
        let title: String
        /// What the ping said, if a ping led here.
        var line: String?
    }

    enum Phase: Equatable {
        case idle
        case composing(ReplyTarget)
        case working(bundleID: String, title: String)
        case failed(bundleID: String, title: String, message: String)
        case done(bundleID: String, title: String, message: String)
    }

    private(set) var phase: Phase = .idle
    /// Quick answers per chat, from how it ends.
    private(set) var chips: [UUID: [String]] = [:]
    /// The notch holds the keyboard for the reply field.
    private(set) var typing = false
    @ObservationIgnored private var origin: ChatTyper.Origin?
    @ObservationIgnored private var job: Task<Void, Never>?
    private typealias Stop = ChatTyper.Stop

    var showing: Bool { phase != .idle }
    var busy: Bool { if case .working = phase { true } else { false } }
    /// A reply being typed or sent: a ping arriving now doesn't take the card (its sound and notification still go).
    var holdsCard: Bool {
        if busy || typing { return true }
        if case .composing = phase { return true }
        return false
    }

    // MARK: Who can reply, who can pass

    /// A ping about a chat: tracked tasks with a chat, and named chats you don't track.
    static func target(for p: Ping) -> ReplyTarget? {
        if let c = p.waiting { return c.name.isEmpty ? nil : ReplyTarget(id: p.taskID, chat: c, title: c.name, line: p.text) }
        guard let t = AppModel.shared.tasks.first(where: { $0.id == p.taskID }), !t.isGroup, let c = t.chat else { return nil }
        return ReplyTarget(id: t.id, chat: c, title: t.title, line: p.text)
    }

    /// A task with a chat that isn't busy working.
    static func target(task id: UUID) -> ReplyTarget? {
        let model = AppModel.shared
        guard let t = model.tasks.first(where: { $0.id == id }), !t.isGroup, let c = t.chat,
              model.chatStatus[id] != .working else { return nil }
        return ReplyTarget(id: id, chat: c, title: t.title, line: model.lines[id])
    }

    static func canReply(_ row: TaskRow) -> Bool { !row.isGroup && row.group == .ready && target(task: row.id) != nil }

    static func canPass(_ id: UUID) -> Bool {
        guard let t = AppModel.shared.tasks.first(where: { $0.id == id }) else { return false }
        return !t.isGroup && (t.chat != nil || !t.windows.isEmpty)
    }

    // MARK: The card

    private func present(_ p: Phase, closeAfter seconds: Double? = nil) {
        phase = p
        let model = AppModel.shared
        guard model.mode != .newTask else { return }   // don't take over the new-task box
        if model.mode != .ping { model.openScreen = DisplayManager.shared.screenUnderPointer() }
        model.stopPingTimer()
        model.mode = .ping
        model.cardDeadline = seconds.map { Date().addingTimeInterval($0) }
        if let seconds {
            let shown = p
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard self.phase == shown else { return }
                if !model.hoveringContent { self.dismiss() }
            }
        }
    }

    func dismiss() {
        guard !busy else { return }
        releaseKeyboard()
        phase = .idle
        if AppModel.shared.mode == .ping { AppModel.shared.collapse() }
    }

    /// The notch closed or a ping took it: a reply card, failed or sent card goes with it.
    func closed() {
        guard !busy else { return }
        releaseKeyboard()
        if phase != .idle { phase = .idle }
    }

    // MARK: Typing in the notch

    /// Opens the reply card for a chat: a field that takes the keyboard straight away.
    func compose(_ t: ReplyTarget) {
        guard !busy, !ContinueFlow.shared.running else { return }
        refreshChips(t)
        present(.composing(t))
    }

    func compose(task id: UUID) { if let t = Self.target(task: id) { compose(t) } }

    #if DEBUG
    /// Sets the card's state for #Preview only.
    func preview(_ p: Phase) { phase = p }
    #endif

    /// The notch takes the keyboard for the field (the panel only does when asked). Where you were is
    /// remembered first, to go back there after sending.
    func takeKeyboard() {
        if !typing {
            origin = ChatTyper.Origin.current()
            DisplayManager.shared.rememberFrontApp()
        }
        // Again after you clicked into another app and came back to the field.
        if let id = AppModel.shared.openScreen, let panel = DisplayManager.shared.slots[id]?.panel, !panel.isKeyWindow {
            panel.allowKey = true
            panel.makeKeyAndOrderFront(nil)
        }
        typing = true
    }

    /// Gives the keyboard back. Before Baton types anywhere, so keystrokes can't land in the notch.
    func releaseKeyboard() {
        guard typing else { return }
        typing = false
        DisplayManager.shared.resignKey()
    }

    /// Reads how the chat ends, if it's the one open in its window, and picks the quick answers. The
    /// ping's line stands in when the chat isn't on screen.
    func refreshChips(_ t: ReplyTarget) {
        let name = t.chat.name, id = t.id, line = t.line ?? ""
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: t.chat.bundleID).first?.processIdentifier else {
            chips[id] = QuickReplies.suggest(tail: line); return
        }
        Task {
            let snap = await Task.detached(priority: .userInitiated) { () -> Snapshot? in
                guard let w = AX.windows(pid: pid).first(where: { Sidebar.isOpen(name, in: $0) }) else { return nil }
                return AX.snapshot(w, wantChars: 900, maxNodes: 6000, maxMillis: 300)
            }.value
            let found = snap.map { QuickReplies.suggest(tail: $0.tail, buttons: $0.buttons) } ?? QuickReplies.suggest(tail: line)
            if chips[id] != found { chips[id] = found }
        }
    }

    // MARK: Reply

    /// Sends `text` to the chat. Only from a click or ⏎ in Baton.
    func reply(_ t: ReplyTarget, text raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, !ContinueFlow.shared.running else { return }
        let origin = typing ? self.origin : ChatTyper.Origin.current()
        releaseKeyboard()
        let clip = ChatTyper.putOnClipboard(text)
        present(.working(bundleID: t.chat.bundleID, title: "Sending to \(t.chat.appName)"))
        job = Task { await runReply(t, text: text, clip: clip, origin: origin) }
    }

    private func runReply(_ t: ReplyTarget, text: String, clip: Int, origin: ChatTyper.Origin?) async {
        let model = AppModel.shared
        let app = t.chat.appName, name = t.chat.name
        do {
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: t.chat.bundleID).first else {
                throw Stop.failed("\(app) isn't open.")
            }
            let pid = running.processIdentifier
            model.openChat(t.chat)
            let w = try await ChatTyper.waitFor("Couldn't open the chat in \(app).", seconds: 8) {
                try await ChatTyper.read { AX.windows(pid: pid).first { Sidebar.isOpen(name, in: $0) } }
            }
            try await ChatTyper.paste(text, clip: clip, in: w, app: app, expect: .chat(name))
            try await ChatTyper.submit(text, in: w, app: app, expect: .chat(name))
            job = nil
            model.acknowledge(t.id)
            ChatTyper.restore(origin, unless: pid)
            present(.done(bundleID: t.chat.bundleID, title: "Sent to \(app)", message: t.title), closeAfter: 3)
        } catch is CancellationError {
            return
        } catch {
            job = nil
            let why = if case Stop.failed(let m) = error { m } else { "Something went wrong." }
            // The chat is yours to finish in: open it, the reply is on the clipboard.
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: t.chat.bundleID).isEmpty
            model.openChat(t.chat)
            present(.failed(bundleID: t.chat.bundleID, title: running ? "Couldn't send — opened the chat instead" : "Couldn't send",
                            message: "\(why) Your reply is on the clipboard."), closeAfter: 12)
        }
    }

    // MARK: Pass

    /// Starts a new chat in `target` with a handoff of the task typed in. Sent only with `send`.
    func pass(_ taskID: UUID, to target: PassTarget, send: Bool) {
        guard !busy, !ContinueFlow.shared.running,
              let task = AppModel.shared.tasks.first(where: { $0.id == taskID }), Self.canPass(taskID) else { return }
        let origin = ChatTyper.Origin.current()
        present(.working(bundleID: target.bundleID, title: "Passing to \(target.name)"))
        job = Task { await runPass(task, to: target, send: send, origin: origin) }
    }

    private func runPass(_ task: BatonTask, to target: PassTarget, send: Bool, origin: ChatTyper.Origin?) async {
        var copied = false
        do {
            let tail = try await sourceTail(task)
            let from = task.chat?.appName ?? task.windows.first?.appName ?? "another app"
            let note = PassNote.build(title: task.title, from: from, steps: task.steps, next: task.next, tail: tail)
            let clip = ChatTyper.putOnClipboard(note)
            copied = true
            let pid = try await launch(target)
            let near = task.chat?.bundleID == target.bundleID ? task.chat?.name : nil
            let w = try await freshChat(pid: pid, target: target, near: near)
            try await ChatTyper.paste(note, clip: clip, in: w, app: target.name, expect: .fresh)
            if send {
                try await ChatTyper.submit(note, in: w, app: target.name, expect: .fresh)
                ChatTyper.restore(origin, unless: pid)
            }
            job = nil
            present(send ? .done(bundleID: target.bundleID, title: "Passed to \(target.name)", message: "\(task.title) carries on there.")
                         : .done(bundleID: target.bundleID, title: "Handoff ready in \(target.name)", message: "Check it, then press Send there."),
                    closeAfter: send ? 5 : 8)
        } catch is CancellationError {
            return
        } catch {
            job = nil
            let why = if case Stop.failed(let m) = error { m } else { "Something went wrong." }
            NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).first?.activate()
            present(.failed(bundleID: target.bundleID, title: "Couldn't pass to \(target.name)",
                            message: why + (copied ? " The handoff is on your clipboard." : "")), closeAfter: 12)
        }
    }

    /// How the task's chat ends, read where it's open (opened first if need be). Nil if it can't be read:
    /// the note still carries the title, steps and next action.
    private func sourceTail(_ task: BatonTask) async throws -> String? {
        if let c = task.chat {
            guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: c.bundleID).first?.processIdentifier else { return nil }
            let name = c.name
            let open: @Sendable () -> AXWindow? = { AX.windows(pid: pid).first { Sidebar.isOpen(name, in: $0) } }
            var w = try await ChatTyper.read(open)
            if w == nil {
                AppModel.shared.openChat(c)
                w = try? await ChatTyper.waitFor("", seconds: 6) { try await ChatTyper.read(open) }
            }
            guard let w else { return nil }
            return try await ChatTyper.read { AX.snapshot(w, wantChars: 1500, maxNodes: 8000, maxMillis: 600)?.tail }
        }
        guard let w = AppModel.shared.live.values.first(where: { $0.taskIDs.contains(task.id) })?.window else { return nil }
        return try await ChatTyper.read { AX.snapshot(w, wantChars: 1500, maxNodes: 8000, maxMillis: 600)?.tail }
    }

    /// The target app's pid, opening it if it isn't running and waiting for its first window.
    private func launch(_ target: PassTarget) async throws -> pid_t {
        let app: NSRunningApplication
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).first {
            app = running
        } else {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID) else {
                throw Stop.failed("\(target.name) isn't installed.")
            }
            app = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        let pid = app.processIdentifier
        AX.enableTree(pid: pid)
        _ = try await ChatTyper.waitFor("\(target.name) didn't open a window.", seconds: 15) {
            try await ChatTyper.read { AX.windows(pid: pid).first }
        }
        return pid
    }

    /// A window showing a new, empty chat: the one in front if it already is, else after pressing the
    /// app's New chat button (clicked like a person if the app ignores the press, only with it in front).
    private func freshChat(pid: pid_t, target: PassTarget, near: String?) async throws -> AXWindow {
        let name = target.name, bundle = target.bundleID
        let fresh: @Sendable () -> AXWindow? = {
            AX.windows(pid: pid).first { w in
                guard let r = AXNode.capture(w.element, maxNodes: 8000, maxMillis: 500) else { return false }
                return (try? TypingTarget.check(r, bundleID: bundle, expect: .fresh).get()) != nil
            }
        }
        guard let w0 = try await ChatTyper.read({ AX.windows(pid: pid).first }) else { throw Stop.failed("Couldn't find a \(name) window.") }
        try await ChatTyper.bringToFront(w0, app: name)
        if let w = try await ChatTyper.read(fresh) { return w }
        let button = try await ChatTyper.read { AXNode.capture(w0.element, maxNodes: 8000, maxMillis: 600).flatMap { Composer.freshChatButton(in: $0, near: near) } }
        guard let button else { throw Stop.failed("Couldn't find \(name)'s New chat button.") }
        guard ChatTyper.isFront(w0) else { throw Stop.failed("\(name) went to the background, so Baton stopped.") }
        Composer.press(button)
        do {
            return try await ChatTyper.waitFor("", seconds: 3) { try await ChatTyper.read(fresh) }
        } catch Stop.failed {
            guard ChatTyper.isFront(w0), let el = button.element else { throw Stop.failed("\(name) didn't open a new chat.") }
            AX.click(el)
            return try await ChatTyper.waitFor("\(name) didn't open a new chat.", seconds: 5) { try await ChatTyper.read(fresh) }
        }
    }
}
