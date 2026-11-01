import CoreGraphics
import Foundation

/// Grayscale UInt8 image — the currency of the CV pipeline.
public struct GrayImage {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init?(width: Int, height: Int, pixels: [UInt8]) {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Rasterize a CGImage (assumed already orientation-normalized) to luma.
    public init?(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data else { return nil }
        let buf = base.assumingMemoryBound(to: UInt8.self)
        var gray = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Double(buf[i * 4]), g = Double(buf[i * 4 + 1]), b = Double(buf[i * 4 + 2])
            // Rec. 601 luma — fine for a threshold pipeline.
            gray[i] = UInt8(min(255, (299 * r + 587 * g + 114 * b + 500) / 1000))
        }
        self.init(width: w, height: h, pixels: gray)
    }

    @inline(__always)
    public func pixel(_ x: Int, _ y: Int) -> UInt8 {
        pixels[y * width + x]
    }

    public func toCGImage() -> CGImage? {
        var mutable = pixels
        guard let ctx = CGContext(
            data: &mutable, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        return ctx.makeImage()
    }

    /// Downscale by integer-free area sampling — used before expensive per-pixel steps.
    public func downscaled(factor: Double) -> GrayImage? {
        guard factor > 0, factor < 1 else { return self }
        let w = max(1, Int(Double(width) * factor))
        let h = max(1, Int(Double(height) * factor))
        var out = [UInt8](repeating: 0, count: w * h)
        for oy in 0..<h {
            let y0 = min(height - 1, Int((Double(oy) / Double(h) * Double(height)).rounded(.down)))
            let y1 = min(height - 1, max(y0, Int((Double(oy + 1) / Double(h) * Double(height)).rounded(.up)) - 1))
            for ox in 0..<w {
                let x0 = min(width - 1, Int((Double(ox) / Double(w) * Double(width)).rounded(.down)))
                let x1 = min(width - 1, max(x0, Int((Double(ox + 1) / Double(w) * Double(width)).rounded(.up)) - 1))
                var sum = 0, count = 0
                var y = y0
                while y <= y1 {
                    var x = x0
                    while x <= x1 {
                        sum += Int(pixels[y * width + x]); count += 1
                        x += 2
                    }
                    y += 2
                }
                out[oy * w + ox] = UInt8(count > 0 ? sum / count : 0)
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }
}

/// RGBA8 raster used for color warping (UI-facing corrected images).
public struct RGBAImage {
    public let width: Int
    public let height: Int
    public var bytes: [UInt8]

    public init?(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0, let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data else { return nil }
        let buf = base.assumingMemoryBound(to: UInt8.self)
        self.init(width: w, height: h, bytes: Array(UnsafeBufferPointer(start: buf, count: w * h * 4)))
    }

    public init?(width: Int, height: Int, bytes: [UInt8]) {
        guard width > 0, height > 0, bytes.count == width * height * 4 else { return nil }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    public func toCGImage() -> CGImage? {
        var mutable = bytes
        guard let ctx = CGContext(
            data: &mutable, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return ctx.makeImage()
    }
}
