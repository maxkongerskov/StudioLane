import Foundation

// MARK: - MCP Tool Handlers

@MainActor
enum MCPHandlers {
    static var mcpRevision: Int { model_revision }
    private static var model_revision: Int = 0

    static func bumpRevision() {
        model_revision += 1
    }

    // MARK: Read Tools

    static func getProjectState(model: EditorModel, compact: Bool) -> [String: Any] {
        let tracks = model.tracks.map { track in
            [
                "id": track.id.uuidString,
                "kind": track.kind == .video ? "video" : "audio",
                "name": track.name,
                "volume": Double(track.volume)
            ]
        }

        let allClips = model.videoClips + model.audioClips
        let clips: [[String: Any]] = allClips.map { clip in
            var dict: [String: Any] = [
                "id": clip.id.uuidString,
                "track_id": clip.trackID.uuidString,
                "name": clip.displayName,
                "timeline_start": clip.timelineStart,
                "duration": clip.duration,
                "fade_in": clip.fadeIn,
                "fade_out": clip.fadeOut
            ]
            if !compact {
                dict["source_in"] = clip.inPoint
                dict["gain"] = Double(clip.gain)
                dict["muted"] = clip.muted
            } else {
                if clip.inPoint > 0.001 { dict["source_in"] = clip.inPoint }
                if abs(Double(clip.gain) - 1.0) > 0.001 { dict["gain"] = Double(clip.gain) }
                if clip.muted { dict["muted"] = true }
            }
            return dict
        }

        return [
            "revision": model_revision,
            "timeline_duration": model.duration,
            "is_playing": model.isPlaying,
            "is_exporting": model.isExporting,
            "tracks": tracks,
            "clips": clips
        ]
    }

    static func getExportStatus(model: EditorModel) -> [String: Any] {
        var dict: [String: Any] = [
            "is_exporting": model.isExporting,
            "progress": model.exportProgress
        ]
        if let url = model.exportDestinationURL {
            dict["destination"] = url.path
        }
        if let error = model.errorMessage {
            dict["error"] = error
        }
        return dict
    }

    // MARK: Revision Check

    static func checkRevision(expected: Int?) -> MCPErrorResponse? {
        guard let expected, expected != model_revision else { return nil }
        return MCPErrorResponse(
            error: "revision_conflict",
            message: "Expected revision \(expected) but current is \(model_revision). Re-read state before editing.",
            currentRevision: model_revision
        )
    }

    // MARK: Edit Tools

    static func addClip(
        model: EditorModel,
        filePath: String,
        trackKind: String?,
        start: Double?,
        trackId: String?
    ) async -> Result<Void, MCPErrorResponse> {
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(MCPErrorResponse(error: "file_not_found", message: "File does not exist: \(filePath)", currentRevision: nil))
        }
        _ = url.startAccessingSecurityScopedResource()

        let kind: TimelineTrack.Kind
        if let k = trackKind {
            switch k.lowercased() {
            case "video": kind = .video
            case "audio", "music": kind = .audio
            default:
                return .failure(MCPErrorResponse(error: "invalid_track_kind", message: "trackKind must be 'video' or 'audio', got '\(k)'", currentRevision: nil))
            }
        } else {
            kind = EditorModel.mediaKind(for: url)
        }

        let trackID: UUID
        if let tid = trackId, let uuid = UUID(uuidString: tid) {
            trackID = uuid
        } else {
            trackID = kind == .video ? EditorModel.defaultVideoTrackID : EditorModel.defaultAudioTrackID
        }

        model.bumpMCPRevision()
        if kind == .video {
            await model.addVideoPublic(url: url, start: start.map { TimeInterval($0) }, ontoTrackID: trackID)
        } else {
            await model.addAudioPublic(url: url, start: start.map { TimeInterval($0) }, ontoTrackID: trackID)
        }
        return .success(())
    }

    static func trimClip(model: EditorModel, clipId: String, newIn: Double?, newDuration: Double?) -> MCPErrorResponse? {
        guard let uuid = UUID(uuidString: clipId) else {
            return MCPErrorResponse(error: "invalid_clip_id", message: "Not a UUID: \(clipId)", currentRevision: nil)
        }
        if let vi = model.videoIndexPublic(uuid) {
            var clip = model.videoClips[vi]
            if let newInValue = newIn {
                let maxIn = max(0, clip.sourceDuration - EditorModel.minimumClipDuration)
                clip.inPoint = min(max(0, newInValue), maxIn)
            }
            if let newDur = newDuration {
                let maxDur = clip.sourceDuration - clip.inPoint
                clip.duration = min(max(EditorModel.minimumClipDuration, newDur), maxDur)
            }
            clip.clampFades()
            model.videoClips[vi] = clip
            model.bumpMCPRevision()
            Task { await model.rebuildCompositionPublic() }
            return nil
        }
        if let ai = model.audioIndexPublic(uuid) {
            var clip = model.audioClips[ai]
            if let newInValue = newIn {
                let maxIn = max(0, clip.sourceDuration - EditorModel.minimumClipDuration)
                clip.inPoint = min(max(0, newInValue), maxIn)
            }
            if let newDur = newDuration {
                let maxDur = clip.sourceDuration - clip.inPoint
                clip.duration = min(max(EditorModel.minimumClipDuration, newDur), maxDur)
            }
            clip.clampFades()
            model.audioClips[ai] = clip
            model.bumpMCPRevision()
            Task { await model.rebuildCompositionPublic() }
            return nil
        }
        return MCPErrorResponse(error: "clip_not_found", message: "No clip with id \(clipId)", currentRevision: nil)
    }

    static func moveClip(model: EditorModel, clipId: String, newStart: Double, trackId: String?) -> MCPErrorResponse? {
        guard let uuid = UUID(uuidString: clipId) else {
            return MCPErrorResponse(error: "invalid_clip_id", message: "Not a UUID: \(clipId)", currentRevision: nil)
        }
        let newTrackID: UUID?
        if let tid = trackId, let uuid2 = UUID(uuidString: tid) { newTrackID = uuid2 } else { newTrackID = nil }

        if let vi = model.videoIndexPublic(uuid) {
            var clip = model.videoClips[vi]
            clip.timelineStart = max(0, newStart)
            if let nt = newTrackID { clip.trackID = nt }
            model.videoClips[vi] = clip
            model.bumpMCPRevision()
            Task { await model.rebuildCompositionPublic() }
            return nil
        }
        if let ai = model.audioIndexPublic(uuid) {
            var clip = model.audioClips[ai]
            clip.timelineStart = max(0, newStart)
            if let nt = newTrackID { clip.trackID = nt }
            model.audioClips[ai] = clip
            model.bumpMCPRevision()
            Task { await model.rebuildCompositionPublic() }
            return nil
        }
        return MCPErrorResponse(error: "clip_not_found", message: "No clip with id \(clipId)", currentRevision: nil)
    }

    static func splitClip(model: EditorModel, clipId: String, atTime: Double) -> Result<[String], MCPErrorResponse> {
        guard let uuid = UUID(uuidString: clipId) else {
            return .failure(MCPErrorResponse(error: "invalid_clip_id", message: "Not a UUID: \(clipId)", currentRevision: nil))
        }
        if let vi = model.videoIndexPublic(uuid) {
            let clip = model.videoClips[vi]
            guard atTime > clip.timelineStart + EditorModel.minimumClipDuration,
                  atTime < clip.timelineEnd - EditorModel.minimumClipDuration else {
                return .failure(MCPErrorResponse(error: "split_out_of_range", message: "Split time must be within clip bounds (excluding minimum duration)", currentRevision: nil))
            }
            let parts = model.gaplessSplitPublic(clip, at: atTime)
            model.videoClips[vi] = parts.left
            model.videoClips.insert(parts.right, at: vi + 1)
            model.bumpMCPRevision()
            Task { await model.rebuildCompositionPublic() }
            return .success([parts.left.id.uuidString, parts.right.id.uuidString])
        }
        if let ai = model.audioIndexPublic(uuid) {
            let clip = model.audioClips[ai]
            guard atTime > clip.timelineStart + EditorModel.minimumClipDuration,
                  atTime < clip.timelineEnd - EditorModel.minimumClipDuration else {
                return .failure(MCPErrorResponse(error: "split_out_of_range", message: "Split time must be within clip bounds", currentRevision: nil))
            }
            let parts = model.gaplessSplitPublic(clip, at: atTime)
            var right = parts.right
            right.waveform = clip.waveform
            model.audioClips[ai] = parts.left
            model.audioClips.insert(right, at: ai + 1)
            model.bumpMCPRevision()
            Task { await model.rebuildCompositionPublic() }
            return .success([parts.left.id.uuidString, parts.right.id.uuidString])
        }
        return .failure(MCPErrorResponse(error: "clip_not_found", message: "No clip with id \(clipId)", currentRevision: nil))
    }

    static func deleteClip(model: EditorModel, clipId: String, confirmed: Bool) -> Result<Void, MCPErrorResponse> {
        guard let uuid = UUID(uuidString: clipId) else {
            return .failure(MCPErrorResponse(error: "invalid_clip_id", message: "Not a UUID: \(clipId)", currentRevision: nil))
        }
        guard confirmed else {
            return .failure(MCPErrorResponse(
                error: "confirmation_required",
                message: "Set confirmed=true to delete this clip.",
                currentRevision: nil
            ))
        }
        model.bumpMCPRevision()
        model.deleteClipPublic(clipID: uuid)
        return .success(())
    }

    static func setClipVolume(model: EditorModel, clipId: String, gain: Double) -> MCPErrorResponse? {
        guard let uuid = UUID(uuidString: clipId) else {
            return MCPErrorResponse(error: "invalid_clip_id", message: "Not a UUID: \(clipId)", currentRevision: nil)
        }
        let clamped = Float(min(max(0, gain), 1))
        if let vi = model.videoIndexPublic(uuid) {
            var clip = model.videoClips[vi]
            clip.gain = clamped
            model.videoClips[vi] = clip
            model.bumpMCPRevision()
            model.applyFadesPublic()
            return nil
        }
        if let ai = model.audioIndexPublic(uuid) {
            var clip = model.audioClips[ai]
            clip.gain = clamped
            model.audioClips[ai] = clip
            model.bumpMCPRevision()
            model.applyFadesPublic()
            return nil
        }
        return MCPErrorResponse(error: "clip_not_found", message: "No clip with id \(clipId)", currentRevision: nil)
    }

    static func setTrackVolume(model: EditorModel, trackId: String, volume: Double) -> MCPErrorResponse? {
        guard let uuid = UUID(uuidString: trackId) else {
            return MCPErrorResponse(error: "invalid_track_id", message: "Not a UUID: \(trackId)", currentRevision: nil)
        }
        model.setTrackVolume(uuid, Float(min(max(0, volume), 1)))
        model.bumpMCPRevision()
        return nil
    }

    static func toggleMute(model: EditorModel, clipId: String) -> MCPErrorResponse? {
        guard let uuid = UUID(uuidString: clipId) else {
            return MCPErrorResponse(error: "invalid_clip_id", message: "Not a UUID: \(clipId)", currentRevision: nil)
        }
        if let vi = model.videoIndexPublic(uuid) {
            model.videoClips[vi].muted.toggle()
            model.bumpMCPRevision()
            model.applyFadesPublic()
            return nil
        }
        if let ai = model.audioIndexPublic(uuid) {
            model.audioClips[ai].muted.toggle()
            model.bumpMCPRevision()
            model.applyFadesPublic()
            return nil
        }
        return MCPErrorResponse(error: "clip_not_found", message: "No clip with id \(clipId)", currentRevision: nil)
    }

    static func setFade(model: EditorModel, clipId: String, direction: String, duration: Double) -> MCPErrorResponse? {
        guard let uuid = UUID(uuidString: clipId) else {
            return MCPErrorResponse(error: "invalid_clip_id", message: "Not a UUID: \(clipId)", currentRevision: nil)
        }
        let d = max(0, duration)
        if let vi = model.videoIndexPublic(uuid) {
            var clip = model.videoClips[vi]
            if direction == "in" { clip.fadeIn = d } else { clip.fadeOut = d }
            clip.clampFades()
            model.videoClips[vi] = clip
            model.bumpMCPRevision()
            model.applyFadesPublic()
            return nil
        }
        if let ai = model.audioIndexPublic(uuid) {
            var clip = model.audioClips[ai]
            if direction == "in" { clip.fadeIn = d } else { clip.fadeOut = d }
            clip.clampFades()
            model.audioClips[ai] = clip
            model.bumpMCPRevision()
            model.applyFadesPublic()
            return nil
        }
        return MCPErrorResponse(error: "clip_not_found", message: "No clip with id \(clipId)", currentRevision: nil)
    }

    static func clearFades(model: EditorModel, clipId: String) -> MCPErrorResponse? {
        guard let uuid = UUID(uuidString: clipId) else {
            return MCPErrorResponse(error: "invalid_clip_id", message: "Not a UUID: \(clipId)", currentRevision: nil)
        }
        if let vi = model.videoIndexPublic(uuid) {
            model.videoClips[vi].fadeIn = 0
            model.videoClips[vi].fadeOut = 0
            model.bumpMCPRevision()
            model.applyFadesPublic()
            return nil
        }
        if let ai = model.audioIndexPublic(uuid) {
            model.audioClips[ai].fadeIn = 0
            model.audioClips[ai].fadeOut = 0
            model.bumpMCPRevision()
            model.applyFadesPublic()
            return nil
        }
        return MCPErrorResponse(error: "clip_not_found", message: "No clip with id \(clipId)", currentRevision: nil)
    }
}
