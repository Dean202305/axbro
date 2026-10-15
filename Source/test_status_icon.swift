import AppKit

@main struct StatusQuotaIndicatorTests {
    static func main() throws {
        _ = NSApplication.shared
        var checks = 0
        func check(_ value: Bool, _ title: String) {
            precondition(value, title)
            checks += 1
        }
        let size = StatusQuotaIndicator.imageSize
        let scale: CGFloat = 4
        func raster(_ indicator: StatusQuotaIndicator, dark: Bool = true,
                    highlighted: Bool = false, image: NSImage? = nil) -> NSBitmapImageRep {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            graphics.cgContext.scaleBy(x: scale, y: scale)
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                if let image = image { image.draw(in: NSRect(origin: .zero, size: size)) }
                else { indicator.draw(highlighted: highlighted) }
            }
            NSGraphicsContext.restoreGraphicsState()
            return bitmap
        }
        func pixels(_ bitmap: NSBitmapImageRep, in rect: NSRect,
                    matching predicate: (NSColor) -> Bool) -> Int {
            var count = 0
            for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
                for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), predicate(color) { count += 1 }
                }
            }
            return count
        }
        let all = NSRect(origin: .zero, size: size)
        let ring = NSRect(x: 0, y: 1, width: 15, height: 16)
        let text = NSRect(x: 16, y: 0, width: 37, height: 18)
        let marker = NSRect(x: 53, y: 7, width: 3, height: 4)
        let red: (NSColor) -> Bool = { $0.alphaComponent > 0.5 && $0.redComponent > $0.greenComponent * 1.5 }
        let chromatic: (NSColor) -> Bool = { $0.alphaComponent > 0.5 && max($0.redComponent, $0.greenComponent, $0.blueComponent) - min($0.redComponent, $0.greenComponent, $0.blueComponent) > 0.25 }
        let amber: (NSColor) -> Bool = { $0.alphaComponent > 0.5 && $0.redComponent > 0.8 && $0.greenComponent > 0.6 && $0.blueComponent < 0.4 }
        let green: (NSColor) -> Bool = { $0.alphaComponent > 0.5 && $0.greenComponent > $0.redComponent * 1.5 }
        let visible: (NSColor) -> Bool = { $0.alphaComponent > 0.2 }
        let bright: (NSColor) -> Bool = { $0.alphaComponent > 0.5 && $0.redComponent > 0.7 && $0.greenComponent > 0.7 && $0.blueComponent > 0.7 }
        let dark: (NSColor) -> Bool = { $0.alphaComponent > 0.5 && $0.redComponent < 0.3 && $0.greenComponent < 0.3 && $0.blueComponent < 0.3 }

        let missing = StatusQuotaIndicator(remaining: nil)
        let zero = StatusQuotaIndicator(remaining: 0)
        check(missing.percentText == "—%" && missing.normalizedRemaining == nil,
              "Unavailable quota must remain unavailable")
        check(zero.percentText == "0%" && zero.normalizedRemaining == 0,
              "Real zero quota must remain distinguishable from unavailable data")
        for invalid in [Double.nan, .infinity, -.infinity] {
            let indicator = StatusQuotaIndicator(remaining: invalid, isStale: true)
            check(indicator.normalizedRemaining == nil && indicator.percentText == "—%" && !indicator.showsStaleMarker,
                  "Nonfinite quota must not produce a number or stale-data marker")
        }
        check(StatusQuotaIndicator(remaining: -12).normalizedRemaining == 0, "Negative quota clamps to zero")
        check(StatusQuotaIndicator(remaining: 112).normalizedRemaining == 100, "Oversized quota clamps to 100")
        check(StatusQuotaIndicator(remaining: 49.5).percentText == "50%", "Percentage uses consistent integer rounding")

        let full = raster(StatusQuotaIndicator(remaining: 100))
        let half = raster(StatusQuotaIndicator(remaining: 50))
        let low = raster(StatusQuotaIndicator(remaining: 4.9))
        let threshold = raster(StatusQuotaIndicator(remaining: 5))
        check(pixels(full, in: ring, matching: green) > 350, "100 percent has a green logo mark")
        check(pixels(full, in: ring, matching: chromatic) > pixels(half, in: ring, matching: chromatic) * 14 / 10,
              "Remaining quota controls the colored bowl arc")
        check(pixels(half, in: ring, matching: amber) > 100, "The midpoint transitions through amber")
        check(pixels(low, in: ring, matching: red) > 5 && pixels(low, in: ring, matching: green) == 0,
              "Very low quota has a red arc and logo dot")
        check(pixels(threshold, in: ring, matching: red) > 5 && pixels(threshold, in: ring, matching: green) == 0,
              "Five percent is near the red end of the continuous scale")
        check(pixels(raster(zero), in: ring, matching: green) == 0 && pixels(raster(zero), in: ring, matching: red) > 350,
              "A genuine zero remains visibly red instead of disappearing")
        let fullColor = StatusQuotaIndicator(remaining: 100).usageColor!
        let zeroColor = zero.usageColor!
        check(fullColor.greenComponent > fullColor.redComponent && zeroColor.redComponent > zeroColor.greenComponent,
              "The two endpoints correspond to green and red")
        check(StatusQuotaIndicator(remaining: nil).usageColor == nil && StatusQuotaIndicator(remaining: 100, isStale: true).usageColor == nil,
              "Unknown and stale data do not advertise a live quota color")
        var previous = zeroColor
        for value in stride(from: 5.0, through: 100.0, by: 5.0) {
            let color = StatusQuotaIndicator(remaining: value).usageColor!
            check(color.greenComponent >= previous.greenComponent && color.redComponent <= previous.redComponent &&
                  abs(color.redComponent - previous.redComponent) < 0.08 && abs(color.greenComponent - previous.greenComponent) < 0.06,
                  "Quota colors change continuously without threshold jumps")
            previous = color
        }
        check(pixels(full, in: NSRect(x: 11.2, y: 12, width: 1.7, height: 3), matching: green) > 40,
              "The brand a retains its upright stem at menu bar scale")
        check(pixels(raster(missing), in: ring, matching: green) == 0, "Unavailable quota has no fresh green arc")

        let stale = StatusQuotaIndicator(remaining: 50, isStale: true)
        let staleRaster = raster(stale)
        check(stale.showsStaleMarker && stale.percentText == "50%", "Stale quota retains its last number and identifies freshness")
        check(pixels(staleRaster, in: ring, matching: green) == 0 && pixels(staleRaster, in: ring, matching: red) == 0,
              "Stale data uses a neutral ring rather than a current-quota color")
        check(pixels(staleRaster, in: marker, matching: visible) > 15 && pixels(half, in: marker, matching: visible) == 0,
              "Only stale numeric data shows the small marker")

        for value: Double? in [nil, 0, 1, 5, 16, 58, 99, 100] {
            let indicator = StatusQuotaIndicator(remaining: value)
            let image = indicator.image()
            check(image.size == size && !image.isTemplate && image.cacheMode == .never,
                  "Every state retains fixed image geometry and live appearance rendering")
            for isDark in [false, true] {
                let bitmap = raster(indicator, dark: isDark, image: image)
                check(pixels(bitmap, in: text, matching: isDark ? bright : dark) > 100,
                      "Percentage text remains legible in both menu bar appearances")
                check(pixels(bitmap, in: NSRect(x: 0, y: 0, width: 56, height: 1), matching: visible) == 0 &&
                      pixels(bitmap, in: NSRect(x: 0, y: 17, width: 56, height: 1), matching: visible) == 0,
                      "Text and arc retain vertical padding without clipping")
            }
        }
        check(StatusQuotaIndicator.itemLength >= size.width + 8, "Native status item retains horizontal click-target padding")
        let adaptive = StatusQuotaIndicator(remaining: 58).image()
        check(pixels(raster(StatusQuotaIndicator(remaining: 58), dark: true, image: adaptive), in: text, matching: bright) > 100 &&
              pixels(raster(StatusQuotaIndicator(remaining: 58), dark: false, image: adaptive), in: text, matching: dark) > 100,
              "The same image redraws text after an appearance change")
        for isDark in [false, true] {
            let pressed = raster(StatusQuotaIndicator(remaining: 58), dark: isDark, highlighted: true)
            check(pixels(pressed, in: text, matching: bright) > 100,
                  "Pressed menu bar item uses selected text color")
            check(pixels(pressed, in: all, matching: visible) > 200,
                  "Pressed item keeps both text and ring visible")
        }

        if CommandLine.arguments.count > 1 {
            let destination = URL(fileURLWithPath: CommandLine.arguments[1])
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let states: [(String, Double?, Bool)] = [
                ("100%", 100, false), ("50%", 50, false), ("5%", 5, false),
                ("<5%", 4, false), ("0%", 0, false), ("Unknown", nil, false), ("Stale", 58, true)
            ]
            let sheetSize = NSSize(width: 620, height: 210)
            let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(sheetSize.width * 2),
                pixelsHigh: Int(sheetSize.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)!
            NSGraphicsContext.current!.cgContext.scaleBy(x: 2, y: 2)
            for row in 0..<3 {
                let y = CGFloat(row) * 70
                let isDark = row != 1
                let pressed = row == 2
                let background = pressed ? NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.80, alpha: 1) :
                    (isDark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.94, alpha: 1))
                background.setFill()
                NSBezierPath(rect: NSRect(x: 0, y: y, width: sheetSize.width, height: 70)).fill()
                let labelColor: NSColor = isDark ? .white : .black
                let title = pressed ? "Pressed" : (isDark ? "Dark" : "Light")
                NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                               .foregroundColor: labelColor]).draw(at: NSPoint(x: 14, y: y + 29))
                for (column, state) in states.enumerated() {
                    let x = 90 + CGFloat(column) * 74
                    let icon = raster(StatusQuotaIndicator(remaining: state.1, isStale: state.2), dark: isDark, highlighted: pressed)
                    NSImage(cgImage: icon.cgImage!, size: size).draw(in: NSRect(x: x, y: y + 34, width: 56, height: 18))
                    NSAttributedString(string: state.0, attributes: [.font: NSFont.systemFont(ofSize: 9),
                                                                    .foregroundColor: labelColor.withAlphaComponent(0.7)]).draw(at: NSPoint(x: x, y: y + 14))
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            try sheet.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("states.png"))
        }
        print("Passed \(checks) status icon value, rendering, appearance, stale-data and fixed-size checks")
    }
}
