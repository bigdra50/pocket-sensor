import SwiftUI
import UIKit

/// 画面（window scene）の向きを追う。RGB-D プレビューを正立させるのに使う。
///
/// 端末の向き（`UIDevice.orientation`）は使わない。回転ロック中や対応外の向きでは画面が回らないので、
/// 端末の向きに合わせるとヒートマップだけが画面とずれて回る。
@MainActor
final class InterfaceOrientationObserver: ObservableObject {
    @Published private(set) var current: UIInterfaceOrientation = .unknown
    private var observation: NSKeyValueObservation?

    /// 最初の window scene を見始める。`effectiveGeometry` は KVO に対応し、回転のたびに通知が来る
    func start() {
        guard observation == nil,
              let scene = UIApplication.shared.connectedScenes.lazy.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        observation = scene.observe(\.effectiveGeometry, options: [.initial, .new]) { [weak self] scene, _ in
            let orientation = scene.effectiveGeometry.interfaceOrientation
            Task { @MainActor in self?.current = orientation }
        }
    }
}
