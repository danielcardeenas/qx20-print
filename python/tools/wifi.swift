// Minimal Wi-Fi helper using CoreWLAN.
//   wifi join <ssid> <password>   join a network
//   wifi leave                    disassociate (macOS auto-joins the preferred network)
//   wifi ssid                     print the current SSID (may be empty without location access)
import CoreWLAN
import Foundation

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

guard let iface = CWWiFiClient.shared().interface() else { fail("no Wi-Fi interface") }
let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: wifi join <ssid> <password> | leave | ssid") }

switch args[1] {
case "join":
    guard args.count == 4 else { fail("usage: wifi join <ssid> <password>") }
    let ssid = args[2], pass = args[3]
    if !iface.powerOn() { try? iface.setPower(true); sleep(2) }
    var network: CWNetwork?
    for attempt in 1...3 {
        let nets = (try? iface.scanForNetworks(withSSID: nil)) ?? []
        network = nets.first(where: { $0.ssid == ssid })
        if network != nil { break }
        FileHandle.standardError.write("\(ssid) not found (attempt \(attempt)), retrying...\n".data(using: .utf8)!)
        sleep(2)
    }
    guard let net = network else { fail("network \(ssid) not found; is the printer on?") }
    do { try iface.associate(to: net, password: pass) }
    catch { fail("join failed: \(error.localizedDescription)") }
    print("joined \(ssid)")
case "leave":
    iface.disassociate()
    print("disassociated")
case "scan":
    do {
        let nets = try iface.scanForNetworks(withSSID: nil)
        print("found \(nets.count)")
        for n in nets { print(" - \(n.ssid ?? "<nil>")") }
    } catch { fail("scan error: \(error)") }
case "ssid":
    print(iface.ssid() ?? "")
default:
    fail("unknown command \(args[1])")
}
