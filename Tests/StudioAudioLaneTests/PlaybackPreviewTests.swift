import AVFoundation
import CoreVideo
import XCTest
@testable import StudioAudioLane

final class PlaybackPreviewTests: XCTestCase {
    func testPlaybackEditsKeepThePreviewCompositionCoveringTheItem() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sal-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let videoURL = directory.appendingPathComponent("clip.mov")
        let audioURL = directory.appendingPathComponent("bed.wav")
        try writeVideo(to: videoURL, frames: 15)
        try writeAudio(to: audioURL, seconds: 2)

        let videoDuration = try await AVURLAsset(url: videoURL).load(.duration).seconds
        let audioDuration = try await AVURLAsset(url: audioURL).load(.duration).seconds
        XCTAssertGreaterThan(audioDuration, videoDuration + 0.5)

        let model = await MainActor.run { EditorModel() }
        let videoID = UUID()
        let audioID = UUID()
        await MainActor.run {
            model.videoClips = [
                MediaClip(
                    id: videoID,
                    url: videoURL,
                    name: "clip",
                    sourceDuration: videoDuration,
                    inPoint: 0,
                    timelineStart: 0,
                    duration: videoDuration,
                    fadeIn: 0,
                    fadeOut: 0.2,
                    trackID: EditorModel.defaultVideoTrackID
                )
            ]
            model.audioClips = [
                MediaClip(
                    id: audioID,
                    url: audioURL,
                    name: "bed",
                    sourceDuration: audioDuration,
                    inPoint: 0,
                    timelineStart: 0,
                    duration: audioDuration,
                    fadeIn: 0,
                    fadeOut: 0,
                    trackID: EditorModel.defaultAudioTrackID
                )
            ]
            model.selectedClipID = audioID
            model.selectedClipIDs = [audioID]
            model.focusedLane = .audio
        }
        await model.rebuildCompositionPublic()

        try await MainActor.run {
            let item = try XCTUnwrap(model.player.currentItem)
            let composition = try XCTUnwrap(item.videoComposition, "a video fade should install a composition")
            try assertCoversPlayback(composition, item: item, file: #filePath, line: #line)
            let picture = composition
            model.audioClips[0].gain = 0.2
            model.applyFadesPublic(refreshingVideo: false)
            XCTAssertTrue(model.player.currentItem?.videoComposition === picture)

            model.videoClips[0].fadeOut = 0.35
            model.applyFadesPublic(refreshingVideo: true)
            let refreshed = try XCTUnwrap(model.player.currentItem?.videoComposition)
            XCTAssertFalse(refreshed === picture)
            try assertCoversPlayback(refreshed, item: try XCTUnwrap(model.player.currentItem), file: #filePath, line: #line)
        }
    }
}

@MainActor
private func assertCoversPlayback(
    _ composition: AVVideoComposition,
    item: AVPlayerItem,
    file: StaticString,
    line: UInt
) throws {
    var cursor = CMTime.zero
    XCTAssertFalse(composition.instructions.isEmpty, file: file, line: line)
    for instruction in composition.instructions {
        XCTAssertEqual(CMTimeCompare(instruction.timeRange.start, cursor), 0, file: file, line: line)
        XCTAssertGreaterThan(CMTimeCompare(instruction.timeRange.end, instruction.timeRange.start), 0, file: file, line: line)
        cursor = instruction.timeRange.end
    }
    XCTAssertGreaterThanOrEqual(CMTimeCompare(cursor, item.duration), 0, file: file, line: line)
    let valid = composition.isValid(
        for: item.asset,
        timeRange: CMTimeRange(start: .zero, duration: item.duration),
        validationDelegate: nil
    )
    XCTAssertTrue(valid, file: file, line: line)
}

private func writeVideo(to url: URL, frames: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 90
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: 160,
            kCVPixelBufferHeightKey as String: 90
        ])
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
            throw writer.error ?? NSError(domain: "PlaybackPreviewTests", code: 1)
        }
    }

private func writeAudio(to url: URL, seconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(44100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
    }
