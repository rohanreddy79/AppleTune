// FineTuneTests/PCMFeatureRingTests.swift
// Tests for SPSCRing/PCMFeatureRing — the lock-free SPSC bounded FIFO that
// ships per-buffer feature frames from the signal plane to the control
// plane — and for AudioFeatureFrame's RT-safe measurement.
// Targets: FIFO ordering, capacity rounding, drop-on-full accounting,
// index wrap-around, a cross-thread torn-read/ordering stress harness, and
// known-signal feature extraction (sine, DC, silence, stereo).

import Foundation
import Synchronization
import Testing
@testable import FineTune

// MARK: - Test Elements

// The test target defaults to MainActor isolation; these helpers are touched
// from background threads in the stress harness, so they opt out explicitly.

/// Element whose fields are all derived from one seed. A torn read (mixing
/// bytes from two different pushes) breaks the derivation invariant.
private nonisolated struct StressElement: BitwiseCopyable, Sendable {
    var a: UInt64
    var b: UInt64
    var c: UInt64

    init(seed: UInt64) {
        a = seed
        b = seed &* 0x9E37_79B9_7F4A_7C15
        c = ~seed
    }

    var isConsistent: Bool {
        b == a &* 0x9E37_79B9_7F4A_7C15 && c == ~a
    }
}

// MARK: - FIFO Semantics

@Suite("SPSCRing — FIFO Semantics")
struct SPSCRingSemanticsTests {

    @Test("Capacity rounds up to the next power of two",
          arguments: [(1, 2), (2, 2), (3, 4), (4, 4), (5, 8), (63, 64), (64, 64), (65, 128)])
    func capacityRounding(requested: Int, expected: Int) {
        let ring = SPSCRing<UInt64>(minimumCapacity: requested)
        #expect(ring.capacity == expected)
    }

    @Test("Pop on an empty ring returns nil")
    func emptyRingPopsNil() {
        let ring = SPSCRing<UInt64>(minimumCapacity: 4)
        #expect(ring.pop() == nil)
        #expect(ring.isEmpty)
        #expect(ring.approximateCount == 0)
        #expect(ring.droppedCount == 0)
    }

    @Test("Elements come out in push order")
    func fifoOrdering() {
        let ring = SPSCRing<UInt64>(minimumCapacity: 8)
        for value: UInt64 in 1...5 { #expect(ring.push(value)) }
        #expect(ring.approximateCount == 5)
        for expected: UInt64 in 1...5 {
            #expect(ring.pop() == expected)
        }
        #expect(ring.pop() == nil)
    }

    @Test("Push on a full ring drops the element and counts it")
    func dropOnFull() {
        let ring = SPSCRing<UInt64>(minimumCapacity: 4) // capacity 4
        for value: UInt64 in 1...4 { #expect(ring.push(value)) }

        #expect(!ring.push(99), "Push into a full ring must report the drop")
        #expect(!ring.push(100))
        #expect(ring.droppedCount == 2)
        #expect(ring.approximateCount == 4)

        // Buffered elements are intact — drops never overwrite.
        for expected: UInt64 in 1...4 {
            #expect(ring.pop() == expected)
        }

        // Space freed: pushes succeed again.
        #expect(ring.push(7))
        #expect(ring.pop() == 7)
    }

    @Test("Indices wrap cleanly across many fill/drain cycles")
    func wrapAroundCycles() {
        let ring = SPSCRing<UInt64>(minimumCapacity: 4) // capacity 4
        var next: UInt64 = 0
        var expected: UInt64 = 0
        // 1000 cycles of fill-3/drain-3 pushes indices far past several
        // multiples of capacity.
        for _ in 0..<1000 {
            for _ in 0..<3 {
                #expect(ring.push(next))
                next &+= 1
            }
            for _ in 0..<3 {
                #expect(ring.pop() == expected)
                expected &+= 1
            }
        }
        #expect(ring.isEmpty)
        #expect(ring.droppedCount == 0)
    }

    @Test("Interleaved push/pop keeps count and order consistent")
    func interleavedPushPop() {
        // Every second step pushes twice but pops once, so the surplus
        // reaches 25 by step 50 — capacity must cover it or the ring's
        // (correct) drop-on-full behavior breaks the expected sequence.
        let ring = SPSCRing<UInt64>(minimumCapacity: 32)
        var next: UInt64 = 1
        var expected: UInt64 = 1
        for step in 1...50 {
            ring.push(next); next &+= 1
            if step % 2 == 0 {
                ring.push(next); next &+= 1
            }
            #expect(ring.pop() == expected)
            expected &+= 1
        }
        // Drain the surplus from the double-push steps.
        while let value = ring.pop() {
            #expect(value == expected)
            expected &+= 1
        }
        #expect(expected == next)
        #expect(ring.droppedCount == 0, "Nothing should have dropped at this capacity")
    }
}

// MARK: - Cross-Thread Stress (Adversarial)

/// Shared tally for the stress harness. Atomics only — the whole point is to
/// avoid introducing synchronization that would mask ring races.
private nonisolated final class RingStressTally: Sendable {
    let tornReads = Atomic<Int>(0)
    let orderViolations = Atomic<Int>(0)
    let consumed = Atomic<UInt64>(0)
    let produced = Atomic<UInt64>(0)
    let producerFinished = Atomic<Bool>(false)
}

@Suite("SPSCRing — Cross-Thread Stress (Adversarial)")
struct SPSCRingStressTests {

    @Test("Concurrent producer/consumer: no torn reads, strict FIFO order, exact accounting",
          .timeLimit(.minutes(1)))
    func concurrentPushPopStress() {
        let ring = SPSCRing<StressElement>(minimumCapacity: 64)
        let tally = RingStressTally()
        let pushAttempts: UInt64 = 200_000
        let producerDone = DispatchSemaphore(value: 0)
        let consumerDone = DispatchSemaphore(value: 0)

        let producer = Thread {
            var accepted: UInt64 = 0
            for seed in 1...pushAttempts {
                if ring.push(StressElement(seed: seed)) { accepted &+= 1 }
            }
            tally.produced.store(accepted, ordering: .releasing)
            tally.producerFinished.store(true, ordering: .releasing)
            producerDone.signal()
        }

        let consumer = Thread {
            var lastSeed: UInt64 = 0
            var consumed: UInt64 = 0
            while true {
                if let element = ring.pop() {
                    consumed &+= 1
                    if !element.isConsistent {
                        tally.tornReads.wrappingAdd(1, ordering: .relaxed)
                    }
                    // Drop-on-full may skip seeds, but FIFO order means
                    // consumed seeds must be strictly increasing.
                    if element.a <= lastSeed {
                        tally.orderViolations.wrappingAdd(1, ordering: .relaxed)
                    }
                    lastSeed = element.a
                } else if tally.producerFinished.load(ordering: .acquiring) {
                    // Producer is done and the ring is empty — drained.
                    break
                }
            }
            tally.consumed.store(consumed, ordering: .releasing)
            consumerDone.signal()
        }

        producer.start()
        consumer.start()

        #expect(producerDone.wait(timeout: .now() + 40) == .success, "Producer thread did not finish")
        #expect(consumerDone.wait(timeout: .now() + 40) == .success, "Consumer thread did not finish")

        let produced = tally.produced.load(ordering: .acquiring)
        let consumed = tally.consumed.load(ordering: .acquiring)
        #expect(tally.tornReads.load(ordering: .acquiring) == 0,
                "Torn reads detected — element bytes mixed across pushes")
        #expect(tally.orderViolations.load(ordering: .acquiring) == 0,
                "FIFO order violated — consumer saw seeds out of order")
        #expect(consumed == produced,
                "Accounting mismatch: \(produced) accepted pushes but \(consumed) pops")
        #expect(produced &+ ring.droppedCount == pushAttempts,
                "accepted (\(produced)) + dropped (\(ring.droppedCount)) must equal attempts (\(pushAttempts))")
        #expect(consumed > 0, "Consumer never drained anything — harness is broken")
    }
}

// MARK: - AudioFeatureFrame Measurement

@Suite("AudioFeatureFrame — Known-Signal Measurement")
struct AudioFeatureFrameTests {

    @Test("Mono sine: peak ≈ amplitude, rms ≈ amplitude/√2, crossings ≈ 2 per cycle")
    func monoSine() {
        let sampleRate = 48_000.0
        let frequency = 1_000.0
        let amplitude: Float = 0.5
        let frameCount = 480 // 10 full cycles
        var samples = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            samples[i] = amplitude * Float(sin(2.0 * .pi * frequency * Double(i) / sampleRate))
        }

        let frame = samples.withUnsafeBufferPointer { buffer in
            AudioFeatureFrame.measure(
                samples: buffer.baseAddress!,
                frameCount: frameCount,
                channelCount: 1,
                sampleRate: sampleRate
            )
        }

        #expect(frame.frameCount == 480)
        #expect(frame.channelCount == 1)
        #expect(abs(frame.peak - amplitude) < 0.01,
                "Sine peak should be ~\(amplitude), got \(frame.peak)")
        #expect(abs(frame.rms - amplitude / Float(2.0.squareRoot())) < 0.01,
                "Sine RMS should be ~amplitude/√2, got \(frame.rms)")
        // 10 cycles → ~20 crossings; sampling alignment allows ±2.
        #expect(frame.zeroCrossings >= 18 && frame.zeroCrossings <= 22,
                "1kHz over 10ms should cross ~20 times, got \(frame.zeroCrossings)")
    }

    @Test("DC signal: peak == rms == level, zero crossings == 0")
    func dcSignal() {
        let samples = [Float](repeating: 0.25, count: 256)
        let frame = samples.withUnsafeBufferPointer { buffer in
            AudioFeatureFrame.measure(
                samples: buffer.baseAddress!,
                frameCount: 256,
                channelCount: 1,
                sampleRate: 48_000
            )
        }
        #expect(abs(frame.peak - 0.25) < 1e-6)
        #expect(abs(frame.rms - 0.25) < 1e-6)
        #expect(frame.zeroCrossings == 0)
    }

    @Test("Silence: all measurements are zero")
    func silence() {
        let samples = [Float](repeating: 0, count: 128)
        let frame = samples.withUnsafeBufferPointer { buffer in
            AudioFeatureFrame.measure(
                samples: buffer.baseAddress!,
                frameCount: 128,
                channelCount: 2,
                sampleRate: 44_100
            )
        }
        #expect(frame.peak == 0)
        #expect(frame.rms == 0)
        #expect(frame.zeroCrossings == 0)
        #expect(frame.frameCount == 128)
        #expect(frame.channelCount == 2)
    }

    @Test("Stereo: peak spans both channels, crossings count the first channel only")
    func stereoChannelHandling() {
        // L = alternating ±0.1 (one crossing per frame), R = DC at 0.9.
        let frameCount = 100
        var samples = [Float](repeating: 0, count: frameCount * 2)
        for i in 0..<frameCount {
            samples[2 * i] = (i % 2 == 0) ? 0.1 : -0.1
            samples[2 * i + 1] = 0.9
        }

        let frame = samples.withUnsafeBufferPointer { buffer in
            AudioFeatureFrame.measure(
                samples: buffer.baseAddress!,
                frameCount: frameCount,
                channelCount: 2,
                sampleRate: 48_000
            )
        }

        #expect(abs(frame.peak - 0.9) < 1e-6,
                "Peak must span all channels — the loud DC right channel")
        // Alternating signs cross between every adjacent left-channel pair.
        #expect(frame.zeroCrossings >= UInt32(frameCount - 2),
                "Left channel alternates sign every frame, got \(frame.zeroCrossings) crossings")
    }

    @Test("Zero frame count yields a silent frame, not a crash")
    func zeroFrameCount() {
        let samples = [Float](repeating: 0.5, count: 4)
        let frame = samples.withUnsafeBufferPointer { buffer in
            AudioFeatureFrame.measure(
                samples: buffer.baseAddress!,
                frameCount: 0,
                channelCount: 2,
                sampleRate: 48_000
            )
        }
        #expect(frame.peak == 0)
        #expect(frame.rms == 0)
        #expect(frame.zeroCrossings == 0)
        #expect(frame.frameCount == 0)
    }

    @Test("Feature frames round-trip a PCMFeatureRing intact")
    func featureFrameThroughRing() {
        let ring = PCMFeatureRing(minimumCapacity: 8)
        let samples = [Float](repeating: 0.25, count: 64)
        let frame = samples.withUnsafeBufferPointer { buffer in
            AudioFeatureFrame.measure(
                samples: buffer.baseAddress!,
                frameCount: 64,
                channelCount: 1,
                sampleRate: 48_000
            )
        }

        #expect(ring.push(frame))
        guard let received = ring.pop() else {
            Issue.record("Ring returned nil for a pushed frame")
            return
        }
        #expect(received.peak == frame.peak)
        #expect(received.rms == frame.rms)
        #expect(received.hostTime == frame.hostTime)
        #expect(received.frameCount == 64)
    }
}
