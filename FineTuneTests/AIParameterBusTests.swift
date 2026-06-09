// FineTuneTests/AIParameterBusTests.swift
// Tests for AIParameterBus — the lock-free SPSC "latest value" exchange
// between the AI control plane and the real-time signal plane.
// Targets: publish/acquire semantics, latest-wins coalescing, sticky reads,
// sequence monotonicity, staleness clock, and a cross-thread torn-read
// stress harness.

import Foundation
import Synchronization
import Testing
@testable import FineTune

// MARK: - Test Payloads

// The test target defaults to MainActor isolation; these helpers are touched
// from background threads in the stress harness, so they opt out explicitly.

/// Minimal control-plane payload shaped like the real use case.
private nonisolated struct GainPayload: BitwiseCopyable, Sendable {
    var gain: Float
    var tilt: Float
}

/// Payload whose fields are all derived from one seed. A torn read (mixing
/// bytes from two different publishes) breaks the derivation invariant.
private nonisolated struct StressPayload: BitwiseCopyable, Sendable {
    var a: UInt64
    var b: UInt64
    var c: UInt64
    var d: UInt64

    init(seed: UInt64) {
        a = seed
        b = seed &* 0x9E37_79B9_7F4A_7C15
        c = ~seed
        d = seed ^ 0xDEAD_BEEF
    }

    var isConsistent: Bool {
        b == a &* 0x9E37_79B9_7F4A_7C15 && c == ~a && d == (a ^ 0xDEAD_BEEF)
    }
}

// MARK: - Publish / Acquire Semantics

@Suite("AIParameterBus — Publish/Acquire Semantics")
struct AIParameterBusSemanticsTests {

    @Test("Acquire before any publish returns nil")
    func emptyBusReturnsNil() {
        let bus = AIParameterBus<GainPayload>()
        #expect(bus.acquireLatest() == nil)
        #expect(bus.lastPublishedSequence == 0)
    }

    @Test("Single publish is acquired with sequence 1 and intact payload")
    func singlePublishRoundTrip() throws {
        let bus = AIParameterBus<GainPayload>()
        bus.publish(GainPayload(gain: 0.5, tilt: -3.0))

        let snapshot = try #require(bus.acquireLatest())
        #expect(snapshot.sequence == 1)
        #expect(snapshot.payload.gain == 0.5)
        #expect(snapshot.payload.tilt == -3.0)
        #expect(bus.lastPublishedSequence == 1)
    }

    @Test("Multiple publishes without acquire coalesce to the latest")
    func unconsumedPublishesCoalesce() throws {
        let bus = AIParameterBus<GainPayload>()
        bus.publish(GainPayload(gain: 0.1, tilt: 0))
        bus.publish(GainPayload(gain: 0.2, tilt: 0))
        bus.publish(GainPayload(gain: 0.3, tilt: 0))

        let snapshot = try #require(bus.acquireLatest())
        #expect(snapshot.sequence == 3, "Consumer must see the latest publish, not an intermediate")
        #expect(snapshot.payload.gain == 0.3)
    }

    @Test("Acquire is sticky: repeated calls without a new publish return the same snapshot")
    func acquireIsSticky() throws {
        let bus = AIParameterBus<GainPayload>()
        bus.publish(GainPayload(gain: 0.7, tilt: 1.5))

        let first = try #require(bus.acquireLatest())
        let second = try #require(bus.acquireLatest())
        let third = try #require(bus.acquireLatest())
        #expect(first.sequence == 1)
        #expect(second.sequence == 1)
        #expect(third.sequence == 1)
        #expect(third.payload.gain == 0.7)
    }

    @Test("Alternating publish/acquire stays correct across all slot rotations")
    func alternatingPublishAcquireRotatesSlots() throws {
        let bus = AIParameterBus<GainPayload>()
        // 12 iterations cycles every slot through writer, middle, and reader
        // ownership several times.
        for i in 1...12 {
            bus.publish(GainPayload(gain: Float(i), tilt: Float(-i)))
            let snapshot = try #require(bus.acquireLatest())
            #expect(snapshot.sequence == UInt64(i))
            #expect(snapshot.payload.gain == Float(i))
            #expect(snapshot.payload.tilt == Float(-i))
        }
    }

    @Test("Sequences are strictly increasing across mixed publish/acquire patterns")
    func sequencesStrictlyIncrease() {
        let bus = AIParameterBus<GainPayload>()
        var lastSeen: UInt64 = 0
        for i in 1...50 {
            bus.publish(GainPayload(gain: Float(i), tilt: 0))
            if i % 3 == 0 { bus.publish(GainPayload(gain: Float(i) + 0.5, tilt: 0)) }
            guard let snapshot = bus.acquireLatest() else {
                Issue.record("Acquire returned nil after publish at iteration \(i)")
                return
            }
            #expect(snapshot.sequence > lastSeen,
                    "Sequence regressed: \(snapshot.sequence) after \(lastSeen)")
            lastSeen = snapshot.sequence
        }
    }
}

// MARK: - Staleness Clock

@Suite("AIParameterBus — Staleness Clock")
struct AIParameterBusStalenessTests {

    @Test("Fresh snapshot reports a small non-negative age and is not stale")
    func freshSnapshotAge() throws {
        let bus = AIParameterBus<GainPayload>()
        bus.publish(GainPayload(gain: 1.0, tilt: 0))

        let snapshot = try #require(bus.acquireLatest())
        let age = snapshot.nanosecondsSincePublish()
        #expect(age >= 0)
        #expect(age < 5_000_000_000, "Snapshot published just now should be < 5s old")
        #expect(!snapshot.isStale(after: 60.0))
    }

    @Test("Snapshot becomes stale once its age exceeds the threshold")
    func snapshotBecomesStale() throws {
        let bus = AIParameterBus<GainPayload>()
        bus.publish(GainPayload(gain: 1.0, tilt: 0))
        let snapshot = try #require(bus.acquireLatest())

        usleep(5_000) // 5 ms
        #expect(snapshot.isStale(after: 0.001),
                "Snapshot older than 1ms must report stale at a 1ms threshold")
        #expect(!snapshot.isStale(after: 30.0))
    }

    @Test("Age is computable against an explicit host time")
    func explicitHostTimeAge() throws {
        let bus = AIParameterBus<GainPayload>()
        bus.publish(GainPayload(gain: 1.0, tilt: 0))
        let snapshot = try #require(bus.acquireLatest())

        // Age measured at publish time itself is zero.
        #expect(snapshot.nanosecondsSincePublish(asOf: snapshot.hostTime) == 0)
        #expect(!snapshot.isStale(after: 0.0001, asOf: snapshot.hostTime))
    }
}

// MARK: - Cross-Thread Stress (Adversarial)

/// Shared tally for the stress harness. Atomics only — the whole point is to
/// avoid introducing synchronization that would mask bus races.
private nonisolated final class StressTally: Sendable {
    let tornReads = Atomic<Int>(0)
    let sequenceRegressions = Atomic<Int>(0)
    let freshAcquisitions = Atomic<Int>(0)
    let finalSequenceSeen = Atomic<UInt64>(0)
}

@Suite("AIParameterBus — Cross-Thread Stress (Adversarial)")
struct AIParameterBusStressTests {

    @Test("Concurrent publisher/consumer: no torn reads, no sequence regressions",
          .timeLimit(.minutes(1)))
    func concurrentPublishConsumeStress() {
        let bus = AIParameterBus<StressPayload>()
        let tally = StressTally()
        let publishCount: UInt64 = 200_000
        let readerDone = DispatchSemaphore(value: 0)
        let writerDone = DispatchSemaphore(value: 0)

        let writer = Thread {
            for i in 1...publishCount {
                bus.publish(StressPayload(seed: i))
            }
            writerDone.signal()
        }

        let reader = Thread {
            var lastSequence: UInt64 = 0
            let deadline = Date(timeIntervalSinceNow: 30)
            while Date() < deadline {
                if let snapshot = bus.acquireLatest(), snapshot.sequence != lastSequence {
                    tally.freshAcquisitions.wrappingAdd(1, ordering: .relaxed)
                    if !snapshot.payload.isConsistent {
                        tally.tornReads.wrappingAdd(1, ordering: .relaxed)
                    }
                    if snapshot.sequence < lastSequence {
                        tally.sequenceRegressions.wrappingAdd(1, ordering: .relaxed)
                    }
                    lastSequence = snapshot.sequence
                    if lastSequence == publishCount { break }
                }
            }
            tally.finalSequenceSeen.store(lastSequence, ordering: .releasing)
            readerDone.signal()
        }

        writer.start()
        reader.start()

        #expect(writerDone.wait(timeout: .now() + 40) == .success, "Writer thread did not finish")
        #expect(readerDone.wait(timeout: .now() + 40) == .success, "Reader thread did not finish")

        #expect(tally.tornReads.load(ordering: .acquiring) == 0,
                "Torn reads detected — payload bytes mixed across publishes")
        #expect(tally.sequenceRegressions.load(ordering: .acquiring) == 0,
                "Sequence went backwards — consumer observed an older snapshot after a newer one")
        #expect(tally.freshAcquisitions.load(ordering: .acquiring) > 0,
                "Reader never acquired anything — harness is broken")
        #expect(tally.finalSequenceSeen.load(ordering: .acquiring) == publishCount,
                "Reader never converged on the final publish — freshness flag lost")
    }

    @Test("Coalescing under pressure: consumer always converges on the final value")
    func slowConsumerConvergesOnFinalValue() {
        let bus = AIParameterBus<StressPayload>()
        let publishCount: UInt64 = 10_000
        let writerDone = DispatchSemaphore(value: 0)

        let writer = Thread {
            for i in 1...publishCount {
                bus.publish(StressPayload(seed: i))
            }
            writerDone.signal()
        }
        writer.start()
        #expect(writerDone.wait(timeout: .now() + 30) == .success, "Writer thread did not finish")

        // Consumer wakes up only after the publish storm: it must see exactly
        // the final snapshot, intact.
        guard let snapshot = bus.acquireLatest() else {
            Issue.record("No snapshot available after \(publishCount) publishes")
            return
        }
        #expect(snapshot.sequence == publishCount)
        #expect(snapshot.payload.isConsistent)
        #expect(snapshot.payload.a == publishCount)
    }
}
