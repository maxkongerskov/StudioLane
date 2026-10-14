import AppKit
import AVFoundation
import ImageIO
import Observation
import UniformTypeIdentifiers

struct TimelineTrack: Identifiable, Codable, Hashable {
    enum Kind: Int, Codable, Hashable, CaseIterable {
        case video = 0
        case audio = 1
    }

    var id: UUID
    var name: String
    var kind: Kind
    var volume: Float

    static func defaultVideo(id: UUID = UUID()) -> TimelineTrack {
        TimelineTrack(id: id, name: "Video", kind: .video, volume: 1)
    }

    static func defaultMusic(id: UUID = UUID()) -> TimelineTrack {
        TimelineTrack(id: id, name: "Music", kind: .audio, volume: 0.62)
    }
}

struct MediaClip: Identifiable, Codable {
    var id: UUID
    var url: URL
    var name: String
    var sourceDuration: TimeInterval
    var inPoint: TimeInterval
    var timelineStart: TimeInterval
    var duration: TimeInterval
    var fadeIn: TimeInterval
    var fadeOut: TimeInterval
    var muted: Bool = false
    /// Per-clip gain 0…1, multiplied with track volume (and duck) in the mix.
    var gain: Float = 1
    /// Lane this clip belongs to (video or audio track).
    var trackID: UUID
    /// Full-source peak map covering `0...sourceDuration`. Drawing windows by inPoint/duration (Logic-style mask).
    var waveform: [Float] = []
    /// Pro video controls. Kept on every clip so projects remain round-trippable
    /// when Pro mode is switched off.
    var transform: ClipTransform = .identity
    var transformKeyframes: [ClipTransformKeyframe] = []
    var transitionIn: ClipTransition = ClipTransition()
    var transitionOut: ClipTransition = ClipTransition()
    /// Pro audio controls.
    var pan: Float = 0
    var isNormalized = false

    var timelineEnd: TimeInterval { timelineStart + duration }

    static let maximumPersistedWaveformPoints = 8_192

    var displayName: String {
        if name == "video" {
            let parent = url.deletingLastPathComponent()
            if parent.lastPathComponent == "files" {
                return parent.deletingLastPathComponent().deletingPathExtension().lastPathComponent
            }
        }
        return name
    }

    mutating func clampFades() {
        fadeIn = min(max(0, fadeIn), max(0, duration - fadeOut))
        fadeOut = min(max(0, fadeOut), max(0, duration - fadeIn))
    }

    enum CodingKeys: String, CodingKey {
        case id, url, name, sourceDuration, inPoint, timelineStart, duration
        case fadeIn, fadeOut, muted, gain, trackID, waveform
        case transform, transformKeyframes, transitionIn, transitionOut, pan, isNormalized
    }

    init(
        id: UUID,
        url: URL,
        name: String,
        sourceDuration: TimeInterval,
        inPoint: TimeInterval,
        timelineStart: TimeInterval,
        duration: TimeInterval,
        fadeIn: TimeInterval,
        fadeOut: TimeInterval,
        muted: Bool = false,
        gain: Float = 1,
        trackID: UUID = UUID(),
        waveform: [Float] = [],
        transform: ClipTransform = .identity,
        transformKeyframes: [ClipTransformKeyframe] = [],
        transitionIn: ClipTransition = ClipTransition(),
        transitionOut: ClipTransition = ClipTransition(),
        pan: Float = 0,
        isNormalized: Bool = false
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.sourceDuration = sourceDuration
        self.inPoint = inPoint
        self.timelineStart = timelineStart
        self.duration = duration
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.muted = muted
        self.gain = gain
        self.trackID = trackID
        self.waveform = waveform
        self.transform = transform
        self.transformKeyframes = transformKeyframes
        self.transitionIn = transitionIn
        self.transitionOut = transitionOut
        self.pan = pan
        self.isNormalized = isNormalized
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        name = try c.decode(String.self, forKey: .name)
        sourceDuration = try c.decode(TimeInterval.self, forKey: .sourceDuration)
        inPoint = try c.decode(TimeInterval.self, forKey: .inPoint)
        timelineStart = try c.decode(TimeInterval.self, forKey: .timelineStart)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        fadeIn = try c.decode(TimeInterval.self, forKey: .fadeIn)
        fadeOut = try c.decode(TimeInterval.self, forKey: .fadeOut)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        gain = try c.decodeIfPresent(Float.self, forKey: .gain) ?? 1
        trackID = try c.decodeIfPresent(UUID.self, forKey: .trackID) ?? UUID()
        waveform = try c.decodeIfPresent([Float].self, forKey: .waveform) ?? []
        transform = try c.decodeIfPresent(ClipTransform.self, forKey: .transform) ?? .identity
        transformKeyframes = try c.decodeIfPresent([ClipTransformKeyframe].self, forKey: .transformKeyframes) ?? []
        transitionIn = try c.decodeIfPresent(ClipTransition.self, forKey: .transitionIn) ?? ClipTransition()
        transitionOut = try c.decodeIfPresent(ClipTransition.self, forKey: .transitionOut) ?? ClipTransition()
        pan = try c.decodeIfPresent(Float.self, forKey: .pan) ?? 0
        isNormalized = try c.decodeIfPresent(Bool.self, forKey: .isNormalized) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(url, forKey: .url)
        try c.encode(name, forKey: .name)
        try c.encode(sourceDuration, forKey: .sourceDuration)
        try c.encode(inPoint, forKey: .inPoint)
        try c.encode(timelineStart, forKey: .timelineStart)
        try c.encode(duration, forKey: .duration)
        try c.encode(fadeIn, forKey: .fadeIn)
        try c.encode(fadeOut, forKey: .fadeOut)
        try c.encode(muted, forKey: .muted)
        try c.encode(gain, forKey: .gain)
        try c.encode(trackID, forKey: .trackID)
        try c.encode(waveform, forKey: .waveform)
        try c.encode(transform, forKey: .transform)
        try c.encode(transformKeyframes, forKey: .transformKeyframes)
        try c.encode(transitionIn, forKey: .transitionIn)
        try c.encode(transitionOut, forKey: .transitionOut)
        try c.encode(pan, forKey: .pan)
        try c.encode(isNormalized, forKey: .isNormalized)
    }

    func sanitized() -> MediaClip? {
        let finiteValues = [
            sourceDuration, inPoint, timelineStart, duration, fadeIn, fadeOut
        ].allSatisfy { $0.isFinite }
        guard finiteValues, sourceDuration > 0 else { return nil }

        let clip = MediaClip(
            id: id,
            url: url,
            name: name,
            sourceDuration: sourceDuration,
            inPoint: inPoint,
            timelineStart: timelineStart,
            duration: duration,
            fadeIn: fadeIn,
            fadeOut: fadeOut,
            muted: muted,
            gain: gain.isFinite ? min(max(gain, 0), 1) : 1,
            trackID: trackID,
            waveform: waveform.count <= Self.maximumPersistedWaveformPoints
                ? waveform.map { $0.isFinite ? min(max($0, 0), 1) : 0 }
                : [],
            transform: transform,
            transformKeyframes: transformKeyframes,
            transitionIn: transitionIn,
            transitionOut: transitionOut,
            pan: pan.isFinite ? min(max(pan, -1), 1) : 0,
            isNormalized: isNormalized
        )
        var sanitized = clip
        // Floors/ceilings go through the shared EditorModel constants (see
        // renderableDuration's comment): stored duration must never exceed the
        // media available from inPoint. A ceiling above that makes insertTimeRange
        // throw and one tiny clip fails the entire timeline rebuild.
        let minimumClipDuration = EditorModel.minimumClipDuration
        sanitized.inPoint = min(max(0, inPoint), max(0, sourceDuration - minimumClipDuration))
        sanitized.duration = EditorModel.renderableDuration(
            requested: max(duration, min(minimumClipDuration, max(0, sourceDuration - sanitized.inPoint))),
            sourceDuration: sourceDuration,
            inPoint: sanitized.inPoint
        )
        sanitized.timelineStart = max(0, timelineStart)
        sanitized.transform.sanitize()
        sanitized.transformKeyframes = transformKeyframes.map {
            var keyframe = $0
            keyframe.sanitize(clipDuration: sanitized.duration)
            return keyframe
        }.sorted { $0.time < $1.time }
        sanitized.transitionIn.sanitize(clipDuration: sanitized.duration)
        sanitized.transitionOut.sanitize(clipDuration: sanitized.duration)
        sanitized.clampFades()
        return sanitized
    }
}

struct EditorSnapshot: Codable {
    var videoClips: [MediaClip]
    var audioClips: [MediaClip]
    var tracks: [TimelineTrack]
    var selectedClipID: UUID?
    var selectedClipIDs: [UUID]
    var focusedLane: Int
    var focusedTrackID: UUID?
    var videoVolume: Float
    var musicVolume: Float
    var isDuckingMusic: Bool
    var audioLayoutMode: Int
    var isProMode: Bool
    var proSettings: ProProjectSettings
}

struct ProjectClips: Codable {
    var video: [MediaClip]
    var audio: [MediaClip]
}

struct ProjectDocument: Codable {
    var clips: ProjectClips
    var tracks: [TimelineTrack]?
    var focusedLane: Int
    var focusedTrackID: UUID?
    var selectedClipID: UUID?
    var selectedClipIDs: [UUID]?
    var videoVolume: Float
    var musicVolume: Float
    var isDuckingMusic: Bool
    var audioLayoutMode: Int?
    var timelineSpan: TimeInterval?
    /// Playhead in seconds. Absent in older files, which open at the start.
    var playhead: TimeInterval?
    var isProMode: Bool?
    var proSettings: ProProjectSettings?

    enum CodingKeys: String, CodingKey {
        case clips, tracks, focusedLane, focusedTrackID, selectedClipID, selectedClipIDs
        case videoVolume, musicVolume, isDuckingMusic, audioLayoutMode, timelineSpan, playhead
        case isProMode, proSettings
    }

    init(
        clips: ProjectClips,
        tracks: [TimelineTrack]? = nil,
        focusedLane: Int,
        focusedTrackID: UUID? = nil,
        selectedClipID: UUID?,
        selectedClipIDs: [UUID]? = nil,
        videoVolume: Float,
        musicVolume: Float,
        isDuckingMusic: Bool,
        audioLayoutMode: Int? = 0,
        timelineSpan: TimeInterval? = nil,
        playhead: TimeInterval? = nil,
        isProMode: Bool? = nil,
        proSettings: ProProjectSettings? = nil
    ) {
        self.clips = clips
        self.tracks = tracks
        self.focusedLane = focusedLane
        self.focusedTrackID = focusedTrackID
        self.selectedClipID = selectedClipID
        self.selectedClipIDs = selectedClipIDs
        self.videoVolume = videoVolume
        self.musicVolume = musicVolume
        self.isDuckingMusic = isDuckingMusic
        self.audioLayoutMode = audioLayoutMode
        self.timelineSpan = timelineSpan
        self.playhead = playhead
        self.isProMode = isProMode
        self.proSettings = proSettings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clips = try c.decode(ProjectClips.self, forKey: .clips)
        tracks = try c.decodeIfPresent([TimelineTrack].self, forKey: .tracks)
        focusedLane = try c.decode(Int.self, forKey: .focusedLane)
        focusedTrackID = try c.decodeIfPresent(UUID.self, forKey: .focusedTrackID)
        selectedClipID = try c.decodeIfPresent(UUID.self, forKey: .selectedClipID)
        selectedClipIDs = try c.decodeIfPresent([UUID].self, forKey: .selectedClipIDs)
        videoVolume = try c.decode(Float.self, forKey: .videoVolume)
        musicVolume = try c.decode(Float.self, forKey: .musicVolume)
        isDuckingMusic = try c.decode(Bool.self, forKey: .isDuckingMusic)
        audioLayoutMode = try c.decodeIfPresent(Int.self, forKey: .audioLayoutMode)
        timelineSpan = try c.decodeIfPresent(TimeInterval.self, forKey: .timelineSpan)
        playhead = try c.decodeIfPresent(TimeInterval.self, forKey: .playhead)
        isProMode = try c.decodeIfPresent(Bool.self, forKey: .isProMode)
        proSettings = try c.decodeIfPresent(ProProjectSettings.self, forKey: .proSettings)
    }
}

extension UTType {
    /// User project files (same JSON shape as Application Support autosave.json).
    static var salProject: UTType {
        UTType(exportedAs: "dev.maxkongerskov.StudioAudioLane.project", conformingTo: .json)
    }
}

@MainActor
@Observable
final class EditorModel {
    var isPlaying = false
    var isLoading = true
    var isExporting = false
    var isExportSheetPresented = false
    var exportProgress: Double = 0
    var status = "Loading…"
    /// Last user Save / Open destination; ⌘S writes here without a panel when set.
    var projectFileURL: URL?
    var currentTime: TimeInterval = 0
    var errorMessage: String?
    var isEditingClip = false
    var focusedLane: Lane = .video
    var selectedClipID: UUID?
    /// Multi-selection across video + audio lanes. `selectedClipID` is the primary (last-clicked) for inspector/fades.
    var selectedClipIDs: Set<UUID> = []
    /// Explicitly multi-selected tracks (sidebar Shift-click). Needed so empty lanes stay highlighted.
    var selectedTrackIDs: Set<UUID> = []
    var videoClips: [MediaClip] = []
    var audioClips: [MediaClip] = []
    /// Ordered timeline lanes. Default Video + Music; + can add more.
    var tracks: [TimelineTrack] = [
        .defaultVideo(id: EditorModel.defaultVideoTrackID),
        .defaultMusic(id: EditorModel.defaultAudioTrackID)
    ]
    var focusedTrackID: UUID = EditorModel.defaultVideoTrackID
    var videoVolume: Float = 1
    var musicVolume: Float = 0.62
    var isDuckingMusic = false
    var canUndo = false
    var canRedo = false
    var timelineZoom: CGFloat = 1
    var timelineViewportWidth: CGFloat = 1100
    var isSnapEnabled = true
    var isProMode = false
    var proSettings = ProProjectSettings()
    /// Playlist = abut/ripple music; Layer = free overlaps.
    var audioLayoutMode: AudioLayoutMode = .playlist
    var loopEnabled = false
    var loopIn: TimeInterval = 0
    var loopOut: TimeInterval = 0
    var filmstrips: [UUID: [CGImage]] = [:]
    /// Sequence length used to map the playlist. Grows with content, never
    /// shrinks during a trim — otherwise the longest clip keeps filling the
    /// lane and a slight drag collapses it toward zero.
    var timelineSpan: TimeInterval = 0

    static let defaultVideoTrackID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let defaultAudioTrackID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private static let proModeDefaultsKey = "StudioAudioLane.ProMode"

    enum Lane: Int, Hashable, CaseIterable {
        case video = 0
        case audio = 1
    }

    var videoTracks: [TimelineTrack] { tracks.filter { $0.kind == .video } }
    var audioTracks: [TimelineTrack] { tracks.filter { $0.kind == .audio } }

    func track(id: UUID) -> TimelineTrack? {
        tracks.first { $0.id == id }
    }

    func trackIndex(_ id: UUID) -> Int? {
        tracks.firstIndex { $0.id == id }
    }

    func setProMode(_ enabled: Bool) {
        isProMode = enabled
        UserDefaults.standard.set(enabled, forKey: Self.proModeDefaultsKey)
        scheduleAutosave()
        scheduleRebuild()
    }

    func updateProSettings(_ update: (inout ProProjectSettings) -> Void) {
        pushHistory()
        update(&proSettings)
        proSettings.sanitize()
        frameDuration = CMTime(
            seconds: 1 / max(1, proSettings.frameRate),
            preferredTimescale: 60_000
        )
        rebuild()
    }

    func clips(on trackID: UUID) -> [MediaClip] {
        if let t = track(id: trackID), t.kind == .video {
            return videoClips.filter { $0.trackID == trackID }
        }
        return audioClips.filter { $0.trackID == trackID }
    }

    func ensureDefaultTracks() {
        if tracks.isEmpty {
            tracks = [
                .defaultVideo(id: Self.defaultVideoTrackID),
                .defaultMusic(id: Self.defaultAudioTrackID)
            ]
        }
        if !tracks.contains(where: { $0.kind == .video }) {
            tracks.insert(.defaultVideo(id: Self.defaultVideoTrackID), at: 0)
        }
        if !tracks.contains(where: { $0.kind == .audio }) {
            tracks.append(.defaultMusic(id: Self.defaultAudioTrackID))
        }
        // Assign orphan clips (legacy autosave without trackID collision) to primary lanes.
        let videoIDs = Set(videoTracks.map(\.id))
        let audioIDs = Set(audioTracks.map(\.id))
        let primaryVideo = videoTracks[0].id
        let primaryAudio = audioTracks[0].id
        for i in videoClips.indices where !videoIDs.contains(videoClips[i].trackID) {
            videoClips[i].trackID = primaryVideo
        }
        for i in audioClips.indices where !audioIDs.contains(audioClips[i].trackID) {
            audioClips[i].trackID = primaryAudio
        }
        if track(id: focusedTrackID) == nil {
            focusedTrackID = focusedLane == .audio ? primaryAudio : primaryVideo
        }
        syncVolumesFromTracks()
    }

    private func syncVolumesFromTracks() {
        if let v = videoTracks.first { videoVolume = v.volume }
        if let a = audioTracks.first { musicVolume = a.volume }
    }

    private func syncTracksFromVolumes() {
        if let i = tracks.firstIndex(where: { $0.kind == .video }) {
            tracks[i].volume = videoVolume
        }
        if let i = tracks.firstIndex(where: { $0.kind == .audio }) {
            tracks[i].volume = musicVolume
        }
    }

    func nextLaneName(kind: TimelineTrack.Kind) -> String {
        let count = tracks.filter { $0.kind == kind }.count
        if kind == .video {
            return count == 0 ? "Video" : "Video \(count + 1)"
        }
        // First audio lane stays "Music"; extras are Audio 2, Audio 3, …
        return count == 0 ? "Music" : "Audio \(count + 1)"
    }

    /// Empty / whitespace names fall back to Video / Music / Audio N.
    func defaultTrackName(for trackID: UUID) -> String {
        guard let i = trackIndex(trackID) else { return "Track" }
        let kind = tracks[i].kind
        let ordinal = tracks.prefix(i + 1).filter { $0.kind == kind }.count
        if kind == .video {
            return ordinal <= 1 ? "Video" : "Video \(ordinal)"
        }
        return ordinal <= 1 ? "Music" : "Audio \(ordinal)"
    }

    func renameTrack(_ trackID: UUID, to rawName: String) {
        guard let i = trackIndex(trackID) else { return }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? defaultTrackName(for: trackID) : trimmed
        if tracks[i].name == name { return }
        pushHistory()
        tracks[i].name = name
        scheduleAutosave()
    }

    /// Track IDs that contain at least one clip in the current multi-selection.
    var trackIDsWithSelectedClips: Set<UUID> {
        var ids = Set<UUID>()
        for clip in videoClips where selectedClipIDs.contains(clip.id) {
            ids.insert(clip.trackID)
        }
        for clip in audioClips where selectedClipIDs.contains(clip.id) {
            ids.insert(clip.trackID)
        }
        return ids
    }

    func trackHasSelectedClip(_ trackID: UUID) -> Bool {
        trackIDsWithSelectedClips.contains(trackID)
    }

    /// Sidebar highlight: focused, explicitly multi-selected, or has a selected clip.
    func isTrackHighlighted(_ trackID: UUID) -> Bool {
        focusedTrackID == trackID
            || selectedTrackIDs.contains(trackID)
            || trackHasSelectedClip(trackID)
    }

    func clipIDs(onTrack trackID: UUID) -> Set<UUID> {
        var ids = Set<UUID>()
        for clip in videoClips where clip.trackID == trackID { ids.insert(clip.id) }
        for clip in audioClips where clip.trackID == trackID { ids.insert(clip.id) }
        return ids
    }

    /// Primary (last-clicked) clip across video + audio.
    var primarySelectedClip: MediaClip? {
        guard let id = selectedClipID else { return nil }
        return videoClips.first(where: { $0.id == id }) ?? audioClips.first(where: { $0.id == id })
    }

    var selectedClipsMixedKinds: Bool {
        let hasVideo = videoClips.contains { selectedClipIDs.contains($0.id) }
        let hasAudio = audioClips.contains { selectedClipIDs.contains($0.id) }
        return hasVideo && hasAudio
    }

    var allSelectedClips: [MediaClip] {
        let ids = selectedClipIDs
        var out: [MediaClip] = []
        out.append(contentsOf: videoClips.filter { ids.contains($0.id) })
        out.append(contentsOf: audioClips.filter { ids.contains($0.id) })
        return out
    }

    @discardableResult
    func addLane(kind: TimelineTrack.Kind) -> UUID {
        pushHistory()
        let id = UUID()
        let name = nextLaneName(kind: kind)
        let volume: Float = kind == .video ? videoVolume : musicVolume
        let track = TimelineTrack(id: id, name: name, kind: kind, volume: volume)
        // Keep videos above audio: insert after last same-kind, or before first audio for video.
        if kind == .video {
            if let lastVideo = tracks.lastIndex(where: { $0.kind == .video }) {
                tracks.insert(track, at: lastVideo + 1)
            } else {
                tracks.insert(track, at: 0)
            }
            focusedLane = .video
        } else {
            tracks.append(track)
            focusedLane = .audio
        }
        focusedTrackID = id
        scheduleAutosave()
        return id
    }

    func setTrackVolume(_ trackID: UUID, _ volume: Float) {
        guard let i = trackIndex(trackID) else { return }
        let v = min(max(0, volume), 1)
        tracks[i].volume = v
        if tracks[i].kind == .video, tracks.filter({ $0.kind == .video }).first?.id == trackID {
            videoVolume = v
        }
        if tracks[i].kind == .audio, tracks.filter({ $0.kind == .audio }).first?.id == trackID {
            musicVolume = v
        }
        // Lane volume is an audio-mix change. Replacing the video composition here
        // tears down the preview while playback is running.
        applyFades(refreshingVideo: false)
        scheduleAutosave()
    }

    func deleteTrack(_ trackID: UUID) {
        guard let t = track(id: trackID) else { return }
        // Keep at least one video and one audio lane.
        let same = tracks.filter { $0.kind == t.kind }
        guard same.count > 1 else {
            // Clearing clips on the last lane of that kind.
            if t.kind == .video { deleteVideoTrack() } else { deleteMusicTrack() }
            return
        }
        pushHistory()
        if t.kind == .video {
            let ids = Set(videoClips.filter { $0.trackID == trackID }.map(\.id))
            for id in ids { filmstrips[id] = nil }
            videoClips.removeAll { $0.trackID == trackID }
            selectedClipIDs.subtract(ids)
        } else {
            let ids = Set(audioClips.filter { $0.trackID == trackID }.map(\.id))
            audioClips.removeAll { $0.trackID == trackID }
            selectedClipIDs.subtract(ids)
        }
        tracks.removeAll { $0.id == trackID }
        selectedTrackIDs.remove(trackID)
        if focusedTrackID == trackID {
            focusedTrackID = tracks.first(where: { $0.kind == t.kind })?.id
                ?? tracks.first?.id
                ?? Self.defaultVideoTrackID
            focusedLane = track(id: focusedTrackID)?.kind == .audio ? .audio : .video
        }
        if let sid = selectedClipID, !selectedClipIDs.contains(sid) {
            selectedClipID = selectedClipIDs.first ?? videoClips.last?.id ?? audioClips.last?.id
        }
        scheduleAutosave()
        scheduleRebuild()
    }

    enum AudioLayoutMode: Int, Hashable, CaseIterable, Codable {
        case playlist = 0
        case layer = 1

        var title: String {
            switch self {
            case .playlist: "Playlist"
            case .layer: "Layer"
            }
        }
    }

    /// Default crossfade length applied at playlist junctions.
    static let playlistCrossfade: TimeInterval = 0.75
    /// Gap / overlap threshold for magnetic snap on release.
    static let playlistSnapThreshold: TimeInterval = 0.12

    var duration: TimeInterval {
        let ends = videoClips.map(\.timelineEnd) + audioClips.map(\.timelineEnd)
        return ends.max() ?? 0
    }

    /// Time range represented by the playlist width. Stays put while the
    /// longest clip is shortened so clip width can actually change.
    var layoutDuration: TimeInterval {
        max(duration, timelineSpan, 0.0001)
    }

    // nonisolated: immutable Sendable constants, needed by MediaClip.sanitized()
    // which runs outside the main actor (project/autosave decode).
    nonisolated static let minimumClipDuration: TimeInterval = 0.12
    /// Floor for a clip's rendered duration. Composition inserts `max(0.05, clip.duration)`,
    /// so keep the stored duration no larger than the media — a 50 ms file must not become 0.12 s.
    nonisolated static let minimumRenderedDuration: TimeInterval = 0.05

    /// Duration a clip can actually render: never more than the media available from
    /// `inPoint`. `insertTimeRange` throws when asked for more than the source holds,
    /// and one bad insert fails the entire timeline rebuild — so the rendered floor
    /// applies only when the media can supply it, never inflating a shorter file.
    nonisolated static func renderableDuration(
        requested: TimeInterval,
        sourceDuration: TimeInterval,
        inPoint: TimeInterval
    ) -> TimeInterval {
        let available = max(0, sourceDuration - max(0, inPoint))
        return min(max(minimumRenderedDuration, requested), available)
    }

    func growTimelineSpan() {
        if duration <= 0 {
            timelineSpan = 0
            return
        }
        timelineSpan = max(timelineSpan, duration)
    }

    var hasVideo: Bool { !videoClips.isEmpty }
    var hasMusic: Bool { !audioClips.isEmpty }

    var clipName: String {
        videoClips.first?.displayName ?? "No clip"
    }

    /// Window / chrome title: prefer saved project filename when available.
    var projectDisplayName: String {
        if let url = projectFileURL {
            return url.deletingPathExtension().lastPathComponent
        }
        return clipName
    }

    var exportSourceSize: CGSize {
        renderSize.width > 1 ? renderSize : CGSize(width: 1080, height: 1920)
    }

    var exportSourceFPS: Double {
        if isProMode { return proSettings.frameRate }
        let seconds = frameDuration.seconds
        guard seconds > 0 else { return 30 }
        return 1.0 / seconds
    }

    var selectedVideo: MediaClip? {
        videoClips.first(where: { $0.id == selectedClipID })
    }

    var selectedAudio: MediaClip? {
        audioClips.first(where: { $0.id == selectedClipID })
    }

    var maxVideoFadeIn: TimeInterval { max(0, (selectedVideo?.duration ?? 0) - (selectedVideo?.fadeOut ?? 0)) }
    var maxVideoFadeOut: TimeInterval { max(0, (selectedVideo?.duration ?? 0) - (selectedVideo?.fadeIn ?? 0)) }
    var maxAudioFadeIn: TimeInterval { max(0, (selectedAudio?.duration ?? 0) - (selectedAudio?.fadeOut ?? 0)) }
    var maxAudioFadeOut: TimeInterval { max(0, (selectedAudio?.duration ?? 0) - (selectedAudio?.fadeIn ?? 0)) }

    let player = AVPlayer()

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var mix = AVMutableComposition()
    private var rebuildTask: Task<Void, Never>?
    /// Bumped every time a rebuild is scheduled; lets `waitForRebuildsToSettle()`
    /// detect a newer rebuild queued while it was awaiting an older one.
    private var rebuildGeneration = 0
    /// Bumped by export start/cancel so a deferred snapshot (queued behind a
    /// pending rebuild) can tell whether its export intent is still valid.
    private var exportIntent = 0
    private var renderSize = CGSize(width: 1380, height: 2304)
    private var frameDuration = CMTime(value: 1, timescale: 60)
    private var musicTrackIDs: [UUID: CMPersistentTrackID] = [:]
    /// One composition audio track per video clip, so each clip gets its own
    /// `AVAudioMixInputParameters` (AVFoundation keeps one parameter set per track, so a
    /// single shared track would drop earlier clips' fades/gain).
    private var videoAudioTrackIDs: [UUID: CMPersistentTrackID] = [:]
    private var didStart = false
    private var terminationObserver: NSObjectProtocol?
    private var history: [EditorSnapshot] = []
    private var future: [EditorSnapshot] = []
    private var autosaveTimer: Timer?
    /// Lock-box token for the writer pipeline. `Task.isCancelled` is always false
    /// inside `requestMediaDataWhenReady` callbacks (they run on raw dispatch queues
    /// with no task context), so `cancelExport()` flips this flag instead (HIGH-2).
    final class ExportCancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private var activeExportSession: AVAssetExportSession?
    private var exportCancelFlag: ExportCancelFlag?
    private var exportProgressTimer: Timer?
    private var exportWriterTask: Task<Void, Never>?
    private var exportTemporaryURLs: Set<URL> = []
    /// Destination of the in-flight export; used to delete incomplete files on cancel/failure.
    var exportDestinationURL: URL?

    /// Monotonic revision counter — bumped on every MCP-initiated mutation.
    private(set) var mcpRevision: Int = 0

    func bumpMCPRevision() {
        mcpRevision += 1
    }

    /// Public bridge for MCP server — the MCP layer calls these instead of reaching into private state.
    func addVideoPublic(url: URL, start: TimeInterval?, ontoTrackID: UUID) async -> Bool {
        await addVideo(url, fade: 0, at: start, ontoTrackID: ontoTrackID)
    }

    func addAudioPublic(url: URL, start: TimeInterval?, ontoTrackID: UUID) async -> Bool {
        await addAudio(url, fade: 0, at: start, ontoTrackID: ontoTrackID)
    }

    func videoIndexPublic(_ id: UUID) -> Int? { videoIndex(id) }
    func audioIndexPublic(_ id: UUID) -> Int? { audioIndex(id) }
    func gaplessSplitPublic(_ clip: MediaClip, at time: TimeInterval) -> (left: MediaClip, right: MediaClip) {
        gaplessSplit(clip, at: time)
    }
    func deleteClipPublic(clipID: UUID) {
        deleteClip(clipID: clipID)
    }
    func rebuildCompositionPublic() async {
        await rebuildAndWait()
    }
    func applyFadesPublic(refreshingVideo: Bool = true) {
        applyFades(refreshingVideo: refreshingVideo)
    }

    /// MCP export entry point — bypasses the save panel.
    /// Returns false when nothing was started (export already running / empty timeline),
    /// so the MCP layer can report failure instead of a fake `"started"` (HIGH-3).
    @discardableResult
    func beginExportDirect(settings: ExportSettings, destination: URL) -> Bool {
        guard !isExporting, player.currentItem != nil else { return false }
        var settings = settings
        settings.sanitize()

        // Claim the export slot now; if a rebuild is mid-flight, wait for it before
        // snapshotting so the item's asset and the fade instructions come from the
        // same composition (CRITICAL-1).
        isExporting = true
        exportProgress = 0
        errorMessage = nil
        exportIntent += 1
        let intent = exportIntent
        Task { @MainActor in
            await self.waitForRebuildsToSettle()
            guard self.isExporting, self.exportIntent == intent else { return }
            self.startExportSnapshot(settings: settings, destination: destination)
        }
        return true
    }

    private func startExportSnapshot(settings: ExportSettings, destination: URL) {
        guard let item = player.currentItem else {
            isExporting = false
            status = "Nothing to export"
            return
        }
        try? FileManager.default.removeItem(at: destination)
        exportDestinationURL = destination

        let videoComposition = makeExportVideoComposition(settings: settings)
        let audioMix = item.audioMix ?? makeAudioMix()

        switch settings.mode {
        case .animatedGIF:
            status = "Exporting… (animated GIF)"
            startGIFExport(
                asset: item.asset,
                settings: settings,
                destination: destination,
                videoComposition: videoComposition
            )
        case .xLoop:
            status = "Exporting… (X loop H.264/AAC)"
            startXLoopExport(
                asset: item.asset,
                settings: settings,
                destination: destination,
                videoComposition: videoComposition,
                audioMix: audioMix
            )
        case .video where settings.prefersWriterPipeline
            || (isProMode && abs(proSettings.sampleRate - 48_000) > 1):
            status = "Exporting… (writer, \(settings.codec.rawValue)/\(settings.container.rawValue))"
            startWriterExport(
                asset: item.asset,
                settings: settings,
                destination: destination,
                videoComposition: videoComposition,
                audioMix: audioMix
            )
        case .video:
            status = "Exporting… (session, \(settings.codec.rawValue)/\(settings.container.rawValue))"
            startSessionExport(
                asset: item.asset,
                settings: settings,
                destination: destination,
                videoComposition: videoComposition,
                audioMix: audioMix
            )
        }
    }

    /// MCP template entry point — replaces the live timeline without a confirmation dialog.
    /// The MCP layer owns the explicit confirmation gate.
    func resetForTemplate(videoTrackCount: Int, audioTrackCount: Int, name: String?) async {
        guard !isExporting else { return }
        pushHistory()

        let videoCount = max(1, videoTrackCount)
        let audioCount = max(1, audioTrackCount)
        var templateTracks: [TimelineTrack] = []

        for index in 0..<videoCount {
            let id = index == 0 ? Self.defaultVideoTrackID : UUID()
            let trackName = index == 0 ? "Video" : "Video \(index + 1)"
            templateTracks.append(TimelineTrack(id: id, name: trackName, kind: .video, volume: 1))
        }
        for index in 0..<audioCount {
            let id = index == 0 ? Self.defaultAudioTrackID : UUID()
            let trackName = index == 0 ? "Music" : "Audio \(index + 1)"
            templateTracks.append(TimelineTrack(id: id, name: trackName, kind: .audio, volume: index == 0 ? 0.62 : 1))
        }

        for clip in videoClips { filmstrips[clip.id] = nil }
        videoClips = []
        audioClips = []
        tracks = templateTracks
        selectedClipID = nil
        selectedClipIDs = []
        selectedTrackIDs = []
        focusedLane = .video
        focusedTrackID = Self.defaultVideoTrackID
        currentTime = 0
        player.pause()
        isPlaying = false
        loopEnabled = false
        loopIn = 0
        loopOut = 0
        timelineSpan = 0
        if let name {
            status = "Created template: \(name)"
        } else {
            status = "Created new project template"
        }
        errorMessage = nil
        bumpMCPRevision()
        projectFileURL = nil
        scheduleAutosave()
        await rebuildAndWait()
    }

    /// MCP save entry point — bypasses the save panel after template creation.
    func saveProjectDirect(to destination: URL) throws {
        let finalURL = destination.pathExtension.lowercased() == "salproject"
            ? destination
            : destination.deletingPathExtension().appendingPathExtension("salproject")
        try writeProjectDocument(makeProjectDocument(), to: finalURL)
        projectFileURL = finalURL
        status = "Saved \(finalURL.lastPathComponent)"
        errorMessage = nil
    }

    private static func filmstripFrameCount(for sourceDuration: TimeInterval) -> Int {
        // Full-source density (~2 thumbs/sec), capped so long clips stay light.
        max(12, min(64, Int(ceil(max(sourceDuration, 0.1) * 2))))
    }

    private func scheduleFilmstrip(for clip: MediaClip) {
        let id = clip.id
        let url = clip.url
        let sourceDuration = max(clip.sourceDuration, 0.05)
        // Stills repeat one picture. A short strip is enough; the lane masks it
        // by in-point the same way a filmstrip is masked.
        let count = StillImage.isStill(url) ? 12 : Self.filmstripFrameCount(for: sourceDuration)
        Task {
            // Full-source frames so trim only remasks the window — no live regenerate.
            let frames = await Filmstrip.generate(url: url, count: count, inPoint: 0, duration: sourceDuration)
            filmstrips[id] = frames
        }
    }

    private static func waveformPointCount(for sourceDuration: TimeInterval) -> Int {
        max(720, min(8192, Int(ceil(max(sourceDuration, 0.1) * 48))))
    }

    private func scheduleWaveform(for clip: MediaClip) {
        let id = clip.id
        let url = clip.url
        let sourceDuration = max(clip.sourceDuration, 0.05)
        let points = Self.waveformPointCount(for: sourceDuration)
        Task {
            // Full-source peaks so trim only remasks the window — no live re-extract.
            let peaks = await Waveform.peaks(url: url, points: points, start: 0, limit: sourceDuration)
            if let index = audioClips.firstIndex(where: { $0.id == id }) {
                audioClips[index].waveform = peaks
            }
        }
    }

    private func scheduleAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.saveProject()
            }
        }
    }

    private func flushAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        do {
            try writeProjectDocument(makeProjectDocument(), to: autosaveURL)
        } catch {
            errorMessage = "Autosave failed: \(error.localizedDescription)"
        }
    }

    private var autosaveURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudioAudioLane", isDirectory: true)
            .appendingPathComponent("autosave.json")
    }

    private func makeProjectDocument() -> ProjectDocument {
        syncTracksFromVolumes()
        return ProjectDocument(
            clips: ProjectClips(video: videoClips, audio: audioClips),
            tracks: tracks,
            focusedLane: focusedLane.rawValue,
            focusedTrackID: focusedTrackID,
            selectedClipID: selectedClipID,
            selectedClipIDs: Array(selectedClipIDs),
            videoVolume: videoVolume,
            musicVolume: musicVolume,
            isDuckingMusic: isDuckingMusic,
            audioLayoutMode: audioLayoutMode.rawValue,
            timelineSpan: timelineSpan,
            playhead: currentTime,
            isProMode: isProMode,
            proSettings: proSettings
        )
    }

    private func writeProjectDocument(_ project: ProjectDocument, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(project)
        try data.write(to: url, options: Data.WritingOptions.atomic)
    }

    /// Background autosave into Application Support (same JSON format as user Save).
    func saveProject() async {
        do {
            try writeProjectDocument(makeProjectDocument(), to: autosaveURL)
        } catch {
            errorMessage = "Autosave failed: \(error.localizedDescription)"
        }
    }

    /// ⌘S — save in place when a project URL is known; otherwise Save As.
    func saveUserProject() {
        if let url = projectFileURL {
            writeUserProject(to: url)
        } else {
            saveUserProjectAs()
        }
    }

    /// ⇧⌘S — always show NSSavePanel.
    func saveUserProjectAs() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Save Project"
        panel.message = "Save StudioLane project"
        let defaultBase = (clipName == "No clip") ? "Untitled" : clipName
        panel.nameFieldStringValue = projectFileURL?.lastPathComponent ?? "\(defaultBase).salproject"
        panel.allowedContentTypes = [.salProject]
        panel.allowsOtherFileTypes = false
        if let dir = projectFileURL?.deletingLastPathComponent() {
            panel.directoryURL = dir
        }
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let finalURL: URL = {
            if dest.pathExtension.lowercased() == "salproject" { return dest }
            return dest.deletingPathExtension().appendingPathExtension("salproject")
        }()
        writeUserProject(to: finalURL)
    }

    private func writeUserProject(to url: URL) {
        do {
            try writeProjectDocument(makeProjectDocument(), to: url)
            projectFileURL = url
            // Keep autosave in sync so relaunch still restores the latest state.
            try? writeProjectDocument(makeProjectDocument(), to: autosaveURL)
            let label = "Saved \(url.lastPathComponent)"
            status = label
            errorMessage = nil
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if self.status == label { self.status = "" }
            }
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Open a previously saved `.salproject` (same decode path as autosave).
    func openUserProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Open Project"
        panel.message = "Open a StudioLane project"
        panel.allowedContentTypes = [.salProject, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let project = try JSONDecoder().decode(ProjectDocument.self, from: data)
            guard applyProjectDocument(project) else {
                errorMessage = "Project has no usable media (files missing)."
                return
            }
            projectFileURL = url
            let label = "Opened \(url.lastPathComponent)"
            status = label
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if self.status == label { self.status = "" }
            }
        } catch {
            errorMessage = "Open failed: \(error.localizedDescription)"
        }
    }

    /// Applies a decoded project. Clips whose source files no longer exist are
    /// dropped; returns false when there is nothing usable to restore.
    @discardableResult
    private func applyProjectDocument(_ project: ProjectDocument) -> Bool {
        let loadedVideoClips = project.clips.video.compactMap { $0.sanitized() }
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
        let loadedAudioClips = project.clips.audio.compactMap { $0.sanitized() }
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }

        var loadedTracks = project.tracks ?? []
        loadedTracks.removeAll { !$0.volume.isFinite || $0.volume < 0 || $0.volume > 1 }
        var seenTrackIDs = Set<UUID>()
        loadedTracks.removeAll { !seenTrackIDs.insert($0.id).inserted }
        if loadedTracks.contains(where: { $0.kind == .video }) == false
            || loadedTracks.contains(where: { $0.kind == .audio }) == false {
            loadedTracks = []
        }

        guard !loadedVideoClips.isEmpty || !loadedAudioClips.isEmpty else {
            videoClips = []
            audioClips = []
            tracks = []
            return false
        }
        var seenClipIDs = Set<UUID>()
        videoClips = loadedVideoClips.filter { seenClipIDs.insert($0.id).inserted }
        loadedAudioClips.forEach { seenClipIDs.insert($0.id) }
        audioClips = loadedAudioClips.filter { clip in
            !videoClips.contains { $0.id == clip.id }
        }

        if loadedTracks.isEmpty {
            tracks = []
        } else {
            let validVideoTrackIDs = Set(loadedTracks.filter { $0.kind == .video }.map(\.id))
            let validAudioTrackIDs = Set(loadedTracks.filter { $0.kind == .audio }.map(\.id))
            videoClips = videoClips.filter { validVideoTrackIDs.contains($0.trackID) }
            audioClips = audioClips.filter { validAudioTrackIDs.contains($0.trackID) }
        }
        guard !videoClips.isEmpty || !audioClips.isEmpty else {
            videoClips = []
            audioClips = []
            tracks = []
            return false
        }
        // Drop any previously saved windowed peaks / filmstrips; regenerate full-source maps.
        for i in audioClips.indices { audioClips[i].waveform = [] }
        filmstrips = [:]
        if !loadedTracks.isEmpty {
            tracks = loadedTracks
        }
        focusedLane = Lane(rawValue: project.focusedLane) ?? .video
        if let savedTrackID = project.focusedTrackID, track(id: savedTrackID) != nil {
            focusedTrackID = savedTrackID
        } else {
            focusedTrackID = focusedLane == .audio
                ? audioTracks.first?.id ?? Self.defaultAudioTrackID
                : videoTracks.first?.id ?? Self.defaultVideoTrackID
        }
        selectedClipID = project.selectedClipID
        if let ids = project.selectedClipIDs, !ids.isEmpty {
            let valid = Set(videoClips.map(\.id) + audioClips.map(\.id))
            selectedClipIDs = Set(ids.filter { valid.contains($0) })
            if selectedClipIDs.isEmpty {
                selectedClipIDs = Set([project.selectedClipID].compactMap { $0 })
            }
            if let sid = selectedClipID, !selectedClipIDs.contains(sid) {
                selectedClipID = selectedClipIDs.first
            }
        } else {
            selectedClipIDs = Set([project.selectedClipID].compactMap { $0 })
        }
        videoVolume = project.videoVolume.isFinite ? min(max(project.videoVolume, 0), 1) : 1
        musicVolume = project.musicVolume.isFinite ? min(max(project.musicVolume, 0), 1) : 0.62
        isDuckingMusic = project.isDuckingMusic
        if let mode = project.audioLayoutMode {
            audioLayoutMode = AudioLayoutMode(rawValue: mode) ?? .playlist
        }
        isProMode = project.isProMode
            ?? UserDefaults.standard.bool(forKey: Self.proModeDefaultsKey)
        if var savedSettings = project.proSettings {
            savedSettings.sanitize()
            proSettings = savedSettings
        }
        ensureDefaultTracks()
        // Prefer saved primary volumes when tracks were synthesized.
        if let i = tracks.firstIndex(where: { $0.kind == .video }) { tracks[i].volume = videoVolume }
        if let i = tracks.firstIndex(where: { $0.kind == .audio }) { tracks[i].volume = musicVolume }
        if let span = project.timelineSpan {
            timelineSpan = span.isFinite && span >= duration ? span : duration
        } else {
            timelineSpan = max(timelineSpan, duration)
        }
        selectedTrackIDs = trackIDsWithSelectedClips
        if let saved = project.playhead, saved.isFinite {
            currentTime = min(max(0, saved), max(duration, 0))
        } else {
            currentTime = 0
        }
        regenerateMissingVisuals()
        scheduleRebuild()
        return true
    }

    /// Restores the last autosaved project. Clips whose source files no longer
    /// exist are dropped; returns false when there is nothing usable to restore.
    private func restoreAutosave() -> Bool {
        guard let data = try? Data(contentsOf: autosaveURL),
              let project = try? JSONDecoder().decode(ProjectDocument.self, from: data) else { return false }
        return applyProjectDocument(project)
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        Task { await loadDefaults() }
        installTimeObserver()
        installKeyMonitor()
        installTerminationHandler()
    }

    func togglePlay() {
        guard duration > 0 else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= duration - 0.04 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(0, time), max(duration, 0))
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func beginEdit() {
        guard !isEditingClip else { return }
        pushHistory()
        growTimelineSpan()
        isEditingClip = true
    }

    func undo() {
        guard let snapshot = history.popLast() else { return }
        future.append(currentSnapshot)
        restore(snapshot)
        rebuild()
    }

    func redo() {
        guard let snapshot = future.popLast() else { return }
        history.append(currentSnapshot)
        restore(snapshot)
        rebuild()
    }

    private func pushHistory() {
        guard !isLoading else { return }
        history.append(currentSnapshot)
        future.removeAll()
        if history.count > 100 { history.removeFirst() }
        refreshHistoryState()
    }

    private var currentSnapshot: EditorSnapshot {
        EditorSnapshot(
            videoClips: videoClips,
            audioClips: audioClips,
            tracks: tracks,
            selectedClipID: selectedClipID,
            selectedClipIDs: Array(selectedClipIDs),
            focusedLane: focusedLane.rawValue,
            focusedTrackID: focusedTrackID,
            videoVolume: videoVolume,
            musicVolume: musicVolume,
            isDuckingMusic: isDuckingMusic,
            audioLayoutMode: audioLayoutMode.rawValue,
            isProMode: isProMode,
            proSettings: proSettings
        )
    }

    private func restore(_ snapshot: EditorSnapshot) {
        videoClips = snapshot.videoClips
        audioClips = snapshot.audioClips
        tracks = snapshot.tracks.isEmpty ? tracks : snapshot.tracks
        selectedClipID = snapshot.selectedClipID
        selectedClipIDs = Set(snapshot.selectedClipIDs)
        if selectedClipIDs.isEmpty, let id = selectedClipID { selectedClipIDs = [id] }
        focusedLane = Lane(rawValue: snapshot.focusedLane) ?? .video
        focusedTrackID = snapshot.focusedTrackID ?? focusedTrackID
        selectedTrackIDs = trackIDsWithSelectedClips
        videoVolume = snapshot.videoVolume
        musicVolume = snapshot.musicVolume
        isDuckingMusic = snapshot.isDuckingMusic
        audioLayoutMode = AudioLayoutMode(rawValue: snapshot.audioLayoutMode) ?? .playlist
        isProMode = snapshot.isProMode
        proSettings = snapshot.proSettings
        proSettings.sanitize()
        ensureDefaultTracks()
        isEditingClip = false
        timelineSpan = max(timelineSpan, duration)
        regenerateMissingVisuals()
        refreshHistoryState()
    }

    private func refreshHistoryState() {
        canUndo = !history.isEmpty
        canRedo = !future.isEmpty
    }

    private func regenerateMissingVisuals() {
        for clip in videoClips where filmstrips[clip.id] == nil {
            scheduleFilmstrip(for: clip)
        }
        for clip in audioClips where clip.waveform.isEmpty {
            scheduleWaveform(for: clip)
        }
    }

    func goToStart() { seek(to: 0) }
    func goToEnd() { seek(to: duration) }

    /// Media-agnostic open: accepts video + audio and routes by type.
    func pickMediaFile(preferredKind: TimelineTrack.Kind? = nil, ontoTrackID: UUID? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.openMediaTypes
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        switch preferredKind {
        case .video:
            panel.message = videoClips.isEmpty ? "Open video or image" : "Add a video or image to the track"
        case .audio:
            panel.message = "Add audio to the track"
        case nil:
            panel.message = "Open video, image, or audio"
        }
        guard panel.runModal() == .OK else { return }
        acceptDroppedFiles(panel.urls, at: nil, ontoTrackID: ontoTrackID, preferKind: preferredKind)
    }

    func pickVideoFile(ontoTrackID: UUID? = nil) {
        pickMediaFile(preferredKind: .video, ontoTrackID: ontoTrackID ?? focusedVideoTrackID())
    }

    func pickAudioFile(ontoTrackID: UUID? = nil) {
        let trackID = ontoTrackID ?? focusedAudioTrackID()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Add audio to the track"
        guard panel.runModal() == .OK else { return }
        Task {
            for url in panel.urls {
                await addAudio(url, at: nil, replaceSelected: false, ontoTrackID: trackID)
            }
            if audioLayoutMode == .playlist {
                normalizeAudioPlaylist(ripple: true)
                rebuild()
            }
        }
    }

    func focusedVideoTrackID() -> UUID {
        if let t = track(id: focusedTrackID), t.kind == .video { return t.id }
        return videoTracks.first?.id ?? Self.defaultVideoTrackID
    }

    func focusedAudioTrackID() -> UUID {
        if let t = track(id: focusedTrackID), t.kind == .audio { return t.id }
        return audioTracks.first?.id ?? Self.defaultAudioTrackID
    }

    nonisolated static let audioExtensions: Set<String> = [
        "wav", "mp3", "m4a", "aac", "aiff", "aif", "caf", "flac", "ogg", "wma"
    ]
    nonisolated static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "mpg", "mpeg", "mts", "m2ts", "webm"
    ]

    /// Movies, still images, and audio. Images land on a video lane.
    static let openMediaTypes: [UTType] = [
        .movie, .mpeg4Movie, .quickTimeMovie, .avi,
        .image, .jpeg, .png, .gif, .tiff, .bmp, .heic, .heif, .webP,
        .audio, .mp3, .wav, .aiff, .mpeg4Audio
    ]

    static let mediaDropTypes: [UTType] = [
        .fileURL, .movie, .audio, .audiovisualContent, .image
    ]

    nonisolated static func mediaKind(for url: URL) -> TimelineTrack.Kind {
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        // Photos, screenshots, RAW, and anything else UniformTypeIdentifiers calls an image.
        if StillImage.isStill(url) { return .video }
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let type = values.contentType {
            if type.conforms(to: .image) { return .video }
            if type.conforms(to: .audiovisualContent) && !type.conforms(to: .audio) {
                return .video
            }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .movie) { return .video }
        }
        // Default: treat unknown as video if preferred open, else audio-safe guess by AVAsset later.
        return .video
    }

    /// Open panel: place first at playhead (or 0), abut subsequent full-length clips; extend timeline.
    func fillMusicFromFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Fill from Files — place playlist starting at playhead (extends timeline)"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        Task {
            pushHistory()
            let startMode = audioLayoutMode
            audioLayoutMode = .playlist
            var cursor = max(0, currentTime)
            for url in panel.urls {
                await addAudio(url, at: cursor, replaceSelected: false, recordsHistory: false, normalize: false)
                if let last = audioClips.last {
                    cursor = last.timelineEnd
                }
            }
            audioLayoutMode = startMode == .layer ? .playlist : startMode
            normalizeAudioPlaylist(ripple: true)
            applyPlaylistCrossfades()
            growTimelineSpan()
            rebuild()
        }
    }

    func acceptDroppedFiles(
        _ urls: [URL],
        at time: TimeInterval? = nil,
        ontoTrackID: UUID? = nil,
        preferKind: TimelineTrack.Kind? = nil
    ) {
        guard !urls.isEmpty else { return }
        let dropTime = time.map { snapTime(max(0, $0)) }
        Task {
            var sawAudio = false
            var cursor = dropTime
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                // Route by the file's real type — never force a file into a lane of a different
                // kind (a WAV dropped on a video lane must stay audio, not become a video clip).
                let kind = Self.mediaKind(for: url)

                switch kind {
                case .audio:
                    sawAudio = true
                    let trackID: UUID = {
                        if let ontoTrackID, let t = track(id: ontoTrackID), t.kind == .audio {
                            return ontoTrackID
                        }
                        return focusedAudioTrackID()
                    }()
                    await addAudio(url, at: cursor, replaceSelected: false, ontoTrackID: trackID, recordsHistory: true, normalize: false)
                    if let last = audioClips.last, dropTime != nil, audioLayoutMode == .playlist {
                        cursor = last.timelineEnd
                    }
                case .video:
                    let trackID: UUID = {
                        if let ontoTrackID, let t = track(id: ontoTrackID), t.kind == .video {
                            return ontoTrackID
                        }
                        return focusedVideoTrackID()
                    }()
                    await addVideo(url, at: cursor, ontoTrackID: trackID)
                    if let last = videoClips.last, dropTime != nil {
                        cursor = last.timelineEnd
                    }
                }
            }
            if sawAudio, audioLayoutMode == .playlist {
                normalizeAudioPlaylist(ripple: true)
                applyPlaylistCrossfades()
            }
            growTimelineSpan()
            rebuild()
        }
    }

    func acceptDroppedAudio(_ urls: [URL], at time: TimeInterval? = nil, ontoTrackID: UUID? = nil) {
        acceptDroppedFiles(urls, at: time, ontoTrackID: ontoTrackID ?? focusedAudioTrackID(), preferKind: .audio)
    }

    /// Explicit replace: keep timelineStart + duration (or stretch to new source), swap URL, regen waveform.
    func replaceSelectedMusic() {
        guard let id = selectedAudio?.id, let i = audioIndex(id) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Replace selected music clip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await replaceAudio(at: i, with: url) }
    }

    func fitSelectedMusicToVideo() {
        guard let id = selectedAudio?.id, let i = audioIndex(id) else { return }
        let videoEnd = videoClips.map(\.timelineEnd).max() ?? 0
        guard videoEnd > 0 else { return }
        pushHistory()
        var clip = audioClips[i]
        // A clip parked after the video end would otherwise stay put at the trim floor.
        // Re-anchor it so it ends within the video span before shortening.
        let sourceMax = Self.renderableDuration(requested: clip.sourceDuration, sourceDuration: clip.sourceDuration, inPoint: clip.inPoint)
        if clip.timelineStart >= videoEnd - Self.minimumRenderedDuration {
            clip.timelineStart = max(0, videoEnd - sourceMax)
        }
        let remaining = max(Self.minimumRenderedDuration, videoEnd - clip.timelineStart)
        let maxDur = Self.renderableDuration(requested: remaining, sourceDuration: clip.sourceDuration, inPoint: clip.inPoint)
        clip.duration = min(remaining, maxDur)
        clip.clampFades()
        audioClips[i] = clip
        if audioLayoutMode == .playlist {
            normalizeAudioPlaylist(ripple: true)
            applyPlaylistCrossfades()
        }
        rebuild()
    }

    func setAudioLayoutMode(_ mode: AudioLayoutMode) {
        guard mode != audioLayoutMode else { return }
        pushHistory()
        audioLayoutMode = mode
        if mode == .playlist {
            normalizeAudioPlaylist(ripple: true)
            applyPlaylistCrossfades()
        }
        rebuild()
    }

    func toggleAudioLayoutMode() {
        setAudioLayoutMode(audioLayoutMode == .playlist ? .layer : .playlist)
    }

    func deleteSelectedVideo() {
        deleteSelectedClips(preferringLane: .video)
    }

    func deleteSelectedAudio() {
        deleteSelectedClips(preferringLane: .audio)
    }

    /// Deletes every clip in `selectedClipIDs`. Falls back to the primary clip in `preferringLane` when the set is empty.
    func deleteSelectedClips(preferringLane: Lane? = nil) {
        guard !isLoading else { return }
        var ids = selectedClipIDs
        if ids.isEmpty {
            if let preferringLane {
                switch preferringLane {
                case .video: if let id = selectedVideo?.id { ids = [id] }
                case .audio: if let id = selectedAudio?.id { ids = [id] }
                }
            } else if let id = selectedClipID {
                ids = [id]
            }
        }
        let videoIDs = ids.filter { videoIndex($0) != nil }
        let audioIDs = ids.filter { audioIndex($0) != nil }
        guard !videoIDs.isEmpty || !audioIDs.isEmpty else { return }
        pushHistory()
        for id in videoIDs {
            videoClips.removeAll { $0.id == id }
            filmstrips[id] = nil
        }
        for id in audioIDs {
            audioClips.removeAll { $0.id == id }
        }
        selectedClipIDs.subtract(ids)
        if let sid = selectedClipID, ids.contains(sid) {
            selectedClipID = selectedClipIDs.first ?? videoClips.last?.id ?? audioClips.last?.id
        }
        if let preferringLane { focusedLane = preferringLane }
        else if videoIDs.isEmpty { focusedLane = .audio }
        else { focusedLane = .video }
        if !audioIDs.isEmpty, audioLayoutMode == .playlist, !audioClips.isEmpty {
            normalizeAudioPlaylist(ripple: true)
            applyPlaylistCrossfades()
        }
        scheduleAutosave()
        scheduleRebuild()
    }

    func deleteClip(clipID: UUID) {
        if videoIndex(clipID) == nil && audioIndex(clipID) == nil { return }
        pushHistory()
        if let i = videoIndex(clipID) {
            let id = videoClips[i].id
            videoClips.remove(at: i)
            filmstrips[id] = nil
            focusedLane = .video
        } else if let i = audioIndex(clipID) {
            audioClips.remove(at: i)
            focusedLane = .audio
        }
        selectedClipIDs.remove(clipID)
        if selectedClipID == clipID {
            selectedClipID = selectedClipIDs.first ?? videoClips.last?.id ?? audioClips.last?.id
        }
        if videoIndex(clipID) == nil, audioLayoutMode == .playlist, !audioClips.isEmpty {
            normalizeAudioPlaylist(ripple: true)
            applyPlaylistCrossfades()
        }
        scheduleAutosave()
        scheduleRebuild()
    }

    func deleteVideoTrack() {
        guard !videoClips.isEmpty else { return }
        pushHistory()
        let ids = Set(videoClips.map(\.id))
        for clip in videoClips { filmstrips[clip.id] = nil }
        videoClips.removeAll()
        selectedClipIDs.subtract(ids)
        if let sid = selectedClipID, ids.contains(sid) {
            selectedClipID = selectedClipIDs.first ?? audioClips.last?.id
        }
        focusedLane = .video
        scheduleAutosave()
        scheduleRebuild()
    }

    func deleteMusicTrack() {
        guard !audioClips.isEmpty else { return }
        pushHistory()
        let ids = Set(audioClips.map(\.id))
        audioClips.removeAll()
        selectedClipIDs.subtract(ids)
        if let sid = selectedClipID, ids.contains(sid) {
            selectedClipID = selectedClipIDs.first ?? videoClips.last?.id
        }
        focusedLane = .audio
        scheduleAutosave()
        scheduleRebuild()
    }

    func toggleMuteSelectedAudio() {
        // A discrete click must record its own step. beginEdit() no-ops while a
        // slider drag is still open, which left Mute off the undo stack.
        guard !isLoading else { return }
        isEditingClip = false
        pushHistory()
        mutateSelectedAudio { $0.muted.toggle() }
        scheduleAutosave()
    }

    func isClipSelected(_ id: UUID) -> Bool {
        selectedClipIDs.contains(id) || selectedClipID == id
    }

    func selectVideoClip(_ id: UUID, extending: Bool = false) {
        focusedLane = .video
        if let clip = videoClips.first(where: { $0.id == id }) {
            focusedTrackID = clip.trackID
        }
        applySelection(id, extending: extending)
    }

    func selectAudioClip(_ id: UUID, extending: Bool = false) {
        focusedLane = .audio
        if let clip = audioClips.first(where: { $0.id == id }) {
            focusedTrackID = clip.trackID
        }
        applySelection(id, extending: extending)
    }

    private func applySelection(_ id: UUID, extending: Bool) {
        if extending {
            if selectedClipIDs.contains(id) {
                selectedClipIDs.remove(id)
                if selectedClipID == id {
                    selectedClipID = selectedClipIDs.first
                }
                // Drop track from explicit multi-select when it no longer has selected clips.
                if let trackID = (videoClips.first(where: { $0.id == id })
                    ?? audioClips.first(where: { $0.id == id }))?.trackID,
                   !trackHasSelectedClip(trackID) {
                    selectedTrackIDs.remove(trackID)
                }
            } else {
                selectedClipIDs.insert(id)
                selectedClipID = id
                if let trackID = (videoClips.first(where: { $0.id == id })
                    ?? audioClips.first(where: { $0.id == id }))?.trackID {
                    selectedTrackIDs.insert(trackID)
                }
            }
        } else {
            selectedClipIDs = [id]
            selectedClipID = id
            if let trackID = (videoClips.first(where: { $0.id == id })
                ?? audioClips.first(where: { $0.id == id }))?.trackID {
                selectedTrackIDs = [trackID]
            } else {
                selectedTrackIDs = []
            }
        }
    }

    /// Select a track from the sidebar. Plain click replaces selection; Shift-click toggles the track
    /// (and all of its clips) into/out of the multi-selection. Empty tracks stay highlighted via `selectedTrackIDs`.
    func selectTrack(_ trackID: UUID, extending: Bool = false) {
        guard let t = track(id: trackID) else { return }
        focusedTrackID = trackID
        focusedLane = t.kind == .video ? .video : .audio
        let clipIDsOnTrack = clipIDs(onTrack: trackID)

        if extending {
            if selectedTrackIDs.contains(trackID) {
                selectedTrackIDs.remove(trackID)
                selectedClipIDs.subtract(clipIDsOnTrack)
                if let sid = selectedClipID, !selectedClipIDs.contains(sid) {
                    selectedClipID = selectedClipIDs.first
                }
            } else {
                selectedTrackIDs.insert(trackID)
                selectedClipIDs.formUnion(clipIDsOnTrack)
                if let first = clipIDsOnTrack.first {
                    selectedClipID = first
                } else if let sid = selectedClipID, selectedClipIDs.contains(sid) {
                    // Keep existing primary when the added track is empty.
                } else {
                    selectedClipID = selectedClipIDs.first
                }
            }
        } else {
            selectedTrackIDs = [trackID]
            selectedClipIDs = clipIDsOnTrack
            selectedClipID = clipIDsOnTrack.first
        }
    }

    func trimIn(clipID: UUID, toTimelineTime time: TimeInterval, snapping: Bool = true) {
        beginEdit()
        if let i = audioIndex(clipID) {
            let original = audioClips[i]
            var anchor = original
            trimInOn(
                &anchor,
                time: snapping ? snapTime(time, excluding: [original.timelineEnd]) : time
            )
            let delta = anchor.timelineStart - original.timelineStart
            for id in directEditClipIDs(anchor: clipID) {
                if id == clipID {
                    audioClips[i] = anchor
                } else if let selectedAudioIndex = audioIndex(id) {
                    trimInOn(
                        &audioClips[selectedAudioIndex],
                        time: audioClips[selectedAudioIndex].timelineStart + delta
                    )
                } else if let selectedVideoIndex = videoIndex(id) {
                    trimInOn(
                        &videoClips[selectedVideoIndex],
                        time: videoClips[selectedVideoIndex].timelineStart + delta
                    )
                }
            }
        } else if let i = videoIndex(clipID) {
            let original = videoClips[i]
            var anchor = original
            trimInOn(
                &anchor,
                time: snapping ? snapTime(time, excluding: [original.timelineEnd]) : time
            )
            let delta = anchor.timelineStart - original.timelineStart
            for id in directEditClipIDs(anchor: clipID) {
                if id == clipID {
                    videoClips[i] = anchor
                } else if let selectedVideoIndex = videoIndex(id) {
                    trimInOn(
                        &videoClips[selectedVideoIndex],
                        time: videoClips[selectedVideoIndex].timelineStart + delta
                    )
                } else if let selectedAudioIndex = audioIndex(id) {
                    trimInOn(
                        &audioClips[selectedAudioIndex],
                        time: audioClips[selectedAudioIndex].timelineStart + delta
                    )
                }
            }
        }
        isEditingClip = true
    }

    func trimOut(clipID: UUID, toTimelineTime time: TimeInterval, snapping: Bool = true) {
        beginEdit()
        if let i = audioIndex(clipID) {
            let original = audioClips[i]
            var anchor = original
            trimOutOn(
                &anchor,
                time: snapping ? snapTime(time, excluding: [original.timelineStart]) : time
            )
            let delta = anchor.timelineEnd - original.timelineEnd
            for id in directEditClipIDs(anchor: clipID) {
                if id == clipID {
                    audioClips[i] = anchor
                } else if let selectedAudioIndex = audioIndex(id) {
                    trimOutOn(
                        &audioClips[selectedAudioIndex],
                        time: audioClips[selectedAudioIndex].timelineEnd + delta
                    )
                } else if let selectedVideoIndex = videoIndex(id) {
                    trimOutOn(
                        &videoClips[selectedVideoIndex],
                        time: videoClips[selectedVideoIndex].timelineEnd + delta
                    )
                }
            }
        } else if let i = videoIndex(clipID) {
            let original = videoClips[i]
            var anchor = original
            trimOutOn(
                &anchor,
                time: snapping ? snapTime(time, excluding: [original.timelineStart]) : time
            )
            let delta = anchor.timelineEnd - original.timelineEnd
            for id in directEditClipIDs(anchor: clipID) {
                if id == clipID {
                    videoClips[i] = anchor
                } else if let selectedVideoIndex = videoIndex(id) {
                    trimOutOn(
                        &videoClips[selectedVideoIndex],
                        time: videoClips[selectedVideoIndex].timelineEnd + delta
                    )
                } else if let selectedAudioIndex = audioIndex(id) {
                    trimOutOn(
                        &audioClips[selectedAudioIndex],
                        time: audioClips[selectedAudioIndex].timelineEnd + delta
                    )
                }
            }
        }
        isEditingClip = true
    }

    func moveAudio(clipID: UUID, toStart time: TimeInterval) {
        moveClip(clipID: clipID, toStart: time)
    }

    func moveClip(clipID: UUID, toStart time: TimeInterval, snapping: Bool = true) {
        beginEdit()
        let proposed = max(0, time)
        let start = snapping ? snapTime(proposed) : proposed
        if let i = audioIndex(clipID) {
            audioClips[i].timelineStart = start
        } else if let i = videoIndex(clipID) {
            videoClips[i].timelineStart = start
        }
        isEditingClip = true
    }

    /// Slip changes which source media is visible without moving or resizing the clip.
    func slipClip(clipID: UUID, toInPoint time: TimeInterval) {
        beginEdit()
        if let i = audioIndex(clipID) {
            audioClips[i].inPoint = min(
                max(0, time),
                max(0, audioClips[i].sourceDuration - audioClips[i].duration)
            )
        } else if let i = videoIndex(clipID) {
            videoClips[i].inPoint = min(
                max(0, time),
                max(0, videoClips[i].sourceDuration - videoClips[i].duration)
            )
        }
        isEditingClip = true
    }

    var inspectorTimelineStart: TimeInterval { primarySelectedClip?.timelineStart ?? 0 }
    var inspectorInPoint: TimeInterval { primarySelectedClip?.inPoint ?? 0 }

    /// Numeric start entry shifts all selected clips by the same delta so a
    /// multi-selection keeps its internal spacing.
    func setSelectedTimelineStart(_ start: TimeInterval) {
        guard let primary = primarySelectedClip else { return }
        beginEdit()
        let ids = selectedClipIDs.isEmpty ? Set([primary.id]) : selectedClipIDs
        let requestedDelta = max(0, start) - primary.timelineStart
        let selected = (videoClips + audioClips).filter { ids.contains($0.id) }
        let minimumStart = selected.map(\.timelineStart).min() ?? 0
        let delta = max(requestedDelta, -minimumStart)
        for id in ids {
            if let i = videoIndex(id) {
                videoClips[i].timelineStart += delta
            } else if let i = audioIndex(id) {
                audioClips[i].timelineStart += delta
            }
        }
        isEditingClip = true
    }

    /// Numeric in-point entry is a slip edit: timeline position and duration stay fixed.
    func setSelectedInPoint(_ inPoint: TimeInterval) {
        guard let primary = primarySelectedClip else { return }
        beginEdit()
        let ids = selectedClipIDs.isEmpty ? Set([primary.id]) : selectedClipIDs
        let delta = max(0, inPoint) - primary.inPoint
        for id in ids {
            if let i = videoIndex(id) {
                let maximum = max(0, videoClips[i].sourceDuration - videoClips[i].duration)
                videoClips[i].inPoint = min(max(0, videoClips[i].inPoint + delta), maximum)
            } else if let i = audioIndex(id) {
                let maximum = max(0, audioClips[i].sourceDuration - audioClips[i].duration)
                audioClips[i].inPoint = min(max(0, audioClips[i].inPoint + delta), maximum)
            }
        }
        isEditingClip = true
    }

    /// Commits a precision edit without playlist normalization. Fine nudges and
    /// numeric offsets are intentional gaps/overlaps and must not be rippled away.
    func commitPrecisionEdit() {
        isEditingClip = false
        growTimelineSpan()
        rebuild()
    }

    @discardableResult
    func nudgeSelectedClips(by delta: TimeInterval, audioOnly: Bool = false) -> Bool {
        var ids = selectedClipIDs
        if ids.isEmpty, let selectedClipID { ids = [selectedClipID] }
        if audioOnly {
            ids = ids.filter { audioIndex($0) != nil }
        }
        let clips = (videoClips + audioClips).filter { ids.contains($0.id) }
        guard !clips.isEmpty, delta.isFinite, delta != 0 else { return false }
        isEditingClip = false
        pushHistory()
        let minimumStart = clips.map(\.timelineStart).min() ?? 0
        let applied = max(delta, -minimumStart)
        for id in ids {
            if let i = videoIndex(id) {
                videoClips[i].timelineStart += applied
            } else if let i = audioIndex(id) {
                audioClips[i].timelineStart += applied
            }
        }
        growTimelineSpan()
        scheduleAutosave()
        scheduleRebuild()
        return true
    }

    func nudgeSelectedByFrames(_ frames: Int) -> Bool {
        let seconds = isProMode
            ? 1 / max(1, proSettings.frameRate)
            : frameDuration.seconds.isFinite && frameDuration.seconds > 0
                ? frameDuration.seconds
                : 1.0 / 30.0
        return nudgeSelectedClips(by: Double(frames) * seconds)
    }

    func nudgeSelectedAudio(milliseconds: Double) -> Bool {
        nudgeSelectedClips(by: milliseconds / 1_000, audioOnly: true)
    }

    func nudgeSelectedAudio(samples: Int) -> Bool {
        let sampleRate: Double = {
            if isProMode { return max(1, proSettings.sampleRate) }
            guard let clip = primarySelectedClip,
                  audioIndex(clip.id) != nil,
                  let file = try? AVAudioFile(forReading: clip.url) else { return 48_000 }
            return max(1, file.processingFormat.sampleRate)
        }()
        return nudgeSelectedClips(by: Double(samples) / sampleRate, audioOnly: true)
    }

    func setClipLength(_ length: TimeInterval) {
        beginEdit()
        let ids = selectedClipIDs.isEmpty
            ? Set([selectedClipID].compactMap { $0 })
            : selectedClipIDs
        for id in ids {
            if let i = audioIndex(id) {
                trimOutOn(&audioClips[i], time: audioClips[i].timelineStart + length)
            } else if let i = videoIndex(id) {
                var clip = videoClips[i]
                trimOutOn(&clip, time: clip.timelineStart + length)
                videoClips[i] = clip
            }
        }
        isEditingClip = true
    }

    func snapTime(_ time: TimeInterval, excluding: [TimeInterval] = []) -> TimeInterval {
        guard isSnapEnabled else { return time }
        let threshold = max(0.02, 7 * layoutDuration / max(timelineWidthPoints, 1))
        var candidates: [TimeInterval] = [0, layoutDuration]
        if !isProMode || proSettings.snapToPlayhead {
            candidates.append(currentTime)
        }
        if !isProMode || proSettings.snapToClipEdges {
            candidates += videoClips.flatMap { [$0.timelineStart, $0.timelineEnd] }
            candidates += audioClips.flatMap { [$0.timelineStart, $0.timelineEnd] }
        }
        if isProMode, proSettings.snapToFrameGrid {
            let frame = 1 / max(1, proSettings.frameRate)
            candidates.append((time / frame).rounded() * frame)
        }
        let filtered = candidates.filter { candidate in
            excluding.allSatisfy { abs($0 - candidate) > 0.0005 }
        }
        guard let nearest = filtered.min(by: { abs($0 - time) < abs($1 - time) }) else { return time }
        return abs(nearest - time) <= threshold ? nearest : time
    }

    static let minTimelineZoom: CGFloat = 1
    static let maxTimelineZoom: CGFloat = 50

    var timelineWidthPoints: CGFloat {
        max(timelineViewportWidth, 1) * max(timelineZoom, 1)
    }

    func setTimelineZoom(_ zoom: CGFloat) {
        timelineZoom = min(max(zoom, Self.minTimelineZoom), Self.maxTimelineZoom)
    }

    func zoomIn() {
        setTimelineZoom(timelineZoom * 1.35)
    }

    func zoomOut() {
        setTimelineZoom(timelineZoom / 1.35)
    }

    func zoomToFit(viewportWidth: CGFloat) {
        if viewportWidth > 0 {
            timelineViewportWidth = viewportWidth
        }
        timelineSpan = duration
        timelineZoom = Self.minTimelineZoom
    }

    func splitSelectedAtPlayhead() {
        guard !isLoading, duration > 0 else { return }
        // Freeze the cut time up front. Never re-read currentTime mid-split (periodic
        // observer / seek round-trips would desync left duration from right start).
        let time = currentTime

        func intersects(_ clip: MediaClip) -> Bool { canSplit(clip, at: time) }

        var videoTargets = videoClips.filter { selectedClipIDs.contains($0.id) && intersects($0) }.map(\.id)
        var audioTargets = audioClips.filter { selectedClipIDs.contains($0.id) && intersects($0) }.map(\.id)

        // Fallback: nothing useful selected under playhead → cut every clip the playhead crosses.
        if videoTargets.isEmpty && audioTargets.isEmpty {
            videoTargets = videoClips.filter(intersects).map(\.id)
            audioTargets = audioClips.filter(intersects).map(\.id)
        }
        guard !videoTargets.isEmpty || !audioTargets.isEmpty else { return }

        pushHistory()
        var newSelection: Set<UUID> = []
        var primary: UUID?

        // Split from the end so insertions do not invalidate earlier indices.
        for id in videoTargets.reversed() {
            guard let i = videoIndex(id) else { continue }
            let parts = gaplessSplit(videoClips[i], at: time)
            videoClips[i] = parts.left
            videoClips.insert(parts.right, at: i + 1)
            // Share full-source filmstrip; FilmstripLane windows by inPoint/duration.
            if let frames = filmstrips[parts.left.id] {
                filmstrips[parts.right.id] = frames
            } else {
                scheduleFilmstrip(for: parts.left)
                scheduleFilmstrip(for: parts.right)
            }
            newSelection.insert(parts.left.id)
            newSelection.insert(parts.right.id)
            primary = parts.right.id
        }

        for id in audioTargets.reversed() {
            guard let i = audioIndex(id) else { continue }
            let parts = gaplessSplit(audioClips[i], at: time)
            // Keep full-source peaks; WaveformView windows by inPoint/duration.
            var right = parts.right
            right.waveform = audioClips[i].waveform
            audioClips[i] = parts.left
            audioClips.insert(right, at: i + 1)
            newSelection.insert(parts.left.id)
            newSelection.insert(right.id)
            primary = right.id
        }

        selectedClipIDs = newSelection
        selectedClipID = primary ?? newSelection.first
        if let pid = selectedClipID {
            focusedLane = videoIndex(pid) != nil ? .video : .audio
        }
        rebuild()
    }

    private func canSplit(_ clip: MediaClip, at time: TimeInterval) -> Bool {
        time > clip.timelineStart + 0.08 && time < clip.timelineEnd - 0.08
    }

    /// Logic-style razor: left ends exactly where right begins — no gap, no overlap.
    /// Right timelineStart is derived from left.timelineEnd (not a second read of `time`)
    /// so floating-point `start + (time - start)` cannot drift away from `time`.
    private func gaplessSplit(_ original: MediaClip, at time: TimeInterval) -> (left: MediaClip, right: MediaClip) {
        let cut = min(max(time, original.timelineStart + Self.minimumClipDuration),
                      original.timelineEnd - Self.minimumClipDuration)
        let leftDuration = cut - original.timelineStart
        // Use residual duration so left+right always equals original.duration exactly.
        let rightDuration = original.duration - leftDuration

        var left = original
        left.duration = leftDuration
        // Hard cut at the razor: no fade across the join.
        left.fadeOut = 0
        left.clampFades()

        var right = original
        right.id = UUID()
        // Abut exactly — derive start from left end, never from a separate `time` sample.
        right.timelineStart = left.timelineStart + left.duration
        right.inPoint = original.inPoint + leftDuration
        right.duration = rightDuration
        right.fadeIn = 0
        right.fadeOut = min(right.fadeOut, max(0, right.duration / 2))
        right.clampFades()
        return (left, right)
    }

    func duplicateSelectedClip() {
        guard !isLoading else { return }
        if let i = audioIndex(selectedClipID ?? UUID()) {
            pushHistory()
            var copy = audioClips[i]
            copy.id = UUID()
            copy.timelineStart = audioClips[i].timelineEnd
            copy.waveform = audioClips[i].waveform
            audioClips.insert(copy, at: i + 1)
            selectedClipID = copy.id
            selectedClipIDs = [copy.id]
            if audioLayoutMode == .playlist {
                normalizeAudioPlaylist(ripple: true)
                applyPlaylistCrossfades()
            }
            rebuild()
        } else if let i = videoIndex(selectedClipID ?? UUID()) {
            pushHistory()
            var copy = videoClips[i]
            let originalID = videoClips[i].id
            copy.id = UUID()
            copy.timelineStart = videoClips[i].timelineEnd
            videoClips.insert(copy, at: i + 1)
            if let frames = filmstrips[originalID] {
                filmstrips[copy.id] = frames
            } else {
                scheduleFilmstrip(for: copy)
            }
            selectedClipID = copy.id
            selectedClipIDs = [copy.id]
            rebuild()
        }
    }

    func selectNextClip() {
        navigateClip(1)
    }

    func selectPreviousClip() {
        navigateClip(-1)
    }

    private func navigateClip(_ direction: Int) {
        let clips: [MediaClip] = (focusedLane == .audio ? audioClips : videoClips)
            .sorted { $0.timelineStart < $1.timelineStart }
        guard !clips.isEmpty else { return }
        let index = clips.firstIndex { $0.id == selectedClipID } ?? 0
        let next = min(max(index + direction, 0), clips.count - 1)
        let id = clips[next].id
        selectedClipID = id
        selectedClipIDs = [id]
        seek(to: clips[next].timelineStart)
    }

    /// Seek to previous/next music clip boundary by sorted timelineStart.
    func seekToPreviousMusicClip() {
        seekToMusicClip(direction: -1)
    }

    func seekToNextMusicClip() {
        seekToMusicClip(direction: 1)
    }

    private func seekToMusicClip(direction: Int) {
        let clips = audioClips.sorted { $0.timelineStart < $1.timelineStart }
        guard !clips.isEmpty else { return }
        if direction > 0 {
            if let next = clips.first(where: { $0.timelineStart > currentTime + 0.04 }) {
                seek(to: next.timelineStart)
                selectAudioClip(next.id)
            } else if let last = clips.last {
                seek(to: last.timelineStart)
                selectAudioClip(last.id)
            }
        } else {
            if let prev = clips.last(where: { $0.timelineStart < currentTime - 0.04 }) {
                seek(to: prev.timelineStart)
                selectAudioClip(prev.id)
            } else if let first = clips.first {
                seek(to: first.timelineStart)
                selectAudioClip(first.id)
            }
        }
    }

    // MARK: - Loop region

    func markLoopIn() {
        loopIn = max(0, currentTime)
        if loopOut <= loopIn {
            loopOut = max(loopIn + 0.5, duration)
        }
    }

    func markLoopOut() {
        loopOut = max(currentTime, loopIn + 0.12)
    }

    func loopSelectedClips() {
        let ids = selectedClipIDs
        let clips = (videoClips + audioClips).filter { ids.contains($0.id) }
        guard !clips.isEmpty else { return }
        loopIn = clips.map(\.timelineStart).min() ?? 0
        loopOut = clips.map(\.timelineEnd).max() ?? duration
        loopEnabled = true
    }

    func toggleLoop() {
        if !loopEnabled, loopOut <= loopIn {
            loopIn = 0
            loopOut = max(duration, 0.5)
        }
        loopEnabled.toggle()
    }

    private func effectiveLoopOut() -> TimeInterval {
        loopOut > loopIn ? loopOut : duration
    }


    func commitEdit() {
        // The pre-edit state was already pushed by beginEdit() when the drag
        // or slider grab started; pushing again here made the first undo a no-op.
        isEditingClip = false
        if audioLayoutMode == .playlist {
            magneticSnapPlaylistOnRelease()
            normalizeAudioPlaylist(ripple: true)
            applyPlaylistCrossfades()
        }
        growTimelineSpan()
        rebuild()
    }

    private func rebuild() {
        scheduleRebuild()
        scheduleAutosave()
    }

    /// The single serialization point for composition rebuilds: always cancels the
    /// in-flight task and takes over `rebuildTask`, so two rebuilds can never mutate
    /// the shared track-ID maps at once (HIGH-1).
    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildGeneration += 1
        rebuildTask = Task { await rebuildComposition() }
    }

    /// Schedules a rebuild and waits until no rebuild is pending — for async
    /// mutators (add/import/template) that must not return a half-built timeline.
    private func rebuildAndWait() async {
        scheduleRebuild()
        await waitForRebuildsToSettle()
    }

    func scheduleRebuildPublic() { scheduleRebuild() }

    /// Awaits the pending composition rebuild (if any) until no newer one has been
    /// queued in the meantime. Export snapshots must pair the player item's asset
    /// with fade instructions derived from the same model state (CRITICAL-1).
    private func waitForRebuildsToSettle() async {
        while true {
            guard let task = rebuildTask else { return }
            let generation = rebuildGeneration
            await task.value
            if generation == rebuildGeneration { return }
        }
    }

    var duckingGain: Float { isDuckingMusic ? 0.22 : 1.0 }

    // Fade setters are called continuously during a drag; beginEdit() pushes
    // history once at drag start so undo returns to the pre-drag state.
    // Multi-select: writes apply to every clip in `selectedClipIDs` (video + audio).
    func setSelectedFadeIn(_ time: TimeInterval) {
        beginEdit()
        let t = max(0, time)
        let ids = selectedClipIDs.isEmpty ? Set([selectedClipID].compactMap { $0 }) : selectedClipIDs
        for id in ids {
            if let i = videoIndex(id) {
                videoClips[i].fadeIn = min(t, max(0, videoClips[i].duration - videoClips[i].fadeOut))
                videoClips[i].clampFades()
            } else if let i = audioIndex(id) {
                audioClips[i].fadeIn = min(t, max(0, audioClips[i].duration - audioClips[i].fadeOut))
                audioClips[i].clampFades()
            }
        }
        applyFades(refreshingVideo: ids.contains { videoIndex($0) != nil })
        isEditingClip = true
    }

    func setSelectedFadeOut(_ time: TimeInterval) {
        beginEdit()
        let t = max(0, time)
        let ids = selectedClipIDs.isEmpty ? Set([selectedClipID].compactMap { $0 }) : selectedClipIDs
        for id in ids {
            if let i = videoIndex(id) {
                videoClips[i].fadeOut = min(t, max(0, videoClips[i].duration - videoClips[i].fadeIn))
                videoClips[i].clampFades()
            } else if let i = audioIndex(id) {
                audioClips[i].fadeOut = min(t, max(0, audioClips[i].duration - audioClips[i].fadeIn))
                audioClips[i].clampFades()
            }
        }
        applyFades(refreshingVideo: ids.contains { videoIndex($0) != nil })
        isEditingClip = true
    }

    func setVideoFadeIn(_ time: TimeInterval) { setSelectedFadeIn(time) }
    func setVideoFadeOut(_ time: TimeInterval) { setSelectedFadeOut(time) }
    func setAudioFadeIn(_ time: TimeInterval) { setSelectedFadeIn(time) }
    func setAudioFadeOut(_ time: TimeInterval) { setSelectedFadeOut(time) }
    func setAudioVolume(_ volume: Float) {
        musicVolume = min(max(0, volume), 1)
        if let i = tracks.firstIndex(where: { $0.kind == .audio }) {
            tracks[i].volume = musicVolume
        }
        applyFades(refreshingVideo: false)
        scheduleAutosave()
    }

    func setVideoVolume(_ volume: Float) {
        videoVolume = min(max(0, volume), 1)
        if let i = tracks.firstIndex(where: { $0.kind == .video }) {
            tracks[i].volume = videoVolume
        }
        applyFades(refreshingVideo: false)
        scheduleAutosave()
    }

    func setSelectedClipGain(_ gain: Float) {
        beginEdit()
        let g = min(max(0, gain), 1)
        let ids = selectedClipIDs.isEmpty ? Set([selectedClipID].compactMap { $0 }) : selectedClipIDs
        for id in ids {
            if let i = videoIndex(id) {
                videoClips[i].gain = g
            } else if let i = audioIndex(id) {
                audioClips[i].gain = g
            }
        }
        applyFades(refreshingVideo: false)
        isEditingClip = true
    }

    var selectedClipGain: Float {
        primarySelectedClip?.gain ?? 1
    }

    var selectedClipTransform: ClipTransform {
        selectedVideo?.transform ?? .identity
    }

    var selectedClipPan: Float {
        selectedAudio?.pan ?? 0
    }

    var selectedTransitionIn: ClipTransition {
        selectedVideo?.transitionIn ?? ClipTransition()
    }

    var selectedTransitionOut: ClipTransition {
        selectedVideo?.transitionOut ?? ClipTransition()
    }

    var selectedKeyframeCount: Int {
        selectedVideo?.transformKeyframes.count ?? 0
    }

    func setSelectedTransform(_ update: (inout ClipTransform) -> Void) {
        guard isProMode else { return }
        beginEdit()
        let ids = selectedClipIDs.isEmpty ? Set([selectedClipID].compactMap { $0 }) : selectedClipIDs
        for id in ids {
            guard let i = videoIndex(id) else { continue }
            update(&videoClips[i].transform)
            videoClips[i].transform.sanitize()
        }
        applyFades()
        scheduleAutosave()
        isEditingClip = true
    }

    func setSelectedTransition(_ transition: ClipTransition, incoming: Bool) {
        guard isProMode else { return }
        beginEdit()
        let ids = selectedClipIDs.isEmpty ? Set([selectedClipID].compactMap { $0 }) : selectedClipIDs
        for id in ids {
            guard let i = videoIndex(id) else { continue }
            var value = transition
            value.sanitize(clipDuration: videoClips[i].duration)
            if incoming {
                videoClips[i].transitionIn = value
            } else {
                videoClips[i].transitionOut = value
            }
        }
        applyFades()
        scheduleAutosave()
        isEditingClip = true
    }

    func addTransformKeyframeAtPlayhead() {
        guard isProMode else { return }
        pushHistory()
        let ids = selectedClipIDs.isEmpty ? Set([selectedClipID].compactMap { $0 }) : selectedClipIDs
        for id in ids {
            guard let i = videoIndex(id) else { continue }
            let localTime = min(max(0, currentTime - videoClips[i].timelineStart), videoClips[i].duration)
            let keyframe = ClipTransformKeyframe(time: localTime, transform: videoClips[i].transform)
            if let existing = videoClips[i].transformKeyframes.firstIndex(where: { abs($0.time - localTime) < 0.5 / max(proSettings.frameRate, 1) }) {
                videoClips[i].transformKeyframes[existing] = keyframe
            } else {
                videoClips[i].transformKeyframes.append(keyframe)
                videoClips[i].transformKeyframes.sort { $0.time < $1.time }
            }
        }
        rebuild()
    }

    func clearSelectedTransformKeyframes() {
        guard isProMode else { return }
        pushHistory()
        let ids = selectedClipIDs.isEmpty ? Set([selectedClipID].compactMap { $0 }) : selectedClipIDs
        for id in ids {
            guard let i = videoIndex(id) else { continue }
            videoClips[i].transformKeyframes = []
        }
        rebuild()
    }

    func setSelectedPan(_ pan: Float) {
        guard isProMode else { return }
        beginEdit()
        let value = min(max(pan, -1), 1)
        let ids = selectedClipIDs.isEmpty ? Set([selectedClipID].compactMap { $0 }) : selectedClipIDs
        for id in ids {
            guard let i = audioIndex(id) else { continue }
            audioClips[i].pan = value
        }
        applyFades(refreshingVideo: false)
        scheduleAutosave()
        isEditingClip = true
    }

    func normalizeSelectedAudio(targetPeak: Float = 0.89) {
        guard isProMode else { return }
        pushHistory()
        let ids = selectedClipIDs.isEmpty ? Set([selectedClipID].compactMap { $0 }) : selectedClipIDs
        var normalizedAny = false
        for id in ids {
            guard let i = audioIndex(id), let peak = audioClips[i].waveform.max(), peak > 0.000_1 else { continue }
            audioClips[i].gain = ProFeatureMath.normalizedGain(
                current: audioClips[i].gain,
                peak: peak,
                targetPeak: targetPeak
            )
            audioClips[i].isNormalized = true
            normalizedAny = true
        }
        status = normalizedAny ? "Normalized selected audio" : "Waveform analysis is still loading"
        applyFades(refreshingVideo: false)
        rebuild()
    }

    var selectedAudioMeter: (left: Float, right: Float) {
        guard isProMode, let clip = selectedAudio, !clip.waveform.isEmpty else { return (0, 0) }
        let local = min(max(0, currentTime - clip.timelineStart), max(clip.duration, 0.000_1))
        let sourceTime = clip.inPoint + local
        let ratio = min(max(sourceTime / max(clip.sourceDuration, 0.000_1), 0), 0.999_999)
        let index = min(clip.waveform.count - 1, max(0, Int(ratio * Double(clip.waveform.count))))
        let level = min(max(clip.waveform[index] * clip.gain, 0), 1)
        let pan = ProFeatureMath.equalPowerPan(clip.pan)
        return (level * pan.left, level * pan.right)
    }

    func alignSelectedClips(_ alignment: ClipAlignment) {
        guard isProMode else { return }
        let ids = selectedClipIDs
        let selected = (videoClips + audioClips).filter { ids.contains($0.id) }
        guard selected.count > 1 else { return }
        pushHistory()
        switch alignment {
        case .starts:
            let target = selected.map(\.timelineStart).min() ?? 0
            setSelectedStarts(ids, target: target)
        case .ends:
            let target = selected.map(\.timelineEnd).max() ?? 0
            for id in ids {
                if let i = videoIndex(id) {
                    videoClips[i].timelineStart = max(0, target - videoClips[i].duration)
                } else if let i = audioIndex(id) {
                    audioClips[i].timelineStart = max(0, target - audioClips[i].duration)
                }
            }
        case .playhead:
            setSelectedStarts(ids, target: currentTime)
        case .distribute:
            let ordered = selected.sorted { $0.timelineStart < $1.timelineStart }
            guard let first = ordered.first, let last = ordered.last else { break }
            let totalDuration = ordered.reduce(0) { $0 + $1.duration }
            let available = max(0, last.timelineEnd - first.timelineStart - totalDuration)
            let gap = available / Double(max(1, ordered.count - 1))
            var cursor = first.timelineStart
            for clip in ordered {
                if let i = videoIndex(clip.id) {
                    videoClips[i].timelineStart = cursor
                } else if let i = audioIndex(clip.id) {
                    audioClips[i].timelineStart = cursor
                }
                cursor += clip.duration + gap
            }
        }
        growTimelineSpan()
        rebuild()
    }

    private func setSelectedStarts(_ ids: Set<UUID>, target: TimeInterval) {
        for id in ids {
            if let i = videoIndex(id) {
                videoClips[i].timelineStart = max(0, target)
            } else if let i = audioIndex(id) {
                audioClips[i].timelineStart = max(0, target)
            }
        }
    }

    /// Inspector display values — primary clip; writes go to all selected.
    var inspectorFadeIn: TimeInterval { primarySelectedClip?.fadeIn ?? 0 }
    var inspectorFadeOut: TimeInterval { primarySelectedClip?.fadeOut ?? 0 }
    var inspectorLength: TimeInterval { primarySelectedClip?.duration ?? 0 }
    var inspectorMaxFadeIn: TimeInterval {
        let clips = allSelectedClips
        guard !clips.isEmpty else { return max(0, (primarySelectedClip?.duration ?? 0) - (primarySelectedClip?.fadeOut ?? 0)) }
        return clips.map { max(0, $0.duration - $0.fadeOut) }.min() ?? 0
    }
    var inspectorMaxFadeOut: TimeInterval {
        let clips = allSelectedClips
        guard !clips.isEmpty else { return max(0, (primarySelectedClip?.duration ?? 0) - (primarySelectedClip?.fadeIn ?? 0)) }
        return clips.map { max(0, $0.duration - $0.fadeIn) }.min() ?? 0
    }
    var inspectorMaxLength: TimeInterval {
        guard let clip = primarySelectedClip else { return 0.2 }
        let mediaMax = max(0.2, clip.sourceDuration - clip.inPoint)
        guard StillImage.isStill(clip.url) else { return mediaMax }
        // A still's source is a long hold, not a file length. Keep the slider
        // near the current hold; it grows as the picture is extended. Trim
        // handles still reach `StillImage.maximumDuration`.
        return min(mediaMax, max(60, clip.duration * 1.5))
    }
    var inspectorValuesAreMixed: Bool {
        let clips = allSelectedClips
        guard clips.count > 1 else { return false }
        let fi = clips[0].fadeIn
        let fo = clips[0].fadeOut
        let dur = clips[0].duration
        let g = clips[0].gain
        return clips.contains { abs($0.fadeIn - fi) > 0.0005 || abs($0.fadeOut - fo) > 0.0005 || abs($0.duration - dur) > 0.0005 || abs($0.gain - g) > 0.0005 }
    }

    func setDuckingMusic(_ enabled: Bool) {
        isDuckingMusic = enabled
        applyFades(refreshingVideo: false)
        scheduleAutosave()
    }

    var videoFadeIn: TimeInterval { selectedVideo?.fadeIn ?? 0 }
    var videoFadeOut: TimeInterval { selectedVideo?.fadeOut ?? 0 }
    var audioFadeIn: TimeInterval { selectedAudio?.fadeIn ?? 0 }
    var audioFadeOut: TimeInterval { selectedAudio?.fadeOut ?? 0 }
    /// `refreshingVideo` is false for mix-only edits (gain, lane volume, pan, ducking,
    /// audio fades). Those must not replace `videoComposition` while playback is running:
    /// swapping the composition object drops the preview. Video fades and transforms
    /// still rebuild it, and the replacement covers the whole item so the picture stays.
    func applyFades(refreshingVideo: Bool = true) {
        guard let item = player.currentItem else { return }
        item.audioMix = makeAudioMix()
        if refreshingVideo {
            item.videoComposition = makeVideoComposition()
        }
    }

    func presentExportSheet() {
        guard hasVideo, !isExporting else { return }
        isExportSheetPresented = true
    }

    func beginExport(with settings: ExportSettings) {
        guard !isExporting, player.currentItem != nil else { return }
        var settings = settings
        settings.sanitize()

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = settings.mode == .animatedGIF ? "Export Animated GIF" : "Export Video"
        panel.nameFieldStringValue = "\(settings.fileBaseName).\(settings.pathExtension)"
        panel.allowedContentTypes = [settings.contentType]
        panel.allowsOtherFileTypes = false
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let finalURL: URL = {
            let ext = settings.pathExtension
            if dest.pathExtension.lowercased() == ext { return dest }
            return dest.deletingPathExtension().appendingPathExtension(ext)
        }()

        // Claim the export slot now; if a rebuild is mid-flight, wait for it before
        // snapshotting so the item's asset and the fade instructions come from the
        // same composition (CRITICAL-1).
        isExporting = true
        exportProgress = 0
        errorMessage = nil
        exportIntent += 1
        let intent = exportIntent
        Task { @MainActor in
            await self.waitForRebuildsToSettle()
            guard self.isExporting, self.exportIntent == intent else { return }
            self.startExportSnapshot(settings: settings, destination: finalURL)
        }
    }

    func cancelExport() {
        exportIntent += 1 // abort any snapshot deferred behind a pending rebuild
        activeExportSession?.cancelExport()
        exportCancelFlag?.cancel()
        exportCancelFlag = nil
        exportWriterTask?.cancel()
        exportWriterTask = nil
        stopExportProgressTimer()
        activeExportSession = nil
        if let dest = exportDestinationURL {
            try? FileManager.default.removeItem(at: dest)
        }
        removeExportTemporaryFiles()
        exportDestinationURL = nil
        if isExporting {
            isExporting = false
            exportProgress = 0
            status = "Export cancelled"
        }
    }

    private var sanitizedExportBaseName: String {
        let raw = clipName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "StudioLane" : cleaned
    }

    private func startGIFExport(
        asset: AVAsset,
        settings: ExportSettings,
        destination: URL,
        videoComposition: AVVideoComposition?
    ) {
        nonisolated(unsafe) let unsafeAsset = asset
        let unsafeVideoComposition = videoComposition
        let cancelFlag = ExportCancelFlag()
        exportCancelFlag = cancelFlag
        let intent = exportIntent
        exportWriterTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await EditorModel.performGIFExport(
                    asset: unsafeAsset,
                    destination: destination,
                    targetSize: settings.targetSize(source: self.exportSourceSize),
                    fps: settings.gifFrameRate.value,
                    compressionQuality: settings.gifPaletteQuality.compressionQuality,
                    videoComposition: unsafeVideoComposition,
                    byteLimit: 15_000_000,
                    isCancelled: { cancelFlag.value },
                    onProgress: { [weak self] value in
                        Task { @MainActor in self?.exportProgress = value }
                    }
                )
                guard self.exportIntent == intent else { return }
                self.finishExport(success: true, destination: destination, message: nil)
            } catch is CancellationError {
                guard self.exportIntent == intent else { return }
                self.finishExport(success: false, destination: destination, message: "Export cancelled", reveal: false)
            } catch {
                guard self.exportIntent == intent else { return }
                self.finishExport(
                    success: false,
                    destination: destination,
                    message: "GIF export failed: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Encodes an infinitely looping GIF and retries progressively smaller/fewer
    /// frames when necessary to stay under X's 15 MB upload limit.
    nonisolated static func performGIFExport(
        asset: AVAsset,
        destination: URL,
        targetSize: CGSize,
        fps: Double,
        compressionQuality: Double,
        videoComposition: AVVideoComposition?,
        byteLimit: Int,
        isCancelled: @escaping @Sendable () -> Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let duration = max(0.05, try await asset.load(.duration).seconds)
        let requestedFPS = min(max(fps, 1), 30)
        let attempts: [(scale: CGFloat, fps: Double)] = [
            (1, requestedFPS),
            (0.84, min(requestedFPS, 12)),
            (0.68, min(requestedFPS, 10)),
            (0.52, min(requestedFPS, 8))
        ]

        for (attemptIndex, attempt) in attempts.enumerated() {
            if isCancelled() { throw CancellationError() }
            try? FileManager.default.removeItem(at: destination)

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.videoComposition = videoComposition
            generator.maximumSize = CGSize(
                width: max(2, targetSize.width * attempt.scale),
                height: max(2, targetSize.height * attempt.scale)
            )
            generator.requestedTimeToleranceBefore = CMTime(
                seconds: 0.5 / attempt.fps,
                preferredTimescale: 600
            )
            generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore

            let frameCount = max(1, Int(ceil(duration * attempt.fps)))
            guard let gif = CGImageDestinationCreateWithURL(
                destination as CFURL,
                UTType.gif.identifier as CFString,
                frameCount,
                nil
            ) else {
                throw NSError(
                    domain: "StudioAudioLane.GIF",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not create the GIF destination."]
                )
            }
            CGImageDestinationSetProperties(gif, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFLoopCount: 0
                ]
            ] as CFDictionary)

            let delay = 1 / attempt.fps
            let frameProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                    kCGImagePropertyGIFDelayTime: delay
                ],
                kCGImageDestinationLossyCompressionQuality: min(max(compressionQuality, 0), 1)
            ]
            for frame in 0..<frameCount {
                if isCancelled() { throw CancellationError() }
                let seconds = min(
                    max(0, duration - 1.0 / 600.0),
                    (Double(frame) + 0.5) / attempt.fps
                )
                let (image, _) = try await generator.image(at: CMTime(
                    seconds: seconds,
                    preferredTimescale: 600
                ))
                CGImageDestinationAddImage(gif, image, frameProperties as CFDictionary)
                let attemptBase = Double(attemptIndex) / Double(attempts.count)
                let attemptSpan = 1 / Double(attempts.count)
                onProgress(min(0.99, attemptBase + attemptSpan * Double(frame + 1) / Double(frameCount)))
            }
            guard CGImageDestinationFinalize(gif) else {
                throw NSError(
                    domain: "StudioAudioLane.GIF",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "ImageIO could not finalize the GIF."]
                )
            }

            let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
            if bytes <= byteLimit {
                onProgress(1)
                return
            }
        }

        let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        try? FileManager.default.removeItem(at: destination)
        throw NSError(
            domain: "StudioAudioLane.GIF",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey:
                    String(format: "The smallest retry was %.1f MB. Shorten the timeline or choose 480 px / 8 fps.", Double(bytes) / 1_000_000)
            ]
        )
    }

    private func startXLoopExport(
        asset: AVAsset,
        settings: ExportSettings,
        destination: URL,
        videoComposition: AVVideoComposition?,
        audioMix: AVAudioMix?
    ) {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioLane-XLoop-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: temporary)
        exportTemporaryURLs.insert(temporary)

        let targetSize = settings.targetSize(source: exportSourceSize)
        let videoBitRate = settings.quality.approximateBitRate(
            pixelCount: targetSize.width * targetSize.height
        )
        nonisolated(unsafe) let unsafeAsset = asset
        let unsafeVideoComposition = videoComposition
        nonisolated(unsafe) let unsafeAudioMix = audioMix
        let cancelFlag = ExportCancelFlag()
        exportCancelFlag = cancelFlag
        let intent = exportIntent
        exportWriterTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await EditorModel.performWriterExport(
                    asset: unsafeAsset,
                    destination: temporary,
                    fileType: .mp4,
                    codec: .h264,
                    targetSize: targetSize,
                    fps: 30,
                    videoBitRate: videoBitRate,
                    audioBitRate: 128_000,
                    sampleRate: 48_000,
                    videoComposition: unsafeVideoComposition,
                    audioMix: unsafeAudioMix,
                    isCancelled: { cancelFlag.value },
                    onProgress: { [weak self] value in
                        Task { @MainActor in self?.exportProgress = value * 0.8 }
                    }
                )
                guard self.exportIntent == intent else { return }
                if settings.xLoopCount == 1 {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    self.exportTemporaryURLs.remove(temporary)
                    self.finishExport(success: true, destination: destination, message: nil)
                } else {
                    await self.finishRepeatedXLoop(
                        flattenedURL: temporary,
                        count: settings.xLoopCount,
                        destination: destination,
                        intent: intent
                    )
                }
            } catch is CancellationError {
                guard self.exportIntent == intent else { return }
                self.finishExport(
                    success: false,
                    destination: destination,
                    message: "Export cancelled",
                    reveal: false
                )
            } catch {
                guard self.exportIntent == intent else { return }
                self.finishExport(
                    success: false,
                    destination: destination,
                    message: "X loop encoding failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func finishRepeatedXLoop(
        flattenedURL: URL,
        count: Int,
        destination: URL,
        intent: Int
    ) async {
        do {
            let flattened = AVURLAsset(url: flattenedURL)
            let repeated = try await Self.makeRepeatedComposition(from: flattened, count: count)

            guard exportIntent == intent, isExporting else { return }
            try? FileManager.default.removeItem(at: destination)
            guard let exporter = AVAssetExportSession(
                asset: repeated,
                presetName: AVAssetExportPresetPassthrough
            ) else {
                throw NSError(
                    domain: "StudioAudioLane.XLoop",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not create the repeated MP4 export."]
                )
            }
            exporter.outputURL = destination
            exporter.outputFileType = .mp4
            exporter.shouldOptimizeForNetworkUse = true
            activeExportSession = exporter
            startExportProgressTimer(base: 0.8, span: 0.2)
            let exporterID = ObjectIdentifier(exporter)
            exporter.exportAsynchronously { [weak self] in
                let result = exporter.status
                let message = exporter.error?.localizedDescription
                Task { @MainActor in
                    guard let self,
                          self.exportIntent == intent,
                          self.activeExportSession.map(ObjectIdentifier.init) == exporterID else { return }
                    self.activeExportSession = nil
                    if result == .completed {
                        self.finishExport(success: true, destination: destination, message: nil)
                    } else {
                        self.finishExport(
                            success: false,
                            destination: destination,
                            message: result == .cancelled ? "Export cancelled" : (message ?? "Could not repeat the X loop"),
                            reveal: result != .cancelled
                        )
                    }
                }
            }
        } catch {
            guard exportIntent == intent else { return }
            finishExport(
                success: false,
                destination: destination,
                message: "Could not repeat X loop: \(error.localizedDescription)"
            )
        }
    }

    static func makeRepeatedComposition(from asset: AVAsset, count: Int) async throws -> AVMutableComposition {
        let repetitions = max(1, min(10, count))
        let sourceDuration = try await asset.load(.duration)
        let sourceRange = CMTimeRange(start: .zero, duration: sourceDuration)
        let repeated = AVMutableComposition()

        for source in try await asset.loadTracks(withMediaType: .video) {
            guard let track = repeated.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: source.trackID
            ) else { continue }
            track.preferredTransform = try await source.load(.preferredTransform)
            for repetition in 0..<repetitions {
                try track.insertTimeRange(
                    sourceRange,
                    of: source,
                    at: CMTimeMultiply(sourceDuration, multiplier: Int32(repetition))
                )
            }
        }
        for source in try await asset.loadTracks(withMediaType: .audio) {
            guard let track = repeated.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: source.trackID
            ) else { continue }
            for repetition in 0..<repetitions {
                try track.insertTimeRange(
                    sourceRange,
                    of: source,
                    at: CMTimeMultiply(sourceDuration, multiplier: Int32(repetition))
                )
            }
        }
        return repeated
    }

    private func startSessionExport(
        asset: AVAsset,
        settings: ExportSettings,
        destination: URL,
        videoComposition: AVVideoComposition?,
        audioMix: AVAudioMix?
    ) {
        let preset = settings.exportPresetName()
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
            finishExport(success: false, destination: destination, message: "Export preset unavailable (\(preset))")
            return
        }
        let supported = exporter.supportedFileTypes
        var fileType = settings.container.fileType
        var fallbackExtension: String?
        if !supported.contains(fileType) {
            if supported.contains(.mov) {
                fileType = .mov
                fallbackExtension = "mov"
            } else if let first = supported.first {
                fileType = first
                fallbackExtension = first == AVFileType.mov ? "mov" : first == AVFileType.mp4 ? "mp4" : nil
            } else {
                finishExport(success: false, destination: destination, message: "No supported file types for preset \(preset)")
                return
            }
        }
        let finalDestination: URL
        if let fallbackExtension {
            finalDestination = destination.deletingPathExtension().appendingPathExtension(fallbackExtension)
            try? FileManager.default.removeItem(at: finalDestination)
        } else {
            finalDestination = destination
        }
        exporter.outputURL = finalDestination
        exporter.outputFileType = fileType
        exporter.audioMix = audioMix
        exporter.videoComposition = videoComposition
        exporter.shouldOptimizeForNetworkUse = settings.codec != .proRes422 && settings.codec != .proRes4444
        activeExportSession = exporter
        startExportProgressTimer()
        status = "Exporting… (session \(preset))"
        exporter.exportAsynchronously { [weak self] in
            let status = exporter.status
            let message = exporter.error?.localizedDescription
            let exporterID = ObjectIdentifier(exporter)
            Task { @MainActor in
                guard let self else { return }
                // A cancelled or superseded exporter must not nil out the current
                // export's session or stop its progress timer (HIGH-2).
                guard self.activeExportSession.map(ObjectIdentifier.init) == exporterID else { return }
                self.activeExportSession = nil
                switch status {
                case .completed:
                    self.finishExport(success: true, destination: finalDestination, message: nil)
                case .cancelled:
                    self.finishExport(success: false, destination: finalDestination, message: "Export cancelled", reveal: false)
                default:
                    let detail = message ?? "Export failed (status \(status.rawValue))"
                    self.finishExport(success: false, destination: finalDestination, message: detail)
                }
            }
        }
    }

    private func startWriterExport(
        asset: AVAsset,
        settings: ExportSettings,
        destination: URL,
        videoComposition: AVVideoComposition?,
        audioMix: AVAudioMix?
    ) {
        let sourceSize = exportSourceSize
        let targetSize = settings.targetSize(source: sourceSize)
        let fps = settings.frameRate.seconds.map { 1.0 / $0 } ?? exportSourceFPS
        let videoBitRate = settings.videoBitRate(pixelCount: targetSize.width * targetSize.height)
        let audioBitRate = settings.audioBitrate.bitsPerSecond ?? 192_000
        let sampleRate = isProMode ? proSettings.sampleRate : 48_000
        let codec = settings.codec
        let fileType = settings.container.fileType

        // AVFoundation objects are not Sendable; pin them for off-main writer work.
        nonisolated(unsafe) let unsafeAsset = asset
        let unsafeVideoComposition = videoComposition
        nonisolated(unsafe) let unsafeAudioMix = audioMix

        let onProgress: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in
                self?.exportProgress = value
            }
        }

        let cancelFlag = ExportCancelFlag()
        exportCancelFlag = cancelFlag
        let intent = exportIntent
        exportWriterTask = Task { [weak self] in
            guard let self else { return }
            do {
                // nonisolated static: requestMediaDataWhenReady closures must NOT inherit @MainActor
                // (that isolation assert was the EXC_BREAKPOINT crash).
                try await EditorModel.performWriterExport(
                    asset: unsafeAsset,
                    destination: destination,
                    fileType: fileType,
                    codec: codec,
                    targetSize: targetSize,
                    fps: fps,
                    videoBitRate: videoBitRate,
                    audioBitRate: audioBitRate,
                    sampleRate: sampleRate,
                    videoComposition: unsafeVideoComposition,
                    audioMix: unsafeAudioMix,
                    isCancelled: { cancelFlag.value },
                    onProgress: onProgress
                )
                // A cancelled/superseded export must not report success for a
                // truncated file or stomp the next export's state (HIGH-2).
                guard self.exportIntent == intent else { return }
                self.finishExport(success: true, destination: destination, message: nil)
            } catch is CancellationError {
                guard self.exportIntent == intent else { return }
                self.finishExport(success: false, destination: destination, message: "Export cancelled", reveal: false)
            } catch {
                guard self.exportIntent == intent else { return }
                self.finishExport(
                    success: false,
                    destination: destination,
                    message: "Writer export failed: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Nonisolated writer pipeline — must not touch MainActor-isolated EditorModel state.
    nonisolated private static func performWriterExport(
        asset: AVAsset,
        destination: URL,
        fileType: AVFileType,
        codec: ExportSettings.Codec,
        targetSize: CGSize,
        fps: Double,
        videoBitRate: Int,
        audioBitRate: Int,
        sampleRate: Double,
        videoComposition: AVVideoComposition?,
        audioMix: AVAudioMix?,
        isCancelled: @escaping @Sendable () -> Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        nonisolated(unsafe) let reader = try AVAssetReader(asset: asset)
        nonisolated(unsafe) let writer = try AVAssetWriter(outputURL: destination, fileType: fileType)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let videoTrack = videoTracks.first else {
            throw NSError(domain: "StudioAudioLane", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track to export"])
        }

        let videoCodec: AVVideoCodecType = {
            switch codec {
            case .hevc: return .hevc
            case .h264: return .h264
            case .proRes422: return .proRes422
            case .proRes4444: return .proRes4444
            }
        }()

        // H.264/HEVC encoders require even dimensions.
        let outW = max(2, Int(targetSize.width.rounded()) & ~1)
        let outH = max(2, Int(targetSize.height.rounded()) & ~1)

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: videoCodec,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH
        ]
        if codec == .h264 || codec == .hevc {
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: videoBitRate,
                AVVideoExpectedSourceFrameRateKey: max(1, Int(fps.rounded()))
            ]
        }

        nonisolated(unsafe) let writerVideo = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerVideo.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerVideo) else {
            throw NSError(domain: "StudioAudioLane", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add video writer input"])
        }
        writer.add(writerVideo)

        let pixelSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        nonisolated(unsafe) let readerVideo: AVAssetReaderOutput
        if let videoComposition {
            let composed = AVAssetReaderVideoCompositionOutput(
                videoTracks: videoTracks,
                videoSettings: pixelSettings
            )
            composed.alwaysCopiesSampleData = false
            composed.videoComposition = videoComposition
            readerVideo = composed
        } else {
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: pixelSettings)
            output.alwaysCopiesSampleData = false
            readerVideo = output
        }
        guard reader.canAdd(readerVideo) else {
            throw NSError(domain: "StudioAudioLane", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot add video reader output"])
        }
        reader.add(readerVideo)

        // AAC writer inputs need uncompressed PCM samples.
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: sampleRate
        ]

        var writerAudio: AVAssetWriterInput?
        var readerAudio: AVAssetReaderOutput?
        if let audioTrack = audioTracks.first {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: sampleRate,
                AVEncoderBitRateKey: audioBitRate
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                writerAudio = input
                if let audioMix {
                    let mixed = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcmSettings)
                    mixed.alwaysCopiesSampleData = false
                    mixed.audioMix = audioMix
                    if reader.canAdd(mixed) {
                        reader.add(mixed)
                        readerAudio = mixed
                    }
                } else {
                    let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
                    output.alwaysCopiesSampleData = false
                    if reader.canAdd(output) {
                        reader.add(output)
                        readerAudio = output
                    }
                }
            }
        }

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "StudioAudioLane", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to start writing"])
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw reader.error ?? NSError(domain: "StudioAudioLane", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to start reading"])
        }
        writer.startSession(atSourceTime: .zero)

        let durationSeconds = max(0.001, (try await asset.load(.duration)).seconds)

        // Ensure each input's group.leave happens exactly once.
        final class OnceFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func fire() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if done { return false }
                done = true
                return true
            }
            func isFired() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return done
            }
        }

        final class FailureBox: @unchecked Sendable {
            private let lock = NSLock()
            private var message: String?
            func set(_ value: String) {
                lock.lock()
                defer { lock.unlock() }
                if message == nil { message = value }
            }
            func get() -> String? {
                lock.lock()
                defer { lock.unlock() }
                return message
            }
        }

        // Task cancellation must unblock the reader/writer callbacks right away —
        // they run on raw dispatch queues that observe neither task nor flag until
        // the next sample arrives (HIGH-2).
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let group = DispatchGroup()
                let videoDone = OnceFlag()
                let audioDone = OnceFlag()
                let resumeOnce = OnceFlag()
                let failure = FailureBox()
    
                @Sendable func finishInput(_ flag: OnceFlag, input: AVAssetWriterInput?, leave: Bool) {
                    if flag.fire() {
                        input?.markAsFinished()
                        if leave { group.leave() }
                    }
                }
    
                group.enter()
                writerVideo.requestMediaDataWhenReady(on: DispatchQueue(label: "studio.export.video")) {
                    while writerVideo.isReadyForMoreMediaData {
                        if isCancelled() {
                            reader.cancelReading()
                            writer.cancelWriting()
                            finishInput(videoDone, input: writerVideo, leave: true)
                            return
                        }
                        if let sample = readerVideo.copyNextSampleBuffer() {
                            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                            onProgress(min(0.99, max(0, pts / durationSeconds)))
                            if !writerVideo.append(sample) {
                                failure.set(writer.error?.localizedDescription ?? "Video append failed")
                                reader.cancelReading()
                                finishInput(videoDone, input: writerVideo, leave: true)
                                return
                            }
                        } else {
                            if reader.status == .failed {
                                failure.set(reader.error?.localizedDescription ?? "Video read failed")
                            }
                            finishInput(videoDone, input: writerVideo, leave: true)
                            return
                        }
                    }
                }
    
                if let writerAudio, let readerAudio {
                    group.enter()
                    writerAudio.requestMediaDataWhenReady(on: DispatchQueue(label: "studio.export.audio")) {
                        while writerAudio.isReadyForMoreMediaData {
                            if isCancelled() {
                                reader.cancelReading()
                                writer.cancelWriting()
                                finishInput(audioDone, input: writerAudio, leave: true)
                                return
                            }
                            if let sample = readerAudio.copyNextSampleBuffer() {
                                if !writerAudio.append(sample) {
                                    failure.set(writer.error?.localizedDescription ?? "Audio append failed")
                                    reader.cancelReading()
                                    finishInput(audioDone, input: writerAudio, leave: true)
                                    return
                                }
                            } else {
                                if reader.status == .failed {
                                    failure.set(reader.error?.localizedDescription ?? "Audio read failed")
                                }
                                finishInput(audioDone, input: writerAudio, leave: true)
                                return
                            }
                        }
                    }
                }
    
                group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                    guard resumeOnce.fire() else { return }
                    if isCancelled() {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if let message = failure.get() {
                        continuation.resume(
                            throwing: NSError(
                                domain: "StudioAudioLane",
                                code: 8,
                                userInfo: [NSLocalizedDescriptionKey: message]
                            )
                        )
                        return
                    }
                    continuation.resume()
                }

                // If the pipeline dies in a way that never re-invokes a
                // requestMediaDataWhenReady callback, that input's group.leave
                // never happens and the continuation above would hang forever.
                // Poll for cancellation or a terminal reader/writer state and
                // force the outstanding inputs to finish so the group drains.
                func drainIfDead() {
                    guard isCancelled() || writer.status == .cancelled || writer.status == .failed || reader.status == .failed else { return }
                    reader.cancelReading()
                    writer.cancelWriting()
                    finishInput(videoDone, input: writerVideo, leave: true)
                    if let writerAudio { finishInput(audioDone, input: writerAudio, leave: true) }
                }

                let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
                watchdog.schedule(deadline: .now() + 0.05, repeating: 0.05)
                watchdog.setEventHandler { [weak watchdog] in
                    drainIfDead()
                    if videoDone.isFired() && (writerAudio == nil || audioDone.isFired()) {
                        watchdog?.cancel()
                    }
                }
                watchdog.resume()
            }
        } onCancel: {
            reader.cancelReading()
            writer.cancelWriting()
        }

        if isCancelled() {
            writer.cancelWriting()
            throw CancellationError()
        }

        if writer.status == .cancelled || writer.status == .failed {
            throw writer.error ?? NSError(domain: "StudioAudioLane", code: 6, userInfo: [NSLocalizedDescriptionKey: "Export writing failed"])
        }

        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? NSError(domain: "StudioAudioLane", code: 6, userInfo: [NSLocalizedDescriptionKey: "Export writing failed"])
        }
        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "StudioAudioLane", code: 7, userInfo: [NSLocalizedDescriptionKey: "Export reading failed"])
        }
    }

    private func startExportProgressTimer(base: Double = 0, span: Double = 1) {
        stopExportProgressTimer()
        exportProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let progress = Double(self.activeExportSession?.progress ?? 0)
                self.exportProgress = min(0.99, max(0, base + progress * span))
            }
        }
    }

    private func stopExportProgressTimer() {
        exportProgressTimer?.invalidate()
        exportProgressTimer = nil
    }

    private func finishExport(success: Bool, destination: URL, message: String?, reveal: Bool = true) {
        stopExportProgressTimer()
        activeExportSession = nil
        exportWriterTask = nil
        exportCancelFlag = nil
        removeExportTemporaryFiles()
        isExporting = false
        exportDestinationURL = nil

        var ok = success
        var failMessage = message

        if ok {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0
            // A small, flat-color GIF can legitimately be only a few hundred
            // bytes; movie containers need a larger floor to catch truncation.
            let minimumBytes = destination.pathExtension.lowercased() == "gif" ? 32 : 1024
            if bytes < minimumBytes {
                ok = false
                failMessage = "Export produced an empty or truncated file (\(bytes) bytes)"
                try? FileManager.default.removeItem(at: destination)
            }
        } else {
            // Never leave a corrupt partial file claiming success; delete incomplete output.
            try? FileManager.default.removeItem(at: destination)
        }

        exportProgress = ok ? 1 : 0
        if ok {
            let label = "Exported \(destination.lastPathComponent)"
            status = label
            errorMessage = nil
            if reveal {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
            isExportSheetPresented = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if self.status == label { self.status = "" }
            }
        } else {
            status = failMessage ?? "Export failed"
            if failMessage != "Export cancelled" {
                errorMessage = failMessage ?? "Export failed"
            }
        }
    }

    private func removeExportTemporaryFiles() {
        for url in exportTemporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        exportTemporaryURLs.removeAll()
    }

    private func makeExportVideoComposition(settings: ExportSettings) -> AVVideoComposition? {
        guard let track = mix.track(withTrackID: 1), !videoClips.isEmpty else { return nil }
        let sourceSize = exportSourceSize
        let targetSize = settings.targetSize(source: sourceSize)
        let outFrameDuration: CMTime = {
            if settings.mode == .animatedGIF {
                return CMTime(seconds: 1 / settings.gifFrameRate.value, preferredTimescale: 600)
            }
            if let seconds = settings.frameRate.seconds {
                return CMTime(seconds: seconds, preferredTimescale: 600)
            }
            return frameDuration
        }()

        let hasFades = videoClips.contains { $0.fadeIn > 0.01 || $0.fadeOut > 0.01 }
        let hasEffects = hasFades || hasProVideoEffects
        let sizeChanged = abs(targetSize.width - sourceSize.width) > 0.5
            || abs(targetSize.height - sourceSize.height) > 0.5
        let fpsChanged = settings.frameRate != .original || settings.mode == .animatedGIF
        guard hasEffects || sizeChanged || fpsChanged else {
            // Keep any existing preview composition (fade ramps).
            return player.currentItem?.videoComposition
        }

        let composition = AVMutableVideoComposition()
        composition.renderSize = targetSize
        composition.frameDuration = outFrameDuration

        let scale = min(targetSize.width / max(sourceSize.width, 1), targetSize.height / max(sourceSize.height, 1))
        let scaled = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let tx = (targetSize.width - scaled.width) * 0.5
        let ty = (targetSize.height - scaled.height) * 0.5
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)

        var instructions: [AVMutableVideoCompositionInstruction] = []
        let timelineEnd = max(videoClips.map(\.timelineEnd).max() ?? 0.05, 0.05)

        if hasEffects {
            for segment in renderSegments() {
                // Instruction ranges come from the *actual* on-track segment (same rule as
                // preview), so export can't diverge from the preview or hand AVFoundation
                // overlapping instructions when clips overlap on the single composition track.
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(
                    start: CMTime(seconds: segment.at, preferredTimescale: 600),
                    duration: CMTime(seconds: segment.duration, preferredTimescale: 600)
                )
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                configureVideoLayer(
                    layer,
                    segment: segment,
                    canvasSize: targetSize,
                    baseTransform: sizeChanged ? transform : .identity
                )
                instruction.layerInstructions = [layer]
                instructions.append(instruction)
            }
        } else {
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: timelineEnd, preferredTimescale: 600)
            )
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            if sizeChanged {
                layer.setTransform(transform, at: .zero)
            }
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
        }

        composition.instructions = instructionsCoveringPlayback(instructions)
        return composition
    }

    private func loadDefaults() async {
        isLoading = true
        status = "Opening…"
        isProMode = UserDefaults.standard.bool(forKey: Self.proModeDefaultsKey)
        ensureDefaultTracks()
        if !restoreAutosave() {
            status = "Drop media to begin"
        }
        isLoading = false
        status = ""
        if selectedClipID == nil {
            focusedLane = .video
            selectedClipID = videoClips.first?.id
        }
        if selectedClipIDs.isEmpty, let id = selectedClipID {
            selectedClipIDs = [id]
        }
    }

    @discardableResult
    private func addVideo(
        _ url: URL,
        fade: TimeInterval = 0,
        at start: TimeInterval? = nil,
        ontoTrackID: UUID? = nil
    ) async -> Bool {
        let trackID = ontoTrackID ?? focusedVideoTrackID()
        let placed: TimeInterval
        if let start {
            placed = snapTime(max(0, start))
        } else {
            placed = videoClips.filter { $0.trackID == trackID }.map(\.timelineEnd).max()
                ?? videoClips.map(\.timelineEnd).max()
                ?? 0
        }
        // Validate before pushing history so a rejected import leaves no undo step.
        guard let clip = await makeClip(url: url, start: placed, fade: fade, trackID: trackID, requiresMediaType: .video) else { return false }
        if !isLoading { pushHistory() }
        videoClips.append(clip)
        selectedClipID = clip.id
        selectedClipIDs = [clip.id]
        focusedLane = .video
        focusedTrackID = trackID
        growTimelineSpan()
        await rebuildAndWait()
        scheduleFilmstrip(for: clip)
        return true
    }

    /// Places full `sourceDuration` — never silently truncates to remaining video.
    /// Use `fitSelectedMusicToVideo` when truncate is desired.
    @discardableResult
    private func addAudio(
        _ url: URL,
        fade: TimeInterval = 0,
        at start: TimeInterval? = nil,
        replaceSelected: Bool = false,
        ontoTrackID: UUID? = nil,
        recordsHistory: Bool = true,
        normalize: Bool = true
    ) async -> Bool {
        let trackID = ontoTrackID ?? focusedAudioTrackID()
        if replaceSelected, let id = selectedAudio?.id, let i = audioIndex(id) {
            return await replaceAudio(at: i, with: url)
        }
        let laneClips = audioClips.filter { $0.trackID == trackID }
        let placed: TimeInterval
        if let start {
            placed = snapTime(max(0, start))
        } else if audioLayoutMode == .playlist {
            placed = laneClips.map(\.timelineEnd).max() ?? max(0, currentTime)
        } else {
            placed = laneClips.isEmpty ? currentTime : max(currentTime, laneClips.map(\.timelineEnd).max() ?? 0)
        }

        // Playlist insert: ripple push clips on THIS lane that start at/after drop time.
        var insertAt = placed
        if audioLayoutMode == .playlist, start != nil {
            guard let provisional = await makeClip(url: url, start: placed, fade: fade, trackID: trackID, requiresMediaType: .audio) else { return false }
            if recordsHistory, !isLoading { pushHistory() }
            let newDur = provisional.duration
            for i in audioClips.indices where audioClips[i].trackID == trackID && audioClips[i].timelineStart >= placed - 0.0001 {
                audioClips[i].timelineStart += newDur
            }
            insertAt = placed
            var clip = provisional
            clip.timelineStart = insertAt
            audioClips.append(clip)
            selectedClipID = clip.id
            selectedClipIDs = [clip.id]
            focusedLane = .audio
            focusedTrackID = trackID
            scheduleWaveform(for: clip)
            if normalize {
                normalizeAudioPlaylist(ripple: true, trackID: trackID)
                applyPlaylistCrossfades(trackID: trackID)
            }
            growTimelineSpan()
            await rebuildAndWait()
            return true
        }

        guard var clip = await makeClip(url: url, start: insertAt, fade: fade, trackID: trackID, requiresMediaType: .audio) else { return false }
        if recordsHistory, !isLoading { pushHistory() }
        // Full source — grow timeline; do NOT truncate to remaining video.
        // Capped at the media actually available so `insertTimeRange` can't throw.
        clip.duration = Self.renderableDuration(requested: clip.sourceDuration, sourceDuration: clip.sourceDuration, inPoint: 0)
        clip.clampFades()
        audioClips.append(clip)
        selectedClipID = clip.id
        selectedClipIDs = [clip.id]
        focusedLane = .audio
        focusedTrackID = trackID
        scheduleWaveform(for: clip)
        if normalize, audioLayoutMode == .playlist {
            normalizeAudioPlaylist(ripple: true, trackID: trackID)
            applyPlaylistCrossfades(trackID: trackID)
        }
        growTimelineSpan()
        await rebuildAndWait()
        return true
    }

    @discardableResult
    private func replaceAudio(at index: Int, with url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        let loadedSource = try? await asset.load(.duration).seconds
        let hasAudioTrack = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
        guard let loadedSource, loadedSource.isFinite, loadedSource > 0, hasAudioTrack else {
            errorMessage = "Can't replace with “\(url.lastPathComponent)” — the file is unsupported, corrupt, or has no audio track."
            return false
        }
        pushHistory()
        let old = audioClips[index]
        let source = loadedSource
        var clip = old
        clip.id = UUID()
        clip.url = url
        clip.name = url.deletingPathExtension().lastPathComponent
        clip.sourceDuration = source
        clip.inPoint = 0
        // Keep timelineStart; keep duration if it fits, else stretch to full source —
        // but never past what the new media can actually render.
        let keepDur = min(old.duration, Self.renderableDuration(requested: source, sourceDuration: source, inPoint: 0))
        clip.duration = keepDur > Self.minimumRenderedDuration ? keepDur : Self.renderableDuration(requested: source, sourceDuration: source, inPoint: 0)
        clip.waveform = []
        clip.clampFades()
        audioClips[index] = clip
        selectedClipID = clip.id
        selectedClipIDs = [clip.id]
        focusedLane = .audio
        scheduleWaveform(for: clip)
        if audioLayoutMode == .playlist {
            normalizeAudioPlaylist(ripple: true)
            applyPlaylistCrossfades()
        }
        growTimelineSpan()
        await rebuildAndWait()
        return true
    }

    /// Returns nil (with `errorMessage` set) when the file can't be read or lacks the
    /// media kind the lane needs. An unloadable clip would become an invisible ghost:
    /// rebuild silently skips it, and the next reload drops it via `sanitized()` (HIGH-3).
    private func makeClip(
        url: URL,
        start: TimeInterval,
        fade: TimeInterval,
        trackID: UUID,
        requiresMediaType: AVMediaType? = nil
    ) async -> MediaClip? {
        if StillImage.isStill(url) {
            if requiresMediaType == .audio {
                errorMessage = "“\(url.lastPathComponent)” is an image — place it on a video lane."
                return nil
            }
            // Pictures have no duration of their own. Prepare the cached movie now
            // so a file ImageIO cannot read never becomes an empty clip.
            do {
                _ = try await StillImage.movieURL(for: url)
            } catch {
                errorMessage = error.localizedDescription
                return nil
            }
            let dur = StillImage.defaultDuration
            return MediaClip(
                id: UUID(),
                url: url,
                name: url.deletingPathExtension().lastPathComponent,
                sourceDuration: StillImage.maximumDuration,
                inPoint: 0,
                timelineStart: start,
                duration: dur,
                fadeIn: min(fade, dur / 2),
                fadeOut: min(fade, dur / 2),
                trackID: trackID
            )
        }
        let asset = AVURLAsset(url: url)
        let source = (try? await asset.load(.duration).seconds) ?? 0
        guard source.isFinite, source > 0 else {
            errorMessage = "Can't read “\(url.lastPathComponent)” — the file is unsupported or corrupt."
            return nil
        }
        if let mediaType = requiresMediaType {
            let tracks = (try? await asset.loadTracks(withMediaType: mediaType)) ?? []
            guard !tracks.isEmpty else {
                errorMessage = "“\(url.lastPathComponent)” has no \(mediaType.rawValue) track to place here."
                return nil
            }
        }
        let dur = Self.renderableDuration(requested: source, sourceDuration: source, inPoint: 0)
        return MediaClip(
            id: UUID(),
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            sourceDuration: source,
            inPoint: 0,
            timelineStart: start,
            duration: dur,
            fadeIn: min(fade, dur / 2),
            fadeOut: min(fade, dur / 2),
            trackID: trackID
        )
    }

    // MARK: - Playlist normalize / magnetic snap / crossfade

    /// Sort by timelineStart and abut (ripple). Overlaps are pushed forward.
    /// When `ripple` is true, clips are hard-abutted; call `applyPlaylistCrossfades()` afterward
    /// to introduce complementary overlaps at junctions.
    func normalizeAudioPlaylist(ripple: Bool, trackID: UUID? = nil) {
        guard audioLayoutMode == .playlist, !audioClips.isEmpty else { return }
        let selected = selectedClipID
        let laneIDs: [UUID]
        if let trackID {
            laneIDs = [trackID]
        } else {
            laneIDs = Array(Set(audioClips.map(\.trackID)))
        }
        for laneID in laneIDs {
            var sorted = audioClips.filter { $0.trackID == laneID }.sorted { $0.timelineStart < $1.timelineStart }
            guard !sorted.isEmpty else { continue }
            if ripple {
                sorted[0].timelineStart = max(0, sorted[0].timelineStart)
                var cursor = sorted[0].timelineEnd
                for i in 1..<sorted.count {
                    sorted[i].timelineStart = cursor
                    cursor = sorted[i].timelineEnd
                }
            }
            let byID = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0) })
            for i in audioClips.indices where audioClips[i].trackID == laneID {
                if let updated = byID[audioClips[i].id] {
                    audioClips[i] = updated
                }
            }
        }
        // Keep a stable overall order for UI: by track then start.
        let trackOrder = Dictionary(uniqueKeysWithValues: audioTracks.enumerated().map { ($0.element.id, $0.offset) })
        audioClips.sort {
            let a = trackOrder[$0.trackID] ?? 0
            let b = trackOrder[$1.trackID] ?? 0
            if a != b { return a < b }
            return $0.timelineStart < $1.timelineStart
        }
        if let selected { selectedClipID = selected }
    }

    /// On move end: snap shut small gaps; ripple-push overlaps before full normalize.
    private func magneticSnapPlaylistOnRelease() {
        guard audioLayoutMode == .playlist, audioClips.count >= 2 else { return }
        let laneIDs = Set(audioClips.map(\.trackID))
        for laneID in laneIDs {
            let ordered = audioClips.filter { $0.trackID == laneID }.sorted { $0.timelineStart < $1.timelineStart }
            guard ordered.count >= 2 else { continue }
            for idx in 1..<ordered.count {
                guard let i = audioIndex(ordered[idx].id),
                      let pi = audioIndex(ordered[idx - 1].id) else { continue }
                let prevEnd = audioClips[pi].timelineEnd
                let gap = audioClips[i].timelineStart - prevEnd
                if gap < Self.playlistSnapThreshold {
                    audioClips[i].timelineStart = prevEnd
                }
            }
            if let first = ordered.first, let i = audioIndex(first.id) {
                if audioClips[i].timelineStart <= Self.playlistSnapThreshold {
                    audioClips[i].timelineStart = 0
                }
            }
        }
    }

    /// Auto complementary crossfades per audio lane.
    func applyPlaylistCrossfades(trackID: UUID? = nil) {
        guard audioLayoutMode == .playlist, audioClips.count >= 2 else { return }
        let laneIDs: [UUID]
        if let trackID {
            laneIDs = [trackID]
        } else {
            laneIDs = Array(Set(audioClips.map(\.trackID)))
        }
        let xf = Self.playlistCrossfade
        for laneID in laneIDs {
            var orderedIDs = audioClips.filter { $0.trackID == laneID }.sorted { $0.timelineStart < $1.timelineStart }.map(\.id)
            guard orderedIDs.count >= 2 else { continue }
            for n in 0..<(orderedIDs.count - 1) {
                orderedIDs = audioClips.filter { $0.trackID == laneID }.sorted { $0.timelineStart < $1.timelineStart }.map(\.id)
                guard let li = audioIndex(orderedIDs[n]),
                      let ri = audioIndex(orderedIDs[n + 1]) else { continue }
                let gap = audioClips[ri].timelineStart - audioClips[li].timelineEnd
                guard abs(gap) <= Self.playlistSnapThreshold else { continue }
                let leftMax = max(0, audioClips[li].duration / 2.5)
                let rightMax = max(0, audioClips[ri].duration / 2.5)
                let amount = min(xf, leftMax, rightMax)
                guard amount > 0.05 else { continue }
                let newStart = max(0, audioClips[li].timelineEnd - amount)
                let delta = audioClips[ri].timelineStart - newStart
                for id in orderedIDs[(n + 1)...] {
                    if let idx = audioIndex(id) {
                        audioClips[idx].timelineStart = max(0, audioClips[idx].timelineStart - delta)
                    }
                }
                audioClips[li].fadeOut = amount
                if let ri2 = audioIndex(orderedIDs[n + 1]) {
                    audioClips[ri2].fadeIn = amount
                    audioClips[ri2].clampFades()
                }
                audioClips[li].clampFades()
            }
        }
    }

    /// Duck factor for a music clip: ducked when it overlaps any video span.
    private func duckFactor(for clip: MediaClip) -> Float {
        guard isDuckingMusic else { return 1 }
        let overlaps = videoClips.contains { v in
            clip.timelineStart < v.timelineEnd && clip.timelineEnd > v.timelineStart
        }
        return overlaps ? duckingGain : 1
    }

    private func trimInOn(_ clip: inout MediaClip, time: TimeInterval) {
        let right = clip.timelineEnd
        let outPoint = clip.inPoint + clip.duration
        let minStart = max(0, right - outPoint)
        let maxStart = right - Self.minimumClipDuration
        guard maxStart > minStart else { return }
        let start = min(max(time, minStart), maxStart)
        clip.timelineStart = start
        clip.duration = right - start
        clip.inPoint = max(0, outPoint - clip.duration)
        clip.clampFades()
    }

    private func trimOutOn(_ clip: inout MediaClip, time: TimeInterval) {
        let minEnd = clip.timelineStart + Self.minimumClipDuration
        let maxEnd = clip.timelineStart + max(Self.minimumClipDuration, clip.sourceDuration - clip.inPoint)
        clip.duration = min(max(time, minEnd), maxEnd) - clip.timelineStart
        clip.clampFades()
    }

    private func audioIndex(_ id: UUID) -> Int? { audioClips.firstIndex(where: { $0.id == id }) }
    private func videoIndex(_ id: UUID) -> Int? { videoClips.firstIndex(where: { $0.id == id }) }

    /// Direct manipulation preserves a multi-selection when its anchor is already
    /// selected. Clicking a handle on an unselected clip edits only that clip.
    private func directEditClipIDs(anchor id: UUID) -> Set<UUID> {
        selectedClipIDs.contains(id) ? selectedClipIDs : [id]
    }

    private func mutateSelectedVideo(_ body: (inout MediaClip) -> Void) {
        let ids = selectedClipIDs.isEmpty ? Set([selectedVideo?.id].compactMap { $0 }) : selectedClipIDs
        var any = false
        for id in ids {
            guard let i = videoIndex(id) else { continue }
            body(&videoClips[i])
            videoClips[i].clampFades()
            any = true
        }
        if any { applyFades() }
    }

    private func mutateSelectedAudio(_ body: (inout MediaClip) -> Void) {
        let ids = selectedClipIDs.isEmpty ? Set([selectedAudio?.id].compactMap { $0 }) : selectedClipIDs
        var any = false
        for id in ids {
            guard let i = audioIndex(id) else { continue }
            body(&audioClips[i])
            audioClips[i].clampFades()
            any = true
        }
        if any { applyFades(refreshingVideo: false) }
    }

    private func rebuildComposition() async {
        growTimelineSpan()
        if isProMode {
            frameDuration = CMTime(
                seconds: 1 / max(1, proSettings.frameRate),
                preferredTimescale: 60_000
            )
        }
        if Task.isCancelled { return }
        do {
            let rebuiltMix = AVMutableComposition()
            // Build the track-ID maps in locals and publish them together with
            // `mix` at the commit point below — a cancelled or superseded rebuild
            // must never leave the shared maps describing a composition that is
            // not loaded (HIGH-1).
            var newVideoAudioTrackIDs: [UUID: CMPersistentTrackID] = [:]
            var newMusicTrackIDs: [UUID: CMPersistentTrackID] = [:]

            let videoTrack = rebuiltMix.addMutableTrack(withMediaType: .video, preferredTrackID: 1)

            // One composition track can't hold two overlapping clips — insertTimeRange pushes a
            // later clip past the previous end, inflating the player item beyond the model
            // duration (two clips at t=0 would become 2× long). Never insert before the running
            // track end: skip the overlapped head and lay only the fresh tail after it, so the
            // composition duration stays bounded by the model's max end. `renderSegments()` is
            // the single source of truth for that collapse, and `makeVideoComposition` derives
            // its instructions from the same segments so they can't disagree.
            for segment in renderSegments() {
                if Task.isCancelled { return }
                guard let videoTrack else { continue }
                if StillImage.isStill(segment.clip.url) {
                    do {
                        let movie = try await StillImage.movieURL(for: segment.clip.url)
                        // The picture has no time axis. `segment.sourceStart` only records
                        // a trim; reading it as a movie offset would run past the one-second cache.
                        let placed = try await StillImage.place(
                            movieURL: movie,
                            on: videoTrack,
                            at: segment.at,
                            duration: segment.duration
                        )
                        if placed.renderSize.width > 1, placed.renderSize.height > 1 {
                            renderSize = placed.renderSize
                        }
                        if !isProMode, placed.frameRate > 1 {
                            frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int(placed.frameRate.rounded()))))
                        }
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    continue
                }
                let asset = AVURLAsset(url: segment.clip.url)
                guard let src = try await asset.loadTracks(withMediaType: .video).first else { continue }
                try videoTrack.insertTimeRange(
                    CMTimeRange(start: CMTime(seconds: segment.sourceStart, preferredTimescale: 600), duration: CMTime(seconds: segment.duration, preferredTimescale: 600)),
                    of: src,
                    at: CMTime(seconds: segment.at, preferredTimescale: 600)
                )
                let transform = try await src.load(.preferredTransform)
                videoTrack.preferredTransform = transform
                let natural = try await src.load(.naturalSize)
                let rendered = CGRect(origin: .zero, size: natural).applying(transform)
                renderSize = CGSize(width: abs(rendered.width), height: abs(rendered.height))
                let fps = try await src.load(.nominalFrameRate)
                if !isProMode, fps > 1 {
                    frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int(fps.rounded()))))
                }
            }

            // Each video clip gets its own audio track so `makeAudioMix` can attach one
            // `AVAudioMixInputParameters` per clip (a shared track drops earlier clips' fades).
            for clip in videoClips.sorted(by: { $0.timelineStart < $1.timelineStart }) {
                if Task.isCancelled { return }
                // A still has no soundtrack. Probing the image file for audio throws
                // and would discard the whole preview composition.
                if StillImage.isStill(clip.url) { continue }
                let asset = AVURLAsset(url: clip.url)
                guard let src = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                guard let track = rebuiltMix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                let start = max(0, clip.timelineStart)
                let duration = Self.renderableDuration(requested: min(clip.duration, clip.timelineEnd - start), sourceDuration: clip.sourceDuration, inPoint: clip.inPoint)
                try track.insertTimeRange(
                    CMTimeRange(start: CMTime(seconds: clip.inPoint, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600)),
                    of: src,
                    at: CMTime(seconds: start, preferredTimescale: 600)
                )
                newVideoAudioTrackIDs[clip.id] = track.trackID
            }
            for clip in audioClips where !clip.muted {
                if Task.isCancelled { return }
                let asset = AVURLAsset(url: clip.url)
                guard let src = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                // Let AVFoundation allocate the track ID; a fixed preferred ID can be
                // rejected after repeated rebuilds, which used to crash on force-unwrap.
                guard let track = rebuiltMix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try track.insertTimeRange(
                    CMTimeRange(start: CMTime(seconds: clip.inPoint, preferredTimescale: 600), duration: CMTime(seconds: Self.renderableDuration(requested: clip.duration, sourceDuration: clip.sourceDuration, inPoint: clip.inPoint), preferredTimescale: 600)),
                    of: src,
                    at: CMTime(seconds: clip.timelineStart, preferredTimescale: 600)
                )
                newMusicTrackIDs[clip.id] = track.trackID
            }

            if Task.isCancelled { return }
            // Commit `mix` and the track-ID maps together BEFORE building the player
            // item: makeAudioMix()/makeVideoComposition() read them (track IDs, layer
            // instructions), so assigning after would pair the new item with the
            // PREVIOUS composition — video fades silently vanish after every edit.
            mix = rebuiltMix
            videoAudioTrackIDs = newVideoAudioTrackIDs
            musicTrackIDs = newMusicTrackIDs
            let item = AVPlayerItem(asset: rebuiltMix)
            item.audioMix = makeAudioMix()
            item.videoComposition = makeVideoComposition()
            let wasPlaying = isPlaying
            player.replaceCurrentItem(with: item)
            seek(to: min(currentTime, duration))
            if wasPlaying {
                player.play()
                isPlaying = true
            }
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.loopEnabled {
                        self.seek(to: self.loopIn)
                        self.player.play()
                        self.isPlaying = true
                    } else {
                        self.isPlaying = false
                        self.seek(to: 0)
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            status = "Could not build timeline"
        }
    }

    private func makeAudioMix() -> AVMutableAudioMix {
        let mix = AVMutableAudioMix()
        var params: [AVMutableAudioMixInputParameters] = []
        func addMix(for clip: MediaClip, trackID: CMPersistentTrackID, volume: Float, applyDuck: Bool) {
            let p = AVMutableAudioMixInputParameters()
            p.trackID = trackID
            let duck: Float = applyDuck ? duckFactor(for: clip) : 1
            let clipGain = min(max(0, clip.gain), 1)
            let vol: Float = clip.muted ? 0 : volume * clipGain * duck
            let start = clip.timelineStart
            let fadeIn = min(max(0, clip.fadeIn), clip.duration / 2)
            let fadeOut = min(max(0, clip.fadeOut), clip.duration - fadeIn)
            if fadeIn > 0.01 && vol > 0 {
                p.setVolumeRamp(
                    fromStartVolume: 0,
                    toEndVolume: vol,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: start, preferredTimescale: 600),
                        duration: CMTime(seconds: fadeIn, preferredTimescale: 600)
                    )
                )
            } else {
                p.setVolume(vol, at: CMTime(seconds: start, preferredTimescale: 600))
            }
            if isProMode,
               let tap = ProAudioProcessor.makeTap(
                   pan: clip.pan,
                   limiterEnabled: proSettings.limiterEnabled
               ) {
                p.audioTapProcessor = tap
            }
            if fadeOut > 0.01 && vol > 0 {
                p.setVolumeRamp(
                    fromStartVolume: vol,
                    toEndVolume: 0,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: start + clip.duration - fadeOut, preferredTimescale: 600),
                        duration: CMTime(seconds: fadeOut, preferredTimescale: 600)
                    )
                )
            }
            params.append(p)
        }
        for clip in videoClips {
            if let id = videoAudioTrackIDs[clip.id] {
                let vol = track(id: clip.trackID)?.volume ?? videoVolume
                addMix(for: clip, trackID: id, volume: vol, applyDuck: false)
            }
        }
        for clip in audioClips {
            if let id = musicTrackIDs[clip.id] {
                let vol = track(id: clip.trackID)?.volume ?? musicVolume
                addMix(for: clip, trackID: id, volume: vol, applyDuck: true)
            }
        }
        mix.inputParameters = params
        return mix
    }

    /// One clip's footprint on the single video composition track, after the overlap
    /// collapse `rebuildComposition` applies. `at`/`duration` are on-track (non-overlapping,
    /// so video-composition instructions can't collide); `sourceStart` is the equivalent
    /// offset into the source asset. A clip that's fully covered by earlier media yields no
    /// segment — it inserts nothing and must not generate an instruction.
    private struct VideoRenderSegment {
        var clip: MediaClip
        var at: TimeInterval
        var sourceStart: TimeInterval
        var duration: TimeInterval
    }

    /// The shared overlap-collapse rule. Both media insertion and instruction emission use
    /// this so the two can never disagree about what's actually on the track.
    private func renderSegments() -> [VideoRenderSegment] {
        var segments: [VideoRenderSegment] = []
        var videoTrackEnd: TimeInterval = 0
        for clip in videoClips.sorted(by: { $0.timelineStart < $1.timelineStart }) {
            let start = max(0, clip.timelineStart)
            let desired = Self.renderableDuration(requested: clip.duration, sourceDuration: clip.sourceDuration, inPoint: clip.inPoint)
            let clipEnd = start + desired
            if start >= videoTrackEnd - 0.0001 {
                // No overlap: lay the whole clip.
                segments.append(VideoRenderSegment(clip: clip, at: start, sourceStart: clip.inPoint, duration: desired))
                videoTrackEnd = max(videoTrackEnd, start + desired)
            } else if clipEnd > videoTrackEnd + 0.0001 {
                // Overlaps existing media: only the tail beyond videoTrackEnd is fresh.
                let skip = videoTrackEnd - start
                segments.append(VideoRenderSegment(clip: clip, at: videoTrackEnd, sourceStart: clip.inPoint + skip, duration: clipEnd - videoTrackEnd))
                videoTrackEnd = max(videoTrackEnd, clipEnd)
            }
            // Fully covered — no segment, nothing inserted, no instruction.
        }
        return segments
    }

    private var hasProVideoEffects: Bool {
        guard isProMode else { return false }
        return videoClips.contains {
            $0.transform != .identity
                || !$0.transformKeyframes.isEmpty
                || $0.transitionIn.style != .none
                || $0.transitionOut.style != .none
        }
    }

    private func transformValue(for clip: MediaClip, at localTime: TimeInterval) -> ClipTransform {
        let keyframes = clip.transformKeyframes.sorted { $0.time < $1.time }
        guard !keyframes.isEmpty else { return clip.transform }
        if localTime <= keyframes[0].time {
            guard keyframes[0].time > 0 else { return keyframes[0].transform }
            return .interpolated(
                from: clip.transform,
                to: keyframes[0].transform,
                progress: localTime / keyframes[0].time
            )
        }
        for pair in zip(keyframes, keyframes.dropFirst()) where localTime <= pair.1.time {
            let span = max(0.000_1, pair.1.time - pair.0.time)
            return .interpolated(
                from: pair.0.transform,
                to: pair.1.transform,
                progress: (localTime - pair.0.time) / span
            )
        }
        return keyframes.last?.transform ?? clip.transform
    }

    private func configureVideoLayer(
        _ layer: AVMutableVideoCompositionLayerInstruction,
        segment: VideoRenderSegment,
        canvasSize: CGSize,
        baseTransform: CGAffineTransform = .identity
    ) {
        let clip = segment.clip
        let localStart = max(0, segment.at - clip.timelineStart)
        let localEnd = localStart + segment.duration
        let segmentStart = CMTime(seconds: segment.at, preferredTimescale: 600)
        let baseAtStart = transformValue(for: clip, at: localStart)

        if isProMode, !clip.transformKeyframes.isEmpty {
            var points: [(TimeInterval, ClipTransform)] = [(localStart, baseAtStart)]
            points += clip.transformKeyframes
                .filter { $0.time > localStart + 0.000_1 && $0.time < localEnd - 0.000_1 }
                .map { ($0.time, $0.transform) }
            points.append((localEnd, transformValue(for: clip, at: localEnd)))
            for pair in zip(points, points.dropFirst()) {
                let start = segment.at + pair.0.0 - localStart
                let span = max(0.000_1, pair.1.0 - pair.0.0)
                let range = CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: 600),
                    duration: CMTime(seconds: span, preferredTimescale: 600)
                )
                layer.setTransformRamp(
                    fromStart: pair.0.1.affineTransform(canvasSize: canvasSize, base: baseTransform),
                    toEnd: pair.1.1.affineTransform(canvasSize: canvasSize, base: baseTransform),
                    timeRange: range
                )
                layer.setOpacityRamp(
                    fromStartOpacity: Float(pair.0.1.opacity),
                    toEndOpacity: Float(pair.1.1.opacity),
                    timeRange: range
                )
            }
        } else {
            layer.setTransform(
                baseAtStart.affineTransform(canvasSize: canvasSize, base: baseTransform),
                at: segmentStart
            )
            layer.setOpacity(Float(baseAtStart.opacity), at: segmentStart)
        }

        let fadeIn = min(max(0, clip.fadeIn), segment.duration / 2)
        let fadeOut = min(max(0, clip.fadeOut), segment.duration - fadeIn)
        if fadeIn > 0.01 {
            layer.setOpacityRamp(
                fromStartOpacity: 0,
                toEndOpacity: Float(baseAtStart.opacity),
                timeRange: CMTimeRange(
                    start: segmentStart,
                    duration: CMTime(seconds: fadeIn, preferredTimescale: 600)
                )
            )
        }
        if fadeOut > 0.01 {
            let endOpacity = transformValue(for: clip, at: localEnd).opacity
            layer.setOpacityRamp(
                fromStartOpacity: Float(endOpacity),
                toEndOpacity: 0,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: segment.at + segment.duration - fadeOut, preferredTimescale: 600),
                    duration: CMTime(seconds: fadeOut, preferredTimescale: 600)
                )
            )
        }

        guard isProMode else { return }
        if localStart < 0.000_1 {
            applyTransition(
                clip.transitionIn,
                incoming: true,
                layer: layer,
                clip: clip,
                canvasSize: canvasSize,
                baseTransform: baseTransform,
                timelineStart: segment.at,
                localTime: 0,
                maximumDuration: segment.duration
            )
        }
        if abs(localEnd - clip.duration) < 0.001 {
            applyTransition(
                clip.transitionOut,
                incoming: false,
                layer: layer,
                clip: clip,
                canvasSize: canvasSize,
                baseTransform: baseTransform,
                timelineStart: segment.at + segment.duration,
                localTime: clip.duration,
                maximumDuration: segment.duration
            )
        }
    }

    private func applyTransition(
        _ transition: ClipTransition,
        incoming: Bool,
        layer: AVMutableVideoCompositionLayerInstruction,
        clip: MediaClip,
        canvasSize: CGSize,
        baseTransform: CGAffineTransform,
        timelineStart: TimeInterval,
        localTime: TimeInterval,
        maximumDuration: TimeInterval
    ) {
        guard transition.style != .none else { return }
        let duration = min(max(0, transition.duration), maximumDuration / 2)
        guard duration > 0.001 else { return }
        let rangeStart = incoming ? timelineStart : timelineStart - duration
        let range = CMTimeRange(
            start: CMTime(seconds: rangeStart, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        let settled = transformValue(for: clip, at: localTime)
        let settledTransform = settled.affineTransform(canvasSize: canvasSize, base: baseTransform)
        switch transition.style {
        case .none:
            break
        case .dissolve:
            layer.setOpacityRamp(
                fromStartOpacity: incoming ? 0 : Float(settled.opacity),
                toEndOpacity: incoming ? Float(settled.opacity) : 0,
                timeRange: range
            )
        case .slide:
            let displaced = settledTransform.translatedBy(
                x: incoming ? -canvasSize.width * 0.18 : canvasSize.width * 0.18,
                y: 0
            )
            layer.setTransformRamp(
                fromStart: incoming ? displaced : settledTransform,
                toEnd: incoming ? settledTransform : displaced,
                timeRange: range
            )
        case .zoom:
            let zoomed = settledTransform
                .translatedBy(x: canvasSize.width / 2, y: canvasSize.height / 2)
                .scaledBy(x: incoming ? 0.82 : 1.18, y: incoming ? 0.82 : 1.18)
                .translatedBy(x: -canvasSize.width / 2, y: -canvasSize.height / 2)
            layer.setTransformRamp(
                fromStart: incoming ? zoomed : settledTransform,
                toEnd: incoming ? settledTransform : zoomed,
                timeRange: range
            )
        }
    }

    private func makeVideoComposition() -> AVVideoComposition? {
        guard let track = mix.track(withTrackID: 1), !videoClips.isEmpty else { return nil }
        guard videoClips.contains(where: { $0.fadeIn > 0.01 || $0.fadeOut > 0.01 })
                || hasProVideoEffects else { return nil }
        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize.width > 1 ? renderSize : CGSize(width: 1080, height: 1920)
        composition.frameDuration = frameDuration
        var instructions: [AVMutableVideoCompositionInstruction] = []
        for segment in renderSegments() {
            // Instruction ranges come from the *actual* on-track segment, not the model's
            // timeline range — a partially-overlapped clip only owns its rendered tail, and a
            // fully-overlapped clip isn't in `segments` at all, so no two instructions overlap.
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(
                start: CMTime(seconds: segment.at, preferredTimescale: 600),
                duration: CMTime(seconds: segment.duration, preferredTimescale: 600)
            )
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            configureVideoLayer(layer, segment: segment, canvasSize: composition.renderSize)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
        }
        guard !instructions.isEmpty else { return nil }
        composition.instructions = instructionsCoveringPlayback(instructions)
        return composition
    }

    /// AVPlayer drops the entire preview when a video composition leaves any hole in
    /// the player item, even a single tick past the video track where an audio edit
    /// rounded longer. Fill those holes with empty instructions so the picture stays
    /// up for the whole item. The empty spans are the regions with no video.
    private func instructionsCoveringPlayback(
        _ segmentInstructions: [AVMutableVideoCompositionInstruction]
    ) -> [AVVideoCompositionInstructionProtocol] {
        var covered: [AVMutableVideoCompositionInstruction] = []
        var cursor = CMTime.zero
        for instruction in segmentInstructions {
            let start = instruction.timeRange.start
            let end = instruction.timeRange.end
            if CMTimeCompare(start, cursor) > 0 {
                let gap = AVMutableVideoCompositionInstruction()
                gap.timeRange = CMTimeRange(start: cursor, end: start)
                gap.layerInstructions = []
                covered.append(gap)
            }
            covered.append(instruction)
            cursor = end
        }
        let itemEnd = mix.duration
        if itemEnd.isNumeric, CMTimeCompare(itemEnd, cursor) > 0 {
            let gap = AVMutableVideoCompositionInstruction()
            gap.timeRange = CMTimeRange(start: cursor, end: itemEnd)
            gap.layerInstructions = []
            covered.append(gap)
        }
        return covered
    }

    private func installTimeObserver() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = seconds
                if self.loopEnabled, self.isPlaying {
                    let out = self.effectiveLoopOut()
                    if seconds >= out - 0.02 {
                        self.seek(to: self.loopIn)
                        self.player.play()
                        self.isPlaying = true
                    }
                }
            }
        }
    }

    private var keyMonitor: Any?

    /// True when a text field/editor has focus — playlist shortcuts must not steal Delete/Backspace/etc.
    private var isTextEditingActive: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSTextView || responder is NSTextField { return true }
        if responder is NSText { return true }
        // Field editor is often the window's fieldEditor
        if let client = (responder as? NSTextView)?.delegate, client is NSTextField { return true }
        return false
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // While the export sheet is open (or any text field is focused), never swallow keys —
            // otherwise Delete while renaming the export file deletes playlist clips.
            if self.isExportSheetPresented || self.isTextEditingActive {
                return event
            }
            if event.keyCode == 49 { // Space
                self.togglePlay()
                return nil
            }
            let command = event.modifierFlags.contains(.command)
            let option = event.modifierFlags.contains(.option)
            let control = event.modifierFlags.contains(.control)
            let shift = event.modifierFlags.contains(.shift)
            // Undo = ⌘Z (keyCode 6); redo = ⇧⌘Z (keyCode 6 + shift) or ⌘Y (keyCode 16).
            // keyCode 7 is ⌘X (Cut) — never map it to redo, so Cut stays free.
            if command && !shift && event.keyCode == 6 { self.undo(); return nil }
            if (command && shift && event.keyCode == 6) || (command && event.keyCode == 16) { self.redo(); return nil }
            if command && event.keyCode == 2 { self.duplicateSelectedClip(); return nil }
            // Standard Mac +/= and - keys. Accept either shifted + or unshifted =
            // so keyboard layout details do not make zoom-in unreachable.
            if command && event.keyCode == 24 { self.zoomIn(); return nil }
            if command && event.keyCode == 27 { self.zoomOut(); return nil }
            if event.keyCode == 1 && !command { self.splitSelectedAtPlayhead(); return nil } // S (not ⌘S)
            if event.keyCode == 123 || event.keyCode == 124 {
                let direction = event.keyCode == 124 ? 1 : -1
                if command {
                    direction > 0 ? self.selectNextClip() : self.selectPreviousClip()
                    return nil
                }
                if option && control {
                    if self.nudgeSelectedAudio(samples: direction * (shift ? 10 : 1)) { return nil }
                } else if option {
                    if self.nudgeSelectedAudio(milliseconds: Double(direction * (shift ? 10 : 1))) { return nil }
                    direction > 0 ? self.seekToNextMusicClip() : self.seekToPreviousMusicClip()
                    return nil
                } else if self.nudgeSelectedByFrames(direction * (shift ? 10 : 1)) {
                    return nil
                } else {
                    direction > 0 ? self.selectNextClip() : self.selectPreviousClip()
                    return nil
                }
            }
            // I / O — mark loop in/out; L — toggle loop
            if event.keyCode == 34 && !command { self.markLoopIn(); return nil }
            if event.keyCode == 31 && !command { self.markLoopOut(); return nil }
            if event.keyCode == 37 && !command { self.toggleLoop(); return nil }
            if event.keyCode == 51 || event.keyCode == 117 {
                self.deleteSelectedClips(preferringLane: self.focusedLane)
                return nil
            }
            return event
        }
    }

    private func installTerminationHandler() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushAutosave()
            }
        }
    }
}

enum Waveform {
    static func peaks(url: URL, points: Int, start: TimeInterval = 0, limit: TimeInterval) async -> [Float] {
        await Task.detached(priority: .userInitiated) {
            do {
                let file = try AVAudioFile(forReading: url)
                let format = file.processingFormat
                let sampleRate = max(1, format.sampleRate)
                let startFrame = AVAudioFramePosition(max(0, start) * sampleRate)
                if startFrame < file.length { file.framePosition = startFrame }
                let remainingFrames = max(0, file.length - file.framePosition)
                let maximumFrames = AVAudioFramePosition(limit * sampleRate)
                let targetFrameCount = min(remainingFrames, max(0, maximumFrames))
                guard targetFrameCount > 0, points > 0 else { return [Float]() }

                let readChunkSize = AVAudioFrameCount(65_536)
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: min(readChunkSize, AVAudioFrameCount(targetFrameCount))
                ) else { return [Float]() }
                guard let data = buffer.floatChannelData else { return [Float]() }
                let channels = Int(format.channelCount)

                var out = [Float](repeating: 0, count: points)
                var framesProcessed: Int64 = 0
                let samplesPerPoint = Double(targetFrameCount) / Double(points)
                var nextPointBoundary: Double = 0
                var currentPoint = 0

                while framesProcessed < targetFrameCount {
                    let framesToRead = AVAudioFrameCount(
                        min(Int64(buffer.frameCapacity), targetFrameCount - framesProcessed)
                    )
                    buffer.frameLength = 0
                    try file.read(into: buffer, frameCount: framesToRead)
                    let frames = Int(buffer.frameLength)
                    guard frames > 0 else { break }

                    for frame in 0..<frames {
                        var mixed: Float = 0
                        for channel in 0..<channels {
                            mixed += abs(data[channel][frame])
                        }
                        let peak = mixed / Float(max(1, channels))

                        while currentPoint < points - 1, Double(framesProcessed + Int64(frame)) >= nextPointBoundary {
                            currentPoint += 1
                            nextPointBoundary = Double(currentPoint + 1) * samplesPerPoint
                        }
                        out[currentPoint] = max(out[currentPoint], min(1, peak * 1.6))
                    }

                    framesProcessed += Int64(frames)
                }
                return out
            } catch {
                return [Float]()
            }
        }.value
    }

    static func peaksFromAsset(url: URL, points: Int, start: TimeInterval, limit: TimeInterval) async -> [Float] {
        await Task.detached(priority: .userInitiated) {
            do {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [Float]() }
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ])
                reader.add(output)
                reader.timeRange = CMTimeRange(
                    start: CMTime(seconds: max(0, start), preferredTimescale: 600),
                    duration: CMTime(seconds: max(0.05, limit), preferredTimescale: 600)
                )
                guard reader.startReading() else { return [Float]() }
                var samples: [Float] = []
                samples.reserveCapacity(points * 8)
                while let buf = output.copyNextSampleBuffer(),
                      let block = CMSampleBufferGetDataBuffer(buf) {
                    let len = CMBlockBufferGetDataLength(block)
                    var data = Data(count: len)
                    data.withUnsafeMutableBytes { raw in
                        if let p = raw.baseAddress {
                            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: p)
                        }
                    }
                    let count = len / 2
                    data.withUnsafeBytes { raw in
                        let ints = raw.bindMemory(to: Int16.self)
                        for i in 0..<count {
                            samples.append(abs(Float(ints[i]) / 32768.0))
                        }
                    }
                }
                guard !samples.isEmpty else { return [Float]() }
                let bucket = max(1, samples.count / max(points, 1))
                var out = [Float](repeating: 0, count: max(points, 1))
                for i in 0..<out.count {
                    let a = i * bucket
                    let b = min(samples.count, a + bucket)
                    var peak: Float = 0
                    if a < b {
                        for s in samples[a..<b] { peak = max(peak, s) }
                    }
                    out[i] = min(1, peak * 1.6)
                }
                return out
            } catch {
                return [Float]()
            }
        }.value
    }
}

enum Filmstrip {
    nonisolated static func generate(url: URL, count: Int, inPoint: TimeInterval = 0, duration: TimeInterval? = nil) async -> [CGImage] {
        if StillImage.isStill(url) {
            let frames = max(1, count)
            return await Task.detached(priority: .userInitiated) {
                guard let image = StillImage.thumbnail(at: url) else { return [] }
                return Array(repeating: image, count: frames)
            }.value
        }
        return await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 268)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
            do {
                let full = try await asset.load(.duration).seconds
                let span = duration ?? max(0.01, full - inPoint)
                guard span > 0 else { return [CGImage]() }
                var images: [CGImage] = []
                images.reserveCapacity(count)
                for i in 0..<count {
                    let t = inPoint + span * (Double(i) + 0.5) / Double(count)
                    let cg = try generator.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
                    images.append(cg)
                }
                return images
            } catch {
                return [CGImage]()
            }
        }.value
    }
}
