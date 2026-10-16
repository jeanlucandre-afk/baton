import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// A picture of one window, for Jev to judge when the window's text can't be trusted (a blind reader).
/// Needs Screen Recording permission; everything here returns nil without it.
public enum WindowShot {
    /// Longest side of the image sent, in pixels. Enough to read a chat's last reply and its buttons,
    /// small enough to keep the upload quick and the token count low.
    public static let maxSide = 1280

    public static var permitted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; after that, only System Settings can change the answer.
    @discardableResult
    public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// The window as a JPEG, or nil (no permission, minimized, gone).
    public static func jpeg(_ win: AXWindow) async -> Data? {
        guard permitted, let image = await capture(pid: win.pid, title: win.title) else { return nil }
        return encode(image)
    }

    static func capture(pid: pid_t, title: String) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        let mine = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 200 && $0.frame.height > 150
        }
        // The window by title; else the app's biggest one (AX and window-server titles can differ).
        guard let w = mine.first(where: { $0.title == title }) ?? mine.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let cfg = SCStreamConfiguration()
        let scale = min(1, Double(maxSide) / max(w.frame.width, w.frame.height) / Double(filter.pointPixelScale))
        cfg.width = Int(w.frame.width * Double(filter.pointPixelScale) * scale)
        cfg.height = Int(w.frame.height * Double(filter.pointPixelScale) * scale)
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    static func encode(_ image: CGImage, quality: Double = 0.7) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
