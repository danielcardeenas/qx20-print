import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

// MARK: - Layer sources

/// An image that can be placed on a page: a raster photo/PNG or a vector SVG.
/// Vectors are re-rasterized at the exact size they are printed.
public final class LayerSource: @unchecked Sendable {
    public let url: URL
    /// Small image for the UI (≤ 1600 px).
    public let preview: CGImage
    /// Natural size, used for the aspect ratio.
    public let pixelSize: CGSize
    private let raster: CGImage?
    private let vector: NSImage?

    /// Name shown to the user (the original file name).
    public let name: String
    public var isVector: Bool { vector != nil }
    public var aspect: Double { Double(pixelSize.width / max(pixelSize.height, 1)) }

    private init(url: URL, name: String, preview: CGImage, pixelSize: CGSize, raster: CGImage?, vector: NSImage?) {
        self.url = url
        self.name = name
        self.preview = preview
        self.pixelSize = pixelSize
        self.raster = raster
        self.vector = vector
    }

    public static func load(_ url: URL, name: String? = nil) throws -> LayerSource {
        let name = name ?? url.lastPathComponent
        let isSVG = url.pathExtension.lowercased() == "svg"
            || (UTType(filenameExtension: url.pathExtension)?.conforms(to: .svg) ?? false)
        if isSVG {
            guard let img = NSImage(contentsOf: url), img.size.width > 0, img.size.height > 0 else {
                throw ImagePrepError.cannotRead(url.lastPathComponent)
            }
            let longSide = 1600.0
            let s = longSide / max(img.size.width, img.size.height)
            guard let preview = rasterize(img, size: CGSize(width: img.size.width * s, height: img.size.height * s)) else {
                throw ImagePrepError.cannotRead(url.lastPathComponent)
            }
            return LayerSource(url: url, name: name, preview: preview, pixelSize: img.size, raster: nil, vector: img)
        }
        let raster = try ImagePrep.load(url)
        let preview = (try? ImagePrep.load(url, maxPixel: 1600)) ?? raster
        return LayerSource(url: url, name: name, preview: preview,
                           pixelSize: CGSize(width: raster.width, height: raster.height),
                           raster: raster, vector: nil)
    }

    /// Image to draw at `size` canvas pixels.
    public func image(forPixelSize size: CGSize) -> CGImage? {
        if let vector { return Self.rasterize(vector, size: size) }
        return raster
    }

    static func rasterize(_ image: NSImage, size: CGSize) -> CGImage? {
        let w = max(1, Int(size.width.rounded(.up))), h = max(1, Int(size.height.rounded(.up)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        image.draw(in: CGRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

// MARK: - Placement & layout

/// Where a layer goes on the canvas (top-left pixel coordinates).
/// `size` is the unrotated frame; `rotation` is in degrees, clockwise.
public struct LayerPlacement: Equatable, Sendable {
    public var center: CGPoint
    public var size: CGSize
    public var rotation: Double
    /// Cover the frame cropping the excess (otherwise fit inside it).
    public var fillsFrame: Bool
    /// Part of the source image used, normalized (0...1, top-left origin).
    public var crop: CGRect

    public static let fullCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    public init(center: CGPoint, size: CGSize, rotation: Double = 0, fillsFrame: Bool = false,
                crop: CGRect = LayerPlacement.fullCrop) {
        self.center = center; self.size = size; self.rotation = rotation; self.fillsFrame = fillsFrame
        self.crop = crop
    }

    public var isCropped: Bool { crop != Self.fullCrop }

    /// Aspect ratio of the cropped part of an image with `sourceAspect`.
    public func croppedAspect(_ sourceAspect: Double) -> Double {
        sourceAspect * Double(crop.width / max(crop.height, 0.0001))
    }

    /// Axis-aligned size of the rotated frame.
    public var boundingSize: CGSize {
        let r = rotation * .pi / 180
        let c = abs(cos(r)), s = abs(sin(r))
        return CGSize(width: size.width * c + size.height * s, height: size.width * s + size.height * c)
    }
}

public enum GridPreset: Hashable, Identifiable, Sendable {
    /// Choose the arrangement that makes the images largest.
    case auto
    /// Exactly `n` cells per sheet.
    case count(Int)

    public static let all: [GridPreset] = [.auto] + [2, 4, 6, 8, 9, 12, 16, 20].map { .count($0) }
    public var id: String { title }
    public var cellCount: Int? { if case .count(let n) = self { return n } else { return nil } }
    public var title: String {
        switch self {
        case .auto: return String(localized: "Automatic")
        case .count(let n): return String(localized: "\(n) per sheet")
        }
    }
}

public enum Layout {
    /// Size of an image with `aspect` fitted inside `box`.
    static func contain(aspect: Double, in box: CGSize) -> CGSize {
        if box.width / box.height > aspect {
            return CGSize(width: box.height * aspect, height: box.height)
        }
        return CGSize(width: box.width, height: box.width / aspect)
    }

    /// Rotate (CCW, like the Python driver) only when it makes the image clearly bigger.
    static func shouldRotate(aspect: Double, cell: CGSize, allow: Bool) -> Bool {
        guard allow else { return false }
        let a = contain(aspect: aspect, in: cell), b = contain(aspect: 1 / aspect, in: cell)
        return b.width * b.height > a.width * a.height * 1.1
    }

    static func place(aspect: Double, in cell: CGRect, mode: FitMode, allowRotation: Bool) -> LayerPlacement {
        let rotate = shouldRotate(aspect: aspect, cell: cell.size, allow: allowRotation)
        let center = CGPoint(x: cell.midX, y: cell.midY)
        switch mode {
        case .fill:
            let size = rotate ? CGSize(width: cell.height, height: cell.width) : cell.size
            return LayerPlacement(center: center, size: size, rotation: rotate ? -90 : 0, fillsFrame: true)
        case .fit:
            let box = contain(aspect: rotate ? 1 / aspect : aspect, in: cell.size)
            // Integer pixels, same rounding as the single-image renderer
            let w = box.width.rounded(), h = box.height.rounded()
            let x = cell.minX + ((cell.width - w) / 2).rounded(.down)
            let y = cell.minY + ((cell.height - h) / 2).rounded(.down)
            let size = rotate ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
            return LayerPlacement(center: CGPoint(x: x + w / 2, y: y + h / 2), size: size,
                                  rotation: rotate ? -90 : 0, fillsFrame: false)
        }
    }

    /// Lay out images (given by aspect ratio) in `area`.
    /// One image with `.auto` fills the area; otherwise a grid is chosen that
    /// maximises the printed image area (or exactly `grid.cellCount` cells).
    public static func arrange(aspects: [Double], in area: CGRect, gap: Double, mode: FitMode,
                               grid: GridPreset, allowRotation: Bool) -> [LayerPlacement] {
        let n = aspects.count
        guard n > 0, area.width > 0, area.height > 0 else { return [] }
        if n == 1, grid == .auto {
            return [place(aspect: aspects[0], in: area, mode: mode, allowRotation: allowRotation)]
        }

        var candidates: [(rows: Int, cols: Int)] = []
        if let cells = grid.cellCount {
            for r in 1...cells where cells % r == 0 { candidates.append((r, cells / r)) }
        } else {
            for r in 1...n { candidates.append((r, Int((Double(n) / Double(r)).rounded(.up)))) }
        }

        func cellSize(_ rows: Int, _ cols: Int) -> CGSize {
            CGSize(width: (area.width - Double(cols - 1) * gap) / Double(cols),
                   height: (area.height - Double(rows - 1) * gap) / Double(rows))
        }

        var best: (rows: Int, cols: Int, score: Double)?
        for (rows, cols) in candidates {
            let cell = cellSize(rows, cols)
            guard cell.width > 4, cell.height > 4 else { continue }
            var score = 0.0
            for (i, a) in aspects.enumerated() where i < rows * cols {
                let rot = shouldRotate(aspect: a, cell: cell, allow: allowRotation)
                let s = contain(aspect: rot ? 1 / a : a, in: cell)
                score += s.width * s.height
            }
            if best == nil || score > best!.score * 1.0001 { best = (rows, cols, score) }
        }
        guard let best else { return [] }

        let cell = cellSize(best.rows, best.cols)
        var placements: [LayerPlacement] = []
        for i in 0..<n {
            let row = i / best.cols, col = i % best.cols
            if row >= best.rows {
                // More images than cells: stack the extras in the centre (user can move them)
                placements.append(place(aspect: aspects[i], in: CGRect(origin: CGPoint(x: area.midX - cell.width / 2, y: area.midY - cell.height / 2), size: cell),
                                        mode: mode, allowRotation: allowRotation))
                continue
            }
            // Centre an incomplete last row
            let inRow = row == best.rows - 1 ? min(best.cols, n - row * best.cols) : best.cols
            let rowOffset = grid == .auto ? Double(best.cols - inRow) * (cell.width + gap) / 2 : 0
            let rect = CGRect(x: area.minX + rowOffset + Double(col) * (cell.width + gap),
                              y: area.minY + Double(row) * (cell.height + gap),
                              width: cell.width, height: cell.height)
            placements.append(place(aspect: aspects[i], in: rect, mode: mode, allowRotation: allowRotation))
        }
        return placements
    }

    /// The area auto-layout uses: printable (non-bleed) area minus the extra
    /// margin; a single filled image covers the whole canvas instead.
    public static func area(paper: Paper, mode: FitMode, borderMM: Double, singleImage: Bool) -> CGRect {
        let border = CGFloat(mmToPx(borderMM))
        let base = (mode == .fill && singleImage)
            ? CGRect(x: 0, y: 0, width: paper.width, height: paper.height)
            : paper.visibleRect
        return base.insetBy(dx: border, dy: border)
    }
}

// MARK: - Rendering

public struct CompositionLayer: Sendable {
    public var source: LayerSource
    public var placement: LayerPlacement
    public init(source: LayerSource, placement: LayerPlacement) {
        self.source = source; self.placement = placement
    }
}

public extension ImagePrep {
    /// Crop an image to a normalized rect (top-left origin).
    static func crop(_ image: CGImage, to crop: CGRect) -> CGImage? {
        if crop == LayerPlacement.fullCrop { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let r = CGRect(x: crop.minX * w, y: crop.minY * h, width: crop.width * w, height: crop.height * h)
            .integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        return r.isEmpty ? nil : image.cropping(to: r)
    }

    /// Draw layers (bottom to top) onto a white page. Optionally adds thin
    /// grey cut guides around each layer.
    static func renderComposition(_ layers: [CompositionLayer], paper: Paper,
                                  cutGuides: Bool = false) throws -> RenderedPage {
        let cw = paper.width, ch = paper.height
        guard let ctx = makeContext(width: cw, height: ch) else { throw ImagePrepError.contextFailed }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))

        func withLayerTransform(_ p: LayerPlacement, _ body: (CGRect) -> Void) {
            ctx.saveGState()
            // CoreGraphics is bottom-left/y-up: flip the centre, and a clockwise
            // rotation on screen is a negative angle here.
            ctx.translateBy(x: p.center.x, y: CGFloat(ch) - p.center.y)
            ctx.rotate(by: -p.rotation * .pi / 180)
            body(CGRect(x: -p.size.width / 2, y: -p.size.height / 2, width: p.size.width, height: p.size.height))
            ctx.restoreGState()
        }

        for layer in layers {
            let p = layer.placement
            guard p.size.width >= 1, p.size.height >= 1 else { continue }
            let crop = p.crop.intersection(LayerPlacement.fullCrop)
            guard crop.width > 0.001, crop.height > 0.001 else { continue }
            let aspect = p.croppedAspect(layer.source.aspect)
            let frameAspect = Double(p.size.width / p.size.height)
            // Rect the image is drawn in (cover or contain within the frame)
            let drawSize: CGSize
            if p.fillsFrame == (aspect > frameAspect) {
                drawSize = CGSize(width: p.size.height * aspect, height: p.size.height)
            } else {
                drawSize = CGSize(width: p.size.width, height: p.size.width / aspect)
            }
            // Full image at the scale it is drawn, then the cropped part of it
            let fullSize = CGSize(width: drawSize.width / crop.width, height: drawSize.height / crop.height)
            guard let full = layer.source.image(forPixelSize: fullSize),
                  let img = Self.crop(full, to: crop) else { continue }
            withLayerTransform(p) { frame in
                if p.fillsFrame { ctx.clip(to: frame) }
                ctx.draw(img, in: CGRect(x: -drawSize.width / 2, y: -drawSize.height / 2,
                                         width: drawSize.width, height: drawSize.height))
            }
        }

        if cutGuides {
            ctx.setStrokeColor(CGColor(gray: 0.62, alpha: 1))
            ctx.setLineWidth(1)
            for layer in layers {
                withLayerTransform(layer.placement) { frame in
                    ctx.stroke(frame.insetBy(dx: -0.5, dy: -0.5))
                }
            }
        }

        guard let out = ctx.makeImage(), let data = ctx.data else { throw ImagePrepError.contextFailed }
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                              count: ctx.bytesPerRow * ch))
        return RenderedPage(image: out, rgbx: bytes, width: cw, height: ch, paper: paper)
    }
}
