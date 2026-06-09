// FineTune/Audio/AI/AIInferenceModel.swift
import Foundation

/// A control-plane model the `InferenceCoordinator` drives.
///
/// Implementations range from heuristic state machines to CoreML/ANE models.
/// Whatever the backend, the contract is the same:
///
/// - `prepare()` does *all* heavy, fallible setup — model compilation,
///   wiring weights into memory (`mlock`), and a warmup inference — so that
///   `infer(_:)` never pays first-use costs. A model is not eligible to
///   publish until `prepare()` returns. Called once, off the main thread.
/// - `infer(_:)` consumes a window of feature frames and produces the next
///   parameter setpoint, or `nil` when nothing should be published this
///   cycle. It runs on the coordinator's dedicated inference thread — never
///   the audio thread — and is allowed to be slow, allocate, or stall; the
///   render side decays to neutral on staleness regardless.
protocol AIInferenceModel: Sendable {
    /// The parameter payload this model publishes (must cross the real-time
    /// boundary, hence `BitwiseCopyable`).
    associatedtype Output: BitwiseCopyable & Sendable

    /// One-time heavy setup: compile, lock weights, warm up. Throwing fails
    /// coordinator start; the coordinator never retries automatically.
    func prepare() throws

    /// Produce the next setpoint from a window of feature frames (oldest
    /// first, possibly gappy when the ring dropped under load). Return `nil`
    /// to skip publishing this cycle.
    func infer(_ frames: [AudioFeatureFrame]) -> Output?
}
