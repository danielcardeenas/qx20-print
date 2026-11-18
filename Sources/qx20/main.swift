import CoreGraphics
import CoreLocation
import Foundation
import QX20Core

// qx20 — print on a Canon SELPHY QX20 from the terminal (for people, scripts and AI agents).
// Shares its settings (printer key, network, paper) with the QX20 Print app.

let version = "0.2.0"
let appDomain = "io.github.danielcardeenas.qx20-print"

// MARK: - Exit codes (stable, documented in docs/CLI.md)

enum Exit: Int32 {
    case ok = 0
    case someFailed = 1
    case usage = 2
    case printerError = 3
    case unreachable = 4
    case notConfigured = 5
    case locationPermission = 6

    var code: String {
        switch self {
        case .ok: return "ok"
        case .someFailed: return "some_failed"
        case .usage: return "usage"
        case .printerError: return "printer_error"
        case .unreachable: return "unreachable"
        case .notConfigured: return "not_configured"
        case .locationPermission: return "location_permission"
        }
    }
}

let usage = """
qx20 \(version) — print photos and stickers on a Canon SELPHY QX20

USAGE
  qx20 print <image>... [options]     Print (one sheet per image unless --together / --per-sheet)
  qx20 preview <image>... -o <path>   Render the sheets to PNG without printing
  qx20 status                         Printer model, paper/ink and error state
  qx20 setup                          First-time check: Location permission, key, nearby printers
  qx20 scan                           Nearby QX20 printers (does not change Wi-Fi)
  qx20 config [show]                  Show settings shared with the QX20 Print app
  qx20 config set <name> <value>      name: key | network | paper | return
  qx20 config unset <name>
  qx20 help | --version

SHEET OPTIONS (print, preview)
  --paper card|square   Paper (default: saved setting, else card)
  --fit                 Whole image, nothing cropped (default)
  --fill                Cover the sheet / cell, cropping the excess
  --margin MM           Extra white margin around the content
  --together            All images on one sheet, auto-arranged
  --per-sheet N         N images per sheet (grid), e.g. 2, 4, 6, 9
  --repeat              With --per-sheet: repeat images to fill every cell (sticker sheets)
  --gap MM              Space between images (default 1.5)
  --no-rotate           Don't rotate images 90° to use the space better
  --guides              Print thin grey cut guides around each image
  --copies N            Print each sheet N times

PRINTER OPTIONS (print, status)
  --no-switch           Don't change Wi-Fi: the Mac must already be on the printer's network
  --stay                Stay on the printer's Wi-Fi afterwards
  --network SSID        Printer network (default: saved, else the strongest QX20-…)
  --key KEY             Printer key (default: saved)
  --size-code N         StartPrint media code (square paper is not verified yet)

OUTPUT
  --json                One JSON object per line on stdout (events + final result)
  --quiet               Only errors

EXIT CODES
  0 ok · 1 some sheets failed · 2 usage · 3 printer error (e.g. no paper)
  4 printer unreachable · 5 printer key not configured · 6 no Location permission

EXAMPLES
  qx20 setup
  qx20 config set key ABCDEFGHI
  qx20 print photo.jpg
  qx20 print a.jpg b.jpg --together --guides
  qx20 print logo.svg --per-sheet 6 --repeat --guides
  qx20 preview *.jpg --per-sheet 4 -o sheets/
  qx20 status --json
"""

// MARK: - Arguments

struct Args {
    var command = ""
    var positional: [String] = []
    var values: [String: String] = [:]
    var flags = Set<String>()

    static let valueOptions: Set<String> = ["paper", "margin", "per-sheet", "gap", "copies", "network", "key",
                                            "size-code", "o", "output", "ip", "port", "local-port"]
    static let flagOptions: Set<String> = ["fit", "fill", "together", "repeat", "no-rotate", "guides", "no-switch",
                                           "stay", "json", "quiet", "help", "version"]

    init(_ argv: [String]) throws {
        var it = argv.makeIterator()
        while let a = it.next() {
            if a == "-o" || a.hasPrefix("--") {
                var name = a == "-o" ? "o" : String(a.dropFirst(2))
                var inline: String?
                if let eq = name.firstIndex(of: "=") {
                    inline = String(name[name.index(after: eq)...])
                    name = String(name[..<eq])
                }
                if Self.flagOptions.contains(name) {
                    flags.insert(name)
                } else if Self.valueOptions.contains(name) {
                    guard let v = inline ?? it.next() else { throw UsageError("--\(name) needs a value") }
                    values[name] = v
                } else {
                    throw UsageError("unknown option \(a)")
                }
            } else if command.isEmpty {
                command = a
            } else {
                positional.append(a)
            }
        }
    }

    func double(_ name: String) throws -> Double? {
        guard let v = values[name] else { return nil }
        guard let d = Double(v), d >= 0 else { throw UsageError("--\(name) must be a number ≥ 0") }
        return d
    }

    func int(_ name: String, min: Int = 1) throws -> Int? {
        guard let v = values[name] else { return nil }
        guard let i = Int(v), i >= min else { throw UsageError("--\(name) must be an integer ≥ \(min)") }
        return i
    }
}

struct UsageError: Error { let message: String; init(_ m: String) { message = m } }

// MARK: - Output

final class Output {
    let json: Bool
    let quiet: Bool
    private let lock = NSLock()

    init(json: Bool, quiet: Bool) { self.json = json; self.quiet = quiet }

    func emit(_ object: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
           let line = String(data: data, encoding: .utf8) {
            print(line)
            fflush(stdout)
        }
    }

    /// Progress (stderr for humans, a "log" event for JSON).
    func log(_ message: String) {
        if json { emit(["event": "log", "message": message]); return }
        guard !quiet else { return }
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardError.write(("· " + message + "\n").data(using: .utf8)!)
    }

    /// Result line for humans (stdout).
    func say(_ message: String) {
        guard !json else { return }
        print(message)
    }

    func fail(_ status: Exit, _ message: String, hint: String? = nil) -> Never {
        if json {
            var o: [String: Any] = ["event": "result", "ok": false, "code": status.code, "exit": Int(status.rawValue), "error": message]
            if let hint { o["hint"] = hint }
            emit(o)
        } else {
            FileHandle.standardError.write(("qx20: " + message + "\n").data(using: .utf8)!)
            if let hint { FileHandle.standardError.write(("      " + hint + "\n").data(using: .utf8)!) }
        }
        Foundation.exit(status.rawValue)
    }
}

// MARK: - Settings shared with the app

struct Settings {
    let defaults = UserDefaults(suiteName: appDomain) ?? .standard

    var key: String { defaults.string(forKey: "printerPassword") ?? "" }
    var network: String { defaults.string(forKey: "ssid") ?? "" }
    var paper: Paper { Paper(rawValue: defaults.string(forKey: "paper") ?? "") ?? .card }
    var returnToNetwork: Bool { defaults.object(forKey: "returnToNetwork") as? Bool ?? true }
    var squareSizeCode: Int? { Int(defaults.string(forKey: "squareSizeCode") ?? "") }

    static let names = ["key": "printerPassword", "network": "ssid", "paper": "paper", "return": "returnToNetwork"]

    func set(_ name: String, _ value: String) throws {
        guard let k = Self.names[name] else { throw UsageError("unknown setting \(name) (use: key, network, paper, return)") }
        switch name {
        case "paper":
            guard Paper(rawValue: value) != nil else { throw UsageError("paper must be card or square") }
            defaults.set(value, forKey: k)
        case "return":
            guard let b = ["true": true, "yes": true, "1": true, "false": false, "no": false, "0": false][value.lowercased()]
            else { throw UsageError("return must be true or false") }
            defaults.set(b, forKey: k)
        default:
            defaults.set(value, forKey: k)
        }
    }

    func unset(_ name: String) throws {
        guard let k = Self.names[name] else { throw UsageError("unknown setting \(name)") }
        defaults.removeObject(forKey: k)
    }
}

// MARK: - Errors → exit codes

func classify(_ error: Error, noSwitch: Bool = false) -> (Exit, String, String?) {
    let message = error.localizedDescription
    let noSwitchHint = noSwitch
        ? "With --no-switch, join the printer's Wi-Fi (QX20-…) before running qx20."
        : "Or join the printer's Wi-Fi yourself and run again with --no-switch."
    switch error {
    case let e as CPNPError:
        if case .printer = e {
            return (.printerError, message, "Check paper and ink cassette, then turn the printer off and on.")
        }
        return (.unreachable, message, "Is the printer on? \(noSwitchHint)")
    case let e as WiFiError:
        switch e {
        case .wrongKey:
            return (.notConfigured, message,
                    "Set the key printed inside the ink cassette cover (case-sensitive): qx20 config set key <KEY>")
        case .namesHidden:
            return (.locationPermission,
                    "macOS hides Wi-Fi network names: QX20 Print doesn't have Location access yet.",
                    "Run `qx20 setup`: it opens QX20 Print so you can allow Location (the tool uses the app's permission). \(noSwitchHint)")
        default:
            return (.unreachable, message, "Is the printer on? \(noSwitchHint)")
        }
    case is JobError:
        return (.unreachable, message, noSwitchHint)
    case let e as ImagePrepError:
        return (.usage, e.localizedDescription, nil)
    default:
        return (.unreachable, message, nil)
    }
}

// MARK: - Sheets

struct SheetPlan {
    var paper: Paper
    var mode: FitMode
    var marginMM: Double
    var gapMM: Double
    var perSheet: Int?
    var together: Bool
    var repeatImages: Bool
    var rotate: Bool
    var guides: Bool

    init(_ a: Args, settings: Settings) throws {
        if let p = a.values["paper"] {
            guard let paper = Paper(rawValue: p) else { throw UsageError("--paper must be card or square") }
            self.paper = paper
        } else {
            paper = settings.paper
        }
        if a.flags.contains("fit") && a.flags.contains("fill") { throw UsageError("use --fit or --fill, not both") }
        mode = a.flags.contains("fill") ? .fill : .fit
        marginMM = try a.double("margin") ?? 0
        gapMM = try a.double("gap") ?? 1.5
        perSheet = try a.int("per-sheet")
        together = a.flags.contains("together")
        repeatImages = a.flags.contains("repeat")
        rotate = !a.flags.contains("no-rotate")
        guides = a.flags.contains("guides")
        if together && perSheet != nil { throw UsageError("use --together or --per-sheet, not both") }
        if repeatImages && perSheet == nil { throw UsageError("--repeat needs --per-sheet N") }
    }

    /// Group the images into sheets.
    func sheets(_ sources: [LayerSource]) -> [[LayerSource]] {
        if together { return [sources] }
        guard let n = perSheet else { return sources.map { [$0] } }
        var chunks = stride(from: 0, to: sources.count, by: n).map { Array(sources[$0..<min($0 + n, sources.count)]) }
        if repeatImages {
            chunks = chunks.map { chunk in (0..<n).map { chunk[$0 % chunk.count] } }
        }
        return chunks
    }

    func render(_ sheet: [LayerSource]) throws -> RenderedPage {
        let grid: GridPreset = perSheet.map { .count($0) } ?? .auto
        let area = Layout.area(paper: paper, mode: mode, borderMM: marginMM,
                               singleImage: sheet.count == 1 && grid == .auto)
        let placements = Layout.arrange(aspects: sheet.map(\.aspect), in: area, gap: Double(mmToPx(gapMM)),
                                        mode: mode, grid: grid, allowRotation: rotate)
        let layers = zip(sheet, placements).map { CompositionLayer(source: $0, placement: $1) }
        return try ImagePrep.renderComposition(layers, paper: paper, cutGuides: guides)
    }
}

func loadImages(_ paths: [String], out: Output) -> [LayerSource] {
    guard !paths.isEmpty else { out.fail(.usage, "no images given", hint: "e.g. qx20 print photo.jpg") }
    return paths.map { path in
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { out.fail(.usage, "file not found: \(path)") }
        do { return try LayerSource.load(url) } catch { out.fail(.usage, "can't read image: \(path)") }
    }
}

// MARK: - Location permission

/// macOS only shows Wi-Fi names to processes with Location access. The first
/// time, ask for it (macOS shows a dialog) and wait for the answer.
@discardableResult
func ensureLocationAccess(out: Output, interactive: Bool = true) -> Bool {
    let wifi = WiFi.shared
    // A fresh process gets its real authorization asynchronously (delegate
    // callback); wait briefly for it before deciding.
    var settled = false
    wifi.onAuthorizationChange = { _ in settled = true }
    wifi.refreshLocationStatus()
    let settle = Date().addingTimeInterval(2)
    while !settled && !wifi.hasLocationAccess && Date() < settle {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    if wifi.hasLocationAccess { return true }
    guard interactive, wifi.locationStatus == .notDetermined else { return false }
    out.log("Asking macOS for Location access (needed to see Wi-Fi network names). Choose Allow in the dialog.")
    var answered = false
    wifi.onAuthorizationChange = { status in if status != .notDetermined { answered = true } }
    wifi.requestLocationAccess()
    let deadline = Date().addingTimeInterval(90)
    while !answered && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
    return wifi.hasLocationAccess
}

/// The Wi-Fi service checks the Location permission of the app that contains
/// this tool (QX20 Print), so test what actually matters: can we see names?
func networkNamesVisible() -> Bool {
    do { _ = try WiFi.shared.scanForPrinters(); return true }
    catch WiFiError.namesHidden { return false }
    catch { return true }
}

/// Open QX20 Print so the user can allow Location there, then wait until the
/// network names become visible.
func waitForAppPermission(out: Output, timeout: TimeInterval = 120) -> Bool {
    // The real executable lives in QX20 Print.app/Contents/MacOS (the PATH entry is a link)
    let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    var app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if app.pathExtension != "app" { app = URL(fileURLWithPath: "/Applications/QX20 Print.app") }
    guard app.pathExtension == "app", FileManager.default.fileExists(atPath: app.path) else {
        out.log("qx20 isn't running from inside QX20 Print.app, so it can't get the app's Location permission.")
        return false
    }
    out.log("Opening QX20 Print: allow Location access there (the command line tool uses the app's permission).")
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = [app.path]
    try? open.run()
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        if networkNamesVisible() { return true }
    }
    return false
}

func locationStatusName(_ s: CLAuthorizationStatus) -> String {
    switch s {
    case .notDetermined: return "not_determined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorizedAlways, .authorizedWhenInUse: return "granted"
    @unknown default: return "unknown"
    }
}

// MARK: - Commands

func printerOptions(_ a: Args, settings: Settings, paper: Paper, out: Output) throws -> PrintOptions {
    let key = a.values["key"] ?? settings.key
    let testing = a.values["ip"] != nil
    if key.isEmpty && !a.flags.contains("no-switch") && !testing {
        out.fail(.notConfigured, "the printer key is not configured",
                 hint: "Run: qx20 config set key <KEY> (it's printed inside the ink cassette cover), or pass --key.")
    }
    var sizeCode = try a.int("size-code", min: 0)
    if sizeCode == nil { sizeCode = paper == .square ? settings.squareSizeCode : paper.defaultSizeCode }
    guard let code = sizeCode else {
        throw UsageError("the media code for square paper isn't known yet; pass --size-code N to experiment")
    }
    var o = PrintOptions(settings: PrintSettings(paper: paper), sizeCode: code,
                         ssid: a.values["network"] ?? settings.network, password: key)
    o.switchNetwork = !a.flags.contains("no-switch")
    o.returnToNetwork = !a.flags.contains("stay") && settings.returnToNetwork
    if let ip = a.values["ip"] {
        o.printerIP = ip
        o.requirePrinterNetwork = false
        o.switchNetwork = false
    }
    if let p = a.values["port"].flatMap(UInt16.init) { o.printerPort = p }
    if let p = a.values["local-port"].flatMap(UInt16.init) { o.localPort = p }
    return o
}

func jobEventHandler(_ out: Output) -> (JobEvent) -> Void {
    return { ev in
        switch ev {
        case .log(let s):
            if s.contains("[debug]") { return }
            out.log(s.trimmingCharacters(in: .whitespaces))
        case .status(let s, let p):
            if out.json {
                var o: [String: Any] = ["event": "status", "message": s]
                if let p { o["progress"] = (p * 100).rounded() / 100 }
                out.emit(o)
            }
        case .itemStarted(let i, let total, let name):
            if out.json { out.emit(["event": "sheet_started", "index": i + 1, "total": total, "name": name]) }
        case .itemFinished(let i, let ok):
            if out.json { out.emit(["event": "sheet_finished", "index": i + 1, "ok": ok]) }
        }
    }
}

func cmdPrint(_ a: Args, out: Output) throws -> Never {
    let settings = Settings()
    let plan = try SheetPlan(a, settings: settings)
    let copies = try a.int("copies") ?? 1
    let sources = loadImages(a.positional, out: out)
    let sheets = plan.sheets(sources)
    let options = try printerOptions(a, settings: settings, paper: plan.paper, out: out)

    var items: [PrintItem] = []
    for (i, sheet) in sheets.enumerated() {
        let name = sheet.count == 1 ? sheet[0].name : "sheet \(i + 1) (\(sheet.count) images)"
        for c in 0..<copies {
            let label = copies > 1 ? "\(name) · copy \(c + 1)/\(copies)" : name
            items.append(PrintItem(name: label) { try plan.render(sheet) })
        }
    }
    out.log("\(items.count) sheet(s) on \(plan.paper.rawValue) paper")
    if options.switchNetwork { ensureLocationAccess(out: out) }
    do {
        let failed = try PrintJob.run(items, options: options, onEvent: jobEventHandler(out))
        let status: Exit = failed == 0 ? .ok : .someFailed
        if out.json {
            out.emit(["event": "result", "ok": failed == 0, "code": status.code, "exit": Int(status.rawValue),
                      "printed": items.count - failed, "failed": failed])
        } else {
            out.say(failed == 0 ? "Printed \(items.count) sheet(s)." : "\(failed) of \(items.count) sheet(s) failed.")
        }
        Foundation.exit(status.rawValue)
    } catch {
        let (code, message, hint) = classify(error, noSwitch: a.flags.contains("no-switch"))
        out.fail(code, message, hint: hint)
    }
}

func cmdPreview(_ a: Args, out: Output) throws -> Never {
    let plan = try SheetPlan(a, settings: Settings())
    guard let target = a.values["o"] ?? a.values["output"] else {
        throw UsageError("preview needs -o <file.png | directory>")
    }
    let sheets = plan.sheets(loadImages(a.positional, out: out))
    let targetURL = URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
    let single = sheets.count == 1 && targetURL.pathExtension.lowercased() == "png"
    if !single { try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true) }
    var files: [String] = []
    for (i, sheet) in sheets.enumerated() {
        let url = single ? targetURL : targetURL.appendingPathComponent(String(format: "sheet-%02d.png", i + 1))
        try ImagePrep.writePNG(try plan.render(sheet).image, to: url)
        files.append(url.path)
        out.log("wrote \(url.path)")
    }
    if out.json {
        out.emit(["event": "result", "ok": true, "code": "ok", "exit": 0, "files": files, "paper": plan.paper.rawValue])
    } else {
        files.forEach { out.say($0) }
    }
    exit(0)
}

func cmdStatus(_ a: Args, out: Output) throws -> Never {
    let settings = Settings()
    let options = try printerOptions(a, settings: settings, paper: .card, out: out)
    if options.switchNetwork { ensureLocationAccess(out: out) }
    do {
        let (device, status) = try PrintJob.checkStatus(options: options, onEvent: jobEventHandler(out))
        let model = device.components(separatedBy: ";").first { $0.hasPrefix("MDL:") }?
            .replacingOccurrences(of: "MDL:", with: "") ?? "QX20"
        if out.json {
            out.emit(["event": "result", "ok": true, "code": "ok", "exit": 0, "model": model, "device": device,
                      "paper": status.paper, "ink": status.ink, "error": status.error,
                      "imageRange": ["min": [status.minSize.0, status.minSize.1], "max": [status.maxSize.0, status.maxSize.1]]])
        } else {
            out.say("\(model)")
            out.say("Paper: \(status.paper) · Ink: \(status.ink) · Error: \(status.error)")
            out.say(status.error == 0 ? "Ready." : "The printer reports error \(status.error).")
        }
        exit(0)
    } catch {
        let (code, message, hint) = classify(error, noSwitch: a.flags.contains("no-switch"))
        out.fail(code, message, hint: hint)
    }
}

func cmdScan(_ a: Args, out: Output) -> Never {
    ensureLocationAccess(out: out)
    do {
        let found = try WiFi.shared.scanForPrinters()
        if out.json {
            out.emit(["event": "result", "ok": true, "code": "ok", "exit": 0,
                      "printers": found.map { ["network": $0.ssid, "rssi": $0.rssi, "bars": $0.bars] }])
        } else if found.isEmpty {
            out.say("No QX20 printer found. Is it on?")
        } else {
            for n in found { out.say("\(n.ssid)  \(String(repeating: "▮", count: n.bars))\(String(repeating: "▯", count: 3 - n.bars))  \(n.rssi) dBm") }
        }
        exit(0)
    } catch {
        let (code, message, hint) = classify(error, noSwitch: a.flags.contains("no-switch"))
        out.fail(code, message, hint: hint)
    }
}

/// First-time setup: Location permission, printer key, nearby printers.
func cmdSetup(_ a: Args, out: Output) -> Never {
    let settings = Settings()
    ensureLocationAccess(out: out)
    var granted = networkNamesVisible()
    if !granted { granted = waitForAppPermission(out: out) }
    let status = granted ? "granted" : "app_not_allowed"
    var printers: [FoundNetwork] = []
    if granted { printers = (try? WiFi.shared.scanForPrinters()) ?? [] }
    let keySet = !settings.key.isEmpty
    if out.json {
        out.emit(["event": "result", "ok": granted && keySet, "code": granted ? (keySet ? "ok" : "not_configured") : "location_permission",
                  "exit": Int((granted ? (keySet ? Exit.ok : .notConfigured) : .locationPermission).rawValue),
                  "location": status, "keyConfigured": keySet, "printers": printers.map(\.ssid)])
    } else {
        out.say("Location access   \(granted ? "✓ granted" : "✗ QX20 Print doesn't have Location access yet")")
        if !granted {
            out.say("  → Open QX20 Print and allow Location (System Settings › Privacy & Security › Location Services).")
        }
        out.say("Printer key       \(keySet ? "✓ configured" : "✗ not set  → qx20 config set key <KEY>")")
        if granted {
            out.say("Nearby printers   \(printers.isEmpty ? "none found (is it on?)" : printers.map(\.ssid).joined(separator: ", "))")
        }
    }
    exit(granted ? (keySet ? 0 : Exit.notConfigured.rawValue) : Exit.locationPermission.rawValue)
}

func cmdConfig(_ a: Args, out: Output) throws -> Never {
    let settings = Settings()
    let sub = a.positional.first ?? "show"
    switch sub {
    case "show":
        let key = settings.key
        let masked = key.isEmpty ? "" : String(repeating: "•", count: max(0, key.count - 3)) + key.suffix(3)
        if out.json {
            out.emit(["event": "result", "ok": true, "code": "ok", "exit": 0, "keyConfigured": !key.isEmpty,
                      "network": settings.network, "paper": settings.paper.rawValue, "return": settings.returnToNetwork])
        } else {
            out.say("key      \(key.isEmpty ? "(not set)" : masked)")
            out.say("network  \(settings.network.isEmpty ? "(automatic: strongest QX20-…)" : settings.network)")
            out.say("paper    \(settings.paper.rawValue)")
            out.say("return   \(settings.returnToNetwork)")
        }
    case "set":
        guard a.positional.count == 3 else { throw UsageError("usage: qx20 config set <key|network|paper|return> <value>") }
        try settings.set(a.positional[1], a.positional[2])
        if out.json { out.emit(["event": "result", "ok": true, "code": "ok", "exit": 0]) } else { out.say("Saved.") }
    case "unset":
        guard a.positional.count == 2 else { throw UsageError("usage: qx20 config unset <name>") }
        try settings.unset(a.positional[1])
        if out.json { out.emit(["event": "result", "ok": true, "code": "ok", "exit": 0]) } else { out.say("Removed.") }
    default:
        throw UsageError("unknown config command \(sub)")
    }
    exit(0)
}

/// Developer helpers (not in the help text).
func cmdDev(_ a: Args) -> Never {
    func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    switch a.positional.first {
    case "packets":
        print("sessionEnd   \(hex(CPNPPacket.sessionEnd(pid: 1)))")
        print("sessionStart \(hex(CPNPPacket.sessionStart(pid: 2)))")
        print("startPrint   \(hex(CPNPPacket.startPrint(sizeCode: 18)))")
        print("probe        \(hex(CPNPPacket.probe(jpegSize: 1234, width: 644, height: 826)))")
        print("endPrint     \(hex(CPNPPacket.endPrint()))")
        exit(0)
    default:
        print("dev commands: packets")
        exit(2)
    }
}

// MARK: - Main

let rawArgs = Array(CommandLine.arguments.dropFirst())
let wantsJSON = rawArgs.contains("--json")
let earlyOut = Output(json: wantsJSON, quiet: false)

do {
    let a = try Args(rawArgs)
    let out = Output(json: a.flags.contains("json"), quiet: a.flags.contains("quiet"))
    if a.flags.contains("version") { print(version); exit(0) }
    if a.flags.contains("help") || a.command.isEmpty || a.command == "help" { print(usage); exit(0) }
    switch a.command {
    case "print": try cmdPrint(a, out: out)
    case "preview": try cmdPreview(a, out: out)
    case "status": try cmdStatus(a, out: out)
    case "scan": cmdScan(a, out: out)
    case "setup": cmdSetup(a, out: out)
    case "config": try cmdConfig(a, out: out)
    case "dev": cmdDev(a)
    default: throw UsageError("unknown command \(a.command)")
    }
} catch let e as UsageError {
    earlyOut.fail(.usage, e.message, hint: "See: qx20 help")
} catch {
    earlyOut.fail(.usage, error.localizedDescription)
}
