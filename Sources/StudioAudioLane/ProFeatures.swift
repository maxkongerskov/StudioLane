import CoreGraphics
import Foundation

/// Advanced clip controls exposed only while Pro mode is enabled.
struct ClipTransform: Codable, Equatable {
    var scale: Double = 1
    /// Position as a fraction of half the project canvas. `1` reaches the right edge.
    var positionX: Double = 0
    /// Position as a fraction of half the project canvas. `1` reaches the bottom edge.
    var positionY: Double = 0
    var rotationDegrees: Double = 0
    var opacity: Double = 1

    static let identity = ClipTransform()

    mutating func sanitize() {
        scale = min(max(scale.isFinite ? scale : 1, 0.05), 8)
        positionX = min(max(positionX.isFinite ? positionX : 0, -2), 2)
        positionY = min(max(positionY.isFinite ? positionY : 0, -2), 2)
        rotationDegrees = min(max(rotationDegrees.isFinite ? rotationDegrees : 0, -1_080), 1_080)
        opacity = min(max(opacity.isFinite ? opacity : 1, 0), 1)
    }

    func sanitized() -> ClipTransform {
        var copy = self
        copy.sanitize()
        return copy
    }

    func affineTransform(canvasSize: CGSize, base: CGAffineTransform = .identity) -> CGAffineTransform {
        let value = sanitized()
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let offset = CGPoint(
            x: value.positionX * Double(canvasSize.width / 2),
            y: value.positionY * Double(canvasSize.height / 2)
        )
        let radians = value.rotationDegrees * .pi / 180
        let user = CGAffineTransform(translationX: center.x + offset.x, y: center.y + offset.y)
            .rotated(by: radians)
            .scaledBy(x: value.scale, y: value.scale)
            .translatedBy(x: -center.x, y: -center.y)
        return base.concatenating(user)
    }

    static func interpolated(from: ClipTransform, to: ClipTransform, progress: Double) -> ClipTransform {
        let p = min(max(progress, 0), 1)
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * p }
        return ClipTransform(
            scale: lerp(from.scale, to.scale),
            positionX: lerp(from.positionX, to.positionX),
            positionY: lerp(from.positionY, to.positionY),
            rotationDegrees: lerp(from.rotationDegrees, to.rotationDegrees),
            opacity: lerp(from.opacity, to.opacity)
        )
    }
}

struct ClipTransformKeyframe: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// Seconds from the clip's timeline start.
    var time: TimeInterval
    var transform: ClipTransform

    mutating func sanitize(clipDuration: TimeInterval) {
        time = min(max(time.isFinite ? time : 0, 0), max(0, clipDuration))
        transform.sanitize()
    }
}

enum ClipTransitionStyle: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    case dissolve = "Dissolve"
    case slide = "Slide"
    case zoom = "Zoom"

    var id: String { rawValue }
}

struct ClipTransition: Codable, Equatable {
    var style: ClipTransitionStyle = .none
    var duration: TimeInterval = 0.35

    mutating func sanitize(clipDuration: TimeInterval) {
        guard duration.isFinite else {
            duration = 0.35
            return
        }
        duration = min(max(0, duration), max(0, clipDuration / 2))
        if style == .none { duration = 0 }
    }
}

struct ProProjectSettings: Codable, Equatable {
    var frameRate: Double = 30
    var sampleRate: Double = 48_000
    var limiterEnabled = true
    var snapToClipEdges = true
    var snapToPlayhead = true
    var snapToFrameGrid = false

    mutating func sanitize() {
        let supportedFrameRates = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]
        frameRate = supportedFrameRates.min(by: { abs($0 - frameRate) < abs($1 - frameRate) }) ?? 30
        let supportedSampleRates = [44_100.0, 48_000.0, 96_000.0]
        sampleRate = supportedSampleRates.min(by: { abs($0 - sampleRate) < abs($1 - sampleRate) }) ?? 48_000
    }
}

enum ClipAlignment {
    case starts
    case ends
    case playhead
    case distribute
}

/// Linear mix for one clip, plus the Pro tap's channel gains.
/// Centered clips keep unity tap gains and do not install a tap, so Standard
/// and Pro describe the same loudness for the same timeline.
struct ClipAudioMixSpec: Equatable {
    var clipID: UUID
    var mixVolume: Float
    var timelineStart: TimeInterval
    var duration: TimeInterval
    var fadeIn: TimeInterval
    var fadeOut: TimeInterval
    var pan: Float
    /// Channel multipliers of the processing tap. `(1, 1)` when no tap is installed.
    var tapLeft: Float
    var tapRight: Float
    var installsProcessingTap: Bool

    var effectiveLeft: Float { mixVolume * tapLeft }
    var effectiveRight: Float { mixVolume * tapRight }
    /// Sum of squared channel gains after the mix volume. Pan keeps this constant
    /// relative to a centered clip, and a centered clip matches Standard mode.
    var linearPower: Float {
        effectiveLeft * effectiveLeft + effectiveRight * effectiveRight
    }
}

enum ProFeatureMath {
    static func equalPowerPan(_ pan: Float) -> (left: Float, right: Float) {
        let p = min(max(pan, -1), 1)
        let angle = (Double(p) + 1) * .pi / 4
        return (Float(cos(angle)), Float(sin(angle)))
    }

    /// Equal-power pan with makeup so center is unity.
    /// `equalPowerPan(0)` is −3 dB per channel. Running that law on every Pro
    /// clip, on top of audio Standard mode plays unprocessed, made Pro quieter.
    static func unityCenterPan(_ pan: Float) -> (left: Float, right: Float) {
        let p = min(max(pan, -1), 1)
        if abs(p) < 0.000_01 { return (1, 1) }
        let raw = equalPowerPan(p)
        let makeup = Float(sqrt(2))
        return (raw.left * makeup, raw.right * makeup)
    }

    /// Tap installed only when Pro processing would change in-range audio.
    /// A centered clip is unity on both channels, and the full-scale ceiling
    /// does not move those samples, so the tap stays off and matches Standard.
    static func playbackTap(pan: Float, proMode: Bool) -> (left: Float, right: Float, install: Bool) {
        guard proMode else { return (1, 1, false) }
        let gains = unityCenterPan(pan)
        let centered = abs(gains.left - 1) <= 0.000_5 && abs(gains.right - 1) <= 0.000_5
        if centered { return (1, 1, false) }
        return (gains.left, gains.right, true)
    }

    static func limitedSample(_ sample: Float, enabled: Bool) -> Float {
        guard enabled else { return sample }
        guard sample.isFinite else { return 0 }
        // Ceiling at full scale. Signals already inside [-1, 1] pass unchanged
        // so the limiter cannot shift loudness against Standard mode. Overs
        // (a hard-panned channel after constant-power makeup) stop at ±1.
        return min(max(sample, -1), 1)
    }

    static func processedSample(_ sample: Float, channelGain: Float, limiterEnabled: Bool) -> Float {
        limitedSample(sample * channelGain, enabled: limiterEnabled)
    }

    static func normalizedGain(current: Float, peak: Float, targetPeak: Float = 0.89) -> Float {
        guard peak.isFinite, peak > 0.000_1 else { return min(max(current, 0), 1) }
        return min(max(current * targetPeak / peak, 0), 1)
    }
}
