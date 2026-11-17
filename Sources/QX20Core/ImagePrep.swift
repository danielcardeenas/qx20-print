import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImagePrepError: LocalizedError {
    case cannotRead(String)
    case borderTooLarge
    case contextFailed

    public var errorDescription: String? {
        switch self {
        case .cannotRead(let name): return String(localized: "Couldn’t open the image \(name)")
        case .borderTooLarge: return String(localized: "The margin is too large")
        case .contextFailed: return String(localized: "Couldn’t create the canvas")
        }
    }
}

/// A canvas ready to print: the exact pixels sent to the printer.
public struct RenderedPage {
    public let image: CGImage
    /// Raw pixels, 4 bytes per pixel (R, G, B, unused), row-major, no padding.
    public let rgbx: [UInt8]
    public let width: Int
    public let height: Int
    public let paper: Paper
    /// Part of the canvas that survives borderless printing (top-left coordinates).
    public var visibleRect: CGRect { paper.visibleRect }
}

public enum ImagePrep {
    /// Load an image applying its EXIF orientation. Large photos are
    /// downscaled to `maxPixel` on the long side (the canvas is < 900 px).
    public static func load(_ url: URL, maxPixel: Int = 3000) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImagePrepError.cannotRead(url.lastPathComponent)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ImagePrepError.cannotRead(url.lastPathComponent)
        }
        return img
    }

    static func makeContext(width: Int, height: Int) -> CGContext? {
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        ctx?.interpolationQuality = .high
        return ctx
    }

    /// Rotate 90° counter-clockwise (same as PIL's rotate(90)).
    static func rotatedCCW(_ img: CGImage) -> CGImage? {
        let w = img.width, h = img.height
        guard let ctx = makeContext(width: h, height: w) else { return nil }
        ctx.translateBy(x: CGFloat(h), y: 0)
        ctx.rotate(by: .pi / 2)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Place an image on the paper canvas without distortion.
    /// - fit: whole image inside the printable (non-bleed) area plus `borderMM`.
    /// - fill: cover the canvas (minus `borderMM`), cropping the excess.
    public static func render(_ source: CGImage, settings: PrintSettings) throws -> RenderedPage {
        let paper = settings.paper
        let cw = paper.width, ch = paper.height

        var img = source
        // Turn landscape photos for the tall card format (square: leave as is)
        if (img.width > img.height) != (cw > ch), abs(cw - ch) > 50,
           let rotated = rotatedCCW(img) {
            img = rotated
        }

        let bleed = settings.mode == .fit ? paper.bleedPx : .zero
        let border = mmToPx(settings.borderMM)
        let left = bleed.left + border, top = bleed.top + border
        let innerW = cw - left - bleed.right - border
        let innerH = ch - top - bleed.bottom - border
        guard innerW > 0, innerH > 0 else { throw ImagePrepError.borderTooLarge }

        let iw = Double(img.width), ih = Double(img.height)
        let sx = Double(innerW) / iw, sy = Double(innerH) / ih
        let scale = settings.mode == .fit ? min(sx, sy) : max(sx, sy)
        let dw = (iw * scale).rounded(), dh = (ih * scale).rounded()
        let dx = Double(left) + ((Double(innerW) - dw) / 2).rounded(.down)
        let dy = Double(top) + ((Double(innerH) - dh) / 2).rounded(.down)

        guard let ctx = makeContext(width: cw, height: ch) else { throw ImagePrepError.contextFailed }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        ctx.saveGState()
        // CoreGraphics has its origin at the bottom-left
        ctx.clip(to: CGRect(x: left, y: ch - top - innerH, width: innerW, height: innerH))
        ctx.draw(img, in: CGRect(x: dx, y: Double(ch) - dy - dh, width: dw, height: dh))
        ctx.restoreGState()

        guard let out = ctx.makeImage(), let data = ctx.data else { throw ImagePrepError.contextFailed }
        let count = ctx.bytesPerRow * ch
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: count))
        return RenderedPage(image: out, rgbx: bytes, width: cw, height: ch, paper: paper)
    }

    /// Encode a page as the JPEG the QX20 expects (baseline, 4:4:4, restart
    /// marker every MCU row). Lowers the quality if it would exceed 1 MB,
    /// because the printer requests bigger images in fragments.
    public static func printJPEG(_ page: RenderedPage) -> [UInt8] {
        var quality = 95
        while true {
            let jpeg = JPEGEncoder.encode(rgbx: page.rgbx, width: page.width, height: page.height,
                                          quality: quality, restartInterval: (page.width + 7) / 8)
            if jpeg.count <= 1_000_000 || quality <= 50 { return jpeg }
            quality -= 10
        }
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ImagePrepError.contextFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ImagePrepError.contextFailed }
    }
}
