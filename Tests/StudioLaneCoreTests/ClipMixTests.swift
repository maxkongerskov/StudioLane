import XCTest
@testable import StudioLaneCore

final class ClipMixTests: XCTestCase {
    func testSplitGivesEachPieceItsOwnFaderCopy() {
        let original = ClipMix.Settings(gain: 0.8, fadeIn: 0.4, fadeOut: 0.6, muted: false, fader: nil)
        var pieces = ClipMix.splitPieces(from: original, laneVolume: 0.62, rightDuration: 4)
        XCTAssertEqual(pieces.left.fader, Float(0.62))
        XCTAssertEqual(pieces.right.fader, Float(0.62))
        XCTAssertEqual(pieces.left.gain, Float(0.8))
        XCTAssertEqual(pieces.right.gain, Float(0.8))
        XCTAssertEqual(pieces.left.fadeOut, 0, accuracy: 0.0001)
        XCTAssertEqual(pieces.right.fadeIn, 0, accuracy: 0.0001)
        XCTAssertFalse(pieces.left.muted)
        XCTAssertFalse(pieces.right.muted)

        pieces.left.fader = 0.15
        pieces.left.gain = 0.2
        pieces.left.muted = true
        XCTAssertEqual(pieces.right.fader, Float(0.62))
        XCTAssertEqual(pieces.right.gain, Float(0.8))
        XCTAssertFalse(pieces.right.muted)

        let leftLevel = ClipMix.level(fader: pieces.left.fader, laneVolume: 0.62, gain: pieces.left.gain, muted: pieces.left.muted)
        let rightLevel = ClipMix.level(fader: pieces.right.fader, laneVolume: 0.62, gain: pieces.right.gain, muted: pieces.right.muted)
        XCTAssertEqual(leftLevel, 0, accuracy: 0.0001)
        XCTAssertEqual(rightLevel, Float(0.62) * Float(0.8), accuracy: 0.0001)
    }

    func testExplicitFaderDoesNotFollowTheLane() {
        let lane: Float = 0.9
        XCTAssertEqual(ClipMix.faderOrLane(nil, laneVolume: lane), lane)
        XCTAssertEqual(ClipMix.faderOrLane(0.25, laneVolume: lane), 0.25)
        XCTAssertEqual(
            ClipMix.level(fader: 0.25, laneVolume: lane, gain: 0.5, muted: false),
            0.125,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ClipMix.level(fader: nil, laneVolume: lane, gain: 0.5, muted: false),
            Float(0.9) * Float(0.5),
            accuracy: 0.0001
        )
    }

    func testClickSelectsOnlyThatSegment() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let lane = Set([a, b, c])
        XCTAssertEqual(ClipMix.selectionAfterClick(clipID: b, extending: false, selected: lane), [b])
        let shifted = ClipMix.selectionAfterClick(clipID: c, extending: true, selected: [b])
        XCTAssertEqual(shifted, [b, c])
        XCTAssertEqual(ClipMix.selectionAfterClick(clipID: b, extending: true, selected: shifted), [c])
    }

    func testCutSelectsOnlyThePieceUnderThePlayhead() {
        let right = UUID()
        XCTAssertEqual(ClipMix.selectionAfterSplit(primaryID: right), [right])
        XCTAssertTrue(ClipMix.selectionAfterSplit(primaryID: nil).isEmpty)
    }

    func testLegacyClipJSONWithoutFaderStillDecodes() throws {
        let json = """
        {"gain":0.8,"fadeIn":0.25,"fadeOut":0.5,"muted":false}
        """.data(using: .utf8)!
        let clip = try JSONDecoder().decode(LegacyClipAudio.self, from: json)
        XCTAssertNil(clip.fader)
        XCTAssertEqual(clip.gain, Float(0.8))
        XCTAssertEqual(clip.fadeIn, 0.25, accuracy: 0.0001)
        XCTAssertEqual(ClipMix.faderOrLane(clip.fader, laneVolume: 1), 1)

        let encoded = try JSONEncoder().encode(clip)
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        XCTAssertNil(object["fader"])
        let gain = object["gain"] as? Double
        XCTAssertNotNil(gain)
        XCTAssertEqual(gain ?? -1, 0.8, accuracy: 0.0001)
    }

    func testNonFiniteFaderIsTreatedAsAbsent() {
        XCTAssertNil(ClipMix.normalizedFader(nil))
        XCTAssertNil(ClipMix.normalizedFader(.nan))
        XCTAssertNil(ClipMix.normalizedFader(.infinity))
        XCTAssertEqual(ClipMix.normalizedFader(1.4), 1)
        XCTAssertEqual(ClipMix.normalizedFader(-0.2), 0)
    }

    func testInspectorEditHitsEveryHighlightedClip() {
        let video = UUID()
        let audio = UUID()
        XCTAssertEqual(ClipMix.inspectorEditIDs(selected: [video, audio], primary: video), [video, audio])
        XCTAssertEqual(ClipMix.inspectorEditIDs(selected: [video], primary: video), [video])
        XCTAssertEqual(ClipMix.inspectorEditIDs(selected: [], primary: audio), [audio])
        XCTAssertTrue(ClipMix.inspectorEditIDs(selected: [], primary: nil).isEmpty)
    }

    func testShorterVideoWithAFadeKeepsTheMiddleOpaqueAndTheAudioTailClear() {
        let picture = VideoCompositionCoverage.PictureSpan(start: 0, duration: 4, fadeIn: 0.5, fadeOut: 0.5)
        let slices = VideoCompositionCoverage.slices(segments: [picture], compositionEnd: 10)
        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(slices[0].body, .picture(fadeIn: 0.5, fadeOut: 0.5))
        XCTAssertEqual(slices[1].body, .empty)
        assertTiles(slices, end: 10)

        XCTAssertEqual(VideoCompositionCoverage.opacity(at: 0, segments: [picture], compositionEnd: 10), 0, accuracy: 0.0001)
        XCTAssertEqual(VideoCompositionCoverage.opacity(at: 0.25, segments: [picture], compositionEnd: 10), 0.5, accuracy: 0.0001)
        XCTAssertEqual(VideoCompositionCoverage.opacity(at: 2, segments: [picture], compositionEnd: 10), 1, accuracy: 0.0001)
        XCTAssertEqual(VideoCompositionCoverage.opacity(at: 3.75, segments: [picture], compositionEnd: 10), 0.5, accuracy: 0.0001)
        XCTAssertEqual(VideoCompositionCoverage.opacity(at: 6, segments: [picture], compositionEnd: 10), 0, accuracy: 0.0001)
    }

    func testLeadingGapAndHoleBecomeEmptySlices() {
        let leading = VideoCompositionCoverage.PictureSpan(start: 2, duration: 4, fadeIn: 0, fadeOut: 0)
        let leadingSlices = VideoCompositionCoverage.slices(segments: [leading], compositionEnd: 10)
        XCTAssertEqual(leadingSlices.map(\.body), [.empty, .picture(fadeIn: 0, fadeOut: 0), .empty])
        assertTiles(leadingSlices, end: 10)
        XCTAssertEqual(VideoCompositionCoverage.opacity(at: 1, segments: [leading], compositionEnd: 10), 0, accuracy: 0.0001)
        XCTAssertEqual(VideoCompositionCoverage.opacity(at: 4, segments: [leading], compositionEnd: 10), 1, accuracy: 0.0001)

        let first = VideoCompositionCoverage.PictureSpan(start: 0, duration: 2, fadeIn: 0, fadeOut: 0)
        let second = VideoCompositionCoverage.PictureSpan(start: 5, duration: 2, fadeIn: 0.2, fadeOut: 0.2)
        let hole = VideoCompositionCoverage.slices(segments: [second, first], compositionEnd: 10)
        XCTAssertEqual(hole.count, 4)
        XCTAssertEqual(hole[1].body, .empty)
        assertTiles(hole, end: 10)
        XCTAssertEqual(VideoCompositionCoverage.opacity(at: 3, segments: [first, second], compositionEnd: 10), 0, accuracy: 0.0001)
        XCTAssertEqual(VideoCompositionCoverage.opacity(at: 6, segments: [first, second], compositionEnd: 10), 1, accuracy: 0.0001)
    }

    func testAbuttingPictureSlicesHaveNoEmptyGap() {
        let left = VideoCompositionCoverage.PictureSpan(start: 0, duration: 4, fadeIn: 0, fadeOut: 0)
        let right = VideoCompositionCoverage.PictureSpan(start: 4, duration: 4, fadeIn: 0, fadeOut: 0)
        let slices = VideoCompositionCoverage.slices(segments: [left, right], compositionEnd: 8)
        XCTAssertEqual(slices.count, 2)
        XCTAssertFalse(slices.contains { if case .empty = $0.body { return true }; return false })
        assertTiles(slices, end: 8)
        XCTAssertEqual(VideoCompositionCoverage.opacity(at: 3.9, segments: [left, right], compositionEnd: 8), 1, accuracy: 0.0001)
        XCTAssertEqual(VideoCompositionCoverage.opacity(at: 4, segments: [left, right], compositionEnd: 8), 1, accuracy: 0.0001)
    }

    func testOpacityCommandsKeepThePictureUpAndTheTailClear() {
        let picture = VideoCompositionCoverage.PictureSpan(start: 0, duration: 4, fadeIn: 0.5, fadeOut: 0.5)
        let commands = VideoCompositionCoverage.opacityCommands(segments: [picture], compositionEnd: 10)
        assertCommandsDoNotOverlap(commands, end: 10)
        XCTAssertGreaterThan(VideoCompositionCoverage.opacity(at: 2, commands: commands), 0.95)
        XCTAssertLessThan(VideoCompositionCoverage.opacity(at: 6, commands: commands), 0.05)
        XCTAssertEqual(VideoCompositionCoverage.opacity(at: 0.25, commands: commands), 0.5, accuracy: 0.02)

        let left = VideoCompositionCoverage.PictureSpan(start: 0, duration: 4, fadeIn: 0, fadeOut: 0)
        let right = VideoCompositionCoverage.PictureSpan(start: 4, duration: 4, fadeIn: 0, fadeOut: 0)
        let abutting = VideoCompositionCoverage.opacityCommands(segments: [left, right], compositionEnd: 8)
        assertCommandsDoNotOverlap(abutting, end: 8)
        XCTAssertGreaterThan(VideoCompositionCoverage.opacity(at: 3.9, commands: abutting), 0.95)
        XCTAssertGreaterThan(VideoCompositionCoverage.opacity(at: 4, commands: abutting), 0.95)
    }

    func testFadesStayInsideThePictureSlice() {
        let fades = VideoCompositionCoverage.clampedFades(fadeIn: 10, fadeOut: 10, duration: 4)
        XCTAssertLessThanOrEqual(fades.in, 2)
        XCTAssertLessThanOrEqual(fades.in + fades.out, 4)
        let span = VideoCompositionCoverage.PictureSpan(start: 0, duration: 4, fadeIn: 10, fadeOut: 10)
        let slices = VideoCompositionCoverage.slices(segments: [span], compositionEnd: 4)
        XCTAssertEqual(slices.count, 1)
        guard case .picture(let fadeIn, let fadeOut) = slices[0].body else {
            return XCTFail("Expected a picture slice")
        }
        XCTAssertEqual(fadeIn, fades.in, accuracy: 0.0001)
        XCTAssertEqual(fadeOut, fades.out, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(slices[0].end, 4.0001)
    }

    private func assertCommandsDoNotOverlap(_ commands: [VideoCompositionCoverage.OpacityCommand], end: Double) {
        XCTAssertFalse(commands.isEmpty)
        var cursor = -1.0
        for command in commands {
            XCTAssertGreaterThan(command.time, cursor)
            XCTAssertLessThan(command.time, end)
            if case .ramp(_, _, let duration) = command.action {
                XCTAssertGreaterThan(duration, 0)
                XCTAssertLessThanOrEqual(command.end, end + 0.0001)
                cursor = command.end - 0.000_0001
            } else {
                cursor = command.time
            }
        }
    }

    private func assertTiles(_ slices: [VideoCompositionCoverage.Slice], end: Double) {
        XCTAssertFalse(slices.isEmpty)
        XCTAssertEqual(slices[0].start, 0, accuracy: 0.0001)
        var cursor = 0.0
        for slice in slices {
            XCTAssertEqual(slice.start, cursor, accuracy: 0.0001)
            XCTAssertGreaterThan(slice.duration, 0)
            XCTAssertLessThanOrEqual(slice.end, end + 0.0001)
            cursor = slice.end
        }
        XCTAssertEqual(cursor, end, accuracy: 0.0001)
    }
}

/// Mirrors `MediaClip`'s fader key: missing or non-finite stays nil, and nil is
/// omitted on save so an untouched project file is not rewritten.
private struct LegacyClipAudio: Codable {
    var gain: Float
    var fadeIn: Double
    var fadeOut: Double
    var muted: Bool
    var fader: Float?

    enum CodingKeys: String, CodingKey {
        case gain, fadeIn, fadeOut, muted, fader
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gain = try c.decodeIfPresent(Float.self, forKey: .gain) ?? 1
        fadeIn = try c.decode(Double.self, forKey: .fadeIn)
        fadeOut = try c.decode(Double.self, forKey: .fadeOut)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        fader = ClipMix.normalizedFader(try c.decodeIfPresent(Float.self, forKey: .fader))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(gain, forKey: .gain)
        try c.encode(fadeIn, forKey: .fadeIn)
        try c.encode(fadeOut, forKey: .fadeOut)
        try c.encode(muted, forKey: .muted)
        try c.encodeIfPresent(fader, forKey: .fader)
    }
}
