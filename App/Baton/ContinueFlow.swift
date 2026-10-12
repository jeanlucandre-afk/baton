import AppKit
import BatonCore
import Defaults
import SwiftUI

/// "Continue in new chat": Baton runs /handoff in a Claude chat, waits for it, opens a new chat in the same
/// project, runs /handoff resume there, and tells you when the new chat is ready. It also suggests this
/// when the open chat's context passes 70%.
@Observable
final class ContinueFlow {
    static let shared = ContinueFlow()

    enum Step: Int, CaseIterable {
        case handoff, newChat, resume, ready
        var label: String {
            switch self {
            case .handoff: "Saving the handoff"
            case .newChat: "Opening a new chat"
            case .resume: "Resuming from the handoff"
            case .ready: "Ready to continue"
            }
        }
        var doneLabel: String {
            switch self {
            case .handoff: "Saved the handoff"
            case .newChat: "Opened a new chat"
            case .resume: "Resumed from the handoff"
            case .ready: "Ready to continue"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case suggest(task: UUID, percent: Int)
        case running(task: UUID, step: Step)
        case failed(task: UUID, message: String)
        case done(task: UUID, context: Int?)
    }

    private(set) var phase: Phase = .idle
    /// The handoff file's name once it's known (shown in the progress view).
    private(set) var handoffName: String?
    /// The open chat's context, per task, as Claude shows it.
    private(set) var context: [UUID: Int] = [:]
    private var job: Task<Void, Never>?
    /// Chats already suggested at 70%, so each is suggested once.
    private var suggested: Set<String> = []

    nonisolated static let claude = "com.anthropic.claudefordesktop"
    static let suggestAt = 70

    var showing: Bool { phase != .idle }
    var running: Bool { if case .running = phase { true } else { false } }

    /// Only Claude chats, where the /handoff skill runs.
    static func canContinue(_ taskID: UUID) -> Bool {
        AppModel.shared.tasks.first { $0.id == taskID }?.chat?.bundleID == claude
    }

    func title(_ id: UUID) -> String { AppModel.shared.tasks.first { $0.id == id }?.title ?? "This chat" }

    // MARK: The notch card

    private func present(_ p: Phase, closeAfter seconds: Double? = nil) {
        phase = p
        let model = AppModel.shared
        guard model.mode != .newTask else { return }   // don't take over the new-task box
        if model.mode != .ping { model.openScreen = DisplayManager.shared.screenUnderPointer() }
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
        guard !running else { return }
        phase = .idle
        handoffName = nil
        if AppModel.shared.mode == .ping { AppModel.shared.collapse() }
    }

    /// The notch closed or a ping took it: a suggested, failed or finished card goes with it, so it
    /// can't come back in place of a later ping.
    func closed() {
        guard !running, phase != .idle else { return }
        phase = .idle
        handoffName = nil
    }

    func cancel() {
        job?.cancel()
        job = nil
        phase = .idle
        handoffName = nil
        if AppModel.shared.mode == .ping { AppModel.shared.collapse() }
    }

    // MARK: Watching context (the 70% suggestion)

    /// Each sidebar poll of Claude passes on its open chat and that chat's context, read from the poll's
    /// own capture (a separate read on a timer cost as much as the poll).
    func noteContext(open name: String?, percent pct: Int?) {
        guard let name, let pct else { return }
        let model = AppModel.shared
        let tasks = model.tasks.filter { $0.chat?.bundleID == Self.claude }
        let rows = tasks.compactMap { t in t.chat.map { ChatRow(name: $0.name, status: .idle) } }
        guard let hit = Sidebar.find(name, in: rows), let task = tasks.first(where: { $0.chat?.name == hit.name }) else { return }
        if context[task.id] != pct { context[task.id] = pct }
        if pct >= Self.suggestAt, !suggested.contains(name), phase == .idle, model.mode == .collapsed {
            suggested.insert(name)
            present(.suggest(task: task.id, percent: pct), closeAfter: 12)
        }
    }

    // MARK: Running it

    func begin(_ taskID: UUID) {
        guard !running, !Relay.shared.busy, Self.canContinue(taskID) else { return }   // one flow types at a time
        handoffName = nil
        present(.running(task: taskID, step: .handoff))
        job = Task { await run(taskID) }
    }

    private typealias Stop = ChatTyper.Stop

    private func run(_ taskID: UUID) async {
        let model = AppModel.shared
        guard let chat = model.tasks.first(where: { $0.id == taskID })?.chat,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: chat.bundleID).first else {
            present(.failed(task: taskID, message: "Claude isn't open."), closeAfter: 10); return
        }
        let pid = app.processIdentifier
        do {
            // 1. Open the chat and send /handoff.
            model.openChat(chat)
            let chatName = chat.name, bundle = chat.bundleID
            let w = try await waitFor("Couldn't open \(chat.name) in Claude.", seconds: 8) {
                try await self.read { AX.windows(pid: pid).first { Sidebar.isOpen(chatName, in: $0) } }
            }
            // Read the same way the reply is read later, or an older handoff further up could pass for the new one.
            let before = try await read { Set(Composer.handoffNames(in: Self.tail(w) ?? "")) }
            try await send("/handoff", in: w, pid: pid)

            // 2. Wait until Claude has finished and its reply names the handoff file. The open chat is watched,
            // not its name: Claude may rename the chat while it works.
            let name = try await waitForHandoff(pid: pid, excluding: before)
            handoffName = name
            try checkCancelled()

            // 3. Open a new chat in the same project.
            present(.running(task: taskID, step: .newChat))
            guard let (win, root) = try await capture(pid) else { throw Stop.failed("Couldn't read Claude's window.") }
            let oldName = Sidebar.openChat(in: root, bundleID: chat.bundleID).name ?? chat.name
            guard let button = Composer.newChatButton(near: oldName, in: root) ?? Composer.newChatButton(near: chat.name, in: root) else {
                throw Stop.failed("Couldn't find Claude's “New session” button.")
            }
            // You may have gone to another app while Claude wrote the handoff; a press that falls back to a
            // real click must land in Claude.
            try await bringToFront(win)
            Composer.press(button)
            let fresh = try await waitFor("Claude didn't open a new chat.", seconds: 10) {
                try await self.read { () -> AXWindow? in
                    guard let w = AX.windows(pid: pid).first, let r = AXNode.capture(w.element, maxMillis: 300),
                          let box = Composer.find(in: r), box.text.isEmpty,
                          Sidebar.openChat(in: r, bundleID: bundle).name != oldName else { return nil }
                    return w
                }
            }

            // 4. Resume there and wait for the briefing.
            present(.running(task: taskID, step: .resume))
            try await send("/handoff resume \(name)", in: fresh, pid: pid)
            try await waitWhileWorking(pid: pid, chat: nil, start: 40, finish: 600)

            // 5. The task follows the new chat (Claude renames it later; renamed chats are followed). Not if
            // you opened another chat meanwhile: the old one, or one a task already follows, isn't the new one.
            let (newName, pct) = try await read { () -> (String?, Int?) in
                guard let r = AX.windows(pid: pid).first.flatMap({ AXNode.capture($0.element, maxNodes: 8000, maxMillis: 600) }) else { return (nil, nil) }
                return (Sidebar.openChat(in: r, bundleID: bundle).name, Composer.contextPercent(in: r))
            }
            let followed = newName.map { n in
                model.tasks.contains { $0.chat?.bundleID == bundle && Sidebar.find($0.chat?.name ?? "", in: [ChatRow(name: n, status: .idle)]) != nil }
            } ?? true
            if let newName, newName != oldName, !followed, let i = model.tasks.firstIndex(where: { $0.id == taskID }) {
                model.tasks[i].chat = ChatRecord(bundleID: chat.bundleID, appName: chat.appName, name: newName, section: chat.section)
                model.file.save(model.tasks)
                model.chatStatus[taskID] = nil
                model.missingPolls[taskID] = 0
            }
            if let pct { context[taskID] = pct }
            job = nil
            present(.done(task: taskID, context: pct), closeAfter: 10)
            model.notifyText(title: "Ready to continue", body: "\(title(taskID)) picked up from its handoff in a new chat.")
        } catch is CancellationError {
            return
        } catch Stop.failed(let message) {
            job = nil
            present(.failed(task: taskID, message: message), closeAfter: 12)
        } catch {
            job = nil
            present(.failed(task: taskID, message: "Something went wrong. Nothing else was typed."), closeAfter: 12)
        }
    }

    // The typing itself is shared with Reply and Pass (ChatTyper).
    private func checkCancelled() throws { try ChatTyper.checkCancelled() }

    private func read<T: Sendable>(_ work: @escaping @Sendable () -> T) async throws -> T { try await ChatTyper.read(work) }

    private func capture(_ pid: pid_t) async throws -> (AXWindow, AXNode)? {
        try await read {
            guard let w = AX.windows(pid: pid).first, let r = AXNode.capture(w.element, maxNodes: 8000, maxMillis: 600) else { return nil }
            return (w, r)
        }
    }

    /// The end of the open chat, where the /handoff reply names its file.
    nonisolated private static func tail(_ w: AXWindow) -> String? {
        AX.snapshot(w, wantChars: 12000, maxNodes: 8000, maxMillis: 600)?.tail
    }

    private func bringToFront(_ w: AXWindow) async throws { try await ChatTyper.bringToFront(w, app: "Claude") }

    private func waitFor<T>(_ message: String, seconds: Double, _ check: () async throws -> T?) async throws -> T {
        try await ChatTyper.waitFor(message, seconds: seconds, check)
    }

    /// Types into the window's message box and sends it (only into an empty box, only with that window in front).
    private func send(_ text: String, in w: AXWindow, pid: pid_t) async throws {
        try await ChatTyper.send(text, in: w, app: "Claude")
    }

    /// Polls the open chat until its reply names a new handoff file and Claude has stopped working
    /// (3 quiet reads in a row), for up to 10 minutes.
    private func waitForHandoff(pid: pid_t, excluding before: Set<String>) async throws -> String {
        var quiet = 0
        var found: String?
        let end = Date().addingTimeInterval(600)
        while Date() < end {
            try checkCancelled()
            let (busy, name) = try await read { () -> (Bool?, String?) in
                guard let w = AX.windows(pid: pid).first else { return (nil, nil) }
                let read = Sidebar.read(w)
                let status = read.openName.flatMap { Sidebar.find($0, in: read.rows)?.status }
                return (read.generating || status == .working, Self.tail(w).flatMap { Composer.handoffName(in: $0, excluding: before) })
            }
            if let busy { quiet = busy ? 0 : quiet + 1 }
            if let name { found = name }
            if let found, quiet >= 3 { return found }
            try await Task.sleep(for: .seconds(1))
        }
        throw Stop.failed(found == nil ? "Couldn't find the handoff file in Claude's reply." : "Claude is still working after 10 minutes. Baton stopped waiting.")
    }

    /// Waits for the chat to start working (up to `start` s), then to stop (up to `finish` s). `chat` is the
    /// sidebar name to watch; nil watches the open chat (a new chat has no settled name yet).
    private func waitWhileWorking(pid: pid_t, chat: String?, start: Double, finish: Double) async throws {
        func working() async throws -> Bool {
            try await read {
                guard let w = AX.windows(pid: pid).first else { return false }
                let read = Sidebar.read(w)
                let name = chat ?? read.openName
                let status = name.flatMap { Sidebar.find($0, in: read.rows)?.status }
                return status == .working || (read.openName == name && read.generating)
            }
        }
        do {
            _ = try await waitFor("", seconds: start) { try await working() ? true : nil }
        } catch Stop.failed {
            return   // it may have finished before we looked; the next step checks the result
        }
        var quiet = 0
        let end = Date().addingTimeInterval(finish)
        while Date() < end {
            try checkCancelled()
            quiet = try await working() ? 0 : quiet + 1
            if quiet >= 3 { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw Stop.failed("Claude is still working after \(Int(finish / 60)) minutes. Baton stopped waiting.")
    }
}

// MARK: The card

struct ContinueView: View {
    private var flow = ContinueFlow.shared
    private var model = AppModel.shared

    var body: some View {
        switch flow.phase {
        case .idle: EmptyView()
        case let .suggest(task, percent): suggestion(task, percent)
        case let .running(task, step): progress(task, step)
        case let .failed(task, message): failure(task, message)
        case let .done(task, context): ready(task, context)
        }
    }

    private func suggestion(_ task: UUID, _ percent: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(.white.opacity(0.12), lineWidth: 3)
                    Circle().trim(from: 0, to: CGFloat(percent) / 100)
                        .stroke(Palette.context, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    AppIcon(bundleID: ContinueFlow.claude, size: 24)
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(flow.title(task)) is \(percent)% full").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Tag("Context", color: Palette.context)
                    }
                    Text("Continue in a fresh chat before Claude compacts it. Baton runs /handoff and picks up there.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(2)
                }
            }
            Divider().overlay(.white.opacity(0.13))
            HStack {
                Spacer()
                TextButton("Not now", color: Palette.secondary) { flow.dismiss() }
                TextButton("Continue in new chat ⏎", color: Palette.ready) { flow.begin(task) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func progress(_ task: UUID, _ step: ContinueFlow.Step) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                AppIcon(bundleID: ContinueFlow.claude, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Moving \(flow.title(task)) to a new chat").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("Hands off for a moment: Baton is typing in Claude.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                TextButton("Cancel", color: Palette.secondary) { flow.cancel() }
            }
            .padding(.bottom, 10)
            ForEach(ContinueFlow.Step.allCases, id: \.self) { s in
                Divider().overlay(.white.opacity(0.08))
                HStack(spacing: 12) {
                    Group {
                        if s.rawValue < step.rawValue {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.done)
                                .transition(.scale.combined(with: .opacity))
                        } else if s == step {
                            ProgressView().controlSize(.small).tint(Palette.working)
                        } else {
                            Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1.5).frame(width: 8, height: 8)
                        }
                    }
                    .frame(width: 18)
                    Text(s.rawValue < step.rawValue ? s.doneLabel : s.label)
                        .font(.system(size: 13, weight: s == step ? .semibold : .regular))
                        .foregroundStyle(s.rawValue > step.rawValue ? Palette.secondary : .white)
                    Spacer()
                    if s == .handoff, let name = flow.handoffName {
                        Text(name + ".md").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary).lineLimit(1)
                    }
                }
                .padding(.vertical, 8)
            }
            WorkingBar(width: 500).padding(.top, 8)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: step)
    }

    private func failure(_ task: UUID, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AppIcon(bundleID: ContinueFlow.claude, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Couldn't continue \(flow.title(task))").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(message).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(2)
                }
            }
            Divider().overlay(.white.opacity(0.13))
            HStack {
                Spacer()
                TextButton("Close", color: Palette.secondary) { flow.dismiss() }
                TextButton("Try again", color: Palette.ready) { flow.begin(task) }
            }
        }
    }

    private func ready(_ task: UUID, _ context: Int?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    AppIcon(bundleID: ContinueFlow.claude, size: 26).opacity(0.45)
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.ready)
                    AppIcon(bundleID: ContinueFlow.claude, size: 40).modifier(Halo(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Ready to continue").font(.system(size: 14, weight: .semibold))
                        Tag("New chat", color: Palette.ready)
                    }
                    Text("\(flow.title(task)) picked up from its handoff.\(context.map { " Context \($0)%." } ?? "")")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
                }
            }
            Divider().overlay(.white.opacity(0.13))
            HStack {
                Text("The old chat stays where it is. Your task now follows the new one.")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
                Spacer()
                TextButton("Later", color: Palette.secondary) { flow.dismiss() }
                TextButton("Jump ⏎", color: Palette.ready) { flow.dismiss(); model.jump(task) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct Tag: View {
    let text: String
    let color: Color
    init(_ text: String, color: Color) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(color)
    }
}

/// A plain text button, like "Open ›" in the task list.
struct TextButton: View {
    let title: String
    let color: Color
    let action: () -> Void
    @State private var hover = false
    init(_ title: String, color: Color, action: @escaping () -> Void) { self.title = title; self.color = color; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
                .underline(hover, color: color.opacity(0.7))
                .padding(.leading, 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// How full a Claude chat is: a small bar, amber from 50%.
struct ContextBar: View {
    let percent: Int
    var body: some View {
        HStack(spacing: 6) {
            Capsule().fill(.white.opacity(0.14)).frame(width: 44, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(percent >= 50 ? Palette.context : Palette.secondary).frame(width: 44 * CGFloat(min(percent, 100)) / 100, height: 4)
                }
            Text("Context \(percent)%").font(.system(size: 11, weight: percent >= 50 ? .semibold : .regular))
                .foregroundStyle(percent >= 50 ? Palette.context : Palette.secondary)
        }
    }
}

extension Palette {
    static let context = Color(red: 1.0, green: 0.70, blue: 0.42)
    static let done = Color(red: 0.56, green: 0.84, blue: 0.66)
}
