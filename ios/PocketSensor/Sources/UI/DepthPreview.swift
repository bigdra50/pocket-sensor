import CoreGraphics
import CoreVideo
import Foundation
import UIKit

/// プレビュー用の深度ヒートマップと、画面へ出すときの枠・向き。
///
/// RGB の縮小は `PreviewScaler` が受け持つ。ここは深度の色付けと、
/// 画面の向きに合わせた表示枠だけを扱う。配信する画素の並びは変えない。
enum DepthPreview {
    /// 色付けの近端（これより近いと赤寄り）
    static let nearM: Float = 0.25
    /// 色付けの遠端（これより遠いと青寄り）
    static let farM: Float = 4.0

    /// 深度配列を RGBA8888 に色付けする（純粋）。無効画素は黒。
    static func rgba(
        depth: [Float], width: Int, height: Int,
        nearM: Float = nearM, farM: Float = farM
    ) -> [UInt8] {
        precondition(depth.count == width * height, "深度配列の長さが合わない")
        precondition(farM > nearM, "farM は nearM より大きい必要がある")
        let span = farM - nearM
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let offset = i * 4
            pixels[offset + 3] = 255
            let z = depth[i]
            guard z > 0, z.isFinite else { continue }
            let t = max(0, min(1, (z - nearM) / span))
            let (r, g, b) = heat(t)
            pixels[offset] = r
            pixels[offset + 1] = g
            pixels[offset + 2] = b
        }
        return pixels
    }

    /// ARKit の depthMap から UIImage を作る。失敗時は nil。
    static func image(of depthMap: CVPixelBuffer) -> UIImage? {
        guard let depth = DepthSummary.floats(from: depthMap) else { return nil }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        return image(rgba: rgba(depth: depth, width: width, height: height), width: width, height: height)
    }

    /// RGB と深度を画面に正立させて表示するための向き。
    ///
    /// ARKit の画素は、画面が回ってもセンサ本来の並び（カメラ群を上にした横持ち、画面の landscapeRight）で届く。
    /// 対応は iPhone の写真の EXIF と同じ。回すのは表示だけである。
    static func displayOrientation(for interface: UIInterfaceOrientation) -> UIImage.Orientation {
        switch interface {
        case .landscapeLeft: return .down
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        // 向きが分かる前は、センサの並びのまま出す
        case .landscapeRight, .unknown: return .up
        @unknown default: return .up
        }
    }

    /// ヒートマップの表示枠。長辺を `long` にして深度マップの縦横比を保ち、横倒しで表示するときは縦長にする。
    static func frameSize(long: CGFloat, for orientation: UIImage.Orientation) -> CGSize {
        // sceneDepth の深度マップは 256×192。RGB も同じ 4:3 なので枠を共有する
        let short = long * 192 / 256
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            return CGSize(width: short, height: long)
        default:
            return CGSize(width: long, height: short)
        }
    }

    /// 2 枚を横に並べたとき可用幅へ収まる長辺。足りなければ縮める。折り返しと切り取りを避ける。
    static func fittedLong(
        preferred: CGFloat,
        availableWidth: CGFloat,
        spacing: CGFloat,
        for orientation: UIImage.Orientation
    ) -> CGFloat {
        let tileWidthBudget = (availableWidth - spacing) / 2
        guard tileWidthBudget > 0 else { return 0 }
        let maxLong: CGFloat
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            maxLong = tileWidthBudget * 256 / 192
        default:
            maxLong = tileWidthBudget
        }
        return min(preferred, maxLong)
    }

    /// 表示の向きだけを付け替える。画素は並べ替えずに同じ CGImage を包み直す。
    static func reoriented(_ image: UIImage, to orientation: UIImage.Orientation) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: orientation)
    }

    /// 近い → 赤、遠い → 青の簡易ヒートマップ。`t` は 0...1。
    static func heat(_ t: Float) -> (UInt8, UInt8, UInt8) {
        // 赤 → 黄 → 緑 → シアン → 青
        let x = max(0, min(1, t))
        let r: Float
        let g: Float
        let b: Float
        switch x {
        case ..<0.25:
            let u = x / 0.25
            r = 1
            g = u
            b = 0
        case ..<0.5:
            let u = (x - 0.25) / 0.25
            r = 1 - u
            g = 1
            b = 0
        case ..<0.75:
            let u = (x - 0.5) / 0.25
            r = 0
            g = 1
            b = u
        default:
            let u = (x - 0.75) / 0.25
            r = 0
            g = 1 - u
            b = 1
        }
        return (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
    }

    private static func image(rgba: [UInt8], width: Int, height: Int) -> UIImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Simulator のレイアウト確認用。近端から遠端への横勾配。
    static func demoGradient() -> UIImage {
        let width = 256
        let height = 192
        var depth = [Float](repeating: 0, count: width * height)
        let span = farM - nearM
        for y in 0 ..< height {
            for x in 0 ..< width {
                depth[y * width + x] = nearM + span * Float(x) / Float(width - 1)
            }
        }
        return image(rgba: rgba(depth: depth, width: width, height: height), width: width, height: height)
            ?? UIImage()
    }

    /// Simulator のレイアウト確認用。左右非対称なので、誤った回転が一目で分かる。
    static func demoColorBars() -> UIImage {
        let width = 256
        let height = 192
        let bars: [(UInt8, UInt8, UInt8)] = [
            (40, 40, 40),
            (192, 192, 0),
            (0, 192, 192),
            (0, 192, 0),
            (192, 0, 192),
            (192, 0, 0),
            (0, 0, 192),
        ]
        let stripe = width / bars.count
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let color = bars[min(x / stripe, bars.count - 1)]
                let offset = (y * width + x) * 4
                pixels[offset] = color.0
                pixels[offset + 1] = color.1
                pixels[offset + 2] = color.2
            }
        }
        // センサ画像の左上。オーバーレイに隠れない大きさにし、90° 回すと別の隅へ移る
        let triangle = 96
        for y in 0 ..< triangle {
            let rowWidth = triangle - y
            for x in 0 ..< rowWidth {
                let offset = (y * width + x) * 4
                pixels[offset] = 255
                pixels[offset + 1] = 255
                pixels[offset + 2] = 255
            }
        }
        return image(rgba: pixels, width: width, height: height) ?? UIImage()
    }
}
