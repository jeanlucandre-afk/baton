import AppKit
import BatonCore

/// "Pick a window": dims every screen except the window under the pointer, which gets a gold frame and its
/// name. One click attaches it, Esc cancels. Works for any visible window, including ones the chip list
/// doesn't show yet.
@MainActor
enum WindowPicker {
    /// A window as the window server lists it, front to back.
    struct Candidate: Equatable {
        let pid: pid_t
        let windowID: CGWindowID
        let frame: CGRect          // global, top-left origin (Quartz)
        let appName: String
        let title: String
    }

    private static var overlays: [PickerPanel] = []
    private static var candidates: [Candidate] = []
    private static var done: ((AXWindow?) -> Void)?
    static private(set) var hovered: Candidate?

    static func pick(_ completion: @escaping (AXWindow?) -> Void) {
        guard overlays.isEmpty else { return }
        done = completion
        candidates = listCandidates()
        AppModel.shared.picking = true
        for s in NSScreen.screens {
            let panel = PickerPanel(screen: s)
            panel.orderFrontRegardless()
            overlays.append(panel)
        }
        NSApp.activate()
        overlays.first(where: { $0.screen == NSScreen.main })?.makeKey() ?? overlays.first?.makeKey()
        update(at: NSEvent.mouseLocation)
    }

    /// Pointer moved: find the frontmost window under it and redraw.
    static func update(at p: NSPoint) {
        let q = quartz(p)
        let hit = candidates.first { $0.frame.contains(q) }
        guard hit != hovered else { return }
        hovered = hit
        overlays.forEach { $0.contentView?.needsDisplay = true }
    }

    static func click(at p: NSPoint) {
        update(at: p)
        let pickedWindow = hovered.flatMap(axWindow(for:))
        finish(pickedWindow)
    }

    static func cancel() { finish(nil) }

    private static func finish(_ w: AXWindow?) {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        hovered = nil
        AppModel.shared.picking = false
        let d = done
        done = nil
        d?(w)
    }

    // MARK: Window lookup

    private static func listCandidates() -> [Candidate] {
        let own = ProcessInfo.processInfo.processIdentifier
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let b = d[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"], w > 80, h > 60 else { return nil }
            return Candidate(pid: pid, windowID: id, frame: CGRect(x: x, y: y, width: w, height: h),
                             appName: d[kCGWindowOwnerName as String] as? String ?? "",
                             title: d[kCGWindowName as String] as? String ?? "")
        }
    }

    /// The Accessibility window for a picked window: same app, closest frame.
    private static func axWindow(for c: Candidate) -> AXWindow? {
        AX.enableTree(pid: c.pid)
        let wins = AX.windows(pid: c.pid)
        func distance(_ w: AXWindow) -> CGFloat {
            guard let f = frame(of: w.element) else { return .infinity }
            return abs(f.minX - c.frame.minX) + abs(f.minY - c.frame.minY) + abs(f.width - c.frame.width) + abs(f.height - c.frame.height)
        }
        return wins.min { distance($0) < distance($1) }
    }

    private static func frame(of el: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// AppKit (bottom-left origin) → Quartz (top-left origin of the primary screen).
    static func quartz(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - p.y)
    }

    static func appKit(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - r.maxY, width: r.width, height: r.height)
    }

    // MARK: Overlay

    final class PickerPanel: NSPanel {
        init(screen: NSScreen) {
            super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            isOpaque = false
            backgroundColor = .clear
            level = .screenSaver
            hasShadow = false
            ignoresMouseEvents = false
            acceptsMouseMovedEvents = true
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            setFrame(screen.frame, display: false)
            contentView = PickerView(frame: CGRect(origin: .zero, size: screen.frame.size))
        }
        override var canBecomeKey: Bool { true }
    }

    final class PickerView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
        }
        required init?(coder: NSCoder) { fatalError() }

        // The click that picks must count even though Baton wasn't the active app.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }

        override func mouseMoved(with event: NSEvent) { WindowPicker.update(at: NSEvent.mouseLocation) }
        override func mouseDown(with event: NSEvent) { WindowPicker.click(at: NSEvent.mouseLocation) }
        override func rightMouseDown(with event: NSEvent) { WindowPicker.cancel() }
        override func keyDown(with event: NSEvent) { if event.keyCode == 53 { WindowPicker.cancel() } }
        override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

        override func draw(_ dirtyRect: NSRect) {
            guard let win = window else { return }
            let screenOrigin = win.frame.origin
            // Hovered window in this view's coordinates.
            let hole = WindowPicker.hovered.map { c -> CGRect in
                let r = WindowPicker.appKit(c.frame)
                return r.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
            }

            // Dim everything except the hovered window.
            let dim = NSBezierPath(rect: bounds)
            if let hole { dim.append(NSBezierPath(roundedRect: hole, xRadius: 10, yRadius: 10)); dim.windingRule = .evenOdd }
            NSColor.black.withAlphaComponent(0.35).setFill()
            dim.fill()

            let gold = NSColor(red: 0.94, green: 0.76, blue: 0.42, alpha: 1)
            if let hole, let c = WindowPicker.hovered, hole.intersects(bounds) {
                let ring = NSBezierPath(roundedRect: hole.insetBy(dx: -1.5, dy: -1.5), xRadius: 11, yRadius: 11)
                ring.lineWidth = 3
                gold.setStroke()
                ring.stroke()
                let name = c.title.isEmpty ? c.appName : "\(c.appName) — \(c.title)"
                pill("\(name)   ·   click to attach", at: CGPoint(x: hole.midX, y: min(hole.maxY - 28, bounds.maxY - 60)), fill: gold, text: .black)
            }
            pill("Click a window to attach it  ·  esc to cancel", at: CGPoint(x: bounds.midX, y: 48),
                 fill: NSColor.black.withAlphaComponent(0.8), text: .white)
        }

        private func pill(_ s: String, at center: CGPoint, fill: NSColor, text: NSColor) {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: text]
            let str = NSAttributedString(string: s, attributes: attrs)
            let size = str.size()
            let w = min(size.width + 28, bounds.width - 40)
            let r = CGRect(x: center.x - w / 2, y: center.y - 15, width: w, height: 30)
            fill.setFill()
            NSBezierPath(roundedRect: r, xRadius: 15, yRadius: 15).fill()
            str.draw(with: CGRect(x: r.minX + 14, y: r.minY + (30 - size.height) / 2, width: w - 28, height: size.height),
                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}
