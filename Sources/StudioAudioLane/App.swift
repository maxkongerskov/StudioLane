import SwiftUI

@main
struct StudioAudioLaneApp: App {
    @State private var model = EditorModel()
    @State private var mcpServer: MCPServer?

    var body: some Scene {
        WindowGroup {
            StudioView()
                .environment(model)
                .preferredColorScheme(.dark)
                .onAppear {
                    startMCPIfNeeded()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1568, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") {
                    model.openUserProject()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift, .option])
                Button("Open Media…") {
                    model.pickMediaFile()
                }
                .keyboardShortcut("o", modifiers: [.command])
                Divider()
                Button("Save Project") {
                    model.saveUserProject()
                }
                .keyboardShortcut("s", modifiers: [.command])
                Button("Save Project As…") {
                    model.saveUserProjectAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Export…") {
                    model.presentExportSheet()
                }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(!model.hasVideo || model.isExporting)
            }
            CommandMenu("Audio") {
                Button("Add Audio Track…") {
                    model.pickAudioFile()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Replace Music…") {
                    model.replaceSelectedMusic()
                }
                .disabled(model.selectedAudio == nil)
                Button("Fill from Files…") {
                    model.fillMusicFromFiles()
                }
                Button("Fit Selected to Video") {
                    model.fitSelectedMusicToVideo()
                }
                .disabled(model.selectedAudio == nil || !model.hasVideo)
                Divider()
                Button(model.audioLayoutMode == .playlist ? "Music Layout: Playlist" : "Music Layout: Layer") {
                    model.toggleAudioLayoutMode()
                }
                Toggle("Duck Music", isOn: Binding(
                    get: { model.isDuckingMusic },
                    set: { model.setDuckingMusic($0) }
                ))
                Divider()
                Button("Previous Music Clip") { model.seekToPreviousMusicClip() }
                    .keyboardShortcut(.leftArrow, modifiers: [.option])
                    .disabled(model.isExportSheetPresented)
                Button("Next Music Clip") { model.seekToNextMusicClip() }
                    .keyboardShortcut(.rightArrow, modifiers: [.option])
                    .disabled(model.isExportSheetPresented)
                Divider()
                Button("Mark In") { model.markLoopIn() }
                    .keyboardShortcut("i", modifiers: [.control])
                    .disabled(model.isExportSheetPresented)
                Button("Mark Out") { model.markLoopOut() }
                    .keyboardShortcut("o", modifiers: [.control])
                    .disabled(model.isExportSheetPresented)
                Button("Loop Selected Clips") { model.loopSelectedClips() }
                    .disabled(model.isExportSheetPresented)
                Button(model.loopEnabled ? "Loop: On" : "Loop: Off") { model.toggleLoop() }
                    .keyboardShortcut("l", modifiers: [.control])
                    .disabled(model.isExportSheetPresented)
                Divider()
                Button("Delete Clip") {
                    switch model.focusedLane {
                    case .audio: model.deleteSelectedAudio()
                    case .video: model.deleteSelectedVideo()
                    }
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(model.isExportSheetPresented || (!model.hasMusic && !model.hasVideo))
                Button(model.isPlaying ? "Pause" : "Play") {
                    model.togglePlay()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.isExportSheetPresented)
            }
        }
    }

    init() {
        if CommandLine.arguments.contains("--mcp") {
        }
    }

    private func startMCPIfNeeded() {
        guard CommandLine.arguments.contains("--mcp"), mcpServer == nil else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            let server = MCPServer(model: model)
            mcpServer = server
            server.start()
        }
    }
}
