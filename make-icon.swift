import AppKit

let size: CGFloat = 1024
let inset: CGFloat = 100
let plate = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let ctx = NSGraphicsContext.current!.cgContext
ctx.setShouldAntialias(true)

// Apple's icon grid: the artwork sits inside a squircle, not the full canvas.
let body = NSBezierPath(roundedRect: plate, xRadius: plate.width * 0.2237, yRadius: plate.width * 0.2237)
body.addClip()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.30, alpha: 1),
    NSColor(calibratedRed: 0.27, green: 0.20, blue: 0.52, alpha: 1),
    NSColor(calibratedRed: 0.13, green: 0.44, blue: 0.55, alpha: 1),
])!
gradient.draw(in: plate, angle: -60)

let config = NSImage.SymbolConfiguration(pointSize: plate.width * 0.46, weight: .regular)
if let glyph = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let tinted = NSImage(size: glyph.size)
    tinted.lockFocus()
    NSColor.white.set()
    NSRect(origin: .zero, size: glyph.size).fill(using: .sourceOver)
    glyph.draw(at: .zero, from: NSRect(origin: .zero, size: glyph.size),
               operation: .destinationIn, fraction: 1)
    tinted.unlockFocus()

    let target = NSRect(x: plate.midX - glyph.size.width / 2,
                        y: plate.midY - glyph.size.height / 2,
                        width: glyph.size.width,
                        height: glyph.size.height)
    tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: 0.95)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("не удалось отрендерить иконку")
}
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("icon written to \(CommandLine.arguments[1])")
