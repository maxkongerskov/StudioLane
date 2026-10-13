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
