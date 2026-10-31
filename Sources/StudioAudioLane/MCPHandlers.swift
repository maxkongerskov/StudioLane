import Foundation

// MARK: - MCP Tool Handlers

@MainActor
enum MCPHandlers {
    /// Facts an agent cannot see by looking at clip numbers alone.
    static var editingBehavior: String {
        let seconds = String(format: "%g", EditorModel.playlistCrossfade)
        return """
        Audio layout defaults to playlist. Adding or deleting an audio clip ripples later clips on that lane and applies an automatic \(seconds)s crossfade where clips meet. trim_clip and move_clip do not ripple and do not rewrite fades. Layer mode keeps the start times you set, allows overlap, and does not crossfade. Fades are clamped so fade-in plus fade-out never exceed the clip duration. Still images land on a video lane as a short hold. An audio-only export is a WAV mixdown and the destination extension may change (for example .mp4 becomes .wav); use the destination the tool returns.
        """
    }

    // MARK: Read Tools

    static func getProjectState(model: EditorModel, compact: Bool) -> [String: Any] {
        let tracks: [[String: Any]] = model.tracks.map { track in
            [
                "id": track.id.uuidString,
                "kind": track.kind == .video ? "video" : "audio",
                "name": track.name,
                "volume": Double(track.volume)
            ]
        }

        let clips = model.videoClips.map { clipFields($0, kind: "video", compact: compact) }
            + model.audioClips.map { clipFields($0, kind: "audio", compact: compact) }

        var state: [String: Any] = [
            "revision": model.mcpRevision,
            "timeline_duration": model.duration,
            "playhead": model.currentTime,
            "is_playing": model.isPlaying,
            "is_exporting": model.isExporting,
            "audio_layout": layoutName(model),
            "ducking": model.isDuckingMusic,
            "fps": model.exportSourceFPS,
            "render_size": [
                "width": Double(model.exportSourceSize.width),
                "height": Double(model.exportSourceSize.height)
            ],
            "editing_behavior": editingBehavior,
            "tracks": tracks,
            "clips": clips
        ]
        if model.audioLayoutMode == .playlist {
            state["playlist_crossfade_seconds"] = EditorModel.playlistCrossfade
        }
        if let path = model.projectFileURL?.path {
            state["project_path"] = path
        }
        if compact, !model.isDuckingMusic {
            state.removeValue(forKey: "ducking")
        }
        return state
    }

    static func getExportStatus(model: EditorModel) -> [String: Any] {
        var dict: [String: Any] = [
            "is_exporting": model.isExporting,
            "progress": model.exportProgress
        ]
        if model.isExporting {
            if let url = model.exportDestinationURL {
                dict["destination"] = url.path
            }
        } else {
            dict["succeeded"] = model.completedExportSucceeded && abs(model.exportProgress - 1) < 0.001
            if let url = model.completedExportURL ?? model.exportDestinationURL {
                dict["destination"] = url.path
            }
        }
        if let error = model.errorMessage {
            dict["error"] = error
        }
        return dict
    }

    // MARK: Revision Check

    static func checkRevision(model: EditorModel, expected: Int?) -> MCPErrorResponse? {
        guard let expected, expected != model.mcpRevision else { return nil }
        return MCPErrorResponse(
            error: "revision_conflict",
            message: "Expected revision \(expected) but current is \(model.mcpRevision). Re-read state before editing.",
            currentRevision: model.mcpRevision
        )
    }

    // MARK: Edit Tools

    static func addClip(
        model: EditorModel,
        filePath: String,
        trackKind: String?,
        start: Double?,
        trackId: String?
    ) async -> Result<[String: Any], MCPErrorResponse> {
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

        let before = placementSnapshot(model)
        let revisionBefore = model.mcpRevision
        let added: Bool
        if kind == .video {
            added = await model.addVideoPublic(url: url, start: start.map { TimeInterval($0) }, ontoTrackID: trackID)
        } else {
            added = await model.addAudioPublic(url: url, start: start.map { TimeInterval($0) }, ontoTrackID: trackID)
        }
        guard added else {
            return .failure(MCPErrorResponse(
                error: "import_failed",
                message: model.errorMessage ?? "Could not import \(url.lastPathComponent).",
                currentRevision: model.mcpRevision
            ))
        }
        // addVideo / addAudio already push history, which bumps revision once.
        model.bumpMCPRevisionIfUnchanged(since: revisionBefore)

        let after = placementSnapshot(model)
        guard let created = after.first(where: { clip in !before.contains(where: { $0.id == clip.id }) }) else {
            return .failure(MCPErrorResponse(
                error: "import_failed",
                message: "The file was accepted but no clip id was created.",
                currentRevision: model.mcpRevision
            ))
        }
        let effects = placementEffects(before: before, after: after, createdID: created.id)
        var payload = outcome(model, status: "added", extra: clipFields(created.clip, kind: created.kind, compact: false))
        payload["clip_id"] = created.id.uuidString
        payload["rippled"] = effects.rippled
        payload["auto_crossfade"] = effects.autoCrossfade
        payload["editing_behavior"] = editingBehavior
        return .success(payload)
    }

    static func trimClip(model: EditorModel, clipId: String, newIn: Double?, newDuration: Double?) -> Result<[String: Any], MCPErrorResponse> {
        guard let uuid = UUID(uuidString: clipId) else {
            return .failure(MCPErrorResponse(error: "invalid_clip_id", message: "Not a UUID: \(clipId)", currentRevision: nil))
        }
        guard let located = locate(model, uuid) else {
            return .failure(MCPErrorResponse(error: "clip_not_found", message: "No clip with id \(clipId)", currentRevision: nil))
        }
        var clip = located.clip
        if let newInValue = newIn {
            let maxIn = max(0, clip.sourceDuration - EditorModel.minimumClipDuration)
            clip.inPoint = min(max(0, newInValue), maxIn)
        }
        if let newDur = newDuration {
            let maxDur = clip.sourceDuration - clip.inPoint
            clip.duration = min(max(EditorModel.minimumClipDuration, newDur), maxDur)
        }
        clip.clampFades()
        guard !sameEditGeometry(located.clip, clip) else {
            var payload = outcome(model, status: "unchanged", extra: clipFields(located.clip, kind: located.kind, compact: false))
            payload["note"] = "trim_clip does not ripple other clips. The requested trim matched the clip already on the timeline."
            return .success(payload)
        }
        let revisionBefore = model.mcpRevision
        store(model, clip, at: located)
        model.bumpMCPRevisionIfUnchanged(since: revisionBefore)
        model.scheduleRebuildPublic()
        var payload = outcome(model, status: "trimmed", extra: clipFields(clip, kind: located.kind, compact: false))
        payload["note"] = "trim_clip does not ripple other clips and does not rewrite neighboring fades. Values below are after clamping to the source."
        return .success(payload)
    }

    static func moveClip(model: EditorModel, clipId: String, newStart: Double, trackId: String?) -> Result<[String: Any], MCPErrorResponse> {
        guard let uuid = UUID(uuidString: clipId) else {
            return .failure(MCPErrorResponse(error: "invalid_clip_id", message: "Not a UUID: \(clipId)", currentRevision: nil))
        }
        guard let located = locate(model, uuid) else {
            return .failure(MCPErrorResponse(error: "clip_not_found", message: "No clip with id \(clipId)", currentRevision: nil))
        }
        var clip = located.clip
        clip.timelineStart = max(0, newStart)
        if let tid = trackId, let trackUUID = UUID(uuidString: tid) {
            clip.trackID = trackUUID
        }
        guard !sameEditGeometry(located.clip, clip) || located.clip.trackID != clip.trackID else {
            var payload = outcome(model, status: "unchanged", extra: clipFields(located.clip, kind: located.kind, compact: false))
            payload["note"] = "move_clip does not ripple other clips."
            return .success(payload)
        }
        let revisionBefore = model.mcpRevision
        store(model, clip, at: located)
        model.bumpMCPRevisionIfUnchanged(since: revisionBefore)
        model.scheduleRebuildPublic()
        var payload = outcome(model, status: "moved", extra: clipFields(clip, kind: located.kind, compact: false))
        payload["note"] = "move_clip does not ripple other clips and does not apply playlist crossfades."
        return .success(payload)
    }

    static func splitClip(model: EditorModel, clipId: String, atTime: Double) -> Result<[String: Any], MCPErrorResponse> {
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
            let revisionBefore = model.mcpRevision
            model.bumpMCPRevisionIfUnchanged(since: revisionBefore)
            model.scheduleRebuildPublic()
            return .success(outcome(model, status: "split", extra: [
                "clip_ids": [parts.left.id.uuidString, parts.right.id.uuidString]
            ]))
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
            let revisionBefore = model.mcpRevision
            model.bumpMCPRevisionIfUnchanged(since: revisionBefore)
            model.scheduleRebuildPublic()
            return .success(outcome(model, status: "split", extra: [
                "clip_ids": [parts.left.id.uuidString, parts.right.id.uuidString],
                "note": "split_clip does not ripple other clips. Playlist auto-crossfade is not reapplied."
            ]))
        }
        return .failure(MCPErrorResponse(error: "clip_not_found", message: "No clip with id \(clipId)", currentRevision: nil))
    }

    static func deleteClip(model: EditorModel, clipId: String, confirmed: Bool) -> Result<[String: Any], MCPErrorResponse> {
        guard let uuid = UUID(uuidString: clipId) else {
            return .failure(MCPErrorResponse(error: "invalid_clip_id", message: "Not a UUID: \(clipId)", currentRevision: nil))
        }
        guard confirmed else {
            return .failure(MCPErrorResponse(
                error: "confirmation_required",
                message: "Set confirmed=true to delete this clip. In playlist mode, deleting an audio clip also ripples the lane and reapplies the automatic crossfade.",
                currentRevision: nil
            ))
        }
        guard model.videoIndexPublic(uuid) != nil || model.audioIndexPublic(uuid) != nil else {
            return .failure(MCPErrorResponse(error: "clip_not_found", message: "No clip with id \(clipId)", currentRevision: nil))
        }
        let before = placementSnapshot(model)
        let revisionBefore = model.mcpRevision
        model.deleteClipPublic(clipID: uuid)
        model.bumpMCPRevisionIfUnchanged(since: revisionBefore)
        let after = placementSnapshot(model)
        let effects = placementEffects(before: before, after: after, createdID: nil)
        return .success(outcome(model, status: "deleted", extra: [
            "clip_id": clipId,
            "rippled": effects.rippled,
            "auto_crossfade": effects.autoCrossfade,
            "editing_behavior": editingBehavior
        ]))
    }

    static func setClipVolume(model: EditorModel, clipId: String, gain: Double) -> Result<[String: Any], MCPErrorResponse> {
        guard let uuid = UUID(uuidString: clipId) else {
            return .failure(MCPErrorResponse(error: "invalid_clip_id", message: "Not a UUID: \(clipId)", currentRevision: nil))
        }
        guard let located = locate(model, uuid) else {
            return .failure(MCPErrorResponse(error: "clip_not_found", message: "No clip with id \(clipId)", currentRevision: nil))
        }
        let clamped = Float(min(max(0, gain), 1))
        guard abs(located.clip.gain - clamped) > 0.000_1 else {
            return .success(outcome(model, status: "unchanged", extra: ["clip_id": clipId, "gain": Double(located.clip.gain)]))
        }
        var clip = located.clip
        clip.gain = clamped
        let revisionBefore = model.mcpRevision
        store(model, clip, at: located)
        model.bumpMCPRevisionIfUnchanged(since: revisionBefore)
        model.applyFadesPublic(refreshingVideo: false)
        return .success(outcome(model, status: "volume_set", extra: ["clip_id": clipId, "gain": Double(clamped)]))
    }

    static func setTrackVolume(model: EditorModel, trackId: String, volume: Double) -> Result<[String: Any], MCPErrorResponse> {
        guard let uuid = UUID(uuidString: trackId) else {
            return .failure(MCPErrorResponse(error: "invalid_track_id", message: "Not a UUID: \(trackId)", currentRevision: nil))
        }
        guard let track = model.track(id: uuid) else {
            return .failure(MCPErrorResponse(error: "track_not_found", message: "No track with id \(trackId)", currentRevision: nil))
        }
        let clamped = Float(min(max(0, volume), 1))
        guard abs(track.volume - clamped) > 0.000_1 else {
            return .success(outcome(model, status: "unchanged", extra: ["track_id": trackId, "volume": Double(track.volume)]))
        }
        let revisionBefore = model.mcpRevision
        model.setTrackVolume(uuid, clamped)
        model.bumpMCPRevisionIfUnchanged(since: revisionBefore)
        return .success(outcome(model, status: "track_volume_set", extra: ["track_id": trackId, "volume": Double(clamped)]))
    }

    static func toggleMute(model: EditorModel, clipId: String) -> Result<[String: Any], MCPErrorResponse> {
        guard let uuid = UUID(uuidString: clipId) else {
            return .failure(MCPErrorResponse(error: "invalid_clip_id", message: "Not a UUID: \(clipId)", currentRevision: nil))
        }
        guard let located = locate(model, uuid) else {
            return .failure(MCPErrorResponse(error: "clip_not_found", message: "No clip with id \(clipId)", currentRevision: nil))
        }
        var clip = located.clip
        clip.muted.toggle()
        let revisionBefore = model.mcpRevision
        store(model, clip, at: located)
        model.bumpMCPRevisionIfUnchanged(since: revisionBefore)
        model.applyFadesPublic(refreshingVideo: false)
        return .success(outcome(model, status: "muted_toggled", extra: ["clip_id": clipId, "muted": clip.muted]))
    }

    static func setFade(model: EditorModel, clipId: String, direction: String, duration: Double) -> Result<[String: Any], MCPErrorResponse> {
        guard let uuid = UUID(uuidString: clipId) else {
            return .failure(MCPErrorResponse(error: "invalid_clip_id", message: "Not a UUID: \(clipId)", currentRevision: nil))
        }
        guard let located = locate(model, uuid) else {
            return .failure(MCPErrorResponse(error: "clip_not_found", message: "No clip with id \(clipId)", currentRevision: nil))
        }
        var clip = located.clip
        let requested = max(0, duration)
        if direction == "in" { clip.fadeIn = requested } else { clip.fadeOut = requested }
        clip.clampFades()
        guard !sameEditGeometry(located.clip, clip) else {
            return .success(outcome(model, status: "unchanged", extra: [
                "clip_id": clipId,
                "fade_in": clip.fadeIn,
                "fade_out": clip.fadeOut,
                "note": "Fades are clamped so fade-in plus fade-out never exceed the clip duration. This call did not change them."
            ]))
        }
        let revisionBefore = model.mcpRevision
        store(model, clip, at: located)
        model.bumpMCPRevisionIfUnchanged(since: revisionBefore)
        model.applyFadesPublic(refreshingVideo: located.kind == "video")
        return .success(outcome(model, status: direction == "in" ? "fade_in_set" : "fade_out_set", extra: [
            "clip_id": clipId,
            "fade_in": clip.fadeIn,
            "fade_out": clip.fadeOut,
            "note": "Fades are clamped so fade-in plus fade-out never exceed the clip duration. The values below are what was stored."
        ]))
    }

    static func clearFades(model: EditorModel, clipId: String) -> Result<[String: Any], MCPErrorResponse> {
        guard let uuid = UUID(uuidString: clipId) else {
            return .failure(MCPErrorResponse(error: "invalid_clip_id", message: "Not a UUID: \(clipId)", currentRevision: nil))
        }
        guard let located = locate(model, uuid) else {
            return .failure(MCPErrorResponse(error: "clip_not_found", message: "No clip with id \(clipId)", currentRevision: nil))
        }
        guard located.clip.fadeIn > 0.000_1 || located.clip.fadeOut > 0.000_1 else {
            return .success(outcome(model, status: "unchanged", extra: ["clip_id": clipId, "fade_in": 0, "fade_out": 0]))
        }
        var clip = located.clip
        clip.fadeIn = 0
        clip.fadeOut = 0
        let revisionBefore = model.mcpRevision
        store(model, clip, at: located)
        model.bumpMCPRevisionIfUnchanged(since: revisionBefore)
        model.applyFadesPublic(refreshingVideo: located.kind == "video")
        return .success(outcome(model, status: "fades_cleared", extra: ["clip_id": clipId, "fade_in": 0, "fade_out": 0]))
    }

    static func crossfadeClips(model: EditorModel, leftClipId: String, rightClipId: String, duration: Double) -> Result<(Double, Double, Double), MCPErrorResponse> {
        guard let leftUUID = UUID(uuidString: leftClipId) else {
            return .failure(MCPErrorResponse(error: "invalid_clip_id", message: "Not a UUID: \(leftClipId)", currentRevision: nil))
        }
        guard let rightUUID = UUID(uuidString: rightClipId) else {
            return .failure(MCPErrorResponse(error: "invalid_clip_id", message: "Not a UUID: \(rightClipId)", currentRevision: nil))
        }
        guard leftUUID != rightUUID else {
            return .failure(MCPErrorResponse(error: "same_clip", message: "Crossfade requires two different clips", currentRevision: nil))
        }

        func crossfadePair(left: MediaClip, right: MediaClip) -> Result<(MediaClip, MediaClip), MCPErrorResponse> {
            let requested = max(0, duration)
            let leftAvailable = max(0, left.duration - left.fadeIn)
            let rightAvailable = max(0, right.duration - right.fadeOut)
            let overlap = min(leftAvailable, rightAvailable, requested)
            guard overlap > 0.001 else {
                return .failure(MCPErrorResponse(
                    error: "crossfade_too_long",
                    message: "Requested \(requested)s but adjacent clips only support \(min(leftAvailable, rightAvailable))s",
                    currentRevision: nil
                ))
            }

            var mutableLeft = left
            mutableLeft.fadeOut = overlap
            mutableLeft.clampFades()

            var mutableRight = right
            mutableRight.fadeIn = overlap
            mutableRight.clampFades()
            mutableRight.timelineStart = mutableLeft.timelineEnd - overlap

            return .success((mutableLeft, mutableRight))
        }

        if let leftIndex = model.videoIndexPublic(leftUUID), let rightIndex = model.videoIndexPublic(rightUUID) {
            switch crossfadePair(left: model.videoClips[leftIndex], right: model.videoClips[rightIndex]) {
            case .failure(let error):
                return .failure(error)
            case .success(let (newLeft, newRight)):
                model.videoClips[leftIndex] = newLeft
                model.videoClips[rightIndex] = newRight
            }
            let revisionBefore = model.mcpRevision
            model.bumpMCPRevisionIfUnchanged(since: revisionBefore)
            model.scheduleRebuildPublic()
            let left = model.videoClips[leftIndex]
            let right = model.videoClips[rightIndex]
            return .success((left.timelineStart, left.fadeOut, right.fadeIn))
        }

        if let leftIndex = model.audioIndexPublic(leftUUID), let rightIndex = model.audioIndexPublic(rightUUID) {
            switch crossfadePair(left: model.audioClips[leftIndex], right: model.audioClips[rightIndex]) {
            case .failure(let error):
                return .failure(error)
            case .success(let (newLeft, newRight)):
                model.audioClips[leftIndex] = newLeft
                model.audioClips[rightIndex] = newRight
            }
            let revisionBefore = model.mcpRevision
            model.bumpMCPRevisionIfUnchanged(since: revisionBefore)
            model.scheduleRebuildPublic()
            let left = model.audioClips[leftIndex]
            let right = model.audioClips[rightIndex]
            return .success((left.timelineStart, left.fadeOut, right.fadeIn))
        }

        return .failure(MCPErrorResponse(
            error: "crossfade_kinds_mismatch",
            message: "Both clips must exist and belong to the same media kind",
            currentRevision: nil
        ))
    }

    // MARK: - Payload helpers

    static func outcome(_ model: EditorModel, status: String, extra: [String: Any] = [:]) -> [String: Any] {
        var payload = extra
        payload["status"] = status
        payload["revision"] = model.mcpRevision
        payload["audio_layout"] = layoutName(model)
        return payload
    }

    private static func layoutName(_ model: EditorModel) -> String {
        model.audioLayoutMode == .playlist ? "playlist" : "layer"
    }

    private static func clipFields(_ clip: MediaClip, kind: String, compact: Bool) -> [String: Any] {
        var dict: [String: Any] = [
            "id": clip.id.uuidString,
            "clip_id": clip.id.uuidString,
            "track_id": clip.trackID.uuidString,
            "kind": kind,
            "name": clip.displayName,
            "file_path": clip.url.path,
            "timeline_start": clip.timelineStart,
            "duration": clip.duration,
            "source_duration": clip.sourceDuration,
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

    private struct LocatedClip {
        var index: Int
        var kind: String
        var clip: MediaClip
    }

    private static func locate(_ model: EditorModel, _ id: UUID) -> LocatedClip? {
        if let index = model.videoIndexPublic(id) {
            return LocatedClip(index: index, kind: "video", clip: model.videoClips[index])
        }
        if let index = model.audioIndexPublic(id) {
            return LocatedClip(index: index, kind: "audio", clip: model.audioClips[index])
        }
        return nil
    }

    private static func store(_ model: EditorModel, _ clip: MediaClip, at located: LocatedClip) {
        if located.kind == "video" {
            model.videoClips[located.index] = clip
        } else {
            model.audioClips[located.index] = clip
        }
    }

    private static func sameEditGeometry(_ lhs: MediaClip, _ rhs: MediaClip) -> Bool {
        abs(lhs.inPoint - rhs.inPoint) < 0.000_1
            && abs(lhs.duration - rhs.duration) < 0.000_1
            && abs(lhs.fadeIn - rhs.fadeIn) < 0.000_1
            && abs(lhs.fadeOut - rhs.fadeOut) < 0.000_1
            && abs(lhs.timelineStart - rhs.timelineStart) < 0.000_1
    }

    private struct PlacedClip {
        var id: UUID
        var kind: String
        var clip: MediaClip
        var start: TimeInterval
        var fadeIn: TimeInterval
        var fadeOut: TimeInterval
    }

    private static func placementSnapshot(_ model: EditorModel) -> [PlacedClip] {
        model.videoClips.map {
            PlacedClip(id: $0.id, kind: "video", clip: $0, start: $0.timelineStart, fadeIn: $0.fadeIn, fadeOut: $0.fadeOut)
        } + model.audioClips.map {
            PlacedClip(id: $0.id, kind: "audio", clip: $0, start: $0.timelineStart, fadeIn: $0.fadeIn, fadeOut: $0.fadeOut)
        }
    }

    private static func placementEffects(before: [PlacedClip], after: [PlacedClip], createdID: UUID?) -> (rippled: Bool, autoCrossfade: Bool) {
        let afterByID = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
        var rippled = false
        var autoCrossfade = false
        for old in before where old.id != createdID {
            guard let new = afterByID[old.id] else { continue }
            if abs(new.start - old.start) > 0.000_1 { rippled = true }
            if abs(new.fadeIn - old.fadeIn) > 0.000_1 || abs(new.fadeOut - old.fadeOut) > 0.000_1 {
                autoCrossfade = true
            }
        }
        if let createdID, let created = afterByID[createdID], created.fadeIn > 0.001 || created.fadeOut > 0.001 {
            autoCrossfade = true
        }
        return (rippled, autoCrossfade)
    }
}
