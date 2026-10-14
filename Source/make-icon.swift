import AppKit
let directory = CommandLine.arguments[1]
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = CGFloat(size)
    let background = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s), xRadius: s * 0.22, yRadius: s * 0.22)
    NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.23, alpha: 1).setFill()
    background.fill()
    NSColor.white.setStroke()
    let box = NSBezierPath(roundedRect: NSRect(x: s * 0.19, y: s * 0.25, width: s * 0.62, height: s * 0.5), xRadius: s * 0.06, yRadius: s * 0.06)
    box.lineWidth = max(1, s * 0.04)
    box.stroke()
    let prompt = NSBezierPath()
    prompt.move(to: NSPoint(x: s * 0.30, y: s * 0.60))
    prompt.line(to: NSPoint(x: s * 0.42, y: s * 0.50))
    prompt.line(to: NSPoint(x: s * 0.30, y: s * 0.40))
    prompt.move(to: NSPoint(x: s * 0.49, y: s * 0.40))
    prompt.line(to: NSPoint(x: s * 0.66, y: s * 0.40))
    prompt.lineWidth = max(1, s * 0.04)
    prompt.lineCapStyle = .round
    prompt.lineJoinStyle = .round
    prompt.stroke()
    image.unlockFocus()
    if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) {
        try data.write(to: URL(fileURLWithPath: directory + "/\(size).png"))
    }
}
