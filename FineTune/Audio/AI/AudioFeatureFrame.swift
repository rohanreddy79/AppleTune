// FineTune/Audio/AI/AudioFeatureFrame.swift
import Accelerate
import Foundation

/// Per-buffer acoustic features extracted on the HAL I/O thread and shipped
/// to the control plane through a `PCMFeatureRing`.
///
/// Frames are deliberately tiny and `BitwiseCopyable`: the audio thread pays
/// three vDSP reductions and one ring push per buffer; everything heavier
/// (band analysis, classification, inference) happens on the control plane.
struct AudioFeatureFrame: BitwiseCopyable, Sendable {
    /// `mach_absolute_time()` when the source buffer was rendered.
    let hostTime: UInt64

    /// Sample rate of the source stream in Hz.
    let sampleRate: Double

    /// Frames (samples per channel) the measurements cover.
    let frameCount: UInt32

    /// Interleaved channel count of the source buffer.
    let channelCount: UInt32

    /// Maximum absolute sample value across all channels (linear, 0...).
    let peak: Float

    /// Root-mean-square level across all channels (linear).
    let rms: Float

    /// Zero crossings in the first channel — a stateless spectral-brightness
    /// proxy (high counts ⇒ high-frequency content) that costs one vDSP pass.
    let zeroCrossings: UInt32

    /// Measure a buffer of interleaved Float32 samples.
    ///
    /// **RT-safe**: three vDSP reductions (`vDSP_maxmgv`, `vDSP_rmsqv`,
    /// `vDSP_nzcros`), no allocation, no locks, no ObjC, no I/O. Call from
    /// the audio callback with the buffer it is already processing.
    ///
    /// - Parameters:
    ///   - samples: Interleaved Float32 samples (`frameCount × channelCount`).
    ///   - frameCount: Samples per channel. Zero yields a silent frame.
    ///   - channelCount: Interleaved channels (≥ 1).
    ///   - sampleRate: Stream sample rate in Hz.
    ///   - hostTime: Render host time; defaults to now.
    static func measure(
        samples: UnsafePointer<Float>,
        frameCount: Int,
        channelCount: Int,
        sampleRate: Double,
        hostTime: UInt64 = mach_absolute_time()
    ) -> AudioFeatureFrame {
        guard frameCount > 0, channelCount > 0 else {
            return AudioFeatureFrame(
                hostTime: hostTime,
                sampleRate: sampleRate,
                frameCount: 0,
                channelCount: UInt32(max(channelCount, 0)),
                peak: 0,
                rms: 0,
                zeroCrossings: 0
            )
        }

        let totalSamples = vDSP_Length(frameCount * channelCount)

        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, totalSamples)

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, totalSamples)

        // First channel only: crossings counted across interleaved channels
        // would mix unrelated waveforms.
        var lastCrossingIndex: vDSP_Length = 0
        var crossingCount: vDSP_Length = 0
        vDSP_nzcros(
            samples, vDSP_Stride(channelCount),
            vDSP_Length(frameCount),
            &lastCrossingIndex, &crossingCount,
            vDSP_Length(frameCount)
        )

        return AudioFeatureFrame(
            hostTime: hostTime,
            sampleRate: sampleRate,
            frameCount: UInt32(frameCount),
            channelCount: UInt32(channelCount),
            peak: peak,
            rms: rms,
            zeroCrossings: UInt32(crossingCount)
        )
    }
}

/// The ring type the audio callback publishes feature frames into
/// (blueprint Track 0: the signal→control plane boundary primitive).
typealias PCMFeatureRing = SPSCRing<AudioFeatureFrame>
