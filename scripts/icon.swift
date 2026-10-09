import AppKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let n = CGFloat(pixels)
        let box = NSRect(x: n * 0.06, y: n * 0.06, width: n * 0.88, height: n * 0.88)
        let shape = NSBezierPath(roundedRect: box, xRadius: n * 0.2, yRadius: n * 0.2)
        NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.52, blue: 0.8, alpha: 1),
                   ending: NSColor(calibratedRed: 0.2, green: 0.24, blue: 0.66, alpha: 1))!.draw(in: shape, angle: -45)
        NSColor.white.setFill()
        let heights: [CGFloat] = [0.16, 0.32, 0.52, 0.72, 0.45, 0.27, 0.14]
        for (i, height) in heights.enumerated() {
            let rect = NSRect(x: n * (0.235 + CGFloat(i) * 0.078), y: n * (0.5 - height / 2), width: n * 0.045, height: n * height)
            NSBezierPath(roundedRect: rect, xRadius: n * 0.0225, yRadius: n * 0.0225).fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
