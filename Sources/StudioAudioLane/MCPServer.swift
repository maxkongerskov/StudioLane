import Foundation

// MARK: - MCP Server (stdio JSON-RPC)

@MainActor
final class MCPServer {
    private let model: EditorModel
    private var isRunning = false

    init(model: EditorModel) {
        self.model = model
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        readLoop()
    }

    func stop() {
        isRunning = false
    }

    private func readLoop() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let stdin = FileHandle.standardInput
            while self.isRunning {
                guard let line = stdin.readLine(),
                      !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    Thread.sleep(forTimeInterval: 0.05)
                    continue
                }
                Task { @MainActor in
                    self.handleMessage(line)
                }
            }
        }
    }

    private func handleMessage(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            writeResponse(MCPJSONRPC.error(id: NSNull(), code: -32700, message: "Parse error"))
            return
        }

        guard let method = dict["method"] as? String else {
            if let id = dict["id"] {
                writeResponse(MCPJSONRPC.error(id: id, code: -32600, message: "Invalid request"))
            }
            return
        }

        let id = dict["id"] ?? NSNull()

        switch method {
        case "initialize":
            writeResponse(MCPJSONRPC.response(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "studioaudiolane", "version": "1.0.0"]
            ]))

        case "notifications/initialized":
            break // No response needed

        case "tools/list":
            writeResponse(MCPJSONRPC.response(id: id, result: ["tools": toolDefinitions]))

        case "tools/call":
            guard let params = dict["params"] as? [String: Any],
                  let toolName = params["name"] as? String else {
                writeResponse(MCPJSONRPC.error(id: id, code: -32602, message: "Missing tool name"))
                return
            }
            let args = (params["arguments"] as? [String: Any]) ?? [:]
            Task { @MainActor in
                let result = await self.callTool(name: toolName, arguments: args)
                self.writeResponse(result)
            }

        default:
            writeResponse(MCPJSONRPC.error(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    private func writeResponse(_ data: Data) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    // MARK: - Tool Registry

    private var toolDefinitions: [[String: Any]] {
        [
            toolDef("get_project_state", "Get current timeline state: tracks, clips, fades, volumes, revision", [
                "type": "object",
                "properties": ["compact": ["type": "boolean", "description": "Omit default/zero fields for smaller output"]]
            ]),
            toolDef("get_export_status", "Check if an export is running, its progress, and destination", [
                "type": "object", "properties": [:]
            ]),
            toolDef("add_clip", "Add a media file to the timeline", [
                "type": "object",
                "properties": [
                    "file_path": ["type": "string", "description": "Absolute path to media file"],
                    "track_kind": ["type": "string", "enum": ["video", "audio"], "description": "Defaults to detected kind"],
                    "start": ["type": "number", "description": "Timeline position in seconds (default: append to end)"],
                    "track_id": ["type": "string", "description": "UUID of target track (default: focused)"]
                ],
                "required": ["file_path"]
            ]),
            toolDef("trim_clip", "Trim clip source in-point and/or duration", [
                "type": "object",
                "properties": [
                    "clip_id": ["type": "string"],
                    "new_in": ["type": "number", "description": "Source in-point in seconds"],
                    "new_duration": ["type": "number", "description": "Clip duration in seconds"]
                ],
                "required": ["clip_id"]
            ]),
            toolDef("move_clip", "Move clip to new timeline position and/or track", [
                "type": "object",
                "properties": [
                    "clip_id": ["type": "string"],
                    "new_start": ["type": "number", "description": "New timeline start in seconds"],
                    "track_id": ["type": "string", "description": "Move to different track"]
                ],
                "required": ["clip_id", "new_start"]
            ]),
            toolDef("split_clip", "Split clip at timeline position", [
                "type": "object",
                "properties": [
                    "clip_id": ["type": "string"],
                    "at_time": ["type": "number", "description": "Timeline position to split at"]
                ],
                "required": ["clip_id", "at_time"]
            ]),
            toolDef("delete_clip", "Delete a clip from the timeline", [
                "type": "object",
                "properties": [
                    "clip_id": ["type": "string"],
                    "confirmed": ["type": "boolean", "description": "Must be true to delete"]
                ],
                "required": ["clip_id"]
            ]),
            toolDef("set_clip_volume", "Set per-clip gain (0–1)", [
                "type": "object",
                "properties": [
                    "clip_id": ["type": "string"],
                    "gain": ["type": "number", "minimum": 0, "maximum": 1]
                ],
                "required": ["clip_id", "gain"]
            ]),
            toolDef("set_track_volume", "Set track master volume (0–1)", [
                "type": "object",
                "properties": [
                    "track_id": ["type": "string"],
                    "volume": ["type": "number", "minimum": 0, "maximum": 1]
                ],
                "required": ["track_id", "volume"]
            ]),
            toolDef("toggle_mute", "Toggle clip audio mute", [
                "type": "object",
                "properties": ["clip_id": ["type": "string"]],
                "required": ["clip_id"]
            ]),
            toolDef("set_fade_in", "Set clip fade-in duration in seconds (video or audio)", [
                "type": "object",
                "properties": [
                    "clip_id": ["type": "string"],
                    "duration": ["type": "number", "minimum": 0]
                ],
                "required": ["clip_id", "duration"]
            ]),
            toolDef("set_fade_out", "Set clip fade-out duration in seconds (video or audio)", [
                "type": "object",
                "properties": [
                    "clip_id": ["type": "string"],
                    "duration": ["type": "number", "minimum": 0]
                ],
                "required": ["clip_id", "duration"]
            ]),
            toolDef("clear_fades", "Remove all fades from a clip", [
                "type": "object",
                "properties": ["clip_id": ["type": "string"]],
                "required": ["clip_id"]
            ]),
            toolDef("batch_edit", "Apply multiple edit operations atomically", [
                "type": "object",
                "properties": [
                    "ops": ["type": "array", "items": ["type": "object"], "description": "Ordered list of operations"],
                    "expected_revision": ["type": "integer", "description": "Reject if model revision differs"]
                ],
                "required": ["ops"]
            ]),
            toolDef("export_project", "Export timeline to MP4/MOV/M4V file", [
                "type": "object",
                "properties": [
                    "destination_path": ["type": "string", "description": "Absolute output path"],
                    "container": ["type": "string", "enum": ["mp4", "mov", "m4v"], "default": "mp4"],
                    "codec": ["type": "string", "enum": ["h264", "hevc", "proRes422", "proRes4444"], "default": "h264"],
                    "quality": ["type": "string", "enum": ["low", "medium", "high", "max"], "default": "high"],
                    "overwrite": ["type": "boolean", "description": "Allow overwriting existing file", "default": false]
                ],
                "required": ["destination_path"]
            ]),
            toolDef("cancel_export", "Cancel active export and delete partial output", [
                "type": "object", "properties": [:]
            ])
        ]
    }

    private func toolDef(_ name: String, _ desc: String, _ schema: [String: Any]) -> [String: Any] {
        ["name": name, "description": desc, "inputSchema": schema]
    }

    // MARK: - Tool Dispatch

    private func callTool(name: String, arguments: [String: Any]) async -> Data {
        let result = await dispatchTool(name: name, arguments: arguments)
        switch result {
        case .success(let value):
            return MCPJSONRPC.response(id: arguments["__id"] ?? NSNull(), result: [
                "content": [["type": "text", "text": encodeJSON(value)]]
            ])
        case .failure(let error):
            return MCPJSONRPC.response(id: arguments["__id"] ?? NSNull(), result: [
                "isError": true,
                "content": [["type": "text", "text": encodeJSON(error)]]
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

    private func dispatchTool(name: String, arguments: [String: Any]) async -> Result<[String: Any], MCPDictError> {
        let id = arguments["__id"] ?? NSNull()

        switch name {
        case "get_project_state":
            let compact = (arguments["compact"] as? Bool) ?? false
            return .success(MCPHandlers.getProjectState(model: model, compact: compact))

        case "get_export_status":
            return .success(MCPHandlers.getExportStatus(model: model))

        case "add_clip":
            let filePath = arguments["file_path"] as? String ?? ""
            let trackKind = arguments["track_kind"] as? String
            let start = arguments["start"] as? Double
            let trackId = arguments["track_id"] as? String
            let result = await MCPHandlers.addClip(model: model, filePath: filePath, trackKind: trackKind, start: start, trackId: trackId)
            switch result {
            case .success:
                return .success(["status": "added", "revision": MCPHandlers.mcpRevision])
            case .failure(let e):
                return .failure(MCPErrorResponseDict(e))
            }

        case "trim_clip":
            if let conflict = checkExpectedRevision(arguments) { return .failure(conflict) }
            let error = MCPHandlers.trimClip(model: model, clipId: arguments["clip_id"] as? String ?? "", newIn: arguments["new_in"] as? Double, newDuration: arguments["new_duration"] as? Double)
            if let e = error { return .failure(MCPErrorResponseDict(e)) }
            return .success(["status": "trimmed", "revision": MCPHandlers.mcpRevision])

        case "move_clip":
            if let conflict = checkExpectedRevision(arguments) { return .failure(conflict) }
            let error = MCPHandlers.moveClip(model: model, clipId: arguments["clip_id"] as? String ?? "", newStart: arguments["new_start"] as? Double ?? 0, trackId: arguments["track_id"] as? String)
            if let e = error { return .failure(MCPErrorResponseDict(e)) }
            return .success(["status": "moved", "revision": MCPHandlers.mcpRevision])

        case "split_clip":
            if let conflict = checkExpectedRevision(arguments) { return .failure(conflict) }
            let result = MCPHandlers.splitClip(model: model, clipId: arguments["clip_id"] as? String ?? "", atTime: arguments["at_time"] as? Double ?? 0)
            switch result {
            case .success(let ids):
                return .success(["status": "split", "clip_ids": ids, "revision": MCPHandlers.mcpRevision])
            case .failure(let e):
                return .failure(MCPErrorResponseDict(e))
            }

        case "delete_clip":
            if let conflict = checkExpectedRevision(arguments) { return .failure(conflict) }
            let result = MCPHandlers.deleteClip(model: model, clipId: arguments["clip_id"] as? String ?? "", confirmed: arguments["confirmed"] as? Bool ?? false)
            switch result {
            case .success:
                return .success(["status": "deleted", "revision": MCPHandlers.mcpRevision])
            case .failure(let e):
                return .failure(MCPErrorResponseDict(e))
            }

        case "set_clip_volume":
            if let conflict = checkExpectedRevision(arguments) { return .failure(conflict) }
            let error = MCPHandlers.setClipVolume(model: model, clipId: arguments["clip_id"] as? String ?? "", gain: arguments["gain"] as? Double ?? 1)
            if let e = error { return .failure(MCPErrorResponseDict(e)) }
            return .success(["status": "volume_set", "revision": MCPHandlers.mcpRevision])

        case "set_track_volume":
            if let conflict = checkExpectedRevision(arguments) { return .failure(conflict) }
            let error = MCPHandlers.setTrackVolume(model: model, trackId: arguments["track_id"] as? String ?? "", volume: arguments["volume"] as? Double ?? 1)
            if let e = error { return .failure(MCPErrorResponseDict(e)) }
            return .success(["status": "track_volume_set", "revision": MCPHandlers.mcpRevision])

        case "toggle_mute":
            if let conflict = checkExpectedRevision(arguments) { return .failure(conflict) }
            let error = MCPHandlers.toggleMute(model: model, clipId: arguments["clip_id"] as? String ?? "")
            if let e = error { return .failure(MCPErrorResponseDict(e)) }
            return .success(["status": "muted_toggled", "revision": MCPHandlers.mcpRevision])

        case "set_fade_in":
            if let conflict = checkExpectedRevision(arguments) { return .failure(conflict) }
            let error = MCPHandlers.setFade(model: model, clipId: arguments["clip_id"] as? String ?? "", direction: "in", duration: arguments["duration"] as? Double ?? 0)
            if let e = error { return .failure(MCPErrorResponseDict(e)) }
            return .success(["status": "fade_in_set", "revision": MCPHandlers.mcpRevision])

        case "set_fade_out":
            if let conflict = checkExpectedRevision(arguments) { return .failure(conflict) }
            let error = MCPHandlers.setFade(model: model, clipId: arguments["clip_id"] as? String ?? "", direction: "out", duration: arguments["duration"] as? Double ?? 0)
            if let e = error { return .failure(MCPErrorResponseDict(e)) }
            return .success(["status": "fade_out_set", "revision": MCPHandlers.mcpRevision])

        case "clear_fades":
            if let conflict = checkExpectedRevision(arguments) { return .failure(conflict) }
            let error = MCPHandlers.clearFades(model: model, clipId: arguments["clip_id"] as? String ?? "")
            if let e = error { return .failure(MCPErrorResponseDict(e)) }
            return .success(["status": "fades_cleared", "revision": MCPHandlers.mcpRevision])

        case "batch_edit":
            return await batchEdit(arguments)

        case "export_project":
            return exportProject(arguments)

        case "cancel_export":
            model.cancelExport()
            MCPHandlers.bumpRevision()
            return .success(["status": "export_cancelled", "revision": MCPHandlers.mcpRevision])

        default:
        return .failure(MCPDictError(dict: ["error": "unknown_tool", "message": "Unknown tool: \(name)"] as [String: Any]))
        }
    }

    private func checkExpectedRevision(_ args: [String: Any]) -> MCPDictError? {
        guard let expected = args["expected_revision"] as? Int else { return nil }
        let conflict = MCPHandlers.checkRevision(expected: expected)
        guard let c = conflict else { return nil }
        return MCPErrorResponseDict(c)
    }

    private func batchEdit(_ args: [String: Any]) async -> Result<[String: Any], MCPDictError> {
        if let conflict = checkExpectedRevision(args) { return .failure(conflict) }
        guard let opsRaw = args["ops"] as? [[String: Any]], !opsRaw.isEmpty else {
        return .failure(MCPDictError(dict: ["error": "invalid_ops", "message": "ops must be a non-empty array of operation objects"] as [String: Any]))
        }

        var errors: [[String: Any]] = []
        var applied = 0

        for (i, op) in opsRaw.enumerated() {
            let action = op["action"] as? String ?? ""
            switch action {
            case "trim_clip":
                if let e = MCPHandlers.trimClip(model: model, clipId: op["clip_id"] as? String ?? "", newIn: op["new_in"] as? Double, newDuration: op["new_duration"] as? Double) {
                    errors.append(["index": i, "error": e.error, "message": e.message])
                } else { applied += 1 }
            case "move_clip":
                if let e = MCPHandlers.moveClip(model: model, clipId: op["clip_id"] as? String ?? "", newStart: op["new_start"] as? Double ?? 0, trackId: op["track_id"] as? String) {
                    errors.append(["index": i, "error": e.error, "message": e.message])
                } else { applied += 1 }
            case "set_clip_volume":
                if let e = MCPHandlers.setClipVolume(model: model, clipId: op["clip_id"] as? String ?? "", gain: op["gain"] as? Double ?? 1) {
                    errors.append(["index": i, "error": e.error, "message": e.message])
                } else { applied += 1 }
            case "set_fade_in":
                if let e = MCPHandlers.setFade(model: model, clipId: op["clip_id"] as? String ?? "", direction: "in", duration: op["duration"] as? Double ?? 0) {
                    errors.append(["index": i, "error": e.error, "message": e.message])
                } else { applied += 1 }
            case "set_fade_out":
                if let e = MCPHandlers.setFade(model: model, clipId: op["clip_id"] as? String ?? "", direction: "out", duration: op["duration"] as? Double ?? 0) {
                    errors.append(["index": i, "error": e.error, "message": e.message])
                } else { applied += 1 }
            case "clear_fades":
                if let e = MCPHandlers.clearFades(model: model, clipId: op["clip_id"] as? String ?? "") {
                    errors.append(["index": i, "error": e.error, "message": e.message])
                } else { applied += 1 }
            case "toggle_mute":
                if let e = MCPHandlers.toggleMute(model: model, clipId: op["clip_id"] as? String ?? "") {
                    errors.append(["index": i, "error": e.error, "message": e.message])
                } else { applied += 1 }
            default:
                errors.append(["index": i, "error": "unknown_action", "message": "Unknown batch op action: '\(action)'"])
            }
        }

        return .success([
            "success": errors.isEmpty,
            "applied_ops": applied,
            "total_ops": opsRaw.count,
            "errors": errors,
            "revision": MCPHandlers.mcpRevision
        ])
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

        let destURL = URL(fileURLWithPath: destPath)
        let ext = containerEnum.pathExtension
        let finalURL = destURL.pathExtension.lowercased() == ext
            ? destURL
            : destURL.deletingPathExtension().appendingPathExtension(ext)

        if FileManager.default.fileExists(atPath: finalURL.path), !overwrite {
            return .failure(MCPDictError(dict: ["error": "file_exists", "message": "Destination already exists. Pass overwrite=true to replace it."] as [String: Any]))
        }

        // Bypass the save panel and start the export directly.
        model.beginExportDirect(settings: settings, destination: finalURL)

        return .success([
            "status": "started",
            "destination": finalURL.path,
            "container": container,
            "codec": codecRaw,
            "quality": qualityRaw,
            "revision": MCPHandlers.mcpRevision
        ])
    }

    private func MCPErrorResponseDict(_ e: MCPErrorResponse) -> MCPDictError {
        var dict: [String: Any] = ["error": e.error, "message": e.message]
        if let rev = e.currentRevision {
            dict["current_revision"] = rev
        }
        return MCPDictError(dict: dict)
    }
}

// MARK: - FileHandle line reading extension

private extension FileHandle {
    func readLine() -> String? {
        var data = Data()
        while true {
            let chunk = readData(ofLength: 1)
            guard !chunk.isEmpty else {
                return data.isEmpty ? nil : String(data: data, encoding: .utf8)
            }
            if let byte = chunk.first, byte == UInt8(ascii: "\n") {
                break
            }
            data.append(chunk)
        }
        return String(data: data, encoding: .utf8)
    }
}
