import AVFoundation
import CoreVideo
import XCTest
@testable import StudioAudioLane

/// Offline mixdown (`performAudioExport`) round-trips: build a tiny two-track
/// composition with a muted track, bounce it, read the file back and listen
/// numerically.
final class AudioExportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sal-audio-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Settings

    func testAudioModeSettings() {
        var settings = ExportSettings()
        settings.mode = .audio
        settings.fileBaseName = "bounce.wav"
        settings.sanitize()
        XCTAssertEqual(settings.fileBaseName, "bounce")
        XCTAssertEqual(settings.pathExtension, "wav")
        XCTAssertEqual(settings.contentType, .wav)
        XCTAssertEqual(settings.audioSampleRateHertz, 48_000)

        settings.audioFormat = .aac
        settings.sanitize()
        XCTAssertEqual(settings.pathExtension, "m4a")

        settings.audioSampleRateHertz = 12_345
        settings.pcmBitDepth = 33
        settings.sanitize()
        XCTAssertEqual(settings.audioSampleRateHertz, 48_000)
        XCTAssertEqual(settings.pcmBitDepth, 24)
    }

    // MARK: - FFmpeg bridge: settings & detection

    func testFFmpegFormatSettings() {
        XCTAssertEqual(ExportSettings.AudioFormat.mp3.pathExtension, "mp3")
        XCTAssertEqual(ExportSettings.AudioFormat.ogg.pathExtension, "ogg")
        XCTAssertEqual(ExportSettings.AudioFormat.opus.pathExtension, "opus")
        XCTAssertTrue(ExportSettings.AudioFormat.mp3.isFFmpeg)
        XCTAssertTrue(ExportSettings.AudioFormat.ogg.isFFmpeg)
        XCTAssertTrue(ExportSettings.AudioFormat.opus.isFFmpeg)
        XCTAssertFalse(ExportSettings.AudioFormat.flac.isFFmpeg)
        XCTAssertTrue(ExportSettings.AudioFormat.opus.isLossy)
        XCTAssertFalse(ExportSettings.AudioFormat.opus.isLossless)
        XCTAssertFalse(ExportSettings.AudioFormat.wav.isLossy)

        var settings = ExportSettings()
        settings.mode = .audio
        settings.audioFormat = .mp3
        settings.sanitize()
        XCTAssertEqual(settings.pathExtension, "mp3")
        XCTAssertEqual(settings.contentType, .mp3)
        XCTAssertEqual(settings.audioFormat.ffmpegEncodeArguments(bitRate: 192_000),
                       ["-codec:a", "libmp3lame", "-b:a", "192k"])
        settings.audioFormat = .opus
        settings.sanitize()
        XCTAssertEqual(settings.pathExtension, "opus")
        XCTAssertTrue(settings.audioFormat.ffmpegEncodeArguments(bitRate: 128_000)
            .contains("libopus"))

        settings.fileBaseName = "bounce.mp3"
        settings.sanitize()
        XCTAssertEqual(settings.fileBaseName, "bounce")

        // The picker hides the three lossy extras without ffmpeg.
        XCTAssertEqual(ExportSettings.AudioFormat.available(ffmpegAvailable: false),
                       [.wav, .aiff, .flac, .alac, .aac])
        XCTAssertEqual(ExportSettings.AudioFormat.available(ffmpegAvailable: true).count,
                       ExportSettings.AudioFormat.allCases.count)
    }

    func testFFmpegDetectionScansSearchPaths() throws {
        let bin = directory.appendingPathComponent("fake-bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let missingDir = directory.appendingPathComponent("empty-bin")
        try FileManager.default.createDirectory(at: missingDir, withIntermediateDirectories: true)

        // Nothing executable named ffmpeg anywhere in the list → nil.
        XCTAssertNil(FFmpegBridge.detect(searchPaths: [
            missingDir.path, "/nonexistent-directory-for-sal-tests", directory.path
        ]))

        let fake = bin.appendingPathComponent("ffmpeg")
        FileManager.default.createFile(
            atPath: fake.path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )
        XCTAssertEqual(
            FFmpegBridge.detect(searchPaths: [missingDir.path, bin.path])?.path,
            fake.path
        )

        // A non-executable stub must not count as a detection.
        let stub = missingDir.appendingPathComponent("ffmpeg")
        try Data("not executable".utf8).write(to: stub)
        XCTAssertNil(FFmpegBridge.detect(searchPaths: [missingDir.path]))
    }

    func testNativeRendererRejectsFFmpegFormats() async throws {
        let (asset, audioMix) = try await makeTwoTrackMix()
        do {
            try await EditorModel.performAudioExport(
                asset: asset,
                destination: directory.appendingPathComponent("bounce.mp3"),
                format: .mp3,
                sampleRate: 44_100,
                bitDepth: 24,
                aacBitRate: 192_000,
                duration: 2.5,
                audioMix: audioMix,
                isCancelled: { false },
                onProgress: { _ in }
            )
            XCTFail("performAudioExport must not encode MP3 natively")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "StudioAudioLane")
            XCTAssertTrue(error.localizedDescription.contains("FFmpeg"),
                          "error should point at the FFmpeg bridge: \(error.localizedDescription)")
        }
    }

    func testFFmpegConversionProducesPlayableFiles() async throws {
        guard let ffmpeg = FFmpegBridge.detect() else {
            throw XCTSkip("ffmpeg is not installed on this machine — skipping FFmpeg conversion test")
        }
        for format in [ExportSettings.AudioFormat.mp3, .ogg, .opus] {
            let (asset, audioMix) = try await makeTwoTrackMix()
            let wav = directory.appendingPathComponent("in-\(format.rawValue).wav")
            try await EditorModel.performAudioExport(
                asset: asset,
                destination: wav,
                format: .wav,
                sampleRate: 44_100,
                bitDepth: 24,
                aacBitRate: 192_000,
                duration: 2.5,
                audioMix: audioMix,
                isCancelled: { false },
                onProgress: { _ in }
            )

            let encoded = directory
                .appendingPathComponent("bounce-\(format.rawValue)")
                .appendingPathExtension(format.pathExtension)
            try await EditorModel.performFFmpegAudioConversion(
                sourceWAV: wav,
                destination: encoded,
                format: format,
                bitRate: 192_000,
                isCancelled: { false }
            )
            let bytes = (try FileManager.default.attributesOfItem(atPath: encoded.path)[.size] as? NSNumber)?.intValue ?? 0
            XCTAssertGreaterThan(bytes, 1_024, "\(format.rawValue) produced a truncated file")

            // Decode back through ffmpeg and listen numerically: 0.5–1.0 s is
            // the unmuted 440 Hz tone, 2.3–2.4 s stays after tone A ends and
            // the muted tone B — it must remain (near) silence.
            let decoded = directory.appendingPathComponent("decoded-\(format.rawValue).wav")
            try await EditorModel.runFFmpeg(
                executable: ffmpeg,
                arguments: ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", encoded.path, decoded.path],
                outputURL: decoded,
                isCancelled: { false }
            )
            XCTAssertGreaterThan(try rms(in: decoded, from: 0.5, to: 1.0), 0.05,
                                 "\(format.rawValue) lost the audible content")
            XCTAssertLessThan(try rms(in: decoded, from: 2.3, to: 2.4), 0.01,
                              "\(format.rawValue) noise-filled the silent tail")
        }
    }

    func testFFmpegConversionHonoursCancellation() async throws {
        guard let ffmpeg = FFmpegBridge.detect() else {
            throw XCTSkip("ffmpeg is not installed on this machine — skipping cancellation test")
        }
        // -re pumps a 10 s WAV in real time, so the run lasts long enough for
        // the cancel flag (set after 0.4 s) to fire mid-encode.
        let wav = directory.appendingPathComponent("cancel-feed.wav")
        try writeSine(to: wav, seconds: 10, frequency: 220)
        let started = Date()
        do {
            try await EditorModel.runFFmpeg(
                executable: ffmpeg,
                arguments: [
                    "-hide_banner", "-loglevel", "error", "-nostdin",
                    "-re", "-i", wav.path, "-f", "null", "-",
                ],
                isCancelled: { Date().timeIntervalSince(started) > 0.4 }
            )
            XCTFail("runFFmpeg should have thrown CancellationError")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                              "cancellation must terminate ffmpeg promptly")
        }
    }

    // MARK: - Render

    func testAudioExportRendersMixedTimeline() async throws {
        let (asset, audioMix) = try await makeTwoTrackMix()
        let destination = directory.appendingPathComponent("bounce.wav")

        try await EditorModel.performAudioExport(
            asset: asset,
            destination: destination,
            format: .wav,
            sampleRate: 44_100,
            bitDepth: 24,
            aacBitRate: 192_000,
            duration: 2.5,
            audioMix: audioMix,
            isCancelled: { false },
            onProgress: { _ in }
        )

        let file = try AVAudioFile(forReading: destination)
        XCTAssertEqual(file.processingFormat.sampleRate, 44_100, accuracy: 1)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        XCTAssertEqual(duration, 2.5, accuracy: 0.1, "export must cover the full timeline")

        // 0.5–1.0 s: track A (440 Hz) alone.
        XCTAssertGreaterThan(try rms(in: destination, from: 0.5, to: 1.0), 0.05)
        // 1.7–2.2 s: both tracks overlap, but B is muted by the audio mix.
        // 2.2–2.4 s: A has ended and B stays muted — must be digital silence.
        XCTAssertLessThan(try rms(in: destination, from: 2.2, to: 2.4), 1e-6,
                          "muted track and trailing range must render silent")
    }

    func testAudioExportEncodesCompressedFormats() async throws {
        for format in [ExportSettings.AudioFormat.flac, .alac, .aac] {
            let (asset, audioMix) = try await makeTwoTrackMix()
            let destination = directory.appendingPathComponent("bounce-\(format.rawValue).\(format.pathExtension)")

            try await EditorModel.performAudioExport(
                asset: asset,
                destination: destination,
                format: format,
                sampleRate: 44_100,
                bitDepth: 24,
                aacBitRate: 192_000,
                duration: 2.5,
                audioMix: audioMix,
                isCancelled: { false },
                onProgress: { _ in }
            )

            let bytes = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0
            XCTAssertGreaterThan(bytes, 1_024, "\(format.rawValue) produced a truncated file")

            let file = try AVAudioFile(forReading: destination)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            XCTAssertEqual(duration, 2.5, accuracy: 0.15, "\(format.rawValue) duration drifted")
            XCTAssertGreaterThan(try rms(in: destination, from: 0.5, to: 1.0), 0.05,
                                 "\(format.rawValue) lost the audible content")
        }
    }

    // MARK: - Audio-only timeline

    /// The Export action must turn on for a playlist that has sound and no picture,
    /// and a video container choice must become an audio mixdown instead of a
    /// video encode that has nothing to write.
    @MainActor
    func testAudioOnlyTimelineEnablesExportAndRewritesVideoSettings() {
        let model = EditorModel()
        XCTAssertFalse(model.canExport)
        model.presentExportSheet()
        XCTAssertFalse(model.isExportSheetPresented)

        model.audioClips = [placeholderClip(name: "voice")]
        XCTAssertFalse(model.hasVideo)
        XCTAssertTrue(model.hasMusic)
        XCTAssertTrue(model.canExport)
        XCTAssertEqual(model.clipName, "voice")
        model.presentExportSheet()
        XCTAssertTrue(model.isExportSheetPresented)

        var video = ExportSettings()
        video.mode = .video
        video.container = .mp4
        let adjusted = model.settingsAdjustedForTimeline(video)
        XCTAssertEqual(adjusted.mode, .audio)
        XCTAssertEqual(adjusted.pathExtension, "wav")
        let rewritten = model.resolvedExportURL(
            URL(fileURLWithPath: "/tmp/mix.mp4"),
            settings: adjusted
        )
        XCTAssertEqual(rewritten.pathExtension, "wav")

        model.isExporting = true
        XCTAssertFalse(model.canExport, "export stays disabled while an encode is running")
        model.isExporting = false

        model.videoClips = [placeholderClip(name: "picture")]
        var kept = ExportSettings()
        kept.mode = .video
        kept.container = .mov
        let stillVideo = model.settingsAdjustedForTimeline(kept)
        XCTAssertEqual(stillVideo.mode, .video)
        XCTAssertEqual(stillVideo.pathExtension, "mov")
    }

    @MainActor
    func testAudioOnlyPlaylistExportsPlayableWAV() async throws {
        let source = directory.appendingPathComponent("voice.wav")
        try writeSine(to: source, seconds: 1.0, frequency: 440)

        let model = EditorModel()
        let added = await model.addAudioPublic(
            url: source,
            start: nil,
            ontoTrackID: EditorModel.defaultAudioTrackID
        )
        XCTAssertTrue(added, model.errorMessage ?? "audio import failed")
        XCTAssertTrue(model.audioClips.count == 1)
        XCTAssertTrue(model.videoClips.isEmpty)
        XCTAssertTrue(model.canExport)

        let item = try XCTUnwrap(model.player.currentItem, "audio-only timeline produced no player item")
        let videos = try await item.asset.loadTracks(withMediaType: .video)
        let audios = try await item.asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(videos.isEmpty, "an empty video track makes the audio asset unreadable")
        XCTAssertFalse(audios.isEmpty)

        var settings = ExportSettings()
        settings.mode = .audio
        settings.audioFormat = .wav
        settings.audioSampleRateHertz = 44_100
        let destination = directory.appendingPathComponent("audio-only.wav")
        XCTAssertTrue(model.beginExportDirect(settings: settings, destination: destination))
        let failure = await waitForExport(model)
        XCTAssertNil(failure)
        XCTAssertGreaterThan(try rms(in: destination, from: 0.2, to: 0.8), 0.05)
    }

    @MainActor
    func testVideoContainerOnAudioOnlyTimelineWritesAudio() async throws {
        let source = directory.appendingPathComponent("voice.wav")
        try writeSine(to: source, seconds: 1.0, frequency: 440)
        let model = EditorModel()
        let added = await model.addAudioPublic(
            url: source,
            start: nil,
            ontoTrackID: EditorModel.defaultAudioTrackID
        )
        XCTAssertTrue(added, model.errorMessage ?? "audio import failed")

        var settings = ExportSettings()
        settings.mode = .video
        settings.container = .mp4
        let requested = directory.appendingPathComponent("from-video.mp4")
        let expected = model.preparedExport(settings: settings, destination: requested).destination
        XCTAssertEqual(expected.pathExtension, "wav")
        XCTAssertTrue(model.beginExportDirect(settings: settings, destination: requested))
        let failure = await waitForExport(model)
        XCTAssertNil(failure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: requested.path))
        XCTAssertGreaterThan(try rms(in: expected, from: 0.2, to: 0.8), 0.05)
    }

    @MainActor
    func testMixedTimelineKeepsVideoTrackAndVideoExport() async throws {
        let videoURL = directory.appendingPathComponent("clip.mov")
        let audioURL = directory.appendingPathComponent("bed.wav")
        try writeVideo(to: videoURL, frames: 10)
        try writeSine(to: audioURL, seconds: 0.6, frequency: 440)

        let model = EditorModel()
        let videoOK = await model.addVideoPublic(
            url: videoURL,
            start: nil,
            ontoTrackID: EditorModel.defaultVideoTrackID
        )
        XCTAssertTrue(videoOK, model.errorMessage ?? "video import failed")
        let audioOK = await model.addAudioPublic(
            url: audioURL,
            start: nil,
            ontoTrackID: EditorModel.defaultAudioTrackID
        )
        XCTAssertTrue(audioOK, model.errorMessage ?? "audio import failed")
        XCTAssertTrue(model.canExport)

        let asset = try XCTUnwrap(model.player.currentItem?.asset)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(videos.isEmpty, "a picture clip must still land on a video track")
        let videoDuration = try await videos[0].load(.timeRange).duration.seconds
        XCTAssertGreaterThan(videoDuration, 0.1)
        XCTAssertFalse(audios.isEmpty)

        var settings = ExportSettings()
        settings.mode = .video
        settings.container = .mp4
        let adjusted = model.settingsAdjustedForTimeline(settings)
        XCTAssertEqual(adjusted.mode, .video)
        XCTAssertEqual(adjusted.pathExtension, "mp4")
    }

    // MARK: - Fixtures

    /// A: 440 Hz sine covering 0–2 s, unmuted.
    /// B: 880 Hz sine at 1.5–2.5 s, muted through the returned audio mix.
    private func makeTwoTrackMix() async throws -> (AVAsset, AVAudioMix) {
        let urlA = directory.appendingPathComponent("sine-a.wav")
        let urlB = directory.appendingPathComponent("sine-b.wav")
        try writeSine(to: urlA, seconds: 2.0, frequency: 440)
        try writeSine(to: urlB, seconds: 1.0, frequency: 880)

        let composition = AVMutableComposition()
        guard let trackA = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ), let trackB = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(domain: "test", code: 1, userInfo: nil)
        }
        // The source assets must outlive the insertions; tracks of a
        // deallocated asset make insertTimeRange throw -11800/-12780.
        let sourceA = AVURLAsset(url: urlA)
        let sourceB = AVURLAsset(url: urlB)
        let clipA = try await sourceA.loadTracks(withMediaType: .audio).first
        let clipB = try await sourceB.loadTracks(withMediaType: .audio).first
        guard let clipA, let clipB else {
            throw NSError(domain: "test", code: 1, userInfo: nil)
        }
        try trackA.insertTimeRange(
            CMTimeRange(start: .zero, duration: CMTime(seconds: 2.0, preferredTimescale: 600)),
            of: clipA, at: .zero
        )
        try trackB.insertTimeRange(
            CMTimeRange(start: .zero, duration: CMTime(seconds: 1.0, preferredTimescale: 600)),
            of: clipB, at: CMTime(seconds: 1.5, preferredTimescale: 600)
        )

        let mix = AVMutableAudioMix()
        let paramsB = AVMutableAudioMixInputParameters(track: trackB)
        paramsB.setVolume(0, at: .zero)
        mix.inputParameters = [paramsB]
        return (composition, mix)
    }

    /// `EditorModel` is `@MainActor`, so its default track ids are isolated too.
    @MainActor
    private func placeholderClip(name: String, duration: TimeInterval = 1) -> MediaClip {
        MediaClip(
            id: UUID(),
            url: URL(fileURLWithPath: "/tmp/\(name).wav"),
            name: name,
            sourceDuration: duration,
            inPoint: 0,
            timelineStart: 0,
            duration: duration,
            fadeIn: 0,
            fadeOut: 0,
            trackID: EditorModel.defaultAudioTrackID
        )
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

    /// Hand-rolled 16-bit PCM WAV bytes — deterministic, no encoder in the
    /// fixture path.
    private func writeSine(to url: URL, seconds: Double, frequency: Double) throws {
        let sampleRate = 44_100
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
            let value = Int16(0.4 * Double(Int16.max) * sin(2 * Double.pi * frequency * Double(frame) / Double(sampleRate)))
            for _ in 0..<channels { samples.append(value.littleEndian) }
        }
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url, options: .atomic)
    }

    private func writeVideo(to url: URL, frames: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 90
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: 160,
                kCVPixelBufferHeightKey as String: 90
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002)
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, 180, CVPixelBufferGetBytesPerRow(buffer) * 90)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        let group = DispatchGroup()
        group.enter()
        writer.finishWriting { group.leave() }
        group.wait()
        if writer.status != .completed {
            throw writer.error ?? NSError(domain: "AudioExportTests", code: 1)
        }
    }

    private func rms(in url: URL, from start: Double, to end: Double) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let first = Int(start * format.sampleRate)
        let last = min(Int(end * format.sampleRate), Int(buffer.frameLength))
        guard last > first else { return 0 }
        var sum: Float = 0
        for frame in first..<last {
            sum += data[frame] * data[frame]
        }
        return Double(sqrt(sum / Float(last - first)))
    }
}
