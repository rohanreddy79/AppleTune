// FineTuneTests/AIPipelineHookTests.swift
// Tests for the AI hook in ProcessTapController.processMappedBuffers():
// the control-plane gain trim applied between per-app EQ and AutoEQ.
// Targets: unity bit-exactness (the off state must be a no-op), trim
// scaling across channel layouts, pre-limiter ordering, clamping at the
// acquisition site contract, and the AIRenderParameters identity element.

import AudioToolbox
import Foundation
import Testing
@testable import FineTune

// MARK: - Test Helpers

/// Minimal AudioBufferList wrapper for driving processMappedBuffers.
/// Same construction pattern as ProcessingPipelineTests' helper.
private final class HookTestABL {
    let pointer: UnsafeMutablePointer<AudioBufferList>
    private var dataPointers: [UnsafeMutablePointer<Float>] = []

    init(channels: UInt32, frames: Int) {
        let sampleCount = Int(channels) * frames
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<AudioBufferList>.size,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        pointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        pointer.pointee.mNumberBuffers = 1

        let data = UnsafeMutablePointer<Float>.allocate(capacity: max(sampleCount, 1))
        data.initialize(repeating: 0, count: max(sampleCount, 1))
        dataPointers.append(data)

        let ablp = UnsafeMutableAudioBufferListPointer(pointer)
        ablp[0] = AudioBuffer(
            mNumberChannels: channels,
            mDataByteSize: UInt32(sampleCount * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(data)
        )
    }

    var bufferList: UnsafeMutableAudioBufferListPointer {
        UnsafeMutableAudioBufferListPointer(pointer)
    }

    var data: UnsafeMutablePointer<Float> { dataPointers[0] }

    var sampleCount: Int {
        Int(bufferList[0].mDataByteSize) / MemoryLayout<Float>.size
    }

    func fill(_ value: Float) {
        for i in 0..<sampleCount { data[i] = value }
    }

    isolated deinit {
        for p in dataPointers { p.deallocate() }
        pointer.deallocate()
    }
}

/// Run the pipeline with a converged unity volume ramp so the only gain
/// in play is the AI trim under test.
private func runPipeline(
    input: HookTestABL,
    output: HookTestABL,
    aiGainTrim: Float? = nil
) {
    var currentVol: Float = 1.0
    if let trim = aiGainTrim {
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
    } else {
        // Exercises the defaulted parameter — existing call sites compile
        // and behave identically without naming the hook.
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
            loudnessCompensatorProc: nil
        )
    }
}

// MARK: - Hook Behavior

@Suite("AI Pipeline Hook — Gain Trim")
struct AIPipelineHookTests {

    @Test("Unity trim is bit-exact with the defaulted (hook-less) call")
    func unityTrimIsBitExact() {
        let frames = 256
        let input = HookTestABL(channels: 2, frames: frames)
        input.fill(0.37)

        let outputDefault = HookTestABL(channels: 2, frames: frames)
        runPipeline(input: input, output: outputDefault)

        let outputUnity = HookTestABL(channels: 2, frames: frames)
        runPipeline(input: input, output: outputUnity, aiGainTrim: 1.0)

        for i in 0..<outputDefault.sampleCount {
            #expect(outputDefault.data[i] == outputUnity.data[i],
                    "Sample \(i) differs: unity trim must be a bit-exact no-op")
        }
        #expect(outputDefault.data[0] == 0.37, "Passthrough at unity volume must preserve samples")
    }

    @Test("Trim scales stereo output linearly", arguments: [Float(0.5), 0.25, 2.0])
    func trimScalesStereo(trim: Float) {
        let frames = 128
        let level: Float = 0.2
        let input = HookTestABL(channels: 2, frames: frames)
        input.fill(level)
        let output = HookTestABL(channels: 2, frames: frames)

        runPipeline(input: input, output: output, aiGainTrim: trim)

        let expected = level * trim
        for i in 0..<output.sampleCount {
            #expect(abs(output.data[i] - expected) < 1e-6,
                    "Sample \(i): expected \(expected), got \(output.data[i])")
        }
    }

    @Test("Trim applies to mono buffers, unlike the stereo-only biquad stages")
    func trimAppliesToMono() {
        let frames = 64
        let input = HookTestABL(channels: 1, frames: frames)
        input.fill(0.4)
        let output = HookTestABL(channels: 1, frames: frames)

        runPipeline(input: input, output: output, aiGainTrim: 0.5)

        for i in 0..<output.sampleCount {
            #expect(abs(output.data[i] - 0.2) < 1e-6)
        }
    }

    @Test("Trim is applied before the soft limiter — boosted output stays under ceiling")
    func trimRunsBeforeLimiter() {
        let frames = 128
        let input = HookTestABL(channels: 2, frames: frames)
        input.fill(0.6)
        let output = HookTestABL(channels: 2, frames: frames)

        // 0.6 × 4.0 = 2.4 pre-limiter; the limiter must bring it under 1.0.
        runPipeline(input: input, output: output, aiGainTrim: 4.0)

        for i in 0..<output.sampleCount {
            #expect(output.data[i] <= 1.0,
                    "Sample \(i) = \(output.data[i]) exceeds the limiter ceiling — trim must run pre-limiter")
            #expect(output.data[i] > 0.9,
                    "Sample \(i) = \(output.data[i]) — heavy boost should land near the ceiling, not collapse")
        }
    }

    @Test("Zero trim silences output without affecting buffer sizing")
    func zeroTrimSilences() {
        let frames = 64
        let input = HookTestABL(channels: 2, frames: frames)
        input.fill(0.8)
        let output = HookTestABL(channels: 2, frames: frames)

        runPipeline(input: input, output: output, aiGainTrim: 0.0)

        for i in 0..<output.sampleCount {
            #expect(output.data[i] == 0.0)
        }
    }
}

// MARK: - Parameter Payload

@Suite("AIRenderParameters")
struct AIRenderParametersTests {

    @Test("Neutral is the identity element")
    func neutralIsIdentity() {
        #expect(AIRenderParameters.neutral.gainTrim == 1.0)
    }

    @Test("Payload round-trips an AIRenderParameterBus intact")
    func roundTripsBus() {
        let bus = AIRenderParameterBus()
        bus.publish(AIRenderParameters(gainTrim: 0.75))
        guard let snapshot = bus.acquireLatest() else {
            Issue.record("Bus returned nil for a published payload")
            return
        }
        #expect(snapshot.payload.gainTrim == 0.75)
        #expect(snapshot.sequence == 1)
    }
}
