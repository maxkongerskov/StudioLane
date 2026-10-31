import AppKit
import Foundation

// MARK: - MCP Server (stdio JSON-RPC)

/// Line-buffered stdin for MCP. One JSON-RPC message per line. Returns on EOF
/// or when `isRunning` becomes false between reads.
enum MCPStdio {
    static func readLines(
        from handle: FileHandle,
        isRunning: @escaping @Sendable () -> Bool,
        onLine: @escaping @Sendable (String) -> Void
    ) {
        var pending = Data()
        while isRunning() {
            do {
                guard let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty else {
                    consume(&pending, flushRemainder: true, onLine: onLine)
                    return
                }
                pending.append(chunk)
                consume(&pending, flushRemainder: false, onLine: onLine)
            } catch {
                MCPLog.info("stdin read ended: \(error.localizedDescription)")
                consume(&pending, flushRemainder: true, onLine: onLine)
                return
            }
        }
        consume(&pending, flushRemainder: true, onLine: onLine)
    }

    private static func consume(_ pending: inout Data, flushRemainder: Bool, onLine: (String) -> Void) {
        let newline = UInt8(ascii: "\n")
        while let breakIndex = pending.firstIndex(of: newline) {
            let line = pending.prefix(upTo: breakIndex)
            pending = Data(pending.suffix(from: pending.index(after: breakIndex)))
            deliver(Data(line), onLine: onLine)
        }
        if flushRemainder, !pending.isEmpty {
            deliver(pending, onLine: onLine)
            pending.removeAll()
        }
    }

    private static func deliver(_ raw: Data, onLine: (String) -> Void) {
        var line = raw
        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        guard let text = String(data: line, encoding: .utf8) else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        onLine(text)
    }
}

enum MCPLog {
    static func info(_ message: String) {
        let line = "StudioLane MCP: \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

final class MCPRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    var isRunning: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return running
        }
        set {
            lock.lock()
            running = newValue
            lock.unlock()
        }
    }
}

/// Hops stdin lines onto the main actor without reading `MCPServer` from the
/// blocking read thread. `isRunning` lives on `MCPRunState`, not the actor.
private final class MCPSessionBridge: @unchecked Sendable {
    weak var server: MCPServer?
    let runState: MCPRunState

    init(server: MCPServer, runState: MCPRunState) {
        self.server = server
        self.runState = runState
    }

    func read(from input: FileHandle) {
        let bridge = self
        MCPStdio.readLines(from: input, isRunning: { bridge.runState.isRunning }) { line in
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                await bridge.server?.handleMessage(line)
                semaphore.signal()
            }
            semaphore.wait()
        }
        runState.isRunning = false
        Task { @MainActor in
            bridge.server?.handleEOF()
        }
    }
}

@MainActor
final class MCPServer {
    private let model: EditorModel
    private let emit: @Sendable (Data) -> Void
    private let onEOF: @MainActor () -> Void
    private let runState = MCPRunState()
    private var capabilitiesSent = false

    /// `emit` receives one JSON-RPC message, including its trailing newline.
    /// `onEOF` runs after stdin closes. The app quits; tests pass a no-op.
    init(
        model: EditorModel,
        emit: (@Sendable (Data) -> Void)? = nil,
        onEOF: (@MainActor () -> Void)? = nil
    ) {
        self.model = model
        self.emit = emit ?? { data in
            FileHandle.standardOutput.write(data)
        }
        self.onEOF = onEOF ?? {
            MCPLog.info("stdin closed; quitting")
            NSApplication.shared.terminate(nil)
        }
    }

    var isReading: Bool { runState.isRunning }

    func start(input: FileHandle = .standardInput) {
        guard !runState.isRunning else { return }
        runState.isRunning = true
        MCPLog.info("stdio server ready (protocol 2024-11-05). JSON-RPC on stdout, logs on stderr.")
        let bridge = MCPSessionBridge(server: self, runState: runState)
        DispatchQueue.global(qos: .userInitiated).async {
            bridge.read(from: input)
        }
    }

    func stop() {
        runState.isRunning = false
    }

    func handleEOF() {
        MCPLog.info("stdin closed")
        onEOF()
    }

    func handleMessage(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            writeResponse(MCPJSONRPC.error(id: NSNull(), code: -32700, message: "Parse error"))
            return
        }

        guard let method = obj["method"] as? String else {
            if let id = obj["id"] {
                writeResponse(MCPJSONRPC.error(id: id, code: -32600, message: "Invalid request"))
            }
            return
        }

        // A missing id is a notification. Notifications get no response,
        // including when the method is unknown. JSON `null` is a real id and
        // must be echoed.
        guard let id = obj["id"] else {
            if method != "notifications/initialized" && method != "notifications/cancelled" {
                MCPLog.info("ignored notification \(method)")
            }
            return
        }

        switch method {
        case "initialize":
            capabilitiesSent = true
            writeResponse(MCPJSONRPC.response(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "studioaudiolane", "version": "1.0.0"]
            ]))

        case "ping":
            writeResponse(MCPJSONRPC.response(id: id, result: [:]))

        case "tools/list":
            writeResponse(MCPJSONRPC.response(id: id, result: ["tools": toolDefinitions]))

        case "tools/call":
            guard let params = obj["params"] as? [String: Any],
                  let toolName = params["name"] as? String else {
                writeResponse(MCPJSONRPC.error(id: id, code: -32602, message: "Missing tool name"))
                return
            }
            let args = (params["arguments"] as? [String: Any]) ?? [:]
            let result = await callTool(name: toolName, arguments: args, requestId: id)
            writeResponse(result)
            monitorExportAfterToolCall(requestId: id, initiallyExporting: model.isExporting)

        default:
            writeResponse(MCPJSONRPC.error(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    private func writeResponse(_ data: Data) {
        var framed = data
        if framed.last != UInt8(ascii: "\n") {
            framed.append(UInt8(ascii: "\n"))
        }
        emit(framed)
    }

    private func writeNotification(_ data: Data) {
        writeResponse(data)
    }

    private func monitorExportAfterToolCall(requestId: Any, initiallyExporting: Bool) {
        guard capabilitiesSent else { return }
        if initiallyExporting {
            sendExportStarted(requestId: requestId)
        }
        Task { @MainActor [weak self] in
            await self?.waitForExportChange(initiallyExporting: initiallyExporting, requestId: requestId)
        }
    }

    private func sendExportStarted(requestId: Any) {
        writeNotification(MCPJSONRPC.notification(method: "notifications/progress", params: [
            "progressToken": requestId,
            "progress": 0,
            "total": 1,
            "message": "Export started"
        ] as [String: Any]))
    }

    private func waitForExportChange(initiallyExporting: Bool, requestId: Any) async {
        var lastProgress = initiallyExporting ? 0.0 : 1.0
        if initiallyExporting {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        while model.isExporting {
            let progress = model.exportProgress
            if progress - lastProgress >= 0.01 || progress < lastProgress {
                lastProgress = progress
                writeNotification(MCPJSONRPC.notification(method: "notifications/progress", params: [
                    "progressToken": requestId,
                    "progress": progress,
                    "total": 1,
                    "message": model.exportDestinationURL?.lastPathComponent ?? "Exporting"
                ] as [String: Any]))
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        if initiallyExporting {
            let progress = model.exportProgress
            let succeeded = abs(progress - 1) < 0.001
            writeNotification(MCPJSONRPC.notification(method: "notifications/progress", params: [
                "progressToken": requestId,
                "progress": succeeded ? 1 : 0,
                "total": 1,
                "message": succeeded ? "Export completed" : "Export failed or cancelled"
            ] as [String: Any]))
        }
    }

    // MARK: - Tool Registry

    private var toolDefinitions: [[String: Any]] {
        [
            toolDef(
                "get_project_state",
                """
                Snapshot for planning an edit. Always includes revision, playhead (seconds), timeline_duration, audio_layout (playlist or layer), editing_behavior, fps, render_size, tracks (id, kind, name, volume), and clips. Each clip includes id, track_id, kind, file_path, timeline_start, duration, and source_duration. project_path is present after a project file is saved. Compact mode omits source_in when it is 0, gain when it is 1, and muted when it is false. \(MCPHandlers.editingBehavior)
                """,
                [
                    "type": "object",
                    "properties": [
                        "compact": ["type": "boolean", "description": "Omit default source_in, gain, and muted. file_path, source_duration, and playhead stay."]
                    ]
                ]
            ),
            toolDef(
                "get_export_status",
                "Export progress. is_exporting, progress from 0 to 1, destination path, and succeeded once the export has finished. error is set when the last export failed. Poll this after export_project. The destination is the file that was or will be written, including an extension the tool rewrote.",
                ["type": "object", "properties": [:]]
            ),
            toolDef(
                "add_clip",
                """
                Add a video, image, or audio file. Returns clip_id plus track_id, file_path, timeline_start, duration, source_duration, and the fades actually stored. Images go on a video lane. \(MCPHandlers.editingBehavior) rippled and auto_crossfade in the result say whether this call moved other clips or wrote fades you did not ask for.
                """,
                editable([
                    "file_path": ["type": "string", "description": "Absolute path to a video, image, or audio file."],
                    "track_kind": ["type": "string", "enum": ["video", "audio"], "description": "Defaults to the detected kind. Images must use video."],
                    "start": ["type": "number", "description": "Timeline position in seconds. In playlist mode, an explicit start inserts and ripples later audio clips on that lane. Omit to append."],
                    "track_id": ["type": "string", "description": "UUID of the target track. Defaults to the primary video or audio lane."]
                ], required: ["file_path"])
            ),
            toolDef(
                "trim_clip",
                "Trim one clip's source in-point and/or duration. Does not ripple other clips and does not rewrite neighboring fades. Returned source_in, duration, fade_in, and fade_out are the clamped values. A trim that changes nothing does not bump revision.",
                editable([
                    "clip_id": ["type": "string"],
                    "new_in": ["type": "number", "description": "Source in-point in seconds"],
                    "new_duration": ["type": "number", "description": "Clip duration in seconds"]
                ], required: ["clip_id"])
            ),
            toolDef(
                "move_clip",
                "Move one clip to a new timeline position and/or track. Does not ripple other clips and does not apply the playlist auto-crossfade. A move that changes nothing does not bump revision.",
                editable([
                    "clip_id": ["type": "string"],
                    "new_start": ["type": "number", "description": "New timeline start in seconds"],
                    "track_id": ["type": "string", "description": "Move to a different track"]
                ], required: ["clip_id", "new_start"])
            ),
            toolDef(
                "split_clip",
                "Split one clip at a timeline position. Returns both clip ids. Does not ripple other clips. Playlist auto-crossfade is not reapplied.",
                editable([
                    "clip_id": ["type": "string"],
                    "at_time": ["type": "number", "description": "Timeline position to split at"]
                ], required: ["clip_id", "at_time"])
            ),
            toolDef(
                "delete_clip",
                "Delete a clip. confirmed must be true. A missing id returns clip_not_found and does not bump revision. In playlist mode, deleting an audio clip ripples the lane closed and reapplies the automatic crossfade; rippled and auto_crossfade in the result report what happened.",
                editable([
                    "clip_id": ["type": "string"],
                    "confirmed": ["type": "boolean", "description": "Must be true to delete"]
                ], required: ["clip_id"])
            ),
            toolDef(
                "set_clip_volume",
                "Set per-clip gain from 0 to 1. A value that is already stored does not bump revision.",
                editable([
                    "clip_id": ["type": "string"],
                    "gain": ["type": "number", "minimum": 0, "maximum": 1]
                ], required: ["clip_id", "gain"])
            ),
            toolDef(
                "set_track_volume",
                "Set a lane's volume from 0 to 1. Unknown track ids return track_not_found and do not bump revision.",
                editable([
                    "track_id": ["type": "string"],
                    "volume": ["type": "number", "minimum": 0, "maximum": 1]
                ], required: ["track_id", "volume"])
            ),
            toolDef(
                "toggle_mute",
                "Toggle one clip's mute.",
                editable([
                    "clip_id": ["type": "string"]
                ], required: ["clip_id"])
            ),
            toolDef(
                "set_fade_in",
                "Set one clip's fade-in in seconds. The stored length may be shorter than requested: fade-in plus fade-out cannot exceed the clip duration. The result's fade_in and fade_out are the stored values. Setting the same fade does not bump revision.",
                editable([
                    "clip_id": ["type": "string"],
                    "duration": ["type": "number", "minimum": 0]
                ], required: ["clip_id", "duration"])
            ),
            toolDef(
                "set_fade_out",
                "Set one clip's fade-out in seconds. The stored length may be shorter than requested: fade-in plus fade-out cannot exceed the clip duration. The result's fade_in and fade_out are the stored values. Setting the same fade does not bump revision.",
                editable([
                    "clip_id": ["type": "string"],
                    "duration": ["type": "number", "minimum": 0]
                ], required: ["clip_id", "duration"])
            ),
            toolDef(
                "clear_fades",
                "Remove both fades from a clip. Clearing fades that are already zero does not bump revision.",
                editable([
                    "clip_id": ["type": "string"]
                ], required: ["clip_id"])
            ),
            toolDef(
                "batch_edit",
                "Apply edit operations in order. This is not rolled back if a later operation fails: errors lists the failures and applied_ops counts how many ran. Ops are trim_clip, move_clip, set_clip_volume, set_fade_in, set_fade_out, clear_fades, toggle_mute, and crossfade_clips. Playlist ripple and auto-crossfade still apply to any included op that adds or deletes audio (none of the current ops do). A no-op op does not bump revision.",
                [
                    "type": "object",
                    "properties": [
                        "ops": ["type": "array", "items": ["type": "object"], "description": "Ordered list of operations. Each object has an action and that action's fields."],
                        "expected_revision": ["type": "integer", "description": "Reject the whole batch if the project revision is no longer this value. Nothing is applied."]
                    ],
                    "required": ["ops"]
                ]
            ),
            toolDef(
                "export_project",
                "Start an export and return immediately with the destination path that will actually be written. Poll get_export_status until is_exporting is false. succeeded is true and progress is 1 when the file is ready. An audio-only timeline is a WAV mixdown, so a .mp4 path may come back as .wav. This does not open a save panel. When the app was launched with --mcp it does not reveal the file in Finder. overwrite must be true to replace an existing file.",
                [
                    "type": "object",
                    "properties": [
                        "destination_path": ["type": "string", "description": "Absolute output path. The extension may be rewritten; trust the returned destination."],
                        "container": ["type": "string", "enum": ["mp4", "mov", "m4v"], "default": "mp4"],
                        "codec": ["type": "string", "enum": ["h264", "hevc", "proRes422", "proRes4444"], "default": "h264"],
                        "quality": ["type": "string", "enum": ["low", "medium", "high", "max"], "default": "high"],
                        "overwrite": ["type": "boolean", "description": "Allow overwriting an existing file", "default": false]
                    ],
                    "required": ["destination_path"]
                ]
            ),
            toolDef(
                "cancel_export",
                "Cancel the active export and delete the partial output. If nothing is exporting, revision is left unchanged.",
                ["type": "object", "properties": [:]]
            ),
            toolDef(
                "crossfade_clips",
                "Overlap two clips of the same kind and set complementary fades. This is separate from the automatic playlist crossfade, which runs on its own when audio clips are added or deleted in playlist mode.",
                editable([
                    "left_clip_id": ["type": "string", "description": "Clip that fades out"],
                    "right_clip_id": ["type": "string", "description": "Clip that fades in"],
                    "duration": ["type": "number", "minimum": 0, "description": "Requested overlap in seconds"]
                ], required: ["left_clip_id", "right_clip_id", "duration"])
            ),
            toolDef(
                "create_project_template",
                "Replace the current timeline with an empty multi-track template. confirmed must be true. This clears every clip. In an --mcp session it does not write the user's autosave.",
                [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Human-readable template name"],
                        "video_track_count": ["type": "integer", "minimum": 1, "maximum": 10, "default": 1],
                        "audio_track_count": ["type": "integer", "minimum": 1, "maximum": 20, "default": 1],
                        "save_path": ["type": "string", "description": "Optional absolute .salproject path"],
                        "overwrite": ["type": "boolean", "description": "Allow replacing an existing save file", "default": false],
                        "confirmed": ["type": "boolean", "description": "Must be true because this clears the current timeline"]
                    ],
                    "required": ["confirmed"]
                ]
            )
        ]
    }

    private func toolDef(_ name: String, _ desc: String, _ schema: [String: Any]) -> [String: Any] {
        ["name": name, "description": desc, "inputSchema": schema]
    }

    private func editable(_ properties: [String: Any], required: [String]) -> [String: Any] {
        var props = properties
        props["expected_revision"] = [
            "type": "integer",
            "description": "Reject the call if the project revision is no longer this value. The timeline is not changed."
        ]
        return [
            "type": "object",
            "properties": props,
            "required": required
        ]
    }

    // MARK: - Tool Dispatch

    private func callTool(name: String, arguments: [String: Any], requestId: Any) async -> Data {
        let result = await dispatchTool(name: name, arguments: arguments)
        switch result {
        case .success(let value):
            return MCPJSONRPC.response(id: requestId, result: [
                "content": [["type": "text", "text": encodeJSON(value)]]
            ])
        case .failure(let error):
            return MCPJSONRPC.response(id: requestId, result: [
                "isError": true,
                "content": [["type": "text", "text": encodeJSON(error.dict)]]
            ])
        }
    }

    private func encodeJSON(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj) else { return "{}" }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private struct MCPDictError: Error {
        let dict: [String: Any]
    }

    private func map(_ result: Result<[String: Any], MCPErrorResponse>) -> Result<[String: Any], MCPDictError> {
        switch result {
        case .success(let value):
            return .success(value)
        case .failure(let error):
            return .failure(errorDict(error))
        }
    }

    /// JSON numbers arrive as `NSNumber`. Casts to `Double` fail for whole
    /// numbers, which is how agents usually write `1` and `0`.
    private func coerceNumbers(_ arguments: [String: Any]) -> [String: Any] {
        var copy = arguments
        for (key, value) in arguments {
            if value is Bool { continue }
            if let number = value as? NSNumber {
                copy[key] = number.doubleValue
            }
        }
        return copy
    }

    private func intArg(_ arguments: [String: Any], _ key: String) -> Int? {
        if let int = arguments[key] as? Int { return int }
        if let double = arguments[key] as? Double, double.rounded() == double, abs(double) <= Double(Int.max) {
            return Int(double)
        }
        return nil
    }

    private func dispatchTool(name: String, arguments rawArguments: [String: Any]) async -> Result<[String: Any], MCPDictError> {
        let arguments = coerceNumbers(rawArguments)
        switch name {
        case "get_project_state":
            let compact = (arguments["compact"] as? Bool) ?? false
            return .success(MCPHandlers.getProjectState(model: model, compact: compact))

        case "get_export_status":
            return .success(MCPHandlers.getExportStatus(model: model))

        case "add_clip":
            if let conflict = checkExpectedRevision(arguments) { return .failure(conflict) }
            return map(await MCPHandlers.addClip(
                model: model,
                filePath: arguments["file_path"] as? String ?? "",
                trackKind: arguments["track_kind"] as? String,
                start: arguments["start"] as? Double,
                trackId: arguments["track_id"] as? String
            ))

        case "trim_clip":
            if let conflict = checkExpectedRevision(arguments) { return .failure(conflict) }
            return map(MCPHandlers.trimClip(
                model: model,
                clipId: arguments["clip_id"] as? String ?? "",
                newIn: arguments["new_in"] as? Double,
                newDuration: arguments["new_duration"] as? Double
            ))

        case "move_clip":
            if let conflict = checkExpectedRevision(arguments) { return .failure(conflict) }
            return map(MCPHandlers.moveClip(
                model: model,
                clipId: arguments["clip_id"] as? String ?? "",
                newStart: arguments["new_start"] as? Double ?? 0,
                trackId: arguments["track_id"] as? String
            ))

        case "split_clip":
            if let conflict = checkExpectedRevision(arguments) { return .failure(conflict) }
            return map(MCPHandlers.splitClip(
                model: model,
                clipId: arguments["clip_id"] as? String ?? "",
                atTime: arguments["at_time"] as? Double ?? 0
            ))

        case "delete_clip":
            if let conflict = checkExpectedRevision(arguments) { return .failure(conflict) }
            return map(MCPHandlers.deleteClip(
                model: model,
                clipId: arguments["clip_id"] as? String ?? "",
                confirmed: arguments["confirmed"] as? Bool ?? false
            ))

        case "set_clip_volume":
            if let conflict = checkExpectedRevision(arguments) { return .failure(conflict) }
            return map(MCPHandlers.setClipVolume(
                model: model,
                clipId: arguments["clip_id"] as? String ?? "",
                gain: arguments["gain"] as? Double ?? 1
            ))

        case "set_track_volume":
            if let conflict = checkExpectedRevision(arguments) { return .failure(conflict) }
            return map(MCPHandlers.setTrackVolume(
                model: model,
                trackId: arguments["track_id"] as? String ?? "",
                volume: arguments["volume"] as? Double ?? 1
            ))

        case "toggle_mute":
            if let conflict = checkExpectedRevision(arguments) { return .failure(conflict) }
            return map(MCPHandlers.toggleMute(model: model, clipId: arguments["clip_id"] as? String ?? ""))

        case "set_fade_in":
            if let conflict = checkExpectedRevision(arguments) { return .failure(conflict) }
            return map(MCPHandlers.setFade(
                model: model,
                clipId: arguments["clip_id"] as? String ?? "",
                direction: "in",
                duration: arguments["duration"] as? Double ?? 0
            ))

        case "set_fade_out":
            if let conflict = checkExpectedRevision(arguments) { return .failure(conflict) }
            return map(MCPHandlers.setFade(
                model: model,
                clipId: arguments["clip_id"] as? String ?? "",
                direction: "out",
                duration: arguments["duration"] as? Double ?? 0
            ))

        case "clear_fades":
            if let conflict = checkExpectedRevision(arguments) { return .failure(conflict) }
            return map(MCPHandlers.clearFades(model: model, clipId: arguments["clip_id"] as? String ?? ""))

        case "batch_edit":
            return batchEdit(arguments)

        case "export_project":
            return exportProject(arguments)

        case "cancel_export":
            let wasExporting = model.isExporting
            model.cancelExport()
            if wasExporting {
                model.bumpMCPRevision()
            }
            return .success(MCPHandlers.outcome(
                model,
                status: wasExporting ? "export_cancelled" : "unchanged"
            ))

        case "crossfade_clips":
            if let conflict = checkExpectedRevision(arguments) { return .failure(conflict) }
            let result = MCPHandlers.crossfadeClips(
                model: model,
                leftClipId: arguments["left_clip_id"] as? String ?? "",
                rightClipId: arguments["right_clip_id"] as? String ?? "",
                duration: arguments["duration"] as? Double ?? 0
            )
            switch result {
            case .success(let applied):
                return .success(MCPHandlers.outcome(model, status: "crossfade_applied", extra: [
                    "left_timeline_start": applied.0,
                    "applied_overlap": applied.1,
                    "fade_in": applied.2,
                    "note": "This crossfade is the one you requested. Playlist mode may also write its own 0.75s crossfades when audio clips are added or deleted."
                ]))
            case .failure(let error):
                return .failure(errorDict(error))
            }

        case "create_project_template":
            return await createProjectTemplate(arguments)

        default:
            return .failure(MCPDictError(dict: ["error": "unknown_tool", "message": "Unknown tool: \(name)"] as [String: Any]))
        }
    }

    private func checkExpectedRevision(_ args: [String: Any]) -> MCPDictError? {
        guard let expected = intArg(args, "expected_revision") else { return nil }
        let conflict = MCPHandlers.checkRevision(model: model, expected: expected)
        guard let conflict else { return nil }
        return errorDict(conflict)
    }

    private func batchEdit(_ args: [String: Any]) -> Result<[String: Any], MCPDictError> {
        if let conflict = checkExpectedRevision(args) { return .failure(conflict) }
        guard let opsRaw = args["ops"] as? [[String: Any]], !opsRaw.isEmpty else {
            return .failure(MCPDictError(dict: ["error": "invalid_ops", "message": "ops must be a non-empty array of operation objects"] as [String: Any]))
        }

        var errors: [[String: Any]] = []
        var applied = 0

        for (i, rawOp) in opsRaw.enumerated() {
            let op = coerceNumbers(rawOp)
            let action = op["action"] as? String ?? ""
            let result: Result<[String: Any], MCPErrorResponse>?
            switch action {
            case "trim_clip":
                result = MCPHandlers.trimClip(model: model, clipId: op["clip_id"] as? String ?? "", newIn: op["new_in"] as? Double, newDuration: op["new_duration"] as? Double)
            case "move_clip":
                result = MCPHandlers.moveClip(model: model, clipId: op["clip_id"] as? String ?? "", newStart: op["new_start"] as? Double ?? 0, trackId: op["track_id"] as? String)
            case "set_clip_volume":
                result = MCPHandlers.setClipVolume(model: model, clipId: op["clip_id"] as? String ?? "", gain: op["gain"] as? Double ?? 1)
            case "set_fade_in":
                result = MCPHandlers.setFade(model: model, clipId: op["clip_id"] as? String ?? "", direction: "in", duration: op["duration"] as? Double ?? 0)
            case "set_fade_out":
                result = MCPHandlers.setFade(model: model, clipId: op["clip_id"] as? String ?? "", direction: "out", duration: op["duration"] as? Double ?? 0)
            case "clear_fades":
                result = MCPHandlers.clearFades(model: model, clipId: op["clip_id"] as? String ?? "")
            case "toggle_mute":
                result = MCPHandlers.toggleMute(model: model, clipId: op["clip_id"] as? String ?? "")
            case "crossfade_clips":
                let crossfade = MCPHandlers.crossfadeClips(
                    model: model,
                    leftClipId: op["left_clip_id"] as? String ?? "",
                    rightClipId: op["right_clip_id"] as? String ?? "",
                    duration: op["duration"] as? Double ?? 0
                )
                switch crossfade {
                case .success:
                    result = .success([:])
                case .failure(let error):
                    result = .failure(error)
                }
            default:
                result = .failure(MCPErrorResponse(error: "unknown_action", message: "Unknown batch op action: '\(action)'", currentRevision: nil))
            }
            switch result {
            case .success:
                applied += 1
            case .failure(let error):
                errors.append(["index": i, "error": error.error, "message": error.message])
            case .none:
                errors.append(["index": i, "error": "unknown_action", "message": "Unknown batch op action: '\(action)'"])
            }
        }

        return .success([
            "success": errors.isEmpty,
            "applied_ops": applied,
            "total_ops": opsRaw.count,
            "errors": errors,
            "revision": model.mcpRevision,
            "audio_layout": model.audioLayoutMode == .playlist ? "playlist" : "layer",
            "editing_behavior": MCPHandlers.editingBehavior
        ])
    }

    private func createProjectTemplate(_ args: [String: Any]) async -> Result<[String: Any], MCPDictError> {
        guard args["confirmed"] as? Bool == true else {
            return .failure(MCPDictError(dict: [
                "error": "confirmation_required",
                "message": "Set confirmed=true to replace the current timeline with an empty template."
            ] as [String: Any]))
        }
        guard !model.isExporting else {
            return .failure(MCPDictError(dict: ["error": "export_in_progress", "message": "Cannot change the project during export"] as [String: Any]))
        }

        let videoCount = intArg(coerceNumbers(args), "video_track_count") ?? 1
        let audioCount = intArg(coerceNumbers(args), "audio_track_count") ?? 1
        guard (1...10).contains(videoCount), (1...20).contains(audioCount) else {
            return .failure(MCPDictError(dict: [
                "error": "invalid_track_count",
                "message": "video_track_count must be 1–10 and audio_track_count must be 1–20"
            ] as [String: Any]))
        }

        let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination: URL?
        if let savePath = args["save_path"] as? String, !savePath.isEmpty {
            let requested = URL(fileURLWithPath: savePath)
            let finalURL = requested.pathExtension.lowercased() == "salproject"
                ? requested
                : requested.deletingPathExtension().appendingPathExtension("salproject")
            if FileManager.default.fileExists(atPath: finalURL.path), args["overwrite"] as? Bool != true {
                return .failure(MCPDictError(dict: [
                    "error": "file_exists",
                    "message": "Destination already exists. Pass overwrite=true to replace it."
                ] as [String: Any]))
            }
            destination = finalURL
        } else {
            destination = nil
        }

        let previousRevision = model.mcpRevision
        await model.resetForTemplate(videoTrackCount: videoCount, audioTrackCount: audioCount, name: name)
        guard model.mcpRevision > previousRevision else {
            return .failure(MCPDictError(dict: ["error": "template_failed", "message": "Template could not be applied"] as [String: Any]))
        }

        var response: [String: Any] = [
            "status": "template_created",
            "video_track_count": videoCount,
            "audio_track_count": audioCount,
            "tracks": MCPHandlers.getProjectState(model: model, compact: true)["tracks"] ?? [],
            "revision": model.mcpRevision
        ]
        if let name { response["name"] = name }
        if let destination {
            do {
                try model.saveProjectDirect(to: destination)
                response["saved_path"] = destination.path
            } catch {
                response["save_error"] = error.localizedDescription
            }
        }
        return .success(response)
    }

    private func exportProject(_ args: [String: Any]) -> Result<[String: Any], MCPDictError> {
        guard let destPath = args["destination_path"] as? String, !destPath.isEmpty else {
            return .failure(MCPDictError(dict: ["error": "missing_destination", "message": "destination_path is required"] as [String: Any]))
        }
        guard !model.isExporting else {
            return .failure(MCPDictError(dict: ["error": "export_in_progress", "message": "An export is already running"] as [String: Any]))
        }

        let container = (args["container"] as? String)?.lowercased() ?? "mp4"
        let codecRaw = (args["codec"] as? String)?.lowercased() ?? "h264"
        let qualityRaw = (args["quality"] as? String)?.lowercased() ?? "high"
        let overwrite = args["overwrite"] as? Bool ?? false

        let containerEnum: ExportSettings.Container
        switch container {
        case "mp4": containerEnum = .mp4
        case "mov": containerEnum = .mov
        case "m4v": containerEnum = .m4v
        default:
            return .failure(MCPDictError(dict: ["error": "invalid_container", "message": "container must be mp4, mov, or m4v"] as [String: Any]))
        }

        let codecEnum: ExportSettings.Codec
        switch codecRaw {
        case "h264": codecEnum = .h264
        case "hevc": codecEnum = .hevc
        case "prores422": codecEnum = .proRes422
        case "prores4444": codecEnum = .proRes4444
        default:
            return .failure(MCPDictError(dict: ["error": "invalid_codec", "message": "codec must be h264, hevc, prores422, or prores4444"] as [String: Any]))
        }

        let qualityEnum: ExportSettings.Quality
        switch qualityRaw {
        case "low": qualityEnum = .low
        case "medium": qualityEnum = .medium
        case "high": qualityEnum = .high
        case "max": qualityEnum = .max
        default:
            return .failure(MCPDictError(dict: ["error": "invalid_quality", "message": "quality must be low, medium, high, or max"] as [String: Any]))
        }

        var settings = ExportSettings()
        settings.container = containerEnum
        settings.codec = codecEnum
        settings.quality = qualityEnum
        settings.fileBaseName = URL(fileURLWithPath: destPath).deletingPathExtension().lastPathComponent

        let prepared = model.preparedExport(settings: settings, destination: URL(fileURLWithPath: destPath))
        let finalURL = prepared.destination

        if FileManager.default.fileExists(atPath: finalURL.path), !overwrite {
            return .failure(MCPDictError(dict: ["error": "file_exists", "message": "Destination already exists. Pass overwrite=true to replace it."] as [String: Any]))
        }

        guard model.beginExportDirect(settings: prepared.settings, destination: finalURL) else {
            return .failure(MCPDictError(dict: [
                "error": "export_not_started",
                "message": "Another export is already running, or nothing is loaded to export."
            ] as [String: Any]))
        }

        let audioOnly = prepared.settings.mode == .audio
        return .success([
            "status": "started",
            "destination": finalURL.path,
            "container": audioOnly ? prepared.settings.pathExtension : container,
            "codec": codecRaw,
            "quality": qualityRaw,
            "revision": model.mcpRevision,
            "finder_reveal": model.revealExportsInFinder,
            "note": audioOnly
                ? "Audio-only timeline. This file is a WAV mixdown; the extension may differ from the path you passed. Finder is not opened. Poll get_export_status until is_exporting is false."
                : "Export is running in the background. Finder is not opened when the app was launched with --mcp. Poll get_export_status until is_exporting is false and succeeded is true."
        ])
    }

    private func errorDict(_ error: MCPErrorResponse) -> MCPDictError {
        var dict: [String: Any] = ["error": error.error, "message": error.message]
        if let revision = error.currentRevision {
            dict["current_revision"] = revision
        }
        return MCPDictError(dict: dict)
    }
}
