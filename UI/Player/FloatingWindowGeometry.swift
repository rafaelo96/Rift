import CoreGraphics

/// Aspect-preserving geometry in AppKit screen coordinates, including negative origins.
enum FloatingWindowGeometry {
    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let bottom = Edges(rawValue: 4)
        static let top = Edges(rawValue: 8)
    }

    static func resize(_ frame: CGRect, delta: CGPoint, edges: Edges,
                       minimum: CGSize, maximum: CGSize) -> CGRect {
        let ratio = frame.width / max(frame.height, 1)
        let horizontal = !edges.intersection([.left, .right]).isEmpty
        let vertical = !edges.intersection([.bottom, .top]).isEmpty
        let dx = edges.contains(.left) ? -delta.x : delta.x
        let dy = edges.contains(.bottom) ? -delta.y : delta.y
        let change = horizontal && (!vertical || abs(dx) >= abs(dy * ratio)) ? dx : dy * ratio
        let lower = max(minimum.width, minimum.height * ratio)
        let upper = max(lower, min(maximum.width, maximum.height * ratio))
        let width = min(max(frame.width + change, lower), upper)
        let height = width / ratio
        let x = edges.contains(.left) ? frame.maxX - width
            : edges.contains(.right) ? frame.minX : frame.midX - width / 2
        let y = edges.contains(.bottom) ? frame.maxY - height
            : edges.contains(.top) ? frame.minY : frame.midY - height / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func fit(_ frame: CGRect, in visible: CGRect, minimum: CGSize) -> CGRect {
        let ratio = frame.width / max(frame.height, 1)
        let width = min(max(frame.width, minimum.width), visible.width, visible.height * ratio)
        let height = width / ratio
        return CGRect(x: min(max(frame.minX, visible.minX), visible.maxX - width),
                      y: min(max(frame.minY, visible.minY), visible.maxY - height),
                      width: width, height: height)
    }
}
