import CoreGraphics
import Foundation

/// 3x3 projective transform, row-major (`m[0..8]`), homogeneous coordinates.
public struct Homography3: Equatable {
    public var m: [Double]

    public init(m: [Double]) {
        precondition(m.count == 9)
        self.m = m
    }

    public static let identity = Homography3(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    public subscript(row: Int, col: Int) -> Double {
        get { m[row * 3 + col] }
        set { m[row * 3 + col] = newValue }
    }

    public static func * (a: Homography3, b: Homography3) -> Homography3 {
        var out = [Double](repeating: 0, count: 9)
        for r in 0..<3 {
            for c in 0..<3 {
                var s = 0.0
                for k in 0..<3 { s += a[r, k] * b[k, c] }
                out[r * 3 + c] = s
            }
        }
        return Homography3(m: out)
    }

    public func apply(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        let w = self[2, 0] * x + self[2, 1] * y + self[2, 2]
        guard abs(w) > 1e-12 else {
            return CGPoint(x: .nan, y: .nan)
        }
        let xx = (self[0, 0] * x + self[0, 1] * y + self[0, 2]) / w
        let yy = (self[1, 0] * x + self[1, 1] * y + self[1, 2]) / w
        return CGPoint(x: xx, y: yy)
    }

    /// Full 3x3 inverse (adjugate / determinant). Returns nil for degenerate matrices.
    public func inverted() -> Homography3? {
        let a = m
        let det =
            a[0] * (a[4] * a[8] - a[5] * a[7])
            - a[1] * (a[3] * a[8] - a[5] * a[6])
            + a[2] * (a[3] * a[7] - a[4] * a[6])
        guard abs(det) > 1e-12 else { return nil }
        let inv = [
            (a[4] * a[8] - a[5] * a[7]) / det,
            (a[1] * a[8] - a[2] * a[7]) / det,
            (a[2] * a[5] - a[1] * a[4]) / det,
            (a[5] * a[6] - a[3] * a[8]) / det,
            (a[0] * a[8] - a[2] * a[6]) / det,
            (a[2] * a[3] - a[0] * a[5]) / det,
            (a[3] * a[7] - a[4] * a[6]) / det,
            (a[1] * a[6] - a[0] * a[7]) / det,
            (a[0] * a[4] - a[1] * a[3]) / det,
        ]
        return Homography3(m: inv)
    }

    /// Direct linear transform: the projective map sending `src` (4 corners) onto `dst`.
    /// Coordinates are normalized before solving and denormalized afterwards, which keeps
    /// the 8x8 linear system well conditioned for full-resolution pixel coordinates.
    /// Order matters: corners must correspond (e.g. TL, TR, BR, BL).
    public static func fromQuad(_ src: [CGPoint], to dst: [CGPoint]) -> Homography3? {
        guard src.count == 4, dst.count == 4 else { return nil }

        let srcT = Self.normalizingTransform(for: src)
        let dstT = Self.normalizingTransform(for: dst)
        guard let srcTInv = srcT?.inverted(), let dstT = dstT else { return nil }

        var ns = [CGPoint](), nd = [CGPoint]()
        for i in 0..<4 {
            ns.append(srcT!.apply(src[i]))
            nd.append(dstT.apply(dst[i]))
        }

        var a = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8)
        var b = [Double](repeating: 0, count: 8)
        for i in 0..<4 {
            let x = Double(ns[i].x), y = Double(ns[i].y)
            let u = Double(nd[i].x), v = Double(nd[i].y)
            a[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y]
            b[2 * i] = u
            a[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y]
            b[2 * i + 1] = v
        }
        guard let h = Self.solveLinearSystem(a: a, b: b) else { return nil }
        let hn = Homography3(m: [h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], 1.0])
        guard let dstInv = dstT.inverted() else { return nil }
        return dstInv * hn * srcTInv
    }

    /// Similarity transform into the unit square for a point set (translation + scale).
    private static func normalizingTransform(for pts: [CGPoint]) -> Homography3? {
        guard let first = pts.first else { return nil }
        var minX = Double(first.x), maxX = minX, minY = Double(first.y), maxY = minY
        for p in pts.dropFirst() {
            minX = min(minX, Double(p.x)); maxX = max(maxX, Double(p.x))
            minY = min(minY, Double(p.y)); maxY = max(maxY, Double(p.y))
        }
        let w = maxX - minX, h = maxY - minY
        guard w > 1e-9, h > 1e-9 else { return nil }
        return Homography3(m: [1.0 / w, 0, -minX / w, 0, 1.0 / h, -minY / h, 0, 0, 1])
    }

    /// Gaussian elimination with partial pivoting (n x n, n = 8 here).
    private static func solveLinearSystem(a: [[Double]], b: [Double]) -> [Double]? {
        let n = b.count
        var m = a
        var y = b
        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<n where abs(m[r][col]) > abs(m[pivot][col]) { pivot = r }
            if abs(m[pivot][col]) < 1e-12 { return nil }
            if pivot != col { m.swapAt(pivot, col); y.swapAt(pivot, col) }
            let pv = m[col][col]
            for c in col..<n { m[col][c] /= pv }
            y[col] /= pv
            for r in 0..<n where r != col {
                let f = m[r][col]
                if f == 0 { continue }
                for c in col..<n { m[r][c] -= f * m[col][c] }
                y[r] -= f * y[col]
            }
        }
        return y
    }
}

/// Ordering of free-form quads into the pipeline convention.
public enum QuadOrdering {
    /// Order 4 corners as TL, TR, BR, BL: clockwise in y-down space, with edge 0
    /// (TL→TR) one of the long edges of the quad. Preserves orientation (never mirrors).
    public static func order(_ pts: [CGPoint]) -> [CGPoint]? {
        guard pts.count == 4 else { return nil }
        let cx = pts.reduce(0) { $0 + Double($1.x) } / 4
        let cy = pts.reduce(0) { $0 + Double($1.y) } / 4
        let p = pts.sorted {
            atan2(Double($0.y) - cy, Double($0.x) - cx) < atan2(Double($1.y) - cy, Double($1.x) - cx)
        }
        guard isValidQuad(p) else { return nil }
        let e0 = hypot(Double(p[1].x - p[0].x), Double(p[1].y - p[0].y))
        let e1 = hypot(Double(p[2].x - p[1].x), Double(p[2].y - p[1].y))
        if e0 >= e1 { return p }
        return [p[1], p[2], p[3], p[0]]
    }

    /// Mean edge-length aspect (long / short); requires a quad ordered TL,TR,BR,BL.
    public static func aspect(_ quad: [CGPoint]) -> Double {
        guard quad.count == 4 else { return 0 }
        let w = (edgeLen(quad[0], quad[1]) + edgeLen(quad[3], quad[2])) / 2
        let h = (edgeLen(quad[1], quad[2]) + edgeLen(quad[0], quad[3])) / 2
        guard h > 1e-9 else { return 0 }
        return w / h
    }

    /// Quad area as a fraction of an image area.
    public static func area(_ quad: [CGPoint]) -> Double {
        guard quad.count == 4 else { return 0 }
        // Shoelace.
        var s = 0.0
        for i in 0..<4 {
            let a = quad[i], b = quad[(i + 1) % 4]
            s += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
        }
        return abs(s) / 2
    }

    public static func edgeLen(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(Double(b.x - a.x), Double(b.y - a.y))
    }

    private static func isValidQuad(_ p: [CGPoint]) -> Bool {
        // No two corners may be degenerate-close; area must be nonzero.
        for i in 0..<4 {
            for j in (i + 1)..<4 where edgeLen(p[i], p[j]) < 1.0 { return false }
        }
        return area(p) > 4.0
    }
}

/// Card-detection sanity gates from docs/ALGORITHM.md §1.
public enum CardQuality {
    public static let cardAspectRatio = 85.60 / 53.98

    public static func isPlausibleCardQuad(_ quad: [CGPoint], imageArea: Double) -> Bool {
        guard quad.count == 4 else { return false }
        let aspect = QuadOrdering.aspect(quad)
        guard aspect >= 1.30, aspect <= 1.90 else { return false }
        guard imageArea > 0, QuadOrdering.area(quad) / imageArea >= 0.15 else { return false }
        return true
    }

    /// Score in [0, ∞); higher = more card-like (area × aspect closeness to ID-1).
    public static func score(_ quad: [CGPoint], imageArea: Double) -> Double {
        let aspect = QuadOrdering.aspect(quad)
        guard aspect > 0 else { return 0 }
        let aspectScore = max(0, 1 - abs(aspect - cardAspectRatio) / 0.5)
        let areaScore = min(1, QuadOrdering.area(quad) / max(imageArea, 1))
        return aspectScore * areaScore
    }
}
