import AppKit
import BatonCore

/// Noticing chats you start in Claude, ChatGPT, Cursor or Grok Bot and offering to track them:
/// add to the task they belong to, start a new task, or ignore. Baton always asks first.
extension AppModel {
    nonisolated static let newChatApps: Set<String> = [
        "com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex",
        "com.anysphere.sand", "com.todesktop.230313mzl4w4u92",
    ]
    /// Names apps give a chat before it has a real one.
    nonisolated static let placeholderChatNames: Set<String> = [
        "new chat", "new conversation", "untitled", "new session", "new agent", "new thread", "new task",
        "chatgpt", "claude", "cursor",
        // Claude Code names a session after the command that started it, then renames it.
        "handoff resume", "handoff", "resume handoff",
    ]

    /// A name the app gives a chat before it has a real one; the new-chat card waits for the real name.
    nonisolated static func isPlaceholder(_ name: String) -> Bool {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        // "/handoff resume acme" starts as "Handoff resume Acme" until Claude names it.
        // A web address is a link someone read out of a reply, never a chat's name.
        return placeholderChatNames.contains(n) || n.hasPrefix("/") || n.hasPrefix("handoff resume ")
            || n.hasPrefix("http://") || n.hasPrefix("https://") || n.hasPrefix("www.")
    }

    /// A chat counts as new when it shows up in an app's sidebar after Baton first read that app, has a
    /// real name, and is the one open or busy (older chats scrolling into view are neither), two reads in a row.
    func detectNewChats(_ read: [String: [ChatRow]]) {
        let tracked = Set(tasks.compactMap { t in t.chat.map { "\($0.bundleID)|\($0.name.lowercased())" } })
        for (b, rows) in read where Self.newChatApps.contains(b) {
            // A chat this read didn't count starts over: "two reads in a row" means in a row.
            var counted = Set<String>()
            defer { newChatSeen = newChatSeen.filter { !$0.key.hasPrefix(b + "|") || counted.contains($0.key) } }
            guard health.trusted(healthKey(b)) else { continue }
            // Apps with tabs list each tab's chats separately: seeing a tab for the first time isn't news.
            let tab = appTabs[b]?.first(where: \.selected)?.name
            let k = tab.map { "\(b)|\($0)" } ?? b
            guard var known = knownChats[k] else { knownChats[k] = Set(rows.map(\.name)); continue }
            for r in rows where !known.contains(r.name) {
                if Self.isPlaceholder(r.name) { continue }
                let fresh = r.status != .idle || openChatNames[b].map { Sidebar.find(r.name, in: [ChatRow(name: $0, status: .idle)]) != nil } == true
                guard fresh else { known.insert(r.name); continue }
                let key = "\(b)|\(r.name)"
                counted.insert(key)
                newChatSeen[key, default: 0] += 1
                guard newChatSeen[key, default: 0] >= 2 else { continue }
                known.insert(r.name)
                newChatSeen[key] = nil
                guard !tracked.contains("\(b)|\(r.name.lowercased())") else { continue }
                let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first?.localizedName ?? b
                let chat = ChatRecord(bundleID: b, appName: app, name: r.name, section: tab)
                Task { await suggestTask(for: chat) }
            }
            knownChats[k] = known
        }
    }

    /// Picks the task a new chat most likely belongs to (Jev, or word overlap without it), then asks.
    func suggestTask(for chat: ChatRecord) async {
        let tops = topRows
        var target: TaskRow?
        let lexical = tops.map { t in (t, ([t.title] + t.children.map(\.title)).map { NewTaskView.score($0, chat.name) }.max() ?? 0) }
            .max { $0.1 < $1.1 }
        if let l = lexical, l.1 >= 0.5 { target = l.0 }
        if let jev = classifier, !tops.isEmpty {
            var options: [String: String] = ["none": "Something new, unrelated to every task listed"]
            for (i, t) in tops.prefix(20).enumerated() {
                let kids = t.children.map { "\"\(Redact.clean($0.title))\"" }.joined(separator: ", ")
                options["t\(i)"] = "Task \"\(Redact.clean(t.title))\"" + (kids.isEmpty ? "" : " (includes \(kids))")
            }
            let state: [String: any Sendable] = ["new_chat": "\(chat.appName) chat titled \"\(Redact.clean(chat.name))\""]
            if let probs = try? await jev.choose(state: state,
                                                 instructions: "The user just started this chat. Which of their tasks is it part of?",
                                                 options: options),
               let best = probs.max(by: { $0.value < $1.value }) {
                if best.key == "none" { target = nil }
                else if best.value >= 0.45, let i = Int(best.key.dropFirst()), tops.indices.contains(i) { target = tops[i] }
            }
        }
        offer(ChatSuggestion(chat: chat, target: target?.id, targetTitle: target?.title))
    }

    /// Shows the card now if the notch is free, otherwise after whatever is open closes.
    func offer(_ s: ChatSuggestion) {
        guard mode == .collapsed, !idlePaused else {
            if !suggestionQueue.contains(where: { $0.chat == s.chat }) { suggestionQueue.append(s) }
            return
        }
        chatSuggestion = s
        openScreen = DisplayManager.shared.screenUnderPointer()
        mode = .newChat
        suggestionTimer?.cancel()
        // Unanswered after a while: the card closes; the chat still shows under "Looks like you're working on".
        // Hovered: it stays until the pointer leaves (see cardDeadline).
        cardDeadline = Date().addingTimeInterval(25)
        suggestionTimer = Task {
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled else { return }
            if mode == .newChat && !hoveringContent { collapse() }
        }
    }

    func acceptSuggestion(into target: UUID?) {
        guard let s = chatSuggestion else { return }
        let id = createTask(title: s.chat.name, windows: [], chat: s.chat)
        if let target { group(id, with: target) }
        collapse()
    }

    func ignoreSuggestion() { collapse() }
}
