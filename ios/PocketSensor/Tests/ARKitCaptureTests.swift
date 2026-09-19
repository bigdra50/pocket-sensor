import ARKit
import XCTest
@testable import PocketSensor

final class ARKitCaptureTests: XCTestCase {
    func testTrackingLabelMatchesWireTokens() {
        XCTAssertEqual(ARKitCapture.trackingLabel(.normal), "normal")
        XCTAssertEqual(ARKitCapture.trackingLabel(.notAvailable), "unavailable")
        XCTAssertEqual(ARKitCapture.trackingLabel(.limited(.initializing)), "limited:initializing")
        XCTAssertEqual(ARKitCapture.trackingLabel(.limited(.excessiveMotion)), "limited:excessive_motion")
        XCTAssertEqual(ARKitCapture.trackingLabel(.limited(.insufficientFeatures)), "limited:insufficient_features")
        XCTAssertEqual(ARKitCapture.trackingLabel(.limited(.relocalizing)), "limited:relocalizing")
    }
}
