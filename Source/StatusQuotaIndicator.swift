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
        // Keep the green/red ring, and resolve adaptive text in the button's own
        // appearance each draw rather than caching one menu bar theme forever.
        image.isTemplate = false
        image.cacheMode = .never
        image.accessibilityDescription = "剩余用量 \(percentText)\(showsStaleMarker ? "，上次数据" : "")"
        return image
    }

    func draw(highlighted: Bool = false) {
        let foreground: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        let accent: NSColor
        if isStale || normalizedRemaining == nil { accent = foreground.withAlphaComponent(0.5) }
        else if (normalizedRemaining ?? 100) < 5 { accent = NSColor(red: 1, green: 0.35, blue: 0.32, alpha: 1) }
        else { accent = NSColor(red: 0.32, green: 0.88, blue: 0.48, alpha: 1) }

        let ring = NSBezierPath(ovalIn: NSRect(x: 1, y: 3, width: 12, height: 12))
        foreground.withAlphaComponent(highlighted ? 0.35 : 0.22).setStroke()
        ring.lineWidth = 1.7
        ring.stroke()
        if let remaining = normalizedRemaining, remaining > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 7, y: 9), radius: 6,
                          startAngle: 90, endAngle: 90 - 360 * remaining / 100, clockwise: true)
            arc.lineWidth = 1.7
            arc.lineCapStyle = .round
            accent.setStroke()
            arc.stroke()
        }
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
