// FineTuneTests/Track0EndToEndTests.swift
// End-to-end integration tests for the Track 0 dual-plane AI foundation.
//
// Exercises the complete loop with no mocks on the data path:
//
//   audio buffers → AudioFeatureFrame.measure → PCMFeatureRing
//     → InferenceCoordinator (dedicated thread) → real AIInferenceModel
//     → AIParameterBus → render-side acquisition + slew (the hook contract)
//     → processMappedBuffers → audio out reflecting the AI decision
//
// The model under test is a genuine control-plane DSP policy (loudness
// guard), not a stub: loud input must come out attenuated toward the
// target level purely through the asynchronous plane — the two sides
// never call each other directly.

import AudioToolbox
import Foundation
import Synchronization
import Testing
@testable import FineTune

// MARK: - A Real Control-Plane Model

/// Loudness guard: when recent frames run hotter than `targetRMS`, publish
/// a gain trim that brings them back to target. The first genuine
/// AIInferenceModel — pure DSP policy, no ML, which is exactly what the
/// blueprint prescribes for validating the plane separation.
private nonisolated final class LoudnessGuardModel: AIInferenceModel, Sendable {
    typealias Output = AIRenderParameters

    let targetRMS: Float
    let prepared = Atomic<Bool>(false)

    init(targetRMS: Float) {
        self.targetRMS = targetRMS
    }

    func prepare() throws {
        prepared.store(true, ordering: .releasing)
    }

    func infer(_ frames: [AudioFeatureFrame]) -> AIRenderParameters? {
        guard !frames.isEmpty else { return nil }
        var meanRMS: Float = 0
        for frame in frames { meanRMS += frame.rms }
        meanRMS /= Float(frames.count)

        guard meanRMS > 0 else { return nil }
        let trim = min(targetRMS / meanRMS, 1.0)
        return AIRenderParameters(gainTrim: max(trim, 0.05))
    }
}

// MARK: - Render-Side Helpers

/// Minimal AudioBufferList wrapper (same pattern as the other pipeline tests).
private final class E2ETestABL {
    let pointer: UnsafeMutablePointer<AudioBufferList>
    private let data: UnsafeMutablePointer<Float>
    let sampleCount: Int

    init(channels: UInt32, frames: Int) {
        sampleCount = Int(channels) * frames
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<AudioBufferList>.size,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        pointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        pointer.pointee.mNumberBuffers = 1
        data = .allocate(capacity: max(sampleCount, 1))
        data.initialize(repeating: 0, count: max(sampleCount, 1))
        UnsafeMutableAudioBufferListPointer(pointer)[0] = AudioBuffer(
            mNumberChannels: channels,
            mDataByteSize: UInt32(sampleCount * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(data)
        )
    }

    var bufferList: UnsafeMutableAudioBufferListPointer {
        UnsafeMutableAudioBufferListPointer(pointer)
    }

    var samples: UnsafeMutablePointer<Float> { data }

    func rms() -> Float {
        var sum: Float = 0
        for i in 0..<sampleCount { sum += data[i] * data[i] }
        return (sum / Float(sampleCount)).squareRoot()
    }

    isolated deinit {
        data.deallocate()
        pointer.deallocate()
    }
}

/// Fill a stereo buffer with a sine at the given amplitude.
@MainActor
private func fillSine(_ abl: E2ETestABL, amplitude: Float, frames: Int) {
    for frame in 0..<frames {
        let value = amplitude * Float(sin(2.0 * .pi * 1_000.0 * Double(frame) / 48_000.0))
        abl.samples[2 * frame] = value
        abl.samples[2 * frame + 1] = value
    }
}

/// Emulates the primary callback's hook contract: slew the current trim
/// toward the setpoint (or neutral when stale/bypassed) per buffer.
@MainActor
private func slewTrim(current: inout Float, target: Float, buffers: Int) {
    for _ in 0..<buffers {
        current += (target - current) * 0.2
    }
    if abs(current - 1.0) < 0.0001 { current = 1.0 }
}

@MainActor
private func eventually(
    seconds: TimeInterval = 5.0,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

// MARK: - End-to-End

@Suite("Track 0 — Dual-Plane End-to-End", .serialized)
struct Track0EndToEndTests {

    @Test("Loud audio in → AI attenuation decision → quieter audio out, across both planes",
          .timeLimit(.minutes(1)))
    func loudAudioGetsAttenuatedThroughTheFullChain() async {
        let frames = 480
        let loudAmplitude: Float = 0.8           // RMS ≈ 0.566
        let targetRMS: Float = 0.1

        // — The full Track 0 plumbing, exactly as production will wire it —
        let ring = PCMFeatureRing(minimumCapacity: 64)
        let bus = AIRenderParameterBus()
        let model = LoudnessGuardModel(targetRMS: targetRMS)
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
        #expect(prepared)

        // — Signal plane (emulated): buffers arrive, features go up —
        let input = E2ETestABL(channels: 2, frames: frames)
        fillSine(input, amplitude: loudAmplitude, frames: frames)
        for _ in 0..<8 {
            let frame = AudioFeatureFrame.measure(
                samples: input.samples,
                frameCount: frames,
                channelCount: 2,
                sampleRate: 48_000
            )
            ring.push(frame)
        }

        // — Control plane runs asynchronously; wait for its decision —
        let published = await eventually { coordinator.publishCount > 0 }
        #expect(published, "Coordinator never published a decision")

        // — Render side: acquire the setpoint exactly as the hook does —
        guard let snapshot = bus.acquireLatest() else {
            Issue.record("No snapshot on the bus after a recorded publish")
            coordinator.stop()
            return
        }
        let expectedTrim = targetRMS / (loudAmplitude / Float(2.0.squareRoot()))
        #expect(abs(snapshot.payload.gainTrim - expectedTrim) < 0.02,
                "Model trim \(snapshot.payload.gainTrim) should approximate \(expectedTrim)")
        #expect(!snapshot.isStale(after: 5.0))

        // — Slew toward the setpoint (the callback's per-buffer behavior) —
        var trim: Float = 1.0
        slewTrim(current: &trim, target: snapshot.payload.gainTrim, buffers: 60)
        #expect(abs(trim - snapshot.payload.gainTrim) < 0.01,
                "Slew should converge on the setpoint within 60 buffers")

        // — Process audio through the real pipeline with the AI trim —
        let output = E2ETestABL(channels: 2, frames: frames)
        var currentVol: Float = 1.0
        ProcessTapController.processMappedBuffers(
            inputBuffers: input.bufferList,
            outputBuffers: output.bufferList,
            targetVol: 1.0,
            crossfadeMultiplier: 1.0,
            outputGateMultiplier: 1.0,
            rampCoefficient: 1.0,
            preferredStereoLeft: 0,
            preferredStereoRight: 1,
            currentVol: &currentVol,
            eqProc: nil,
            autoEQProc: nil,
            loudnessEqualizerProc: nil,
            loudnessCompensatorProc: nil,
            aiGainTrim: trim
        )

        // The AI's decision, formed entirely on the other plane, landed in
        // the audio: loud input came out at (approximately) the target RMS.
        let outputRMS = output.rms()
        #expect(abs(outputRMS - targetRMS) < 0.02,
                "Output RMS \(outputRMS) should sit near the AI target \(targetRMS)")
        #expect(outputRMS < input.rms() / 3,
                "Output must be substantially attenuated versus the loud input")

        coordinator.stop()
        #expect(coordinator.state == .stopped)
    }

    @Test("Quiet audio in → unity decision → bit-exact passthrough",
          .timeLimit(.minutes(1)))
    func quietAudioPassesThroughUntouched() async {
        let frames = 480
        let quietAmplitude: Float = 0.05          // RMS ≈ 0.035, below target
        let targetRMS: Float = 0.1

        let ring = PCMFeatureRing(minimumCapacity: 64)
        let bus = AIRenderParameterBus()
        let model = LoudnessGuardModel(targetRMS: targetRMS)
        let coordinator = InferenceCoordinator(
            model: model,
            featureRing: ring,
            parameterBus: bus,
            cadence: 0.005
        )

        await coordinator.start()

        let input = E2ETestABL(channels: 2, frames: frames)
        fillSine(input, amplitude: quietAmplitude, frames: frames)
        for _ in 0..<8 {
            ring.push(AudioFeatureFrame.measure(
                samples: input.samples,
                frameCount: frames,
                channelCount: 2,
                sampleRate: 48_000
            ))
        }

        let published = await eventually { coordinator.publishCount > 0 }
        #expect(published)

        guard let snapshot = bus.acquireLatest() else {
            Issue.record("No snapshot on the bus")
            coordinator.stop()
            return
        }
        #expect(snapshot.payload.gainTrim == 1.0,
                "Below-target audio must produce a unity decision, got \(snapshot.payload.gainTrim)")

        // Unity setpoint + converged slew = the hook's bit-exact fast path.
        var trim: Float = 1.0
        slewTrim(current: &trim, target: snapshot.payload.gainTrim, buffers: 10)
        #expect(trim == 1.0)

        let output = E2ETestABL(channels: 2, frames: frames)
        var currentVol: Float = 1.0
        ProcessTapController.processMappedBuffers(
            inputBuffers: input.bufferList,
            outputBuffers: output.bufferList,
            targetVol: 1.0,
            crossfadeMultiplier: 1.0,
            outputGateMultiplier: 1.0,
            rampCoefficient: 1.0,
            preferredStereoLeft: 0,
            preferredStereoRight: 1,
            currentVol: &currentVol,
            eqProc: nil,
            autoEQProc: nil,
            loudnessEqualizerProc: nil,
            loudnessCompensatorProc: nil,
            aiGainTrim: trim
        )

        for i in 0..<output.sampleCount {
            #expect(output.samples[i] == input.samples[i],
                    "Sample \(i) changed — unity AI decision must be bit-exact")
        }

        coordinator.stop()
    }

    @Test("Stale decisions decay to neutral — the 'AI may be late' invariant",
          .timeLimit(.minutes(1)))
    func staleDecisionDecaysToNeutral() async {
        let ring = PCMFeatureRing(minimumCapacity: 16)
        let bus = AIRenderParameterBus()
        let model = LoudnessGuardModel(targetRMS: 0.1)
        let coordinator = InferenceCoordinator(
            model: model,
            featureRing: ring,
            parameterBus: bus,
            cadence: 0.005
        )

        await coordinator.start()

        let input = E2ETestABL(channels: 2, frames: 480)
        fillSine(input, amplitude: 0.8, frames: 480)
        ring.push(AudioFeatureFrame.measure(
            samples: input.samples, frameCount: 480, channelCount: 2, sampleRate: 48_000
        ))

        _ = await eventually { coordinator.publishCount > 0 }
        guard let snapshot = bus.acquireLatest() else {
            Issue.record("No snapshot on the bus")
            coordinator.stop()
            return
        }
        #expect(snapshot.payload.gainTrim < 0.5, "Loud input should yield deep attenuation")

        // Control plane dies; its last decision ages past the threshold.
        coordinator.stop()
        try? await Task.sleep(nanoseconds: 30_000_000) // 30 ms
        #expect(snapshot.isStale(after: 0.01),
                "A 30ms-old snapshot must be stale at a 10ms threshold")

        // The hook contract: stale ⇒ slew target reverts to neutral.
        var trim = snapshot.payload.gainTrim
        let target: Float = snapshot.isStale(after: 0.01) ? 1.0 : snapshot.payload.gainTrim
        slewTrim(current: &trim, target: target, buffers: 80)
        #expect(trim == 1.0,
                "Stale decision must decay to unity, got \(trim)")
    }
}
