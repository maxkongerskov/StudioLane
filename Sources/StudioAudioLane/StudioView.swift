import AVFoundation
import SwiftUI

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
            PlayerSurface(player: model.player) { urls in
                model.acceptDroppedFiles(urls)
            }
            if model.isLoading {
                ProgressView(model.status.isEmpty ? "Loading…" : model.status)
                    .controlSize(.small)
                    .tint(.white)
                    .allowsHitTesting(false)
            } else if !model.hasVideo {
                VStack(spacing: 10) {
                    Image(systemName: "film")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(StudioTheme.muted)
                    Text("Drop media here")
                        .font(.system(size: 13))
                        .foregroundStyle(StudioTheme.muted)
                }
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    var onDropFiles: ([URL]) -> Void

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        view.onDropFiles = onDropFiles
        return view
    }

    func updateNSView(_ view: PlayerNSView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        view.onDropFiles = onDropFiles
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
        registerForDraggedTypes([.fileURL])
    }

    var onDropFiles: ([URL]) -> Void = { _ in }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        let files = urls
        let deliver = onDropFiles
        DispatchQueue.main.async { deliver(files) }
        return true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds.insetBy(dx: 18, dy: 18)
    }
}
