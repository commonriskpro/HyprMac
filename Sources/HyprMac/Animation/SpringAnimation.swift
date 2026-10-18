import Foundation
import CoreGraphics

/// Configuration for an analytical damped harmonic oscillator.
public struct SpringConfig: Equatable, Hashable, Sendable {
    public var mass: Double
    public var stiffness: Double
    public var damping: Double

    public init(mass: Double = 1.0, stiffness: Double = 100.0, damping: Double = 10.0) {
        self.mass = max(mass, 0.001)
        self.stiffness = max(stiffness, 0.001)
        self.damping = max(damping, 0.0)
    }

    /// Creates a spring config with an explicit dimensionless damping ratio zeta (ζ).
    /// ζ < 1: underdamped (oscillates before settling)
    /// ζ = 1: critically damped (fastest settling with zero oscillation)
    /// ζ > 1: overdamped (slow exponential return without oscillation)
    public static func withDampingRatio(
        mass: Double = 1.0,
        stiffness: Double = 100.0,
        dampingRatio: Double = 0.8
    ) -> SpringConfig {
        let m = max(mass, 0.001)
        let k = max(stiffness, 0.001)
        let c = 2.0 * dampingRatio * sqrt(m * k)
        return SpringConfig(mass: m, stiffness: k, damping: c)
    }

    /// Damping ratio zeta (ζ) = c / (2 * sqrt(m * k))
    public var dampingRatio: Double {
        damping / (2.0 * sqrt(mass * stiffness))
    }

    /// Undamped natural angular frequency ω0 = sqrt(k / m)
    public var naturalFrequency: Double {
        sqrt(stiffness / mass)
    }

    // Upstream Hyprland default spring presets
    public static let easy = SpringConfig(mass: 1.0, stiffness: 238.1191, damping: 24.2128)
    public static let defaultSpring = SpringConfig(mass: 1.0, stiffness: 250.0, damping: 25.0)
    public static let `default` = SpringConfig(mass: 1.0, stiffness: 250.0, damping: 25.0)
    public static let bouncy = SpringConfig.withDampingRatio(mass: 1.0, stiffness: 120.0, dampingRatio: 0.6)
    public static let snappy = SpringConfig.withDampingRatio(mass: 1.0, stiffness: 200.0, dampingRatio: 0.9)
    public static let smooth = SpringConfig.withDampingRatio(mass: 1.0, stiffness: 80.0, dampingRatio: 1.0)
    public static let overdamped = SpringConfig.withDampingRatio(mass: 1.0, stiffness: 80.0, dampingRatio: 1.4)
}

/// Exact analytical damped harmonic oscillator solver.
/// Closed-form evaluation for underdamped, critically damped, and overdamped regimes.
public final class SpringAnimation: @unchecked Sendable {
    public let config: SpringConfig
    public private(set) var startValue: Double
    public private(set) var targetValue: Double
    public private(set) var initialVelocity: Double

    public private(set) var currentValue: Double
    public private(set) var currentVelocity: Double
    public private(set) var isSettled: Bool = false

    private var elapsedTime: Double = 0.0

    public init(
        config: SpringConfig = .default,
        startValue: Double = 0.0,
        targetValue: Double = 1.0,
        initialVelocity: Double = 0.0
    ) {
        self.config = config
        self.startValue = startValue
        self.targetValue = targetValue
        self.initialVelocity = initialVelocity
        self.currentValue = startValue
        self.currentVelocity = initialVelocity
        self.isSettled = (abs(startValue - targetValue) < 1e-5 && abs(initialVelocity) < 1e-4)
    }

    /// Reconfigures start, target and initial velocity, resetting elapsed time.
    public func reset(startValue: Double, targetValue: Double, initialVelocity: Double = 0.0) {
        self.startValue = startValue
        self.targetValue = targetValue
        self.initialVelocity = initialVelocity
        self.currentValue = startValue
        self.currentVelocity = initialVelocity
        self.elapsedTime = 0.0
        self.isSettled = (abs(startValue - targetValue) < 1e-5 && abs(initialVelocity) < 1e-4)
    }

    /// Evaluates the analytical solution (position and velocity) at any given elapsed time t >= 0.
    public func evaluate(at t: Double) -> (value: Double, velocity: Double) {
        if t <= 0.0 {
            return (startValue, initialVelocity)
        }
        if isSettled {
            return (targetValue, 0.0)
        }

        let y0 = startValue - targetValue
        let v0 = initialVelocity
        let m = config.mass
        let k = config.stiffness
        let c = config.damping
        let omega0 = sqrt(k / m)
        let zeta = c / (2.0 * sqrt(m * k))

        let y: Double
        let v: Double

        if zeta < 0.9999 {
            // 1. Underdamped (oscillatory decay)
            let omegaD = omega0 * sqrt(1.0 - zeta * zeta)
            let gamma = zeta * omega0
            let c1 = y0
            let c2 = (v0 + gamma * y0) / omegaD
            let decay = exp(-gamma * t)
            let cosTerm = cos(omegaD * t)
            let sinTerm = sin(omegaD * t)

            y = decay * (c1 * cosTerm + c2 * sinTerm)
            v = decay * ((c2 * omegaD - c1 * gamma) * cosTerm - (c1 * omegaD + c2 * gamma) * sinTerm)
        } else if zeta > 1.0001 {
            // 2. Overdamped (two real decaying exponentials)
            let omegaD = omega0 * sqrt(zeta * zeta - 1.0)
            let r1 = -zeta * omega0 + omegaD
            let r2 = -zeta * omega0 - omegaD
            let c2 = (v0 - r1 * y0) / (r2 - r1)
            let c1 = y0 - c2

            let e1 = exp(r1 * t)
            let e2 = exp(r2 * t)
            y = c1 * e1 + c2 * e2
            v = c1 * r1 * e1 + c2 * r2 * e2
        } else {
            // 3. Critically damped (fastest monotonic decay)
            let c1 = y0
            let c2 = v0 + omega0 * y0
            let decay = exp(-omega0 * t)

            y = decay * (c1 + c2 * t)
            v = decay * (c2 - omega0 * (c1 + c2 * t))
        }

        return (targetValue + y, v)
    }

    /// Advances time by dt seconds and updates currentValue and currentVelocity.
    /// Checks convergence against displacement and velocity thresholds.
    @discardableResult
    public func step(
        dt: Double,
        tolerance: Double = 5e-4,
        velocityTolerance: Double = 5e-3
    ) -> Double {
        if isSettled { return targetValue }
        elapsedTime += dt
        let (val, vel) = evaluate(at: elapsedTime)
        currentValue = val
        currentVelocity = vel

        if abs(val - targetValue) < tolerance && abs(vel) < velocityTolerance {
            currentValue = targetValue
            currentVelocity = 0.0
            isSettled = true
        }
        return currentValue
    }
}
