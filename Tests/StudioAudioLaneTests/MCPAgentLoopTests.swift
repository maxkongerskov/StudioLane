import AVFoundation
import CoreVideo
import XCTest
@testable import StudioAudioLane

/// Speaks newline-delimited JSON-RPC at `MCPServer`, the same bytes a stdio
/// client writes. `EditorModel` is `@MainActor`, so every test that touches it
/// is `@MainActor` too. Media files are built by nonisolated helpers that do
/// not touch the model.
final class MCPAgentLoopTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sal-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testStdioReaderAssemblesChunksAndStopsOnEOF() throws {
        let pipe = Pipe()
        let log = MCPLineLog()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            MCPStdio.readLines(from: pipe.fileHandleForReading, isRunning: { true }) { line in
                log.append(Data(line.utf8))
            }
            finished.signal()
        }
        pipe.fileHandleForWriting.write(Data("{\"a\":1}\n{\"b\":".utf8))
        pipe.fileHandleForWriting.write(Data("2}\n".utf8))
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(
            log.snapshot().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            ["{\"a\":1}", "{\"b\":2}"]
        )
    }

    @MainActor
    func testJSONRPCIdsNotificationsAndMissingDelete() async throws {
        let autosave = directory.appendingPathComponent("untouched-autosave", isDirectory: true)
        try FileManager.default.createDirectory(at: autosave, withIntermediateDirectories: true)
        let client = MCPTestClient(autosaveDirectory: autosave)
        defer { client.closeInput() }

        let initialize = try await client.request(id: 1, method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [String: String](),
            "clientInfo": ["name": "test", "version": "0"]
        ])
        XCTAssertTrue(idsMatch(initialize["id"], 1))
        let initResult = try XCTUnwrap(initialize["result"] as? [String: Any])
        XCTAssertEqual(initResult["protocolVersion"] as? String, "2024-11-05")

        let linesBeforeNotification = client.log.snapshot().count
        try client.notify(method: "notifications/initialized")
        let ping = try await client.request(id: "ping", method: "ping")
        XCTAssertTrue(idsMatch(ping["id"], "ping"))
        XCTAssertEqual(client.log.snapshot().count, linesBeforeNotification + 1)

        let listed = try await client.request(id: "list", method: "tools/list")
        XCTAssertTrue(idsMatch(listed["id"], "list"))
        let tools = try XCTUnwrap((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let addClip = try XCTUnwrap(tools.first { $0["name"] as? String == "add_clip" })
        let description = try XCTUnwrap(addClip["description"] as? String)
        XCTAssertTrue(description.localizedCaseInsensitiveContains("playlist"))
        XCTAssertTrue(description.localizedCaseInsensitiveContains("crossfade"))

        let missingMethod = try await client.request(id: 9, method: "nope")
        XCTAssertTrue(idsMatch(missingMethod["id"], 9))
        XCTAssertNotNil(missingMethod["error"])

        let revisionBefore = client.model.mcpRevision
        let deleted = try await client.call(
            id: "missing",
            tool: "delete_clip",
            arguments: ["clip_id": UUID().uuidString, "confirmed": true]
        )
        XCTAssertTrue(idsMatch(deleted.rpc["id"], "missing"))
        let deletedResult = try XCTUnwrap(deleted.rpc["result"] as? [String: Any])
        XCTAssertEqual(deletedResult["isError"] as? Bool, true)
        XCTAssertEqual(deleted.payload["error"] as? String, "clip_not_found")
        XCTAssertEqual(client.model.mcpRevision, revisionBefore)

        client.closeInput()
        let deadline = Date().addingTimeInterval(5)
        while client.server.isReading, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(client.server.isReading)
        XCTAssertFalse(FileManager.default.fileExists(atPath: autosave.appendingPathComponent("autosave.json").path))
    }

    @MainActor
    func testUIGestureBumpsRevisionOnce() {
        let model = EditorModel()
        model.isLoading = false
        let before = model.mcpRevision
        model.beginEdit()
        XCTAssertEqual(model.mcpRevision, before + 1)
        model.beginEdit()
        XCTAssertEqual(model.mcpRevision, before + 1)
    }

    @MainActor
    func testAgentSessionSkipsAutosaveThatANormalLaunchRestores() async throws {
        let wav = directory.appendingPathComponent("seed.wav")
        try writeSine(to: wav, seconds: 0.4, frequency: 440)
        let clipID = UUID()
        let document = ProjectDocument(
            clips: ProjectClips(video: [], audio: [
                MediaClip(
                    id: clipID,
                    url: wav,
                    name: "seed",
                    sourceDuration: 0.4,
                    inPoint: 0,
                    timelineStart: 0,
                    duration: 0.4,
                    fadeIn: 0,
                    fadeOut: 0,
                    trackID: EditorModel.defaultAudioTrackID
                )
            ]),
            tracks: [
                .defaultVideo(id: EditorModel.defaultVideoTrackID),
                .defaultMusic(id: EditorModel.defaultAudioTrackID)
            ],
            focusedLane: 1,
            focusedTrackID: EditorModel.defaultAudioTrackID,
            selectedClipID: clipID,
            selectedClipIDs: [clipID],
            videoVolume: 1,
            musicVolume: 0.62,
            isDuckingMusic: false,
            audioLayoutMode: 0,
            playhead: 0.1
        )
        let autosaveDir = directory.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: autosaveDir, withIntermediateDirectories: true)
        let autosave = autosaveDir.appendingPathComponent("autosave.json")
        try JSONEncoder().encode(document).write(to: autosave)
        let original = try Data(contentsOf: autosave)

        let agent = EditorModel()
        agent.enterAgentSession(autosaveDirectory: autosaveDir)
        await agent.loadInitialSession()
        XCTAssertTrue(agent.videoClips.isEmpty)
        XCTAssertTrue(agent.audioClips.isEmpty)
        XCTAssertEqual(agent.mcpRevision, 0)
        XCTAssertFalse(agent.revealExportsInFinder)
        await agent.saveProject()
        XCTAssertEqual(try Data(contentsOf: autosave), original)

        let restored = EditorModel()
        restored.autosaveDirectoryOverride = autosaveDir
        await restored.loadInitialSession()
        XCTAssertEqual(restored.audioClips.count, 1)
        XCTAssertEqual(restored.audioClips.first?.url.path, wav.path)
        XCTAssertEqual(restored.currentTime, 0.1, accuracy: 0.001)
        XCTAssertEqual(try Data(contentsOf: autosave), original)
    }

    @MainActor
    func testAgentLoopTrimFadeExport() async throws {
        let wav = directory.appendingPathComponent("tone.wav")
        try writeSine(to: wav, seconds: 1.0, frequency: 440)
        let video = directory.appendingPathComponent("clip.mov")
        let hasVideo = (try? writeTinyVideo(to: video, frames: 15)) != nil
            && FileManager.default.fileExists(atPath: video.path)

        let autosave = directory.appendingPathComponent("agent-autosave", isDirectory: true)
        try FileManager.default.createDirectory(at: autosave, withIntermediateDirectories: true)
        let client = MCPTestClient(autosaveDirectory: autosave)
        defer { client.closeInput() }
        await client.model.loadInitialSession()
        XCTAssertTrue(client.model.audioClips.isEmpty)
        XCTAssertEqual(client.model.mcpRevision, 0)

        _ = try await client.request(id: 1, method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [String: String](),
            "clientInfo": ["name": "test", "version": "0"]
        ])
        try client.notify(method: "notifications/initialized")
        let listed = try await client.request(id: 2, method: "tools/list")
        XCTAssertTrue(idsMatch(listed["id"], 2))

        let audioAdd = try await client.call(id: "add-audio", tool: "add_clip", arguments: [
            "file_path": wav.path,
            "track_kind": "audio"
        ])
        XCTAssertTrue(idsMatch(audioAdd.rpc["id"], "add-audio"))
        XCTAssertNotEqual((audioAdd.rpc["result"] as? [String: Any])?["isError"] as? Bool, true)
        let audioID = try XCTUnwrap(audioAdd.payload["clip_id"] as? String)
        XCTAssertNotNil(UUID(uuidString: audioID))
        XCTAssertEqual(jsonInt(audioAdd.payload["revision"]), 1)
        XCTAssertEqual(audioAdd.payload["file_path"] as? String, wav.path)
        XCTAssertEqual(audioAdd.payload["audio_layout"] as? String, "playlist")
        XCTAssertGreaterThan(jsonDouble(audioAdd.payload["source_duration"]) ?? 0, 0.5)

        var videoID: String?
        if hasVideo {
            let videoAdd = try await client.call(id: "add-video", tool: "add_clip", arguments: [
                "file_path": video.path,
                "track_kind": "video"
            ])
            XCTAssertTrue(idsMatch(videoAdd.rpc["id"], "add-video"))
            videoID = try XCTUnwrap(videoAdd.payload["clip_id"] as? String)
            XCTAssertEqual(jsonInt(videoAdd.payload["revision"]), 2)
        }

        let revisionAfterImport = client.model.mcpRevision
        let missing = try await client.call(
            id: "missing-during-loop",
            tool: "delete_clip",
            arguments: ["clip_id": UUID().uuidString, "confirmed": true]
        )
        XCTAssertEqual(missing.payload["error"] as? String, "clip_not_found")
        XCTAssertEqual(client.model.mcpRevision, revisionAfterImport)

        let stateCall = try await client.call(id: 4, tool: "get_project_state")
        XCTAssertTrue(idsMatch(stateCall.rpc["id"], 4))
        let state = stateCall.payload
        XCTAssertEqual(jsonInt(state["revision"]), revisionAfterImport)
        XCTAssertEqual(jsonDouble(state["playhead"]) ?? -1, 0, accuracy: 0.001)
        XCTAssertGreaterThan(jsonDouble(state["timeline_duration"]) ?? 0, 0.2)
        XCTAssertEqual(state["audio_layout"] as? String, "playlist")
        let behavior = try XCTUnwrap(state["editing_behavior"] as? String)
        XCTAssertTrue(behavior.localizedCaseInsensitiveContains("crossfade"))
        XCTAssertTrue(behavior.localizedCaseInsensitiveContains("trim_clip"))
        let tracks = try XCTUnwrap(state["tracks"] as? [[String: Any]])
        XCTAssertFalse(tracks.isEmpty)
        XCTAssertTrue(tracks.allSatisfy { ($0["id"] as? String)?.isEmpty == false })
        let clips = try XCTUnwrap(state["clips"] as? [[String: Any]])
        let audioClip = try XCTUnwrap(clips.first { $0["id"] as? String == audioID })
        XCTAssertEqual(audioClip["file_path"] as? String, wav.path)
        XCTAssertGreaterThan(jsonDouble(audioClip["source_duration"]) ?? 0, 0.5)
        XCTAssertEqual(audioClip["track_id"] as? String, audioAdd.payload["track_id"] as? String)
        if let videoID {
            XCTAssertTrue(clips.contains { $0["id"] as? String == videoID && $0["file_path"] as? String == video.path })
        }

        let trimTarget = videoID ?? audioID
        let trimDuration = videoID == nil ? 0.45 : 0.3
        let trimmed = try await client.call(id: "trim", tool: "trim_clip", arguments: [
            "clip_id": trimTarget,
            "new_duration": trimDuration
        ])
        XCTAssertTrue(idsMatch(trimmed.rpc["id"], "trim"))
        XCTAssertEqual(trimmed.payload["status"] as? String, "trimmed")
        XCTAssertEqual(jsonDouble(trimmed.payload["duration"]) ?? 0, trimDuration, accuracy: 0.02)
        XCTAssertEqual(jsonInt(trimmed.payload["revision"]), revisionAfterImport + 1)
        let note = try XCTUnwrap(trimmed.payload["note"] as? String)
        XCTAssertTrue(note.localizedCaseInsensitiveContains("does not ripple"))

        let faded = try await client.call(id: "fade", tool: "set_fade_in", arguments: [
            "clip_id": trimTarget,
            "duration": 0.08
        ])
        XCTAssertTrue(idsMatch(faded.rpc["id"], "fade"))
        XCTAssertEqual(jsonDouble(faded.payload["fade_in"]) ?? 0, 0.08, accuracy: 0.01)
        XCTAssertEqual(jsonInt(faded.payload["revision"]), revisionAfterImport + 2)

        let again = try await client.call(id: "fade-again", tool: "set_fade_in", arguments: [
            "clip_id": trimTarget,
            "duration": 0.08
        ])
        XCTAssertEqual(again.payload["status"] as? String, "unchanged")
        XCTAssertEqual(jsonInt(again.payload["revision"]), revisionAfterImport + 2)

        let timeline = jsonDouble(
            (try await client.call(id: "state-before-export", tool: "get_project_state")).payload["timeline_duration"]
        ) ?? 0
        let destination = directory.appendingPathComponent("finished.mp4")
        let exported = try await client.call(id: "export", tool: "export_project", arguments: [
            "destination_path": destination.path,
            "container": "mp4",
            "codec": "h264",
            "quality": "high",
            "overwrite": true
        ])
        XCTAssertTrue(idsMatch(exported.rpc["id"], "export"))
        XCTAssertEqual(exported.payload["status"] as? String, "started", "\(exported.payload)")
        XCTAssertEqual(exported.payload["finder_reveal"] as? Bool, false)
        let outputPath = try XCTUnwrap(exported.payload["destination"] as? String)

        var finalStatus: [String: Any] = [:]
        let deadline = Date().addingTimeInterval(90)
        var poll = 0
        while Date() < deadline {
            poll += 1
            let status = try await client.call(id: 100 + poll, tool: "get_export_status")
            XCTAssertTrue(idsMatch(status.rpc["id"], 100 + poll))
            finalStatus = status.payload
            if (status.payload["is_exporting"] as? Bool) == false {
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertEqual(finalStatus["is_exporting"] as? Bool, false, "\(finalStatus)")
        XCTAssertEqual(finalStatus["succeeded"] as? Bool, true, "\(finalStatus)")
        XCTAssertEqual(jsonDouble(finalStatus["progress"]) ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(finalStatus["destination"] as? String, outputPath)

        let output = URL(fileURLWithPath: outputPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let bytes = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(bytes, 1_024)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 0.15)
        XCTAssertEqual(duration, timeline, accuracy: 0.35)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertFalse(audioTracks.isEmpty && videoTracks.isEmpty)

        let progressTokens = client.log.snapshot().compactMap { line -> Any? in
            guard let obj = jsonObject(line),
                  obj["method"] as? String == "notifications/progress",
                  let params = obj["params"] as? [String: Any] else { return nil }
            return params["progressToken"]
        }
        XCTAssertTrue(progressTokens.contains { idsMatch($0, "export") })

        XCTAssertFalse(FileManager.default.fileExists(atPath: autosave.appendingPathComponent("autosave.json").path))
        client.closeInput()
        let eofDeadline = Date().addingTimeInterval(5)
        while client.server.isReading, Date() < eofDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(client.server.isReading)
    }
}

@MainActor
private final class MCPTestClient {
    let model: EditorModel
    let server: MCPServer
    let log: MCPLineLog
    let input: Pipe
    private var closed = false

    init(autosaveDirectory: URL) {
        let model = EditorModel()
        model.enterAgentSession(autosaveDirectory: autosaveDirectory)
        let log = MCPLineLog()
        let input = Pipe()
        let server = MCPServer(model: model, emit: { log.append($0) }, onEOF: {})
        self.model = model
        self.server = server
        self.log = log
        self.input = input
        server.start(input: input.fileHandleForReading)
    }

    func request(id: Any, method: String, params: [String: Any]? = nil, timeout: TimeInterval = 30) async throws -> [String: Any] {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        try write(message)
        return try await waitForResponse(id: id, timeout: timeout)
    }

    func notify(method: String) throws {
        try write(["jsonrpc": "2.0", "method": method])
    }

    func call(id: Any, tool: String, arguments: [String: Any] = [:], timeout: TimeInterval = 60) async throws -> (rpc: [String: Any], payload: [String: Any]) {
        let rpc = try await request(
            id: id,
            method: "tools/call",
            params: ["name": tool, "arguments": arguments],
            timeout: timeout
        )
        let result = try XCTUnwrap(rpc["result"] as? [String: Any], "\(rpc)")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let payload = try XCTUnwrap(jsonObject(text))
        return (rpc, payload)
    }

    func closeInput() {
        guard !closed else { return }
        closed = true
        try? input.fileHandleForWriting.close()
    }

    private func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(UInt8(ascii: "\n"))
        input.fileHandleForWriting.write(data)
    }

    private func waitForResponse(id: Any, timeout: TimeInterval) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for line in log.snapshot() {
                guard let obj = jsonObject(line), idsMatch(obj["id"], id) else { continue }
                return obj
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for id \(id). lines:\n\(log.snapshot().joined())")
        throw MCPTestTimeout()
    }
}

private struct MCPTestTimeout: Error {}

private final class MCPLineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        lines.append(text)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

private func jsonObject(_ line: String) -> [String: Any]? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return obj
}

private func idsMatch(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let left = normalizeID(lhs), let right = normalizeID(rhs) else { return false }
    return left == right
}

private func normalizeID(_ value: Any?) -> String? {
    guard let value else { return nil }
    if value is NSNull { return "null" }
    if let string = value as? String { return "s:\(string)" }
    if value is Bool { return nil }
    if let number = value as? NSNumber { return "n:\(number.stringValue)" }
    return nil
}

private func jsonInt(_ value: Any?) -> Int? {
    guard let value, !(value is Bool) else { return nil }
    if let int = value as? Int { return int }
    if let number = value as? NSNumber { return number.intValue }
    return nil
}

private func jsonDouble(_ value: Any?) -> Double? {
    guard let value, !(value is Bool) else { return nil }
    if let number = value as? NSNumber { return number.doubleValue }
    return nil
}

private func writeSine(to url: URL, seconds: Double, frequency: Double) throws {
    let sampleRate = 44_100.0
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
        throw MCPTestTimeout()
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(sampleRate * seconds)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
          let samples = buffer.floatChannelData?[0] else {
        throw MCPTestTimeout()
    }
    buffer.frameLength = frames
    for frame in 0..<Int(frames) {
        let time = Double(frame) / sampleRate
        samples[frame] = Float(sin(2 * Double.pi * frequency * time) * 0.2)
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
        throw writer.error ?? MCPTestTimeout()
    }
}
