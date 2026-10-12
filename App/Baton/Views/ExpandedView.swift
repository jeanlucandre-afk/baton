import AppKit
import BatonCore
import SwiftUI

struct ExpandedView: View {
    private var model = AppModel.shared
    @Namespace private var rowSpace
    @Environment(\.accessibilityReduceMotion) private var reduce

    /// What the list's shape depends on: which rows sit in which section, and which tasks each big task holds.
    /// The list animates when this changes (a poll moved a task), not on every redraw.
    private func layout(_ top: [TaskRow]) -> [String] {
        top.map { r in "\(r.id)|\(r.group.rawValue)|" + r.children.map(\.id.uuidString).joined(separator: ",") }
    }

    // While AIs are working, your still tasks come first: that's what you can do right now.
    // Worked out from the top rows already read, not a second rebuild of every row.
    private func groups(_ top: [TaskRow]) -> [(TaskRow.Group, String)] {
        let busy = top.contains { $0.group == .working || $0.children.contains { $0.group == .working } }
        return busy ? [(.now, "Now"), (.ready, "Ready for you"), (.idle, "Your turn while the AIs work"), (.working, "AI working")]
                    : [(.now, "Now"), (.ready, "Ready for you"), (.idle, "Idle"), (.working, "AI working")]
    }

    /// The list stays a compact block under the notch and scrolls past that; it only gets shorter
    /// when the screen has less room, so its bottom never runs off the panel.
    private var listHeight: CGFloat {
        let suggestions = model.suggestions.isEmpty ? 0 : CGFloat(min(model.suggestions.count, 3)) * 44 + 24
        return min(380, max(200, DisplayManager.shared.openHeight() - 190 - suggestions))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                UsageLine()
                Spacer()
                Button { model.openNewTask() } label: {
                    Label("New task", systemImage: "plus").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.white.opacity(0.1), in: Capsule())
            }
            .padding(.horizontal, 8)

            if !model.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").font(.system(size: 9, weight: .bold))
                        Text("LOOKS LIKE YOU'RE WORKING ON").font(.system(size: 10, weight: .semibold)).tracking(0.6)
                    }
                    .foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 8).padding(.bottom, 2)
                    ForEach(model.suggestions.prefix(3)) { SuggestionRow(suggestion: $0) }
                }
            }

            let rows = model.topRows
            if rows.isEmpty && model.suggestions.isEmpty {
                VStack(spacing: 6) {
                    Text("No tasks yet").font(.system(size: 13, weight: .semibold))
                    Text("Press ⌥N, type what you're doing, and attach its windows.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 28)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(groups(rows), id: \.0) { g, label in
                            let inGroup = rows.filter { $0.group == g }
                            if !inGroup.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        StatusDot(color: Palette.color(g))
                                        Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6)
                                            .contentTransition(.opacity)
                                    }
                                    .foregroundStyle(Palette.color(g))
                                    .padding(.horizontal, 8).padding(.bottom, 2)
                                    ForEach(inGroup) { r in
                                        // A task changing section is carried across by its matched frame.
                                        Group {
                                            if r.isGroup { GroupRowView(row: r, space: rowSpace) } else { TaskRowView(row: r) }
                                        }
                                        .matchedGeometryEffect(id: r.id, in: rowSpace)
                                        .transition(Motion.row(reduce))
                                    }
                                }
                                .transition(.opacity)
                            }
                        }
                    }
                    .animation(Motion.list(reduce), value: layout(rows))
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: listHeight)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(.white.opacity(0.08))
            HStack {
                Text("Click a task to jump to its windows")
                Spacer()
                Text("⌥⇥ next ready · ⌥N new task")
            }
            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 8)
        }
        // The list closed mid-rename: the next rename starts from the task's name, not this one's typing.
        .onDisappear { RenameField.draft = nil }
    }
}

struct SuggestionRow: View {
    let suggestion: AppModel.Suggestion
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(bundleID: suggestion.bundleID, size: 28).frame(width: 54, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(suggestion.appName) · \(statusText)").font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Track") { AppModel.shared.track(suggestion) }
                .buttonStyle(PillButton(fill: hovering ? Palette.ready : .white.opacity(0.12), text: hovering ? .black : .white))
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .onHover { hovering = $0 }
    }

    private var statusText: String {
        switch suggestion.status {
        case .working: "running now"
        case .needsInput: "needs your input"
        case .unread: "new reply"
        default: "not tracked yet"
        }
    }
}

struct TaskRowView: View {
    let row: TaskRow
    @State private var hovering = false
    private var checked: Bool { AppModel.shared.finishing.contains(row.id) }

    var body: some View {
        HStack(spacing: 6) {
            // Done: tick it and the task closes after a few seconds; tick again to undo.
            Button {
                withAnimation(Motion.list) {
                    checked ? AppModel.shared.undoDone(row.id) : AppModel.shared.markDone(row.id)
                }
            } label: {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(checked ? Palette.ready : .white.opacity(hovering ? 0.6 : 0.3))
                    .frame(width: 22, height: 22)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(checked ? "Undo" : "Mark task done")
            if AppModel.shared.renamingID == row.id { RenameField(row: row) } else { mainButton }
        }
        .padding(.leading, 4)
        .opacity(checked ? 0.5 : 1)
    }

    private var mainButton: some View {
        Button { AppModel.shared.jump(row.id) } label: {
            HStack(spacing: 10) {
                Group {
                    if row.isGroup { BigTaskStack(bundleIDs: row.apps, size: 30) } else { IconStack(bundleIDs: row.apps, size: 32) }
                }
                .frame(width: 54, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).strikethrough(checked)
                        if !row.steps.isEmpty {
                            Text("\(row.steps.filter(\.done).count)/\(row.steps.count)")
                                .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.white.opacity(0.1), in: Capsule())
                                .foregroundStyle(Palette.secondary)
                                .help(row.steps.map { ($0.done ? "✓ " : "○ ") + $0.text }.joined(separator: "\n"))
                        }
                    }
                    HStack(spacing: 8) {
                        if let pct = ContinueFlow.shared.context[row.id] { ContextBar(percent: pct) }
                        Text(row.line).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if hovering && (Relay.canReply(row) || ContinueFlow.canContinue(row.id)) {
                    HStack(spacing: 0) {
                        // A chat that's ready for you: answer it from here.
                        if Relay.canReply(row) { TextButton("Reply", color: Palette.ready) { Relay.shared.compose(task: row.id) } }
                        // Hovering a Claude chat: hand it off to a fresh chat.
                        if ContinueFlow.canContinue(row.id) {
                            TextButton("↻ Continue in new chat", color: Palette.ready) { ContinueFlow.shared.begin(row.id) }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else if row.group == .working { WorkingOrStuck(id: row.id) }
                Text(row.updated, style: .relative)
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.secondary)
                    .frame(width: 58, alignment: .trailing)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(.white.opacity(hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu { TaskMenu(row: row) }
    }
}

/// A big task's name, edited in place in the list: ⏎ keeps it, Esc leaves it as it was.
private struct RenameField: View {
    let row: TaskRow
    /// What you've typed so far, kept outside the field: a status change can move the big task to another
    /// group in the list, which rebuilds the field, and it mustn't start over from the old name.
    static var draft: (id: UUID, text: String)?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            BigTaskStack(bundleIDs: row.apps, size: 30).frame(width: 54, alignment: .leading)
            TextField("Big task name", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .focused($focused)
                .onSubmit { Self.draft = nil; AppModel.shared.finishRename(text) }
                .onExitCommand { Self.draft = nil; AppModel.shared.finishRename(nil) }
                .onChange(of: text) { Self.draft = (row.id, text) }
            Text("⏎ save · esc cancel").font(.system(size: 10)).foregroundStyle(Palette.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.3)).frame(height: 1).padding(.leading, 72).padding(.trailing, 8)
        }
        .task {
            text = Self.draft.flatMap { $0.id == row.id ? $0.text : nil } ?? row.title
            // The panel takes the keyboard on the hover monitor's next tick; focus once it has.
            try? await Task.sleep(for: .milliseconds(120))
            focused = true
        }
    }
}

/// Right-click menu for a task anywhere in Baton (the list and the shelf).
/// A big task: add a task to it, jump, rename, done, merge, ungroup, remove.
/// A task: jump, continue, reply, pass to another app, done, make it a big task / move it into one / take it out, remove.
struct TaskMenu: View {
    let row: TaskRow
    var body: some View {
        let model = AppModel.shared
        // Menu actions land after the menu closes, so a list that reshuffles isn't fighting it.
        // The list animates the reshuffle itself (and plainly, with Reduce Motion).
        let later = { (f: @escaping () -> Void) in DispatchQueue.main.async { f() } }
        let bigs = model.topRows.filter { $0.isGroup && $0.id != row.id && $0.id != row.parentID }
        if row.isGroup {
            Button("Add task…") { DispatchQueue.main.async { model.openNewTask(under: row.id) } }
            Button("Jump to it") { model.jump(row.id) }
            Button("Rename…") { DispatchQueue.main.async { model.startRename(row.id) } }
            Button("Mark big task done") { model.markDone(row.id) }
            Divider()
            if !bigs.isEmpty {
                Menu("Merge into") {
                    ForEach(bigs) { t in Button(t.title) { later { model.group(row.id, with: t.id) } } }
                }
            }
            Button("Ungroup all") { later { model.ungroupAll(row.id) } }
            Divider()
            Button("Remove big task and its tasks", role: .destructive) { model.delete(row.id) }
        } else {
            Button("Jump to it") { model.jump(row.id) }
            if ContinueFlow.canContinue(row.id) {
                Button("Continue in new chat") { ContinueFlow.shared.begin(row.id) }
            }
            if Relay.target(task: row.id) != nil {
                Button("Reply…") { later { Relay.shared.compose(task: row.id) } }
            }
            PassMenu(taskID: row.id)
            Button("Mark task done") { model.markDone(row.id) }
            Divider()
            if row.parentID == nil {
                Button("Make big task") { later { model.makeGroup(from: row.id) } }
            }
            // Big tasks first; plain tasks under them make a new big task holding both (as dragging does).
            let singles = model.topRows.filter { !$0.isGroup && $0.id != row.id }
            if !bigs.isEmpty || !singles.isEmpty {
                Menu("Move to") {
                    ForEach(bigs) { t in Button(t.title) { later { model.move(row.id, under: t.id) } } }
                    if !singles.isEmpty {
                        Section("New big task with") {
                            ForEach(singles) { t in Button(t.title) { later { model.group(row.id, with: t.id) } } }
                        }
                    }
                }
            }
            if row.parentID != nil {
                Button("Remove from \(model.parentTitle(of: row.id) ?? "big task")") { later { model.ungroup(row.id) } }
            }
            Divider()
            Button("Remove task", role: .destructive) { model.delete(row.id) }
        }
    }
}

/// A big task: its own row with the rollup ("1 ready · 1 working"), its subtasks indented below.
/// A task joining or leaving it opens or closes its height smoothly (the list animates the change).
struct GroupRowView: View {
    let row: TaskRow
    /// The list's namespace, so a subtask taken out (or moved in) travels to its new place.
    var space: Namespace.ID?
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TaskRowView(row: row)
            ForEach(row.children) { kid in
                HStack(spacing: 0) {
                    Rectangle().fill(.white.opacity(0.12)).frame(width: 1).padding(.leading, 19).padding(.trailing, 10)
                    TaskRowView(row: kid)
                }
                .modifier(MatchedRow(id: kid.id, space: space))
                .transition(Motion.row(reduce))
            }
        }
    }
}

private struct MatchedRow: ViewModifier {
    let id: UUID
    let space: Namespace.ID?
    func body(content: Content) -> some View {
        if let space { content.matchedGeometryEffect(id: id, in: space) } else { content }
    }
}

/// A short blue segment sliding along a faint track while an AI works.
/// Clock-driven at 30 fps (same easeInOut sweep every 1.8 s as before), so it stops with the panel.
struct WorkingBar: View {
    var width: CGFloat = 60
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.notchVisible) private var visible

    var body: some View {
        let on = loopingMotion(visible: visible, reduce: reduce)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !on)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let x = on ? -0.4 + 1.4 * eased : 0.3
            Capsule().fill(Palette.working.opacity(0.18))
                .frame(width: width, height: 3)
                .overlay(alignment: .leading) {
                    Capsule().fill(Palette.working)
                        .frame(width: width * 0.4, height: 3)
                        .offset(x: x * width)
                }
                .clipShape(Capsule())
        }
    }
}

#if DEBUG
private extension TaskRow {
    static func sample(_ title: String, _ group: Group, app: String = "com.anthropic.claudefordesktop",
                       parent: UUID? = nil, kids: [TaskRow] = []) -> TaskRow {
        TaskRow(id: UUID(), title: title, apps: [app], appNames: ["Claude"], created: .now,
                state: group == .working ? .working : group == .ready ? .finished : .idle, group: group,
                line: group == .working ? "Claude · running" : "Next: review the draft", updated: .now,
                onScreen: false, steps: [], parentID: parent, isGroup: !kids.isEmpty, children: kids)
    }
}

#Preview("Rows") {
    let big = UUID()
    let kids = [TaskRow.sample("Hero copy", .ready, parent: big), TaskRow.sample("Pricing table", .working, parent: big)]
    let group = TaskRow(id: big, title: "Pitch deck", apps: kids.flatMap(\.apps), appNames: ["Claude"], created: .now,
                        state: .finished, group: .ready, line: "1 ready · 1 working", updated: .now, onScreen: false,
                        steps: [], isGroup: true, children: kids)
    VStack(alignment: .leading, spacing: 2) {
        GroupRowView(row: group)
        TaskRowView(row: .sample("Logo pass", .idle))
    }
    .padding(16).frame(width: 640).background(.black).environment(\.colorScheme, .dark)
}

#Preview("Menus") {
    // The context menus, laid out flat so both kinds can be read side by side.
    HStack(alignment: .top, spacing: 40) {
        VStack(alignment: .leading) { Text("Big task").bold(); TaskMenu(row: .sample("Pitch deck", .ready, kids: [.sample("Hero copy", .ready)])) }
        VStack(alignment: .leading) { Text("Task").bold(); TaskMenu(row: .sample("Logo pass", .idle)) }
    }
    .padding(20)
}

#Preview("Status dot") {
    @Previewable @State var ready = false
    HStack(spacing: 12) {
        StatusDot(color: ready ? Palette.ready : Palette.working, size: 8, wantsYou: ready)
        Button(ready ? "Back to working" : "Finish") { ready.toggle() }
    }
    .padding(30).background(.black).environment(\.colorScheme, .dark)
}
#endif
