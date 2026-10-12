import BatonCore
import Defaults
import SwiftUI

/// The calm amber "Stuck?" tag, in the same shape as the ping card's status tag.
struct StuckTag: View {
    var body: some View {
        Text("STUCK?")
            .font(.system(size: 9, weight: .bold)).tracking(0.5)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(Palette.ready)
            .background(Palette.ready.opacity(0.15), in: Capsule())
    }
}

/// A working task's row: the sliding bar, or the tag (with why, on hover) once its run looks stuck.
struct WorkingOrStuck: View {
    let id: UUID
    var body: some View {
        if let v = Insight.shared.stuck[id] {
            StuckTag().frame(width: 60).help(v.why).transition(.opacity)
        } else {
            WorkingBar()
        }
    }
}

/// The collapsed notch's right wing when nothing waits on you but a run looks stuck.
struct StuckWing: View {
    let row: TaskRow

    /// The working row that has looked stuck longest, if any.
    static func first(in rows: [TaskRow]) -> TaskRow? {
        let stuck = Insight.shared.stuck
        return rows.filter { stuck[$0.id] != nil }.max { stuck[$0.id]!.working < stuck[$1.id]!.working }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("Stuck?").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ready)
            AppIcon(bundleID: row.apps.first ?? "", size: 17)
        }
        .help(Insight.shared.stuck[row.id].map { "\(row.title): \($0.why)" } ?? row.title)
    }
}

/// Settings › General: the stuck threshold and the day's recap.
struct InsightSettingsSection: View {
    @Default(.stuckMinutes) private var stuckMinutes
    @Default(.recapScheduled) private var recapScheduled
    @Default(.recapMinutes) private var recapMinutes

    private var recapTime: Binding<Date> {
        Binding {
            Calendar.current.date(byAdding: .minute, value: recapMinutes, to: Calendar.current.startOfDay(for: .now)) ?? .now
        } set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            recapMinutes = (c.hour ?? 18) * 60 + (c.minute ?? 0)
        }
    }

    var body: some View {
        Section {
            Picker("Say a run looks stuck after", selection: $stuckMinutes) {
                Text("10 minutes").tag(10.0)
                Text("15 minutes").tag(15.0)
                Text("30 minutes").tag(30.0)
                Text("1 hour").tag(60.0)
                Text("Never").tag(0.0)
            }
            Toggle("Show the day's recap at", isOn: $recapScheduled)
            DatePicker("Time", selection: recapTime, displayedComponents: .hourAndMinute)
                .disabled(!recapScheduled)
            Button("Show Today's Recap…") { RecapWindow.show() }
        } header: {
            Text("Stuck runs and recap")
        } footer: {
            Text("A run looks stuck when its screen hasn't changed for that long, or it has run twice as long as that app usually takes. One ping per run. The recap is also in the menu bar menu.")
                .foregroundStyle(.secondary)
        }
    }
}

#if DEBUG
#Preview("Stuck tag and wing") {
    let row = TaskRow(id: UUID(), title: "Pricing table", apps: ["com.openai.codex"], appNames: ["Codex"], created: .now,
                      state: .working, group: .working, line: "Codex · running", updated: .now.addingTimeInterval(-900),
                      onScreen: false, steps: [])
    VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 12) { WorkingBar(); StuckTag() }
        StuckWing(row: row)
            .padding(.horizontal, 12).frame(height: 32)
            .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
    }
    .padding(24).background(Color(white: 0.1)).environment(\.colorScheme, .dark)
}

#Preview("Settings section") {
    Form { InsightSettingsSection() }.formStyle(.grouped).frame(width: 560)
}
#endif
