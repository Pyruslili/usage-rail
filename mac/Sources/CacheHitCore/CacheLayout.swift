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

    public func contains(_ px: Double, _ py: Double) -> Bool {
        px >= minX && px < maxX && py >= minY && py < maxY
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
    /// Visual gap under the usage rail. Does not change the rail's own 24pt hover pad.
    public static let gapBelowRail: Double = 8
    public static let hotPadLeft: Double = 16
    public static let hotPadRight: Double = 10
    public static let hotPadUp: Double = 4
    public static let hotPadDown: Double = 24
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
        let top = rail.minY - gapBelowRail
        let room = top - visibleMinY
        let height: Double
        if expanded {
            height = min(desired, max(0, room))
        } else {
            height = min(desired, max(0, room))
        }
        return CacheFrame(
            x: screenMaxX - width,
            y: top - height,
            width: width,
            height: height
        )
    }

    /// Hover target around the drawer. Upward pad stays inside the gap so it does not cover the rail body.
    public static func hotZone(frame: CacheFrame) -> CacheFrame {
        CacheFrame(
            x: frame.x - hotPadLeft,
            y: frame.y - hotPadDown,
            width: frame.width + hotPadLeft + hotPadRight,
            height: frame.height + hotPadUp + hotPadDown
        )
    }
}
