import XCTest
@testable import StudioAudioLane

final class PrecisionEditingTests: XCTestCase {
    @MainActor
    func testFrameMillisecondAndSampleNudges() {
        let model = EditorModel()
        model.isLoading = false
        let video = clip(start: 1, trackID: EditorModel.defaultVideoTrackID)
        model.videoClips = [video]
        model.selectedClipID = video.id
        model.selectedClipIDs = [video.id]

        XCTAssertTrue(model.nudgeSelectedByFrames(1))
        XCTAssertEqual(
            model.videoClips[0].timelineStart,
            1 + 1 / model.exportSourceFPS,
            accuracy: 0.000_001
        )
        XCTAssertTrue(model.nudgeSelectedByFrames(10))
        XCTAssertEqual(
            model.videoClips[0].timelineStart,
            1 + 11 / model.exportSourceFPS,
            accuracy: 0.000_001
        )

        let audio = clip(start: 2, trackID: EditorModel.defaultAudioTrackID)
        model.audioClips = [audio]
        model.selectedClipID = audio.id
        model.selectedClipIDs = [audio.id]
        XCTAssertTrue(model.nudgeSelectedAudio(milliseconds: -1))
        XCTAssertEqual(model.audioClips[0].timelineStart, 1.999, accuracy: 0.000_001)
        XCTAssertTrue(model.nudgeSelectedAudio(samples: 1))
        XCTAssertEqual(
            model.audioClips[0].timelineStart,
            1.999 + 1.0 / 48_000,
            accuracy: 0.000_001
        )
    }

    @MainActor
    func testNumericStartInPointDurationAndGain() {
        let model = EditorModel()
        model.isLoading = false
        let first = clip(start: 2, inPoint: 1, duration: 4, trackID: EditorModel.defaultVideoTrackID)
        let second = clip(start: 5, inPoint: 2, duration: 4, trackID: EditorModel.defaultVideoTrackID)
        model.videoClips = [first, second]
        model.selectedClipID = first.id
        model.selectedClipIDs = [first.id, second.id]

        model.setSelectedTimelineStart(3)
        XCTAssertEqual(model.videoClips[0].timelineStart, 3, accuracy: 0.000_001)
        XCTAssertEqual(model.videoClips[1].timelineStart, 6, accuracy: 0.000_001)

        model.setSelectedInPoint(2)
        XCTAssertEqual(model.videoClips[0].inPoint, 2, accuracy: 0.000_001)
        XCTAssertEqual(model.videoClips[1].inPoint, 3, accuracy: 0.000_001)
        XCTAssertEqual(model.videoClips[0].timelineStart, 3, accuracy: 0.000_001)
        XCTAssertEqual(model.videoClips[0].duration, 4, accuracy: 0.000_001)

        model.setClipLength(2.5)
        XCTAssertEqual(model.videoClips[0].duration, 2.5, accuracy: 0.000_001)
        XCTAssertEqual(model.videoClips[1].duration, 2.5, accuracy: 0.000_001)

        model.setSelectedClipGain(0.375)
        XCTAssertEqual(model.videoClips[0].gain, 0.375, accuracy: 0.000_001)
        XCTAssertEqual(model.videoClips[1].gain, 0.375, accuracy: 0.000_001)
    }

    @MainActor
    func testSlipKeepsTimelineFootprintAndClampsToSource() {
        let model = EditorModel()
        model.isLoading = false
        let original = clip(
            start: 3,
            inPoint: 1,
            duration: 4,
            sourceDuration: 10,
            trackID: EditorModel.defaultVideoTrackID
        )
        model.videoClips = [original]

        model.slipClip(clipID: original.id, toInPoint: 5)
        XCTAssertEqual(model.videoClips[0].timelineStart, 3, accuracy: 0.000_001)
        XCTAssertEqual(model.videoClips[0].duration, 4, accuracy: 0.000_001)
        XCTAssertEqual(model.videoClips[0].inPoint, 5, accuracy: 0.000_001)

        model.slipClip(clipID: original.id, toInPoint: 99)
        XCTAssertEqual(model.videoClips[0].inPoint, 6, accuracy: 0.000_001)
    }

    @MainActor
    func testMomentarySnapBypass() {
        let model = EditorModel()
        model.isLoading = false
        model.timelineViewportWidth = 1_100
        let moving = clip(start: 0.5, trackID: EditorModel.defaultVideoTrackID)
        let target = clip(start: 2, trackID: EditorModel.defaultVideoTrackID)
        model.videoClips = [moving, target]

        model.moveClip(clipID: moving.id, toStart: 1.99, snapping: true)
        XCTAssertEqual(model.videoClips[0].timelineStart, 2, accuracy: 0.000_001)

        model.moveClip(clipID: moving.id, toStart: 1.97, snapping: false)
        XCTAssertEqual(model.videoClips[0].timelineStart, 1.97, accuracy: 0.000_001)
    }

    @MainActor
    func testMultiSelectionExtendsTrimsAndFadesTogether() {
        let model = EditorModel()
        model.isLoading = false
        let first = clip(start: 0, inPoint: 1, duration: 4, trackID: EditorModel.defaultAudioTrackID)
        let second = clip(start: 6, inPoint: 2, duration: 3, trackID: EditorModel.defaultAudioTrackID)
        model.audioClips = [first, second]
        model.selectedClipID = first.id
        model.selectedClipIDs = [first.id, second.id]

        model.trimOut(clipID: first.id, toTimelineTime: 5, snapping: false)
        XCTAssertEqual(model.audioClips[0].duration, 5, accuracy: 0.000_001)
        XCTAssertEqual(model.audioClips[1].duration, 4, accuracy: 0.000_001)

        model.trimIn(clipID: first.id, toTimelineTime: 0.5, snapping: false)
        XCTAssertEqual(model.audioClips[0].timelineStart, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(model.audioClips[1].timelineStart, 6.5, accuracy: 0.000_001)
        XCTAssertEqual(model.audioClips[0].inPoint, 1.5, accuracy: 0.000_001)
        XCTAssertEqual(model.audioClips[1].inPoint, 2.5, accuracy: 0.000_001)

        model.setSelectedFadeIn(0.75)
        model.setSelectedFadeOut(1.25)
        XCTAssertEqual(model.audioClips[0].fadeIn, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(model.audioClips[1].fadeIn, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(model.audioClips[0].fadeOut, 1.25, accuracy: 0.000_001)
        XCTAssertEqual(model.audioClips[1].fadeOut, 1.25, accuracy: 0.000_001)
    }

    func testOptionFineDragUsesOneTenthScale() {
        let normal = TimelinePrecisionMath.dragDelta(
            translation: 100,
            laneWidth: 1_000,
            timelineDuration: 20,
            fine: false
        )
        let fine = TimelinePrecisionMath.dragDelta(
            translation: 100,
            laneWidth: 1_000,
            timelineDuration: 20,
            fine: true
        )
        XCTAssertEqual(normal, 2, accuracy: 0.000_001)
        XCTAssertEqual(fine, 0.2, accuracy: 0.000_001)
    }

    private func clip(
        start: TimeInterval,
        inPoint: TimeInterval = 0,
        duration: TimeInterval = 1,
        sourceDuration: TimeInterval = 20,
        trackID: UUID
    ) -> MediaClip {
        MediaClip(
            id: UUID(),
            url: URL(fileURLWithPath: "/tmp/precision-fixture.mov"),
            name: "Precision",
            sourceDuration: sourceDuration,
            inPoint: inPoint,
            timelineStart: start,
            duration: duration,
            fadeIn: 0,
            fadeOut: 0,
            trackID: trackID
        )
    }
}
