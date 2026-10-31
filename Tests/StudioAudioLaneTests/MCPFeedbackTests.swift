import AVFoundation
import CoreFoundation
import Darwin
import CoreGraphics
import CoreVideo
import ImageIO
import XCTest
@testable import StudioAudioLane

/// In-process coverage for Finder suppression, undo, atomic batch, waveform, and frame render.
/// The stdio server is not started: under `swift test` its read loop deadlocks the main actor.
@MainActor
final class MCPFeedbackTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sal-mcp-feedback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTestsAndAgentSessionDoNotRevealExportsInFinder() {
        XCTAssertTrue(EditorModel.isRunningUnderXCTest)
        let model = EditorModel()
        XCTAssertFalse(model.revealExportsInFinder)
        XCTAssertFalse(model.shouldRevealExportedFileInFinder)
        model.revealExportsInFinder = true
        XCTAssertFalse(
            model.shouldRevealExportedFileInFinder,
            "XCTest must not open Finder even if the flag is forced on"
        )

        let agent = EditorModel()
        agent.enterAgentSession()
        XCTAssertFalse(agent.revealExportsInFinder)
        XCTAssertFalse(agent.shouldRevealExportedFileInFinder)
    }

    func testUndoRedoRoundtripBumpsRevision() async throws {
        let wav = directory.appendingPathComponent("undo.wav")
        try writeSine(to: wav, seconds: 0.5, frequency: 440, amplitude: 0.25)
        let harness = try Harness()
        let added = try await harness.call(tool: "add_clip", arguments: [
            "file_path": wav.path,
            "track_kind": "audio"
        ])
        XCTAssertNotEqual(added.isError, true, "\(added.payload)")
        let clipID = try XCTUnwrap(added.payload["clip_id"] as? String)
        let revisionAfterAdd = try XCTUnwrap(jsonInt(added.payload["revision"]))

        // JSON `1` is an NSNumber that passes `is Bool`. It must still move the clip.
        let moved = try await harness.call(tool: "move_clip", arguments: [
            "clip_id": clipID,
            "new_start": 1
        ])
        XCTAssertEqual(moved.payload["status"] as? String, "moved", "\(moved.payload)")
        XCTAssertEqual(jsonDouble(moved.payload["timeline_start"]) ?? -1, 1, accuracy: 0.02)
        XCTAssertEqual(jsonInt(moved.payload["revision"]), revisionAfterAdd + 1)

        let undone = try await harness.call(tool: "undo")
        XCTAssertEqual(undone.payload["status"] as? String, "undone")
        XCTAssertEqual(undone.payload["label"] as? String, "Move clip")
        XCTAssertEqual(jsonInt(undone.payload["revision"]), revisionAfterAdd + 2)
        XCTAssertEqual(harness.model.audioClips.first?.timelineStart ?? -1, 0, accuracy: 0.02)

        let redone = try await harness.call(tool: "redo")
        XCTAssertEqual(redone.payload["status"] as? String, "redone")
        XCTAssertEqual(redone.payload["label"] as? String, "Move clip")
        XCTAssertEqual(jsonInt(redone.payload["revision"]), revisionAfterAdd + 3)
        XCTAssertEqual(harness.model.audioClips.first?.timelineStart ?? -1, 1, accuracy: 0.02)

        let history = try await harness.call(tool: "get_history")
        let undoLabels = try XCTUnwrap(history.payload["undo_labels"] as? [String])
        XCTAssertEqual(undoLabels.first, "Move clip")
        XCTAssertTrue(undoLabels.contains("Add clip"))
        XCTAssertEqual(history.payload["can_undo"] as? Bool, true)
        XCTAssertEqual((history.payload["redo_labels"] as? [String])?.isEmpty, true)

        var guardCount = 0
        while harness.model.canUndo, guardCount < 10 {
            _ = try await harness.call(tool: "undo")
            guardCount += 1
        }
        let revision = harness.model.mcpRevision
        let stuck = try await harness.call(tool: "undo")
        XCTAssertEqual(stuck.isError, true)
        XCTAssertEqual(stuck.payload["error"] as? String, "nothing_to_undo")
        XCTAssertEqual(harness.model.mcpRevision, revision)
    }

    func testBatchRollsBackAndDryRunLeavesState() async throws {
        let wav = directory.appendingPathComponent("batch.wav")
        try writeSine(to: wav, seconds: 0.8, frequency: 330, amplitude: 0.25)
        let harness = try Harness()
        let added = try await harness.call(tool: "add_clip", arguments: [
            "file_path": wav.path,
            "track_kind": "audio"
        ])
        let clipID = try XCTUnwrap(added.payload["clip_id"] as? String)
        let duration = try XCTUnwrap(harness.model.audioClips.first?.duration)
        let revision = harness.model.mcpRevision
        let labelsBefore = harness.model.historyLabels(limit: 20).undo.count

        let failed = try await harness.call(tool: "apply_batch", arguments: [
            "operations": [
                ["tool": "trim_clip", "arguments": ["clip_id": clipID, "new_duration": 0.2]],
                ["tool": "trim_clip", "arguments": ["clip_id": UUID().uuidString, "new_duration": 0.2]]
            ]
        ])
        XCTAssertEqual(failed.isError, true)
        XCTAssertEqual(failed.payload["error"] as? String, "batch_failed")
        XCTAssertEqual(jsonInt(failed.payload["failed_step"]), 1)
        XCTAssertEqual(failed.payload["failed_tool"] as? String, "trim_clip")
        XCTAssertEqual(failed.payload["step_error"] as? String, "clip_not_found")
        XCTAssertEqual(harness.model.audioClips.first?.duration ?? -1, duration, accuracy: 0.02)
        XCTAssertEqual(harness.model.mcpRevision, revision)
        XCTAssertEqual(harness.model.historyLabels(limit: 20).undo.count, labelsBefore)
        XCTAssertFalse(harness.model.historyLabels(limit: 20).undo.contains("Apply batch"))

        let preview = try await harness.call(tool: "apply_batch", arguments: [
            "dry_run": true,
            "operations": [
                ["tool": "trim_clip", "arguments": ["clip_id": clipID, "new_duration": 0.2]]
            ]
        ])
        XCTAssertNotEqual(preview.isError, true, "\(preview.payload)")
        XCTAssertEqual(preview.payload["status"] as? String, "dry_run")
        XCTAssertEqual(jsonInt(preview.payload["would_apply"]), 1)
        XCTAssertEqual(jsonInt(preview.payload["revision"]), revision)
        let previewSteps = try XCTUnwrap(preview.payload["results"] as? [[String: Any]])
        XCTAssertEqual(jsonDouble(previewSteps[0]["duration"]) ?? 0, 0.2, accuracy: 0.02)
        XCTAssertEqual(harness.model.audioClips.first?.duration ?? -1, duration, accuracy: 0.02)
        XCTAssertEqual(harness.model.mcpRevision, revision)
        XCTAssertEqual(harness.model.historyLabels(limit: 20).undo.count, labelsBefore)
    }

    func testBatchIsOneUndoStep() async throws {
        let wav = directory.appendingPathComponent("one-undo.wav")
        try writeSine(to: wav, seconds: 0.8, frequency: 440, amplitude: 0.25)
        let harness = try Harness()
        let added = try await harness.call(tool: "add_clip", arguments: [
            "file_path": wav.path,
            "track_kind": "audio"
        ])
        let clipID = try XCTUnwrap(added.payload["clip_id"] as? String)
        let revision = try XCTUnwrap(jsonInt(added.payload["revision"]))
        let labelsBefore = harness.model.historyLabels(limit: 20).undo.count

        let batched = try await harness.call(tool: "apply_batch", arguments: [
            "operations": [
                ["tool": "move_clip", "arguments": ["clip_id": clipID, "new_start": 1]],
                ["tool": "set_clip_volume", "arguments": ["clip_id": clipID, "gain": 0.4]],
                ["tool": "set_fade_out", "arguments": ["clip_id": clipID, "duration": 0.05]]
            ]
        ])
        XCTAssertNotEqual(batched.isError, true, "\(batched.payload)")
        XCTAssertEqual(batched.payload["status"] as? String, "applied")
        XCTAssertEqual(jsonInt(batched.payload["applied"]), 3)
        XCTAssertEqual(jsonInt(batched.payload["revision"]), revision + 1)
        XCTAssertEqual(harness.model.audioClips.first?.timelineStart ?? -1, 1, accuracy: 0.02)
        XCTAssertEqual(Double(harness.model.audioClips.first?.gain ?? -1), 0.4, accuracy: 0.02)
        XCTAssertEqual(harness.model.audioClips.first?.fadeOut ?? -1, 0.05, accuracy: 0.01)
        XCTAssertEqual(harness.model.historyLabels(limit: 20).undo.count, labelsBefore + 1)
        XCTAssertEqual(harness.model.historyLabels(limit: 20).undo.first, "Apply batch")

        let undone = try await harness.call(tool: "undo")
        XCTAssertEqual(undone.payload["label"] as? String, "Apply batch")
        XCTAssertEqual(jsonInt(undone.payload["revision"]), revision + 2)
        XCTAssertEqual(harness.model.audioClips.first?.timelineStart ?? -1, 0, accuracy: 0.02)
        XCTAssertEqual(Double(harness.model.audioClips.first?.gain ?? -1), 1, accuracy: 0.02)
        XCTAssertEqual(harness.model.audioClips.first?.fadeOut ?? -1, 0, accuracy: 0.001)

        let redone = try await harness.call(tool: "redo")
        XCTAssertEqual(redone.payload["label"] as? String, "Apply batch")
        XCTAssertEqual(harness.model.audioClips.first?.timelineStart ?? -1, 1, accuracy: 0.02)
        XCTAssertEqual(Double(harness.model.audioClips.first?.gain ?? -1), 0.4, accuracy: 0.02)
        XCTAssertEqual(harness.model.audioClips.first?.fadeOut ?? -1, 0.05, accuracy: 0.01)
    }

    func testWaveformOfSineIsFlat() async throws {
        let wav = directory.appendingPathComponent("sine.wav")
        let amplitude = 0.25
        try writeSine(to: wav, seconds: 0.5, frequency: 440, amplitude: amplitude)
        let harness = try Harness()
        let added = try await harness.call(tool: "add_clip", arguments: [
            "file_path": wav.path,
            "track_kind": "audio"
        ])
        let clipID = try XCTUnwrap(added.payload["clip_id"] as? String)
        let reading = try await harness.call(tool: "get_waveform", arguments: [
            "clip_id": clipID,
            "buckets": 48
        ])
        XCTAssertNotEqual(reading.isError, true, "\(reading.payload)")
        XCTAssertEqual(reading.payload["scope"] as? String, "clip")
        let peaks = try doubles(reading.payload["peaks"])
        let rms = try doubles(reading.payload["rms"])
        XCTAssertEqual(peaks.count, 48)
        XCTAssertEqual(rms.count, 48)
        let middlePeaks = Array(peaks.dropFirst().dropLast())
        let middleRMS = Array(rms.dropFirst().dropLast())
        let peakMean = middlePeaks.reduce(0, +) / Double(middlePeaks.count)
        let rmsMean = middleRMS.reduce(0, +) / Double(middleRMS.count)
        XCTAssertEqual(peakMean, amplitude, accuracy: 0.04)
        XCTAssertEqual(rmsMean, amplitude / (2.0).squareRoot(), accuracy: 0.04)
        XCTAssertLessThan((middlePeaks.max() ?? 0) - (middlePeaks.min() ?? 0), 0.08)
        for (peak, power) in zip(middlePeaks, middleRMS) {
            XCTAssertLessThanOrEqual(power, peak + 0.000_1)
            XCTAssertGreaterThan(peak, 0.12)
        }

        let mixed = try await harness.call(tool: "get_waveform", arguments: ["buckets": 48])
        XCTAssertNotEqual(mixed.isError, true, "\(mixed.payload)")
        XCTAssertEqual(mixed.payload["scope"] as? String, "timeline")
        let mixPeaks = try doubles(mixed.payload["peaks"])
        let mixMiddle = Array(mixPeaks.dropFirst().dropLast())
        let mixMean = mixMiddle.reduce(0, +) / Double(mixMiddle.count)
        let lane = Double(harness.model.track(id: EditorModel.defaultAudioTrackID)?.volume ?? 1)
        XCTAssertEqual(mixMean, peakMean * lane, accuracy: 0.05)
        XCTAssertLessThan(mixMean, peakMean)
    }

    func testRenderFrameOnVideoAndAudioOnlyError() async throws {
        let wav = directory.appendingPathComponent("only-audio.wav")
        try writeSine(to: wav, seconds: 0.4, frequency: 440, amplitude: 0.2)
        let audioOnly = try Harness()
        _ = try await audioOnly.call(tool: "add_clip", arguments: [
            "file_path": wav.path,
            "track_kind": "audio"
        ])
        let missing = try await audioOnly.call(tool: "render_frame", arguments: ["time": 0.1])
        XCTAssertEqual(missing.isError, true)
        XCTAssertEqual(missing.payload["error"] as? String, "no_video")

        let video = directory.appendingPathComponent("frame.mov")
        try writeTinyVideo(to: video, frames: 15)
        let harness = try Harness()
        let added = try await harness.call(tool: "add_clip", arguments: [
            "file_path": video.path,
            "track_kind": "video"
        ])
        XCTAssertNotEqual(added.isError, true, "\(added.payload)")
        let png = directory.appendingPathComponent("frame.png")
        let rendered = try await harness.call(tool: "render_frame", arguments: [
            "time": 0.1,
            "max_dimension": 80,
            "destination_path": png.path,
            "include_image": true
        ])
        XCTAssertNotEqual(rendered.isError, true, "\(rendered.payload)")
        XCTAssertEqual(rendered.payload["status"] as? String, "rendered")
        XCTAssertEqual(rendered.payload["file_path"] as? String, png.path)
        XCTAssertLessThanOrEqual(jsonInt(rendered.payload["width"]) ?? 10_000, 80)
        XCTAssertLessThanOrEqual(jsonInt(rendered.payload["height"]) ?? 10_000, 80)
        XCTAssertGreaterThan(jsonInt(rendered.payload["width"]) ?? 0, 0)
        let imageContent = try XCTUnwrap(rendered.content.dropFirst().first)
        XCTAssertEqual(imageContent["type"] as? String, "image")
        XCTAssertEqual(imageContent["mimeType"] as? String, "image/png")
        let base64 = try XCTUnwrap(imageContent["data"] as? String)
        let decoded = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertEqual([UInt8](decoded.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let image = try pngImage(at: png)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 80)
        XCTAssertGreaterThan(luma(of: image), 30, "rendered frame looks blank")
    }
}

@MainActor
private final class Harness {
    let model: EditorModel
    let server: MCPServer
    private let capture: LineCapture
    private var nextID = 0

    init() throws {
        let model = EditorModel()
        model.enterAgentSession()
        let capture = LineCapture()
        self.capture = capture
        self.model = model
        self.server = MCPServer(model: model, emit: { capture.write($0) }, onEOF: {})
    }

    func call(tool: String, arguments: [String: Any] = [:]) async throws -> ToolReply {
        nextID += 1
        let id = nextID
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": [
                "name": tool,
                "arguments": arguments
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: message)
        let line = try XCTUnwrap(String(data: data, encoding: .utf8))
        await server.handleMessage(line)
        let rpc = try XCTUnwrap(capture.lines().last.flatMap(jsonObject))
        let result = try XCTUnwrap(rpc["result"] as? [String: Any], "\(rpc)")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let payload = try XCTUnwrap(jsonObject(text))
        return ToolReply(isError: result["isError"] as? Bool, payload: payload, content: content)
    }
}

private struct ToolReply {
    var isError: Bool?
    var payload: [String: Any]
    var content: [[String: Any]]
}

private final class LineCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func write(_ data: Data) {
        lock.lock()
        text += String(data: data, encoding: .utf8) ?? ""
        lock.unlock()
    }

    func lines() -> [String] {
        lock.lock()
        let raw = text
        lock.unlock()
        return raw.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

private func jsonObject(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return obj
}

private func jsonNumber(_ value: Any?) -> NSNumber? {
    guard let value else { return nil }
    if type(of: value) == Bool.self { return nil }
    guard let number = value as? NSNumber else { return nil }
    if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
    return number
}

private func jsonInt(_ value: Any?) -> Int? {
    guard let number = jsonNumber(value) else { return nil }
    let asDouble = number.doubleValue
    guard asDouble.isFinite, asDouble.rounded() == asDouble, abs(asDouble) <= Double(Int.max) else { return nil }
    return Int(asDouble)
}

private func jsonDouble(_ value: Any?) -> Double? {
    guard let number = jsonNumber(value) else { return nil }
    let asDouble = number.doubleValue
    return asDouble.isFinite ? asDouble : nil
}

private func doubles(_ value: Any?) throws -> [Double] {
    if let items = value as? [Double] { return items }
    if let items = value as? [NSNumber] { return items.map(\.doubleValue) }
    let items = try XCTUnwrap(value as? [Any], "expected a number array, got \(String(describing: value))")
    return try items.map { try XCTUnwrap(jsonDouble($0)) }
}

private func pngImage(at url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(domain: "MCPFeedbackTests", code: 1)
    }
    return image
}

private func luma(of image: CGImage) -> Int {
    var pixel = [UInt8](repeating: 0, count: 4)
    guard let context = CGContext(
        data: &pixel,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return 0 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])
}

private func writeSine(to url: URL, seconds: Double, frequency: Double, amplitude: Double) throws {
    let sampleRate = 44_100.0
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
        throw NSError(domain: "MCPFeedbackTests", code: 2)
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(sampleRate * seconds)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
          let samples = buffer.floatChannelData?[0] else {
        throw NSError(domain: "MCPFeedbackTests", code: 3)
    }
    buffer.frameLength = frames
    for frame in 0..<Int(frames) {
        let time = Double(frame) / sampleRate
        samples[frame] = Float(sin(2 * Double.pi * frequency * time) * amplitude)
    }
    try file.write(from: buffer)
}

private func writeTinyVideo(to url: URL, frames: Int) throws {
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
        throw writer.error ?? NSError(domain: "MCPFeedbackTests", code: 4)
    }
}
