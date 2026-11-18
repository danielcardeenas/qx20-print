import CoreGraphics
import Foundation

public struct PrintItem: Sendable {
    public let name: String
    /// Builds the page to print (called off the main thread before connecting).
    public let makePage: @Sendable () throws -> RenderedPage

    public init(name: String, makePage: @escaping @Sendable () throws -> RenderedPage) {
        self.name = name; self.makePage = makePage
    }

    /// A single image placed with `settings` (fit / fill / margin).
    public init(name: String, image: CGImage, settings: PrintSettings) {
        let img = image
        self.init(name: name) { try ImagePrep.render(img, settings: settings) }
    }
}

public struct PrintOptions: Sendable {
    public var settings = PrintSettings()
    public var sizeCode: Int
    public var ssid: String
    public var password: String
    /// Join the printer's Wi-Fi automatically (otherwise the Mac must already be on it).
    public var switchNetwork = true
    /// Leave the printer's Wi-Fi when done so macOS rejoins the usual network.
    public var returnToNetwork = true
    public var printerIP = "192.168.0.1"
    /// CPNP ports (only changed to test against scripts/fake_qx20.py).
    public var printerPort: UInt16 = 8609
    public var localPort: UInt16 = 8609
    /// Check that the Mac is on the printer's network first (off for tests).
    public var requirePrinterNetwork = true

    public init(settings: PrintSettings, sizeCode: Int, ssid: String, password: String) {
        self.settings = settings; self.sizeCode = sizeCode; self.ssid = ssid; self.password = password
    }
}

public enum JobEvent {
    case log(String)
    /// Overall status line + optional progress for the current item (0...1)
    case status(String, Double?)
    case itemStarted(index: Int, total: Int, name: String)
    case itemFinished(index: Int, ok: Bool)
}

public enum JobError: LocalizedError {
    case notOnPrinterNetwork

    public var errorDescription: String? {
        String(localized: "The Mac didn’t get an address on the printer’s network (192.168.0.x).")
    }
}

final class StopFlag {
    private let lock = NSLock()
    private var stopped = false
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
}

public enum PrintJob {

    /// Run `body` while connected to the printer's Wi-Fi. Blocking.
    public static func withPrinterNetwork<T>(_ options: PrintOptions,
                                             onEvent: @escaping (JobEvent) -> Void,
                                             body: () throws -> T) throws -> T {
        let wifi = WiFi.shared
        let log: (String) -> Void = { onEvent(.log($0)) }
        if !options.requirePrinterNetwork { return try body() }
        var joined = false
        var joinedSSID = options.ssid

        if !wifi.isOnPrinterNetwork {
            guard options.switchNetwork else { throw JobError.notOnPrinterNetwork }
            let target = options.ssid.isEmpty ? String(localized: "the printer") : options.ssid
            onEvent(.status(String(localized: "Connecting to \(target)…"), nil))
            log(String(localized: "Connecting to \(target)…"))
            joinedSSID = try wifi.join(ssid: options.ssid, password: options.password)
            joined = true
            log(String(localized: "Network: \(joinedSSID)"))
            for _ in 0..<30 where !wifi.isOnPrinterNetwork { sleep(1) }
            guard wifi.isOnPrinterNetwork else {
                wifi.leave()
                throw JobError.notOnPrinterNetwork
            }
        }
        log(String(localized: "Connected to the printer (\(wifi.currentIP ?? "?")).")) 

        // macOS may jump back to a network with internet mid-print: rejoin.
        let stop = StopFlag()
        if options.switchNetwork {
            let rejoinSSID = joinedSSID
            let watchdog = Thread {
                while !stop.isStopped {
                    sleep(2)
                    if stop.isStopped { break }
                    if !wifi.isOnPrinterNetwork {
                        log(String(localized: "macOS left the printer’s network; reconnecting…"))
                        _ = try? wifi.join(ssid: rejoinSSID, password: options.password)
                    }
                }
            }
            watchdog.start()
        }
        defer {
            stop.stop()
            if joined && options.returnToNetwork {
                log(String(localized: "Returning to your usual network…"))
                onEvent(.status(String(localized: "Returning to your network…"), nil))
                wifi.leave()
            }
        }
        waitForPrinter(options, log: log)
        return try body()
    }

    /// Right after joining, macOS has an address but often can't reach the printer
    /// yet ("No route to host", or no UDP reply) for a few seconds. Ask until it answers.
    static func waitForPrinter(_ options: PrintOptions, log: (String) -> Void, seconds: Int = 20) {
        let printer = QX20Printer(ip: options.printerIP, port: options.printerPort, localPort: options.localPort)
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        var told = false
        while true {
            if (try? printer.discover()) != nil { return }
            if Date() >= deadline { return }   // let the job report the real error
            if !told {
                log(String(localized: "Waiting for the printer to answer…"))
                told = true
            }
            sleep(1)
        }
    }

    /// Print several images in one Wi-Fi session. Returns how many failed.
    @discardableResult
    public static func run(_ items: [PrintItem], options: PrintOptions,
                           onEvent: @escaping (JobEvent) -> Void) throws -> Int {
        let log: (String) -> Void = { onEvent(.log($0)) }
        // Prepare JPEGs before touching the network
        let pages: [(String, [UInt8], Int, Int)] = try items.map { item in
            let page = try item.makePage()
            return (item.name, ImagePrep.printJPEG(page), page.width, page.height)
        }

        return try withPrinterNetwork(options, onEvent: onEvent) {
            var failed = 0
            for (index, (name, jpeg, width, height)) in pages.enumerated() {
                onEvent(.itemStarted(index: index, total: pages.count, name: name))
                log(String(localized: "Printing (\(index + 1)/\(pages.count)): \(name)"))
                var ok = false
                for attempt in 1...3 {
                    if attempt > 1 { log(String(localized: "Retry \(attempt)…")) }
                    let printer = QX20Printer(ip: options.printerIP, port: options.printerPort, localPort: options.localPort)
                    do {
                        try printer.printJPEG(jpeg, width: width, height: height, sizeCode: options.sizeCode) { ev in
                            switch ev {
                            case .stage(let s):
                                log("  \(s)")
                                onEvent(.status(s, nil))
                            case .state(let st):
                                log("  \(st.qx20StateDescription)")
                                onEvent(.status(st.qx20StateDescription, st.qx20Progress))
                            case .debug(let d):
                                log("  [debug] \(d)")
                            }
                        }
                        ok = true
                        log("✓ \(name)")
                        break
                    } catch let error as CPNPError where !error.isRetryable {
                        log("✗ \(error.localizedDescription)")
                        onEvent(.itemFinished(index: index, ok: false))
                        if index < pages.count - 1 {
                            log(String(localized: "Cancelled the remaining \(pages.count - index - 1) image(s)."))
                        }
                        throw error
                    } catch {
                        if printer.dataSent {
                            log(String(localized: "Connection lost after sending the image (\(error.localizedDescription)). The printer already had the data; it most likely printed."))
                            onEvent(.status(String(localized: "Waiting for it to finish…"), nil))
                            sleep(60)
                            ok = true
                            break
                        }
                        if attempt == 3 {
                            log("✗ \(error.localizedDescription)")
                        } else {
                            log(String(localized: "Connection error (\(error.localizedDescription)); retrying in 8 s…"))
                            sleep(8)
                        }
                    }
                }
                if !ok { failed += 1 }
                onEvent(.itemFinished(index: index, ok: ok))
                if index < pages.count - 1 { sleep(3) }
            }
            return failed
        }
    }

    /// Read the printer's identity and status (joining its Wi-Fi if needed).
    public static func checkStatus(options: PrintOptions,
                                   onEvent: @escaping (JobEvent) -> Void) throws -> (String, PrinterStatus) {
        try withPrinterNetwork(options, onEvent: onEvent) {
            let printer = QX20Printer(ip: options.printerIP, port: options.printerPort, localPort: options.localPort)
            let device = try printer.discover()
            let status = try printer.status()
            return (device, status)
        }
    }
}
