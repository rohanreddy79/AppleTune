// FineTuneTests/InferenceCoordinatorTests.swift
// Tests for InferenceCoordinator — the control-plane engine that drives an
// AIInferenceModel on a dedicated thread between a PCMFeatureRing and an
// AIParameterBus.
// Targets: lifecycle transitions, preparation failure, frame delivery and
// snapshot publishing end-to-end, nil-output cycles, stop semantics, and
// the stall watchdog latch.

import Foundation
import Synchronization
import Testing
@testable import FineTune

// MARK: - Test Doubles

/// Output payload whose value is derived from the frames it saw.
private nonisolated struct TestOutput: BitwiseCopyable, Sendable {
    var frameTotal: UInt64
    var marker: Float
}

/// Configurable model double. Thread-agnostic by construction (atomics
/// only) because infer(_:) runs on the coordinator's inference thread.
private nonisolated final class StubModel: AIInferenceModel, Sendable {
    typealias Output = TestOutput

    let shouldFailPrepare: Bool
    let returnsNil: Bool
    let prepared = Atomic<Bool>(false)
    let inferCalls = Atomic<Int>(0)
    let framesSeen = Atomic<UInt64>(0)

    init(shouldFailPrepare: Bool = false, returnsNil: Bool = false) {
        self.shouldFailPrepare = shouldFailPrepare
        self.returnsNil = returnsNil
    }

    struct PrepareError: Error, LocalizedError {
        var errorDescription: String? { "stub preparation failure" }
    }

    func prepare() throws {
        if shouldFailPrepare { throw PrepareError() }
        prepared.store(true, ordering: .releasing)
    }

    func infer(_ frames: [AudioFeatureFrame]) -> TestOutput? {
        inferCalls.wrappingAdd(1, ordering: .relaxed)
        framesSeen.wrappingAdd(UInt64(frames.count), ordering: .relaxed)
        guard !returnsNil else { return nil }
        return TestOutput(
            frameTotal: framesSeen.load(ordering: .relaxed),
            marker: 42.0
        )
    }
}

/// Box for the stall counter — `Atomic` is non-copyable and cannot be
/// captured directly by an escaping closure while also read afterwards.
private nonisolated final class StallCounter: Sendable {
    let count = Atomic<Int>(0)
}

private func makeFrame(frameCount: UInt32 = 128) -> AudioFeatureFrame {
    let samples = [Float](repeating: 0.25, count: Int(frameCount))
    return samples.withUnsafeBufferPointer { buffer in
        AudioFeatureFrame.measure(
            samples: buffer.baseAddress!,
            frameCount: Int(frameCount),
            channelCount: 1,
            sampleRate: 48_000
        )
    }
}

/// Poll until `condition` is true or the deadline passes.
@MainActor
private func eventually(
    seconds: TimeInterval = 5.0,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms
    }
    return condition()
}

// MARK: - Lifecycle & End-to-End

@Suite("InferenceCoordinator — Lifecycle & Publishing", .serialized)
struct InferenceCoordinatorTests {

    @Test("Frames pushed into the ring reach the model and snapshots reach the bus",
          .timeLimit(.minutes(1)))
    func endToEndPublishing() async {
        let model = StubModel()
        let ring = PCMFeatureRing(minimumCapacity: 32)
        let bus = AIParameterBus<TestOutput>()
        let coordinator = InferenceCoordinator(
            model: model,
            featureRing: ring,
            parameterBus: bus,
            cadence: 0.005
        )

        await coordinator.start()
        #expect(coordinator.state == .running)
        // Loaded into a local because #expect's macro expansion captures the
        // receiver for diagnostics, and Atomic is non-copyable.
        let prepared = model.prepared.load(ordering: .acquiring)
        #expect(prepared,
                "prepare() must complete before the model is eligible")

        for _ in 0..<10 { ring.push(makeFrame()) }

        let published = await eventually { coordinator.publishCount > 0 }
        #expect(published, "Coordinator never published despite available frames")

        guard let snapshot = bus.acquireLatest() else {
            Issue.record("Bus empty after a recorded publish")
            coordinator.stop()
            return
        }
        #expect(snapshot.payload.marker == 42.0)
        #expect(snapshot.payload.frameTotal > 0, "Model should have seen the pushed frames")
        #expect(coordinator.secondsSinceLastPublish != nil)

        coordinator.stop()
        #expect(coordinator.state == .stopped)
    }

    @Test("Preparation failure lands in .failed and nothing ever runs",
          .timeLimit(.minutes(1)))
    func prepareFailure() async {
        let model = StubModel(shouldFailPrepare: true)
        let ring = PCMFeatureRing(minimumCapacity: 8)
        let bus = AIParameterBus<TestOutput>()
        let coordinator = InferenceCoordinator(
            model: model,
            featureRing: ring,
            parameterBus: bus,
            cadence: 0.005
        )

        await coordinator.start()
        #expect(coordinator.state == .failed("stub preparation failure"))

        ring.push(makeFrame())
        try? await Task.sleep(nanoseconds: 50_000_000) // 10 cadences
        #expect(model.inferCalls.load(ordering: .acquiring) == 0,
                "A failed coordinator must never call infer()")
        #expect(coordinator.publishCount == 0)
    }

    @Test("Models returning nil keep running but never publish",
          .timeLimit(.minutes(1)))
    func nilOutputPublishesNothing() async {
        let model = StubModel(returnsNil: true)
        let ring = PCMFeatureRing(minimumCapacity: 8)
        let bus = AIParameterBus<TestOutput>()
        let coordinator = InferenceCoordinator(
            model: model,
            featureRing: ring,
            parameterBus: bus,
            cadence: 0.005
        )

        await coordinator.start()
        for _ in 0..<5 { ring.push(makeFrame()) }

        let inferred = await eventually { model.inferCalls.load(ordering: .acquiring) > 0 }
        #expect(inferred, "Model should be invoked even when it declines to publish")
        #expect(coordinator.publishCount == 0)
        #expect(bus.acquireLatest() == nil)
        #expect(coordinator.state == .running)
        #expect(coordinator.secondsSinceLastPublish == nil)

        coordinator.stop()
    }

    @Test("Stop halts inference within a few cadences",
          .timeLimit(.minutes(1)))
    func stopHaltsInference() async {
        let model = StubModel()
        let ring = PCMFeatureRing(minimumCapacity: 32)
        let bus = AIParameterBus<TestOutput>()
        let coordinator = InferenceCoordinator(
            model: model,
            featureRing: ring,
            parameterBus: bus,
            cadence: 0.005
        )

        await coordinator.start()
        ring.push(makeFrame())
        _ = await eventually { coordinator.publishCount > 0 }

        coordinator.stop()
        #expect(coordinator.state == .stopped)

        // Let any in-flight cycle drain, then verify quiescence.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let countAfterStop = model.inferCalls.load(ordering: .acquiring)
        for _ in 0..<5 { ring.push(makeFrame()) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.inferCalls.load(ordering: .acquiring) == countAfterStop,
                "infer() ran after stop()")
    }

    @Test("Restart after stop works and publishes again",
          .timeLimit(.minutes(1)))
    func restartAfterStop() async {
        let model = StubModel()
        let ring = PCMFeatureRing(minimumCapacity: 32)
        let bus = AIParameterBus<TestOutput>()
        let coordinator = InferenceCoordinator(
            model: model,
            featureRing: ring,
            parameterBus: bus,
            cadence: 0.005
        )

        await coordinator.start()
        ring.push(makeFrame())
        _ = await eventually { coordinator.publishCount > 0 }
        coordinator.stop()
        let countAfterFirstRun = coordinator.publishCount

        await coordinator.start()
        #expect(coordinator.state == .running)
        ring.push(makeFrame())
        let republished = await eventually { coordinator.publishCount > countAfterFirstRun }
        #expect(republished, "Restarted coordinator never published")
        coordinator.stop()
    }

    @Test("Stall watchdog fires once when the model goes quiet",
          .timeLimit(.minutes(1)))
    func stallWatchdogFires() async {
        let model = StubModel(returnsNil: true) // never publishes → stalls
        let ring = PCMFeatureRing(minimumCapacity: 8)
        let bus = AIParameterBus<TestOutput>()
        let coordinator = InferenceCoordinator(
            model: model,
            featureRing: ring,
            parameterBus: bus,
            cadence: 0.005,
            stallThreshold: 0.05
        )

        let stalls = StallCounter()
        coordinator.onStall = { stalls.count.wrappingAdd(1, ordering: .relaxed) }

        await coordinator.start()
        let stalled = await eventually { stalls.count.load(ordering: .acquiring) > 0 }
        #expect(stalled, "Watchdog never fired for a permanently quiet model")

        // Latch: no repeat notifications without an intervening publish.
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(stalls.count.load(ordering: .acquiring) == 1,
                "Stall watchdog must latch after firing once")

        coordinator.stop()
    }
}
