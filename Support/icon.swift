// Renders the app icon: white double arrow on black. Usage: swift icon.swift out.png
import AppKit

let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let size = CGFloat(px)
NSColor.black.setFill()
NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: size * 0.22, yRadius: size * 0.22).fill()

let config = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .bold).applying(.init(paletteColors: [.white]))
let arrow = NSImage(systemSymbolName: "arrow.left.and.right", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
arrow.draw(in: NSRect(x: (size - arrow.size.width) / 2, y: (size - arrow.size.height) / 2, width: arrow.size.width, height: arrow.size.height))

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
