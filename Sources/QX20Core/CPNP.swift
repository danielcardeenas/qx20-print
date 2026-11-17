import Foundation

// Swift port of qx20.py: Canon's CPNP protocol as used by the SELPHY QX20.
// UDP 8609 for discovery/status/session, then a TCP port negotiated per session.

public enum CPNPError: LocalizedError {
    case network(String)
    case timeout(String)
    case connectionLost(String)
    case protocolError(String)
    /// The printer itself reported a problem (no paper, jam...). Not retryable.
    case printer(String)

    public var errorDescription: String? {
        switch self {
        case .network(let m): return String(localized: "Network error: \(m)")
        case .timeout(let m): return String(localized: "Timed out: \(m)")
        case .connectionLost(let m): return String(localized: "Connection lost: \(m)")
        case .protocolError(let m): return String(localized: "Unexpected response from the printer: \(m)")
        case .printer(let m): return m
        }
    }

    /// Network-level problems that may succeed on a retry.
    public var isRetryable: Bool {
        switch self {
        case .network, .timeout, .connectionLost: return true
        case .protocolError, .printer: return false
        }
    }
}

public struct PrinterStatus: Sendable {
    public var paper: Int
    public var ink: Int
    public var error: Int
    public var minSize: (Int, Int)
    public var maxSize: (Int, Int)

    public var summary: String {
        String(localized: "Paper: \(paper) · Ink: \(ink) · Error: \(error)")
    }
}

public enum PrintEvent: Sendable {
    case stage(String)
    /// Printer state byte while printing (0x01 ready, 0x03/05/07 colours, 0x09 overcoat, 0x10 finishing)
    case state(UInt8)
    case debug(String)
}

public extension UInt8 {
    /// Human readable QX20 print state (observed on hardware).
    var qx20StateDescription: String {
        switch self {
        case 0x01: return String(localized: "Image received")
        case 0x03: return String(localized: "Printing yellow")
        case 0x05: return String(localized: "Printing magenta")
        case 0x07: return String(localized: "Printing cyan")
        case 0x09: return String(localized: "Applying overcoat")
        case 0x10: return String(localized: "Finishing")
        case 0x0A: return String(localized: "Done")
        case 0x0C, 0x0D: return String(localized: "Printer error")
        default: return String(format: String(localized: "State 0x%02X"), self)
        }
    }

    /// Rough progress (0...1) for a print state.
    var qx20Progress: Double? {
        switch self {
        case 0x01: return 0.10
        case 0x03: return 0.25
        case 0x05: return 0.45
        case 0x07: return 0.65
        case 0x09: return 0.85
        case 0x10, 0x0A: return 0.97
        default: return nil
        }
    }
}

/// States where the printer stopped with its red error LED (seen with an empty paper cassette).
let printErrorStates: Set<UInt8> = [0x0C, 0x0D]

// MARK: - Packet builders

public enum CPNPPacket {
    static let magic: [UInt8] = Array("CPNP".utf8)
    public static let maxWriteSize = 33792

    static func put16be(_ b: inout [UInt8], _ o: Int, _ v: Int) {
        b[o] = UInt8((v >> 8) & 0xFF); b[o + 1] = UInt8(v & 0xFF)
    }
    static func put32be(_ b: inout [UInt8], _ o: Int, _ v: Int) {
        b[o] = UInt8((v >> 24) & 0xFF); b[o + 1] = UInt8((v >> 16) & 0xFF)
        b[o + 2] = UInt8((v >> 8) & 0xFF); b[o + 3] = UInt8(v & 0xFF)
    }
    static func put16le(_ b: inout [UInt8], _ o: Int, _ v: Int) {
        b[o] = UInt8(v & 0xFF); b[o + 1] = UInt8((v >> 8) & 0xFF)
    }
    static func put32le(_ b: inout [UInt8], _ o: Int, _ v: Int) {
        b[o] = UInt8(v & 0xFF); b[o + 1] = UInt8((v >> 8) & 0xFF)
        b[o + 2] = UInt8((v >> 16) & 0xFF); b[o + 3] = UInt8((v >> 24) & 0xFF)
    }
    static func le32(_ b: [UInt8], _ o: Int) -> Int {
        Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }

    /// 16-byte CPNP header (+ zeroed body space up to `length`).
    public static func header(cmd: UInt8, pid: UInt16, session: UInt16 = 0,
                              size: Int = 0, length: Int = 16) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: length)
        b.replaceSubrange(0..<4, with: magic)
        b[4] = 0x01
        b[5] = cmd
        put16be(&b, 8, Int(pid))
        put16be(&b, 10, Int(session))
        put32be(&b, 12, size)
        return b
    }

    public static func discover(pid: UInt16) -> [UInt8] {
        header(cmd: 0x30, pid: pid, size: 4, length: 20)
    }

    public static func udpStatus(pid: UInt16) -> [UInt8] {
        header(cmd: 0x20, pid: pid)
    }

    public static func sessionEnd(pid: UInt16) -> [UInt8] {
        header(cmd: 0x11, pid: pid)
    }

    public static func sessionStart(pid: UInt16) -> [UInt8] {
        var b = header(cmd: 0x10, pid: pid, size: 0x188, length: 408)
        let name = utf16be("loveletter")
        b.replaceSubrange(24..<(24 + name.count), with: name)
        let su = utf16be("SPL v2.0")
        b.replaceSubrange(88..<(88 + su.count), with: su)
        let sd = utf16be("Square")
        b.replaceSubrange(152..<(152 + sd.count), with: sd)
        return b
    }

    static func utf16be(_ s: String) -> [UInt8] {
        s.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }

    public static func setMaxWriteSize(pid: UInt16, session: UInt16) -> [UInt8] {
        var b = header(cmd: 0x52, pid: pid, session: session, size: 4, length: 20)
        put32be(&b, 16, maxWriteSize)
        return b
    }

    public static func getMaxWriteSize(pid: UInt16, session: UInt16) -> [UInt8] {
        header(cmd: 0x51, pid: pid, session: session)
    }

    public static func tcpRead(pid: UInt16, session: UInt16) -> [UInt8] {
        header(cmd: 0x20, pid: pid, session: session)
    }

    public static func tcpWrite(pid: UInt16, session: UInt16, payload: [UInt8]) -> [UInt8] {
        header(cmd: 0x21, pid: pid, session: session, size: payload.count) + payload
    }

    /// StartPrint command (64 bytes): media size code + glossy overcoat.
    public static func startPrint(sizeCode: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 64)
        put16le(&b, 0, 0)
        put16le(&b, 2, 0)
        put32le(&b, 4, 64)
        put32le(&b, 8, 0)
        put16le(&b, 12, 1)
        put16le(&b, 14, sizeCode)
        b[16] = 2  // overcoat: glossy
        return b
    }

    /// PrintDataTransfer header (104 bytes).
    public static func printHeader(jpegSize: Int, width: Int, height: Int, offset: Int, chunk: Int) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 104)
        put16le(&h, 0, 0)            // typePrint
        put16le(&h, 2, 1)            // codePrintDataTransfer
        put32le(&h, 4, 104 + chunk)
        put32le(&h, 8, 0)            // typeJpegEasyPrint
        put32le(&h, 12, 1)           // totalJpegImages
        put32le(&h, 16, 0)           // jpegImageNo
        put32le(&h, 20, jpegSize)
        put32le(&h, 24, width)
        put32le(&h, 28, height)
        put32le(&h, 96, offset)
        put32le(&h, 100, chunk)
        return h
    }

    /// The 1-byte probe the printer asks for before the image.
    public static func probe(jpegSize: Int, width: Int, height: Int) -> [UInt8] {
        var h = printHeader(jpegSize: jpegSize, width: width, height: height, offset: 16, chunk: 1)
        put32le(&h, 4, 105)
        return h + [0x00]
    }

    public static func endPrint() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 64)
        put16le(&b, 2, 3)
        put32le(&b, 4, 64)
        return b
    }

    public static func cancelPrint() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 64)
        put16le(&b, 2, 2)
        put32le(&b, 4, 64)
        return b
    }
}

// MARK: - Printer

public final class QX20Printer {
    public let ip: String
    public let port: UInt16
    public let localPort: UInt16

    private var packetID: UInt16 = 0
    private var sessionID: UInt16 = 0
    private var tcpPort: UInt16 = 0
    private var tcp: TCPSocket?

    /// True once the image has started to be sent. If the connection drops after
    /// this point the printer usually finishes on its own, so don't reprint.
    public private(set) var dataSent = false

    public init(ip: String = "192.168.0.1", port: UInt16 = 8609, localPort: UInt16 = 8609) {
        self.ip = ip
        self.port = port
        self.localPort = localPort
    }

    private func nextID() -> UInt16 {
        packetID = packetID >= 65535 ? 1 : packetID + 1
        return packetID
    }

    // MARK: UDP

    private func udpExchange(_ sock: UDPSocket, _ packet: [UInt8]) throws -> [UInt8] {
        try sock.send(packet, to: ip, port: port)
        usleep(200_000)
        return try sock.receive()
    }

    public func discover() throws -> String {
        let sock = try UDPSocket(localPort: localPort, timeout: 3)
        defer { sock.close() }
        let data = try udpExchange(sock, CPNPPacket.discover(pid: nextID()))
        let chars = data.dropFirst(16).filter { $0 >= 32 && $0 < 127 }
        return String(decoding: chars, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    public func status() throws -> PrinterStatus {
        let sock = try UDPSocket(localPort: localPort, timeout: 3)
        defer { sock.close() }
        let data = try udpExchange(sock, CPNPPacket.udpStatus(pid: nextID()))
        guard data.count >= 528 else { throw CPNPError.protocolError("status too short (\(data.count) bytes)") }
        let p = Array(data.dropFirst(16))
        func le16(_ o: Int) -> Int { Int(p[o]) | Int(p[o + 1]) << 8 }
        return PrinterStatus(paper: Int(p[2]), ink: Int(p[3]),
                             error: CPNPPacket.le32(p, 68),
                             minSize: (le16(132), le16(134)), maxSize: (le16(136), le16(138)))
    }

    private func sessionEnd(_ sock: UDPSocket) {
        _ = try? udpExchange(sock, CPNPPacket.sessionEnd(pid: nextID()))
    }

    private func sessionStart(_ sock: UDPSocket) throws {
        let data = try udpExchange(sock, CPNPPacket.sessionStart(pid: nextID()))
        guard data.count >= 22 else { throw CPNPError.protocolError("short session response") }
        let result = Int(data[6]) << 8 | Int(data[7])
        sessionID = UInt16(data[10]) << 8 | UInt16(data[11])
        tcpPort = UInt16(data[20]) << 8 | UInt16(data[21])
        guard result == 0, sessionID != 0, tcpPort != 0 else {
            throw CPNPError.protocolError("could not open a session (result=\(result) sid=\(sessionID) port=\(tcpPort))")
        }
    }

    // MARK: TCP

    private func receivePacket(expectCmd: UInt8? = nil, expectPID: UInt16? = nil) throws -> (typ: UInt8, cmd: UInt8, body: [UInt8]) {
        guard let tcp else { throw CPNPError.connectionLost("no TCP connection") }
        let hdr = try tcp.receiveExact(16)
        guard Array(hdr[0..<4]) == CPNPPacket.magic else {
            throw CPNPError.protocolError("invalid header")
        }
        let typ = hdr[4], cmd = hdr[5]
        let pid = UInt16(hdr[8]) << 8 | UInt16(hdr[9])
        let size = Int(hdr[12]) << 24 | Int(hdr[13]) << 16 | Int(hdr[14]) << 8 | Int(hdr[15])
        let body = size > 0 ? try tcp.receiveExact(size) : []
        if let expectCmd, cmd != expectCmd {
            throw CPNPError.protocolError(String(format: "command 0x%02X, expected 0x%02X", cmd, expectCmd))
        }
        if let expectPID, pid != expectPID {
            throw CPNPError.protocolError("pid \(pid), expected \(expectPID)")
        }
        return (typ, cmd, body)
    }

    /// CPNP Write; returns how many bytes the printer accepted.
    @discardableResult
    private func tcpWrite(_ payload: [UInt8]) throws -> Int {
        guard let tcp else { throw CPNPError.connectionLost("no TCP connection") }
        let pid = nextID()
        try tcp.sendAll(CPNPPacket.tcpWrite(pid: pid, session: sessionID, payload: payload))
        let r = try receivePacket(expectCmd: 0x21, expectPID: pid)
        guard r.typ == 0x81, r.body.count >= 4 else {
            throw CPNPError.protocolError(String(format: "invalid write ack (typ=0x%02X)", r.typ))
        }
        return Int(r.body[0]) << 24 | Int(r.body[1]) << 16 | Int(r.body[2]) << 8 | Int(r.body[3])
    }

    /// CPNP Read: the printer's 64-byte connection/state payload.
    private func tcpRead() throws -> [UInt8] {
        guard let tcp else { throw CPNPError.connectionLost("no TCP connection") }
        let pid = nextID()
        try tcp.sendAll(CPNPPacket.tcpRead(pid: pid, session: sessionID))
        usleep(50_000)
        let r = try receivePacket(expectCmd: 0x20, expectPID: pid)
        guard r.typ == 0x81 else { throw CPNPError.protocolError(String(format: "invalid read ack (typ=0x%02X)", r.typ)) }
        return r.body
    }

    private func sendCommand(_ data: [UInt8]) throws {
        var offset = 0
        while offset < data.count {
            let chunk = min(CPNPPacket.maxWriteSize, data.count - offset)
            let accepted = try tcpWrite(Array(data[offset..<(offset + chunk)]))
            guard accepted > 0, accepted <= chunk else {
                throw CPNPError.protocolError("invalid accepted bytes: \(accepted) of \(chunk)")
            }
            offset += accepted
        }
    }

    private func negotiateMaxWriteSize() throws {
        guard let tcp else { return }
        try tcp.sendAll(CPNPPacket.setMaxWriteSize(pid: nextID(), session: sessionID))
        _ = try receivePacket()
        try tcp.sendAll(CPNPPacket.getMaxWriteSize(pid: nextID(), session: sessionID))
        _ = try receivePacket()
    }

    private func waitForRequest(offset: Int, size: Int, label: String, maxPolls: Int = 120) throws {
        for _ in 0..<maxPolls {
            let p = try tcpRead()
            if p.count >= 32, p[8] == 0x01, p[9] == 0xFF,
               CPNPPacket.le32(p, 24) == offset, CPNPPacket.le32(p, 28) == size {
                return
            }
            usleep(50_000)
        }
        throw CPNPError.timeout(label)
    }

    // MARK: Print

    /// Print a JPEG that is already in the QX20 format (see ImagePrep.printJPEG).
    public func printJPEG(_ jpeg: [UInt8], width: Int, height: Int, sizeCode: Int,
                          onEvent: (PrintEvent) -> Void = { _ in }) throws {
        dataSent = false

        onEvent(.stage(String(localized: "Opening session")))
        let udp = try UDPSocket(localPort: localPort, timeout: 3)
        do {
            sessionEnd(udp)
            usleep(1_000_000)
            try sessionStart(udp)
            udp.close()
        } catch {
            udp.close()
            throw error
        }

        onEvent(.stage(String(localized: "Connecting (TCP \(String(tcpPort)))")))
        let sock = try TCPSocket(ip: ip, port: tcpPort, timeout: 30)
        tcp = sock
        defer { sock.close(); tcp = nil }

        try negotiateMaxWriteSize()

        onEvent(.stage(String(localized: "Starting print")))
        try tcpWrite(CPNPPacket.startPrint(sizeCode: sizeCode))

        onEvent(.stage(String(localized: "Waiting for the printer")))
        try waitForRequest(offset: 16, size: 1, label: String(localized: "the printer did not request the probe"))
        try tcpWrite(CPNPPacket.probe(jpegSize: jpeg.count, width: width, height: height))
        try waitForRequest(offset: 0, size: jpeg.count, label: String(localized: "the printer did not request the image"))

        onEvent(.stage(String(localized: "Sending image (\(jpeg.count / 1024) KB)")))
        dataSent = true
        try sendCommand(CPNPPacket.printHeader(jpegSize: jpeg.count, width: width, height: height,
                                               offset: 0, chunk: jpeg.count) + jpeg)

        onEvent(.stage(String(localized: "Printing")))
        var lastState: UInt8?
        var lastPayload: [UInt8] = []
        for i in 0..<300 {
            let payload = try tcpRead()
            if payload.count >= 42 {
                let state = payload[8]
                if payload[41] > 0 { onEvent(.stage(String(localized: "Printed"))); break }
                if state == 0x0A { onEvent(.stage(String(localized: "Finishing"))); break }
                if printErrorStates.contains(state) {
                    onEvent(.debug("raw=\(hex(payload.prefix(64)))"))
                    throw CPNPError.printer(String(format:
                        String(localized: "The printer reported an error (state 0x%02X). Check that it has paper and nothing is jammed, then turn it off and on again."), state))
                }
                if state != lastState { onEvent(.state(state)); lastState = state }
                if payload != lastPayload {
                    onEvent(.debug(String(format: "t=%.1fs raw=", Double(i) * 0.5) + hex(payload.prefix(64))))
                    lastPayload = payload
                }
            }
            usleep(500_000)
        }

        try tcpWrite(CPNPPacket.endPrint())
        onEvent(.stage(String(localized: "Job closed")))
        sleep(5)
    }
}

func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
}
