import AppKit

/// A fixed-width menu bar graphic for the current window's remaining quota.
/// Values are supplied by Telemetry; missing or stale data never becomes fresh zero.
struct StatusQuotaIndicator {
    static let imageSize = NSSize(width: 56, height: 18)
    static let itemLength: CGFloat = 68
    let remaining: Double?
    var isStale = false

    var normalizedRemaining: Double? {
        remaining.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
    }
    var percentText: String { normalizedRemaining.map { "\(Int($0.rounded()))%" } ?? "—%" }
    var showsStaleMarker: Bool { isStale && normalizedRemaining != nil }

    func image(for button: NSStatusBarButton? = nil) -> NSImage {
        let image = NSImage(size: Self.imageSize, flipped: false) { [weak button] _ in
            let draw = { self.draw(highlighted: button?.cell?.isHighlighted ?? false) }
            if let appearance = button?.effectiveAppearance { appearance.performAsCurrentDrawingAppearance(draw) }
            else { draw() }
            return true
        }
        // Keep the quota-colored brand mark, and resolve adaptive text in the button's own
        // appearance each draw rather than caching one menu bar theme forever.
        image.isTemplate = false
        image.cacheMode = .never
        image.accessibilityDescription = "剩余用量 \(percentText)\(showsStaleMarker ? "，上次数据" : "")"
        return image
    }

    /// Blend through amber so both endpoints and intermediate quota states are meaningful.
    var usageColor: NSColor? {
        guard !isStale, let value = normalizedRemaining else { return nil }
        let red = (r: 1.0, g: 0.30, b: 0.28)
        let amber = (r: 1.0, g: 0.75, b: 0.25)
        let mint = (r: 0.32, g: 0.88, b: 0.56)
        let lower = value <= 50 ? red : amber
        let upper = value <= 50 ? amber : mint
        let t = value <= 50 ? value / 50 : (value - 50) / 50
        return NSColor(red: lower.r + (upper.r - lower.r) * t,
                       green: lower.g + (upper.g - lower.g) * t,
                       blue: lower.b + (upper.b - lower.b) * t, alpha: 1)
    }

    func draw(highlighted: Bool = false) {
        let foreground: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        let accent = usageColor ?? foreground.withAlphaComponent(0.5)
        drawBrandMark(foreground: foreground, accent: accent, highlighted: highlighted)
        let text = NSAttributedString(string: percentText, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: foreground
        ])
        let textBounds = NSRect(x: 17, y: 1, width: 35, height: 16)
        let size = text.size()
        text.draw(at: NSPoint(x: textBounds.midX - size.width / 2, y: textBounds.midY - size.height / 2))
        if showsStaleMarker {
            foreground.withAlphaComponent(0.6).setFill()
            NSBezierPath(ovalIn: NSRect(x: 53, y: 8, width: 2, height: 2)).fill()
        }
    }

    /// A small, tile-free version of the app logo. The opening and dot stay fixed;
    /// the 310-degree bowl is the meter and the right-hand stem makes it an a.
    private func drawBrandMark(foreground: NSColor, accent: NSColor, highlighted: Bool) {
        let center = NSPoint(x: 7, y: 8.8)
        let radius: CGFloat = 5.2
        let fresh = usageColor != nil
        let depleted = fresh && normalizedRemaining == 0
        let complete = fresh && normalizedRemaining == 100
        let bowl = NSBezierPath()
        bowl.appendArc(withCenter: center, radius: radius, startAngle: 75, endAngle: 385, clockwise: false)
        bowl.lineWidth = 1.9
        bowl.lineCapStyle = .round
        // An exhausted mark is red even though its positive-remaining arc is empty.
        (depleted ? accent : foreground.withAlphaComponent(highlighted ? 0.40 : 0.28)).setStroke()
        bowl.stroke()
        let stem = NSBezierPath(roundedRect: NSRect(x: 11.05, y: 2.65, width: 2.1, height: 8.5), xRadius: 0.4, yRadius: 0.4)
        (depleted || complete ? accent : fresh ? foreground : accent).setFill()
        stem.fill()
        if fresh, let value = normalizedRemaining, value > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius,
                          startAngle: 75, endAngle: 75 + 310 * value / 100, clockwise: false)
            arc.lineWidth = 1.9
            arc.lineCapStyle = .round
            accent.setStroke()
            arc.stroke()
        }
        accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: 9.49, y: 11.93, width: 1.7, height: 1.7)).fill()
    }

}

/// Observe the actual menu bar appearance without replacing its native button
/// or adding a hit target over the hover/click tracking area.
final class StatusQuotaAppearanceObserver: NSView {
    var onChange: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onChange?()
    }
}
