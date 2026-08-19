import AppKit
import XCTest
@testable import ClipFlow

@MainActor
final class PlaybackCommandTests: XCTestCase {

    func testTextInputsAreExcludedFromWindowShortcutCapture() {
        XCTAssertTrue(KeyBindings.isTextInput(NSTextField()))
        XCTAssertTrue(KeyBindings.isTextInput(NSTextView()))
        XCTAssertFalse(KeyBindings.isTextInput(NSView()))
    }

    func testTransportBarKeepsOnlyFrameNavigationInFrameMode() {
        XCTAssertEqual(
            TransportControl.visible(isFrameStepMode: false),
            [.playPause, .mute, .volume, .speed, .loop]
        )
        XCTAssertEqual(
            TransportControl.visible(isFrameStepMode: true),
            [.playPause, .frameBackward, .frameForward, .mute, .volume, .speed, .loop]
        )
    }

    func testUnloadFileClearsQueuedFileAndTransportState() {
        let controller = PlaybackController()
        let backend = ImmediateReadyBackend()
        controller.attachRenderBackend(backend)
        let url = URL(fileURLWithPath: "/tmp/clipflow-unload-test.mp4")

        controller.loadFile(url)
        XCTAssertEqual(controller.loadedURL, url)

        controller.unloadFile()

        XCTAssertNil(controller.loadedURL)
        XCTAssertFalse(controller.isLoaded)
        XCTAssertTrue(controller.isPaused)
        XCTAssertEqual(controller.currentTime, 0)
        XCTAssertEqual(controller.duration, 0)
    }

    func testVideoRotationCyclesClockwiseBackToZero() {
        let controller = PlaybackController()

        XCTAssertEqual(controller.videoRotationDegrees, 0)
        controller.rotateVideoClockwise()
        XCTAssertEqual(controller.videoRotationDegrees, 90)
        controller.rotateVideoClockwise()
        XCTAssertEqual(controller.videoRotationDegrees, 180)
        controller.rotateVideoClockwise()
        XCTAssertEqual(controller.videoRotationDegrees, 270)
        controller.rotateVideoClockwise()
        XCTAssertEqual(controller.videoRotationDegrees, 0)
    }
}

private final class ImmediateReadyBackend: MPVRenderBackend {
    var onRenderContextReady: (() -> Void)?

    func attach(mpvHandle: OpaquePointer) {
        onRenderContextReady?()
    }

    func detach() {}
}
