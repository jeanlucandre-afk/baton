import AppKit
import SwiftUI

/// AppKit's Liquid Glass view. Unlike SwiftUI's glassEffect inside a floating panel, it refracts and blurs
/// the windows behind Baton, not just Baton's own content.
struct SystemGlass: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let v = NSGlassEffectView()
        v.cornerRadius = cornerRadius
        v.tintColor = NSColor.black.withAlphaComponent(0.08)
        return v
    }

    func updateNSView(_ v: NSGlassEffectView, context: Context) {
        v.cornerRadius = cornerRadius
    }
}
