import Foundation

/// Minimal baseline JPEG encoder producing the same format the Python driver
/// (Pillow/libjpeg) sends to the QX20: YCbCr 4:4:4 (no chroma subsampling),
/// standard IJG quantization and Huffman tables, JFIF header and an optional
/// restart interval. ImageIO cannot be told to use 4:4:4 or restart markers.
public enum JPEGEncoder {

    // MARK: Tables

    /// zigzag index -> natural (row-major) index
    static let zigzag: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]

    static let stdLuminanceQ: [Int] = [
        16, 11, 10, 16, 24, 40, 51, 61,
        12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56,
        14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77,
        24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101,
        72, 92, 95, 98, 112, 100, 103, 99,
    ]

    static let stdChrominanceQ: [Int] = [
        17, 18, 24, 47, 99, 99, 99, 99,
        18, 21, 26, 66, 99, 99, 99, 99,
        24, 26, 56, 99, 99, 99, 99, 99,
        47, 66, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
    ]

    static let dcLuminanceBits: [UInt8] = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0]
    static let dcLuminanceVals: [UInt8] = Array(0...11)
    static let dcChrominanceBits: [UInt8] = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0]
    static let dcChrominanceVals: [UInt8] = Array(0...11)

    static let acLuminanceBits: [UInt8] = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D]
    static let acLuminanceVals: [UInt8] = [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
        0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
        0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
        0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
        0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
        0xF9, 0xFA,
    ]

    static let acChrominanceBits: [UInt8] = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77]
    static let acChrominanceVals: [UInt8] = [
        0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
        0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0,
        0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34, 0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26,
        0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
        0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
        0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5,
        0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3,
        0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA,
        0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
        0xF9, 0xFA,
    ]

    struct HuffmanTable {
        var code = [UInt16](repeating: 0, count: 256)
        var length = [UInt8](repeating: 0, count: 256)

        init(bits: [UInt8], values: [UInt8]) {
            var code = 0, k = 0
            for len in 1...16 {
                for _ in 0..<Int(bits[len - 1]) {
                    let v = Int(values[k])
                    self.code[v] = UInt16(code)
                    self.length[v] = UInt8(len)
                    code += 1
                    k += 1
                }
                code <<= 1
            }
        }
    }

    /// cos((2x+1) u pi / 16), indexed [x * 8 + u]
    static let cosTable: [Double] = {
        var t = [Double](repeating: 0, count: 64)
        for x in 0..<8 {
            for u in 0..<8 {
                t[x * 8 + u] = cos(Double(2 * x + 1) * Double(u) * Double.pi / 16)
            }
        }
        return t
    }()

    // MARK: Bit writer

    struct BitWriter {
        var out: [UInt8] = []
        var acc: UInt32 = 0
        var count: Int = 0

        mutating func write(_ value: Int, _ bits: Int) {
            guard bits > 0 else { return }
            let mask = (UInt32(1) << UInt32(bits)) - 1
            acc = (acc << UInt32(bits)) | (UInt32(truncatingIfNeeded: value) & mask)
            count += bits
            while count >= 8 {
                let byte = UInt8((acc >> UInt32(count - 8)) & 0xFF)
                out.append(byte)
                if byte == 0xFF { out.append(0x00) }  // byte stuffing
                count -= 8
            }
            acc &= (UInt32(1) << UInt32(count)) - 1
        }

        /// Pad the last byte with 1-bits.
        mutating func flush() {
            if count > 0 { write((1 << (8 - count)) - 1, 8 - count) }
        }
    }

    // MARK: Encoding

    static func bitLength(_ v: Int) -> Int {
        var n = abs(v), s = 0
        while n > 0 { s += 1; n >>= 1 }
        return s
    }

    static func scaledTable(_ base: [Int], quality: Int) -> [Int] {
        let q = min(100, max(1, quality))
        let scale = q < 50 ? 5000 / q : 200 - q * 2
        return base.map { min(255, max(1, ($0 * scale + 50) / 100)) }
    }

    /// Forward DCT, quantize and entropy-code one 8x8 block (level-shifted samples).
    static func encodeBlock(_ block: inout [Double], quant: [Int], dc: HuffmanTable, ac: HuffmanTable,
                            prevDC: Int, writer: inout BitWriter, tmp: inout [Double]) -> Int {
        let c = cosTable
        // Rows
        for y in 0..<8 {
            for u in 0..<8 {
                var s = 0.0
                for x in 0..<8 { s += block[y * 8 + x] * c[x * 8 + u] }
                tmp[y * 8 + u] = s
            }
        }
        // Columns + scaling + quantization (stored in zigzag order)
        var coef = [Int](repeating: 0, count: 64)
        let invSqrt2 = 1 / 2.0.squareRoot()
        for v in 0..<8 {
            let cv = v == 0 ? invSqrt2 : 1
            for u in 0..<8 {
                var s = 0.0
                for y in 0..<8 { s += tmp[y * 8 + u] * c[y * 8 + v] }
                let cu = u == 0 ? invSqrt2 : 1
                block[v * 8 + u] = 0.25 * cu * cv * s
            }
        }
        for k in 0..<64 {
            let n = zigzag[k]
            coef[k] = Int((block[n] / Double(quant[n])).rounded())
        }

        // DC
        let diff = coef[0] - prevDC
        let dcSize = bitLength(diff)
        writer.write(Int(dc.code[dcSize]), Int(dc.length[dcSize]))
        if dcSize > 0 { writer.write(diff < 0 ? diff + (1 << dcSize) - 1 : diff, dcSize) }

        // AC
        var run = 0
        for k in 1..<64 {
            let v = coef[k]
            if v == 0 { run += 1; continue }
            while run > 15 {
                writer.write(Int(ac.code[0xF0]), Int(ac.length[0xF0]))  // ZRL
                run -= 16
            }
            let size = bitLength(v)
            let sym = (run << 4) | size
            writer.write(Int(ac.code[sym]), Int(ac.length[sym]))
            writer.write(v < 0 ? v + (1 << size) - 1 : v, size)
            run = 0
        }
        if run > 0 { writer.write(Int(ac.code[0x00]), Int(ac.length[0x00])) }  // EOB
        return coef[0]
    }

    /// Encode RGBX pixels (4 bytes per pixel, no row padding).
    public static func encode(rgbx: [UInt8], width: Int, height: Int,
                              quality: Int = 95, restartInterval: Int? = nil) -> [UInt8] {
        precondition(rgbx.count >= width * height * 4)
        let qY = scaledTable(stdLuminanceQ, quality: quality)
        let qC = scaledTable(stdChrominanceQ, quality: quality)
        let dcY = HuffmanTable(bits: dcLuminanceBits, values: dcLuminanceVals)
        let acY = HuffmanTable(bits: acLuminanceBits, values: acLuminanceVals)
        let dcC = HuffmanTable(bits: dcChrominanceBits, values: dcChrominanceVals)
        let acC = HuffmanTable(bits: acChrominanceBits, values: acChrominanceVals)

        var out: [UInt8] = []
        func u16(_ v: Int) { out.append(UInt8((v >> 8) & 0xFF)); out.append(UInt8(v & 0xFF)) }

        // SOI + JFIF APP0
        out += [0xFF, 0xD8]
        out += [0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00,
                0x00, 0x01, 0x00, 0x01, 0x00, 0x00]
        // DQT (two tables, zigzag order)
        out += [0xFF, 0xDB]; u16(2 + 2 * 65)
        out.append(0x00); for k in 0..<64 { out.append(UInt8(qY[zigzag[k]])) }
        out.append(0x01); for k in 0..<64 { out.append(UInt8(qC[zigzag[k]])) }
        // SOF0: 8-bit, 3 components, all 1x1 sampling (4:4:4)
        out += [0xFF, 0xC0]; u16(17); out.append(8); u16(height); u16(width); out.append(3)
        out += [1, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1]
        // DHT
        let tables: [(UInt8, [UInt8], [UInt8])] = [
            (0x00, dcLuminanceBits, dcLuminanceVals), (0x10, acLuminanceBits, acLuminanceVals),
            (0x01, dcChrominanceBits, dcChrominanceVals), (0x11, acChrominanceBits, acChrominanceVals),
        ]
        out += [0xFF, 0xC4]; u16(2 + tables.reduce(0) { $0 + 17 + $1.2.count })
        for (id, bits, vals) in tables { out.append(id); out += bits; out += vals }
        // DRI
        if let ri = restartInterval, ri > 0 { out += [0xFF, 0xDD]; u16(4); u16(ri) }
        // SOS
        out += [0xFF, 0xDA]; u16(12); out.append(3)
        out += [1, 0x00, 2, 0x11, 3, 0x11, 0x00, 0x3F, 0x00]

        var writer = BitWriter()
        writer.out.reserveCapacity(width * height)
        var yBlk = [Double](repeating: 0, count: 64)
        var cbBlk = [Double](repeating: 0, count: 64)
        var crBlk = [Double](repeating: 0, count: 64)
        var tmp = [Double](repeating: 0, count: 64)
        var predY = 0, predCb = 0, predCr = 0
        var mcuIndex = 0, rst = 0
        let mcusX = (width + 7) / 8, mcusY = (height + 7) / 8

        rgbx.withUnsafeBufferPointer { px in
            for by in 0..<mcusY {
                for bx in 0..<mcusX {
                    if let ri = restartInterval, ri > 0, mcuIndex > 0, mcuIndex % ri == 0 {
                        writer.flush()
                        writer.out += [0xFF, UInt8(0xD0 + rst)]
                        rst = (rst + 1) & 7
                        predY = 0; predCb = 0; predCr = 0
                    }
                    for y in 0..<8 {
                        let py = min(by * 8 + y, height - 1)
                        for x in 0..<8 {
                            let pxX = min(bx * 8 + x, width - 1)
                            let i = (py * width + pxX) * 4
                            let r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2])
                            let n = y * 8 + x
                            yBlk[n] = 0.299 * r + 0.587 * g + 0.114 * b - 128
                            cbBlk[n] = -0.168736 * r - 0.331264 * g + 0.5 * b
                            crBlk[n] = 0.5 * r - 0.418688 * g - 0.081312 * b
                        }
                    }
                    predY = encodeBlock(&yBlk, quant: qY, dc: dcY, ac: acY, prevDC: predY, writer: &writer, tmp: &tmp)
                    predCb = encodeBlock(&cbBlk, quant: qC, dc: dcC, ac: acC, prevDC: predCb, writer: &writer, tmp: &tmp)
                    predCr = encodeBlock(&crBlk, quant: qC, dc: dcC, ac: acC, prevDC: predCr, writer: &writer, tmp: &tmp)
                    mcuIndex += 1
                }
            }
        }
        writer.flush()
        out += writer.out
        out += [0xFF, 0xD9]
        return out
    }
}
