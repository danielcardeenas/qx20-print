import Darwin
import Foundation

func errnoString(_ code: Int32 = errno) -> String {
    String(cString: strerror(code))
}

func makeAddress(_ ip: String, _ port: UInt16) -> sockaddr_in {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    inet_pton(AF_INET, ip, &addr.sin_addr)
    return addr
}

func setTimeouts(_ fd: Int32, seconds: Double) {
    var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
    let len = socklen_t(MemoryLayout<timeval>.size)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, len)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, len)
}

/// Blocking UDP socket bound to a local port (the QX20 talks to port 8609 on both ends).
final class UDPSocket {
    let fd: Int32

    init(localPort: UInt16, timeout: Double) throws {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw CPNPError.network("socket UDP: \(errnoString())") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = makeAddress("0.0.0.0", localPort)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            let msg = errnoString()
            Darwin.close(fd)
            throw CPNPError.network("bind UDP \(localPort): \(msg)")
        }
        setTimeouts(fd, seconds: timeout)
    }

    func send(_ data: [UInt8], to ip: String, port: UInt16) throws {
        var addr = makeAddress(ip, port)
        let n = data.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard n == data.count else { throw CPNPError.network("sendto: \(errnoString())") }
    }

    func receive(maxLength: Int = 4096) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: maxLength)
        let n = Darwin.recv(fd, &buf, maxLength, 0)
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { throw CPNPError.timeout(String(localized: "UDP response from the printer")) }
            throw CPNPError.network("recv UDP: \(errnoString())")
        }
        return Array(buf[0..<n])
    }

    func close() { Darwin.close(fd) }
}

/// Blocking TCP connection with connect/read timeouts.
final class TCPSocket {
    let fd: Int32

    init(ip: String, port: UInt16, timeout: Double) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CPNPError.network("socket TCP: \(errnoString())") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var addr = makeAddress(ip, port)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else {
                let msg = errnoString()
                Darwin.close(fd)
                throw CPNPError.network("connect TCP \(port): \(msg)")
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(timeout * 1000))
            if ready <= 0 {
                Darwin.close(fd)
                throw CPNPError.timeout(String(localized: "TCP connection to the printer"))
            }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            if err != 0 {
                Darwin.close(fd)
                throw CPNPError.network("connect TCP \(port): \(errnoString(err))")
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        setTimeouts(fd, seconds: timeout)
    }

    func sendAll(_ data: [UInt8]) throws {
        var offset = 0
        try data.withUnsafeBytes { buf in
            while offset < buf.count {
                let n = Darwin.send(fd, buf.baseAddress! + offset, buf.count - offset, 0)
                if n <= 0 { throw CPNPError.connectionLost(errnoString()) }
                offset += n
            }
        }
    }

    func receiveExact(_ count: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count)
        var buf = [UInt8](repeating: 0, count: max(count, 1))
        while out.count < count {
            let n = Darwin.recv(fd, &buf, count - out.count, 0)
            if n == 0 { throw CPNPError.connectionLost(String(localized: "the printer closed the connection")) }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { throw CPNPError.timeout(String(localized: "TCP read")) }
                throw CPNPError.connectionLost(errnoString())
            }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    func close() { Darwin.close(fd) }
}
