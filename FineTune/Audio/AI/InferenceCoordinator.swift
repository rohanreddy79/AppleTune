// FineTune/Audio/AI/InferenceCoordinator.swift
import Foundation
import Synchronization
import os

// MARK: - Threading Model
//
// InferenceCoordinator is the control plane's engine room. Three domains:
//
// 1. **Main thread / @MainActor**: lifecycle (start/stop), state, and the
//    stall callback. Mirrors the tap controllers' isolation style.
//
// 2. **Preparation (Task.detached)**: AIInferenceModel.prepare() — model
//    compilation, weight locking, warmup — runs off-main once; the model
//    only becomes eligible to publish after it succeeds. Same philosophy
//    as the crossfade warmup: never pay first-use costs on a live path.
//
// 3. **Inference thread (dedicated, pinned)**: a named Thread — NOT the
//    cooperative Swift Concurrency pool, which must never be blocked by
//    model latency — drains the feature ring, runs the model, publishes
//    snapshots, sleeps for the cadence. It may stall or be slow; the
//    render side decays toward neutral on staleness, so the audio thread
//    never depends on this thread making progress.
//
// The coordinator owns a stall watchdog: if the model stops publishing for
// longer than `stallThreshold` while running, `onStall` fires once on the
// main actor (re-armed by the next successful publish). Owners use it to
// trip the render-side AI bypass — defense in depth on top of snapshot
// staleness decay.

/// Drives an `AIInferenceModel` on a dedicated thread: feature frames in
/// (from a `PCMFeatureRing`), parameter snapshots out (to an
/// `AIParameterBus`), with lifecycle, health, and stall detection.
@MainActor
final class InferenceCoordinator<Model: AIInferenceModel> {

    enum State: Equatable {
        case idle
        case preparing
        case running
        case stopped
        case failed(String)
    }

    /// Lifecycle state. Main thread only.
    private(set) var state: State = .idle

    /// Fired once on the main actor when the model stops publishing for
    /// longer than `stallThreshold` while running; re-armed by the next
    /// publish. Wire this to the render side's `setAIBypassed(true)`.
    var onStall: (() -> Void)?

    private let core: InferenceCore<Model>
    private var thread: Thread?
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "InferenceCoordinator")

    /// - Parameters:
    ///   - model: The model to drive. `prepare()` is called during `start()`.
    ///   - featureRing: Source of feature frames (the render side produces).
    ///   - parameterBus: Destination for inference outputs (the render side
    ///     consumes).
    ///   - cadence: Inference loop period in seconds. The loop drains the
    ///     ring, infers once, publishes, then sleeps for this long.
    ///   - maxWindowSize: Most frames handed to a single `infer(_:)` call.
    ///   - stallThreshold: Seconds without a publish (while running) before
    ///     `onStall` fires.
    init(
        model: Model,
        featureRing: PCMFeatureRing,
        parameterBus: AIParameterBus<Model.Output>,
        cadence: TimeInterval = 0.05,
        maxWindowSize: Int = 64,
        stallThreshold: TimeInterval = 1.0
    ) {
        core = InferenceCore(
            model: model,
            featureRing: featureRing,
            parameterBus: parameterBus,
            cadence: cadence,
            maxWindowSize: maxWindowSize,
            stallThreshold: stallThreshold
        )
    }

    deinit {
        // Belt and braces: a leaked coordinator must not leak its thread.
        core.shouldStop.store(true, ordering: .releasing)
    }

    // MARK: - Lifecycle (main thread)

    /// Prepare the model off-main, then start the inference thread.
    /// On preparation failure the state becomes `.failed` and nothing runs.
    func start() async {
        guard state == .idle || state == .stopped else { return }
        state = .preparing

        let core = self.core
        do {
            try await Task.detached(priority: .userInitiated) {
                try core.model.prepare()
            }.value
        } catch {
            logger.error("Model preparation failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            return
        }

        // State may have moved (e.g. stop() during preparation).
        guard state == .preparing else { return }

        core.shouldStop.store(false, ordering: .releasing)
        core.stallLatched.store(false, ordering: .releasing)
        let thread = Thread { [core] in
            core.run { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.state == .running else { return }
                    self.logger.warning("Inference stalled past threshold — notifying owner")
                    self.onStall?()
                }
            }
        }
        thread.name = "FineTune.InferenceCoordinator"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        state = .running
        thread.start()
    }

    /// Stop the inference thread. Takes effect within one cadence period.
    func stop() {
        guard state == .running || state == .preparing else { return }
        core.shouldStop.store(true, ordering: .releasing)
        thread = nil
        state = .stopped
    }

    // MARK: - Diagnostics

    /// Total successful publishes since creation.
    var publishCount: UInt64 {
        core.publishCount.load(ordering: .acquiring)
    }

    /// Seconds since the model last published, or `nil` if it never has.
    var secondsSinceLastPublish: Double? {
        let last = core.lastPublishHostTime.load(ordering: .acquiring)
        guard last != 0 else { return nil }
        let nanos = Double(mach_absolute_time() &- last)
            * AIParameterSnapshot<Model.Output>.hostTimeNanosScale
        return nanos / 1_000_000_000.0
    }
}

// MARK: - Inference Core (dedicated thread)

/// The Sendable kernel the inference thread runs. Split from the
/// coordinator so the thread closure captures no main-actor state.
private final class InferenceCore<Model: AIInferenceModel>: Sendable {
    let model: Model
    let featureRing: PCMFeatureRing
    let parameterBus: AIParameterBus<Model.Output>
    let cadence: TimeInterval
    let maxWindowSize: Int
    let stallThreshold: TimeInterval

    let shouldStop = Atomic<Bool>(false)
    let publishCount = Atomic<UInt64>(0)
    let lastPublishHostTime = Atomic<UInt64>(0)
    /// One-shot latch so a stall notifies once, re-armed by the next publish.
    let stallLatched = Atomic<Bool>(false)

    init(
        model: Model,
        featureRing: PCMFeatureRing,
        parameterBus: AIParameterBus<Model.Output>,
        cadence: TimeInterval,
        maxWindowSize: Int,
        stallThreshold: TimeInterval
    ) {
        self.model = model
        self.featureRing = featureRing
        self.parameterBus = parameterBus
        self.cadence = cadence
        self.maxWindowSize = maxWindowSize
        self.stallThreshold = stallThreshold
    }

    /// The inference loop. Control plane: free to allocate, block, and be
    /// late — the render side never waits for it.
    func run(onStall: @escaping @Sendable () -> Void) {
        let stallNanosLimit = stallThreshold * 1_000_000_000.0
        let nanosPerTick = hostTicksToNanos()
        var window: [AudioFeatureFrame] = []
        window.reserveCapacity(maxWindowSize)

        // The loop start counts as activity: a model that never publishes
        // trips the watchdog `stallThreshold` after start, not instantly.
        var lastActivity = mach_absolute_time()

        while !shouldStop.load(ordering: .acquiring) {
            window.removeAll(keepingCapacity: true)
            while window.count < maxWindowSize, let frame = featureRing.pop() {
                window.append(frame)
            }

            if !window.isEmpty, let output = model.infer(window) {
                parameterBus.publish(output)
                publishCount.wrappingAdd(1, ordering: .relaxed)
                let now = mach_absolute_time()
                lastPublishHostTime.store(now, ordering: .releasing)
                lastActivity = now
                stallLatched.store(false, ordering: .releasing)
            } else {
                let stalledNanos = Double(mach_absolute_time() &- lastActivity) * nanosPerTick
                if stalledNanos > stallNanosLimit,
                   !stallLatched.exchange(true, ordering: .acquiringAndReleasing) {
                    onStall()
                }
            }

            Thread.sleep(forTimeInterval: cadence)
        }
    }

    private func hostTicksToNanos() -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.denom != 0 else { return 1.0 }
        return Double(info.numer) / Double(info.denom)
    }
}
