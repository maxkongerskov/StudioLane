import XCTest
@testable import StudioAudioLane

final class ProFeaturesTests: XCTestCase {
    func testProFeatureMathAndTransformSanitization() {
        let center = ProFeatureMath.equalPowerPan(0)
        XCTAssertEqual(center.left, Float(sqrt(0.5)), accuracy: 0.000_1)
        XCTAssertEqual(center.right, Float(sqrt(0.5)), accuracy: 0.000_1)
        XCTAssertEqual(ProFeatureMath.equalPowerPan(-1).right, 0, accuracy: 0.000_1)
        XCTAssertEqual(ProFeatureMath.equalPowerPan(1).left, 0, accuracy: 0.000_1)
        XCTAssertLessThanOrEqual(ProFeatureMath.limitedSample(8, enabled: true), 1)
        XCTAssertEqual(
            ProFeatureMath.normalizedGain(current: 0.5, peak: 0.25, targetPeak: 0.9),
            1,
            accuracy: 0.000_1
        )

        var transform = ClipTransform(
            scale: 99,
            positionX: -99,
            positionY: 99,
            rotationDegrees: .infinity,
            opacity: -1
        )
        transform.sanitize()
        XCTAssertEqual(transform.scale, 8)
        XCTAssertEqual(transform.positionX, -2)
        XCTAssertEqual(transform.positionY, 2)
        XCTAssertEqual(transform.rotationDegrees, 0)
        XCTAssertEqual(transform.opacity, 0)
    }

    @MainActor
    func testProControlsAreGatedAndApplyToSelectedClips() {
        let model = EditorModel()
        model.isLoading = false
        let video = clip(trackID: EditorModel.defaultVideoTrackID)
        let audio = clip(trackID: EditorModel.defaultAudioTrackID, waveform: [0.2, 0.5, 0.8])
        model.videoClips = [video]
        model.audioClips = [audio]

        model.selectedClipID = video.id
        model.selectedClipIDs = [video.id]
        model.setSelectedTransform { $0.scale = 2 }
        XCTAssertEqual(model.videoClips[0].transform.scale, 1)

        model.setProMode(true)
        model.setSelectedTransform {
            $0.scale = 2
            $0.positionX = 0.25
        }
        XCTAssertEqual(model.videoClips[0].transform.scale, 2)
        XCTAssertEqual(model.videoClips[0].transform.positionX, 0.25)

        model.currentTime = 1.5
        model.addTransformKeyframeAtPlayhead()
        XCTAssertEqual(model.videoClips[0].transformKeyframes.count, 1)
        XCTAssertEqual(model.videoClips[0].transformKeyframes[0].time, 1.5, accuracy: 0.000_1)

        var transition = ClipTransition(style: .zoom, duration: 0.4)
        model.setSelectedTransition(transition, incoming: true)
        XCTAssertEqual(model.videoClips[0].transitionIn.style, .zoom)
        XCTAssertEqual(model.videoClips[0].transitionIn.duration, 0.4, accuracy: 0.000_1)

        model.selectedClipID = audio.id
        model.selectedClipIDs = [audio.id]
        model.setSelectedPan(-0.6)
        XCTAssertEqual(model.audioClips[0].pan, -0.6, accuracy: 0.000_1)
        model.normalizeSelectedAudio()
        XCTAssertTrue(model.audioClips[0].isNormalized)
        XCTAssertGreaterThan(model.audioClips[0].gain, 0)

        transition.style = .none
        transition.duration = 1
        transition.sanitize(clipDuration: 4)
        XCTAssertEqual(transition.duration, 0)
    }

    @MainActor
    func testProFrameGridSnappingAlignmentAndExportBitrate() {
        let model = EditorModel()
        model.isLoading = false
        model.setProMode(true)
        model.isSnapEnabled = true
        model.timelineViewportWidth = 1_000
        model.timelineSpan = 10
        model.proSettings.snapToClipEdges = false
        model.proSettings.snapToPlayhead = false
        model.proSettings.snapToFrameGrid = true
        model.proSettings.frameRate = 25
        XCTAssertEqual(model.snapTime(1.039), 1.04, accuracy: 0.000_1)

        let first = clip(start: 1, duration: 2, trackID: EditorModel.defaultVideoTrackID)
        let second = clip(start: 5, duration: 1, trackID: EditorModel.defaultAudioTrackID)
        model.videoClips = [first]
        model.audioClips = [second]
        model.selectedClipIDs = [first.id, second.id]
        model.selectedClipID = first.id
        model.alignSelectedClips(.starts)
        XCTAssertEqual(model.videoClips[0].timelineStart, 1, accuracy: 0.000_1)
        XCTAssertEqual(model.audioClips[0].timelineStart, 1, accuracy: 0.000_1)

        var settings = ExportSettings()
        settings.videoBitrateMbps = 12.5
        settings.sanitize()
        XCTAssertTrue(settings.prefersWriterPipeline)
        XCTAssertEqual(settings.videoBitRate(pixelCount: 1920 * 1080), 12_500_000)
    }

    private func clip(
        start: TimeInterval = 0,
        duration: TimeInterval = 4,
        trackID: UUID,
        waveform: [Float] = []
    ) -> MediaClip {
        MediaClip(
            id: UUID(),
            url: URL(fileURLWithPath: "/tmp/pro-fixture.mov"),
            name: "Pro",
            sourceDuration: 20,
            inPoint: 0,
            timelineStart: start,
            duration: duration,
            fadeIn: 0,
            fadeOut: 0,
            trackID: trackID,
            waveform: waveform
        )
    }
}
