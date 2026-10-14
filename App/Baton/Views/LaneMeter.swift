import BatonCore
import SwiftUI

/// The notch's wings in the Lanes style (and while the always-on shelf is on): one pill per AI lane on
/// the left, "3/7 working" on the right. Only working pills move.
struct LaneMeter: View {
    let notchWidth: CGFloat
    /// False when the right wing would cover menu bar items: then only the pills show.
    var trailing = true
    private var model = AppModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.notchVisible) private var visible

    init(notchWidth: CGFloat, trailing: Bool = true) { self.notchWidth = notchWidth; self.trailing = trailing }

    enum State { case working, waiting, idle }

    /// AI lanes: tasks in AI apps (chats, or windows of AI apps, terminals and browsers), oldest first,
    /// so pills keep their place.
    static var lanes: [TaskRow] {
        AppModel.shared.rows.filter { $0.apps.contains(where: AppModel.aiApps.contains) }.sorted { $0.created < $1.created }
    }

    static func state(_ r: TaskRow) -> State {
        switch r.group {
        case .working: .working
        case .ready: .waiting
        case .now, .idle: .idle
        }
    }

    static func color(_ s: State) -> Color {
        switch s {
        case .working: Palette.working
        case .waiting: Palette.ready
        case .idle: .white.opacity(0.2)
        }
    }

    var body: some View {
        let lanes = Self.lanes
        let shown = Array(lanes.prefix(12))
        // One clock for every working pill, and none at all when no lane is working or nobody can see it.
        let breathing = loopingMotion(visible: visible, reduce: reduce)
            && shown.contains { Self.state($0) == .working && $0.group != .now }
        HStack(spacing: 0) {
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !breathing)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let glow = breathing ? 0.75 + 0.25 * cos(t * .pi / 0.8) : 1
                HStack(spacing: 3) {
                    ForEach(shown) { r in
                        let s = Self.state(r)
                        // The chat you're in right now is purple, like "Now" on the shelf.
                        Capsule().fill(r.group == .now ? Palette.now : Self.color(s))
                            .frame(width: 6, height: s == .idle && r.group != .now ? 11 : 15)
                            .opacity(s == .working && r.group != .now ? glow : 1)
                            .transition(reduce ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
                    }
                }
            }
            // Pills change color and height in place and slide over when one comes or goes.
            .animation(Motion.list(reduce), value: lanes.map { "\($0.id)\($0.group)" })
            .frame(width: DisplayManager.wing, alignment: .leading).padding(.leading, 10)
            Color.clear.frame(width: notchWidth)
            if trailing {
                Group {
                    if model.idlePaused {
                        Label("paused", systemImage: "moon.zzz").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    } else if lanes.isEmpty {
                        Text("no lanes").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    } else {
                        let working = lanes.filter { $0.group == .working }.count
                        HStack(spacing: 3) {
                            Text("\(working)/\(lanes.count)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                .contentTransition(reduce ? .opacity : .numericText(value: Double(working)))
                                .animation(Motion.list(reduce), value: "\(working)/\(lanes.count)")
                            Text("working").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        }
                    }
                }
                .lineLimit(1)
                .frame(width: DisplayManager.wing, alignment: .trailing).padding(.trailing, 10)
            }
        }
    }
}

// Working pills breathe off the meter's one clock (above), not a repeating animation, so a pill stops
// (fully lit) the moment its lane stops working. 15 fps: a 0.25 opacity swing over 1.6 s shows no steps.
