import BatonCore
import Defaults
import SwiftUI

/// The always-black notch with content in its wings, left and right of the camera.
struct CollapsedNotch: View {
    let geometry: NotchGeometry
    let notchHeight: CGFloat
    /// With the always-on shelf on, the wings show the lane meter whatever the collapsed style.
    var lanes = false

    @Default(.collapsedStyle) private var style
    private var model = AppModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.notchVisible) private var visible

    init(geometry: NotchGeometry, notchHeight: CGFloat, lanes: Bool = false) {
        self.geometry = geometry; self.notchHeight = notchHeight; self.lanes = lanes
    }

    private let ear: CGFloat = 6
    private var wing: CGFloat { DisplayManager.wing }

    var body: some View {
        if geometry.kind == .lip {
            // no menu bar on this screen: a thin sliver that opens on hover
            Capsule().fill(.black).frame(width: geometry.rect.width, height: NotchGeometry.lipHeight)
        } else if lanes || style == .lanes {
            LaneMeter(notchWidth: geometry.rect.width)
                .frame(width: geometry.rect.width + 2 * wing + 2 * ear + 20, height: notchHeight)
                .background(NotchShape(topRadius: ear, bottomRadius: 14).fill(.black))
        } else {
            // The task rows are rebuilt on every read: read them once per draw and hand them to both wings.
            let rows = model.rows
            let ready = rows.filter { $0.group == .ready }.sorted { $0.updated < $1.updated }   // = model.readyRows
            HStack(spacing: 0) {
                leading(rows, ready).frame(width: wing, alignment: .leading).padding(.leading, 10)
                Color.clear.frame(width: geometry.rect.width)
                trailing(rows, ready).frame(width: wing, alignment: .trailing).padding(.trailing, 10)
            }
            .frame(width: geometry.rect.width + 2 * wing + 2 * ear + 20, height: notchHeight)
            .background(NotchShape(topRadius: ear, bottomRadius: 14).fill(.black))
        }
    }

    @ViewBuilder private func leading(_ rows: [TaskRow], _ ready: [TaskRow]) -> some View {
        switch style {
        case .iconsNext, .lanes:   // Lanes draws LaneMeter instead (see body)
            HStack(spacing: 6) {
                ForEach(rows.prefix(4)) { r in
                    VStack(spacing: 1) {
                        AppIcon(bundleID: r.apps.first ?? "", size: 17)
                        Capsule().fill(Palette.color(r.group)).frame(width: 5, height: 2)
                            .animation(Motion.fade, value: r.group)
                    }
                    .transition(.opacity)
                }
            }
            // Icons are in status order: when a task's status moves it, it slides to its new place instead of jumping.
            .animation(Motion.list(reduce), value: rows.prefix(4).map(\.id))
        case .readyCount:
            IconStack(bundleIDs: ready.compactMap(\.apps.first), size: 20).modifier(Glow())
        case .progress:
            let working = rows.filter { $0.group == .working }
            if !working.isEmpty {
                Ticker(count: working.count) { i in
                    ZStack {
                        SpinningRing().frame(width: 24, height: 24)
                        AppIcon(bundleID: working[i].apps.first ?? "", size: 16)
                    }
                }
            } else {
                IconStack(bundleIDs: ready.compactMap(\.apps.first), size: 18)
            }
        }
    }

    @ViewBuilder private func trailing(_ rows: [TaskRow], _ ready: [TaskRow]) -> some View {
        if model.idlePaused {
            HStack(spacing: 4) {
                Image(systemName: "moon.zzz").font(.system(size: 10))
                Text("paused").font(.system(size: 11))
            }
            .foregroundStyle(Palette.secondary)
        } else {
        switch style {
        case .iconsNext, .lanes:   // Lanes draws LaneMeter instead (see body)
            if let next = ready.first {
                HStack(spacing: 6) {
                    Text("next").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    AppIcon(bundleID: next.apps.first ?? "", size: 19).modifier(Halo(cornerRadius: 5))
                }
            } else if let stuck = StuckWing.first(in: rows) {
                StuckWing(row: stuck)
            } else {
                let n = rows.filter { $0.group == .working }.count
                if n > 0 {
                    HStack(spacing: 5) {
                        // AppKit's spinner never stops on its own: show it only while motion can be seen.
                        if loopingMotion(visible: visible, reduce: reduce) {
                            ProgressView().controlSize(.mini).tint(Palette.working)
                        } else {
                            Circle().fill(Palette.working).frame(width: 6, height: 6).frame(width: 12)
                        }
                        Text("\(n) working").font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.working)
                            .contentTransition(reduce ? .opacity : .numericText(value: Double(n)))
                            .animation(Motion.list(reduce), value: n)
                    }
                } else {
                    // nothing running and nothing waiting: say so instead of leaving the wing empty
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        Text(rows.isEmpty ? "⌥N" : "all clear").font(.system(size: 11))
                    }
                    .foregroundStyle(Palette.secondary)
                }
            }
        case .readyCount:
            let n = ready.count
            if n > 0 {
                Text("\(n) ready").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(Palette.ready)
                    .contentTransition(reduce ? .opacity : .numericText(value: Double(n)))
                    .animation(Motion.list(reduce), value: n)
            }
        case .progress:
            let working = rows.filter { $0.group == .working }
            if !working.isEmpty {
                // Rotates through every working AI, in step with the icon on the left.
                Ticker(count: working.count) { i in
                    HStack(spacing: 5) {
                        Text(working[i].appNames.first ?? "").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        Text(working[i].updated, style: .timer).font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.working)
                    }
                    .lineLimit(1)
                }
            } else if let n = ready.first {
                Text(n.appNames.first.map { "\($0) ready" } ?? "ready").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ready)
            } else {
                Text("all clear").font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
        }
    }
    }
}


/// A short blue arc that circles while an AI is working. Driven by the clock at 30 fps (smooth for a
/// 24 pt ring) and fully stopped, not just hidden, when nobody can see it.
struct SpinningRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.notchVisible) private var visible
    var body: some View {
        let on = loopingMotion(visible: visible, reduce: reduce)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !on)) { ctx in
            let turn = on ? ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1 : 0
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 2)
                Circle().trim(from: 0, to: 0.3)
                    .stroke(Palette.working, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360))
            }
        }
    }
}

/// Shows one of `count` items at a time, sliding up to the next every few seconds. The index comes from
/// the clock, so tickers in both wings stay in step. It holds still (no clock at all) with one item, or
/// when nobody can see it, like the other looping motion.
struct Ticker<Content: View>: View {
    let count: Int
    var seconds: Double = 3
    @ViewBuilder let content: (Int) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.notchVisible) private var visible

    var body: some View {
        let on = count > 1 && loopingMotion(visible: visible, reduce: false)
        TimelineView(Every(seconds: seconds, on: on)) { ctx in
            let i = count > 1 ? Int(ctx.date.timeIntervalSinceReferenceDate / seconds) % count : 0
            ZStack {
                content(min(i, count - 1))
                    .id(i)
                    .transition(reduce ? .opacity : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                                removal: .move(edge: .top).combined(with: .opacity)))
            }
            .animation(Motion.list(reduce), value: i)
            .clipped()
        }
    }
}

/// Every `seconds` on the clock while `on`, else a single moment: a ticker that can stop.
private struct Every: TimelineSchedule {
    let seconds: Double
    let on: Bool
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        on ? AnySequence(PeriodicTimelineSchedule(from: startDate, by: seconds).entries(from: startDate, mode: mode))
            : AnySequence([startDate])
    }
}

/// A gold ring that keeps pulsing out from an icon: the task that's next for you. A slow, fading ring
/// reads smooth at 20 fps; it stops outright when nobody can see it.
struct Halo: ViewModifier {
    var cornerRadius: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.notchVisible) private var visible

    func body(content: Content) -> some View {
        let on = loopingMotion(visible: visible, reduce: reduce)
        content.overlay {
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !on)) { ctx in
                // easeOut over 1.8 s, then again: same curve as before.
                let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                let p = 1 - (1 - t) * (1 - t)
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Palette.ready, lineWidth: 1.5)
                    .scaleEffect(on ? 1 + 0.6 * p : 1)
                    .opacity(on ? 0.7 * (1 - p) : 0)
            }
            .allowsHitTesting(false)
        }
    }
}

/// A slow fade in and out for things waiting on you. 15 fps is plenty for a 1.2 s opacity swing,
/// and it stops (fully lit) when nobody can see it.
struct Glow: ViewModifier {
    var low = 0.55
    var duration = 1.2
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.notchVisible) private var visible

    func body(content: Content) -> some View {
        let on = loopingMotion(visible: visible, reduce: reduce)
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !on)) { ctx in
            // easeInOut there and back, like the old autoreversing animation.
            let t = ctx.date.timeIntervalSinceReferenceDate / duration
            let wave = 0.5 - 0.5 * cos(t * .pi)
            content.opacity(on ? 1 - (1 - low) * wave : 1)
        }
    }
}
