import AppKit
import BatonCore
import Defaults
import SwiftUI

extension NSScreen {
    var displayID: CGDirectDisplayID { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0 }
    var isBuiltIn: Bool { CGDisplayIsBuiltin(displayID) != 0 }

    var notchGeometry: NotchGeometry {
        NotchGeometry.make(frame: frame, visibleFrame: visibleFrame, safeAreaTop: safeAreaInsets.top,
                           auxLeft: auxiliaryTopLeftArea, auxRight: auxiliaryTopRightArea, scale: backingScaleFactor)
    }
}

/// One notch panel per eligible screen. Panels never move between screens; only one is open at a time.
@MainActor
final class DisplayManager {
    static let shared = DisplayManager()
    /// The panel's width; its height follows the screen (see `panelFrame`), so a long list fits.
    static let panelSize = CGSize(width: 960, height: 600)
    static let maxPanelHeight: CGFloat = 900
    static let wing: CGFloat = 96   // collapsed content width on each side of the notch

    struct Slot {
        let panel: NotchPanel
        var geometry: NotchGeometry
        var frame: CGRect
    }

    private(set) var slots: [CGDirectDisplayID: Slot] = [:]
    private var debounce: Task<Void, Never>?
    private var hover: HoverMonitor?
    /// Where each open panel's card or list actually is, in panel (top-left) coordinates. Only there does the
    /// panel take clicks; the transparent rest lets them through to the apps below.
    private var contentFrames: [CGDirectDisplayID: CGRect] = [:]
    /// The app you were in when the new-task box took the keyboard, so it gets it back when the box closes.
    private var previousApp: NSRunningApplication?

    /// Settings the hover monitor needs 20 times a second, cached and refreshed when they change.
    private(set) var showShelf = Defaults[.showShelf]
    private(set) var theme = Defaults[.theme]
    private var watchers: [Task<Void, Never>] = []

    func start() {
        watchers = [
            Task { for await v in Defaults.updates(.showShelf) { self.showShelf = v } },
            Task { for await v in Defaults.updates(.theme) { self.theme = v } },
        ]
        rebuild()
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DisplayManager.shared.scheduleRebuild() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DisplayManager.shared.scheduleRebuild() }
        }
        hover = HoverMonitor(manager: self)
        hover?.start()
    }

    /// The pointer moved (from the hover monitor's event monitors).
    func hoverMoved() { hover?.moved() }

    func scheduleRebuild() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            rebuild()
        }
    }

    func eligibleScreens() -> [NSScreen] {
        let all = NSScreen.screens
        switch Defaults[.showOn] {
        case .all: return all
        case .main: return Array(all.prefix(1))   // the menu-bar display, never NSScreen.main (that follows focus)
        case .builtIn:
            let b = all.filter(\.isBuiltIn)
            return b.isEmpty ? Array(all.prefix(1)) : b   // lid closed: fall back to the main display
        }
    }

    /// Adds, removes or moves only the screens that changed, so nothing flickers.
    func rebuild() {
        let screens = eligibleScreens()
        let ids = Set(screens.map(\.displayID))
        for (id, slot) in slots where !ids.contains(id) {
            slot.panel.orderOut(nil)
            slot.panel.close()
            slots[id] = nil
            contentFrames[id] = nil
        }
        for s in screens {
            let g = s.notchGeometry
            let frame = Self.panelFrame(for: g, screen: s.frame)
            if var slot = slots[s.displayID] {
                if slot.geometry != g || slot.frame != frame {
                    slot.geometry = g
                    slot.frame = frame
                    slot.panel.setFrame(frame, display: true)
                    slot.panel.update(geometry: g)
                    slots[s.displayID] = slot
                }
            } else {
                let p = NotchPanel(frame: frame, displayID: s.displayID, geometry: g)
                p.orderFrontRegardless()
                slots[s.displayID] = Slot(panel: p, geometry: g, frame: frame)
            }
        }
        // The open display went away (unplugged, or no longer shown): close instead of staying open where nobody sees it.
        let model = AppModel.shared
        if model.mode != .collapsed, model.openScreen.map({ slots[$0] == nil }) ?? true { model.collapse() }
    }

    static func panelFrame(for g: NotchGeometry, screen: CGRect) -> CGRect {
        // As tall as the screen allows (it's transparent and lets clicks through outside the open card).
        let w = panelSize.width, h = max(panelSize.height, min(maxPanelHeight, screen.height - 40))
        let x = min(max(g.rect.midX - w / 2, screen.minX), screen.maxX - w)
        return CGRect(x: x.rounded(), y: screen.maxY - h, width: w, height: h)
    }

    /// The collapsed notch plus its wings, in global coordinates: where hovering opens it.
    func hotZone(_ id: CGDirectDisplayID) -> CGRect? {
        guard let g = slots[id]?.geometry else { return nil }
        let r = g.rect.insetBy(dx: -Self.wing, dy: 0)
        return CGRect(x: r.minX, y: r.minY - 4, width: r.width, height: r.height + 4)
    }

    /// The always-on shelf under the notch, where clicks must reach Baton without opening the list.
    func shelfZone(_ id: CGDirectDisplayID) -> CGRect? {
        guard showShelf, let g = slots[id]?.geometry, g.kind != .lip else { return nil }
        // Only the shelf strip itself, below the menu bar: the menu bar beside the notch (battery, Wi-Fi,
        // menu extras) must stay clickable. The glass shelf floats 6 pt lower than the black one.
        let gap: CGFloat = theme == .glass ? 6 : 0
        let top = g.rect.minY - gap
        return CGRect(x: g.rect.midX - ShelfView.width / 2 + 10, y: top - ShelfView.rowHeight + 4,
                      width: ShelfView.width - 20, height: ShelfView.rowHeight - 4)
    }

    /// The display under the pointer if Baton shows there, else the first one it shows on: a ping or the new-task
    /// box must never open on a screen without a panel, where nobody would see it.
    func screenUnderPointer() -> CGDirectDisplayID? {
        let p = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }), slots[s.displayID] != nil { return s.displayID }
        return NSScreen.screens.lazy.map(\.displayID).first { self.slots[$0] != nil } ?? slots.keys.first
    }

    /// How tall the open list may get on the open screen, so its bottom never runs past the panel.
    func openHeight() -> CGFloat {
        let id = AppModel.shared.openScreen
        return id.flatMap { slots[$0]?.frame.height } ?? Self.panelSize.height
    }

    /// The open card's frame as laid out by SwiftUI, in the panel's own (top-left) coordinates.
    func setContentFrame(_ r: CGRect, on id: CGDirectDisplayID) { contentFrames[id] = r }

    /// The card closed: its frame mustn't stand in for the next card's while that one is still laying out.
    func forgetContentFrames() { contentFrames.removeAll() }

    /// The open card or list in global screen coordinates, if the panel on `id` has laid one out.
    func contentRect(_ id: CGDirectDisplayID) -> CGRect? {
        guard let r = contentFrames[id], let f = slots[id]?.frame else { return nil }
        return CGRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// The new-task box is about to take the keyboard: remember who had it.
    func rememberFrontApp() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
    }

    /// Really gives the keyboard back: resignKey() alone leaves the invisible panel key and swallowing typing.
    /// Ordering it out drops key status; ordering it straight back keeps the notch drawn.
    func resignKey() {
        for s in slots.values where s.panel.isKeyWindow {
            s.panel.allowKey = false
            s.panel.orderOut(nil)
            s.panel.orderFrontRegardless()
        }
        for s in slots.values { s.panel.allowKey = false }
        if NSApp.isActive, let app = previousApp, !app.isTerminated { app.activate() }
        previousApp = nil
    }
}
