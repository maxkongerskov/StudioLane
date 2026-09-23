import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct ExportSettings: Equatable {
    enum Container: String, CaseIterable, Identifiable {
        case mp4 = "MP4"
        case mov = "MOV"
        case m4v = "M4V"

        var id: String { rawValue }

        var pathExtension: String {
            switch self {
            case .mp4: "mp4"
            case .mov: "mov"
            case .m4v: "m4v"
            }
        }

        var fileType: AVFileType {
            switch self {
            case .mp4: .mp4
            case .mov: .mov
            case .m4v: .m4v
            }
        }

        var contentType: UTType {
            switch self {
            case .mp4: .mpeg4Movie
            case .mov: .quickTimeMovie
            case .m4v: UTType(filenameExtension: "m4v") ?? .mpeg4Movie
            }
        }
    }

    enum Codec: String, CaseIterable, Identifiable {
        case h264 = "H.264"
        case hevc = "HEVC"
        case proRes422 = "ProRes 422"
        case proRes4444 = "ProRes 4444"

        var id: String { rawValue }

        var requiresMOV: Bool {
            self == .proRes422 || self == .proRes4444
        }

        var usesPCMAudio: Bool {
            requiresMOV
        }
    }

    enum Quality: String, CaseIterable, Identifiable {
        case low = "Low"
        case medium = "Medium"
        case high = "High"
        case max = "Max"

        var id: String { rawValue }

        /// Approximate average video bit rate in bits/sec for writer path.
        func approximateBitRate(pixelCount: CGFloat) -> Int {
            let mp = Swift.max(0.3, Double(pixelCount) / 1_000_000)
            let factor: Double
            switch self {
            case .low: factor = 1.2
            case .medium: factor = 2.5
            case .high: factor = 5.0
            case .max: factor = 10.0
            }
            return Int(mp * factor * 1_000_000)
        }
    }

    enum Resolution: String, CaseIterable, Identifiable {
        case original = "Original"
        case p1080 = "1080p"
        case p720 = "720p"
        case custom = "Custom"

        var id: String { rawValue }
    }

    enum FrameRate: String, CaseIterable, Identifiable {
        case original = "Original"
        case fps30 = "30 fps"
        case fps60 = "60 fps"

        var id: String { rawValue }

        var seconds: Double? {
            switch self {
            case .original: nil
            case .fps30: 1.0 / 30.0
            case .fps60: 1.0 / 60.0
            }
        }
    }

    enum AudioBitrate: String, CaseIterable, Identifiable {
        case match = "Match / default"
        case aac96 = "AAC 96 kbps"
        case aac128 = "AAC 128 kbps"
        case aac192 = "AAC 192 kbps"
        case aac256 = "AAC 256 kbps"

        var id: String { rawValue }

        var bitsPerSecond: Int? {
            switch self {
            case .match: nil
            case .aac96: 96_000
            case .aac128: 128_000
            case .aac192: 192_000
            case .aac256: 256_000
            }
        }
    }

    var container: Container = .mp4
    var codec: Codec = .h264
    var quality: Quality = .high
    var resolution: Resolution = .original
    var customWidth: Int = 1920
    var customHeight: Int = 1080
    var frameRate: FrameRate = .original
    /// Default Match → AVAssetExportSession (reliable QuickTime output).
    /// Explicit AAC kbps opts into the writer pipeline.
    var audioBitrate: AudioBitrate = .match
    /// Base file name without extension (shown/editable in the export sheet).
    var fileBaseName: String = "StudioAudioLane"

    mutating func sanitize() {
        if codec.requiresMOV {
            container = .mov
        }
        if codec.usesPCMAudio {
            audioBitrate = .match
        }
        customWidth = Swift.max(16, Swift.min(7680, customWidth))
        customHeight = Swift.max(16, Swift.min(4320, customHeight))
        fileBaseName = Self.sanitizedBaseName(fileBaseName)
    }

    static func sanitizedBaseName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        // Strip a trailing extension if the user typed one matching common movie types.
        let noExt: String = {
            let lower = cleaned.lowercased()
            for ext in [".mp4", ".mov", ".m4v"] where lower.hasSuffix(ext) {
                return String(cleaned.dropLast(ext.count))
            }
            return cleaned
        }()
        return noExt.isEmpty ? "StudioAudioLane" : noExt
    }

    var availableContainers: [Container] {
        codec.requiresMOV ? [.mov] : Container.allCases
    }

    var availableAudioBitrates: [AudioBitrate] {
        codec.usesPCMAudio ? [.match] : AudioBitrate.allCases
    }

    func targetSize(source: CGSize) -> CGSize {
        let src = CGSize(width: max(1, source.width), height: max(1, source.height))
        switch resolution {
        case .original:
            return CGSize(width: src.width.rounded(), height: src.height.rounded())
        case .p1080:
            return Self.fit(src, shortSide: 1080)
        case .p720:
            return Self.fit(src, shortSide: 720)
        case .custom:
            return Self.fit(src, into: CGSize(width: CGFloat(customWidth), height: CGFloat(customHeight)))
        }
    }

    private static func fit(_ source: CGSize, shortSide: CGFloat) -> CGSize {
        if source.width <= source.height {
            let scale = shortSide / source.width
            return CGSize(width: shortSide.rounded(), height: (source.height * scale).rounded())
        } else {
            let scale = shortSide / source.height
            return CGSize(width: (source.width * scale).rounded(), height: shortSide.rounded())
        }
    }

    private static func fit(_ source: CGSize, into box: CGSize) -> CGSize {
        let sx = box.width / source.width
        let sy = box.height / source.height
        let scale = min(sx, sy)
        return CGSize(width: (source.width * scale).rounded(), height: (source.height * scale).rounded())
    }

    func exportPresetName() -> String {
        switch codec {
        case .proRes422:
            return AVAssetExportPresetAppleProRes422LPCM
        case .proRes4444:
            return AVAssetExportPresetAppleProRes4444LPCM
        case .hevc:
            switch quality {
            case .low, .medium:
                return AVAssetExportPresetHEVC1920x1080
            case .high, .max:
                return AVAssetExportPresetHEVCHighestQuality
            }
        case .h264:
            switch quality {
            case .low: return AVAssetExportPresetLowQuality
            case .medium: return AVAssetExportPresetMediumQuality
            case .high, .max: return AVAssetExportPresetHighestQuality
            }
        }
    }

    /// Prefer AVAssetExportSession for common presets (playable in QuickTime).
    /// Writer is only used when the user picks an explicit AAC bitrate that
    /// ExportSession cannot set — and that path must stay MainActor-safe.
    var prefersWriterPipeline: Bool {
        !codec.usesPCMAudio && audioBitrate.bitsPerSecond != nil
    }
}

struct ExportSheet: View {
    @Environment(EditorModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ExportSettings()
    @State private var isRenaming = false
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(StudioTheme.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 16) {
                    summary
                    field("Container") {
                        Picker("", selection: $settings.container) {
                            ForEach(settings.availableContainers) { item in
                                Text(item.rawValue).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(settings.codec.requiresMOV)
                    }
                    field("Video codec") {
                        Picker("", selection: $settings.codec) {
                            ForEach(ExportSettings.Codec.allCases) { item in
                                Text(item.rawValue).tag(item)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    field("Quality") {
                        Picker("", selection: $settings.quality) {
                            ForEach(ExportSettings.Quality.allCases) { item in
                                Text(item.rawValue).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(settings.codec.usesPCMAudio)
                    }
                    field("Resolution") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("", selection: $settings.resolution) {
                                ForEach(ExportSettings.Resolution.allCases) { item in
                                    Text(item.rawValue).tag(item)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            if settings.resolution == .custom {
                                HStack(spacing: 8) {
                                    steppableInt("W", value: $settings.customWidth)
                                    Text("×").foregroundStyle(StudioTheme.muted)
                                    steppableInt("H", value: $settings.customHeight)
                                    Text("fit, keep aspect")
                                        .font(.system(size: 11))
                                        .foregroundStyle(StudioTheme.muted)
                                }
                            }
                            Text(resolutionCaption)
                                .font(.system(size: 11))
                                .foregroundStyle(StudioTheme.muted)
                        }
                    }
                    field("Frame rate") {
                        Picker("", selection: $settings.frameRate) {
                            ForEach(ExportSettings.FrameRate.allCases) { item in
                                Text(item.rawValue).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    field("Audio") {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("", selection: $settings.audioBitrate) {
                                ForEach(settings.availableAudioBitrates) { item in
                                    Text(item.rawValue).tag(item)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .disabled(settings.codec.usesPCMAudio)
                            Text(settings.codec.usesPCMAudio
                                 ? "ProRes exports use linear PCM audio."
                                 : "Match uses ExportSession (recommended). Explicit kbps uses the writer pipeline.")
                                .font(.system(size: 11))
                                .foregroundStyle(StudioTheme.muted)
                        }
                    }
                    if model.isExporting {
                        progressBlock
                    }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Rectangle().fill(StudioTheme.hairline).frame(height: 1)
            footer
        }
        .frame(width: 480, height: 720)
        .fixedSize()
        .background(StudioTheme.panel)
        .foregroundStyle(StudioTheme.text)
        .onAppear {
            settings.customWidth = max(16, Int(model.exportSourceSize.width.rounded()))
            settings.customHeight = max(16, Int(model.exportSourceSize.height.rounded()))
            settings.fileBaseName = ExportSettings.sanitizedBaseName(model.clipName)
            settings.sanitize()
        }
        .onChange(of: settings.codec) { _, _ in
            settings.sanitize()
        }
        .onChange(of: model.isExportSheetPresented) { _, open in
            if !open { dismiss() }
        }
    }

    private var header: some View {
        HStack {
            Text("Export")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if model.isExporting {
                Text("Encoding…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioTheme.accent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(StudioTheme.inspector)
    }

    private var summary: some View {
        let size = settings.targetSize(source: model.exportSourceSize)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Group {
                    if isRenaming {
                        TextField("Export name", text: $settings.fileBaseName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                            .focused($nameFieldFocused)
                            .onSubmit { commitRename() }
                            .onExitCommand { commitRename() }
                    } else {
                        Text(settings.fileBaseName)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(2)
                            .onTapGesture(count: 2) { beginRename() }
                            .help("Double-click to rename")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(isRenaming ? "Done" : "Rename") {
                    if isRenaming {
                        commitRename()
                    } else {
                        beginRename()
                    }
                }
                .buttonStyle(ExportSecondaryButtonStyle())
                .disabled(model.isExporting)
            }

            Text("\(settings.container.pathExtension.uppercased())  ·  double-click name or Rename")
                .font(.system(size: 11))
                .foregroundStyle(StudioTheme.muted)

            Text(String(
                format: "Source %.0f×%.0f · %.2f fps  →  %.0f×%.0f · %@",
                model.exportSourceSize.width,
                model.exportSourceSize.height,
                model.exportSourceFPS,
                size.width,
                size.height,
                settings.frameRate == .original
                    ? String(format: "%.2f fps", model.exportSourceFPS)
                    : settings.frameRate.rawValue
            ))
            .font(.system(size: 11))
            .foregroundStyle(StudioTheme.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func beginRename() {
        guard !model.isExporting else { return }
        isRenaming = true
        DispatchQueue.main.async {
            nameFieldFocused = true
        }
    }

    private func commitRename() {
        settings.fileBaseName = ExportSettings.sanitizedBaseName(settings.fileBaseName)
        isRenaming = false
        nameFieldFocused = false
    }

    private var resolutionCaption: String {
        let size = settings.targetSize(source: model.exportSourceSize)
        return String(format: "Output %.0f × %.0f (aspect preserved)", size.width, size.height)
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Progress")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StudioTheme.muted)
                Spacer()
                Text("\(Int((model.exportProgress * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(StudioTheme.text.opacity(0.8))
            }
            ProgressView(value: model.exportProgress)
                .tint(StudioTheme.accent)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.isExporting {
                Button("Cancel encode") {
                    model.cancelExport()
                }
                .buttonStyle(ExportSecondaryButtonStyle())
            } else {
                Button("Cancel") {
                    model.isExportSheetPresented = false
                    dismiss()
                }
                .buttonStyle(ExportSecondaryButtonStyle())
            }
            Spacer()
            Button(model.isExporting ? "Encoding…" : "Export…") {
                commitRename()
                settings.sanitize()
                model.beginExport(with: settings)
            }
            .buttonStyle(ExportPrimaryButtonStyle())
            .disabled(model.isExporting || !model.hasVideo)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(StudioTheme.inspector)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(StudioTheme.text.opacity(0.38))
            content()
        }
    }

    private func steppableInt(_ label: String, value: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(StudioTheme.muted)
            TextField("", value: value, format: .number)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .padding(.horizontal, 8)
                .frame(width: 72, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
        }
    }
}

private struct ExportPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(StudioTheme.text)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(StudioTheme.accent.opacity(configuration.isPressed ? 0.55 : 0.42))
            )
    }
}

private struct ExportSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(StudioTheme.text.opacity(configuration.isPressed ? 0.95 : 0.75))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.10 : 0.05))
            )
    }
}
