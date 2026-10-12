import BatonCore
import SwiftUI

struct PingView: View {
    private var model = AppModel.shared
    @State private var drain = 1.0
    @State private var pop = false
    @State private var sheen: CGFloat = -0.5
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        if let p = model.ping {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    AppIcon(bundleID: p.bundleID, size: 48)
                        .scaleEffect(pop ? 1 : 0.86)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Palette.ready, lineWidth: 2)
                                .scaleEffect(pop ? 1.35 : 1)
                                .opacity(pop ? 0 : 0.8)
                        )
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(p.headline)
                                .font(.system(size: 13, weight: .semibold))
                            Text(p.badge)
                                .font(.system(size: 9, weight: .bold)).tracking(0.5)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .foregroundStyle(Palette.ready)
                                .background(Palette.ready.opacity(0.15), in: Capsule())
                        }
                        Text(model.parentTitle(of: p.taskID).map { "\(p.text) · in \($0)" } ?? p.text)
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(2)
                            .contentTransition(.opacity)
                            .animation(.easeOut(duration: 0.25), value: p.text)
                    }
                    Spacer(minLength: 6)
                    Button("Later") { model.collapse() }
                        .buttonStyle(PillButton(fill: .white.opacity(0.1), text: .white))
                    // Done with 4 seconds of Undo on the shelf and in the list, like every other ✓.
                    // A chat you don't track has no task to finish.
                    if p.waiting == nil, !p.test {
                        Button { model.dismissPingDone(p.taskID) } label: { Image(systemName: "checkmark") }
                            .buttonStyle(PillButton(fill: .white.opacity(0.1), text: .white))
                            .help("Mark the whole task done")
                    }
                    Button("Jump") { model.jump(p.taskID) }
                        .buttonStyle(PillButton(fill: Palette.ready, text: .black))
                }
                // Answer it from here: quick answers and a reply field (see Relay).
                if let t = Relay.target(for: p) { ReplyBar(target: t).padding(.leading, 60) }
                if let next = model.readyRows.first(where: { $0.id != p.taskID }) {
                    HStack(spacing: 8) {
                        Text("Also ready")
                        AppIcon(bundleID: next.apps.first ?? "", size: 16)
                        Text(next.title).foregroundStyle(.white)
                        Spacer()
                        Text("⌥⇥ next")
                    }
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    .padding(.top, 8)
                    .overlay(alignment: .top) { Divider().overlay(.white.opacity(0.08)) }
                }
                // How long until the ping closes. No bar when it stays until you answer it.
                if hasTimeout {
                    GeometryReader { g in
                        Capsule().fill(Palette.ready.opacity(0.6)).frame(width: g.size.width * drain, height: 2)
                    }
                    .frame(height: 2)
                }
            }
            .overlay {
                // a gold sheen sweeping across once as the ping lands
                GeometryReader { g in
                    LinearGradient(colors: [.clear, Palette.ready.opacity(0.14), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.3)
                        .offset(x: sheen * g.size.width)
                }
                .allowsHitTesting(false)
            }
            .onAppear(perform: animateIn)
            .onChange(of: p.taskID) { animateIn() }
            .onChange(of: model.cardDeadline) { startDrain() }
        }
    }

    /// "Never" closes no ping, so there's nothing to count down (and no 100 000-second animation to run).
    private var hasTimeout: Bool {
        guard let d = model.cardDeadline else { return false }
        return d.timeIntervalSinceNow < 3600
    }

    /// The icon settles in with the notch's spring (no wobble) and one ring goes out; the sheen follows
    /// once the card is open. Reduce Motion: the icon is just there.
    private func animateIn() {
        startDrain()
        guard !reduce else { pop = true; return }
        pop = false
        sheen = -0.5
        withAnimation(.easeOut(duration: 0.9).delay(0.3)) { sheen = 1.2 }
        withAnimation(Motion.shape.delay(0.08)) { pop = true }
    }

    private func startDrain() {
        drain = 1
        guard hasTimeout, let d = model.cardDeadline else { return }
        withAnimation(.linear(duration: max(d.timeIntervalSinceNow, 0))) { drain = 0 }
    }
}

struct PillButton: ButtonStyle {
    let fill: Color
    let text: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(text)
            .padding(.horizontal, 14).frame(height: 30)
            .background(fill, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}
