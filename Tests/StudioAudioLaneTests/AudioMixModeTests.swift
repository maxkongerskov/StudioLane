import AVFoundation
import XCTest
@testable import StudioAudioLane

/// Pro mode used to install an audio tap that attenuated every clip (equal-power
/// center is −3 dB, and `tanh` turned the limiter into a permanent level cut).
/// Standard mode had no tap. These tests lock the mix so a mode switch, a
/// rebuild, and an export all keep the same loudness.
final class AudioMixModeTests: XCTestCase {
    @MainActor
    func testModeSwitchKeepsEffectiveAudioGain() throws {
        let model = EditorModel()
        model.isLoading = false
        XCTAssertFalse(model.isProMode)
        XCTAssertTrue(model.proSettings.limiterEnabled, "the reported bug happens with the limiter left on")

        let videoID = UUID()
        let musicID = UUID()
        let tailID = UUID()
        let musicVolume = model.musicVolume
        let videoVolume = model.videoVolume
        let playbackVolume = model.player.volume

        model.videoClips = [
            MediaClip(
                id: videoID,
                url: URL(fileURLWithPath: "/tmp/picture.mov"),
                name: "picture",
                sourceDuration: 8,
                inPoint: 0,
                timelineStart: 0,
                duration: 4,
                fadeIn: 0.25,
                fadeOut: 0.5,
                gain: 0.8,
                trackID: EditorModel.defaultVideoTrackID
            )
        ]
        model.audioClips = [
            MediaClip(
                id: musicID,
                url: URL(fileURLWithPath: "/tmp/bed.wav"),
                name: "bed",
                sourceDuration: 8,
                inPoint: 0,
                timelineStart: 0,
                duration: 4,
                fadeIn: 0.2,
                fadeOut: 0.35,
                gain: 0.5,
                trackID: EditorModel.defaultAudioTrackID
            ),
            MediaClip(
                id: tailID,
                url: URL(fileURLWithPath: "/tmp/tail.wav"),
                name: "tail",
                sourceDuration: 8,
                inPoint: 0,
                timelineStart: 6,
                duration: 2,
                fadeIn: 0,
                fadeOut: 0,
                muted: true,
                gain: 1,
                trackID: EditorModel.defaultAudioTrackID
            )
        ]
        model.isDuckingMusic = true

        let standard = model.clipAudioMixSpecs()
        model.setProMode(true)
        let pro = model.clipAudioMixSpecs()

        XCTAssertEqual(model.player.volume, playbackVolume)
        XCTAssertEqual(model.musicVolume, musicVolume)
        XCTAssertEqual(model.videoVolume, videoVolume)
        XCTAssertEqual(standard.count, 3)
        assertSameMix(standard, pro)

        let music = try XCTUnwrap(standard.first { $0.clipID == musicID })
        XCTAssertEqual(music.mixVolume, musicVolume * 0.5 * model.duckingGain, accuracy: 0.000_01)
        XCTAssertEqual(music.fadeIn, 0.2, accuracy: 0.000_01)
        XCTAssertEqual(music.fadeOut, 0.35, accuracy: 0.000_01)
        XCTAssertEqual(music.effectiveLeft, music.mixVolume, accuracy: 0.000_01)
        XCTAssertEqual(music.effectiveRight, music.mixVolume, accuracy: 0.000_01)

        let picture = try XCTUnwrap(standard.first { $0.clipID == videoID })
        XCTAssertEqual(picture.mixVolume, videoVolume * 0.8, accuracy: 0.000_01)
        XCTAssertEqual(picture.fadeIn, 0.25, accuracy: 0.000_01)
        XCTAssertEqual(picture.fadeOut, 0.5, accuracy: 0.000_01)

        let tail = try XCTUnwrap(standard.first { $0.clipID == tailID })
        XCTAssertEqual(tail.mixVolume, 0, accuracy: 0.000_01)

        guard let musicIndex = model.audioClips.firstIndex(where: { $0.id == musicID }) else {
            return XCTFail("missing music clip")
        }
        model.audioClips[musicIndex].pan = -0.55
        model.isProMode = false
        let standardPan = try XCTUnwrap(model.clipAudioMixSpecs().first { $0.clipID == musicID })
        model.isProMode = true
        let proPan = try XCTUnwrap(model.clipAudioMixSpecs().first { $0.clipID == musicID })
        XCTAssertEqual(standardPan.mixVolume, proPan.mixVolume, accuracy: 0.000_01)
        XCTAssertEqual(standardPan.fadeIn, proPan.fadeIn, accuracy: 0.000_01)
        XCTAssertEqual(standardPan.fadeOut, proPan.fadeOut, accuracy: 0.000_01)
        XCTAssertFalse(standardPan.installsProcessingTap)
        XCTAssertTrue(proPan.installsProcessingTap)
        XCTAssertEqual(standardPan.linearPower, proPan.linearPower, accuracy: 0.001)
        // Below the ceiling, constant-power pan keeps the same loudness as bypass.
        let sample: Float = 0.35
        XCTAssertEqual(
            renderedPower(sample, spec: standardPan, limit: false),
            renderedPower(sample, spec: proPan, limit: true),
            accuracy: 0.001
        )

        model.audioClips[musicIndex].pan = 0
        model.proSettings.limiterEnabled = false
        let limiterOff = model.clipAudioMixSpecs()
        model.proSettings.limiterEnabled = true
        let limiterOn = model.clipAudioMixSpecs()
        assertSameMix(limiterOff, limiterOn)

        model.setProMode(false)
        let restored = model.clipAudioMixSpecs()
        assertSameMix(standard, restored)
        XCTAssertEqual(model.player.volume, playbackVolume)
    }

    /// Rebuilds the player item the way the Pro button does, then bounces the
    /// same timeline. Centered clips (limiter on, the default) must come back
    /// at the same level in both modes, and that level is the mix volume.
    @MainActor
    func testPlaybackAndExportLoudnessMatchAcrossModes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sal-mode-gain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("tone.wav")
        try writeSine(
            to: source,
            seconds: 2,
            frequency: 440,
            amplitude: sineAmplitude,
            sampleRate: Int(sineSampleRate)
        )

        let model = EditorModel()
        model.isLoading = false
        let imported = await model.addAudioPublic(
            url: source,
            start: 0,
            ontoTrackID: EditorModel.defaultAudioTrackID
        )
        XCTAssertTrue(imported, model.errorMessage ?? "audio import failed")
        XCTAssertEqual(model.audioClips.count, 1)
        model.audioClips[0].gain = 0.75
        model.audioClips[0].fadeIn = 0.4
        model.audioClips[0].fadeOut = 0.4
        model.audioClips[0].pan = 0
        model.applyFadesPublic(refreshingVideo: false)
        XCTAssertTrue(model.proSettings.limiterEnabled)
        XCTAssertFalse(model.isProMode)

        let playbackVolume = model.player.volume
        let standardSpec = try XCTUnwrap(model.clipAudioMixSpecs().first)
        try assertPlayerMix(model, matches: standardSpec)
        let standardRMS = try await exportSustainRMS(
            model,
            to: directory.appendingPathComponent("standard.wav"),
            spec: standardSpec
        )

        model.setProMode(true)
        await model.rebuildCompositionPublic()
        XCTAssertTrue(model.isProMode)
        XCTAssertEqual(model.player.volume, playbackVolume)
        let proSpec = try XCTUnwrap(model.clipAudioMixSpecs().first)
        XCTAssertEqual(proSpec.mixVolume, standardSpec.mixVolume, accuracy: 0.000_01)
        XCTAssertEqual(proSpec.effectiveLeft, standardSpec.effectiveLeft, accuracy: 0.000_01)
        XCTAssertEqual(proSpec.effectiveRight, standardSpec.effectiveRight, accuracy: 0.000_01)
        XCTAssertEqual(proSpec.fadeIn, standardSpec.fadeIn, accuracy: 0.000_01)
        XCTAssertEqual(proSpec.fadeOut, standardSpec.fadeOut, accuracy: 0.000_01)
        XCTAssertFalse(proSpec.installsProcessingTap)
        try assertPlayerMix(model, matches: proSpec)
        let proRMS = try await exportSustainRMS(
            model,
            to: directory.appendingPathComponent("pro.wav"),
            spec: proSpec
        )

        XCTAssertEqual(proRMS, standardRMS, accuracy: max(0.004, standardRMS * 0.03))
        let expected = Double(standardSpec.mixVolume) * sineAmplitude / 2.squareRoot()
        XCTAssertEqual(
            standardRMS,
            expected,
            accuracy: max(0.012, expected * 0.08),
            "export loudness should be the mix volume, same level playback uses"
        )

        model.setProMode(false)
        await model.rebuildCompositionPublic()
        XCTAssertEqual(model.player.volume, playbackVolume)
        let restored = try XCTUnwrap(model.clipAudioMixSpecs().first)
        XCTAssertEqual(restored.mixVolume, standardSpec.mixVolume, accuracy: 0.000_01)
        XCTAssertEqual(restored.effectiveLeft, standardSpec.effectiveLeft, accuracy: 0.000_01)
        XCTAssertEqual(restored.effectiveRight, standardSpec.effectiveRight, accuracy: 0.000_01)
        XCTAssertFalse(restored.installsProcessingTap)
        try assertPlayerMix(model, matches: restored)
    }

    @MainActor
    private func assertSameMix(
        _ standard: [ClipAudioMixSpec],
        _ other: [ClipAudioMixSpec],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(standard.count, other.count, file: file, line: line)
        for (left, right) in zip(standard, other) {
            XCTAssertEqual(left.clipID, right.clipID, file: file, line: line)
            XCTAssertEqual(left.mixVolume, right.mixVolume, accuracy: 0.000_01, file: file, line: line)
            XCTAssertEqual(left.fadeIn, right.fadeIn, accuracy: 0.000_01, file: file, line: line)
            XCTAssertEqual(left.fadeOut, right.fadeOut, accuracy: 0.000_01, file: file, line: line)
            XCTAssertEqual(left.effectiveLeft, right.effectiveLeft, accuracy: 0.000_01, file: file, line: line)
            XCTAssertEqual(left.effectiveRight, right.effectiveRight, accuracy: 0.000_01, file: file, line: line)
            XCTAssertEqual(left.linearPower, right.linearPower, accuracy: 0.000_1, file: file, line: line)
            XCTAssertFalse(left.installsProcessingTap, file: file, line: line)
            XCTAssertFalse(right.installsProcessingTap, file: file, line: line)
        }
    }

    @MainActor
    private func assertPlayerMix(
        _ model: EditorModel,
        matches spec: ClipAudioMixSpec,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let mix = try XCTUnwrap(model.player.currentItem?.audioMix, file: file, line: line)
        XCTAssertEqual(mix.inputParameters.count, 1, file: file, line: line)
        XCTAssertFalse(
            processingTapInstalled(mix),
            "centered audio must not install a processing tap",
            file: file,
            line: line
        )
        let fadeIn = try XCTUnwrap(
            volumeRamp(in: mix, at: spec.timelineStart + spec.fadeIn / 2),
            "missing fade-in ramp",
            file: file,
            line: line
        )
        XCTAssertEqual(fadeIn.start, 0, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(fadeIn.end, spec.mixVolume, accuracy: 0.001, file: file, line: line)

        let fadeOut = try XCTUnwrap(
            volumeRamp(in: mix, at: spec.timelineStart + spec.duration - spec.fadeOut / 2),
            "missing fade-out ramp",
            file: file,
            line: line
        )
        XCTAssertEqual(fadeOut.start, spec.mixVolume, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(fadeOut.end, 0, accuracy: 0.001, file: file, line: line)
    }

    @MainActor
    private func exportSustainRMS(
        _ model: EditorModel,
        to url: URL,
        spec: ClipAudioMixSpec,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Double {
        var settings = ExportSettings()
        settings.mode = .audio
        settings.audioFormat = .wav
        settings.audioSampleRateHertz = Int(sineSampleRate)
        settings.pcmBitDepth = 24
        settings.sanitize()
        XCTAssertTrue(
            model.beginExportDirect(settings: settings, destination: url),
            model.errorMessage ?? "export did not start",
            file: file,
            line: line
        )
        let failure = await waitForExport(model)
        XCTAssertNil(failure, failure ?? "", file: file, line: line)
        let sustainStart = spec.timelineStart + spec.fadeIn + 0.08
        let sustainEnd = spec.timelineStart + spec.duration - spec.fadeOut - 0.08
        XCTAssertGreaterThan(sustainEnd, sustainStart, file: file, line: line)
        return try rootMeanSquare(in: url, from: sustainStart, to: sustainEnd)
    }

    @MainActor
    private func waitForExport(_ model: EditorModel, timeout: TimeInterval = 20) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while model.isExporting, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if model.isExporting { return "export timed out" }
        return model.errorMessage
    }
}

private let sineAmplitude: Double = 0.5
private let sineSampleRate: Double = 48_000

private func renderedPower(_ sample: Float, spec: ClipAudioMixSpec, limit: Bool) -> Float {
    let applyLimit = limit && spec.installsProcessingTap
    let left = ProFeatureMath.processedSample(sample, channelGain: spec.tapLeft, limiterEnabled: applyLimit)
    let right = ProFeatureMath.processedSample(sample, channelGain: spec.tapRight, limiterEnabled: applyLimit)
    let mixedLeft = left * spec.mixVolume
    let mixedRight = right * spec.mixVolume
    return mixedLeft * mixedLeft + mixedRight * mixedRight
}

private struct VolumeRamp {
    var start: Float
    var end: Float
}

private func processingTapInstalled(_ mix: AVAudioMix) -> Bool {
    mix.inputParameters.contains { $0.audioTapProcessor != nil }
}

private func volumeRamp(in mix: AVAudioMix, at seconds: Double) -> VolumeRamp? {
    guard let parameters = mix.inputParameters.first else { return nil }
    var start: Float = 0
    var end: Float = 0
    var range = CMTimeRange()
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    guard parameters.getVolumeRamp(
        for: time,
        startVolume: &start,
        endVolume: &end,
        timeRange: &range
    ) else { return nil }
    return VolumeRamp(start: start, end: end)
}

private func writeSine(
    to url: URL,
    seconds: Double,
    frequency: Double,
    amplitude: Double,
    sampleRate: Int
) throws {
    let channels = 2
    let frameCount = Int(seconds * Double(sampleRate))
    let dataSize = frameCount * channels * 2

    var data = Data()
    func ascii(_ text: String) { data.append(contentsOf: text.utf8) }
    func u32(_ value: UInt32) {
        var le = value.littleEndian
        data.append(Data(bytes: &le, count: 4))
    }
    func u16(_ value: UInt16) {
        var le = value.littleEndian
        data.append(Data(bytes: &le, count: 2))
    }

    ascii("RIFF"); u32(UInt32(36 + dataSize)); ascii("WAVE")
    ascii("fmt "); u32(16); u16(1); u16(UInt16(channels))
    u32(UInt32(sampleRate)); u32(UInt32(sampleRate * channels * 2))
    u16(UInt16(channels * 2)); u16(16)
    ascii("data"); u32(UInt32(dataSize))

    var samples = [Int16]()
    samples.reserveCapacity(frameCount * channels)
    for frame in 0..<frameCount {
        let value = Int16(
            amplitude * Double(Int16.max) * sin(2 * Double.pi * frequency * Double(frame) / Double(sampleRate))
        )
        for _ in 0..<channels { samples.append(value.littleEndian) }
    }
    samples.withUnsafeBytes { data.append(contentsOf: $0) }
    try data.write(to: url, options: .atomic)
}

private func rootMeanSquare(in url: URL, from start: Double, to end: Double) throws -> Double {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    guard let channels = buffer.floatChannelData else { return 0 }
    let channelCount = Int(format.channelCount)
    let first = Int(start * format.sampleRate)
    let last = min(Int(end * format.sampleRate), Int(buffer.frameLength))
    guard last > first, channelCount > 0 else { return 0 }
    var sum: Float = 0
    for channel in 0..<channelCount {
        for frame in first..<last {
            let sample = channels[channel][frame]
            sum += sample * sample
        }
    }
    return Double(sqrt(sum / Float((last - first) * channelCount)))
}
