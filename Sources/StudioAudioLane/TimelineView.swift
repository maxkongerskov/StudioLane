import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TimelineView: View {
    @Environment(EditorModel.self) private var model
    @State private var isDropTargeted = false
    @State private var dragKind: DragKind?
    @State private var dragOrigin: TimeInterval = 0
    @State private var dragClipID: UUID?
    @State private var lastPlayheadFollowAt: Date = .distantPast

    static let videoLaneHeight: CGFloat = 54
    static let audioLaneHeight: CGFloat = 52
    static let laneSpacing: CGFloat = 6
    static let rulerHeight: CGFloat = 18
    static let transportHeight: CGFloat = 36
    static let bottomPad: CGFloat = 6

    static func laneStackHeight(trackCount: Int) -> CGFloat {
        let count = max(trackCount, 1)
        // Approximate: treat mixed heights as average of video/audio; refined per-render below.
        return CGFloat(count) * ((videoLaneHeight + audioLaneHeight) / 2) + CGFloat(max(0, count - 1)) * laneSpacing
    }

    static func playlistContentHeight(for tracks: [TimelineTrack]) -> CGFloat {
        let lanes = tracks.reduce(CGFloat(0)) { partial, track in
            partial + (track.kind == .video ? videoLaneHeight : audioLaneHeight)
        }
        let spacing = CGFloat(max(0, tracks.count - 1)) * laneSpacing
        return rulerHeight + laneSpacing + lanes + spacing
    }

    static func timelineHeight(for tracks: [TimelineTrack]) -> CGFloat {
        transportHeight + playlistContentHeight(for: tracks) + bottomPad
    }

    /// Fallback for callers before model is available.
    static var timelineHeight: CGFloat {
        timelineHeight(for: [.defaultVideo(), .defaultMusic()])
    }

    private var playlistContentHeight: CGFloat {
        Self.playlistContentHeight(for: model.tracks)
    }

    private enum DragKind {
        case seek, videoFadeIn, videoFadeOut
        case audioMove, videoMove, videoTrimIn, videoTrimOut
        case audioTrimIn, audioTrimOut, audioFadeIn, audioFadeOut
    }

    var body: some View {
        VStack(spacing: 0) {
            transport
            playlist
        }
        .frame(height: Self.timelineHeight(for: model.tracks))
        .frame(maxWidth: .infinity)
        .clipped()
        .background(StudioTheme.bg)
    }

    private var playlist: some View {
        GeometryReader { geo in
            let viewport = max(geo.size.width, 1)
            let width = viewport * max(model.timelineZoom, 1)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: model.timelineZoom > 1.01) {
                    VStack(spacing: Self.laneSpacing) {
                        ruler(width: width)
                        ForEach(model.tracks) { track in
                            laneView(for: track, width: width)
                        }
                    }
                    .frame(width: width, height: playlistContentHeight, alignment: .top)
                    .coordinateSpace(name: "playlist")
                    .overlay(alignment: .topLeading) {
                        playhead(width: width, height: playlistContentHeight)
                    }
                    .background(alignment: .leading) {
                        ZStack(alignment: .leading) {
                            Color.clear
                                .frame(width: 1, height: 1)
                                .id("timeline-start")
                            Color.clear
                                .frame(width: 1, height: 1)
                                .id("playhead-anchor")
                                .offset(x: playheadX(width: width))
                        }
                        .frame(width: width, height: 1, alignment: .leading)
                        .allowsHitTesting(false)
                    }
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .onChange(of: model.timelineZoom) { _, _ in
                    Task { @MainActor in
                        if model.timelineZoom <= 1.01 {
                            proxy.scrollTo("timeline-start", anchor: .leading)
                        } else {
                            proxy.scrollTo("playhead-anchor", anchor: .center)
                        }
                    }
                }
                .onChange(of: model.currentTime) { _, _ in
                    followPlayheadIfNeeded(proxy: proxy, viewport: viewport, width: width)
                }
            }
            .onAppear { model.timelineViewportWidth = viewport }
            .onChange(of: geo.size.width) { _, newValue in
                model.timelineViewportWidth = max(newValue, 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, Self.bottomPad)
        .frame(height: playlistContentHeight + Self.bottomPad)
    }

    private var transport: some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                EditingToolsMenu()
                transportDivider
                TransportIconButton(systemImage: "scissors") {
                    model.splitSelectedAtPlayhead()
                }
                AddLaneMenuButton()
                TransportIconButton(systemImage: "magnet", prominent: model.isSnapEnabled) {
                    model.isSnapEnabled.toggle()
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                TransportIconButton(systemImage: "backward.end.fill") { model.goToStart() }
                TransportIconButton(systemImage: "backward.frame.fill") { model.seekToPreviousMusicClip() }
                TransportIconButton(systemImage: model.isPlaying ? "pause.fill" : "play.fill", prominent: true) {
                    model.togglePlay()
                }
                TransportIconButton(systemImage: "forward.frame.fill") { model.seekToNextMusicClip() }
                TransportIconButton(systemImage: "forward.end.fill") { model.goToEnd() }
                transportDivider
                TransportIconButton(systemImage: "repeat", prominent: model.loopEnabled) {
                    model.toggleLoop()
                }
            }

            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Text(timeLabel)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(StudioTheme.muted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                transportDivider
                TransportIconButton(systemImage: "minus.magnifyingglass") { model.zoomOut() }
                TransportIconButton(systemImage: "plus.magnifyingglass") { model.zoomIn() }
                TransportIconButton(systemImage: "arrow.down.right.and.arrow.up.left") {
                    model.zoomToFit(viewportWidth: model.timelineViewportWidth)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: Self.transportHeight)
    }

    private var transportDivider: some View {
        Divider()
            .frame(height: 16)
            .overlay(StudioTheme.hairline)
    }

    private func ruler(width: CGFloat) -> some View {
        let duration = max(model.layoutDuration, 0.25)
        let targetSpacing = max(55, width / 18)
        let rawStep = duration * targetSpacing / width
        let magnitude = pow(10, floor(log10(rawStep)))
        let step = [1, 2, 5, 10].map { magnitude * $0 }.first { $0 >= rawStep } ?? magnitude * 10
        let count = Int(duration / step) + 1
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(StudioTheme.bg)
            ForEach(0..<max(1, count), id: \.self) { index in
                let time = TimeInterval(index) * step
                let x = CGFloat(time / duration) * width
                VStack(alignment: .leading, spacing: 2) {
                    Rectangle().fill(StudioTheme.hairline).frame(width: 1, height: 5)
                    Text(format(time))
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(StudioTheme.muted)
                        .monospacedDigit()
                }
                .offset(x: max(0, min(width - 34, x + 2)))
            }
        }
        .frame(width: width, height: Self.rulerHeight)
        .contentShape(Rectangle())
        .gesture(seekGesture(width: width))
    }

    @ViewBuilder
    private func laneView(for track: TimelineTrack, width: CGFloat) -> some View {
        switch track.kind {
        case .video:
            videoLane(track: track, width: width)
        case .audio:
            audioLane(track: track, width: width)
        }
    }

    private func videoLane(track: TimelineTrack, width: CGFloat) -> some View {
        let dur = timelineDuration
        let clips = model.videoClips.filter { $0.trackID == track.id }
        let focused = model.focusedTrackID == track.id
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(StudioTheme.lane)
            if clips.isEmpty {
                Button {
                    model.focusedLane = .video
                    model.focusedTrackID = track.id
                    model.pickVideoFile(ontoTrackID: track.id)
                } label: {
                    Text("Add video")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(StudioTheme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
            } else {
                ForEach(clips) { clip in
                    let x = clipX(clip.timelineStart, duration: dur, width: width)
                    let w = clipWidth(clip.duration, duration: dur, width: width)
                    videoClipView(clip: clip, clipWidth: w, laneWidth: width)
                        .frame(width: w, height: Self.videoLaneHeight)
                        .offset(x: x)
                }
            }
        }
        .frame(width: width, height: Self.videoLaneHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(focused ? StudioTheme.accent.opacity(0.7) : StudioTheme.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.focusedLane = .video
            model.focusedTrackID = track.id
        }
        .contextMenu {
            Button("Delete Video Lane", role: .destructive) { model.deleteTrack(track.id) }
            if model.videoTracks.count == 1 {
                Button("Clear Video Clips", role: .destructive) { model.deleteVideoTrack() }
                    .disabled(clips.isEmpty)
            }
        }
        .onDrop(of: [.fileURL, .movie, .audio, .audiovisualContent], delegate: TimelineDropDelegate(
            model: model,
            isTargeted: .constant(false),
            laneWidth: { width },
            preferKind: .video,
            ontoTrackID: track.id
        ))
    }

    private func videoClipView(clip: MediaClip, clipWidth: CGFloat, laneWidth: CGFloat) -> some View {
        let clipDur = max(clip.duration, 0.25)
        let fadeInW = min(clipWidth / 2, CGFloat(clip.fadeIn / clipDur) * clipWidth)
        let fadeOutW = min(clipWidth / 2, CGFloat(clip.fadeOut / clipDur) * clipWidth)
        let selected = model.isClipSelected(clip.id)
        return ZStack(alignment: .leading) {
            if let frames = model.filmstrips[clip.id], !frames.isEmpty {
                FilmstripLane(
                    images: frames,
                    inPoint: clip.inPoint,
                    duration: clip.duration,
                    sourceDuration: clip.sourceDuration
                )
            } else {
                StudioTheme.lane
            }
            FadeTriangles(fadeInWidth: fadeInW, fadeOutWidth: fadeOutW, color: Color.black.opacity(0.55))
            Text(clip.displayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.black.opacity(0.4), in: Capsule())
                .padding(.leading, 8)
            FadeHandle(isAudio: false)
                .offset(x: max(0, fadeInW - 4))
                .highPriorityGesture(fadeDrag(kind: .videoFadeIn, clipID: clip.id, width: laneWidth, origin: { clip.fadeIn }) { model.setVideoFadeIn($0) })
            FadeHandle(isAudio: false)
                .offset(x: max(0, clipWidth - fadeOutW - 8))
                .highPriorityGesture(fadeDrag(kind: .videoFadeOut, clipID: clip.id, width: laneWidth, origin: { clip.fadeOut }) { model.setVideoFadeOut($0) })
            TrimEdge()
                .frame(width: 14)
                .contentShape(Rectangle())
                .highPriorityGesture(trimDrag(kind: .videoTrimIn, clipID: clip.id, laneWidth: laneWidth, origin: { clip.timelineStart }) { time in
                    model.trimIn(clipID: clip.id, toTimelineTime: time)
                })
            TrimEdge()
                .frame(width: 14)
                .contentShape(Rectangle())
                .offset(x: clipWidth - 14)
                .highPriorityGesture(trimDrag(kind: .videoTrimOut, clipID: clip.id, laneWidth: laneWidth, origin: { clip.timelineEnd }) { time in
                    model.trimOut(clipID: clip.id, toTimelineTime: time)
                })
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(selected ? StudioTheme.accent : Color.white.opacity(0.12), lineWidth: selected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .gesture(clipMoveGesture(kind: .videoMove, clipID: clip.id, laneWidth: laneWidth, origin: clip.timelineStart, isVideo: true))
        .onTapGesture(count: 2) { showClipMenu(clipID: clip.id) }
        .onTapGesture {
            model.selectVideoClip(clip.id, extending: NSEvent.modifierFlags.contains(.shift))
        }
    }

    private func audioLane(track: TimelineTrack, width: CGFloat) -> some View {
        let dur = timelineDuration
        let clips = model.audioClips.filter { $0.trackID == track.id }
        let focused = model.focusedTrackID == track.id
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDropTargeted && focused ? StudioTheme.audioLaneSelected : StudioTheme.audioLane.opacity(0.55))
            if clips.isEmpty {
                Button {
                    model.focusedLane = .audio
                    model.focusedTrackID = track.id
                    model.pickAudioFile(ontoTrackID: track.id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                        Text(track.name == "Music" ? "Add music" : "Add audio")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioTheme.audioWave.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
            } else {
                ForEach(clips) { clip in
                    let x = clipX(clip.timelineStart, duration: dur, width: width)
                    let w = clipWidth(clip.duration, duration: dur, width: width)
                    audioClip(clip: clip, clipWidth: w, laneWidth: width, wave: StudioTheme.audioWave, fill: StudioTheme.audioLane)
                        .frame(width: w, height: Self.audioLaneHeight)
                        .offset(x: x)
                }
                if model.audioLayoutMode == .playlist {
                    ForEach(playlistJunctions(for: track.id, duration: dur, width: width), id: \.id) { junction in
                        Capsule()
                            .fill(StudioTheme.audioWave.opacity(0.55))
                            .frame(width: 3, height: Self.audioLaneHeight - 10)
                            .offset(x: junction.x - 1.5, y: 5)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(width: width, height: Self.audioLaneHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(focused ? StudioTheme.audioWave.opacity(0.7) : StudioTheme.hairline, lineWidth: 1)
        )
        .onTapGesture {
            model.focusedLane = .audio
            model.focusedTrackID = track.id
        }
        .contextMenu {
            Button("Delete Audio Lane", role: .destructive) { model.deleteTrack(track.id) }
            if model.audioTracks.count == 1 {
                Button("Clear Music Clips", role: .destructive) { model.deleteMusicTrack() }
                    .disabled(clips.isEmpty)
            }
        }
        .onDrop(of: [.fileURL, .movie, .audio, .audiovisualContent], delegate: TimelineDropDelegate(
            model: model,
            isTargeted: $isDropTargeted,
            laneWidth: { width },
            preferKind: .audio,
            ontoTrackID: track.id
        ))
    }

    private func audioClip(clip: MediaClip, clipWidth: CGFloat, laneWidth: CGFloat, wave: Color, fill: Color) -> some View {
        let clipDur = max(clip.duration, 0.25)
        let fadeInW = min(clipWidth / 2, CGFloat(clip.fadeIn / clipDur) * clipWidth)
        let fadeOutW = min(clipWidth / 2, CGFloat(clip.fadeOut / clipDur) * clipWidth)
        let selected = model.isClipSelected(clip.id)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(fill)
            WaveformView(
                    samples: clip.waveform,
                    inPoint: clip.inPoint,
                    duration: clip.duration,
                    sourceDuration: clip.sourceDuration,
                    color: wave
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            FadeTriangles(fadeInWidth: fadeInW, fadeOutWidth: fadeOutW, color: StudioTheme.audioFade)
            Text(clip.muted ? "Muted" : clip.displayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(wave)
                .lineLimit(1)
                .padding(.leading, 10)
            TrimEdge()
                .frame(width: 14)
                .contentShape(Rectangle())
                .highPriorityGesture(trimDrag(kind: .audioTrimIn, clipID: clip.id, laneWidth: laneWidth, origin: { clip.timelineStart }) { time in
                    model.trimIn(clipID: clip.id, toTimelineTime: time)
                })
            TrimEdge()
                .frame(width: 14)
                .contentShape(Rectangle())
                .offset(x: clipWidth - 14)
                .highPriorityGesture(trimDrag(kind: .audioTrimOut, clipID: clip.id, laneWidth: laneWidth, origin: { clip.timelineEnd }) { time in
                    model.trimOut(clipID: clip.id, toTimelineTime: time)
                })
            FadeHandle(isAudio: true)
                .offset(x: max(0, fadeInW - 4))
                .highPriorityGesture(fadeDrag(kind: .audioFadeIn, clipID: clip.id, width: laneWidth, origin: { clip.fadeIn }) { time in
                    model.setAudioFadeIn(time)
                })
            FadeHandle(isAudio: true)
                .offset(x: max(0, clipWidth - fadeOutW - 8))
                .highPriorityGesture(fadeDrag(kind: .audioFadeOut, clipID: clip.id, width: laneWidth, origin: { clip.fadeOut }) { time in
                    model.setAudioFadeOut(time)
                })
        }
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(selected ? wave : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .gesture(clipMoveGesture(kind: .audioMove, clipID: clip.id, laneWidth: laneWidth, origin: clip.timelineStart, isVideo: false))
        .onTapGesture(count: 2) { showClipMenu(clipID: clip.id) }
        .onTapGesture {
            model.selectAudioClip(clip.id, extending: NSEvent.modifierFlags.contains(.shift))
        }
    }

    private func clipMoveGesture(kind: DragKind, clipID: UUID, laneWidth: CGFloat, origin: TimeInterval, isVideo: Bool) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("playlist"))
            .onChanged { value in
                if dragKind == nil {
                    dragKind = kind
                    dragClipID = clipID
                    dragOrigin = origin
                    if isVideo {
                        model.selectVideoClip(clipID)
                    } else {
                        model.selectAudioClip(clipID)
                    }
                }
                guard dragKind == kind, dragClipID == clipID, laneWidth > 0 else { return }
                let dt = Double(value.translation.width / laneWidth) * model.layoutDuration
                model.moveClip(clipID: clipID, toStart: dragOrigin + dt)
            }
            .onEnded { _ in
                if dragKind == kind { model.commitEdit() }
                dragKind = nil
                dragClipID = nil
            }
    }

    private func fadeDrag(kind: DragKind, clipID: UUID, width: CGFloat, origin: @escaping () -> TimeInterval, apply: @escaping (TimeInterval) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("playlist"))
            .onChanged { value in
                if dragKind == nil {
                    dragKind = kind
                    dragClipID = clipID
                    dragOrigin = origin()
                    if kind == .videoFadeIn || kind == .videoFadeOut {
                        model.selectVideoClip(clipID)
                    } else {
                        model.selectAudioClip(clipID)
                    }
                }
                guard dragKind == kind, dragClipID == clipID, width > 0 else { return }
                let dt = Double(value.translation.width / width) * model.layoutDuration
                switch kind {
                case .videoFadeIn, .audioFadeIn:
                    apply(dragOrigin + dt)
                case .videoFadeOut, .audioFadeOut:
                    apply(dragOrigin - dt)
                default:
                    break
                }
            }
            .onEnded { _ in
                // A fade drag leaves isEditingClip true via beginEdit(); commit so the next
                // trim/length/gain pushes its own history instead of merging into this fade.
                if dragKind == kind { model.commitEdit() }
                dragKind = nil
                dragClipID = nil
            }
    }

    private func trimDrag(kind: DragKind, clipID: UUID, laneWidth: CGFloat, origin: @escaping () -> TimeInterval, apply: @escaping (TimeInterval) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("playlist"))
            .onChanged { value in
                if dragKind == nil {
                    dragKind = kind
                    dragClipID = clipID
                    dragOrigin = origin()
                    if model.videoClips.contains(where: { $0.id == clipID }) {
                        model.selectVideoClip(clipID)
                    } else {
                        model.selectAudioClip(clipID)
                    }
                }
                guard dragKind == kind, dragClipID == clipID, laneWidth > 0 else { return }
                let time = Double(value.location.x / laneWidth) * model.layoutDuration
                apply(time)
            }
            .onEnded { _ in
                if dragKind == kind { model.commitEdit() }
                dragKind = nil
                dragClipID = nil
            }
    }

    private func playhead(width: CGFloat, height: CGFloat) -> some View {
        let x = playheadX(width: width)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(StudioTheme.playhead)
                .frame(width: 1.5, height: height)
            Circle()
                .fill(StudioTheme.playhead)
                .frame(width: 8, height: 8)
                .offset(x: -3.25, y: -3)
        }
        .offset(x: x)
        .allowsHitTesting(false)
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("playlist"))
            .onChanged { value in
                if dragKind == nil { dragKind = .seek }
                guard dragKind == .seek, width > 0 else { return }
                model.seek(to: (value.location.x / width) * model.layoutDuration)
            }
            .onEnded { _ in
                if dragKind == .seek { dragKind = nil }
            }
    }

    private func playheadX(width: CGFloat) -> CGFloat {
        let span = model.layoutDuration
        guard span > 0 else { return 0 }
        return min(max(0, CGFloat(model.currentTime / span) * width), width)
    }

    private var timelineDuration: TimeInterval {
        model.layoutDuration
    }

    private func clipX(_ start: TimeInterval, duration: TimeInterval, width: CGFloat) -> CGFloat {
        CGFloat(start / duration) * width
    }

    private func clipWidth(_ span: TimeInterval, duration: TimeInterval, width: CGFloat) -> CGFloat {
        max(2, CGFloat(span / duration) * width)
    }

    private var timeLabel: String {
        "\(format(model.currentTime))  /  \(format(model.duration))"
    }

    private func format(_ t: TimeInterval) -> String {
        let s = max(0, t)
        let m = Int(s) / 60
        let r = Int(s) % 60
        let f = Int((s.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", m, r, f)
    }

    private func showClipMenu(clipID: UUID) {
        if model.videoClips.contains(where: { $0.id == clipID }) {
            model.selectVideoClip(clipID)
        } else {
            model.selectAudioClip(clipID)
        }
        popupMenu([
            popupMenuItem("Delete Clip", destructive: true) {
                model.deleteClip(clipID: clipID)
            }
        ])
    }

    private func popupMenuItem(_ title: String, destructive: Bool = false, handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(PopupMenuAction.fire), keyEquivalent: "")
        let action = PopupMenuAction(handler)
        item.target = action
        item.representedObject = action
        if destructive {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.systemRed]
            )
        }
        return item
    }

    private func popupMenu(_ items: [NSMenuItem]) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let content = window.contentView else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items { menu.addItem(item) }
        menu.popUp(positioning: nil, at: window.convertPoint(fromScreen: NSEvent.mouseLocation), in: content)
    }

    private func followPlayheadIfNeeded(proxy: ScrollViewProxy, viewport: CGFloat, width: CGFloat) {
        guard model.isPlaying, model.timelineZoom > 1.01, viewport > 0, width > viewport else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPlayheadFollowAt) > 0.12 else { return }
        lastPlayheadFollowAt = now
        // Throttled follow while playing zoomed — keeps playhead in the viewport.
        proxy.scrollTo("playhead-anchor", anchor: UnitPoint(x: 0.35, y: 0.5))
    }

    private struct JunctionMark: Identifiable {
        let id: String
        let x: CGFloat
    }

    private func playlistJunctions(for trackID: UUID, duration: TimeInterval, width: CGFloat) -> [JunctionMark] {
        let ordered = model.audioClips.filter { $0.trackID == trackID }.sorted { $0.timelineStart < $1.timelineStart }
        guard ordered.count >= 2, duration > 0 else { return [] }
        var marks: [JunctionMark] = []
        for i in 0..<(ordered.count - 1) {
            let gap = ordered[i + 1].timelineStart - ordered[i].timelineEnd
            if abs(gap) <= EditorModel.playlistSnapThreshold {
                let x = clipX(ordered[i].timelineEnd, duration: duration, width: width)
                marks.append(JunctionMark(id: "\(ordered[i].id)-\(ordered[i + 1].id)", x: x))
            }
        }
        return marks
    }
}

final class DropURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL] = []
    func append(_ url: URL) {
        lock.lock(); values.append(url); lock.unlock()
    }
    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

struct TimelineDropDelegate: DropDelegate {
    let model: EditorModel
    @Binding var isTargeted: Bool
    let laneWidth: () -> CGFloat
    var preferKind: TimelineTrack.Kind
    var ontoTrackID: UUID?

    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL, .audio, .movie, .audiovisualContent])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let width = max(laneWidth(), 1)
        let x = max(0, info.location.x)
        let time = Double(min(x, width) / width) * model.layoutDuration
        // Prefer fileURL providers; fall back to any conforming provider.
        var providers = info.itemProviders(for: [.fileURL])
        if providers.isEmpty {
            providers = info.itemProviders(for: [.movie, .audio, .audiovisualContent])
        }
        guard !providers.isEmpty else { return false }

        let group = DispatchGroup()
        let box = DropURLBox()

        for provider in providers {
            group.enter()
            Self.loadFileURL(from: provider) { url in
                if let url { box.append(url) }
                group.leave()
            }
        }

        let trackID = ontoTrackID
        let kind = preferKind
        group.notify(queue: .main) {
            let urls = box.urls
            guard !urls.isEmpty else { return }
            model.acceptDroppedFiles(urls, at: time, ontoTrackID: trackID, preferKind: kind)
        }
        return true
    }

    private static func loadFileURL(from provider: NSItemProvider, completion: @escaping @Sendable (URL?) -> Void) {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                completion(Self.parseURL(item))
            }
            return
        }
        // Some drops only expose the concrete media UTI; still try fileURL data representation.
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            if let data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                completion(url)
            } else {
                completion(nil)
            }
        }
    }

    nonisolated private static func parseURL(_ item: (any NSSecureCoding)?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let str = item as? String { return URL(fileURLWithPath: str) }
        return nil
    }
}

struct AddLaneMenuButton: View {
    @Environment(EditorModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Menu {
            Button("Add Audio Lane") { model.addLane(kind: .audio) }
            Button("Add Video Lane") { model.addLane(kind: .video) }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(StudioTheme.text.opacity(hovering ? 1 : 0.62))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.11 : 0))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Add lane")
        .accessibilityLabel("Add lane")
        .onHover { hovering = $0 }
    }
}

final class PopupMenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func fire() {
        handler()
    }
}

struct EditingToolsMenu: View {
    @Environment(EditorModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Menu {
            Button("Cut at Playhead") { model.splitSelectedAtPlayhead() }
            Button("Duplicate Clip") { model.duplicateSelectedClip() }
            Divider()
            Button("Replace Music…") { model.replaceSelectedMusic() }
                .disabled(model.selectedAudio == nil)
            Button("Fit to Video") { model.fitSelectedMusicToVideo() }
                .disabled(model.selectedAudio == nil || !model.hasVideo)
            Button("Fill from Files…") { model.fillMusicFromFiles() }
            Divider()
            Picker("Music Layout", selection: Binding(
                get: { model.audioLayoutMode },
                set: { model.setAudioLayoutMode($0) }
            )) {
                Text("Playlist").tag(EditorModel.AudioLayoutMode.playlist)
                Text("Layer").tag(EditorModel.AudioLayoutMode.layer)
            }
            Toggle(isOn: Binding(
                get: { model.isDuckingMusic },
                set: { model.setDuckingMusic($0) }
            )) {
                Text("Duck Music")
            }
            Divider()
            Button("Mark In") { model.markLoopIn() }
            Button("Mark Out") { model.markLoopOut() }
            Button("Loop Selected Clips") { model.loopSelectedClips() }
            Toggle(isOn: Binding(
                get: { model.loopEnabled },
                set: { _ in model.toggleLoop() }
            )) {
                Text("Loop Region")
            }
            Divider()
            Button("Delete Selected", role: .destructive) {
                model.deleteSelectedClips(preferringLane: model.focusedLane)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                Text("Tools")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(StudioTheme.text.opacity(hovering ? 1 : 0.72))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.11 : 0.05))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
    }
}

struct FadeTriangles: View {
    var fadeInWidth: CGFloat
    var fadeOutWidth: CGFloat
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Path { path in
                if fadeInWidth > 1 {
                    path.move(to: .zero)
                    path.addLine(to: CGPoint(x: 0, y: h))
                    path.addLine(to: CGPoint(x: min(fadeInWidth, w), y: 0))
                    path.closeSubpath()
                }
                if fadeOutWidth > 1 {
                    path.move(to: CGPoint(x: w, y: 0))
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.addLine(to: CGPoint(x: max(0, w - fadeOutWidth), y: 0))
                    path.closeSubpath()
                }
            }
            .fill(color)
        }
        .allowsHitTesting(false)
    }
}

struct FadeHandle: View {
    var isAudio: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(isAudio ? StudioTheme.audioWave : Color.white)
            .frame(width: 8, height: 22)
            .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
            .overlay {
                VStack(spacing: 2) {
                    Capsule().fill(Color.black.opacity(isAudio ? 0.35 : 0.25)).frame(width: 1.5, height: 8)
                    Capsule().fill(Color.black.opacity(isAudio ? 0.35 : 0.25)).frame(width: 1.5, height: 8)
                }
            }
            .offset(y: 16)
    }
}

struct TrimEdge: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(Color.white.opacity(0.85))
            .frame(width: 5, height: 36)
            .offset(y: 8)
    }
}

struct FilmstripLane: View {
    let images: [CGImage]
    /// Media in-point (seconds into source) for the left edge of the clip.
    var inPoint: TimeInterval = 0
    /// Visible media duration mapped across the clip width.
    var duration: TimeInterval = 0
    /// Full source length that `images` covers (0...sourceDuration).
    var sourceDuration: TimeInterval = 0

    var body: some View {
        Canvas { context, size in
            guard !images.isEmpty, size.width > 0, size.height > 0 else { return }
            let source = max(sourceDuration, 0.0001)
            let startFrac = min(max(inPoint / source, 0), 1)
            let endFrac = min(max((inPoint + max(duration, 0.0001)) / source, startFrac), 1)
            guard endFrac > startFrac else { return }
            let startIndex = Int((startFrac * Double(images.count)).rounded(.down))
            let endIndex = min(images.count, max(startIndex + 1, Int((endFrac * Double(images.count)).rounded(.up))))
            let slice = Array(images[startIndex..<endIndex])
            guard !slice.isEmpty else { return }
            // Stretch only the source window across the clip; thumb density tracks timeline time.
            let cellWidth = size.width / CGFloat(slice.count)
            for (index, cg) in slice.enumerated() {
                let cellRect = CGRect(
                    x: CGFloat(index) * cellWidth,
                    y: 0,
                    width: cellWidth,
                    height: size.height
                )
                var layer = context
                layer.clip(to: Path(cellRect))
                let nsImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                let resolved = layer.resolve(Image(nsImage: nsImage))
                layer.draw(resolved, in: fillRect(for: CGSize(width: cg.width, height: cg.height), in: cellRect))
            }
        }
        .allowsHitTesting(false)
    }

    private func fillRect(for imageSize: CGSize, in cell: CGRect) -> CGRect {
        guard imageSize.height > 0, imageSize.width > 0 else { return cell }
        let imageAspect = imageSize.width / imageSize.height
        let cellAspect = cell.width / cell.height
        if imageAspect > cellAspect {
            let width = cell.height * imageAspect
            return CGRect(x: cell.midX - width / 2, y: cell.minY, width: width, height: cell.height)
        }
        let height = cell.width / imageAspect
        return CGRect(x: cell.minX, y: cell.midY - height / 2, width: cell.width, height: height)
    }
}

struct WaveformView: View {
    let samples: [Float]
    /// Media in-point (seconds into source) for the left edge of the clip.
    var inPoint: TimeInterval = 0
    /// Visible media duration mapped across the clip width.
    var duration: TimeInterval = 0
    /// Full source length that `samples` covers (0...sourceDuration).
    var sourceDuration: TimeInterval = 0
    var color: Color = StudioTheme.audioWave

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1, size.width > 1 else { return }
            let source = max(sourceDuration, 0.0001)
            let startFrac = min(max(inPoint / source, 0), 1)
            let endFrac = min(max((inPoint + max(duration, 0.0001)) / source, startFrac), 1)
            guard endFrac > startFrac else { return }
            let startIndex = Int((startFrac * Double(samples.count)).rounded(.down))
            let endIndex = min(samples.count, max(startIndex + 1, Int((endFrac * Double(samples.count)).rounded(.up))))
            let slice = samples[startIndex..<endIndex]
            guard !slice.isEmpty else { return }
            let mid = size.height / 2
            // Stretch only the source window across the clip; bar density tracks timeline time, not "fit all peaks".
            let step = size.width / CGFloat(slice.count)
            var path = Path()
            for (offset, sample) in slice.enumerated() {
                let h = max(1, CGFloat(sample) * (size.height * 0.86))
                let x = CGFloat(offset) * step
                path.addRect(CGRect(x: x, y: mid - h / 2, width: max(0.7, step * 0.72), height: h))
            }
            context.fill(path, with: .color(color.opacity(0.95)))
        }
        .allowsHitTesting(false)
    }
}
