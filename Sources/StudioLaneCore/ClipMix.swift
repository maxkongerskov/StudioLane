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

    /// Inspector edits (length, fade, gain, fader) hit every highlighted clip.
    /// An empty multi-set still edits the primary clip.
    public static func inspectorEditIDs(selected: Set<UUID>, primary: UUID?) -> Set<UUID> {
        if !selected.isEmpty { return selected }
        if let primary { return [primary] }
        return []
    }
}

/// How a video composition stays valid when the timeline is longer than the picture.
///
/// AVFoundation rejects a composition whose instructions do not tile the whole
/// duration. A rejected composition draws black for every frame while audio
/// keeps playing. Picture slices keep their fades; every other span (a leading
/// gap, a hole, or an audio tail) is an empty slice so the instruction list
/// still reaches `compositionEnd`.
public enum VideoCompositionCoverage {
    public struct PictureSpan: Equatable, Sendable {
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

    public struct Slice: Equatable, Sendable {
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

    /// Fade ramps share a segment without crossing. Fade-in takes at most half;
    /// fade-out takes what remains.
    public static func clampedFades(fadeIn: Double, fadeOut: Double, duration: Double) -> (in: Double, out: Double) {
        let span = duration.isFinite ? max(0, duration) : 0
        let fadeIn = fadeIn.isFinite ? min(max(0, fadeIn), span / 2) : 0
        let fadeOut = fadeOut.isFinite ? min(max(0, fadeOut), max(0, span - fadeIn)) : 0
        return (fadeIn, fadeOut)
    }

    /// Slices tile `[0, compositionEnd)` with no gaps and no overlaps.
    /// Picture is clipped to that range. Adjacent empty spans collapse into one.
    public static func slices(segments: [PictureSpan], compositionEnd: Double) -> [Slice] {
        guard compositionEnd.isFinite, compositionEnd > 0.000_05 else { return [] }
        let end = compositionEnd

        var pictures: [(start: Double, end: Double, fadeIn: Double, fadeOut: Double)] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            guard segment.start.isFinite, segment.duration.isFinite else { continue }
            let rawStart = min(max(0, segment.start), end)
            let rawStop = min(max(rawStart, segment.start + max(0, segment.duration)), end)
            let start = pictures.last.map { max(rawStart, $0.end) } ?? rawStart
            let stop = max(start, rawStop)
            guard stop - start > 0.000_05 else { continue }
            let fades = clampedFades(fadeIn: segment.fadeIn, fadeOut: segment.fadeOut, duration: stop - start)
            pictures.append((start, stop, fades.in, fades.out))
        }

        var slices: [Slice] = []
        var cursor = 0.0
        func append(from start: Double, to stop: Double, body: Slice.Body) {
            let duration = stop - start
            guard duration > 0.000_05 else { return }
            if case .empty = body, let last = slices.last, case .empty = last.body, abs(last.end - start) < 0.000_05 {
                slices[slices.count - 1].duration += duration
                return
            }
            slices.append(Slice(start: start, duration: duration, body: body))
        }

        for picture in pictures {
            if picture.start > cursor + 0.000_05 {
                append(from: cursor, to: picture.start, body: .empty)
            }
            append(
                from: picture.start,
                to: picture.end,
                body: .picture(fadeIn: picture.fadeIn, fadeOut: picture.fadeOut)
            )
            cursor = picture.end
        }
        if end > cursor + 0.000_05 {
            append(from: cursor, to: end, body: .empty)
        }
        return slices
    }

    /// Opacity a full-timeline instruction would show. Empty spans are 0.
    /// Inside a picture, fade-in rises 0→1, the middle holds 1, fade-out falls 1→0.
    public static func opacity(at time: Double, segments: [PictureSpan], compositionEnd: Double) -> Float {
        guard time.isFinite, time >= 0, compositionEnd.isFinite, time < compositionEnd else { return 0 }
        for slice in slices(segments: segments, compositionEnd: compositionEnd) {
            guard time >= slice.start, time < slice.end else { continue }
            switch slice.body {
            case .empty:
                return 0
            case .picture(let fadeIn, let fadeOut):
                let local = time - slice.start
                if fadeIn > 0.000_05, local < fadeIn {
                    return Float(local / fadeIn)
                }
                let fadeOutStart = slice.duration - fadeOut
                if fadeOut > 0.000_05, local > fadeOutStart {
                    let t = (local - fadeOutStart) / fadeOut
                    return Float(1 - min(max(t, 0), 1))
                }
                return 1
            }
        }
        return 0
    }

    /// One tick at the composition timescale. Ramps and holds stay this far apart
    /// so AVFoundation does not treat them as overlapping and reject the frame.
    public static let commandTick: Double = 1.0 / 600.0

    public struct OpacityCommand: Equatable, Sendable {
        public enum Action: Equatable, Sendable {
            case set(Float)
            case ramp(from: Float, to: Float, duration: Double)
        }

        public var time: Double
        public var action: Action

        public init(time: Double, action: Action) {
            self.time = time
            self.action = action
        }

        public var end: Double {
            switch action {
            case .set:
                return time
            case .ramp(_, _, let duration):
                return time + duration
            }
        }
    }

    /// Opacity operations for one instruction that spans the whole composition.
    /// Picture holds at full opacity between its fades. A gap holds at 0 so a
    /// filler frame in that gap stays black. Commands never overlap.
    public static func opacityCommands(segments: [PictureSpan], compositionEnd: Double) -> [OpacityCommand] {
        guard compositionEnd.isFinite, compositionEnd > commandTick else { return [] }
        let tick = commandTick
        var commands: [OpacityCommand] = []

        func append(_ time: Double, _ action: OpacityCommand.Action) {
            guard time.isFinite, time >= 0, time < compositionEnd - tick * 0.25 else { return }
            var command = OpacityCommand(time: time, action: action)
            if let last = commands.last, command.time < last.end + tick * 0.5 {
                let shifted = last.end + tick
                guard shifted < compositionEnd - tick * 0.25 else { return }
                command.time = shifted
            }
            if case .ramp(_, _, let duration) = command.action {
                guard duration > tick * 0.5, command.time + duration <= compositionEnd + 0.000_0001 else { return }
            }
            commands.append(command)
        }

        let tiled = slices(segments: segments, compositionEnd: compositionEnd)
        for (index, slice) in tiled.enumerated() {
            let start = slice.start
            let stop = min(slice.end, compositionEnd)
            guard stop - start > tick else { continue }
            switch slice.body {
            case .empty:
                append(start, .set(0))
            case .picture(let fadeIn, let fadeOut):
                let room = stop - start
                var rise = min(max(0, fadeIn), room / 2)
                var fall = min(max(0, fadeOut), max(0, room - rise))
                if rise > 0, rise < tick { rise = 0 }
                if fall > 0, fall < tick { fall = 0 }
                if rise + fall > room - tick {
                    let overflow = rise + fall - (room - tick)
                    fall = max(0, fall - overflow)
                }
                if rise >= tick {
                    append(start, .ramp(from: 0, to: 1, duration: rise))
                }
                let hold = start + (rise >= tick ? rise + tick : 0)
                let fallStart = stop - fall
                if fall < tick || hold < fallStart - tick * 0.25 {
                    append(min(hold, stop - tick), .set(1))
                }
                if fall >= tick {
                    append(fallStart, .ramp(from: 1, to: 0, duration: fall))
                } else if index + 1 < tiled.count, case .empty = tiled[index + 1].body {
                    append(max(hold + tick, stop - tick), .set(0))
                }
            }
        }
        return commands
    }

    /// Opacity produced by `opacityCommands`. The default before the first command is full.
    public static func opacity(at time: Double, commands: [OpacityCommand]) -> Float {
        guard time.isFinite else { return 0 }
        var value: Float = 1
        for command in commands {
            switch command.action {
            case .set(let opacity):
                if time >= command.time { value = opacity }
            case .ramp(let from, let to, let duration):
                guard duration > 0 else { continue }
                if time >= command.end {
                    value = to
                } else if time >= command.time {
                    let t = Float((time - command.time) / duration)
                    value = from + (to - from) * min(max(t, 0), 1)
                }
            }
        }
        return value
    }
}
