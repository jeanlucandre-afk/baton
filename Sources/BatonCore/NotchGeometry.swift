import CoreGraphics

/// Where the notch sits on a screen. Pure function of the screen's numbers so it can be unit-tested
/// for every display arrangement (built-in with notch, external without, stacked, negative x, auto-hide).
public struct NotchGeometry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case hardware, virtual, lip }

    public let kind: Kind
    /// The collapsed notch in global screen coordinates (origin bottom-left, like NSScreen.frame).
    public let rect: CGRect

    public static let virtualWidth: CGFloat = 185
    public static let lipHeight: CGFloat = 5

    public static func make(frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat,
                            auxLeft: CGRect?, auxRight: CGRect?, scale: CGFloat) -> NotchGeometry {
        func align(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

        if let l = auxLeft, let r = auxRight, safeAreaTop > 0 {
            let width = frame.width - l.width - r.width
            let x = frame.minX + l.width
            return NotchGeometry(kind: .hardware, rect: CGRect(x: align(x), y: align(frame.maxY - safeAreaTop),
                                                               width: align(width), height: align(safeAreaTop)))
        }
        let menuBar = frame.maxY - visibleFrame.maxY
        let x = frame.midX - virtualWidth / 2
        if menuBar >= 10 {
            return NotchGeometry(kind: .virtual, rect: CGRect(x: align(x), y: align(frame.maxY - menuBar),
                                                              width: virtualWidth, height: align(menuBar)))
        }
        // No menu bar on this screen (auto-hide, or shared Spaces): a thin sliver that opens on hover.
        return NotchGeometry(kind: .lip, rect: CGRect(x: align(x), y: frame.maxY - lipHeight,
                                                      width: virtualWidth, height: lipHeight))
    }
}
