import Foundation

/// Per-clip mix values and the selection rules that keep a scissor cut editable
/// one segment at a time.
///
/// Lane volume stays a master for clips that have never been given their own
/// fader (`fader == nil`). A cut materializes that level onto each piece so the
/// pieces no longer share the lane slider. Older project files omit `fader`
/// and keep the shared-lane sound until a segment is edited.
public enum ClipMix {
    public struct Settings: Equatable, Sendable {
        public var gain: Float
        public var fadeIn: Double
        public var fadeOut: Double
        public var muted: Bool
        /// Nil means "follow the lane volume" — the on-disk shape of projects saved
        /// before clips had their own fader.
        public var fader: Float?

        public init(gain: Float, fadeIn: Double, fadeOut: Double, muted: Bool, fader: Float?) {
            self.gain = gain
            self.fadeIn = fadeIn
            self.fadeOut = fadeOut
            self.muted = muted
            self.fader = fader
        }
    }

    /// Absent, null, or non-finite values stay absent so an old file is not rewritten
    /// into a different mix. Out-of-range numbers clamp into 0…1.
    public static func normalizedFader(_ raw: Float?) -> Float? {
        guard let raw, raw.isFinite else { return nil }
        return min(max(raw, 0), 1)
    }

    /// The level a clip actually uses before gain and ducking. An explicit fader
    /// wins; otherwise the clip still follows its lane, which is how saved
    /// projects without a fader key behave.
    public static func faderOrLane(_ fader: Float?, laneVolume: Float) -> Float {
        if let own = normalizedFader(fader) { return own }
        guard laneVolume.isFinite else { return 1 }
        return min(max(laneVolume, 0), 1)
    }

    public static func level(
        fader: Float?,
        laneVolume: Float,
        gain: Float,
        muted: Bool,
        duck: Float = 1
    ) -> Float {
        if muted { return 0 }
        let base = faderOrLane(fader, laneVolume: laneVolume)
        let g = gain.isFinite ? min(max(gain, 0), 1) : 1
        let d = duck.isFinite ? duck : 1
        return base * g * d
    }

    /// Two value copies. Each piece starts from the original mix, with the fader
    /// filled in from the lane when the original was still inheriting it, and the
    /// fade that crossed the razor cleared. Mutating one result does not change
    /// the other.
    public static func splitPieces(
        from original: Settings,
        laneVolume: Float,
        rightDuration: Double
    ) -> (left: Settings, right: Settings) {
        var seeded = original
        seeded.fader = faderOrLane(original.fader, laneVolume: laneVolume)
        seeded.gain = original.gain.isFinite ? min(max(original.gain, 0), 1) : 1

        var left = seeded
        left.fadeOut = 0

        var right = seeded
        right.fadeIn = 0
        let cap = max(0, rightDuration / 2)
        right.fadeOut = min(max(0, original.fadeOut), cap)
        return (left, right)
    }

    /// A plain click replaces the selection with that one segment. Shift-click
    /// toggles it in the existing set.
    public static func selectionAfterClick(clipID: UUID, extending: Bool, selected: Set<UUID>) -> Set<UUID> {
        if !extending { return [clipID] }
        var next = selected
        if next.contains(clipID) {
            next.remove(clipID)
        } else {
            next.insert(clipID)
        }
        return next
    }

    /// After a razor cut, only the piece under the playhead stays selected.
    public static func selectionAfterSplit(primaryID: UUID?) -> Set<UUID> {
        guard let primaryID else { return [] }
        return [primaryID]
    }
}
