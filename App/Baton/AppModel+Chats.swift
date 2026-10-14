import AppKit
import BatonCore
import Defaults
import UserNotifications

/// Following chats through each app's own sidebar, and what happens when an app update stops Baton
/// from reading it: no guessing, watch the window instead, and re-learn the sidebar.
extension AppModel {
    /// A chat task is followed through its app's sidebar, unless that sidebar can't be read right now:
    /// then its window is watched like any other (Jev decides).
    func followsChat(_ task: UUID) -> Bool {
        guard let c = tasks.first(where: { $0.id == task })?.chat else { return false }
        return fallbackLive[c.bundleID] == nil
    }

    /// Every chat with a live status across the AI apps, for the new-task box.
    var allChats: [(ChatRecord, ChatStatus)] {
        chatRows.flatMap { bundle, rows in
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName ?? bundle
            let tab = appTabs[bundle]?.first(where: \.selected)?.name
            return rows.map { (ChatRecord(bundleID: bundle, appName: app, name: $0.name, section: tab), $0.status) }
        }
        .sorted { a, b in
            let order: [ChatStatus] = [.needsInput, .unread, .working, .idle]
            return (order.firstIndex(of: a.1) ?? 9) < (order.firstIndex(of: b.1) ?? 9)
        }
    }

    /// What one poll read from one app's windows.
    nonisolated struct AppRead: Sendable {
        var rows: [ChatRow] = []
        /// The open chats whose stop button is showing.
        var generating: [String] = []
        var openName: String?
        /// How full the open chat's context is (Claude), for the "Continue in new chat" suggestion.
        var context: Int?
        /// Usage buttons in the window ("Usage: … Weekly · all models: 39% …", "Usage 100%"), for the usage line.
        var usageLabels: [String] = []
        /// Each window's open chat, so window tasks can switch to following it without another read.
        var openByWindow: [AXWindow: String] = [:]
        /// Followed chats showing a status word Baton doesn't know (chat name → word).
        var unknown: [String: String] = [:]
        var tabs: [Sidebar.Section] = []
        /// A window's read hit its time or size limit: chats missing from it prove nothing.
        var truncated = false
        /// The first window's row names in order, duplicates kept, to notice renamed chats.
        var names: [String] = []
        /// Folder headers, which are never chats.
        var folders: [String] = []
    }

    /// Reads the sidebars of apps that have chat tasks (and every AI app while the notch is open).
    /// One poll at a time: a call while one runs asks for one more pass instead, so "missing two
    /// reads in a row" really means two reads.
    func pollSidebars() async {
        guard axTrusted else { return }
        guard !polling else { pollAgain = true; DebugLog.log("poll skipped: one still running"); return }
        polling = true
        repeat {
            pollAgain = false
            await pollOnce()
        } while pollAgain && axTrusted
        polling = false
    }

    private func pollOnce() async {
        var bundles = Set(tasks.compactMap { $0.chat?.bundleID })
        // Window tasks in chat apps too, so they can switch to following their chat.
        bundles.formUnion(tasks.filter { $0.chat == nil }.flatMap(\.windows).map(\.bundleID).filter(Self.chatApps.contains))
        if mode != .collapsed { bundles.formUnion(Self.aiApps) }
        // Every few polls, also read the apps where you start chats, to notice new ones.
        sweepCount += 1
        // Nothing tracked, nobody looking and nothing running at the last read: no chat can start or finish
        // without you, so the sweep waits until you're back (then the next one notices what changed).
        let dormant = tasks.isEmpty && notLooking && !anythingRunning
        if sweepCount % 3 == 0, !dormant {
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            bundles.formUnion(Self.newChatApps.intersection(running))
        }
        guard !bundles.isEmpty else { return }
        let wanted = bundles
        // Followed chats per app, to look for one whose status word Baton doesn't know.
        let followed = Dictionary(grouping: tasks.compactMap(\.chat), by: \.bundleID).mapValues { $0.map(\.name) }
        let started = Date()
        let (result, front): ([String: AppRead], FrontWindow?) = await Task.detached(priority: .utility) {
            var out: [String: AppRead] = [:]
            for app in NSWorkspace.shared.runningApplications {
                guard let b = app.bundleIdentifier, wanted.contains(b) else { continue }
                let wins = AX.windows(pid: app.processIdentifier)
                guard !wins.isEmpty else { continue }
                AX.enableTree(pid: app.processIdentifier)
                var r = AppRead()
                var roots: [AXNode] = []
                // One capture per window serves the rows, the open chat, the tabs and unknown words.
                for (i, w) in wins.prefix(2).enumerated() {
                    let read = Sidebar.read(w)
                    r.rows += read.rows.filter { x in !r.rows.contains(where: { $0.name == x.name }) }
                    // The open chat's stop button: the only working signal some apps (Cursor) give.
                    if read.generating, let n = read.openName { r.generating.append(n) }
                    if r.openName == nil, let n = read.openName {
                        r.openName = n
                        if b == ContinueFlow.claude, let root = read.root { r.context = Composer.contextPercent(in: root) }
                    }
                    if let n = read.openName { r.openByWindow[w] = n }
                    // Apps with tabs that each list their own chats (Claude: Claude / Code)
                    if i == 0 { r.tabs = read.sections; r.names = read.names }
                    r.folders += read.folders
                    if read.truncated { r.truncated = true }
                    if let root = read.root {
                        roots.append(root)
                        if UsageMonitor.windowApps.contains(b) { r.usageLabels += UsageReader.labels(in: root) }
                    }
                }
                // A followed chat missing from the rows: is it showing a status word Baton doesn't know?
                if !Profiles.shared.current.profile(b).leading.isEmpty {
                    for name in followed[b] ?? [] where Sidebar.find(name, in: r.rows) == nil {
                        if let word = roots.lazy.compactMap({ Sidebar.unknownStatusWord(for: name, in: $0) }).first { r.unknown[name] = word }
                    }
                }
                out[b] = r
            }
            // Here too, not on the main thread: asking for it waits on the front app.
            return (out, AX.focusedWindow().map { FrontWindow(pid: $0.pid, element: $0.element) })
        }.value
        // Only what changed since the last poll is logged (and slow polls), so poll.log stays small.
        let took = Int(Date().timeIntervalSince(started) * 1000)
        if took >= 1000 { DebugLog.log("slow poll front=\(DebugLog.front) took=\(took)ms wanted=\(wanted.count) read=\(result.count)") }
        for (b, r) in result where followed[b] != nil {
            let mine = (followed[b] ?? []).map { n in "\(n)=\(Sidebar.find(n, in: r.rows).map { "\($0.status)" } ?? "-")" }
            DebugLog.changed("app|\(b)", "\(b.split(separator: ".").last ?? "") front=\(DebugLog.front) rows=\(r.rows.count)\(r.truncated ? " TRUNCATED" : "") open=\(r.openName ?? "-") gen=\(r.generating) tabs=\(r.tabs.map { "\($0.name)\($0.selected ? "*" : "")\($0.activity.map { "(\($0))" } ?? "")" }) health=\(health.verdict(healthKey(b))) | \(mine.joined(separator: " | "))")
        }
        for b in wanted where followed[b] != nil { DebugLog.changed("read|\(b)", result[b] == nil ? "\(b) NOT READ (no window?)" : "\(b) read") }
        // The front window's open chat, as this poll read it: the focus timer uses it instead of walking the
        // window again (47 ms a time in Cursor). Only a name counts; no name, and the focus timer reads itself.
        if (lastFocusRead?.at ?? .distantPast) < started, let f = front,
           let open = result.values.lazy.flatMap(\.openByWindow).first(where: { $0.key.pid == f.pid && CFEqual($0.key.element, f.element) })?.value {
            lastFocusRead = (f.pid, f.element, started, open)
        }
        if let r = result[ContinueFlow.claude] { ContinueFlow.shared.noteContext(open: r.openName, percent: r.context) }
        for (b, r) in result where !r.usageLabels.isEmpty { UsageMonitor.shared.note(bundle: b, labels: r.usageLabels) }
        // An app that quit or has no window: nothing to read, and nothing to conclude.
        for b in wanted where result[b] == nil && chatRows[b] != nil { chatRows[b] = nil }
        for (b, r) in result {
            // A window with no tabs and no chats, in an app that has tabs (Claude starting up or reloading):
            // nothing's been drawn yet. It mustn't count against the reader's health, which would also be
            // filed under the app without its tab and then never clear.
            let loading = r.tabs.isEmpty && r.rows.isEmpty && !(appTabs[b] ?? []).isEmpty
            // A read cut short can miss the tab switch: keep the tabs last seen rather than lose the tab rule.
            let tabs = (r.truncated || loading) && r.tabs.isEmpty ? appTabs[b] ?? [] : r.tabs
            if chatRows[b] != r.rows { chatRows[b] = r.rows }
            // A read cut short may not have reached the stop button (Cursor answers slowly while it streams):
            // keep the stop buttons seen last until a full read says they're gone.
            let generating = r.truncated ? Array(Set(r.generating + (generatingChats[b] ?? []))).sorted() : r.generating
            if generatingChats[b] != generating { generatingChats[b] = generating }
            if openChatNames[b] != r.openName { openChatNames[b] = r.openName }
            if unknownStatusWords[b] != r.unknown { unknownStatusWords[b] = r.unknown }
            if appTabs[b] != tabs { appTabs[b] = tabs }
            // What each hidden tab's button showed when you left it (see the hidden-tab rule).
            for tab in tabs {
                let key = "\(b)|\(tab.name)"
                if tab.selected {
                    tabBaseline[key] = nil
                    tabSeenWorking.remove(key)
                    if let open = r.openName { lastOpenInTab[key] = open }
                } else if tabBaseline[key] == nil || tab.status == .working {
                    // Seen working: the chat finishing is any change from here on.
                    tabBaseline[key] = .some(tab.activity)
                    if tab.status == .working { tabSeenWorking.insert(key) } else { tabSeenWorking.remove(key) }
                }
            }
            // A partial read looks like chats vanishing: it says nothing about the reader's health.
            if !r.truncated && !loading { checkHealth(b, rows: r.rows); followRenames(b, r); followHandoffs(b, r) }
            unfollowFolders(b, r.folders)
        }
        pollsSinceSave += 1
        if pollsSinceSave >= 30 { health.save(); pollsSinceSave = 0 }
        migrateWindowTasksToChats(open: result.values.reduce(into: [:]) { $0.merge($1.openByWindow) { a, _ in a } })
        applyChatStatuses(cutShort: Set(result.filter(\.value.truncated).keys))
        detectNewChats(result.filter { !$0.value.truncated }.mapValues(\.rows))
        if let r = result[Self.claude] { pingWaitingClaudeChats(r) }
    }

    /// Some app showed a chat running at its last read (a working row, a stop button, a tab saying working).
    var anythingRunning: Bool {
        chatRows.values.contains { $0.contains { $0.status == .working } }
            || generatingChats.values.contains { !$0.isEmpty }
            || appTabs.values.contains { $0.contains { $0.status == .working } }
            || !tabSeenWorking.isEmpty
    }

    /// A chat continued with /handoff ("Baton · Part 6"): the task that followed the earlier part moves on
    /// to it, and an old task left behind goes (see `Handoff.follow`). No new-chat card for it.
    private func followHandoffs(_ b: String, _ r: AppRead) {
        let tab = r.tabs.first(where: \.selected)?.name
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first?.localizedName ?? b
        var changed = false
        for row in r.rows where row.name.contains("· Part") {
            let before = Set(tasks.map(\.id))
            guard let old = Handoff.follow(&tasks, newChat: ChatRecord(bundleID: b, appName: app, name: row.name, section: tab))
            else { continue }
            changed = true
            for id in before.subtracting(tasks.map(\.id)) { chatStatus[id] = nil; missingPolls[id] = nil; lines[id] = nil }
            if let t = tasks.first(where: { $0.chat?.bundleID == b && $0.chat?.name == row.name }) { missingPolls[t.id] = 0 }
            knownChats[tab.map { "\(b)|\($0)" } ?? b, default: []].insert(row.name)
            DebugLog.log("  HANDOFF \(old) -> \(row.name)")
        }
        if changed { file.save(tasks) }
    }

    /// Chats get renamed: Claude names a "/handoff resume" session once it knows what it's about. The task
    /// keeps following its chat under the new name instead of losing it (and, untracked, the real name
    /// is what the new-chat card offers).
    private func followRenames(_ b: String, _ r: AppRead) {
        let tab = r.tabs.first(where: \.selected)?.name
        let key = tab.map { "\(b)|\($0)" } ?? b
        defer { lastRowNames[key] = r.names }
        guard let before = lastRowNames[key], let (old, new) = Sidebar.rename(from: before, to: r.names) else { return }
        // Another chat still has the old name (two "Handoff resume"s): only a task made in the last half hour moves.
        let ambiguous = r.names.contains(old)
        var moved = false
        for i in tasks.indices {
            guard let c = tasks[i].chat, c.bundleID == b, c.name == old, tab == nil || (c.section ?? "Code") == tab,
                  !ambiguous || Date().timeIntervalSince(tasks[i].createdAt) < 1800 else { continue }
            tasks[i].chat?.name = new
            if tasks[i].title.lowercased() == old.lowercased() || Self.isPlaceholder(tasks[i].title) {
                tasks[i].title = new
            }
            missingPolls[tasks[i].id] = 0
            knownChats[key, default: []].insert(new)
            moved = true
        }
        if moved { file.save(tasks) }
    }

    /// A task following a folder header ("baton" above its sessions) can't be read or opened: pressing
    /// it folds the folder. Older readers took headers for chats; such a task goes back to a plain task.
    private func unfollowFolders(_ b: String, _ folders: [String]) {
        guard !folders.isEmpty else { return }
        var changed = false
        for i in tasks.indices where tasks[i].chat?.bundleID == b && folders.contains(tasks[i].chat?.name ?? "") {
            tasks[i].chat = nil
            changed = true
        }
        if changed { file.save(tasks) }
    }

    /// Tasks made before Baton could name a window's open chat follow the whole window, so switching
    /// chats broke them. When the window shows the chat the task is named after, follow that chat instead.
    /// `open` is each window's open chat, as this poll read it.
    private func migrateWindowTasksToChats(open: [AXWindow: String]) {
        for i in tasks.indices where tasks[i].chat == nil && tasks[i].windows.count == 1 {
            guard let (tid, l) = live.first(where: { $0.value.taskIDs == [tasks[i].id] }),
                  let name = open[l.window],
                  name.lowercased() == tasks[i].title.lowercased() else { continue }
            let b = l.window.bundleID
            tasks[i].chat = ChatRecord(bundleID: b, appName: l.window.appName, name: name,
                                       section: appTabs[b]?.first(where: \.selected)?.name)
            tasks[i].windows = []
            engine.unwatch(tid)
            live[tid] = nil
            file.save(tasks)
        }
    }

    /// `cutShort`: apps whose read hit its limit this time, where a missing chat proves nothing.
    private func applyChatStatuses(cutShort: Set<String>) {
        // Every chat in a hidden tab is judged against the same button change and the same statuses,
        // whatever order they're gone through in.
        let baselines = tabBaseline, atStart = chatStatus
        var settledTabs: Set<String> = []
        defer { tabSeenWorking.subtract(settledTabs) }
        for t in tasks {
            guard let c = t.chat, let rows = chatRows[c.bundleID] else { continue }
            // Only a sidebar that reads normally right now can say a chat went quiet. Otherwise a broken
            // reader would turn every running chat into a "done" ping.
            guard health.trusted(healthKey(c.bundleID)) else {
                missingPolls[t.id] = 0
                DebugLog.changed("chat|\(t.id)", "  skip \(c.name): reader not trusted (\(health.verdict(healthKey(c.bundleID))))")
                continue
            }
            var status: ChatStatus
            var listed = false
            // Its tab isn't showing (a Claude chat while you're in Code, or the other way round): the
            // sidebar can't show it, so go by what the tab's button says ("working", "unread activity").
            if let tabs = appTabs[c.bundleID], !tabs.isEmpty,
               let current = tabs.first(where: \.selected)?.name, current != (c.section ?? "Code") {
                missingPolls[t.id] = 0
                let prev = chatStatus[t.id]
                let mine = c.section ?? "Code"
                let tab = tabs.first(where: { $0.name == mine })
                let othersWorking = tasks.contains { o in
                    o.id != t.id && o.chat?.bundleID == c.bundleID && (o.chat?.section ?? "Code") == mine && atStart[o.id] == .working
                }
                // Claude's chat button never says "working", and a blue dot can be an old unread chat. So only
                // a change in what the button shows, since you left the tab, means the chat you prompted finished.
                let key = "\(c.bundleID)|\(mine)"
                let before = baselines[key] ?? nil
                if tab?.status == .working {
                    // The tab says a chat in it is working (after a relaunch, or a switch faster than a read):
                    // the chat you left open there, or the only one Baton follows there.
                    let followedThere = tasks.filter { $0.chat?.bundleID == c.bundleID && ($0.chat?.section ?? "Code") == mine }
                    let leftOpen = lastOpenInTab[key].map { Sidebar.find(c.name, in: [ChatRow(name: $0, status: .idle)]) != nil } ?? false
                    guard prev != .working, leftOpen || followedThere.count == 1 else {
                        if prev != .working { DebugLog.changed("chat|\(t.id)", "  hidden tab \(mine) working, but can't tell which of \(followedThere.count) chats: \(c.name) stays \(prev.map { "\($0)" } ?? "nil")") }
                        continue
                    }
                    status = .working
                } else {
                    // The button said "working" and no longer does: nothing runs there now, so every chat Baton
                    // had running there is done. (Waiting for the others to finish first, each chat kept the
                    // others working forever.) Any other change can only be pinned on a chat running alone.
                    let stopped = tabSeenWorking.contains(key)
                    guard prev == .working, tab?.activity != before, stopped || !othersWorking else {
                        if prev == .working { DebugLog.changed("chat|\(t.id)", "  hidden tab \(mine): \(c.name) stays working (button \(tab?.activity ?? "nil"), was \((before ?? nil) ?? "nil"), othersWorking=\(othersWorking))") }
                        continue
                    }
                    tabBaseline[key] = .some(tab?.activity)
                    settledTabs.insert(key)
                    status = tab?.status.flatMap { $0 == .idle || $0 == .working ? nil : $0 } ?? .unread
                }
            } else if let row = Sidebar.find(c.name, in: rows) {
                status = row.status
                listed = true
                missingPolls[t.id] = 0
            } else if let word = unknownStatusWords[c.bundleID]?[c.name] {
                // The app shows a word Baton doesn't know: keep the last status rather than guess quiet,
                // and learn what the word means.
                missingPolls[t.id] = 0
                let line = "\(c.appName) shows \u{201C}\(word)\u{201D}"
                if lines[t.id] != line { lines[t.id] = line }
                learnStatusWord(word, app: c.appName, bundle: c.bundleID)
                continue
            } else {
                // A read cut short may just not have reached the chat.
                guard !cutShort.contains(c.bundleID) else { continue }
                // No status next to the chat (Grok Bot after a run, ChatGPT once read): it's quiet.
                // Two polls in a row, so a sidebar mid-redraw doesn't count.
                missingPolls[t.id, default: 0] += 1
                guard missingPolls[t.id, default: 0] >= 2 else { continue }
                status = .idle
            }
            let prev = chatStatus[t.id]
            if Sidebar.find(c.name, in: (generatingChats[c.bundleID] ?? []).map { ChatRow(name: $0, status: .working) }) != nil {
                status = .working   // its stop button is showing
            } else if listed, prev == .working, status == .idle,
                      Self.sidebarHidesWorking.contains(c.bundleID) || (c.bundleID == "com.anthropic.claudefordesktop" && c.section == "Claude"),
                      openChatNames[c.bundleID].map({ Sidebar.find(c.name, in: [ChatRow(name: $0, status: .idle)]) == nil }) ?? true {
                // Switched to another chat while this one runs (Cursor): working until the sidebar says done.
                // Only while its row is listed: a chat gone from the sidebar two reads in a row is done.
                status = .working
            }
            // A read cut short can't end a working chat; only the app saying unread or waiting on you can.
            if cutShort.contains(c.bundleID), prev == .working, status == .idle { continue }
            guard prev != status else { continue }
            DebugLog.log("  CHANGE \(c.name): \(prev.map { "\($0)" } ?? "nil") -> \(status) front=\(DebugLog.front)")
            chatStatus[t.id] = status
            // Ready follows the app's own mark: only a chat it shows as unread or waiting on you is Ready.
            // A chat that goes Running → Idle (Claude doesn't mark the chat you have open as unread) is
            // done and pings, but it's idle, as the app says.
            let finishedNow = status == .idle && prev == .working
            // Claude marks a session that finished while you were elsewhere with a blue dot, but a session with
            // a pull request shows the PR's badge there instead (purple merged, green open) and never turns
            // unread. Finished while you weren't looking: Ready until you open it, like the blue dot.
            let unseenFinish = finishedNow && c.bundleID == "com.anthropic.claudefordesktop" && !nowTaskIDs.contains(t.id)
            let state: WindowState = unseenFinish ? .finished : status.windowState
            setState(t.id, state)
            let ping = prev != nil && (finishedNow || state == .finished || state == .needsYou)
            if ping {
                let shown: WindowState = state == .needsYou ? .needsYou : .finished
                if state != .idle { unacknowledge(t.id) }
                let text = shown == .needsYou ? "\(c.name) needs your input" : "\(c.name) is done"
                lines[t.id] = text
                show(Ping(taskID: t.id, app: c.appName, bundleID: c.bundleID, text: text, status: shown, at: Date()))
            }
        }
    }

    /// Asks Gemini once what an unknown status word means, keeps the answer and reads the sidebar again.
    func learnStatusWord(_ word: String, app: String, bundle: String) {
        guard !learningWords.contains(word.lowercased()) else { return }
        // A failed try waits 5 minutes: each poll asked again before (every 2-6 s, for as long as it failed).
        if let at = learnRetryAt[word.lowercased()], Date() < at { return }
        guard let smart else {
            let note = "\(app) shows \u{201C}\(word)\u{201D}, a status Baton doesn't know yet (needs Gemini to learn it)."
            if readerNotes[bundle] != note { readerNotes[bundle] = note }
            return
        }
        // Only while a question is out: it's cleared again if Gemini can't say.
        learningWords.insert(word.lowercased())
        Task {
            guard let status = await smart.classifyStatus(word: word, app: app) else {
                learningWords.remove(word.lowercased())   // try again on a later read
                learnRetryAt[word.lowercased()] = Date().addingTimeInterval(300)
                return
            }
            LearnedStatus.shared.learn(word, status)
            let meaning = switch status {
            case .working: "working"
            case .needsInput: "needs you"
            case .unread: "new reply"
            case .idle: "idle"
            }
            readerNotes[bundle] = "Learned \u{201C}\(word)\u{201D} means \(meaning)"
            notifyText(title: "Baton learned a new status", body: "\(app) shows \u{201C}\(word)\u{201D}. Baton now reads it as \(meaning).")
            await pollSidebars()
        }
    }

    nonisolated static let claude = "com.anthropic.claudefordesktop"

    /// "Claude Chat" / "Claude Code", for Claude's two tabs.
    static func claudeTabName(_ tab: String?) -> String {
        switch tab { case "Claude": "Claude Chat"; case "Code": "Claude Code"; default: "Claude" }
    }

    /// Any Claude chat that finishes pings, tracked or not: you run many at once in both tabs.
    /// - In the tab that's showing, a chat you don't track turning unread or waiting on you (or, while
    ///   you're elsewhere, going Running → Idle) pings by name.
    /// - The hidden tab's button turning to "unread activity" pings "one of your chats is waiting".
    /// Tracked chats ping through their tasks; one ping per read at most.
    private func pingWaitingClaudeChats(_ r: AppRead) {
        let b = Self.claude
        guard !r.truncated, health.trusted(healthKey(b)) else { return }
        let selected = r.tabs.first(where: \.selected)?.name
        let tracked = Set(tasks.compactMap { $0.chat?.bundleID == b ? $0.chat?.name.lowercased() : nil })
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == b
        var found: (chat: ChatRecord, status: ChatStatus)?

        // The tab that's showing. Just switched to it: what it lists now is old news, not a change.
        let switched = lastSelectedTab[b] != (selected ?? "")
        lastSelectedTab[b] = selected ?? ""
        let prefix = "\(b)|\(selected ?? "")|"
        if !switched {
            for row in r.rows where !tracked.contains(row.name.lowercased()) && !Self.isPlaceholder(row.name) {
                guard let before = lastRowStatus[prefix + row.name], before != row.status else { continue }
                let isOpen = r.openName.map { Sidebar.find(row.name, in: [ChatRow(name: $0, status: .idle)]) != nil } ?? false
                let waiting = row.status == .unread || row.status == .needsInput
                let doneUnseen = before == .working && row.status == .idle && !(front && isOpen)
                if (waiting || doneUnseen) && found == nil {
                    found = (ChatRecord(bundleID: b, appName: "Claude", name: row.name, section: selected), row.status)
                }
            }
        }
        lastRowStatus = lastRowStatus.filter { !$0.key.hasPrefix(prefix) }
        for row in r.rows { lastRowStatus[prefix + row.name] = row.status }

        // The hidden tab: its button is all Baton can see of it.
        for tab in r.tabs {
            let key = "\(b)|\(tab.name)"
            if tab.selected { lastTabActivity[key] = nil; continue }
            let before = lastTabActivity[key]
            lastTabActivity[key] = .some(tab.activity)
            guard let before, before != tab.activity, let s = tab.status, s == .unread || s == .needsInput, found == nil else { continue }
            found = (ChatRecord(bundleID: b, appName: "Claude", name: "", section: tab.name), s)
        }

        guard let found else { return }
        // A tracked chat here pinged on this read already.
        if let p = ping, p.bundleID == b, Date().timeIntervalSince(p.at) < 3 { return }
        let place = Self.claudeTabName(found.chat.section)
        let text = found.chat.name.isEmpty ? "One of your chats is waiting for you in \(place)"
                                           : "\(found.chat.name) is waiting for you in \(place)"
        DebugLog.log("  WAITING ping: \(text)")
        show(Ping(taskID: UUID(), app: place, bundleID: b, text: text,
                  status: found.status == .needsInput ? .needsYou : .finished, at: Date(), waiting: found.chat))
    }

    /// Jump for a waiting chat you don't track: opens it, or, when only the tab's button said something
    /// is waiting, switches to that tab and opens the chat it marks unread or waiting on you.
    func openWaiting(_ c: ChatRecord) {
        if !c.name.isEmpty { openChat(c); return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: c.bundleID).first else { return }
        app.activate()
        let pid = app.processIdentifier
        Task.detached(priority: .userInitiated) {
            AX.enableTree(pid: pid)
            try? await Task.sleep(for: .milliseconds(150))
            guard let w0 = AX.windows(pid: pid).first else { return }
            AX.raise(w0)
            if let section = c.section, let current = Sidebar.sections(in: w0).first(where: \.selected), current.name != section {
                Sidebar.selectSection(section, in: w0)
                try? await Task.sleep(for: .milliseconds(900))
            }
            guard let w = AX.windows(pid: pid).first else { return }
            let rows = Sidebar.read(w).rows
            guard let row = rows.first(where: { $0.status == .needsInput }) ?? rows.first(where: { $0.status == .unread }) else {
                AX.raise(w)
                return
            }
            if Sidebar.openVerified(row.name, in: w) { AX.raise(w) }
        }
    }

    /// Brings the app forward and clicks the chat in its sidebar.
    func openChat(_ c: ChatRecord) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: c.bundleID).first else { return }
        app.activate()
        let pid = app.processIdentifier
        Task.detached(priority: .userInitiated) {
            AX.enableTree(pid: pid)
            // Give the app a moment to come forward, then open the chat and check it really opened.
            try? await Task.sleep(for: .milliseconds(150))
            var wins = AX.windows(pid: pid)
            // A chat in another tab (Claude's chats while Code is showing): switch tabs first.
            let section = c.section ?? (c.bundleID == "com.anthropic.claudefordesktop" ? "Code" : nil)
            if let section, let w = wins.first, let current = Sidebar.sections(in: w).first(where: \.selected), current.name != section {
                Sidebar.selectSection(section, in: w)
                try? await Task.sleep(for: .milliseconds(900))
                wins = AX.windows(pid: pid)
            }
            if let w = wins.first(where: { Sidebar.isOpen(c.name, in: $0) }) { AX.raise(w); return }
            for w in wins.prefix(2) where Sidebar.rowElement(c.name, in: w) != nil {
                if Sidebar.openVerified(c.name, in: w) { AX.raise(w) }
                return
            }
        }
    }

    // MARK: Reader health

    /// Health is kept per tab for apps whose tabs list different chats (Claude: ~25 chats vs ~5
    /// sessions), so switching tabs doesn't look like a broken reader.
    func healthKey(_ bundle: String) -> String {
        appTabs[bundle]?.first(where: \.selected).map { "\(bundle)|\($0.name)" } ?? bundle
    }

    /// Records a read and reacts when an app goes blind or comes back.
    private func checkHealth(_ bundle: String, rows: [ChatRow]) {
        let key = healthKey(bundle)
        let before = health.verdict(key)
        let now = health.record(key, rows: rows)
        // Reading normally while the window is still watched instead: back to the sidebar, whether or not
        // the verdict just changed. (A blind spell filed under another key, the app without its tab, left
        // Claude on window guesses for 40 minutes: a chat waiting on you showed as idle.)
        if now == .reading, fallbackLive[bundle] != nil {
            backToSidebar(bundle)
            if key != bundle, health.verdict(bundle) == .blind { health.reset(bundle) }
            health.save()
            if now == before { return }
        }
        guard now != before else { return }
        health.save()
        let followed = tasks.contains { $0.chat?.bundleID == bundle }
        if now == .blind, followed {
            watchWindowsInstead(bundle)
            if Defaults[.autoRepair] { repairReader(bundle) }
        }
    }

    /// While a sidebar can't be read, its chat tasks are watched through the app's window, so they
    /// still ping (Jev decides working / finished / needs you).
    private func watchWindowsInstead(_ bundle: String) {
        guard fallbackLive[bundle] == nil,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
              let w = AX.windows(pid: app.processIdentifier).first else { return }
        let chatTasks = tasks.filter { $0.chat?.bundleID == bundle }
        for t in chatTasks { attach(w, to: t.id, makeCurrent: chatTasks.count == 1) }
        fallbackLive[bundle] = live.first(where: { $0.value.window == w })?.key
        readerNotes[bundle] = "Can't read the sidebar. Watching the window instead."
    }

    private func backToSidebar(_ bundle: String) {
        if let tid = fallbackLive.removeValue(forKey: bundle) {
            engine.unwatch(tid)
            live[tid] = nil
        }
        // Start fresh, so the first read after recovering sets the status without a stale ping.
        for t in tasks where t.chat?.bundleID == bundle { chatStatus[t.id] = nil; missingPolls[t.id] = 0 }
        if readerNotes[bundle]?.hasPrefix("Can't") == true { readerNotes[bundle] = nil }
    }

    /// Re-learns how to read an app's sidebar (see ProfileRepair). At most every 30 minutes on its own;
    /// `force` is the Repair button.
    func repairReader(_ bundle: String, force: Bool = false) {
        guard !repairing.contains(bundle) else { return }
        if !force, let last = lastRepair[bundle], Date().timeIntervalSince(last) < 1800 { return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return }
        repairing.insert(bundle)
        lastRepair[bundle] = Date()
        let pid = app.processIdentifier
        let name = app.localizedName ?? bundle
        let known = health.known(healthKey(bundle))
        let usual = health.apps[healthKey(bundle)]?.usual ?? 0
        let smart = self.smart
        Task {
            let outcome: ProfileRepair.Outcome? = await Task.detached(priority: .utility) {
                AX.enableTree(pid: pid)
                guard let w = AX.windows(pid: pid).first,
                      let root = AXNode.capture(w.element, maxNodes: 8000, maxMillis: 2000) else { return nil }
                return await ProfileRepair.repair(root: root, bundleID: bundle, appName: name, known: known, usual: usual, smart: smart)
            }.value
            repairing.remove(bundle)
            guard let outcome, (try? Profiles.shared.save(outcome.profile, for: bundle)) != nil else {
                readerNotes[bundle] = "Couldn't re-learn the sidebar. Watching the window instead."
                return
            }
            health.reset(healthKey(bundle))
            readerNotes[bundle] = "Re-learned after an update: \(outcome.rows.count) chats"
            notifyText(title: "Baton re-learned \(name)", body: "\(name) changed its sidebar. Baton found your \(outcome.rows.count) chats again.")
            await pollSidebars()
        }
    }

    /// Back to the built-in profile (if a repair made things worse).
    func resetReader(_ bundle: String) {
        try? Profiles.shared.reset(bundle)
        health.reset(healthKey(bundle))
        readerNotes[bundle] = nil
        Task { await pollSidebars() }
    }

    /// Apps worth showing in Settings: ones you follow chats in, or that listed chats before.
    var readers: [(bundle: String, name: String, verdict: ReaderHealth.Verdict, count: Int, note: String?, custom: Bool)] {
        let followed = Set(tasks.compactMap { $0.chat?.bundleID })
        let custom = Set(Profiles.shared.saved?.apps.keys.map { $0 } ?? [])
        return health.apps
            .filter { followed.contains($0.key.components(separatedBy: "|")[0]) || $0.value.usual > 0 }
            .filter { k, _ in !k.contains("|") || k == healthKey(k.components(separatedBy: "|")[0]) }
            .map { k, a in
                let b = k.components(separatedBy: "|")[0]
                let name = NSRunningApplication.runningApplications(withBundleIdentifier: b).first?.localizedName
                    ?? tasks.first(where: { $0.chat?.bundleID == b })?.chat?.appName ?? b
                return (b, name, a.verdict, a.lastCount, readerNotes[b], custom.contains(b))
            }
            .sorted { $0.name < $1.name }
    }

    func notifyText(title: String, body: String) {
        guard Defaults[.notifications] else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
