import CoreLocation
import QX20Core
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: PrintModel
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                TextField("Network", text: $model.ssid, prompt: Text("Automatic (QX20-…)"))
                SecureField("Key", text: $password, prompt: Text("Printed inside the ink cassette cover"))
                    .onChange(of: password) { model.password = password }
                Toggle("Return to my network when done", isOn: $model.returnToNetwork)
                Button("Connect Printer Assistant…") { model.showWizard = true }
            } header: {
                Text("Printer Wi-Fi")
            } footer: {
                Text("Open the ink cassette cover: you’ll see a 9-character key. The network is called QX20- followed by its last 3 characters. Leave the network empty to find it automatically. The key is stored in the app’s preferences; it only opens the printer’s local network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Location permission") {
                LocationPermissionView()
            }

            Section("Advanced") {
                TextField("Media code for square paper", text: $model.squareSizeCode,
                          prompt: Text("17"))
                Text("Card paper uses code 18 and square paper code 17. Leave empty unless you know what you’re doing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 470)
        .onAppear {
            password = model.password
        }
    }


}
