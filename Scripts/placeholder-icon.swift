// Draws the temporary app icon: a black rounded square with a coral dot. Usage:
//   swift Scripts/placeholder-icon.swift design/icon/placeholder-1024.png
import AppKit

let path = CommandLine.arguments.dropFirst().first ?? "placeholder-1024.png"
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let inset: CGFloat = 100  // macOS icon grid: an 824 pt body inside 1024
let body = NSRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset)
NSColor.black.setFill()
NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).fill()
NSColor(red: 1.0, green: 0.47, blue: 0.40, alpha: 1).setFill()
let d: CGFloat = 170
NSBezierPath(ovalIn: NSRect(x: CGFloat(size) / 2 - d / 2, y: CGFloat(size) / 2 - d / 2, width: d, height: d)).fill()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
print("Wrote \(path)")
