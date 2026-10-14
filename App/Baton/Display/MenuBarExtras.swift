import AppKit
import ApplicationServices
import BatonCore

/// Where the menu bar's own items start, right of the notch. Since macOS 27, when the menu bar is crowded
/// it tucks extras behind the notch and puts a "«" button just right of it to show them. The collapsed notch's
/// right wing must not cover that button (or any item), so it steps aside when there isn't room.
///
/// Read through Accessibility from MenuBarAgent, which draws the extras. No clock: it looks again only
/// when the extras can move: an app launching, quitting or coming to the front (its menus can push items
/// behind the notch), or the screens changing.
@MainActor @Observable
final class MenuBarExtras {
    static let shared = MenuBarExtras()

    /// The menu bar items' frames, in global screen coordinates (origin bottom-left, like NSScreen.frame).
    private(set) var items: [CGRect] = []
    /// The "show hidden items" button, if the menu bar has one right now.
    private(set) var overflow: CGRect?

    @ObservationIgnored private var pending: Task<Void, Never>?

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.screensDidWakeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MenuBarExtras.shared.scheduleRefresh() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuBarExtras.shared.scheduleRefresh() }
        }
        refresh()
    }

    /// The menu bar lays itself out again a moment after the change: look once it has settled.
    func scheduleRefresh() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    func refresh() {
        guard AXIsProcessTrusted(),
              let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first,
              let primary = NSScreen.screens.first else {
            set([], nil)
            return
        }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        // On the main thread: a hung MenuBarAgent mustn't stall the notch for the system's 6 s.
        AXUIElementSetMessagingTimeout(app, AX.messagingTimeout)
        var found = Self.children(of: app)
        if let bar = AX.element(Self.attribute(app, "AXExtrasMenuBar")) { found += Self.children(of: bar) }
        var frames: [CGRect] = []
        var button: CGRect?
        for e in found {
            guard let f = AX.frame(of: e), f.width > 0, f.height <= 40,
                  f.minX.isFinite, f.minY.isFinite, f.width.isFinite else { continue }
            // AX frames are top-left based on the primary screen; flip them to AppKit's bottom-left.
            let r = CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
            frames.append(r)
            // The other extras are groups; the one button among them is the one that shows the hidden ones.
            if Self.attribute(e, kAXRoleAttribute) as? String == kAXButtonRole { button = r }
        }
        set(frames, button)
    }

    /// True when the right wing fits between the notch and the first menu bar item.
    func rightWingFits(_ g: NotchGeometry) -> Bool {
        guard g.kind == .hardware else { return true }   // without a camera notch, the bar's middle stays empty
        let reach = g.rect.maxX + CollapsedNotch.rightReach + 4
        let row = g.rect.minY - 2...g.rect.maxY + 2
        func onThisBar(_ r: CGRect) -> Bool { row.contains(r.midY) && r.maxX > g.rect.maxX }
        if let b = overflow, onThisBar(b) { return b.minX >= reach }
        return !items.contains { onThisBar($0) && $0.minX < reach }
    }

    private func set(_ frames: [CGRect], _ button: CGRect?) {
        if frames != items { items = frames }
        if button != overflow { overflow = button }
    }

    private static func attribute(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private static func children(of e: AXUIElement) -> [AXUIElement] {
        // The app element's timeout doesn't carry over to its children.
        let kids = (attribute(e, kAXChildrenAttribute) as? [AnyObject] ?? []).compactMap { AX.element($0) }
        for k in kids { AXUIElementSetMessagingTimeout(k, AX.messagingTimeout) }
        return kids
    }
}
