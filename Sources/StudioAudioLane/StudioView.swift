import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct StudioView: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            Rectangle().fill(StudioTheme.hairline).frame(height: 1)
            HStack(spacing: 0) {
                InspectorPane()
                Rectangle().fill(StudioTheme.hairline).frame(width: 1)
                preview
            }
            .layoutPriority(1)
            Rectangle().fill(StudioTheme.hairline).frame(height: 1)
            TimelineView()
                .frame(height: TimelineView.timelineHeight(for: model.tracks))
                .clipped()
        }
        .background(StudioTheme.bg)
        .foregroundStyle(StudioTheme.text)
        .frame(minWidth: 1100, minHeight: 620)
        .background(WindowConfigurator(title: model.projectDisplayName))
        .onAppear { model.start() }
        .alert("Studio", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: Binding(
            get: { model.isExportSheetPresented },
            set: { model.isExportSheetPresented = $0 }
        )) {
            ExportSheet()
                .environment(model)
                .preferredColorScheme(.dark)
        }
    }

    private var preview: some View {
        ZStack {
            StudioTheme.canvas
            PlayerSurface(player: model.player)
                .padding(18)
            if model.isLoading {
                ProgressView(model.status.isEmpty ? "Loading…" : model.status)
                    .controlSize(.small)
                    .tint(.white)
            } else if !model.hasVideo {
                VStack(spacing: 10) {
                    Image(systemName: "film")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(StudioTheme.muted)
                    Text("Drop media here")
                        .font(.system(size: 13))
                        .foregroundStyle(StudioTheme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL, .movie, .audio], isTargeted: nil) { providers in
            _ = loadDropped(providers)
            return true
        }
    }

    private func loadDropped(_ providers: [NSItemProvider]) -> Bool {
        let eligible = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.audio.identifier)
        }
        guard !eligible.isEmpty else { return false }

        let group = DispatchGroup()
        let box = DropURLBox()
        for provider in eligible {
            group.enter()
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL? = {
                        if let url = item as? URL { return url }
                        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
                        return nil
                    }()
                    if let url { box.append(url) }
                    group.leave()
                }
            } else {
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = box.urls
            guard !urls.isEmpty else { return }
            model.acceptDroppedFiles(urls)
        }
        return true
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerNSView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = playerLayer
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
