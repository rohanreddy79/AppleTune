// FineTune/Audio/AI/AIParameterBus.swift
import Foundation
import Synchronization

// MARK: - Threading Model
//
// AIParameterBus bridges the two planes of the AI pipeline:
//
// 1. **Control plane (single publisher)**: Asynchronous inference/analysis code
//    calls publish(_:) whenever it has new parameters. It may run at any
//    cadence, stall, or stop entirely.
//
// 2. **Signal plane (single consumer, HAL I/O thread)**: The audio callback
//    calls acquireLatest() once per buffer. It never blocks, never allocates,
//    and never observes a partially written snapshot.
//
// The exchange is a classic lock-free triple buffer: three pre-allocated
// slots, a writer-owned `back` index, a reader-owned `front` index, and one
// shared atomic word (`middle`) carrying a slot index plus a freshness bit.
// Publishing and acquiring are each a single atomic exchange — wait-free for
// both sides. Intermediate snapshots are dropped by design: the consumer
// wants the *latest* setpoint, not a history.
//
// Unlike BiquadProcessor.swapSetup() this needs no deferred-destruction grace
// period: payloads are BitwiseCopyable, slots are owned by the bus for its
// whole lifetime, and nothing heap-allocated ever crosses the thread
// boundary. The bus itself must outlive the last audio callback that touches
// it — same ownership rule the tap's DSP processors already follow.

/// Lock-free, wait-free single-publisher/single-consumer "latest value"
/// exchange for control-plane parameters feeding the real-time audio path.
///
/// ## RT-Safety
/// `acquireLatest()` is RT-safe: one relaxed atomic load, at most one atomic
/// exchange, and a trivial copy out of a pre-allocated slot. No locks, no
/// allocation, no ObjC, no ARC traffic.
///
/// ## Contract
/// - Exactly one publisher thread and one consumer thread at a time.
///   (Either role may migrate between threads as long as calls do not
///   overlap — the same rule the tap's primary/secondary callbacks follow.)
/// - The bus must be kept alive (e.g. by the owning controller) until the
///   consumer can no longer be invoked.
final class AIParameterBus<Payload: BitwiseCopyable & Sendable>: @unchecked Sendable {

    private typealias Snapshot = AIParameterSnapshot<Payload>

    /// Freshness flag carried in the high bit of the shared `middle` word.
    private static var freshFlag: UInt32 { 0b100 }
    private static var indexMask: UInt32 { 0b011 }

    /// Three pre-allocated snapshot slots, stored as raw bytes. A slot is only
    /// ever touched by the side that currently owns its index, so plain
    /// (non-atomic) access is safe; the release/acquire ordering on `middle`
    /// publishes slot contents. Raw storage with `storeBytes`/`load` is the
    /// documented-correct access pattern for trivial (`BitwiseCopyable`)
    /// types regardless of slot initialization state.
    private let slotStorage: UnsafeMutableRawPointer
    private let slotStride = MemoryLayout<Snapshot>.stride

    /// Shared hand-off word: slot index in the low bits, `freshFlag` set when
    /// the slot holds a snapshot the consumer has not yet acquired.
    private let middle = Atomic<UInt32>(1)

    /// Slot the publisher writes into next. Publisher thread only.
    private nonisolated(unsafe) var back: UInt32 = 0

    /// Slot holding the consumer's most recently acquired snapshot.
    /// Consumer thread only.
    private nonisolated(unsafe) var front: UInt32 = 2

    /// Whether the consumer has ever acquired a snapshot. Consumer thread only.
    /// Gates reads of the (otherwise uninitialized) `front` slot.
    private nonisolated(unsafe) var hasAcquired = false

    /// Next sequence number to assign. Publisher thread only.
    private nonisolated(unsafe) var nextSequence: UInt64 = 1

    /// Sequence of the most recent publish, for diagnostics/tests.
    /// Readable from any thread; not part of the RT consumer path.
    private let publishedSequence = Atomic<UInt64>(0)

    init() {
        slotStorage = .allocate(
            byteCount: MemoryLayout<Snapshot>.stride * 3,
            alignment: MemoryLayout<Snapshot>.alignment
        )
        // Force the timebase-scale lazy initializer now so its dispatch_once
        // can never first-fire on the HAL I/O thread.
        _ = Snapshot.hostTimeNanosScale
    }

    deinit {
        // Payload is BitwiseCopyable (trivial), so no per-slot deinitialization
        // is required even for slots that were never written.
        slotStorage.deallocate()
    }

    // MARK: - Control Plane (single publisher)

    /// Publish a new parameter snapshot, replacing any unconsumed one.
    ///
    /// Not RT-safe by contract (it is technically allocation-free, but it
    /// belongs to the control plane); call from the inference/analysis thread.
    func publish(_ payload: Payload) {
        let sequence = nextSequence
        nextSequence &+= 1

        slotStorage.storeBytes(
            of: Snapshot(payload: payload, hostTime: mach_absolute_time(), sequence: sequence),
            toByteOffset: Int(back) * slotStride,
            as: Snapshot.self
        )

        // Release ordering makes the slot write above visible to the consumer
        // before the freshness flag is observable.
        let previous = middle.exchange(back | Self.freshFlag, ordering: .acquiringAndReleasing)
        back = previous & Self.indexMask

        publishedSequence.store(sequence, ordering: .releasing)
    }

    // MARK: - Signal Plane (single consumer, RT-safe)

    /// Return the freshest available snapshot, or the previously acquired one
    /// if nothing new has been published, or `nil` before the first publish.
    ///
    /// RT-safe: no locks, no allocation, no ObjC, no ARC traffic. The returned
    /// value is a trivial copy; the consumer decides how to slew toward it and
    /// uses `isStale(after:)` to decay toward neutral when the control plane
    /// has gone quiet.
    func acquireLatest() -> AIParameterSnapshot<Payload>? {
        if middle.load(ordering: .relaxed) & Self.freshFlag != 0 {
            // Swap our spent front slot for the fresh one. Acquire ordering
            // pairs with the release in publish(_:). If the publisher races
            // us and publishes again mid-exchange, we simply receive the even
            // fresher slot — the exchange is the linearization point.
            let previous = middle.exchange(front, ordering: .acquiringAndReleasing)
            front = previous & Self.indexMask
            hasAcquired = true
        }
        guard hasAcquired else { return nil }
        return slotStorage.load(fromByteOffset: Int(front) * slotStride, as: Snapshot.self)
    }

    // MARK: - Diagnostics (non-realtime)

    /// Sequence number of the most recent publish (0 before the first).
    /// For health monitoring and tests; not for use on the audio thread.
    var lastPublishedSequence: UInt64 {
        publishedSequence.load(ordering: .acquiring)
    }
}
