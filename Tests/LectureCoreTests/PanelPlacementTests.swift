import XCTest
import CoreGraphics
@testable import LectureCore

final class PanelPlacementTests: XCTestCase {
    func testVisibleUserPositionIsPreserved() {
        let frame = CGRect(x: 200, y: 220, width: 340, height: 420)
        XCTAssertEqual(PanelPlacement.clamped(frame, to: [CGRect(x: 0, y: 0, width: 1440, height: 875)]), frame)
    }
    func testPanelCannotDisappearBeyondScreenEdges() {
        let screen = CGRect(x: 0, y: 40, width: 1000, height: 700)
        let result = PanelPlacement.clamped(CGRect(x: 950, y: -80, width: 340, height: 420), to: [screen])
        XCTAssertEqual(result, CGRect(x: 660, y: 40, width: 340, height: 420))
        XCTAssertTrue(screen.contains(result))
    }
    func testSecondaryDisplayWithNegativeCoordinatesIsRetained() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1280, y: 0, width: 1280, height: 800)]
        let frame = CGRect(x: -850, y: 150, width: 340, height: 420)
        XCTAssertEqual(PanelPlacement.clamped(frame, to: screens), frame)
    }
    func testDisconnectedDisplayReturnsPanelToAvailableScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let result = PanelPlacement.clamped(CGRect(x: -1800, y: 150, width: 340, height: 420), to: [screen])
        XCTAssertTrue(screen.contains(result))
    }
    func testSmallScreenStillKeepsControlsInBounds() {
        let screen = CGRect(x: 0, y: 0, width: 320, height: 400)
        XCTAssertEqual(PanelPlacement.clamped(CGRect(x: 30, y: 30, width: 340, height: 420), to: [screen]), screen)
    }
}
