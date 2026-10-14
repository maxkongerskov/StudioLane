import AppKit
import AVFoundation
import CoreVideo
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Still pictures placed on a video lane. AVFoundation can only insert a video
/// track, so each image is cached as a one-second movie and stretched to the
/// clip length. The clip's `sourceDuration` is a hold limit, not the file length,
/// so trim and the length slider can extend the picture.
enum StillImage {
    /// First hold when a picture is dropped on the timeline.
    static let defaultDuration: TimeInterval = 5
    /// Longest a single still clip can run. Duplicate the clip to hold it longer.
    static let maximumDuration: TimeInterval = 600

    static let extensions: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif", "png", "gif", "bmp", "dib",
        "tif", "tiff", "heic", "heif", "heics", "webp", "avif", "jxl",
        "ico", "icns", "jp2", "j2k", "jpf", "jpx", "pict", "pct", "tga", "targa",
        "psd", "exr", "hdr", "pic", "pbm", "pgm", "ppm", "pnm", "pfm", "qoi",
        "dng", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
        "rw2", "pef", "srw", "3fr", "fff", "mef", "mos", "raw", "iiq", "erf",
        "kdc", "dcr", "rwl"
    ]

    static func isStill(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if extensions.contains(ext) { return true }
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else {
            return false
        }
        return type.conforms(to: .image)
    }

    /// Cached one-second movie of `imageURL`. Regenerated when the file changes.
    static func movieURL(for imageURL: URL) async throws -> URL {
        let dest = try cacheFile(for: imageURL)
        if FileManager.default.fileExists(atPath: dest.path) {
            return dest
        }
        return try await Task.detached(priority: .userInitiated) {
            if FileManager.default.fileExists(atPath: dest.path) {
                return dest
            }
            let image = try orientedImage(at: imageURL, maxPixel: 3840)
            let temp = dest
                .deletingLastPathComponent()
                .appendingPathComponent(dest.deletingPathExtension().lastPathComponent + "-" + UUID().uuidString)
                .appendingPathExtension("mov")
            do {
                try writeMovie(image, to: temp)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.removeItem(at: temp)
                    return dest
                }
                try FileManager.default.moveItem(at: temp, to: dest)
                return dest
            } catch {
                try? FileManager.default.removeItem(at: temp)
                if FileManager.default.fileExists(atPath: dest.path) {
                    return dest
                }
                throw error
            }
        }.value
    }

    struct Placement {
        var renderSize: CGSize
        var frameRate: Float
    }

    /// Lays the still on `track` at `start` and stretches it to `duration`.
    /// A one-second source is scaled so the picture holds for the clip length.
    /// Main actor: composition tracks are mutated on the same actor as the editor.
    @MainActor
    static func place(
        movieURL: URL,
        on track: AVMutableCompositionTrack,
        at start: TimeInterval,
        duration: TimeInterval
    ) async throws -> Placement {
        let asset = AVURLAsset(url: movieURL)
        guard let source = try await asset.loadTracks(withMediaType: .video).first else {
            throw StillImageError.encodeFailed(movieURL.lastPathComponent)
        }
        let sourceDuration = try await asset.load(.duration)
        let at = CMTime(seconds: max(0, start), preferredTimescale: 600)
        let before = track.segments ?? []
        try track.insertTimeRange(
            CMTimeRange(start: .zero, duration: sourceDuration),
            of: source,
            at: at
        )
        // Scale only the segment just inserted. A later clip must not be stretched,
        // and the one-second cache must not stay at one second when the hold is longer.
        let target = CMTime(seconds: max(0.05, duration), preferredTimescale: 600)
        guard let mapped = insertedTargetRange(before: before, after: track.segments ?? [], at: at) else {
            throw StillImageError.encodeFailed(movieURL.lastPathComponent)
        }
        if abs(mapped.duration.seconds - target.seconds) > 0.01 {
            track.scaleTimeRange(mapped, toDuration: target)
        }
        let transform = try await source.load(.preferredTransform)
        track.preferredTransform = transform
        let natural = try await source.load(.naturalSize)
        let rendered = CGRect(origin: .zero, size: natural).applying(transform)
        let fps = try await source.load(.nominalFrameRate)
        return Placement(
            renderSize: CGSize(width: abs(rendered.width), height: abs(rendered.height)),
            frameRate: fps
        )
    }

    static func thumbnail(at url: URL, maxPixel: Int = 320) -> CGImage? {
        try? orientedImage(at: url, maxPixel: maxPixel)
    }

    static func orientedImage(at url: URL, maxPixel: Int) throws -> CGImage {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(2, maxPixel),
                kCGImageSourceShouldCacheImmediately: true
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
               image.width > 0, image.height > 0 {
                return image
            }
        }
        if let image = NSImage(contentsOf: url),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           cg.width > 0, cg.height > 0 {
            return cg
        }
        throw StillImageError.unreadable(url.lastPathComponent)
    }

    /// Time range of the non-empty segment inserted at `at`.
    private static func insertedTargetRange(
        before: [AVCompositionTrackSegment],
        after: [AVCompositionTrackSegment],
        at: CMTime
    ) -> CMTimeRange? {
        let previousStarts = Set(before.filter { !$0.isEmpty }.map { $0.timeMapping.target.start.seconds })
        let fresh = after.filter { segment in
            !segment.isEmpty && !previousStarts.contains(segment.timeMapping.target.start.seconds)
        }
        let pool = fresh.isEmpty ? after.filter { !$0.isEmpty } : fresh
        guard let range = pool
            .map(\.timeMapping.target)
            .min(by: { abs($0.start.seconds - at.seconds) < abs($1.start.seconds - at.seconds) })
        else { return nil }
        guard abs(range.start.seconds - at.seconds) < 0.05 else { return nil }
        return range
    }

    private static func cacheFile(for url: URL) throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = base.appendingPathComponent("StudioAudioLane/StillMovies", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "v1|\(url.path)|\(size)|\(modified)"
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("mov")
    }

    /// One second of identical frames. `place` stretches this to the clip length.
    private static func writeMovie(_ image: CGImage, to url: URL) throws {
        let (width, height) = evenSize(for: image)
        guard let buffer = pixelBuffer(from: image, width: width, height: height) else {
            throw StillImageError.encodeFailed(url.lastPathComponent)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(250_000, width * height * 2)
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else {
            throw StillImageError.encodeFailed(url.lastPathComponent)
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? StillImageError.encodeFailed(url.lastPathComponent)
        }
        let fps: Int32 = 30
        let frameCount = 30
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frameCount {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData {
                if Date() > deadline {
                    writer.cancelWriting()
                    throw StillImageError.encodeFailed(url.lastPathComponent)
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
            let time = CMTime(value: CMTimeValue(frame), timescale: fps)
            if !adaptor.append(buffer, withPresentationTime: time) {
                writer.cancelWriting()
                throw writer.error ?? StillImageError.encodeFailed(url.lastPathComponent)
            }
        }
        // Last sample is stamped at frame 29; close the session at frame 30 so the
        // cached movie is a full second and stretch math stays stable.
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: fps))
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw writer.error ?? StillImageError.encodeFailed(url.lastPathComponent)
        }
    }

    private static func evenSize(for image: CGImage, maxSide: Int = 3840) -> (Int, Int) {
        var width = max(image.width, 1)
        var height = max(image.height, 1)
        let longSide = max(width, height)
        if longSide > maxSide {
            let scale = Double(maxSide) / Double(longSide)
            width = max(2, Int((Double(width) * scale).rounded(.down)))
            height = max(2, Int((Double(height) * scale).rounded(.down)))
        }
        if width % 2 != 0 { width -= 1 }
        if height % 2 != 0 { height -= 1 }
        return (max(2, width), max(2, height))
    }

    private static func pixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

enum StillImageError: LocalizedError {
    case unreadable(String)
    case encodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            "Can't read “\(name)” — the image is unsupported or corrupt."
        case .encodeFailed(let name):
            "Can't place “\(name)” on the timeline — the still could not be prepared."
        }
    }
}
