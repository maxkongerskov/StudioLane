import AVFoundation
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
