// FineTune/Audio/AI/AIRenderParameters.swift
import Foundation

/// Control-plane setpoints applied at the AI hook in the render pipeline
/// (between per-app EQ and per-device AutoEQ).
///
/// Fields are *setpoints*, not commands: the render callback slews toward
/// them over several buffers and decays back to `.neutral` when the
/// publishing control plane goes stale or the AI bypass is engaged. The
/// struct must stay `BitwiseCopyable` — it crosses the real-time boundary
/// through an `AIParameterBus` as a plain copy.
struct AIRenderParameters: BitwiseCopyable, Sendable {
    /// Linear gain applied at the AI hook. 1.0 = unity (no contribution).
    /// Clamped to 0.0...4.0 at the point of use, matching the volume×boost
    /// range the rest of the pipeline already enforces.
    var gainTrim: Float

    /// The identity element: parameters that leave audio bit-exact.
    static let neutral = AIRenderParameters(gainTrim: 1.0)
}

/// The bus specialization the render pipeline consumes.
typealias AIRenderParameterBus = AIParameterBus<AIRenderParameters>
