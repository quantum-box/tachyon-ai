// Renders the app icon: `swift scripts/make-icon.swift <output.png>`.
// A placeholder design (the sparkles mark on the app's gradient) until real artwork exists.
import AppKit

let size = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"

// No alpha channel: App Store Connect rejects icons that have one.
let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

let colors = [
    CGColor(red: 0.36, green: 0.34, blue: 0.96, alpha: 1),
    CGColor(red: 0.62, green: 0.32, blue: 0.94, alpha: 1),
    CGColor(red: 0.93, green: 0.45, blue: 0.82, alpha: 1),
] as CFArray
let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 0.55, 1])!
context.drawLinearGradient(
    gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

let configuration = NSImage.SymbolConfiguration(pointSize: 520, weight: .medium)
    .applying(.init(paletteColors: [.white]))
let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)!
    .withSymbolConfiguration(configuration)!
let graphics = NSGraphicsContext(cgContext: context, flipped: false)
NSGraphicsContext.current = graphics
let symbolSize = symbol.size
symbol.draw(in: NSRect(
    x: (CGFloat(size) - symbolSize.width) / 2, y: (CGFloat(size) - symbolSize.height) / 2,
    width: symbolSize.width, height: symbolSize.height))
graphics.flushGraphics()

let destination = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: output) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(output)") }
print("wrote \(output)")
