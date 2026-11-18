import CoreLocation
import CoreWLAN
import Darwin
import Foundation

public enum WiFiError: LocalizedError {
    case noInterface
    case notFound(String)
    case namesHidden
    case joinFailed(String)
    /// The printer refused the key (CoreWLAN kCWChallengeFailureErr).
    case wrongKey(String)

    public var errorDescription: String? {
        switch self {
        case .noInterface:
            return String(localized: "No Wi-Fi interface found")
        case .notFound(let ssid):
            return ssid.isEmpty
                ? String(localized: "No QX20 network found. Is the printer on?")
                : String(localized: "Network \(ssid) not found. Is the printer on?")
        case .namesHidden:
            return String(localized: "macOS hides Wi-Fi network names: allow Location access for QX20 Print in System Settings › Privacy & Security › Location Services.")
        case .joinFailed(let msg):
            return String(localized: "Couldn’t connect to the printer: \(msg)")
        case .wrongKey(let ssid):
            return String(localized: "\(ssid) didn’t accept the key. Check it, including uppercase and lowercase letters.")
        }
    }
}

/// A printer network seen in a scan.
public struct FoundNetwork: Identifiable, Hashable, Sendable {
    public let ssid: String
    /// Signal strength in dBm (closer to 0 is stronger).
    public let rssi: Int
    public var id: String { ssid }
    /// 1...3 signal bars.
    public var bars: Int { rssi >= -60 ? 3 : (rssi >= -75 ? 2 : 1) }
}

/// Joins / leaves the printer's Wi-Fi Direct network with CoreWLAN.
/// macOS only reveals network names (SSIDs) to apps with Location access.
public final class WiFi: NSObject, CLLocationManagerDelegate {
    public static let shared = WiFi()

    private let client = CWWiFiClient.shared()
    private let locationManager = CLLocationManager()
    public var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    public static let printerSubnetPrefix = "192.168.0."

    override init() {
        super.init()
        locationManager.delegate = self
    }

    public var interfaceName: String {
        client.interface()?.interfaceName ?? "en0"
    }

    public var locationStatus: CLAuthorizationStatus {
        locationManager.authorizationStatus
    }

    public var hasLocationAccess: Bool { Self.isGranted(locationStatus) }

    /// "Always" and "while using the app" both let the app see network names.
    public static func isGranted(_ status: CLAuthorizationStatus) -> Bool {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: return true
        default: return false
        }
    }

    /// Location Services switched on for the whole Mac. Without it macOS never
    /// shows the permission prompt. Can block: call off the main thread.
    public static var locationServicesEnabled: Bool { CLLocationManager.locationServicesEnabled() }

    /// Re-read the permission (e.g. after the user comes back from System Settings).
    public func refreshLocationStatus() {
        onAuthorizationChange?(locationManager.authorizationStatus)
    }

    /// Call on the main thread (shows the system permission prompt once).
    public func requestLocationAccess() {
        if locationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager.authorizationStatus)
    }

    public var currentIP: String? { Self.ipv4(of: interfaceName) }

    public var isOnPrinterNetwork: Bool {
        currentIP?.hasPrefix(Self.printerSubnetPrefix) ?? false
    }

    /// Prefix of the printers' Wi-Fi Direct networks (e.g. "QX20-ABC").
    public static let printerNetworkPrefix = "QX20-"

    /// Scan and join `ssid`; an empty `ssid` picks the strongest "QX20-…" network.
    /// Returns the joined network name. Blocking; call off the main thread.
    @discardableResult
    public func join(ssid: String, password: String) throws -> String {
        guard let iface = client.interface() else { throw WiFiError.noInterface }
        if !iface.powerOn() {
            try? iface.setPower(true)
            sleep(2)
        }
        var network: CWNetwork?
        var namesHidden = false
        for attempt in 0..<3 {
            let nets = (try? iface.scanForNetworks(withSSID: nil)) ?? []
            if !nets.isEmpty, nets.allSatisfy({ $0.ssid == nil }) { namesHidden = true }
            if ssid.isEmpty {
                network = nets.filter { $0.ssid?.hasPrefix(Self.printerNetworkPrefix) ?? false }
                    .max { $0.rssiValue < $1.rssiValue }
            } else {
                network = nets.first { $0.ssid == ssid }
            }
            if network != nil { break }
            if attempt < 2 { sleep(2) }
        }
        guard let network else {
            throw namesHidden ? WiFiError.namesHidden : WiFiError.notFound(ssid)
        }
        do {
            try iface.associate(to: network, password: password)
        } catch let error as NSError where error.code == CWErr.cwChallengeFailureErr.rawValue {
            throw WiFiError.wrongKey(network.ssid ?? ssid)
        } catch {
            throw WiFiError.joinFailed(error.localizedDescription)
        }
        return network.ssid ?? ssid
    }

    /// List nearby printer networks ("QX20-…"), strongest first, without
    /// changing the current network. Blocking; call off the main thread.
    public func scanForPrinters() throws -> [FoundNetwork] {
        guard let iface = client.interface() else { throw WiFiError.noInterface }
        if !iface.powerOn() { return [] }
        let nets = try iface.scanForNetworks(withSSID: nil)
        if !nets.isEmpty, nets.allSatisfy({ $0.ssid == nil }) { throw WiFiError.namesHidden }
        var best: [String: Int] = [:]
        for n in nets {
            guard let ssid = n.ssid, ssid.hasPrefix(Self.printerNetworkPrefix) else { continue }
            best[ssid] = max(best[ssid] ?? Int.min, n.rssiValue)
        }
        return best.map { FoundNetwork(ssid: $0.key, rssi: $0.value) }.sorted { $0.rssi > $1.rssi }
    }

    /// Disassociate; macOS then auto-joins the user's preferred network.
    public func leave() {
        client.interface()?.disassociate()
    }

    public static func ipv4(of name: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name) == name else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
