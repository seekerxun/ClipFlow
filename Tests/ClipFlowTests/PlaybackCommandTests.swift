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
}
