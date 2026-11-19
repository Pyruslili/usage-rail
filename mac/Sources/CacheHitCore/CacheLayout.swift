import Foundation

public struct CacheFrame: Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public func contains(_ px: Double, _ py: Double) -> Bool {
        px >= minX && px < maxX && py >= minY && py < maxY
    }

    public func intersects(_ other: CacheFrame) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }

    public func inset(by pad: Double) -> CacheFrame {
        CacheFrame(x: x - pad, y: y - pad, width: width + pad * 2, height: height + pad * 2)
    }

    public func union(_ other: CacheFrame) -> CacheFrame {
        let left = min(minX, other.minX)
        let bottom = min(minY, other.minY)
        let right = max(maxX, other.maxX)
        let top = max(maxY, other.maxY)
        return CacheFrame(x: left, y: bottom, width: right - left, height: top - bottom)
    }
}

/// Placement for the cache drawer. Coordinates are AppKit-style: y grows upward.
/// The drawer is glued to the screen's right edge and sits below the live rail frame.
public enum CacheLayout {
    public static let collapsedWidth: Double = 8
    public static let expandedWidth: Double = 308
    public static let collapsedHeight: Double = 56
    public static let expandedHeight: Double = 380
    public static let minimumExpandedHeight: Double = 120
    /// Audited rail geometry. The rail's own hover code is not edited.
    public static let railHeight: Double = 420
    public static let railExpandedWidth: Double = 50
    public static let railTopInset: Double = 72
    public static let slotCount: Double = 6
    public static let railHoverOutsetX: Double = 16
    public static let railHoverOutsetY: Double = 24
    public static let cardWidth: Double = 240
    public static let cardHeight: Double = 200
    public static let cardGap: Double = 6
    public static let cardHoverPad: Double = 8
    /// Clear gap after the lower of the rail pad and the bottom usage card.
    public static let visualGap: Double = 8
    public static let hotPadLeft: Double = 16
    public static let hotPadRight: Double = 10
    public static let hotPadUp: Double = 4
    public static let hotPadDown: Double = 24

    /// How far the bottom usage card extends below the rail, before its hover pad.
    public static var bottomCardDrop: Double {
        (cardHeight - railHeight / slotCount) / 2
    }

    /// Distance from the rail's bottom edge down to the drawer's top edge.
    public static var reservedBelowRail: Double {
        max(railHoverOutsetY, bottomCardDrop + cardHoverPad) + visualGap
    }

    public static func railHotZone(rail: CacheFrame) -> CacheFrame {
        CacheFrame(
            x: rail.minX - railHoverOutsetX,
            y: rail.minY - railHoverOutsetY,
            width: rail.width + railHoverOutsetX * 2,
            height: rail.height + railHoverOutsetY * 2
        )
    }

    /// Lowest usage card: the endpoint slot, centered on a 200pt panel.
    public static func bottomCardFrame(rail: CacheFrame) -> CacheFrame {
        let slot = rail.height / slotCount
        return CacheFrame(
            x: rail.minX - cardWidth - cardGap,
            y: rail.minY + (slot - cardHeight) / 2,
            width: cardWidth,
            height: cardHeight
        )
    }
    public static let corner: Double = 25
    /// Same slide as the usage rail.
    public static let animationDuration: Double = 0.34
    public static let collapseDelay: Double = 0.22
    public static let animationControlPoints: (Float, Float, Float, Float) = (0.22, 0.9, 0.28, 1)

    public static func frame(
        rail: CacheFrame,
        screenMaxX: Double,
        visibleMinY: Double,
        expanded: Bool
    ) -> CacheFrame {
        let width = expanded ? expandedWidth : collapsedWidth
        let desired = expanded ? expandedHeight : collapsedHeight
        let top = rail.minY - reservedBelowRail
        let room = top - visibleMinY
        let height = min(desired, max(0, room))
        return CacheFrame(
            x: screenMaxX - width,
            y: top - height,
            width: width,
            height: height
        )
    }

    /// Hover target around the drawer. The upward pad is smaller than the reserved gap.
    public static func hotZone(frame: CacheFrame) -> CacheFrame {
        CacheFrame(
            x: frame.x - hotPadLeft,
            y: frame.y - hotPadDown,
            width: frame.width + hotPadLeft + hotPadRight,
            height: frame.height + hotPadUp + hotPadDown
        )
    }
}
