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

    func testMakeConfigurationInsertsSceneDepthOnlyWhenRequested() {
        let withDepth = ARKitCapture.makeConfiguration(depth: true)
        XCTAssertEqual(withDepth.worldAlignment, .gravity)
        XCTAssertTrue(withDepth.planeDetection.isEmpty)
        XCTAssertEqual(withDepth.environmentTexturing, .none)
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            XCTAssertTrue(withDepth.frameSemantics.contains(.sceneDepth))
        } else {
            XCTAssertFalse(withDepth.frameSemantics.contains(.sceneDepth))
        }

        let withoutDepth = ARKitCapture.makeConfiguration(depth: false)
        XCTAssertFalse(withoutDepth.frameSemantics.contains(.sceneDepth))
        XCTAssertEqual(withoutDepth.worldAlignment, .gravity)
        XCTAssertTrue(withoutDepth.planeDetection.isEmpty)
    }
}
