import CoreGraphics
import Foundation
import QX20Core

// qx20tool: exercise QX20Core without the UI.
//   qx20tool render <image> <out.jpg> [--png out.png] [--paper card|square] [--mode fit|fill] [--border mm]
//   qx20tool status [--ip IP] [--port P] [--local-port P]
//   qx20tool print <image>... [--paper ..] [--mode ..] [--border ..] [--size-code N] [--ip IP] [--port P] [--local-port P]
//   qx20tool compose <out.png> <image>... [--grid N] [--gap mm] [--guides] [--copies N] [--no-rotate] [--paper ..] [--mode ..] [--border ..]
//   qx20tool packets
// status/print use the current network (no Wi-Fi switching).

var args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func hexString(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

guard let command = args.first else {
    fail("uso: qx20tool render|status|print|packets ...")
}
args.removeFirst()

let paper = Paper(rawValue: option("--paper") ?? "card") ?? .card
let mode = FitMode(rawValue: option("--mode") ?? "fit") ?? .fit
let border = Double(option("--border") ?? "0") ?? 0
let settings = PrintSettings(paper: paper, mode: mode, borderMM: border)
let ip = option("--ip") ?? "192.168.0.1"
let port = UInt16(option("--port") ?? "8609") ?? 8609
let localPort = UInt16(option("--local-port") ?? "8609") ?? 8609

do {
    switch command {
    case "render":
        let png = option("--png")
        guard args.count == 2 else { fail("uso: qx20tool render <imagen> <salida.jpg>") }
        let img = try ImagePrep.load(URL(fileURLWithPath: args[0]))
        let page = try ImagePrep.render(img, settings: settings)
        let jpeg = ImagePrep.printJPEG(page)
        try Data(jpeg).write(to: URL(fileURLWithPath: args[1]))
        if let png { try ImagePrep.writePNG(page.image, to: URL(fileURLWithPath: png)) }
        print("\(page.width)x\(page.height) jpeg=\(jpeg.count) bytes")

    case "status":
        let printer = QX20Printer(ip: ip, port: port, localPort: localPort)
        print("Device: \(try printer.discover())")
        let st = try printer.status()
        print(st.summary)
        print("Image range: \(st.minSize.0)x\(st.minSize.1) ~ \(st.maxSize.0)x\(st.maxSize.1)")

    case "print":
        let sizeCode = option("--size-code").flatMap(Int.init) ?? paper.defaultSizeCode
        guard let sizeCode else { fail("El código de tamaño para \(paper.rawValue) es desconocido; usa --size-code") }
        guard !args.isEmpty else { fail("uso: qx20tool print <imagen>...") }
        for path in args {
            let img = try ImagePrep.load(URL(fileURLWithPath: path))
            let page = try ImagePrep.render(img, settings: settings)
            let jpeg = ImagePrep.printJPEG(page)
            print("Printing: \(path) (\(jpeg.count) bytes)")
            let printer = QX20Printer(ip: ip, port: port, localPort: localPort)
            try printer.printJPEG(jpeg, width: page.width, height: page.height, sizeCode: sizeCode) { ev in
                switch ev {
                case .stage(let s): print("  [stage] \(s)")
                case .state(let s): print("  [state] \(s.qx20StateDescription)")
                case .debug(let d): print("  [debug] \(d)")
                }
            }
            print("Success!")
        }

    case "compose":
        let grid = option("--grid").flatMap(Int.init).map { GridPreset.count($0) } ?? .auto
        let gap = Double(option("--gap") ?? "1.5") ?? 1.5
        let copies = option("--copies").flatMap(Int.init) ?? 1
        let guides = args.contains("--guides"); args.removeAll { $0 == "--guides" }
        let noRotate = args.contains("--no-rotate"); args.removeAll { $0 == "--no-rotate" }
        guard args.count >= 2 else { fail("uso: qx20tool compose <salida.png> <imagen>...") }
        let cropRect = option("--crop").map { str -> CGRect in
            let v = str.split(separator: ",").compactMap { Double($0) }
            return v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : LayerPlacement.fullCrop
        } ?? LayerPlacement.fullCrop
        let base = try args.dropFirst().map { try LayerSource.load(URL(fileURLWithPath: $0)) }
        let sources = (0..<copies).flatMap { _ in base }
        let area = Layout.area(paper: paper, mode: mode, borderMM: border, singleImage: sources.count == 1)
        let cropped = LayerPlacement(center: .zero, size: .zero, crop: cropRect)
        let placements = Layout.arrange(aspects: sources.map { cropped.croppedAspect($0.aspect) }, in: area,
                                        gap: Double(mmToPx(gap)), mode: mode, grid: grid, allowRotation: !noRotate)
            .map { p -> LayerPlacement in var p = p; p.crop = cropRect; return p }
        let layers = zip(sources, placements).map { CompositionLayer(source: $0, placement: $1) }
        let page = try ImagePrep.renderComposition(layers, paper: paper, cutGuides: guides)
        try ImagePrep.writePNG(page.image, to: URL(fileURLWithPath: args[0]))
        for (s, p) in zip(sources, placements) {
            print("\(s.name): center=(\(Int(p.center.x)),\(Int(p.center.y))) size=\(Int(p.size.width))x\(Int(p.size.height)) rot=\(Int(p.rotation)) fill=\(p.fillsFrame)")
        }

    case "packets":
        print("sessionEnd   \(hexString(CPNPPacket.sessionEnd(pid: 1)))")
        print("sessionStart \(hexString(CPNPPacket.sessionStart(pid: 2)))")
        print("setMax       \(hexString(CPNPPacket.setMaxWriteSize(pid: 3, session: 0x42)))")
        print("getMax       \(hexString(CPNPPacket.getMaxWriteSize(pid: 4, session: 0x42)))")
        print("startPrint   \(hexString(CPNPPacket.startPrint(sizeCode: 18)))")
        print("probe        \(hexString(CPNPPacket.probe(jpegSize: 1234, width: 644, height: 826)))")
        print("dataHeader   \(hexString(CPNPPacket.printHeader(jpegSize: 1234, width: 644, height: 826, offset: 0, chunk: 1234)))")
        print("endPrint     \(hexString(CPNPPacket.endPrint()))")

    default:
        fail("comando desconocido: \(command)")
    }
} catch {
    fail("Error: \(error.localizedDescription)")
}
