import ARKit
import CoreVideo
import Foundation
import QuartzCore
import simd

/// ARKit の 1 フレーム。単位変換も座標変換もしていない。
struct ARFrameSample {
    /// 届けたフレームの通し番号（1 始まり）
    var index: UInt64
    var timestamp: TimeInterval
    /// コールバック入口で測った `CACurrentMediaTime()`。`timestamp` との差で時計を診断する
    var arrivalMediaTime: CFTimeInterval
    var cameraTransform: simd_float4x4
    var intrinsics: simd_float3x3
    var imageResolution: CGSize
    var trackingState: ARCamera.TrackingState
    var capturedImage: CVPixelBuffer
    var depthMap: CVPixelBuffer?
    var confidenceMap: CVPixelBuffer?
    var imageAnchors: [(name: String, transform: simd_float4x4, isTracked: Bool)]
}

/// ARSession を回し、届いた `ARFrame` を加工せず callback へ渡す。
///
/// 状態は ARKit の delegate queue（`queue`）に閉じる。他のキューから呼べるのは queue へ飛ばすメソッドだけなので、
/// `@unchecked Sendable` はこの規約を言い切っているだけで、コンパイラは検査しない。
final class ARKitCapture: NSObject, ARSessionDelegate, @unchecked Sendable {
    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    private let session = ARSession()
    private let queue = DispatchQueue(label: "pocketsensor.arkit")
    private let frames = HandlerList<ARFrameSample>()
    private var deliveredIndex: UInt64 = 0
    private var depthEnabled = false
    private var sessionRunning = false

    func onFrame(_ handler: @escaping (ARFrameSample) -> Void) {
        frames.add(handler)
    }

    func start(reset: Bool, depth: Bool) {
        session.delegate = self
        session.delegateQueue = queue
        queue.async {
            self.depthEnabled = depth
            self.run(reset: reset)
        }
    }

    /// 動作中に深度の要否だけを変える。reset しないので world 原点は保つ。
    func setDepth(_ depth: Bool) {
        queue.async {
            guard self.sessionRunning else { return }
            guard self.depthEnabled != depth else { return }
            self.depthEnabled = depth
            self.run(reset: false)
        }
    }

    func pause() {
        queue.async {
            self.session.pause()
            self.sessionRunning = false
        }
    }

    /// world 原点を作り直す。消費側への不連続の知らせは呼び出し側が持つ。
    func resetOrigin() {
        queue.async {
            guard self.sessionRunning else { return }
            self.run(reset: true)
        }
    }

    /// 平面検出と環境テクスチャは自己位置に要らず、CPU と熱を使う。
    /// smoothedSceneDepth は時間平滑で移動体に残像が出るので sceneDepth を使う。
    static func makeConfiguration(depth: Bool) -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        // gravityAndHeading は方位センサの揺れを拾うので使わない
        configuration.worldAlignment = .gravity
        configuration.planeDetection = []
        configuration.environmentTexturing = .none
        if depth, ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        if let images = ARReferenceImage.referenceImages(inGroupNamed: "Anchors", bundle: nil), !images.isEmpty {
            configuration.detectionImages = images
            // 検出だけ（0）にすると anchor の transform が検出時のまま古くなり、isTracked も更新されない。
            // 1 枚の追跡なら CPU は小さく、視野に入っている間だけ新しい transform が届く
            configuration.maximumNumberOfTrackedImages = 1
        }
        return configuration
    }

    /// queue 上の実装
    private func run(reset: Bool) {
        let configuration = Self.makeConfiguration(depth: depthEnabled)
        session.run(configuration, options: reset ? [.resetTracking, .removeExistingAnchors] : [])
        sessionRunning = true
    }

    static func trackingLabel(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal:
            return "normal"
        case .notAvailable:
            return "unavailable"
        case .limited(let reason):
            switch reason {
            case .initializing: return "limited:initializing"
            case .excessiveMotion: return "limited:excessive_motion"
            case .insufficientFeatures: return "limited:insufficient_features"
            case .relocalizing: return "limited:relocalizing"
            @unknown default: return "limited:unknown"
            }
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let arrivalMediaTime = CACurrentMediaTime()
        deliveredIndex += 1
        let anchors: [(name: String, transform: simd_float4x4, isTracked: Bool)] = frame.anchors.compactMap { anchor in
            guard let image = anchor as? ARImageAnchor else { return nil }
            return (image.referenceImage.name ?? "unnamed", image.transform, image.isTracked)
        }
        let sample = ARFrameSample(
            index: deliveredIndex,
            timestamp: frame.timestamp,
            arrivalMediaTime: arrivalMediaTime,
            cameraTransform: frame.camera.transform,
            intrinsics: frame.camera.intrinsics,
            imageResolution: frame.camera.imageResolution,
            trackingState: frame.camera.trackingState,
            capturedImage: frame.capturedImage,
            depthMap: frame.sceneDepth?.depthMap,
            confidenceMap: frame.sceneDepth?.confidenceMap,
            imageAnchors: anchors
        )
        frames.emit(sample)
    }

    /// 中断（電話、バックグラウンド）から戻ったら、原点を保ったまま再局所化を試す。
    /// 諦めて作り直す判断は人が Reset で行う
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        true
    }
}
