import XCTest
@testable import StudioLaneCore

final class VideoCompositionPlanTests: XCTestCase {
    func testLateStartingClipWithAFadeCoversFromTimeZero() {
        // The open project: picture begins at 12.748s, fade-out is 1.6s, item ends at 40.474s.
        let picture = VideoCompositionPlan.Segment(start: 12.748, duration: 27.726, fadeIn: 0, fadeOut: 1.6)
        let slots = VideoCompositionPlan.slots(segments: [picture], compositionEnd: 40.474)
        XCTAssertEqual(slots.count, 2)
        XCTAssertEqual(slots[0].body, .empty)
        XCTAssertEqual(slots[0].start, 0, accuracy: 0.0001)
        XCTAssertEqual(slots[0].duration, 12.748, accuracy: 0.0001)
        guard case .picture(let fadeIn, let fadeOut) = slots[1].body else {
            return XCTFail("Expected the picture slot")
        }
        XCTAssertEqual(fadeIn, 0, accuracy: 0.0001)
        XCTAssertEqual(fadeOut, 1.6, accuracy: 0.0001)
        XCTAssertEqual(slots[1].start, 12.748, accuracy: 0.0001)
        XCTAssertEqual(slots[1].duration, 27.726, accuracy: 0.0001)
        assertTiles(slots, end: 40.474)

        let ramps = VideoCompositionPlan.opacityRamps(
            start: slots[1].start,
            duration: slots[1].duration,
            fadeIn: fadeIn,
            fadeOut: fadeOut
        )
        XCTAssertEqual(ramps.count, 1)
        XCTAssertEqual(ramps[0].from, 1, accuracy: 0.0001)
        XCTAssertEqual(ramps[0].to, 0, accuracy: 0.0001)
        XCTAssertEqual(ramps[0].duration, 1.6, accuracy: 0.0001)
        XCTAssertEqual(ramps[0].start, 38.874, accuracy: 0.0001)
        XCTAssertFalse(ramps.contains { $0.start < 0.001 && $0.from < 0.01 })
    }

    func testAudioTailAndAHoleAreEmptyAndTheFadeRampsStayOnThePicture() {
        let picture = VideoCompositionPlan.Segment(start: 0, duration: 4, fadeIn: 0.5, fadeOut: 0.5)
        let tail = VideoCompositionPlan.slots(segments: [picture], compositionEnd: 10)
        XCTAssertEqual(tail.count, 2)
        XCTAssertEqual(tail[1].body, .empty)
        assertTiles(tail, end: 10)
        let ramps = VideoCompositionPlan.opacityRamps(start: 0, duration: 4, fadeIn: 0.5, fadeOut: 0.5)
        XCTAssertEqual(ramps.count, 2)
        XCTAssertEqual(ramps[0].from, 0, accuracy: 0.0001)
        XCTAssertEqual(ramps[0].to, 1, accuracy: 0.0001)
        XCTAssertEqual(ramps[0].start, 0, accuracy: 0.0001)
        XCTAssertEqual(ramps[0].duration, 0.5, accuracy: 0.0001)
        XCTAssertEqual(ramps[1].from, 1, accuracy: 0.0001)
        XCTAssertEqual(ramps[1].to, 0, accuracy: 0.0001)
        XCTAssertEqual(ramps[1].start, 3.5, accuracy: 0.0001)
        XCTAssertEqual(ramps[1].duration, 0.5, accuracy: 0.0001)

        let first = VideoCompositionPlan.Segment(start: 0, duration: 2, fadeIn: 0, fadeOut: 0)
        let second = VideoCompositionPlan.Segment(start: 5, duration: 2, fadeIn: 0.2, fadeOut: 0.2)
        let hole = VideoCompositionPlan.slots(segments: [second, first], compositionEnd: 10)
        XCTAssertEqual(hole.count, 4)
        XCTAssertEqual(hole[1].body, .empty)
        assertTiles(hole, end: 10)
    }

    func testRotatedPortraitFrameUsesThePreferredTransform() {
        // 720p stored sideways. A 90° preferredTransform displays it as 720×1280.
        let preferred = VideoCompositionPlan.PictureTransform(a: 0, b: 1, c: -1, d: 0, tx: 720, ty: 0)
        let applied = VideoCompositionPlan.PictureTransform.atTimeZero(preferred: preferred)
        XCTAssertEqual(applied, preferred)
        let size = VideoCompositionPlan.displaySize(naturalWidth: 1280, naturalHeight: 720, transform: applied)
        XCTAssertEqual(size.width, 720, accuracy: 0.001)
        XCTAssertEqual(size.height, 1280, accuracy: 0.001)

        let landscape = VideoCompositionPlan.PictureTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
        let flat = VideoCompositionPlan.displaySize(naturalWidth: 1280, naturalHeight: 720, transform: landscape)
        XCTAssertEqual(flat.width, 1280, accuracy: 0.001)
        XCTAssertEqual(flat.height, 720, accuracy: 0.001)
    }

    private func assertTiles(_ slots: [VideoCompositionPlan.Slot], end: Double) {
        XCTAssertFalse(slots.isEmpty)
        XCTAssertEqual(slots[0].start, 0, accuracy: 0.0001)
        var cursor = 0.0
        for slot in slots {
            XCTAssertEqual(slot.start, cursor, accuracy: 0.0001)
            XCTAssertGreaterThan(slot.duration, 0)
            XCTAssertLessThanOrEqual(slot.end, end + 0.0001)
            cursor = slot.end
        }
        XCTAssertEqual(cursor, end, accuracy: 0.0001)
    }
}
