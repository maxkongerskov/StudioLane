import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import StudioAudioLane

final class StillImageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sal-still-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testImageExtensionsUseTheVideoLane() async {
        let pictures = ["png", "jpg", "jpeg", "jpe", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp"]
        for ext in pictures {
            let url = URL(fileURLWithPath: "/tmp/picture.\(ext)")
            XCTAssertTrue(StillImage.isStill(url), ext)
            XCTAssertEqual(EditorModel.mediaKind(for: url), .video, ext)
        }
        XCTAssertTrue(StillImage.isStill(URL(fileURLWithPath: "/tmp/Photo.JPEG")))
        XCTAssertEqual(EditorModel.mediaKind(for: URL(fileURLWithPath: "/tmp/clip.mp4")), .video)
        XCTAssertEqual(EditorModel.mediaKind(for: URL(fileURLWithPath: "/tmp/clip.mov")), .video)
        XCTAssertEqual(EditorModel.mediaKind(for: URL(fileURLWithPath: "/tmp/song.wav")), .audio)
        XCTAssertEqual(EditorModel.mediaKind(for: URL(fileURLWithPath: "/tmp/song.mp3")), .audio)
        XCTAssertFalse(StillImage.isStill(URL(fileURLWithPath: "/tmp/clip.mov")))
        XCTAssertFalse(StillImage.isStill(URL(fileURLWithPath: "/tmp/song.wav")))

        let opened = await MainActor.run { EditorModel.openMediaTypes }
        let dropped = await MainActor.run { EditorModel.mediaDropTypes }
        for type in [UTType.image, .jpeg, .png, .gif, .tiff, .heic, .webP] {
            XCTAssertTrue(opened.contains(type), type.identifier)
        }
        XCTAssertTrue(dropped.contains(.image))
        XCTAssertEqual(StillImage.defaultDuration, 5, accuracy: 0.001)
        XCTAssertGreaterThan(StillImage.maximumDuration, StillImage.defaultDuration)
    }

    func testStillTimelineTileSizeDependsOnLaneHeightAndAspectRatio() {
        let landscape = FilmstripLane.stillTileWidth(
            imageSize: CGSize(width: 1600, height: 900),
            laneHeight: 54
        )
        let portrait = FilmstripLane.stillTileWidth(
            imageSize: CGSize(width: 900, height: 1600),
            laneHeight: 54
        )

        XCTAssertEqual(landscape, 96, accuracy: 0.001)
        XCTAssertEqual(portrait, 30.375, accuracy: 0.001)
        // The helper intentionally takes no clip duration or width: extending a
        // still adds tiles instead of making each thumbnail larger.
        XCTAssertEqual(
            FilmstripLane.stillTileWidth(
                imageSize: CGSize(width: 1600, height: 900),
                laneHeight: 54
            ),
            landscape,
            accuracy: 0.001
        )
    }

    func testCommonImageFormatsDecode() throws {
        let image = solidImage(red: 0.15, green: 0.55, blue: 0.25)
        let required: [(String, UTType)] = [
            ("png", .png),
            ("jpg", .jpeg),
            ("jpeg", .jpeg),
            ("gif", .gif),
            ("tiff", .tiff),
            ("tif", .tiff)
        ]
        for (ext, type) in required {
            let url = directory.appendingPathComponent("sample.\(ext)")
            try write(image, type: type, to: url)
            let thumb = try XCTUnwrap(StillImage.thumbnail(at: url), ext)
            XCTAssertGreaterThan(thumb.width, 0, ext)
            XCTAssertGreaterThan(thumb.height, 0, ext)
            XCTAssertTrue(StillImage.isStill(url), ext)
            XCTAssertEqual(EditorModel.mediaKind(for: url), .video, ext)
        }

        let heicURL = directory.appendingPathComponent("sample.heic")
        var wroteHEIC = true
        do {
            try write(image, type: .heic, to: heicURL)
        } catch {
            wroteHEIC = false
        }
        if wroteHEIC {
            let thumb = try XCTUnwrap(StillImage.thumbnail(at: heicURL))
            XCTAssertGreaterThan(thumb.width, 0)
            XCTAssertTrue(StillImage.isStill(heicURL))
            XCTAssertEqual(EditorModel.mediaKind(for: heicURL), .video)
        }

        // ImageIO on this SDK reads WebP but cannot write it, so the fixture is a real file.
        let webpURL = directory.appendingPathComponent("sample.webp")
        try Data(Self.webpFixture).write(to: webpURL)
        let webp = try XCTUnwrap(StillImage.thumbnail(at: webpURL))
        XCTAssertGreaterThan(webp.width, 0)
        XCTAssertGreaterThan(meanRed(webp), 0.5)
        XCTAssertTrue(StillImage.isStill(webpURL))
        XCTAssertEqual(EditorModel.mediaKind(for: webpURL), .video)
    }

    /// 32×24 red WebP (VP8).
    private static let webpFixture = Data([
        0x52, 0x49, 0x46, 0x46, 0x4e, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
        0x42, 0x00, 0x00, 0x00, 0x30, 0x03, 0x00, 0x9d, 0x01, 0x2a, 0x20, 0x00, 0x18, 0x00, 0x3e, 0x31,
        0x18, 0x8a, 0x43, 0xa2, 0x21, 0xa1, 0x14, 0x04, 0x00, 0x20, 0x03, 0x04, 0xb2, 0x80, 0x3b, 0x00,
        0x7e, 0x00, 0x00, 0x41, 0x94, 0x10, 0x00, 0xfe, 0xf5, 0x89, 0x1f, 0xff, 0xfa, 0x69, 0x1e, 0x18,
        0x7f, 0x1a, 0x47, 0xcc, 0x5b, 0xff, 0xff, 0x6f, 0x87, 0xfb, 0x7c, 0x3f, 0xdb, 0xe1, 0xff, 0xed,
        0x91, 0x4e, 0xdc, 0x00, 0x00, 0x00
    ])

    func testStillHoldsForTheClipAndExports() async throws {
        let url = directory.appendingPathComponent("red.png")
        try write(solidImage(red: 0.92, green: 0.08, blue: 0.08), type: .png, to: url)
        let frames = await Filmstrip.generate(url: url, count: 4, inPoint: 0, duration: StillImage.maximumDuration)
        XCTAssertEqual(frames.count, 4)
        XCTAssertGreaterThan(meanRed(frames[0]), 0.5)

        try await assertHoldAndExport(imageURL: url)
    }

    func testEditorImportsTrimsAndExtendsAStill() async throws {
        let url = directory.appendingPathComponent("red.png")
        try write(solidImage(red: 0.92, green: 0.08, blue: 0.08), type: .png, to: url)
        try await assertEditorClip(imageURL: url)
    }

    func testUnreadableImageIsRejected() async throws {
        let url = directory.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: url)
        let message = try await rejectedImport(url, asAudio: false)
        XCTAssertNotNil(message)
    }

    func testImageIsNotImportedOntoAnAudioLane() async throws {
        let url = directory.appendingPathComponent("red.png")
        try write(solidImage(red: 0.2, green: 0.2, blue: 0.8), type: .png, to: url)
        let message = try await rejectedImport(url, asAudio: true)
        XCTAssertNotNil(message)
    }
}

@MainActor
private func assertHoldAndExport(imageURL: URL) async throws {
    let movie = try await StillImage.movieURL(for: imageURL)
    let cached = AVURLAsset(url: movie)
    let movieDuration = try await cached.load(.duration).seconds
    XCTAssertEqual(movieDuration, 1, accuracy: 0.05)
    let cachedTracks = try await cached.loadTracks(withMediaType: .video)
    XCTAssertEqual(cachedTracks.count, 1)

    let mix = AVMutableComposition()
    guard let track = mix.addMutableTrack(withMediaType: .video, preferredTrackID: 1) else {
        XCTFail("Could not add a video track")
        return
    }
    let first = try await StillImage.place(movieURL: movie, on: track, at: 0, duration: 4)
    XCTAssertGreaterThan(first.renderSize.width, 1)
    XCTAssertGreaterThan(first.renderSize.height, 1)
    _ = try await StillImage.place(movieURL: movie, on: track, at: 7, duration: 3)
    XCTAssertEqual(track.timeRange.duration.seconds, 10, accuracy: 0.15)

    let generator = AVAssetImageGenerator(asset: mix)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
    let early = try generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
    let late = try generator.copyCGImage(at: CMTime(seconds: 8, preferredTimescale: 600), actualTime: nil)
    XCTAssertGreaterThan(meanRed(early), 0.5)
    XCTAssertGreaterThan(meanRed(late), 0.5)

    let destination = imageURL.deletingLastPathComponent().appendingPathComponent("still-export.mp4")
    try? FileManager.default.removeItem(at: destination)
    guard let session = AVAssetExportSession(asset: mix, presetName: AVAssetExportPreset640x480) else {
        XCTFail("Export session was not created")
        return
    }
    session.outputURL = destination
    session.outputFileType = .mp4
    await session.export()
    XCTAssertEqual(session.status, .completed, session.error?.localizedDescription ?? "export failed")

    let exported = AVURLAsset(url: destination)
    let exportedDuration = try await exported.load(.duration).seconds
    XCTAssertEqual(exportedDuration, 10, accuracy: 0.35)
    let exportedVideo = try await exported.loadTracks(withMediaType: .video)
    XCTAssertFalse(exportedVideo.isEmpty)
}

@MainActor
private func assertEditorClip(imageURL: URL) async throws {
    let model = EditorModel()
    let trackID = EditorModel.defaultVideoTrackID
    let added = await model.addVideoPublic(url: imageURL, start: nil, ontoTrackID: trackID)
    XCTAssertTrue(added, model.errorMessage ?? "import failed")
    XCTAssertEqual(model.videoClips.count, 1)
    XCTAssertTrue(model.audioClips.isEmpty)
    XCTAssertTrue(model.hasVideo)

    let clip = try XCTUnwrap(model.videoClips.first)
    XCTAssertEqual(clip.duration, StillImage.defaultDuration, accuracy: 0.001)
    XCTAssertEqual(clip.sourceDuration, StillImage.maximumDuration, accuracy: 0.001)
    XCTAssertEqual(clip.inPoint, 0, accuracy: 0.001)
    XCTAssertEqual(clip.timelineStart, 0, accuracy: 0.001)
    XCTAssertEqual(clip.trackID, trackID)
    XCTAssertEqual(clip.url, imageURL)
    XCTAssertGreaterThan(model.inspectorMaxLength, clip.duration)
    XCTAssertNil(model.errorMessage)

    let held = try await videoDuration(model)
    XCTAssertEqual(held, StillImage.defaultDuration, accuracy: 0.2)
    XCTAssertNil(model.errorMessage)

    model.videoClips[0].duration = 8
    await model.rebuildCompositionPublic()
    let extended = try await videoDuration(model)
    XCTAssertEqual(extended, 8, accuracy: 0.2)

    model.videoClips[0].duration = 1.5
    await model.rebuildCompositionPublic()
    let trimmed = try await videoDuration(model)
    XCTAssertEqual(trimmed, 1.5, accuracy: 0.2)

    model.videoClips[0].duration = StillImage.defaultDuration
    await model.rebuildCompositionPublic()
    let parts = model.gaplessSplitPublic(model.videoClips[0], at: 2)
    XCTAssertEqual(parts.left.duration + parts.right.duration, StillImage.defaultDuration, accuracy: 0.001)
    XCTAssertEqual(parts.right.timelineStart, parts.left.timelineEnd, accuracy: 0.001)
    XCTAssertEqual(parts.right.inPoint, 2, accuracy: 0.001)
    model.videoClips = [parts.left, parts.right]
    await model.rebuildCompositionPublic()
    XCTAssertNil(model.errorMessage)
    let splitDuration = try await videoDuration(model)
    XCTAssertEqual(splitDuration, StillImage.defaultDuration, accuracy: 0.25)
    XCTAssertEqual(model.duration, StillImage.defaultDuration, accuracy: 0.001)
}

@MainActor
private func rejectedImport(_ url: URL, asAudio: Bool) async throws -> String? {
    let model = EditorModel()
    let added: Bool
    if asAudio {
        added = await model.addAudioPublic(url: url, start: nil, ontoTrackID: EditorModel.defaultAudioTrackID)
    } else {
        added = await model.addVideoPublic(url: url, start: 0, ontoTrackID: EditorModel.defaultVideoTrackID)
    }
    XCTAssertFalse(added)
    XCTAssertTrue(model.videoClips.isEmpty)
    XCTAssertTrue(model.audioClips.isEmpty)
    return model.errorMessage
}

@MainActor
private func videoDuration(_ model: EditorModel) async throws -> TimeInterval {
    let asset = try XCTUnwrap(model.player.currentItem?.asset, "preview composition is missing")
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first, "still produced no video track")
    return try await track.load(.timeRange).duration.seconds
}

private func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
    let width = 64
    let height = 48
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private func write(_ image: CGImage, type: UTType, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        throw StillFixtureError.unwritable(type.identifier)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw StillFixtureError.unwritable(type.identifier)
    }
}

private func meanRed(_ image: CGImage) -> CGFloat {
    guard let context = CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return 0 }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    guard let data = context.data else { return 0 }
    return CGFloat(data.bindMemory(to: UInt8.self, capacity: 4)[0]) / 255
}

private enum StillFixtureError: Error {
    case unwritable(String)
}
