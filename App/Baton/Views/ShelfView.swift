import BatonCore
import Defaults
import SwiftUI

/// The always-on shelf from the B2 design: a short black strip hanging from the notch. The first slot holds
/// what's next for you; the rest of your tasks drift past on a belt. A gold pop plays when a task finishes.
struct ShelfView: View {
    let notchHeight: CGFloat
    let notchWidth: CGFloat
    let glass: Bool
    private var model = AppModel.shared

    static let width: CGFloat = 900
    static let rowHeight: CGFloat = 58

    init(notchHeight: CGFloat, notchWidth: CGFloat = 185, glass: Bool = false) {
        self.notchHeight = notchHeight; self.notchWidth = notchWidth; self.glass = glass
    }

    var body: some View {
        // The task rows are rebuilt on every read, so read them once per draw and derive the rest from them.
        let top = model.topRows
        let ready = Self.readyLeaves(top)
        let first = Self.first(top, nextReady: ready.first?.id, active: model.activeTaskID)
        // Creation order, not status order: the belt mustn't reshuffle (and jump) every time a status changes.
        let rest = top.filter { $0.id != first?.id }.sorted { $0.created < $1.created }
        VStack(spacing: 0) {
            // The notch strip itself: with the shelf on, its wings show the lane meter.
            if !glass { LaneMeter(notchWidth: notchWidth).frame(height: notchHeight) }
            HStack(spacing: 0) {
                if let first {
                    FirstSlot(row: first, popToken: model.popToken).frame(width: 270).zIndex(1)
                } else {
                    Text("No tasks yet · ⌥N to start one")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        .frame(maxWidth: .infinity)
                }
                if !rest.isEmpty {
                    Belt(rows: rest, stir: Self.statusKey(top))
                }
                ReadyCount(count: ready.count).zIndex(1)
            }
            .frame(height: Self.rowHeight)
        }
        .padding(.horizontal, 14)
        .frame(width: Self.width)
        .background {
            if glass {
                SystemGlass(cornerRadius: 22)
                    .overlay(RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 22))
            } else {
                // The shadow belongs to the black shape alone (everything sits inside it, so it looks the same):
                // cast from the whole shelf, it was blurred again on every frame anything inside moved.
                NotchShape(topRadius: 10, bottomRadius: 20).fill(.black)
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
            }
        }
        .padding(.top, glass ? notchHeight + 6 : 0)
        .modifier(GlassShadow(on: glass))
    }

    /// Changes whenever any task's status does (not when they only reorder): the belt drifts for a while after.
    static func statusKey(_ top: [TaskRow]) -> Int {
        var h = Hasher()
        for r in top.flatMap({ $0.isGroup ? $0.children : [$0] }).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            h.combine(r.id); h.combine(r.group); h.combine(r.state)
        }
        return h.finalize()
    }

    /// Same as `AppModel.readyRows`, from top rows already read: every big task's subtasks are in its children.
    static func readyLeaves(_ top: [TaskRow]) -> [TaskRow] {
        top.flatMap { $0.isGroup ? $0.children : [$0] }.filter { $0.group == .ready }.sorted { $0.updated < $1.updated }
    }

    /// Same as `AppModel.shelfFirst`: the row holding the next ready task, else the active one, else the top row.
    static func first(_ top: [TaskRow], nextReady: UUID?, active: UUID?) -> TaskRow? {
        func holding(_ id: UUID?) -> TaskRow? {
            guard let id else { return nil }
            return top.first { $0.id == id || $0.children.contains { $0.id == id } }
        }
        return holding(nextReady) ?? holding(active) ?? top.first
    }
}

private struct ShelfCard: View {
    let row: TaskRow
    @State private var hovering = false
    @State private var showTick = false   // the ✓ only after you rest on a card, not while passing over it
    /// A big task shows the task in it you'd work on next (the ready one, else the most urgent),
    /// with how the big task stands and its name under it: "1 working · 2 idle · NEW FEATURES".
    private var lead: TaskRow? { row.isGroup ? row.children.first { $0.group == .ready } ?? row.children.first : nil }
    /// What clicking, ✓ and Undo act on: that task inside a big task, else the row itself.
    private var target: TaskRow { lead ?? row }
    private var done: Bool { AppModel.shared.finishing.contains(target.id) }

    var body: some View {
        Button { done ? AppModel.shared.undoDone(target.id) : AppModel.shared.jump(target.id) } label: {
            HStack(spacing: 10) {
                if row.isGroup {
                    BigTaskStack(bundleIDs: row.apps, size: 26)
                } else {
                    AppIcon(bundleID: row.apps.first ?? "", size: 30)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        StatusDot(color: Palette.color(target.group), wantsYou: target.group == .ready)
                            .modifier(BreatheIf(on: target.group == .working))
                        Text(tag).font(.system(size: 9, weight: .semibold)).tracking(0.5)
                            .contentTransition(.opacity)
                    }
                    .foregroundStyle(Palette.color(target.group))
                    .animation(Motion.fade, value: target.group)
                    Text(target.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).strikethrough(done)
                    Text(lead != nil ? "\(row.line) · \(row.title)" : row.line)
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 14).padding(.trailing, showTick || done ? 44 : 14)
            .frame(maxHeight: .infinity)
            .background(.white.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if done {
                Button("Undo") { AppModel.shared.undoDone(target.id) }
                    .buttonStyle(PillButton(fill: Palette.ready, text: .black))
                    .padding(.trailing, 8)
                    .transition(.opacity)
            } else if showTick {
                // Rest on a card to finish its task in one click.
                Button(action: finish) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Mark task done")
                .accessibilityLabel("Mark \(target.title) done")
                .padding(.trailing, 8)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .opacity(done ? 0.5 : 1)
        .animation(.easeOut(duration: 0.15), value: showTick)
        .animation(.easeOut(duration: 0.15), value: done)
        .onHover { hovering = $0; if !$0 { showTick = false } }
        // Another task slid under the pointer (the first slot or a big task's lead changed): its ✓ waits for a new rest.
        .onChange(of: target.id) { showTick = false }
        .task(id: hovering ? target.id : nil) {
            guard hovering else { return }
            try? await Task.sleep(for: .milliseconds(600))
            if hovering && !Task.isCancelled { showTick = true }
        }
        .contextMenu { TaskMenu(row: row) }
    }

    private func finish() {
        showTick = false
        withAnimation(Motion.list) { AppModel.shared.markDone(target.id) }
    }

    private var tag: String {
        switch target.group {
        case .ready: target.state == .needsYou ? "NEEDS YOU" : "READY"
        case .working: "WORKING"
        case .idle: "IDLE"
        case .now: "NOW"
        }
    }
}

private struct FirstSlot: View {
    let row: TaskRow
    let popToken: Int
    @State private var pop = 1.0
    @State private var sheen: CGFloat = -1
    @State private var ring = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        ShelfCard(row: row)
            .scaleEffect(0.94 + 0.06 * pop)
            .overlay {
                // gold sheen sweeping across once
                GeometryReader { g in
                    LinearGradient(colors: [.clear, Palette.ready.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.4)
                        .offset(x: sheen * g.size.width)
                }
                .allowsHitTesting(false)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Palette.ready, lineWidth: 2)
                    .frame(width: 32, height: 32)
                    .scaleEffect(1 + ring * 0.5)
                    .opacity(ring > 0 ? 1 - ring : 0)
                    .padding(.leading, 13)
                    .allowsHitTesting(false)
            }
            .onChange(of: popToken) { playPop() }
    }

    private func playPop() {
        guard !reduce else { return }
        pop = 0; sheen = -0.5; ring = 0
        withAnimation(Motion.shape) { pop = 1 }
        withAnimation(.easeOut(duration: 1.1).delay(0.15)) { sheen = 1.3 }
        withAnimation(.easeOut(duration: 1.2).delay(0.3).repeatCount(2, autoreverses: false)) { ring = 1 }
    }
}

/// Your other tasks on a strip that sits still, showing the most urgent ones (needs you, then ready), and
/// drifts left at the set speed only while you come up to the shelf or for a few seconds after a task's
/// status changes; the list is drawn twice so the loop has no seam. It eases into motion and glides to a stop
/// on the most urgent cards again. With Reduce Motion, while nobody can see it, or when everything fits,
/// it doesn't move at all. A still belt draws no frames.
private struct Belt: View {
    let rows: [TaskRow]
    /// Changes when a task's status does.
    let stir: Int
    @Default(.beltSpeed) private var speed
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.notchVisible) private var visible
    @Environment(\.notchDisplayID) private var displayID
    @State private var motion = BeltMotion(at: 0)
    @State private var stirred = false
    @State private var stirToken = 0
    private let itemWidth: CGFloat = 230
    /// How long the belt keeps drifting after a status change.
    private static let stirSeconds = 9.0

    enum Want: Equatable { case drift, hold, settle }

    /// Everything that decides where the belt should be heading. A change re-plans the motion from where it is.
    private struct Plan: Equatable {
        var loop: Double
        var width: Double
        var urgency: [Int]
        var want: Want
        var instant: Bool
        var speed: Double
    }

    var body: some View {
        let model = AppModel.shared
        GeometryReader { g in
            let loop = itemWidth * CGFloat(rows.count)
            let moving = loop > g.size.width
            // Hover and idle state are read here, so they re-plan the belt without rebuilding the shelf's rows.
            let canMove = moving && loopingMotion(visible: visible, reduce: reduce)
            let want: Want = model.pointerOnShelf ? .hold
                : canMove && (model.pointerNearShelf == displayID || stirred) ? .drift : .settle
            let plan = Plan(loop: Double(loop), width: Double(g.size.width), urgency: rows.map(Self.urgency),
                            want: want, instant: !canMove, speed: speed.pointsPerSecond)
            // 30 fps drifting at 18–48 pt/s is a point or so per frame: smooth. A glide can be quicker, so 60.
            TimelineView(.animation(minimumInterval: motion.gliding ? 1.0 / 60 : 1.0 / 30, paused: !motion.moving)) { ctx in
                let x = moving ? -CGFloat(motion.position(at: ctx.date).truncatingRemainder(dividingBy: Double(loop))) : 0
                let count = moving ? rows.count * 2 : rows.count
                // Clipping hides cards that slid past the edges but they'd still take clicks, landing a
                // click on a hidden card under the first slot. Only mostly-visible cards are clickable.
                let clickable = Set((0..<count).filter { i in
                    let minX = CGFloat(i) * itemWidth + x
                    return min(minX + itemWidth, g.size.width) - max(minX, 0) >= itemWidth * 0.6
                })
                BeltStrip(rows: rows, doubled: moving, clickable: clickable, itemWidth: itemWidth)
                    .equatable()
                    .offset(x: x)
            }
            .onChange(of: plan, initial: true) { _, p in replan(p) }
        }
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                     .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .onChange(of: stir) { stirred = true; stirToken += 1 }
        .task(id: stirToken) {
            guard stirred else { return }
            try? await Task.sleep(for: .seconds(Self.stirSeconds))
            if !Task.isCancelled { stirred = false }
        }
        // A glide that ran its course becomes still, so the clock stops.
        .task(id: motion) {
            guard let left = motion.remaining(at: .now) else { return }
            try? await Task.sleep(for: .seconds(left))
            if !Task.isCancelled { motion = motion.settled() }
        }
    }

    /// 2 for a task that needs you, 1 for one that's ready, else 0.
    private static func urgency(_ r: TaskRow) -> Int {
        r.state == .needsYou ? 2 : r.group == .ready ? 1 : 0
    }

    private func replan(_ p: Plan) {
        let now = Date.now
        guard p.loop > p.width, p.loop > 0 else { motion = BeltMotion(at: 0); return }
        let here = motion.position(at: now).truncatingRemainder(dividingBy: p.loop)
        let v = motion.speed(at: now)
        switch p.want {
        case .drift:
            motion = .drift(from: here, speed: p.speed, startSpeed: v, at: now)
        case .hold:
            // The pointer reached the shelf: stop under it within a few points, not dead on the spot.
            motion = v < 1 ? BeltMotion(at: here) : .glide(from: here, by: v * 0.2, startSpeed: v, duration: 0.4, at: now)
        case .settle:
            let i = BeltMotion.restIndex(p.urgency, visible: Int(p.width / Double(itemWidth)), from: here, itemWidth: Double(itemWidth))
            let target = Double(i) * Double(itemWidth)
            let by = (target - here + p.loop).truncatingRemainder(dividingBy: p.loop)
            if p.instant || (by < 0.5 && v < 1) {
                motion = BeltMotion(at: target)
            } else if v >= 1 {
                // Moving: slow down into place, about as gently as it would stop on its own.
                motion = .glide(from: here, by: by, startSpeed: v, duration: min(max(2 * by / v, 0.35), 3.5), at: now)
            } else {
                motion = .glide(from: here, by: by, startSpeed: 0, duration: min(max(1.5 * by / p.speed, 0.5), 2.5), at: now)
            }
        }
    }
}

/// The belt's position as a function of the clock, so a frame only reads the time: still, drifting at a
/// speed it eases into, or gliding to a stop at a chosen place. Positions are points travelled left.
struct BeltMotion: Equatable {
    enum Kind: Equatable {
        case still
        case drift(speed: Double)
        case glide(by: Double, duration: Double)
    }
    var start: Double
    var startSpeed = 0.0
    var since = Date.distantPast
    var kind = Kind.still

    /// Seconds a drift takes to reach its speed.
    static let rampIn = 0.8

    init(at position: Double) { start = position }

    static func drift(from p: Double, speed: Double, startSpeed: Double, at t: Date) -> BeltMotion {
        var m = BeltMotion(at: p); m.startSpeed = startSpeed; m.since = t; m.kind = .drift(speed: speed); return m
    }

    static func glide(from p: Double, by d: Double, startSpeed: Double, duration: Double, at t: Date) -> BeltMotion {
        var m = BeltMotion(at: p); m.startSpeed = startSpeed; m.since = t
        m.kind = .glide(by: max(d, 0), duration: max(duration, 0.01))
        return m
    }

    var moving: Bool { kind != .still }
    var gliding: Bool { if case .glide = kind { true } else { false } }

    /// Seconds until a glide ends (nil when it isn't gliding).
    func remaining(at t: Date) -> Double? {
        guard case let .glide(_, duration) = kind else { return nil }
        return max(duration - t.timeIntervalSince(since), 0)
    }

    /// A finished glide, at rest where it ended.
    func settled() -> BeltMotion {
        guard case let .glide(by, _) = kind else { return self }
        return BeltMotion(at: start + by)
    }

    /// The speed a glide carries in, capped so it never overshoots (the curve stays monotone up to 3× the distance).
    private func carried(_ by: Double, _ duration: Double) -> Double { min(startSpeed * duration, 3 * by) }

    func position(at t: Date) -> Double {
        let s = max(t.timeIntervalSince(since), 0)
        switch kind {
        case .still:
            return start
        case let .drift(v):
            let r = Self.rampIn
            if s < r { return start + startSpeed * s + (v - startSpeed) * s * s / (2 * r) }
            return start + (startSpeed + v) * r / 2 + v * (s - r)
        case let .glide(by, duration):
            guard s < duration else { return start + by }
            let u = s / duration, m = carried(by, duration)
            return start + m * (u * u * u - 2 * u * u + u) + by * (3 * u * u - 2 * u * u * u)
        }
    }

    func speed(at t: Date) -> Double {
        let s = max(t.timeIntervalSince(since), 0)
        switch kind {
        case .still:
            return 0
        case let .drift(v):
            return s < Self.rampIn ? startSpeed + (v - startSpeed) * s / Self.rampIn : v
        case let .glide(by, duration):
            guard s < duration else { return 0 }
            let u = s / duration, m = carried(by, duration)
            return (m * (3 * u * u - 4 * u + 1) + by * (6 * u - 6 * u * u)) / duration
        }
    }

    /// Where a still belt rests, in cards: the start whose fully visible cards hold the most that need you,
    /// then the most ready, the first of them as far left as can be; on a tie, the nearest one ahead.
    static func restIndex(_ urgency: [Int], visible: Int, from position: Double, itemWidth: Double) -> Int {
        let n = urgency.count
        guard n > 0, itemWidth > 0 else { return 0 }
        let k = max(1, min(visible, n))
        let loop = Double(n) * itemWidth
        func score(_ i: Int) -> [Int] {
            let w = (0..<k).map { urgency[(i + $0) % n] }
            let lead = w.firstIndex(where: { $0 > 0 }) ?? k
            return [w.filter { $0 == 2 }.count, w.filter { $0 >= 1 }.count, -lead]
        }
        let here = position.truncatingRemainder(dividingBy: loop)
        func ahead(_ i: Int) -> Double { (Double(i) * itemWidth - here + loop).truncatingRemainder(dividingBy: loop) }
        return (0..<n).max { a, b in
            let sa = score(a), sb = score(b)
            return sa != sb ? sa.lexicographicallyPrecedes(sb) : ahead(a) > ahead(b)
        } ?? 0
    }
}

/// The belt's cards. Equatable, so a frame that only moves the belt doesn't rebuild them.
private struct BeltStrip: View, Equatable {
    let rows: [TaskRow]
    let doubled: Bool
    let clickable: Set<Int>
    let itemWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            // Keyed by task (and which copy of the loop), so a card's state never moves to another task.
            ForEach(Array((doubled ? rows + rows : rows).enumerated()).map { ($0.offset, "\($0.element.id)-\($0.offset >= rows.count)", $0.element) }, id: \.1) { i, _, r in
                HStack(spacing: 0) {
                    Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 30)
                    ShelfCard(row: r)
                }
                .frame(width: itemWidth)
                .allowsHitTesting(clickable.contains(i))
            }
        }
    }
}

/// How many tasks wait on you; click it to jump to the next one.
private struct ReadyCount: View {
    let count: Int
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 30)
            Button { AppModel.shared.jumpToNextReady() } label: {
                VStack(spacing: 1) {
                    Text("\(count)").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(count > 0 ? Palette.ready : Palette.secondary)
                        .underline(hovering && count > 0)
                        .contentTransition(.numericText())
                        .animation(Motion.list, value: count)
                    Text("READY").font(.system(size: 8, weight: .semibold)).tracking(0.5).foregroundStyle(Palette.secondary)
                }
                .frame(width: 54)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(count == 0)
            .onHover { hovering = $0 }
            .help("Jump to the next ready task (⌥⇥)")
            .accessibilityLabel(count > 0 ? "Jump to the next ready task, \(count) ready" : "Nothing ready")
        }
    }
}

/// On glass the shadow falls from the shelf's contents (the glass itself casts none), so it stays on the
/// whole shelf there; the black shelf casts its own from its shape.
private struct GlassShadow: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.shadow(color: .black.opacity(0.4), radius: 12, y: 6) } else { content }
    }
}

/// The design's breathing dot for working tasks.
private struct BreatheIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.modifier(Glow(low: 0.35, duration: 0.8)) } else { content }
    }
}
