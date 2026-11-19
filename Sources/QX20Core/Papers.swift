import Foundation
import CoreGraphics

/// The QX20 prints at 287 dpi (Canon spec, confirmed with calibrate.py).
public let qx20DPI: Double = 287

public func mmToPx(_ mm: Double) -> Int {
    max(0, Int((mm / 25.4 * qx20DPI).rounded()))
}

public func pxToMM(_ px: Int) -> Double {
    Double(px) / qx20DPI * 25.4
}

public struct EdgeInsetsPx: Equatable, Sendable {
    public var left, top, right, bottom: Int
    public init(left: Int, top: Int, right: Int, bottom: Int) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
    public static let zero = EdgeInsetsPx(left: 0, top: 0, right: 0, bottom: 0)
}

public enum Paper: String, CaseIterable, Identifiable, Codable, Sendable {
    case card, square

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .card: return String(localized: "Card · XC-20L")
        case .square: return String(localized: "Square · XS-20L")
        }
    }

    public var sheetSize: String {
        switch self {
        case .card: return "54 × 85 mm"
        case .square: return "72 × 85 mm"
        }
    }

    /// Canvas size in pixels (what the official Canon app sends).
    public var width: Int { self == .card ? 644 : 848 }
    public var height: Int { 826 }

    /// StartPrint media code (both verified on hardware).
    public var defaultSizeCode: Int? { self == .card ? 18 : 17 }

    /// Before 0.3.1 the square code was unknown and people typed guesses into
    /// Settings › Advanced (e.g. 16, which makes the printer blink red). Those
    /// saved guesses would override the verified default, so drop them once.
    public static func clearSquareCodeGuess(in defaults: UserDefaults) {
        let flag = "squareSizeCodeMigrated"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.removeObject(forKey: "squareSizeCode")
        defaults.set(true, forKey: flag)
    }

    /// Millimetres lost on each side with borderless printing.
    /// Card measured with calibrate.py; square assumed equal (same overhang).
    public var bleedMM: (left: Double, top: Double, right: Double, bottom: Double) {
        (2, 1, 2, 1)
    }

    public var bleedPx: EdgeInsetsPx {
        let b = bleedMM
        return EdgeInsetsPx(left: mmToPx(b.left), top: mmToPx(b.top),
                            right: mmToPx(b.right), bottom: mmToPx(b.bottom))
    }

    /// Area of the canvas that survives on the paper, in top-left pixel coordinates.
    public var visibleRect: CGRect {
        let b = bleedPx
        return CGRect(x: b.left, y: b.top,
                      width: width - b.left - b.right, height: height - b.top - b.bottom)
    }
}

public enum FitMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Whole image visible, white bars where the aspect ratio differs.
    case fit
    /// Cover the whole sheet, cropping the excess.
    case fill

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fit: return String(localized: "Whole image")
        case .fill: return String(localized: "Fill sheet")
        }
    }
}

public struct PrintSettings: Equatable, Sendable {
    public var paper: Paper
    public var mode: FitMode
    public var borderMM: Double

    public init(paper: Paper = .card, mode: FitMode = .fit, borderMM: Double = 0) {
        self.paper = paper; self.mode = mode; self.borderMM = borderMM
    }
}
