import AppKit
import BatonCore
import SwiftUI

/// Borderless, non-activating, on every Space, above the menu bar. Takes keyboard focus only for the new-task box.
final class NotchPanel: NSPanel {
    let displayID: CGDirectDisplayID
    var allowKey = false
    private let host: NSHostingView<NotchRootView>

    init(frame: CGRect, displayID: CGDirectDisplayID, geometry: NotchGeometry) {
        self.displayID = displayID
        host = NSHostingView(rootView: NotchRootView(displayID: displayID, geometry: geometry, panelFrame: frame))
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        isMovable = false
        ignoresMouseEvents = true
        host.sizingOptions = []
        contentView = host
    }

    func update(geometry: NotchGeometry) {
        host.rootView = NotchRootView(displayID: displayID, geometry: geometry, panelFrame: frame)
    }

    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
}
