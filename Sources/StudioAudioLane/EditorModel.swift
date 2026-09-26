import AppKit
import AVFoundation
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
        waveform: [Float] = []
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
                : []
        )
        var sanitized = clip
        let minimumClipDuration = 0.12
        sanitized.inPoint = min(max(0, inPoint), max(0, sourceDuration - minimumClipDuration))
        sanitized.duration = min(
            max(duration, minimumClipDuration),
            max(minimumClipDuration, sourceDuration - sanitized.inPoint)
        )
        sanitized.timelineStart = max(0, timelineStart)
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

    enum CodingKeys: String, CodingKey {
        case clips, tracks, focusedLane, focusedTrackID, selectedClipID, selectedClipIDs
        case videoVolume, musicVolume, isDuckingMusic, audioLayoutMode, timelineSpan
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
        timelineSpan: TimeInterval? = nil
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
        applyFades()
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
        Task { await rebuildComposition() }
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

    static let minimumClipDuration: TimeInterval = 0.12
    /// Floor for a clip's rendered duration. Composition inserts `max(0.05, clip.duration)`,
    /// so keep the stored duration no larger than the media — a 50 ms file must not become 0.12 s.
    static let minimumRenderedDuration: TimeInterval = 0.05

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
    private var activeExportSession: AVAssetExportSession?
    private var exportProgressTimer: Timer?
    private var exportWriterTask: Task<Void, Never>?
    /// Destination of the in-flight export; used to delete incomplete files on cancel/failure.
    var exportDestinationURL: URL?

    /// Monotonic revision counter — bumped on every MCP-initiated mutation.
    private(set) var mcpRevision: Int = 0

    func bumpMCPRevision() {
        mcpRevision += 1
    }

    /// Public bridge for MCP server — the MCP layer calls these instead of reaching into private state.
    func addVideoPublic(url: URL, start: TimeInterval?, ontoTrackID: UUID) async {
        await addVideo(url, fade: 0, at: start, ontoTrackID: ontoTrackID)
    }

    func addAudioPublic(url: URL, start: TimeInterval?, ontoTrackID: UUID) async {
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
        await rebuildComposition()
    }
    func applyFadesPublic() {
        applyFades()
    }

    /// MCP export entry point — bypasses the save panel.
    func beginExportDirect(settings: ExportSettings, destination: URL) {
        guard !isExporting, let item = player.currentItem else { return }
        var settings = settings
        settings.sanitize()

        try? FileManager.default.removeItem(at: destination)
        isExporting = true
        exportProgress = 0
        errorMessage = nil
        exportDestinationURL = destination
        let pipeline = settings.prefersWriterPipeline ? "writer" : "session"
        status = "Exporting… (\(pipeline), \(settings.codec.rawValue)/\(settings.container.rawValue))"

        let videoComposition = makeExportVideoComposition(settings: settings)
        let audioMix = item.audioMix ?? makeAudioMix()

        if settings.prefersWriterPipeline {
            startWriterExport(
                asset: item.asset,
                settings: settings,
                destination: destination,
                videoComposition: videoComposition,
                audioMix: audioMix
            )
        } else {
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
        await rebuildComposition()
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
        let count = Self.filmstripFrameCount(for: sourceDuration)
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
            timelineSpan: timelineSpan
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
        panel.message = "Save Studio Audio Lane project"
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
        panel.message = "Open a Studio Audio Lane project"
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
        regenerateMissingVisuals()
        Task { await rebuildComposition() }
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
            audioLayoutMode: audioLayoutMode.rawValue
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
        panel.allowedContentTypes = [
            .movie, .mpeg4Movie, .quickTimeMovie, .avi,
            .audio, .mp3, .wav, .aiff, .mpeg4Audio
        ]
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        switch preferredKind {
        case .video:
            panel.message = videoClips.isEmpty ? "Open media" : "Add video to the track"
        case .audio:
            panel.message = "Add audio to the track"
        case nil:
            panel.message = "Open media"
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

    static let audioExtensions: Set<String> = [
        "wav", "mp3", "m4a", "aac", "aiff", "aif", "caf", "flac", "ogg", "wma"
    ]
    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "mpg", "mpeg", "mts", "m2ts", "webm"
    ]

    static func mediaKind(for url: URL) -> TimelineTrack.Kind {
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        // UTI fallback
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let type = values.contentType {
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
        let sourceMax = max(Self.minimumRenderedDuration, clip.sourceDuration - clip.inPoint)
        if clip.timelineStart >= videoEnd - Self.minimumRenderedDuration {
            clip.timelineStart = max(0, videoEnd - sourceMax)
        }
        let remaining = max(Self.minimumRenderedDuration, videoEnd - clip.timelineStart)
        let maxDur = max(Self.minimumRenderedDuration, clip.sourceDuration - clip.inPoint)
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
        Task { await rebuildComposition() }
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
        Task { await rebuildComposition() }
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
        Task { await rebuildComposition() }
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
        Task { await rebuildComposition() }
    }

    func toggleMuteSelectedAudio() {
        beginEdit()
        mutateSelectedAudio { $0.muted.toggle() }
        commitEdit()
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

    func trimIn(clipID: UUID, toTimelineTime time: TimeInterval) {
        beginEdit()
        if let i = audioIndex(clipID) {
            let end = audioClips[i].timelineEnd
            trimInOn(&audioClips[i], time: snapTime(time, excluding: [end]))
        } else if let i = videoIndex(clipID) {
            let end = videoClips[i].timelineEnd
            trimInOn(&videoClips[i], time: snapTime(time, excluding: [end]))
        }
        isEditingClip = true
    }

    func trimOut(clipID: UUID, toTimelineTime time: TimeInterval) {
        beginEdit()
        if let i = audioIndex(clipID) {
            let start = audioClips[i].timelineStart
            trimOutOn(&audioClips[i], time: snapTime(time, excluding: [start]))
        } else if let i = videoIndex(clipID) {
            let start = videoClips[i].timelineStart
            var clip = videoClips[i]
            trimOutOn(&clip, time: snapTime(time, excluding: [start]))
            videoClips[i] = clip
        }
        isEditingClip = true
    }

    func moveAudio(clipID: UUID, toStart time: TimeInterval) {
        moveClip(clipID: clipID, toStart: time)
    }

    func moveClip(clipID: UUID, toStart time: TimeInterval) {
        beginEdit()
        let start = snapTime(max(0, time))
        if let i = audioIndex(clipID) {
            audioClips[i].timelineStart = start
        } else if let i = videoIndex(clipID) {
            videoClips[i].timelineStart = start
        }
        isEditingClip = true
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
        var candidates: [TimeInterval] = [0, currentTime, layoutDuration]
        candidates += videoClips.flatMap { [$0.timelineStart, $0.timelineEnd] }
        candidates += audioClips.flatMap { [$0.timelineStart, $0.timelineEnd] }
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

    func zoomIn() {
        timelineZoom = min(Self.maxTimelineZoom, timelineZoom * 1.35)
    }

    func zoomOut() {
        timelineZoom = max(Self.minTimelineZoom, timelineZoom / 1.35)
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
        rebuildTask?.cancel()
        rebuildTask = Task { await rebuildComposition() }
        scheduleAutosave()
    }

    private func rebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { await rebuildComposition() }
        scheduleAutosave()
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
        applyFades()
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
        applyFades()
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
        applyFades()
        scheduleAutosave()
    }

    func setVideoVolume(_ volume: Float) {
        videoVolume = min(max(0, volume), 1)
        if let i = tracks.firstIndex(where: { $0.kind == .video }) {
            tracks[i].volume = videoVolume
        }
        applyFades()
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
        applyFades()
        isEditingClip = true
    }

    var selectedClipGain: Float {
        primarySelectedClip?.gain ?? 1
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
        return max(0.2, clip.sourceDuration - clip.inPoint)
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
        applyFades()
        scheduleAutosave()
    }

    var videoFadeIn: TimeInterval { selectedVideo?.fadeIn ?? 0 }
    var videoFadeOut: TimeInterval { selectedVideo?.fadeOut ?? 0 }
    var audioFadeIn: TimeInterval { selectedAudio?.fadeIn ?? 0 }
    var audioFadeOut: TimeInterval { selectedAudio?.fadeOut ?? 0 }
    func applyFades() {
        guard let item = player.currentItem else { return }
        item.audioMix = makeAudioMix()
        item.videoComposition = makeVideoComposition()
    }

    func presentExportSheet() {
        guard hasVideo, !isExporting else { return }
        isExportSheetPresented = true
    }

    func beginExport(with settings: ExportSettings) {
        guard !isExporting, let item = player.currentItem else { return }
        var settings = settings
        settings.sanitize()

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export Video"
        panel.nameFieldStringValue = "\(settings.fileBaseName).\(settings.container.pathExtension)"
        panel.allowedContentTypes = [settings.container.contentType]
        panel.allowsOtherFileTypes = false
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let finalURL: URL = {
            let ext = settings.container.pathExtension
            if dest.pathExtension.lowercased() == ext { return dest }
            return dest.deletingPathExtension().appendingPathExtension(ext)
        }()

        try? FileManager.default.removeItem(at: finalURL)
        isExporting = true
        exportProgress = 0
        errorMessage = nil
        exportDestinationURL = finalURL
        let pipeline = settings.prefersWriterPipeline ? "writer" : "session"
        status = "Exporting… (\(pipeline), \(settings.codec.rawValue)/\(settings.container.rawValue))"

        let videoComposition = makeExportVideoComposition(settings: settings)
        let audioMix = item.audioMix ?? makeAudioMix()

        if settings.prefersWriterPipeline {
            startWriterExport(
                asset: item.asset,
                settings: settings,
                destination: finalURL,
                videoComposition: videoComposition,
                audioMix: audioMix
            )
        } else {
            startSessionExport(
                asset: item.asset,
                settings: settings,
                destination: finalURL,
                videoComposition: videoComposition,
                audioMix: audioMix
            )
        }
    }

    func cancelExport() {
        activeExportSession?.cancelExport()
        exportWriterTask?.cancel()
        exportWriterTask = nil
        stopExportProgressTimer()
        activeExportSession = nil
        if let dest = exportDestinationURL {
            try? FileManager.default.removeItem(at: dest)
        }
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
        return cleaned.isEmpty ? "StudioAudioLane" : cleaned
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
            Task { @MainActor in
                guard let self else { return }
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
        let videoBitRate = settings.quality.approximateBitRate(pixelCount: targetSize.width * targetSize.height)
        let audioBitRate = settings.audioBitrate.bitsPerSecond ?? 192_000
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
                    videoComposition: unsafeVideoComposition,
                    audioMix: unsafeAudioMix,
                    isCancelled: { Task.isCancelled },
                    onProgress: onProgress
                )
                self.finishExport(success: true, destination: destination, message: nil)
            } catch is CancellationError {
                self.finishExport(success: false, destination: destination, message: "Export cancelled", reveal: false)
            } catch {
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
            AVSampleRateKey: 48_000
        ]

        var writerAudio: AVAssetWriterInput?
        var readerAudio: AVAssetReaderOutput?
        if let audioTrack = audioTracks.first {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
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

    private func startExportProgressTimer() {
        stopExportProgressTimer()
        exportProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.exportProgress = min(0.99, max(0, Double(self.activeExportSession?.progress ?? 0)))
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
        isExporting = false
        exportDestinationURL = nil

        var ok = success
        var failMessage = message

        if ok {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0
            if bytes < 1024 {
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

    private func makeExportVideoComposition(settings: ExportSettings) -> AVVideoComposition? {
        guard let track = mix.track(withTrackID: 1), !videoClips.isEmpty else { return nil }
        let sourceSize = exportSourceSize
        let targetSize = settings.targetSize(source: sourceSize)
        let outFrameDuration: CMTime = {
            if let seconds = settings.frameRate.seconds {
                return CMTime(seconds: seconds, preferredTimescale: 600)
            }
            return frameDuration
        }()

        let hasFades = videoClips.contains { $0.fadeIn > 0.01 || $0.fadeOut > 0.01 }
        let sizeChanged = abs(targetSize.width - sourceSize.width) > 0.5
            || abs(targetSize.height - sourceSize.height) > 0.5
        let fpsChanged = settings.frameRate != .original
        guard hasFades || sizeChanged || fpsChanged else {
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

        var instructions: [AVVideoCompositionInstructionProtocol] = []
        let timelineEnd = max(videoClips.map(\.timelineEnd).max() ?? 0.05, 0.05)

        if hasFades {
            for segment in renderSegments() {
                let clip = segment.clip
                // Instruction ranges come from the *actual* on-track segment (same rule as
                // preview), so export can't diverge from the preview or hand AVFoundation
                // overlapping instructions when clips overlap on the single composition track.
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(
                    start: CMTime(seconds: segment.at, preferredTimescale: 600),
                    duration: CMTime(seconds: segment.duration, preferredTimescale: 600)
                )
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                if sizeChanged {
                    layer.setTransform(transform, at: .zero)
                }
                let fadeIn = min(max(0, clip.fadeIn), segment.duration / 2)
                let fadeOut = min(max(0, clip.fadeOut), segment.duration - fadeIn)
                if fadeIn > 0.01 {
                    layer.setOpacityRamp(
                        fromStartOpacity: 0,
                        toEndOpacity: 1,
                        timeRange: CMTimeRange(
                            start: CMTime(seconds: segment.at, preferredTimescale: 600),
                            duration: CMTime(seconds: fadeIn, preferredTimescale: 600)
                        )
                    )
                }
                if fadeOut > 0.01 {
                    layer.setOpacityRamp(
                        fromStartOpacity: 1,
                        toEndOpacity: 0,
                        timeRange: CMTimeRange(
                            start: CMTime(seconds: segment.at + segment.duration - fadeOut, preferredTimescale: 600),
                            duration: CMTime(seconds: fadeOut, preferredTimescale: 600)
                        )
                    )
                }
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

        composition.instructions = instructions
        return composition
    }

    private func loadDefaults() async {
        isLoading = true
        status = "Opening…"
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

    private func addVideo(
        _ url: URL,
        fade: TimeInterval = 0,
        at start: TimeInterval? = nil,
        ontoTrackID: UUID? = nil
    ) async {
        if !isLoading { pushHistory() }
        let trackID = ontoTrackID ?? focusedVideoTrackID()
        let placed: TimeInterval
        if let start {
            placed = snapTime(max(0, start))
        } else {
            placed = videoClips.filter { $0.trackID == trackID }.map(\.timelineEnd).max()
                ?? videoClips.map(\.timelineEnd).max()
                ?? 0
        }
        let clip = await makeClip(url: url, start: placed, fade: fade, trackID: trackID)
        videoClips.append(clip)
        selectedClipID = clip.id
        selectedClipIDs = [clip.id]
        focusedLane = .video
        focusedTrackID = trackID
        growTimelineSpan()
        await rebuildComposition()
        scheduleFilmstrip(for: clip)
    }

    /// Places full `sourceDuration` — never silently truncates to remaining video.
    /// Use `fitSelectedMusicToVideo` when truncate is desired.
    private func addAudio(
        _ url: URL,
        fade: TimeInterval = 0,
        at start: TimeInterval? = nil,
        replaceSelected: Bool = false,
        ontoTrackID: UUID? = nil,
        recordsHistory: Bool = true,
        normalize: Bool = true
    ) async {
        let trackID = ontoTrackID ?? focusedAudioTrackID()
        if replaceSelected, let id = selectedAudio?.id, let i = audioIndex(id) {
            await replaceAudio(at: i, with: url)
            return
        }
        if recordsHistory, !isLoading { pushHistory() }

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
            let provisional = await makeClip(url: url, start: placed, fade: fade, trackID: trackID)
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
            await rebuildComposition()
            return
        }

        var clip = await makeClip(url: url, start: insertAt, fade: fade, trackID: trackID)
        // Full source — grow timeline; do NOT truncate to remaining video.
        // Floor with the rendered minimum, not the trim floor, so a short file isn't inflated.
        clip.duration = max(Self.minimumRenderedDuration, clip.sourceDuration)
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
        await rebuildComposition()
    }

    private func replaceAudio(at index: Int, with url: URL) async {
        pushHistory()
        let old = audioClips[index]
        let asset = AVURLAsset(url: url)
        let source = (try? await asset.load(.duration).seconds) ?? old.sourceDuration
        var clip = old
        clip.id = UUID()
        clip.url = url
        clip.name = url.deletingPathExtension().lastPathComponent
        clip.sourceDuration = source
        clip.inPoint = 0
        // Keep timelineStart; keep duration if it fits, else stretch to full source.
        let keepDur = min(old.duration, max(Self.minimumRenderedDuration, source))
        clip.duration = keepDur > Self.minimumRenderedDuration ? keepDur : max(Self.minimumRenderedDuration, source)
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
        await rebuildComposition()
    }

    private func makeClip(url: URL, start: TimeInterval, fade: TimeInterval, trackID: UUID) async -> MediaClip {
        let asset = AVURLAsset(url: url)
        let source = (try? await asset.load(.duration).seconds) ?? 0
        let dur = max(Self.minimumRenderedDuration, source)
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
        if any { applyFades() }
    }

    private func rebuildComposition() async {
        growTimelineSpan()
        if Task.isCancelled { return }
        do {
            let rebuiltMix = AVMutableComposition()
            musicTrackIDs = [:]
            videoAudioTrackIDs = [:]

            let videoTrack = rebuiltMix.addMutableTrack(withMediaType: .video, preferredTrackID: 1)

            // One composition track can't hold two overlapping clips — insertTimeRange pushes a
            // later clip past the previous end, inflating the player item beyond the model
            // duration (two clips at t=0 would become 2× long). Never insert before the running
            // track end: skip the overlapped head and lay only the fresh tail after it, so the
            // composition duration stays bounded by the model's max end. `renderSegments()` is
            // the single source of truth for that collapse, and `makeVideoComposition` derives
            // its instructions from the same segments so they can't disagree.
            for segment in renderSegments() {
                let asset = AVURLAsset(url: segment.clip.url)
                guard let src = try await asset.loadTracks(withMediaType: .video).first, let videoTrack else { continue }
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
                if fps > 1 {
                    frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int(fps.rounded()))))
                }
            }

            // Each video clip gets its own audio track so `makeAudioMix` can attach one
            // `AVAudioMixInputParameters` per clip (a shared track drops earlier clips' fades).
            for clip in videoClips.sorted(by: { $0.timelineStart < $1.timelineStart }) {
                let asset = AVURLAsset(url: clip.url)
                guard let src = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                guard let track = rebuiltMix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                let start = max(0, clip.timelineStart)
                let duration = max(Self.minimumRenderedDuration, min(clip.duration, clip.timelineEnd - start))
                try track.insertTimeRange(
                    CMTimeRange(start: CMTime(seconds: clip.inPoint, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600)),
                    of: src,
                    at: CMTime(seconds: start, preferredTimescale: 600)
                )
                videoAudioTrackIDs[clip.id] = track.trackID
            }
            for clip in audioClips where !clip.muted {
                let asset = AVURLAsset(url: clip.url)
                guard let src = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                // Let AVFoundation allocate the track ID; a fixed preferred ID can be
                // rejected after repeated rebuilds, which used to crash on force-unwrap.
                guard let track = rebuiltMix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try track.insertTimeRange(
                    CMTimeRange(start: CMTime(seconds: clip.inPoint, preferredTimescale: 600), duration: CMTime(seconds: max(0.05, clip.duration), preferredTimescale: 600)),
                    of: src,
                    at: CMTime(seconds: clip.timelineStart, preferredTimescale: 600)
                )
                musicTrackIDs[clip.id] = track.trackID
            }

            if Task.isCancelled { return }
            let item = AVPlayerItem(asset: rebuiltMix)
            item.audioMix = makeAudioMix()
            item.videoComposition = makeVideoComposition()
            let wasPlaying = isPlaying
            player.replaceCurrentItem(with: item)
            mix = rebuiltMix
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
            let desired = max(Self.minimumRenderedDuration, clip.duration)
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

    private func makeVideoComposition() -> AVVideoComposition? {
        guard let track = mix.track(withTrackID: 1), !videoClips.isEmpty else { return nil }
        guard videoClips.contains(where: { $0.fadeIn > 0.01 || $0.fadeOut > 0.01 }) else { return nil }
        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize.width > 1 ? renderSize : CGSize(width: 1080, height: 1920)
        composition.frameDuration = frameDuration
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        for segment in renderSegments() {
            let clip = segment.clip
            // Instruction ranges come from the *actual* on-track segment, not the model's
            // timeline range — a partially-overlapped clip only owns its rendered tail, and a
            // fully-overlapped clip isn't in `segments` at all, so no two instructions overlap.
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(
                start: CMTime(seconds: segment.at, preferredTimescale: 600),
                duration: CMTime(seconds: segment.duration, preferredTimescale: 600)
            )
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            let fadeIn = min(max(0, clip.fadeIn), segment.duration / 2)
            let fadeOut = min(max(0, clip.fadeOut), segment.duration - fadeIn)
            if fadeIn > 0.01 {
                layer.setOpacityRamp(
                    fromStartOpacity: 0,
                    toEndOpacity: 1,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: segment.at, preferredTimescale: 600),
                        duration: CMTime(seconds: fadeIn, preferredTimescale: 600)
                    )
                )
            }
            if fadeOut > 0.01 {
                layer.setOpacityRamp(
                    fromStartOpacity: 1,
                    toEndOpacity: 0,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: segment.at + segment.duration - fadeOut, preferredTimescale: 600),
                        duration: CMTime(seconds: fadeOut, preferredTimescale: 600)
                    )
                )
            }
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
        }
        composition.instructions = instructions
        return composition
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
            let shift = event.modifierFlags.contains(.shift)
            // Undo = ⌘Z (keyCode 6); redo = ⇧⌘Z (keyCode 6 + shift) or ⌘Y (keyCode 16).
            // keyCode 7 is ⌘X (Cut) — never map it to redo, so Cut stays free.
            if command && !shift && event.keyCode == 6 { self.undo(); return nil }
            if (command && shift && event.keyCode == 6) || (command && event.keyCode == 16) { self.redo(); return nil }
            if command && event.keyCode == 2 { self.duplicateSelectedClip(); return nil }
            if event.keyCode == 1 && !command { self.splitSelectedAtPlayhead(); return nil } // S (not ⌘S)
            // Option+← / Option+→ — previous / next music clip
            if option && event.keyCode == 124 { self.seekToNextMusicClip(); return nil }
            if option && event.keyCode == 123 { self.seekToPreviousMusicClip(); return nil }
            if event.keyCode == 124 { self.selectNextClip(); return nil }
            if event.keyCode == 123 { self.selectPreviousClip(); return nil }
            // I / O — mark loop in/out; L — toggle loop
            if event.keyCode == 34 && !command { self.markLoopIn(); return nil }
            if event.keyCode == 31 && !command { self.markLoopOut(); return nil }
            if event.keyCode == 37 && !command { self.toggleLoop(); return nil }
            if event.keyCode == 51 || event.keyCode == 117 {
                self.deleteSelectedClips(preferringLane: self.focusedLane)
                return nil
            }
            _ = shift // reserved; Shift+click handled in views
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
        await Task.detached(priority: .userInitiated) {
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
