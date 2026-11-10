// Draws the RouterBar app icon (1024x1024 PNG). Usage: swift make-icon.swift out.png
import AppKit

let size = 1024.0
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// macOS-style rounded square with a blue gradient.
let inset = size * 0.1
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.45, blue: 0.98, alpha: 1),
                    NSColor(calibratedRed: 0.05, green: 0.22, blue: 0.62, alpha: 1)])!
    .draw(in: path, angle: -90)

// White router symbol.
let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .medium)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "wifi.router.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = sym.size
    sym.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 - size * 0.02,
                        width: s.width, height: s.height))
}
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
