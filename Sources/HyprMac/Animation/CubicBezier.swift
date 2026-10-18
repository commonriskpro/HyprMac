import Foundation
import CoreGraphics

/// Exact 2D cubic-bezier curve evaluator using Newton-Raphson root-finding
/// for x(t) - X = 0 and evaluating Y = y(t), identical to Hyprland's bezier solver.
public struct CubicBezier: Sendable, Equatable {
    public let x0: Double
    public let y0: Double
    public let x1: Double
    public let y1: Double

    // Polynomial coefficients for x(t)
    private let ax: Double
    private let bx: Double
    private let cx: Double

    // Polynomial coefficients for y(t)
    private let ay: Double
    private let by: Double
    private let cy: Double

    public init(x0: Double, y0: Double, x1: Double, y1: Double) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1

        // x(t) = 3(1-t)^2 * t * x0 + 3(1-t) * t^2 * x1 + t^3
        //      = (ax * t + bx) * t + cx) * t
        let cx = 3.0 * x0
        let bx = 3.0 * (x1 - x0) - cx
        let ax = 1.0 - cx - bx
        self.cx = cx
        self.bx = bx
        self.ax = ax

        let cy = 3.0 * y0
        let by = 3.0 * (y1 - y0) - cy
        let ay = 1.0 - cy - by
        self.cy = cy
        self.by = by
        self.ay = ay
    }

    public init(_ bezier: HyprBezier) {
        self.init(x0: bezier.x0, y0: bezier.y0, x1: bezier.x1, y1: bezier.y1)
    }

    @inline(__always)
    public func sampleCurveX(_ t: Double) -> Double {
        return ((ax * t + bx) * t + cx) * t
    }

    @inline(__always)
    public func sampleCurveY(_ t: Double) -> Double {
        return ((ay * t + by) * t + cy) * t
    }

    @inline(__always)
    public func sampleCurveDerivativeX(_ t: Double) -> Double {
        return (3.0 * ax * t + 2.0 * bx) * t + cx
    }

    /// Solves for t where x(t) = x using Newton-Raphson with bisection fallback.
    public func solveCurveX(_ x: Double, epsilon: Double = 1e-6) -> Double {
        if x <= 0.0 { return 0.0 }
        if x >= 1.0 { return 1.0 }

        // 1. Try Newton-Raphson (fast convergence for smooth slopes)
        var t = x
        for _ in 0..<8 {
            let xEst = sampleCurveX(t) - x
            if abs(xEst) < epsilon {
                return t
            }
            let d = sampleCurveDerivativeX(t)
            if abs(d) < 1e-6 {
                break // Derivative too flat, fallback to bisection
            }
            let tNext = t - xEst / d
            if tNext < 0.0 || tNext > 1.0 {
                break // Stepped out of bounds, fallback to bisection
            }
            t = tNext
        }

        // 2. Bisection fallback (guaranteed monotonic convergence in [0, 1])
        var t0 = 0.0
        var t1 = 1.0
        t = x

        for _ in 0..<20 {
            let xEst = sampleCurveX(t)
            if abs(xEst - x) < epsilon {
                return t
            }
            if x > xEst {
                t0 = t
            } else {
                t1 = t
            }
            t = (t1 + t0) * 0.5
        }

        return t
    }

    /// Evaluates the cubic bezier Y output for a given progress X in [0, 1].
    public func evaluate(at x: Double) -> Double {
        if x <= 0.0 { return 0.0 }
        if x >= 1.0 { return 1.0 }
        let t = solveCurveX(x)
        return sampleCurveY(t)
    }

    // Common standard presets
    public static let linear = CubicBezier(x0: 0.0, y0: 0.0, x1: 1.0, y1: 1.0)
    public static let `default` = CubicBezier(x0: 0.0, y0: 0.75, x1: 0.15, y1: 1.0)
    public static let almostLinear = CubicBezier(x0: 0.5, y0: 0.5, x1: 0.75, y1: 1.0)
    public static let quick = CubicBezier(x0: 0.15, y0: 0.0, x1: 0.1, y1: 1.0)
    public static let easeInOutCubic = CubicBezier(x0: 0.65, y0: 0.05, x1: 0.36, y1: 1.0)
    public static let myBezier = CubicBezier(x0: 0.05, y0: 0.9, x1: 0.1, y1: 1.05)
    public static let easeOutQuint = CubicBezier(x0: 0.23, y0: 1.0, x1: 0.32, y1: 1.0)
    public static let ease = CubicBezier(x0: 0.25, y0: 0.1, x1: 0.25, y1: 1.0)
    public static let easeIn = CubicBezier(x0: 0.42, y0: 0.0, x1: 1.0, y1: 1.0)
    public static let easeOut = CubicBezier(x0: 0.0, y0: 0.0, x1: 0.58, y1: 1.0)
    public static let easeInOut = CubicBezier(x0: 0.42, y0: 0.0, x1: 0.58, y1: 1.0)
}
