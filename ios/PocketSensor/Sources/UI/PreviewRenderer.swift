import Dispatch
import Foundation
import PocketSensorCore
import PocketSensorMedia
import UIKit

/// 同じ ARFrame から作った RGB と深度。どちらかが欠けても、欠けた側は waiting になる。
struct PreviewPair {
    var rgb: UIImage?
    var depth: UIImage?
}

/// ARKit の queue から呼んでもすぐ戻る。画像はプレビュー用の queue で作る。
///
/// 前の 1 組が終わるまで次のバッファは持たない。配信経路は待たせない。
final class PreviewRenderer: @unchecked Sendable {
    private let scaler = PreviewScaler()
    private var pacer = PreviewPacer(maxRateHz: 30)
    private let queue = DispatchQueue(label: "pocketsensor.preview", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false

    /// 縮小先の幅。1920×1440 なら 480×360。拡大はしない。
    static let rgbTargetWidth = 480

    func submit(_ sample: ARFrameSample, deliver: @escaping (PreviewPair) -> Void) {
        lock.lock()
        let accepted = pacer.shouldRender(timestamp: sample.timestamp, busy: busy)
        if accepted {
            busy = true
        }
        lock.unlock()
        guard accepted else { return }

        let color = sample.capturedImage
        let depthMap = sample.depthMap
        queue.async { [scaler] in
            let rgb = scaler.cgImage(from: color, targetWidth: Self.rgbTargetWidth).map { UIImage(cgImage: $0) }
            let depth = depthMap.flatMap { DepthPreview.image(of: $0) }
            self.lock.lock()
            self.busy = false
            self.lock.unlock()
            deliver(PreviewPair(rgb: rgb, depth: depth))
        }
    }
}
