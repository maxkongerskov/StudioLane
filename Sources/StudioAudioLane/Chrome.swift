import AppKit
import SwiftUI

enum StudioFormat {
    static func timecode(_ t: TimeInterval) -> String {
        let s = max(0, t)
        let m = Int(s) / 60
        let r = Int(s) % 60
        let f = Int((s.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", m, r, f)
    }
}

enum InspectorValueFormat {
    case seconds, percent

    func string(_ value: TimeInterval) -> String {
        switch self {
        case .seconds: String(format: "%.1fs", value)
        case .percent: "\(Int((value * 100).rounded()))%"
        }
    }
}

struct WindowConfigurator: NSViewRepresentable {
    var title: String = "Studio Audio Lane"

    func makeNSView(context: Context) -> WindowHookView {
        WindowHookView()
    }

    func updateNSView(_ view: WindowHookView, context: Context) {
        view.apply(title: title)
    }
}

final class WindowHookView: NSView {
    private var didConfigure = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configure()
    }

    func apply(title: String) {
        window?.title = title
        configure()
    }

    private func configure() {
        guard let window, !didConfigure else { return }
        didConfigure = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(srgbRed: 0.086, green: 0.086, blue: 0.090, alpha: 1)
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        window.toolbarStyle = .unified
    }
}

struct TitleBarDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> TitleBarDragView { TitleBarDragView() }
    func updateNSView(_ view: TitleBarDragView, context: Context) {}
}

final class TitleBarDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct TitleBar: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        ZStack {
            TitleBarDragRegion()
            Text(titleText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(StudioTheme.text.opacity(0.86))
                .lineLimit(1)
                .padding(.horizontal, 196)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
            HStack(spacing: 8) {
                TitleBarOpenButton {
                    model.pickMediaFile()
                }
                Spacer(minLength: 0)
                TitleBarExportButton(
                    title: model.isExporting ? "Exporting…" : "Export",
                    enabled: exportEnabled
                ) {
                    model.presentExportSheet()
                }
            }
            .padding(.trailing, 14)
        }
        .padding(.leading, 78)
        .frame(height: 48)
        .background(StudioTheme.bg)
    }

    private var exportEnabled: Bool {
        !model.isExporting && model.hasVideo
    }

    private var titleText: String {
        if model.isLoading {
            return model.status.isEmpty ? "Opening…" : model.status
        }
        if !model.status.isEmpty {
            return model.status
        }
        return model.projectDisplayName
    }
}

struct InspectorPane: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(StudioTheme.hairline).frame(height: 1)
            if model.isLoading {
                loading
            } else if !model.hasVideo {
                emptyProject
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        tracksSection
                        Rectangle()
                            .fill(StudioTheme.hairline)
                            .frame(height: 1)
                            .padding(.top, 16)
                            .padding(.bottom, 14)
                        clipSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: 248)
        .background(StudioTheme.inspector)
    }

    private var header: some View {
        Text("Studio Audio Lane")
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(StudioTheme.text.opacity(0.45))
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .padding(.horizontal, 14)
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(StudioTheme.text.opacity(0.7))
            Text(model.status.isEmpty ? "Opening…" : model.status)
                .font(.system(size: 12))
                .foregroundStyle(StudioTheme.muted)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyProject: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No clip")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(StudioTheme.text.opacity(0.82))
            Text("Drop media on the preview, or open files.")
                .font(.system(size: 12))
                .foregroundStyle(StudioTheme.text.opacity(0.42))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Tracks

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Tracks")
            ForEach(model.tracks) { track in
                let accent = track.kind == .video ? StudioTheme.accent : StudioTheme.audioWave
                let highlighted = model.isTrackHighlighted(track.id)
                TrackRow(
                    name: track.name,
                    accent: accent,
                    isSelected: highlighted,
                    onRename: { model.renameTrack(track.id, to: $0) }
                ) {
                    selectTrack(track)
                } volume: {
                    TrackVolumeSlider(
                        value: Binding(
                            get: { Double(model.track(id: track.id)?.volume ?? track.volume) },
                            set: { model.setTrackVolume(track.id, Float($0)) }
                        ),
                        accent: accent
                    )
                }
            }
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                AddChipButton(title: "Add media", systemImage: "plus") {
                    model.pickMediaFile()
                }
                AddChipButton(
                    title: model.audioLayoutMode == .playlist ? "Playlist" : "Layer",
                    systemImage: "rectangle.stack"
                ) {
                    model.toggleAudioLayoutMode()
                }
                AddChipButton(title: "Fill from Files…", systemImage: "folder") {
                    model.fillMusicFromFiles()
                }
                AddChipButton(
                    title: "Replace…",
                    systemImage: "arrow.triangle.2.circlepath",
                    enabled: model.selectedAudio != nil
                ) {
                    model.replaceSelectedMusic()
                }
            }
            .padding(.top, 4)
        }
    }

    private func selectTrack(_ track: TimelineTrack) {
        let extending = NSEvent.modifierFlags.contains(.shift)
        model.selectTrack(track.id, extending: extending)
    }

    private func selectLane(_ lane: EditorModel.Lane) {
        model.focusedLane = lane
        switch lane {
        case .video:
            model.focusedTrackID = model.focusedVideoTrackID()
            if let id = model.selectedVideo?.id {
                model.selectVideoClip(id)
            }
        case .audio:
            model.focusedTrackID = model.focusedAudioTrackID()
            if let id = model.selectedAudio?.id {
                model.selectAudioClip(id)
            }
        }
    }

    // MARK: - Selected clip

    private var clipSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Selected clip")
            laneSegmented
            if let clip = selectedClip {
                identity(for: clip)
                clipFields
                actionRow
            } else {
                Text("Select a clip on the timeline.")
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTheme.text.opacity(0.42))
                    .padding(.top, 2)
            }
        }
    }

    private var laneSegmented: some View {
        Group {
            if model.selectedClipsMixedKinds {
                Text("Mixed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StudioTheme.text.opacity(0.72))
                    .frame(maxWidth: .infinity, minHeight: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .padding(2)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            } else {
                HStack(spacing: 2) {
                    segmentButton("Video", lane: .video)
                    segmentButton("Music", lane: .audio)
                }
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
            }
        }
    }

    private func segmentButton(_ title: String, lane: EditorModel.Lane) -> some View {
        let selected = model.focusedLane == lane
        return Button {
            selectLane(lane)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? StudioTheme.text : StudioTheme.text.opacity(0.5))
                .frame(maxWidth: .infinity, minHeight: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.10) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private var selectedClip: MediaClip? {
        if let primary = model.primarySelectedClip {
            return primary
        }
        switch model.focusedLane {
        case .video: return model.selectedVideo
        case .audio: return model.selectedAudio
        }
    }

    private var inspectorAccent: Color {
        if model.selectedClipsMixedKinds { return Color.white.opacity(0.85) }
        return model.focusedLane == .audio ? StudioTheme.audioWave : StudioTheme.accent
    }

    private func identity(for clip: MediaClip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(clip.displayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(StudioTheme.text.opacity(0.94))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if model.selectedClipIDs.count > 1 {
                Text("\(model.selectedClipIDs.count) clips selected · editing all")
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.text.opacity(0.45))
            } else if model.inspectorValuesAreMixed {
                Text("Mixed values")
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.text.opacity(0.45))
            }
            HStack(spacing: 6) {
                Text("\(StudioFormat.timecode(clip.timelineStart))  –  \(StudioFormat.timecode(clip.timelineEnd))")
                Text("·")
                    .foregroundStyle(StudioTheme.text.opacity(0.22))
                Text(StudioFormat.timecode(clip.duration))
            }
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(StudioTheme.text.opacity(0.42))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
    }

    @ViewBuilder
    private var clipFields: some View {
        if selectedClip != nil {
            let accent = inspectorAccent
            parameterStack {
                ParameterSlider(
                    title: "Fade in",
                    value: Binding(get: { model.inspectorFadeIn }, set: { model.setSelectedFadeIn($0) }),
                    upper: fadeUpper(current: model.inspectorFadeIn, clipMax: model.inspectorMaxFadeIn),
                    format: .seconds,
                    accent: accent,
                    onEditingEnded: { model.commitEdit() }
                )
                ParameterSlider(
                    title: "Fade out",
                    value: Binding(get: { model.inspectorFadeOut }, set: { model.setSelectedFadeOut($0) }),
                    upper: fadeUpper(current: model.inspectorFadeOut, clipMax: model.inspectorMaxFadeOut),
                    format: .seconds,
                    accent: accent,
                    onEditingEnded: { model.commitEdit() }
                )
                ParameterSlider(
                    title: "Length",
                    value: Binding(
                        get: { model.inspectorLength },
                        set: { model.setClipLength($0) }
                    ),
                    upper: model.inspectorMaxLength,
                    format: .seconds,
                    accent: accent,
                    onEditingEnded: { model.commitEdit() }
                )
                ParameterSlider(
                    title: "Gain",
                    value: Binding(
                        get: { TimeInterval(model.selectedClipGain) },
                        set: { model.setSelectedClipGain(Float($0)) }
                    ),
                    upper: 1,
                    format: .percent,
                    accent: accent,
                    onEditingEnded: { model.commitEdit() }
                )
            }
        }
    }

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Type-specific actions when selection is audio-only (or focused audio without mixed kinds).
            if !model.selectedClipsMixedKinds, model.focusedLane == .audio || model.selectedAudio != nil && model.selectedVideo == nil {
                HStack(spacing: 8) {
                    if let clip = model.selectedAudio ?? model.primarySelectedClip, model.audioClips.contains(where: { $0.id == clip.id }) {
                        ActionChipButton(title: clip.muted ? "Unmute" : "Mute", kind: clip.muted ? .danger : .normal) {
                            model.toggleMuteSelectedAudio()
                        }
                    }
                    ActionChipButton(title: "Replace…", kind: .normal) {
                        model.replaceSelectedMusic()
                    }
                    ActionChipButton(title: "Fit to Video", kind: .normal) {
                        model.fitSelectedMusicToVideo()
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ActionChipButton(title: model.selectedClipIDs.count > 1 ? "Delete selected" : "Delete clip", kind: .danger) {
                    model.deleteSelectedClips(preferringLane: model.focusedLane)
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(StudioTheme.text.opacity(0.38))
    }

    private func parameterStack<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
    }

    private func fadeUpper(current: TimeInterval, clipMax: TimeInterval) -> TimeInterval {
        // Range is the clip's max fade. Floor 0.12 so a tiny clip still has a grabable
        // track; include current so a value already past clipMax doesn't sit past 100%.
        max(0.12, max(0, clipMax), current)
    }
}

struct TrackRow<Volume: View>: View {
    let name: String
    let accent: Color
    let isSelected: Bool
    var onRename: ((String) -> Void)? = nil
    let select: () -> Void
    var volume: Volume
    @State private var hovering = false
    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    init(
        name: String,
        accent: Color,
        isSelected: Bool,
        onRename: ((String) -> Void)? = nil,
        select: @escaping () -> Void,
        @ViewBuilder volume: () -> Volume
    ) {
        self.name = name
        self.accent = accent
        self.isSelected = isSelected
        self.onRename = onRename
        self.select = select
        self.volume = volume()
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(accent)
                .frame(width: 6, height: 6)
            if isRenaming {
                TextField("Track name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioTheme.text.opacity(0.95))
                    .focused($nameFieldFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { cancelRename() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioTheme.text.opacity(isSelected ? 0.95 : 0.68))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        beginRename()
                    }
            }
            if !isRenaming {
                volume
                    .frame(width: 96)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(isSelected ? 0.05 : (hovering ? 0.04 : 0)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isSelected ? accent.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if !isRenaming { select() }
        }
        .onChange(of: nameFieldFocused) { _, focused in
            if isRenaming && !focused {
                commitRename()
            }
        }
        .onChange(of: name) { _, newName in
            if !isRenaming {
                draftName = newName
            }
        }
    }

    private func beginRename() {
        guard onRename != nil else { return }
        draftName = name
        isRenaming = true
        DispatchQueue.main.async {
            nameFieldFocused = true
        }
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        nameFieldFocused = false
        onRename?(draftName)
    }

    private func cancelRename() {
        isRenaming = false
        nameFieldFocused = false
        draftName = name
    }
}

struct TrackVolumeSlider: View {
    @Binding var value: Double
    var accent: Color = Color.white.opacity(0.85)

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let t = CGFloat(min(max(value, 0), 1))
            let thumb: CGFloat = 9
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 3)
                Capsule(style: .continuous)
                    .fill(accent.opacity(0.88))
                    .frame(width: max(3, t * width), height: 3)
                Circle()
                    .fill(Color.white.opacity(0.94))
                    .frame(width: thumb, height: thumb)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                    .offset(x: max(0, min(width - thumb, t * width - thumb / 2)))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        value = Double(min(max(0, drag.location.x / width), 1))
                    }
            )
        }
        .frame(height: 14)
        .accessibilityLabel("Track volume")
    }
}

struct AddChipButton: View {
    let title: String
    var systemImage: String = "plus"
    var enabled: Bool = true
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .foregroundStyle(StudioTheme.text.opacity(labelOpacity))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(fillOpacity))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .frame(maxWidth: .infinity)
        .onHover { hovering = $0 }
    }

    private var labelOpacity: Double {
        guard enabled else { return 0.28 }
        return hovering ? 0.92 : 0.62
    }

    private var fillOpacity: Double {
        guard enabled else { return 0.03 }
        return hovering ? 0.08 : 0.04
    }
}

struct ActionChipButton: View {
    enum Kind { case normal, danger }

    let title: String
    var kind: Kind = .normal
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(background)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        kind == .danger
            ? StudioTheme.destructive.opacity(hovering ? 1 : 0.8)
            : StudioTheme.text.opacity(hovering ? 0.92 : 0.66)
    }

    private var background: Color {
        kind == .danger
            ? StudioTheme.destructive.opacity(hovering ? 0.10 : 0.05)
            : Color.white.opacity(hovering ? 0.08 : 0.04)
    }
}

struct ParameterSlider: View {
    let title: String
    @Binding var value: TimeInterval
    var upper: TimeInterval
    var format: InspectorValueFormat
    var accent: Color = Color.white.opacity(0.85)
    var onEditingEnded: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTheme.text.opacity(0.55))
                Spacer(minLength: 8)
                Text(format.string(clampedValue))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(StudioTheme.text.opacity(0.82))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                let range = max(upper, 0.0001)
                let t = CGFloat(min(max(clampedValue / range, 0), 1))
                let thumb: CGFloat = 10
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 3)
                    Capsule(style: .continuous)
                        .fill(accent.opacity(0.88))
                        .frame(width: max(3, t * width), height: 3)
                    Circle()
                        .fill(Color.white.opacity(0.94))
                        .frame(width: thumb, height: thumb)
                        .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                        .offset(x: max(0, min(width - thumb, t * width - thumb / 2)))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { drag in
                            if drag.translation == .zero, drag.location == .zero { return }
                            let x = drag.startLocation.x + drag.translation.width
                            let p = min(max(0, x / width), 1)
                            value = TimeInterval(p) * range
                        }
                        .onEnded { _ in
                            onEditingEnded?()
                        }
                )
            }
            .frame(height: 14)
        }
    }

    private var clampedValue: TimeInterval {
        min(max(0, value), max(upper, 0))
    }
}

struct TitleBarOpenButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 11, weight: .medium))
                Text("Open media")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(StudioTheme.text.opacity(hovering ? 0.96 : 0.82))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.10 : 0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Load video or audio from Finder")
        .accessibilityLabel("Open media")
        .onHover { hovering = $0 }
    }
}

struct TitleBarIconButton: View {
    let systemImage: String
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(StudioTheme.text.opacity(hovering ? 0.92 : 0.58))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.07 : 0))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

struct TitleBarExportButton: View {
    let title: String
    var enabled: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(StudioTheme.text.opacity(enabled ? (hovering ? 0.96 : 0.82) : 0.32))
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(enabled ? (hovering ? 0.10 : 0.06) : 0.03))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help("Export with encode settings")
        .onHover { hovering = $0 }
    }
}

struct TransportIconButton: View {
    let systemImage: String
    var prominent: Bool = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: prominent ? 12 : 10, weight: .semibold))
                .foregroundStyle(StudioTheme.text.opacity(hovering ? 1 : 0.62))
                .frame(width: prominent ? 28 : 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
