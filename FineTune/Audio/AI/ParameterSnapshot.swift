// FineTune/Audio/AI/ParameterSnapshot.swift
import Foundation

/// An immutable control-plane output captured at a point in time.
///
/// Snapshots are produced by asynchronous (non-realtime) inference or analysis
/// code and consumed by the HAL I/O thread through `AIParameterBus`. The
/// consumer treats the payload as a *setpoint* valid over a short horizon and
/// interpolates toward it; it never waits for a fresher one.
///
/// `Payload` must be `BitwiseCopyable` so that snapshots can live in
/// pre-allocated slots and cross the thread boundary as plain copies — no ARC
/// traffic, no deinitialization, nothing for the audio thread to free.
struct AIParameterSnapshot<Payload: BitwiseCopyable & Sendable>: BitwiseCopyable, Sendable {
    /// The control-plane parameters carried by this snapshot.
    let payload: Payload

    /// `mach_absolute_time()` at publish. Used for staleness detection.
    let hostTime: UInt64

    /// Monotonically increasing publish counter (first publish is 1).
    /// Lets the consumer distinguish "fresh data" from "same snapshot as last
    /// buffer" without comparing payloads.
    let sequence: UInt64

    /// Nanoseconds elapsed since this snapshot was published.
    ///
    /// RT-safe: pure arithmetic plus `mach_absolute_time()`. The timebase
    /// scale is forced at `AIParameterBus` init so the lazy static below is
    /// never first-touched on the audio thread.
    func nanosecondsSincePublish(asOf now: UInt64 = mach_absolute_time()) -> Double {
        Double(now &- hostTime) * Self.hostTimeNanosScale
    }

    /// Whether this snapshot is older than `seconds`.
    ///
    /// Consumers should treat stale snapshots as a signal to decay toward
    /// neutral parameters rather than as an error — the control plane is
    /// allowed to be late; audio is not.
    func isStale(after seconds: Double, asOf now: UInt64 = mach_absolute_time()) -> Bool {
        nanosecondsSincePublish(asOf: now) > seconds * 1_000_000_000.0
    }

    /// Host-tick → nanoseconds conversion factor (same derivation as
    /// `ProcessTapController.hostTimeNanosScale`).
    static var hostTimeNanosScale: Double { hostTimeNanosScaleStorage }
}

/// Computed once per process. `AIParameterBus.init` reads this so the
/// underlying `dispatch_once` never fires on the HAL I/O thread.
private let hostTimeNanosScaleStorage: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    guard info.denom != 0 else { return 1.0 }
    return Double(info.numer) / Double(info.denom)
}()
