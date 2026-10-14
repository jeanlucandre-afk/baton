import BatonCore
import Defaults
import SwiftUI

enum Palette {
    static let ready = Color(red: 0.94, green: 0.76, blue: 0.42)
    static let working = Color(red: 0.53, green: 0.66, blue: 1.0)
    static let idle = Color(white: 0.62)
    static let now = Color(red: 0.79, green: 0.68, blue: 1.0)
    static let secondary = Color.white.opacity(0.55)

    static func color(_ g: TaskRow.Group) -> Color {
        switch g { case .now: now; case .ready: ready; case .working: working; case .idle: idle }
    }
}

/// One motion language for the notch: a single spring for the shape, the content fading in just after
/// it grows and out before it shrinks, lists that slide rather than jump. Nothing over 350 ms, no bounce
/// you'd notice. With Reduce Motion, everything is a plain short fade.
enum Motion {
    /// The notch opening, closing and resizing between cards.
    static let shape = Animation.spring(duration: 0.35, bounce: 0.15)
    /// Rows moving, arriving and leaving.
    static let list = Animation.spring(duration: 0.3, bounce: 0.1)
    /// Colors and labels changing in place.
    static let fade = Animation.easeInOut(duration: 0.25)
    static let reduced = Animation.easeInOut(duration: 0.2)

    /// The dark notch opening: the black springs out of the notch with a small overshoot.
    static let pop = Animation.spring(duration: 0.42, bounce: 0.3)

    static func shape(_ reduce: Bool) -> Animation { reduce ? reduced : shape }
    static func pop(_ reduce: Bool) -> Animation { reduce ? reduced : pop }
    static func list(_ reduce: Bool) -> Animation { reduce ? reduced : list }

    /// Rows: in with a short drop and a fade, out with a fade; a row that changes section is carried
    /// across by its matched geometry instead.
    static func row(_ reduce: Bool) -> AnyTransition {
        reduce ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity)
    }

    /// A glass card coming out of the notch: from just under it, slightly smaller, clear.
    static func fromNotch(_ reduce: Bool) -> AnyTransition {
        reduce ? .opacity : .asymmetric(
            insertion: .modifier(active: FromNotch(on: true), identity: FromNotch(on: false)),
            removal: .opacity.animation(.easeIn(duration: 0.12)))
    }
}

private struct FromNotch: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content.scaleEffect(on ? 0.94 : 1, anchor: .top).offset(y: on ? -10 : 0).opacity(on ? 0 : 1)
    }
}

/// What's inside an open card arrives a beat after the shape: a short fade with the last of a blur,
/// so the black grows first and the words settle into it. Plays again whenever the card changes.
struct Reveal: ViewModifier {
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown || reduce ? 0 : 5)
            .offset(y: shown || reduce ? 0 : -3)
            .onAppear {
                withAnimation(reduce ? Motion.reduced : .easeOut(duration: 0.22).delay(0.1)) { shown = true }
            }
    }
}

/// A status dot. Its color cross-fades when the status changes, and turning ready ("finished" or
/// "needs you") sends one soft ring out of it. Nothing loops here; the breathing of working lanes is elsewhere.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 5
    /// True while the status is one that wants you (ready / needs you): the ring plays when it turns true.
    var wantsYou = false
    @State private var ringScale = 1.0
    @State private var ringAlpha = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Circle().fill(color)
            .frame(width: size, height: size)
            .overlay {
                Circle().stroke(color, lineWidth: 1)
                    .scaleEffect(ringScale)
                    .opacity(ringAlpha)
                    .allowsHitTesting(false)
            }
            .animation(Motion.fade, value: color)
            .onChange(of: wantsYou) { _, on in
                guard on, !reduce else { return }
                // Set the start without animating, then let it go out on the next frame.
                ringScale = 1; ringAlpha = 0.7
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.45)) { ringScale = 2.8; ringAlpha = 0 }
                }
            }
    }
}

extension EnvironmentValues {
    /// False while this screen's notch panel is fully covered (or its screen is asleep): looping motion stops.
    @Entry var notchVisible = true
    /// The display this notch panel is on.
    @Entry var notchDisplayID: CGDirectDisplayID = 0
}

/// Endless motion runs only when someone can see it: the panel isn't covered, you're not away, and Reduce
/// Motion is off. Everything that loops (belt, lanes, spinners, halos) asks this before it draws a frame.
@MainActor func loopingMotion(visible: Bool, reduce: Bool) -> Bool {
    visible && !reduce && !AppModel.shared.idlePaused && !AppModel.shared.notLooking
}

/// Watches the panel's occlusion state (another screen asleep, the panel ordered out, a full-screen space
/// that hides it) and hands it down as `notchVisible`.
private struct PanelOcclusion: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.onChange = { visible = $0 }
        return v
    }
    func updateNSView(_ v: Probe, context: Context) { v.onChange = { visible = $0 } }

    final class Probe: NSView {
        var onChange: ((Bool) -> Void)?
        private var token: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            guard let window else { return }
            token = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                           object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            guard let window else { return }
            let on = window.occlusionState.contains(.visible)
            DispatchQueue.main.async { [onChange] in onChange?(on) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Everything one screen's notch draws. The collapsed notch is always black so it melts into the hardware notch;
/// the theme only changes how it looks when open.
struct NotchRootView: View {
    let displayID: CGDirectDisplayID
    let geometry: NotchGeometry
    let panelFrame: CGRect

    @Default(.theme) private var theme
    @Default(.showShelf) private var showShelf
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var panelVisible = true
    /// The open card's height, as last measured: the black grows toward it, and follows it when it changes.
    @State private var openHeight: CGFloat = 320
    /// False until the open card has been measured once since it opened: that first size is still the pop.
    @State private var measuredSinceOpen = false
    private var model = AppModel.shared

    init(displayID: CGDirectDisplayID, geometry: NotchGeometry, panelFrame: CGRect) {
        self.displayID = displayID; self.geometry = geometry; self.panelFrame = panelFrame
    }

    private var isOpen: Bool { model.mode != .collapsed && model.openScreen == displayID }
    private var notchW: CGFloat { geometry.rect.width }
    private var notchH: CGFloat { max(geometry.rect.height, geometry.kind == .lip ? 24 : 0) }
    private var centerX: CGFloat { geometry.rect.midX - panelFrame.minX }

    private var shelfOn: Bool { showShelf && geometry.kind != .lip }
    /// False while the collapsed notch's right wing would cover menu bar items (see MenuBarExtras).
    private var rightWing: Bool { MenuBarExtras.shared.rightWingFits(geometry) }
    /// The plain collapsed notch is the one shape that can lose its right wing, and so move off-center.
    private var collapsedShift: CGFloat {
        isOpen || shelfOn || geometry.kind == .lip ? 0 : CollapsedNotch.shift(rightWing: rightWing)
    }

    private var openWidth: CGFloat {
        switch model.mode {
        case .ping: ContinueFlow.shared.showing || Relay.shared.showing || UsageMonitor.shared.alert != nil ? 600 : 560
        case .newTask: 640
        case .newChat: 560
        default: 700
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            if theme == .dark {
                darkMorph
            } else {
                CollapsedNotch(geometry: geometry, notchHeight: notchH, lanes: shelfOn)
                    .offset(x: geometry.kind == .lip ? 0 : CollapsedNotch.shift(rightWing: rightWing))
                if shelfOn && !isOpen {
                    ShelfView(notchHeight: notchH, glass: true)
                        .transition(reduce ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
                if isOpen {
                    glassOpen
                        .padding(.top, notchH + 8)
                        .transition(Motion.fromNotch(reduce))
                }
            }
        }
        .frame(width: panelFrame.width, height: panelFrame.height, alignment: .top)
        .offset(x: centerX - panelFrame.width / 2)
        .environment(\.colorScheme, .dark)
        .environment(\.notchVisible, panelVisible)
        .environment(\.notchDisplayID, displayID)
        .background(PanelOcclusion(visible: $panelVisible).frame(width: 0, height: 0))
        // One spring for opening, closing and switching cards, so the shape never moves two ways at once.
        // Opening pops (a little overshoot, like the Dynamic Island); closing settles without it.
        .animation(isOpen ? Motion.pop(reduce) : Motion.shape(reduce), value: isOpen)
        .animation(Motion.shape(reduce), value: model.mode)
        .animation(Motion.shape(reduce), value: showShelf)
        .animation(Motion.shape(reduce), value: rightWing)
    }

    /// Each card is its own view, so switching cards (list → new task, ping → list) reveals the new one too.
    private var openContent: some View {
        ZStack(alignment: .top) {
            switch model.mode {
            case .ping:
                if ContinueFlow.shared.showing { ContinueView().modifier(Reveal()) }
                else if Relay.shared.showing { RelayView().modifier(Reveal()) }
                else if UsageMonitor.shared.alert != nil { UsageAlertView().modifier(Reveal()) }
                else { PingView().modifier(Reveal()) }
            case .newTask: NewTaskView().modifier(Reveal())
            case .newChat: NewChatView().modifier(Reveal())
            default: ExpandedView().modifier(Reveal())
            }
        }
    }

    /// The dark notch is one black shape that never goes away: it is the notch (or the shelf) when collapsed
    /// and grows out of it into the open card, then shrinks back. Whatever is inside is clipped to it, so the
    /// card is uncovered as the black grows instead of sliding in.
    private var darkMorph: some View {
        let size = darkSize
        let shape = isOpen ? NotchShape(topRadius: 15, bottomRadius: 22)
            : geometry.kind == .lip ? NotchShape(topRadius: 0, bottomRadius: NotchGeometry.lipHeight / 2)
            : shelfOn ? NotchShape(topRadius: 10, bottomRadius: 20)
            : NotchShape(topRadius: 6, bottomRadius: 14)
        return ZStack(alignment: .top) {
            // Shadow from the black shape alone, so it isn't blurred again each time something inside moves.
            // Open only: the shelf brings its own, and the collapsed notch has none.
            shape.fill(.black)
                .shadow(color: .black.opacity(isOpen ? 0.6 : 0), radius: 14, y: 6)
                .frame(width: size.width, height: size.height)
                .modifier(ReportsContentFrame(displayID: displayID, active: isOpen))
            darkContent
                // Laid out as tall as the panel allows (as before), then cut to the shape as it grows.
                .frame(height: panelFrame.height, alignment: .top)
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
        }
        .offset(x: collapsedShift)
    }

    /// Exactly one of these at a time. Opening, the collapsed one is gone almost at once; closing, the words
    /// clear before the black has shrunk much and the notch's own content comes back once it has.
    @ViewBuilder private var darkContent: some View {
        let leave = AnyTransition.opacity.animation(.easeIn(duration: 0.1))
        let settle = AnyTransition.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.15)),
                                              removal: leave)
        ZStack(alignment: .top) {
            if isOpen {
                openContent
                    .padding(.top, notchH + 6)
                    .padding(.horizontal, 15 + 14)
                    .padding(.bottom, 16)
                    .frame(width: openWidth)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                        let first = !measuredSinceOpen
                        measuredSinceOpen = true
                        guard h != openHeight else { return }
                        withAnimation(first ? Motion.pop(reduce) : Motion.shape(reduce)) { openHeight = h }
                    }
                    .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(.easeIn(duration: 0.12))))
            } else if shelfOn {
                ShelfView(notchHeight: notchH, notchWidth: notchW).transition(settle)
            } else {
                CollapsedNotch(geometry: geometry, notchHeight: notchH).transition(settle)
            }
        }
        .onChange(of: isOpen) { _, open in if !open { measuredSinceOpen = false } }
    }

    /// The black shape's size: the card when open (its last measured height), else the shelf or the notch.
    private var darkSize: CGSize {
        if isOpen { return CGSize(width: openWidth, height: openHeight) }
        if geometry.kind == .lip { return CGSize(width: notchW, height: NotchGeometry.lipHeight) }
        if shelfOn { return CGSize(width: ShelfView.width, height: notchH + ShelfView.rowHeight) }
        return CGSize(width: CollapsedNotch.width(notchWidth: notchW, rightWing: rightWing), height: notchH)
    }

    private var glassOpen: some View {
        openContent
            .padding(16)
            .frame(width: openWidth - 30)
            .background(SystemGlass(cornerRadius: 26))
            .overlay(
                // the bright top edge that makes glass read as glass
                RoundedRectangle(cornerRadius: 26)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 26))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            .modifier(ReportsContentFrame(displayID: displayID))
    }
}

/// Tells the display manager where the open card really is, so the panel takes clicks (and counts as hovered)
/// only there, and the transparent rest of it lets clicks through to the apps below.
private struct ReportsContentFrame: ViewModifier {
    let displayID: CGDirectDisplayID
    /// False while the dark shape is the collapsed notch or shelf rather than an open card.
    var active = true
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            if active { DisplayManager.shared.setContentFrame($0, on: displayID) }
        }
    }
}

/// App icon by bundle ID, cached.
struct AppIcon: View {
    let bundleID: String
    var size: CGFloat = 32

    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        Image(nsImage: Self.icon(bundleID))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }

    static func icon(_ id: String) -> NSImage {
        if let i = cache[id] { return i }
        let img: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            img = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            img = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        cache[id] = img
        return img
    }
}

/// A big task: its apps' icons stacked like cards, up and to the right, the front one solid.
/// One app still shows three layers, so a big task always reads as a stack.
struct BigTaskStack: View {
    let bundleIDs: [String]
    var size: CGFloat = 30

    var body: some View {
        let ids = bundleIDs.isEmpty ? [""] : bundleIDs
        let layers = (0..<3).map { ids[min($0, ids.count - 1)] }
        ZStack(alignment: .bottomLeading) {
            ForEach(Array(layers.enumerated().reversed()), id: \.offset) { i, id in
                AppIcon(bundleID: id, size: size - CGFloat(i) * 2)
                    .opacity([1, 0.78, 0.5][i])
                    .offset(x: CGFloat(i) * size * 0.2, y: -CGFloat(i) * size * 0.13)
            }
        }
        .frame(width: size * 1.4, height: size * 1.3, alignment: .bottomLeading)
    }
}

struct IconStack: View {
    let bundleIDs: [String]
    var size: CGFloat = 32

    var body: some View {
        HStack(spacing: -size * 0.35) {
            ForEach(Array(bundleIDs.prefix(3).enumerated()), id: \.offset) { _, id in AppIcon(bundleID: id, size: size) }
        }
    }
}
