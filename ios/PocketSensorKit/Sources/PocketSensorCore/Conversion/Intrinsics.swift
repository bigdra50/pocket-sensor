import simd

/// ピンホールの内部パラメータ。画素の中心を原点とする。
public struct Intrinsics: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var fx: Double
    public var fy: Double
    public var cx: Double
    public var cy: Double

    public init(width: Int, height: Int, fx: Double, fy: Double, cx: Double, cy: Double) {
        self.width = width
        self.height = height
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
    }

    /// ARKit の 3x3 は列優先。fx = m[0][0]、fy = m[1][1]、cx = m[2][0]、cy = m[2][1]。
    public init(arkitMatrix m: simd_double3x3, width: Int, height: Int) {
        self.width = width
        self.height = height
        fx = m[0][0]
        fy = m[1][1]
        cx = m[2][0]
        cy = m[2][1]
    }

    /// 画素中心を原点とする規約で、主点へ 0.5 の補正を入れて縮尺する。
    public func scaled(toWidth newWidth: Int, height newHeight: Int) -> Intrinsics {
        let sx = Double(newWidth) / Double(width)
        let sy = Double(newHeight) / Double(height)
        return Intrinsics(
            width: newWidth,
            height: newHeight,
            fx: fx * sx,
            fy: fy * sy,
            cx: (cx + 0.5) * sx - 0.5,
            cy: (cy + 0.5) * sy - 0.5
        )
    }

    /// K は行優先 9。
    public var k: [Double] {
        [fx, 0.0, cx, 0.0, fy, cy, 0.0, 0.0, 1.0]
    }

    public var r: [Double] {
        [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
    }

    /// P は [K | 0] の行優先 12。
    public var p: [Double] {
        [fx, 0.0, cx, 0.0, 0.0, fy, cy, 0.0, 0.0, 0.0, 1.0, 0.0]
    }

    /// plumb_bob の係数。ARKit は歪みを出さないので 0 を 5 つ。
    public var d: [Double] {
        [0.0, 0.0, 0.0, 0.0, 0.0]
    }
}
