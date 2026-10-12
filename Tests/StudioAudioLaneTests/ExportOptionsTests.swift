import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import StudioAudioLane

final class ExportOptionsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sal-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testGIFSettingsAndXLoopSettingsSanitize() {
        var gif = ExportSettings()
        gif.mode = .animatedGIF
        gif.gifSize = .recommended
        gif.gifFrameRate = .fps12
        gif.fileBaseName = "post.gif"
        gif.sanitize()
        XCTAssertEqual(gif.pathExtension, "gif")
        XCTAssertEqual(gif.contentType, .gif)
        XCTAssertEqual(gif.fileBaseName, "post")
        XCTAssertEqual(gif.targetSize(source: CGSize(width: 1920, height: 1080)), CGSize(width: 720, height: 405))

        var xLoop = ExportSettings()
        xLoop.mode = .xLoop
        xLoop.codec = .hevc
        xLoop.container = .mov
        xLoop.audioBitrate = .match
        xLoop.xLoopCount = 99
        xLoop.sanitize()
        XCTAssertEqual(xLoop.container, .mp4)
        XCTAssertEqual(xLoop.codec, .h264)
        XCTAssertEqual(xLoop.audioBitrate, .aac128)
        XCTAssertEqual(xLoop.frameRate, .fps30)
        XCTAssertEqual(xLoop.xLoopCount, 10)
        let size = xLoop.targetSize(source: CGSize(width: 3840, height: 2160))
        XCTAssertLessThanOrEqual(max(size.width, size.height), 1280)
    }

    func testAnimatedGIFLoopsForeverAndStaysWithinBudget() async throws {
        let imageURL = directory.appendingPathComponent("source.png")
        try writePNG(to: imageURL)
        let movieURL = try await StillImage.movieURL(for: imageURL)
        let asset = AVURLAsset(url: movieURL)
        let destination = directory.appendingPathComponent("loop.gif")

        try await EditorModel.performGIFExport(
            asset: asset,
            destination: destination,
            targetSize: CGSize(width: 96, height: 72),
            fps: 8,
            compressionQuality: 0.72,
            videoComposition: nil,
            byteLimit: 15_000_000,
            isCancelled: { false },
            onProgress: { _ in }
        )

        let bytes = try XCTUnwrap(
            try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        XCTAssertGreaterThan(bytes, 100)
        XCTAssertLessThanOrEqual(bytes, 15_000_000)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
        XCTAssertGreaterThanOrEqual(CGImageSourceGetCount(source), 7)
        let properties = try XCTUnwrap(
            CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        )
        let gif = try XCTUnwrap(
            properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        )
        XCTAssertEqual((gif[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue, 0)
    }

    @MainActor
    func testXLoopRepeatsTimelineDuration() async throws {
        let imageURL = directory.appendingPathComponent("source.png")
        try writePNG(to: imageURL)
        let movieURL = try await StillImage.movieURL(for: imageURL)
        let source = AVURLAsset(url: movieURL)
        let sourceDuration = try await source.load(.duration).seconds

        let repeated = try await EditorModel.makeRepeatedComposition(from: source, count: 3)
        let repeatedDuration = try await repeated.load(.duration).seconds
        XCTAssertEqual(repeatedDuration, sourceDuration * 3, accuracy: 0.05)
    }

    private func writePNG(to url: URL) throws {
        let context = CGContext(
            data: nil,
            width: 96,
            height: 72,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 72))
        let image = context.makeImage()!
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
