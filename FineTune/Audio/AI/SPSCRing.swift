// FineTune/Audio/AI/SPSCRing.swift
import Foundation
import Synchronization

// MARK: - Threading Model
//
// SPSCRing is the bounded-FIFO counterpart to the "latest value" parameter
// exchange: where a parameter bus coalesces to the newest snapshot, the ring
// preserves a short ordered history so the control plane can analyze a
// window of frames, not just the most recent one.
//
// 1. **Producer (HAL I/O thread)**: push(_:) once per buffer. Wait-free:
//    one relaxed load, one acquiring load, one raw store, one releasing
//    store. When the ring is full the element is dropped and counted —
//    the producer never blocks and never overwrites unconsumed data.
//
// 2. **Consumer (control-plane thread)**: pop() drains at its own pace.
//    Wait-free by the same construction.
//
// Indices increase monotonically and are masked into the power-of-two slot
// array on access; UInt64 indices cannot meaningfully wrap. Slot contents
// are published by the release store of the index that hands them over
// (tail for push, head for pop), so neither side ever observes a partially
// written element. Elements are BitwiseCopyable and the slot storage is
// owned by the ring for its whole lifetime — nothing heap-allocated crosses
// the thread boundary, so no deferred-destruction grace period is needed.

/// Lock-free, wait-free single-producer/single-consumer bounded FIFO ring
/// for trivially copyable elements crossing the real-time boundary.
///
/// ## RT-Safety
/// `push(_:)` is RT-safe: no locks, no allocation, no ObjC, no ARC traffic.
/// `pop()` is equally cheap but belongs to the control plane by contract.
///
/// ## Contract
/// - Exactly one producer thread and one consumer thread at a time.
///   (Either role may migrate between threads as long as calls do not
///   overlap.)
/// - The ring must be kept alive (e.g. by the owning controller) until the
///   producer can no longer be invoked.
final class SPSCRing<Element: BitwiseCopyable & Sendable>: @unchecked Sendable {

    /// Number of slots. Always a power of two so index masking is a single AND.
    let capacity: Int

    private let mask: UInt64
    private let slotStride = MemoryLayout<Element>.stride

    /// Slot storage as raw bytes — `storeBytes`/`load` is the
    /// documented-correct access pattern for trivial (`BitwiseCopyable`)
    /// types regardless of slot initialization state.
    private let slotStorage: UnsafeMutableRawPointer

    /// Monotonic write index. Owned by the producer; consumer reads it to
    /// detect available elements.
    private let tail = Atomic<UInt64>(0)

    /// Monotonic read index. Owned by the consumer; producer reads it to
    /// detect free space.
    private let head = Atomic<UInt64>(0)

    /// Elements dropped because the ring was full. Producer-incremented,
    /// readable from any thread for health monitoring.
    private let dropped = Atomic<UInt64>(0)

    /// - Parameter minimumCapacity: Lower bound on slot count; rounded up to
    ///   the next power of two (minimum 2). All storage is allocated here —
    ///   never on the audio thread.
    init(minimumCapacity: Int) {
        precondition(minimumCapacity > 0, "SPSCRing capacity must be positive")
        var slots = 2
        while slots < minimumCapacity { slots <<= 1 }
        capacity = slots
        mask = UInt64(slots - 1)
        slotStorage = .allocate(
            byteCount: MemoryLayout<Element>.stride * slots,
            alignment: MemoryLayout<Element>.alignment
        )
    }

    deinit {
        // Element is BitwiseCopyable (trivial), so no per-slot
        // deinitialization is required even for slots that were written.
        slotStorage.deallocate()
    }

    // MARK: - Producer (RT-safe)

    /// Append an element, or drop it if the ring is full.
    ///
    /// RT-safe: no locks, no allocation, no ObjC, no ARC traffic. Returns
    /// `false` on drop — the producer should not retry within the same
    /// render cycle; a full ring means the consumer is behind, and the
    /// drop counter is the health signal for that.
    @discardableResult
    func push(_ element: Element) -> Bool {
        let writeIndex = tail.load(ordering: .relaxed)
        let readIndex = head.load(ordering: .acquiring)
        guard writeIndex &- readIndex < UInt64(capacity) else {
            dropped.wrappingAdd(1, ordering: .relaxed)
            return false
        }
        slotStorage.storeBytes(
            of: element,
            toByteOffset: Int(writeIndex & mask) * slotStride,
            as: Element.self
        )
        // Release pairs with the consumer's acquiring tail load: the slot
        // write above is visible before the new tail is.
        tail.store(writeIndex &+ 1, ordering: .releasing)
        return true
    }

    // MARK: - Consumer (control plane)

    /// Remove and return the oldest element, or `nil` if the ring is empty.
    func pop() -> Element? {
        let readIndex = head.load(ordering: .relaxed)
        let writeIndex = tail.load(ordering: .acquiring)
        guard readIndex != writeIndex else { return nil }
        let element = slotStorage.load(
            fromByteOffset: Int(readIndex & mask) * slotStride,
            as: Element.self
        )
        // Release pairs with the producer's acquiring head load: the slot
        // read above completes before the slot is handed back for reuse.
        head.store(readIndex &+ 1, ordering: .releasing)
        return element
    }

    // MARK: - Diagnostics

    /// Number of elements currently buffered. Approximate under concurrent
    /// access; exact when either side is quiescent.
    var approximateCount: Int {
        let writeIndex = tail.load(ordering: .relaxed)
        let readIndex = head.load(ordering: .relaxed)
        return Int(writeIndex &- readIndex)
    }

    /// Total elements dropped because the ring was full. A rising value
    /// means the consumer is not keeping up — a health-monitor signal, not
    /// an error (dropping is the designed overload behavior).
    var droppedCount: UInt64 {
        dropped.load(ordering: .relaxed)
    }

    var isEmpty: Bool { approximateCount == 0 }
}
