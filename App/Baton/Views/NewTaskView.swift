import AppKit
import BatonCore
import Defaults
import SwiftUI

struct NewTaskView: View {
    private var model = AppModel.shared
    @State private var text = ""
    @State private var windows: [AXWindow] = []
    @State private var selected: Set<AXWindow> = []
    @State private var suggested: [AXWindow] = []
    @State private var touched = false     // once you toggle a chip, suggestions stop overriding you
    @State private var guess: AppModel.Suggestion?   // what Baton thinks you're working on in the front window
    @State private var chat: ChatRecord?   // the chat the new task follows
    @FocusState private var focused: Bool
    @State private var highlighted = 0
    @State private var chatApp: String?    // the app whose chats the Follow-a-chat grid shows
    @State private var frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    @State private var accepted: String?   // the suggestion you took; hides the list until you type again
    @State private var target: UUID?       // the task list the new task goes into; nil = its own new task
    @Default(.newTaskPing) private var pingMe
    @Default(.newTaskReadScreen) private var readScreen

    var body: some View {
        // Every chat across the apps, and what fits your words, worked out once per draw (not once per use).
        let chats = model.allChats
        let matches = findMatches(chats)
        let showMatches = accepted == nil && !matches.isEmpty
        let apps = chatApps(chats)
        let shown = shownApp(apps)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(heading).font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(Palette.secondary)
                    .contentTransition(.opacity)
                HStack(spacing: 10) {
                    Image(systemName: "plus").foregroundStyle(Palette.ready)
                    TextField(guess.map { "\($0.title) (⏎ to use)" } ?? "Rewrite pricing page copy in 3 tones", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($focused)
                        .onSubmit {
                            if showMatches && highlighted > 0 && matches.indices.contains(highlighted) { accept(matches[highlighted]) } else { start() }
                        }
                        .overlay(alignment: .leading) {
                            // The rest of the best match, in grey after what you typed. Tab takes it.
                            if showMatches, let rest = ghost(matches) {
                                Text("\(Text(text).foregroundStyle(.clear))\(Text(rest).foregroundStyle(.white.opacity(0.32)))")
                                    .font(.system(size: 15)).lineLimit(1).allowsHitTesting(false)
                            }
                        }
                        .onKeyPress(.tab) {
                            // The list can shrink under you on a poll: never index past its end.
                            guard showMatches, let m = matches[safe: highlighted] ?? matches.first else { return .ignored }
                            accept(m); return .handled
                        }
                        .onKeyPress(.downArrow) {
                            guard showMatches else { return .ignored }
                            highlighted = min(highlighted + 1, matches.count - 1); return .handled
                        }
                        .onKeyPress(.upArrow) {
                            guard showMatches else { return .ignored }
                            highlighted = max(highlighted - 1, 0); return .handled
                        }
                        .onChange(of: text) { highlighted = 0; if text != accepted { accepted = nil }; model.draft = text }
                        .onChange(of: matches.map(\.id)) { highlighted = min(highlighted, max(matches.count - 1, 0)) }
                }
                .padding(.horizontal, 12).frame(height: 44)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.ready.opacity(0.55), lineWidth: 1))

                if showMatches {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("MATCHING CHATS AND WINDOWS")
                            Spacer()
                            Text("tab to use · ↑↓")
                        }
                        .font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(Palette.secondary)
                        .padding(.horizontal, 8).padding(.top, 2)
                        ForEach(Array(matches.enumerated()), id: \.element.id) { i, m in matchRow(m, index: i, on: i == highlighted) }
                    }
                    .padding(4)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else if text.isEmpty, let g = guess {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.ready)
                        Text("Looks like you're working on").foregroundStyle(Palette.secondary)
                        Text(g.title).foregroundStyle(.white)
                        Text("in").foregroundStyle(Palette.secondary)
                        AppIcon(bundleID: g.bundleID, size: 14)
                        Text(g.appName)
                    }
                    .font(.system(size: 11))
                } else if !suggested.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.ready)
                        Text("Got it: watching").foregroundStyle(Palette.secondary)
                        ForEach(suggested, id: \.self) { w in
                            AppIcon(bundleID: w.bundleID, size: 14)
                            Text(w.appName)
                        }
                    }
                    .font(.system(size: 11))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            if !chats.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("FOLLOW A CHAT").font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(Palette.secondary)
                        Spacer(minLength: 8)
                        // One app at a time, so every chat and bot is reachable, not just the first dozen.
                        ForEach(apps, id: \.bundle) { a in
                            let on = a.bundle == shown
                            Button { chatApp = a.bundle } label: {
                                HStack(spacing: 5) {
                                    AppIcon(bundleID: a.bundle, size: 14)
                                    Text(a.name).font(.system(size: 11, weight: on ? .semibold : .regular))
                                    Text("\(a.count)").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                                }
                                .padding(.horizontal, 8).frame(height: 24)
                                .background(on ? Palette.ready.opacity(0.14) : .white.opacity(0.04), in: Capsule())
                                .overlay(Capsule().stroke(on ? Palette.ready.opacity(0.6) : .clear, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .leading), count: 3), alignment: .leading, spacing: 8) {
                            ForEach(chipChats(chats, shown), id: \.0) { c, status in chatChip(c, status) }
                        }
                    }
                    .scrollIndicators(.automatic)
                    .frame(maxHeight: 118)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(chat == nil ? "ATTACH WINDOWS" : "OR ATTACH WINDOWS INSTEAD").font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(Palette.secondary)
                    Spacer()
                    Button("Pick a window…") { pick() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.ready)
                }
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(chipWindows, id: \.self) { w in chip(w) }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: 132)
            }

            if let p = model.ping { pingStrip(p).transition(.move(edge: .bottom).combined(with: .opacity)) }

            HStack(spacing: 16) {
                Toggle("Ping when done", isOn: $pingMe)
                    .help("Off: the task still moves to Ready for you, without a ping")
                Toggle("Read screen text", isOn: $readScreen)
                    .help("Lets Gemini read the chat to write the ping summary, steps and next action")
                Spacer()
                let places = model.topRows
                if !places.isEmpty { placeMenu(places) }
                Button("esc") { cancel() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                Button("Start task ⏎") { start() }
                    .buttonStyle(PillButton(fill: Palette.ready, text: .black))
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty && guess == nil)
            }
            .toggleStyle(MiniSwitch())
        }
        .onAppear(perform: load)
        // "Add task…" on a big task while this box is already open: it files into that big task now.
        .onChange(of: model.pendingParent) { _, p in
            guard let p else { return }
            target = p
            model.pendingParent = nil
        }
        .task { await loadWindows() }
        .onChange(of: model.suggestions) { pickGuess() }
        .onExitCommand { cancel() }
        .task(id: text) { await suggest() }
        .animation(.easeOut(duration: 0.2), value: suggested)
        .animation(.easeOut(duration: 0.15), value: showMatches)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.ping?.taskID)
    }

    /// "NEW TASK IN PITCH DECK" when the box files into a big task, so you know where it lands before you type.
    private var heading: String {
        guard let target, let r = model.topRows.first(where: { $0.id == target && $0.isGroup }) else { return "WHAT ARE YOU WORKING ON?" }
        return "NEW TASK IN \(r.title.uppercased())"
    }

    /// Where the new task goes: its own new task, or into a big task or a task you already have
    /// (which then becomes a big task holding both).
    private func placeMenu(_ places: [TaskRow]) -> some View {
        let picked = places.first { $0.id == target }
        let bigs = places.filter(\.isGroup)
        let singles = places.filter { !$0.isGroup }
        return Menu {
            Button { target = nil } label: {
                if picked == nil { Label("New task", systemImage: "checkmark") } else { Text("New task") }
            }
            if !bigs.isEmpty {
                Section("Big tasks") {
                    ForEach(bigs) { r in placeItem(r, on: r.id == picked?.id) }
                }
            }
            if !singles.isEmpty {
                Section("Tasks") {
                    ForEach(singles) { r in placeItem(r, on: r.id == picked?.id) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: picked == nil ? "plus.square.on.square" : "square.stack.3d.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(picked == nil ? .white.opacity(0.55) : Palette.ready)
                Text(picked.map { "In: \($0.title)" } ?? "New task")
                    .font(.system(size: 11, weight: picked == nil ? .regular : .semibold))
                    .foregroundStyle(.white.opacity(picked == nil ? 0.75 : 1))
                    .lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 9).frame(height: 24)
            .frame(maxWidth: 180)
            .background(picked == nil ? .white.opacity(0.06) : Palette.ready.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(picked == nil ? .white.opacity(0.1) : Palette.ready.opacity(0.6), lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Where the new task goes: on its own, or into a task list you already have")
    }

    /// One task list in the menu; big tasks say how many tasks they hold.
    private func placeItem(_ r: TaskRow, on: Bool) -> some View {
        let name = r.isGroup ? "\(r.title)  (\(r.children.count))" : r.title
        return Button { target = r.id } label: {
            if on { Label(name, systemImage: "checkmark") }
            else { Label(name, systemImage: r.isGroup ? "square.stack.3d.up" : "circle") }
        }
    }

    /// A task finished while you were typing: say so here, without closing the box.
    private func pingStrip(_ p: Ping) -> some View {
        HStack(spacing: 10) {
            AppIcon(bundleID: p.bundleID, size: 22).modifier(Halo(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(p.status == .needsYou ? "\(p.app) needs you" : "\(p.app) finished")
                    .font(.system(size: 12, weight: .semibold))
                Text(p.text).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("your draft stays").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
            Button("Later") { model.ping = nil }
                .buttonStyle(PillButton(fill: .white.opacity(0.1), text: .white))
            Button("Jump") { model.jump(p.taskID) }
                .buttonStyle(PillButton(fill: Palette.ready, text: .black))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Palette.ready.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.ready.opacity(0.35), lineWidth: 1))
    }

    // MARK: Suggestions while typing

    struct Match: Identifiable {
        var id: String { "\(bundleID)|\(title)" }
        let title: String
        let bundleID: String
        let appName: String
        let chat: ChatRecord?
        let window: AXWindow?
        let status: ChatStatus?
        let score: Double
    }

    /// How well a name fits what you typed: the share of your words that start a word in it,
    /// with a bonus when it starts with exactly what you typed.
    static func score(_ name: String, _ query: String) -> Double {
        let q = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
        guard !q.isEmpty else { return 0 }
        let n = name.lowercased()
        let words = n.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let hit = q.filter { w in words.contains { $0.hasPrefix(w) } }.count
        var s = Double(hit) / Double(q.count)
        if n.hasPrefix(query.lowercased().trimmingCharacters(in: .whitespaces)) { s += 0.5 }
        return s
    }

    /// Your chats (every app Baton can read), AI windows it noticed, and open windows, best match first.
    private func findMatches(_ chats: [(ChatRecord, ChatStatus)]) -> [Match] {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return [] }
        var out: [Match] = []
        var seen = Set<String>()
        func add(_ m: Match) { if m.score >= 0.5, seen.insert(m.title.lowercased()).inserted { out.append(m) } }
        for (c, st) in chats {
            add(Match(title: c.name, bundleID: c.bundleID, appName: c.appName, chat: c, window: nil, status: st, score: Self.score(c.name, t) + 0.05))
        }
        for g in model.suggestions {
            add(Match(title: g.title, bundleID: g.bundleID, appName: g.appName, chat: g.chat, window: g.window, status: g.status, score: Self.score(g.title, t)))
        }
        for w in windows where !w.title.isEmpty {
            add(Match(title: w.title, bundleID: w.bundleID, appName: w.appName, chat: nil, window: w, status: nil, score: Self.score(w.title, t) - 0.05))
        }
        return Array(out.sorted { $0.score > $1.score }.prefix(4))
    }

    /// The grey rest of the top match when it starts with what you typed.
    private func ghost(_ matches: [Match]) -> String? {
        guard highlighted == 0, let m = matches.first,
              m.title.lowercased().hasPrefix(text.lowercased()), m.title.count > text.count else { return nil }
        return String(m.title.dropFirst(text.count))
    }

    private func accept(_ m: Match) {
        text = m.title
        accepted = m.title
        if let c = m.chat { chat = c }
        if let w = m.window {
            if !windows.contains(w) { windows.insert(w, at: 0) }
            selected = [w]
            touched = true
        }
    }

    private func matchRow(_ m: Match, index: Int, on: Bool) -> some View {
        Button { accept(m) } label: {
            HStack(spacing: 9) {
                AppIcon(bundleID: m.bundleID, size: 18)
                Text(m.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(m.chat != nil ? "\(m.appName) chat" : m.appName).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
                Spacer(minLength: 6)
                if let st = m.status, st != .idle {
                    Circle().fill(st == .working ? Palette.working : Palette.ready).frame(width: 6, height: 6)
                }
                if on { Text("tab").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(.white.opacity(0.1), in: Capsule()) }
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(on ? Palette.ready.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlighted = index } }
    }

    /// Apps with chats Baton can follow, with how many each lists, by name: the pills mustn't swap places
    /// every time a chat somewhere starts or finishes.
    private func chatApps(_ chats: [(ChatRecord, ChatStatus)]) -> [(bundle: String, name: String, count: Int)] {
        var seen: [String: (String, Int)] = [:]
        for (c, _) in chats {
            if seen[c.bundleID] == nil { seen[c.bundleID] = (c.appName, 0) }
            seen[c.bundleID]!.1 += 1
        }
        let apps: [(bundle: String, name: String, count: Int)] = seen.map { ($0.key, $0.value.0, $0.value.1) }
        return apps.sorted { a, b in
            let c = a.name.localizedCaseInsensitiveCompare(b.name)
            return c == .orderedSame ? a.bundle < b.bundle : c == .orderedAscending
        }
    }

    /// The app whose chats are shown: the one you picked, else the app you were just in, else the first.
    private func shownApp(_ chatApps: [(bundle: String, name: String, count: Int)]) -> String? {
        let apps = chatApps.map(\.bundle)
        if let chatApp, apps.contains(chatApp) { return chatApp }
        if let front = frontBundle, apps.contains(front) { return front }
        if let w = windows.first(where: { selected.contains($0) }), apps.contains(w.bundleID) { return w.bundleID }
        return apps.first
    }

    /// Every chat of the shown app: ones that fit your words first, then ones with news, then the rest.
    private func chipChats(_ chats: [(ChatRecord, ChatStatus)], _ shownApp: String?) -> [(ChatRecord, ChatStatus)] {
        let all = chats.filter { $0.0.bundleID == shownApp }
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return all }
        return all.enumerated()
            .map { ($0.element, Self.score($0.element.0.name, t), $0.offset) }
            .sorted { ($0.1, -$0.2) > ($1.1, -$1.2) }
            .map(\.0)
    }

    /// Selected windows first, then every other window (scrolls).
    private var chipWindows: [AXWindow] {
        windows.filter { selected.contains($0) } + windows.filter { !selected.contains($0) }
    }

    private func chatChip(_ c: ChatRecord, _ status: ChatStatus) -> some View {
        let on = chat == c
        let color: Color = status == .working ? Palette.working : status == .idle ? Palette.idle : Palette.ready
        return Button {
            chat = on ? nil : c
            if !on && text.isEmpty { text = c.name }
        } label: {
            HStack(spacing: 7) {
                AppIcon(bundleID: c.bundleID, size: 18)
                Circle().fill(color).frame(width: 6, height: 6)
                Text(c.name).font(.system(size: 11)).lineLimit(1)
                Spacer(minLength: 0)
                if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.ready) }
            }
            .padding(.horizontal, 9).frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .leading)
            .background((on ? Palette.ready.opacity(0.1) : .white.opacity(0.04)), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Palette.ready.opacity(0.7) : .white.opacity(0.1), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chip(_ w: AXWindow) -> some View {
        let on = selected.contains(w)
        return Button {
            touched = true
            if on { selected.remove(w) } else { selected.insert(w) }
        } label: {
            HStack(spacing: 7) {
                AppIcon(bundleID: w.bundleID, size: 22)
                Text(w.title.isEmpty ? w.appName : w.title).font(.system(size: 11)).lineLimit(1)
                Spacer(minLength: 0)
                if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.ready) }
            }
            .padding(.horizontal, 8).frame(height: 38)
            .background((on ? Palette.ready.opacity(0.1) : .white.opacity(0.04)), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Palette.ready.opacity(0.7) : .white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func load() {
        // Each opening starts as its own new task, unless it came from a big task's "Add task…".
        target = model.pendingParent
        model.pendingParent = nil
        if text.isEmpty { text = model.draft }
        pickGuess()
        DispatchQueue.main.async { focused = true }
    }

    /// Listing every window asks each app over Accessibility, which can stall: do it off the main thread
    /// so the box opens (and takes typing) at once, and fill the window chips in when the list arrives.
    private func loadWindows() async {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let found = await Task.detached(priority: .userInitiated) {
            AX.listWindows().filter { !$0.title.isEmpty || $0.appName != "Finder" }
        }.value
        guard !Task.isCancelled else { return }
        // Keep any window you picked or took from a match while the list was loading.
        windows = windows.filter { !found.contains($0) } + found
        // The app you were just in is the best first guess.
        if !touched, selected.isEmpty, let front, let w = windows.first(where: { $0.pid == front }) {
            selected = [w]
        }
        pickGuess()
    }

    private func pickGuess() {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guess = model.suggestions.first(where: { $0.window?.pid == front })
            ?? model.suggestions.first(where: { $0.chat != nil && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == $0.bundleID })
            ?? model.suggestions.first(where: { s in s.window.map { selected.contains($0) } ?? false })
    }

    private func suggest() async {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count >= 3, let jev = model.classifier else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        let picks = await WindowMatcher.suggest(task: t, windows: windows, using: jev)
        guard !Task.isCancelled else { return }
        suggested = picks
        if !touched && !picks.isEmpty { selected = Set(picks) }
    }

    private func pick() {
        WindowPicker.pick { w in
            guard let w else { return }
            if !windows.contains(w) { windows.insert(w, at: 0) }
            selected.insert(w)
            touched = true
        }
    }

    private func start() {
        var t = text.trimmingCharacters(in: .whitespaces)
        var wins = windows.filter { selected.contains($0) }
        var c = chat
        if t.isEmpty, let g = guess {
            t = g.title
            if c == nil { c = g.chat }
            if wins.isEmpty, let w = g.window { wins = [w] }
        }
        guard !t.isEmpty else { return }
        let id = model.createTask(title: t, windows: wins, chat: c, ping: pingMe, readScreen: readScreen)
        // Into the list you picked, if it's still there.
        if let target, let r = model.topRows.first(where: { $0.id == target }) {
            if r.isGroup { model.move(id, under: target) } else { model.group(id, with: target) }
        }
        model.draft = ""
        model.ping = nil
        model.collapse()
    }

    private func cancel() {
        model.draft = ""
        model.ping = nil
        model.collapse()
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// The small gold switch from the design: label after the switch, compact enough for the notch.
struct MiniSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 7) {
                Capsule()
                    .fill(configuration.isOn ? Palette.ready : .white.opacity(0.18))
                    .frame(width: 30, height: 18)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 14, height: 14).padding(2)
                            .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                    }
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isOn)
                configuration.label.font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}
