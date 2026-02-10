import Foundation

public struct Frame: Codable, Equatable, Sendable {
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

    public var array: [Double] {
        [x, y, width, height]
    }

    public func approxEquals(_ other: Frame, tolerance: Double = 2.0) -> Bool {
        abs(x - other.x) <= tolerance &&
        abs(y - other.y) <= tolerance &&
        abs(width - other.width) <= tolerance &&
        abs(height - other.height) <= tolerance
    }

    public func delta(from expected: Frame) -> [String: Double] {
        [
            "x": x - expected.x,
            "y": y - expected.y,
            "width": width - expected.width,
            "height": height - expected.height
        ]
    }
}
