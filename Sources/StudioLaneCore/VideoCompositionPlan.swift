import Foundation

/// How a fade composition covers the whole item without changing the picture ramps.
///
/// Picture segments keep a fade-in of opacity 0→1 and a fade-out of 1→0.
/// Every other range is an empty instruction so the list starts at time zero
/// and runs to the end of the item with no gaps. Nothing in this plan sets
/// opacity to 0 at time zero.
public enum VideoCompositionPlan {
    public struct Segment: Equatable, Sendable {
        public var start: Double
        public var duration: Double
        public var fadeIn: Double
        public var fadeOut: Double

        public init(start: Double, duration: Double, fadeIn: Double, fadeOut: Double) {
            self.start = start
            self.duration = duration
            self.fadeIn = fadeIn
            self.fadeOut = fadeOut
        }
    }

    public struct Slot: Equatable, Sendable {
        public enum Body: Equatable, Sendable {
            case empty
            case picture(fadeIn: Double, fadeOut: Double)
        }

        public var start: Double
        public var duration: Double
        public var body: Body

        public var end: Double { start + duration }

        public init(start: Double, duration: Double, body: Body) {
            self.start = start
            self.duration = duration
            self.body = body
        }
    }

    /// One opacity ramp on a picture segment. `from`/`to` are 0→1 or 1→0.
    public struct OpacityRamp: Equatable, Sendable {
        public var from: Double
        public var to: Double
        public var start: Double
        public var duration: Double

        public init(from: Double, to: Double, start: Double, duration: Double) {
            self.from = from
            self.to = to
            self.start = start
            self.duration = duration
        }
    }

    /// The transform passed to `setTransform(_:at: .zero)` before any ramp.
    /// It is the composition track's preferredTransform, unchanged.
    public struct PictureTransform: Equatable, Sendable {
        public var a: Double
        public var b: Double
        public var c: Double
        public var d: Double
        public var tx: Double
        public var ty: Double

        public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
            self.a = a
            self.b = b
            self.c = c
            self.d = d
            self.tx = tx
            self.ty = ty
        }

        public static func atTimeZero(preferred: PictureTransform) -> PictureTransform {
            preferred
        }
    }

    /// Display size after `preferredTransform`, matching a transformed source rect.
    /// A 90° phone transform turns a landscape buffer into a portrait frame.
    public static func displaySize(
        naturalWidth: Double,
        naturalHeight: Double,
        transform: PictureTransform
    ) -> (width: Double, height: Double) {
        let corners = [
            (0.0, 0.0),
            (naturalWidth, 0.0),
            (0.0, naturalHeight),
            (naturalWidth, naturalHeight),
        ]
        let xs = corners.map { transform.a * $0.0 + transform.c * $0.1 + transform.tx }
        let ys = corners.map { transform.b * $0.0 + transform.d * $0.1 + transform.ty }
        let width = abs((xs.max() ?? 0) - (xs.min() ?? 0))
        let height = abs((ys.max() ?? 0) - (ys.min() ?? 0))
        return (width, height)
    }

    /// Instructions tile `[0, compositionEnd)` with no gaps. Picture ranges are
    /// kept. A leading hole, a hole between clips, and a tail past the picture
    /// are empty slots.
    public static func slots(segments: [Segment], compositionEnd: Double) -> [Slot] {
        let pictures = segments
            .filter { $0.start.isFinite && $0.duration.isFinite && $0.duration > 0.000_05 }
            .sorted { $0.start < $1.start }
        let lastEnd = pictures.map { $0.start + $0.duration }.max() ?? 0
        let end = max(compositionEnd.isFinite ? compositionEnd : 0, lastEnd)
        guard end > 0.000_05 else { return [] }

        var slots: [Slot] = []
        var cursor = 0.0
        func append(from start: Double, to stop: Double, body: Slot.Body) {
            let duration = stop - start
            guard duration > 0.000_05 else { return }
            slots.append(Slot(start: start, duration: duration, body: body))
        }

        for picture in pictures {
            let start = min(max(0, picture.start), end)
            let stop = min(max(start, picture.start + picture.duration), end)
            if start > cursor + 0.000_05 {
                append(from: cursor, to: start, body: .empty)
            }
            append(
                from: start,
                to: stop,
                body: .picture(fadeIn: picture.fadeIn, fadeOut: picture.fadeOut)
            )
            cursor = stop
        }
        if end > cursor + 0.000_05 {
            append(from: cursor, to: end, body: .empty)
        }
        return slots
    }

    /// The same ramp lengths the player used before this coverage fix.
    /// Fade-in is at most half the segment and runs 0→1 from the segment start.
    /// Fade-out uses what remains and runs 1→0 at the end of the segment.
    /// A length of 0.01 or less is not ramped. This never emits a hold at time zero.
    public static func opacityRamps(
        start: Double,
        duration: Double,
        fadeIn: Double,
        fadeOut: Double
    ) -> [OpacityRamp] {
        let span = duration.isFinite ? max(0, duration) : 0
        let rise = fadeIn.isFinite ? min(max(0, fadeIn), span / 2) : 0
        let fall = fadeOut.isFinite ? min(max(0, fadeOut), max(0, span - rise)) : 0
        var ramps: [OpacityRamp] = []
        if rise > 0.01 {
            ramps.append(OpacityRamp(from: 0, to: 1, start: start, duration: rise))
        }
        if fall > 0.01 {
            ramps.append(OpacityRamp(from: 1, to: 0, start: start + span - fall, duration: fall))
        }
        return ramps
    }
}
