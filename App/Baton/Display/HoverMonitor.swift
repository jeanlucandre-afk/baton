import AppKit

/// Watches the pointer and drives open/close: 50 ms of dwell over a notch opens it, 300 ms away closes it.
/// Also lets clicks pass through everywhere except the open card itself and the shelf.
///
/// It polls the pointer 20 times a second (cheap, needs no permission), but only while that can matter: a
/// card is open, or the pointer is around a notch or shelf. Otherwise the clock stops, and moving the mouse
/// (or the notch opening on its own, for a ping) starts it again. Away from the notches, resting, away from
/// the Mac, locked or asleep: no wakeups at all.
@MainActor
final class HoverMonitor {
    private unowned let manager: DisplayManager
    private var timer: Timer?
    private var monitors: [Any] = []
    /// When a mouse move last checked the pointer while the clock was stopped (moves come at up to 120 Hz).
    private var lastWake = Date.distantPast
    private var dwellStart: Date?
    private var dwellScreen: CGDirectDisplayID?
    private var awaySince: Date?
    private var keyedScreen: CGDirectDisplayID?   // the panel the new-task box last took the keyboard on
    private var lastMode: NotchMode = .collapsed
    /// When the list last opened: while it slides down, its frame isn't known yet (or is the last card's).
    private var openedAt: Date?
    private var lastTick: Date?

    /// How far around a notch and its shelf the pointer keeps the clock running.
    private static let margin: CGFloat = 140

    init(manager: DisplayManager) { self.manager = manager }

    func start() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        // Moves over other apps (global) and over Baton's own panels (local).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { _ in
            MainActor.assumeIsolated { DisplayManager.shared.hoverMoved() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { e in
            MainActor.assumeIsolated { DisplayManager.shared.hoverMoved() }
            return e
        }) { monitors.append(m) }
        watchModel()
        wake()
    }

    /// The pointer moved: while the clock is stopped, look at most 20 times a second whether it should run.
    func moved() {
        guard timer == nil else { return }
        let now = Date()
        guard now.timeIntervalSince(lastWake) >= 0.05 else { return }
        lastWake = now
        wake()
    }

    /// A card opening or closing, or you coming back, needs a look even if the pointer doesn't move.
    private func watchModel() {
        withObservationTracking {
            let m = AppModel.shared
            _ = m.mode; _ = m.notLooking; _ = m.renamingID; _ = m.picking
        } onChange: {
            Task { @MainActor in self.watchModel(); self.wake() }
        }
    }

    /// Checks the pointer now and keeps checking 20 times a second for as long as it matters.
    private func wake() {
        guard timer == nil else { return }
        tick()
        // No clock to run: forget this tick, or the next wake would log the whole quiet gap as a stall.
        guard timer == nil, needsClock() else { lastTick = nil; return }
        // Common modes: a plain timer stops while a mouse button is down or a menu is open, so a
        // hover then went unnoticed.
        let t = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { self.tickAndMaybeStop() }
        }
        // A little slack lets the system fold these wakeups in with others; 10 ms more never shows in a hover.
        t.tolerance = 0.01
        RunLoop.main.add(t, forMode: .common)
        timer = t
        lastTick = Date()
    }

    private func tickAndMaybeStop() {
        tick()
        if !needsClock() {
            timer?.invalidate()
            timer = nil
            lastTick = nil
        }
    }

    /// The clock matters while a card is open or taking the keyboard, a hover is being timed, or the pointer
    /// is around a notch or shelf, unless nobody is at the Mac (then moving the mouse wakes it again).
    private func needsClock() -> Bool {
        let model = AppModel.shared
        if model.mode != .collapsed || keyedScreen != nil || dwellStart != nil { return true }
        if model.notLooking { return false }
        let p = NSEvent.mouseLocation
        return manager.slots.keys.contains { id in
            let zones = [manager.hotZone(id), manager.shelfZone(id)].compactMap { $0 }
            return zones.contains { $0.insetBy(dx: -Self.margin, dy: -Self.margin).contains(p) }
        }
    }

    private func tick() {
        let model = AppModel.shared
        let p = NSEvent.mouseLocation
        let tickAt = Date()
        // The main thread was busy: hovers in that gap went unseen (see poll.log).
        if let last = lastTick, tickAt.timeIntervalSince(last) > 0.25 {
            DebugLog.log("hover: main thread stalled \(Int(tickAt.timeIntervalSince(last) * 1000))ms (mode \(model.mode))")
        }
        lastTick = tickAt
        let shelfOn = manager.showShelf
        // With the shelf on, the shelf is for clicking; only the notch itself (no wings) opens the full list.
        let over = manager.slots.keys.first { id in
            guard let zone = shelfOn ? manager.slots[id].map({ $0.geometry.rect.insetBy(dx: -8, dy: 0) }) : manager.hotZone(id) else { return false }
            // A pointer pushed to the top of the screen sits exactly on its top edge (y = maxY), which
            // CGRect.contains leaves out: with the shelf on, that's where you go to open the list.
            return p.x >= zone.minX && p.x <= zone.maxX && p.y >= zone.minY && p.y <= zone.maxY + 1
        }
        let onAnyShelf = manager.slots.keys.contains { manager.shelfZone($0)?.contains(p) == true }
        if model.pointerOnShelf != onAnyShelf { model.pointerOnShelf = onAnyShelf }
        // Coming up to the shelf (around it, or over the notch) sets the belt drifting to show what's on it.
        let near = onAnyShelf ? nil : manager.slots.keys.first { manager.shelfZone($0)?.insetBy(dx: -60, dy: -70).contains(p) == true }
        if model.pointerNearShelf != near { model.pointerNearShelf = near }

        // The open card's real frame, not the whole 960×600 panel: hovering and clicking count only there.
        // (SwiftUI's onHover can't tell us: the panel ignores the mouse until we know the pointer is on the card.)
        let content = model.mode == .collapsed ? nil : model.openScreen.flatMap { manager.contentRect($0) }
        // A few points of slack, so a quick move-and-click lands on the card rather than the app beneath it.
        let inContent = content?.insetBy(dx: -4, dy: -4).contains(p) == true
        if model.mode != .collapsed && model.hoveringContent != inContent { model.hoveringContent = inContent }

        if model.mode == .newTask && lastMode != .newTask { manager.rememberFrontApp() }
        if model.mode != lastMode {
            if lastMode == .collapsed { openedAt = Date() }
            if model.mode == .collapsed { manager.forgetContentFrames(); openedAt = nil }
        }
        lastMode = model.mode

        switch model.mode {
        case .collapsed:
            awaySince = nil
            if let over {
                if dwellScreen != over { dwellScreen = over; dwellStart = Date() }
                if let s = dwellStart, Date().timeIntervalSince(s) >= (shelfOn ? 0.2 : 0.05) {
                    model.expand(on: over)
                    dwellStart = nil
                }
            } else {
                dwellScreen = nil
                dwellStart = nil
            }
        case .expanded, .ping, .newChat:
            // Just opened: the card is still sliding down and its frame may not be known yet. Anywhere on
            // its panel counts, so moving down onto it doesn't close it.
            let opening = openedAt.map { Date().timeIntervalSince($0) < 0.6 } ?? false
                && model.openScreen.flatMap { manager.slots[$0]?.frame.contains(p) } == true
            let inside = inContent || opening || (over != nil && over == model.openScreen)
            if inside || model.renamingID != nil {
                // Renaming a big task: stays open until ⏎ or Esc, like the new-task box.
                awaySince = nil
            } else if model.mode == .expanded {
                if awaySince == nil { awaySince = Date() }
                if let a = awaySince, Date().timeIntervalSince(a) >= 0.3 { model.collapse(); awaySince = nil }
            } else if let deadline = model.cardDeadline, deadline <= Date() {
                // A ping or new-chat card whose time ran out while you rested on it: it closes once you leave.
                model.collapse()
            }
        case .newTask:
            awaySince = nil   // stays open until ⏎, Esc or Cancel
        }

        // Only the open card and the shelf take mouse events; everywhere else clicks reach the menus and apps below.
        for (id, slot) in manager.slots {
            let open = model.mode != .collapsed && model.openScreen == id
            let onShelf = manager.shelfZone(id)?.contains(p) == true
            let interactive = (open && inContent) || onShelf
            if slot.panel.ignoresMouseEvents == interactive { slot.panel.ignoresMouseEvents = !interactive }
        }

        // The new-task box takes the keyboard once as it opens (and again after picking a window), never on
        // every tick: clicking another app has to be able to take the keyboard away.
        let typing = (model.mode == .newTask && !model.picking) || (model.mode == .expanded && model.renamingID != nil)
        let wantsKey = typing ? model.openScreen : nil
        if wantsKey != keyedScreen {
            keyedScreen = wantsKey
            if let id = wantsKey, let panel = manager.slots[id]?.panel, !panel.isKeyWindow {
                panel.allowKey = true
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }
}
