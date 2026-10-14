import Foundation
import CoreGraphics

struct FloatingPlacement: Codable {
    var x: Double
    var top: Double

    func origin(size: CGSize, screens: [CGRect]) -> CGPoint? {
        guard x.isFinite, top.isFinite, let fallback = screens.first else { return nil }
        let target = CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
        let screen = screens.first { $0.contains(CGPoint(x: target.midX, y: target.midY)) } ?? fallback
        return CGPoint(x: max(screen.minX, min(x, screen.maxX - size.width)),
                       y: max(screen.minY, min(top - size.height, screen.maxY - size.height)))
    }
}
