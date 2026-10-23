import XCTest
@testable import StudioAudioLane

final class TimelineZoomTests: XCTestCase {
    @MainActor
    func testTimelineZoomClampsAtBothEnds() {
        let model = EditorModel()

        model.setTimelineZoom(0.01)
        XCTAssertEqual(model.timelineZoom, EditorModel.minTimelineZoom)

        model.setTimelineZoom(10_000)
        XCTAssertEqual(model.timelineZoom, EditorModel.maxTimelineZoom)

        model.setTimelineZoom(4)
        model.zoomIn()
        XCTAssertEqual(model.timelineZoom, 5.4, accuracy: 0.001)
        model.zoomOut()
        XCTAssertEqual(model.timelineZoom, 4, accuracy: 0.001)
    }

    func testPinchZoomPreservesTimelinePointUnderAnchor() {
        let oldOffset: CGFloat = 800
        let viewport: CGFloat = 1_000
        let anchor: CGFloat = 0.25
        let oldWidth: CGFloat = 4_000
        let newWidth: CGFloat = 8_000

        let newOffset = TimelineZoomMath.anchoredOffset(
            oldOffset: oldOffset,
            viewportWidth: viewport,
            anchorFraction: anchor,
            oldDocumentWidth: oldWidth,
            newDocumentWidth: newWidth
        )

        let oldTimelineFraction = (oldOffset + viewport * anchor) / oldWidth
        let newTimelineFraction = (newOffset + viewport * anchor) / newWidth
        XCTAssertEqual(newTimelineFraction, oldTimelineFraction, accuracy: 0.000_001)
    }

    func testAnchoredOffsetClampsAtDocumentEdges() {
        XCTAssertEqual(
            TimelineZoomMath.anchoredOffset(
                oldOffset: 0,
                viewportWidth: 1_000,
                anchorFraction: 0,
                oldDocumentWidth: 1_000,
                newDocumentWidth: 500
            ),
            0
        )

        XCTAssertEqual(
            TimelineZoomMath.anchoredOffset(
                oldOffset: 3_000,
                viewportWidth: 1_000,
                anchorFraction: 1,
                oldDocumentWidth: 4_000,
                newDocumentWidth: 8_000
            ),
            7_000
        )
    }
}
