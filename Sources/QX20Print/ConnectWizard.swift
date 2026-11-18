import QX20Core
import SwiftUI

/// Step-by-step assistant to connect a QX20: permission, find the printer's
/// network, enter its key and test the connection.
struct ConnectWizard: View {
    @EnvironmentObject var model: PrintModel
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable { case welcome, location, network, key, test }

    @State private var step: Step = .welcome
    @State private var found: [FoundNetwork] = []
    @State private var scanning = false
    @State private var scanError: String?
    @State private var selectedSSID = ""   // empty = automatic
    @State private var key = ""

    var body: some View {
        VStack(spacing: 0) {
            StepDots(current: step.rawValue, total: Step.allCases.count)
                .padding(.top, 18)

            Group {
                switch step {
                case .welcome: welcome
                case .location: location
                case .network: network
                case .key: keyStep
                case .test: test
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.vertical, 20)

            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 560, height: 480)
        .onAppear {
            key = model.password
            selectedSSID = model.ssid
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(symbol: "printer.fill", title: "Connect your QX20")
            Text("It takes about a minute. You’ll need:")
            VStack(alignment: .leading, spacing: 10) {
                Bullet(symbol: "power", text: "The printer turned on")
                Bullet(symbol: "square.stack", text: "Paper and an ink cassette loaded")
                Bullet(symbol: "key", text: "The key printed inside the ink cassette cover")
            }
            Text("Your Mac only joins the printer’s Wi-Fi while printing, then goes back to your usual network.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var location: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(symbol: "location.fill", title: "Allow Location access")
            Text("macOS only shows Wi-Fi network names to apps with Location access. QX20 Print needs them to find your printer; it never reads your location.")
                .fixedSize(horizontal: false, vertical: true)
            LocationPermissionView()
        }
        .onAppear { model.refreshLocation() }
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(symbol: "wifi", title: "Find your printer")
            Text("Turn the printer on and wait a few seconds for its network to appear.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                NetworkRow(title: Text("Automatic (strongest QX20)"), bars: nil,
                           selected: selectedSSID.isEmpty) { selectedSSID = "" }
                ForEach(found) { net in
                    Divider()
                    NetworkRow(title: Text(verbatim: net.ssid), bars: net.bars,
                               selected: selectedSSID == net.ssid) { selectedSSID = net.ssid }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))

            HStack {
                if scanning {
                    ProgressView().controlSize(.small)
                    Text("Searching…").foregroundStyle(.secondary)
                } else if let scanError {
                    Label(scanError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if found.isEmpty {
                    Label("No QX20 printer found yet.", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Label(found.count == 1 ? LocalizedStringKey("Found 1 printer.")
                                           : LocalizedStringKey("Found \(found.count) printers."),
                          systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Search Again", action: scan).disabled(scanning)
            }
            .font(.callout)
        }
        .onAppear(perform: scan)
    }

    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(symbol: "key.fill", title: "Enter the printer key")
            Text("Open the ink cassette cover: inside there is a 9-character key printed next to a QR code.")
                .fixedSize(horizontal: false, vertical: true)
            TextField("Key", text: $key, prompt: Text(verbatim: "ABCDEFGHI"))
                .font(.system(.title3, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { if canContinue { advance() } }
            keyHint
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var keyHint: some View {
        let k = key.trimmingCharacters(in: .whitespaces)
        if k.isEmpty {
            Text("The printer’s network is called QX20- followed by the key’s last 3 characters.")
                .foregroundStyle(.secondary)
        } else if !selectedSSID.isEmpty, selectedSSID.hasPrefix(WiFi.printerNetworkPrefix) {
            let suffix = String(selectedSSID.dropFirst(WiFi.printerNetworkPrefix.count))
            if k.hasSuffix(suffix) {
                Label("Matches \(selectedSSID).", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("This key doesn’t end in “\(suffix)” like \(selectedSSID). Check it, or go back and pick another printer.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } else if k.count != 9 {
            Label("The key usually has 9 characters (this one has \(k.count)).", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else {
            Label("It will connect to QX20-\(String(k.suffix(3))).", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var test: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(symbol: "checkmark.shield", title: "Test the connection")
            Text("QX20 Print will join the printer’s Wi-Fi, read its status and return to your network. You’ll be offline for a few seconds.")
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Text(model.statusText).foregroundStyle(.secondary)
                } else if model.lastCheckOK == true {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
                    VStack(alignment: .leading) {
                        Text("Printer connected!").font(.headline)
                        if let summary = model.printerSummary { Text(summary).foregroundStyle(.secondary) }
                    }
                } else if model.lastCheckOK == false {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.title2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Couldn’t connect").font(.headline)
                        Text(model.lastCheckError ?? "").foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Check that the printer is on and the key is correct, then try again.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        TextField("Key", text: $key, prompt: Text(verbatim: "ABCDEFGHI"))
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .frame(maxWidth: 220)
                            .padding(.top, 6)
                            .onSubmit(retry)
                    }
                }
            }
            .frame(minHeight: 44, alignment: .leading)

            Button(model.lastCheckOK == nil ? LocalizedStringKey("Test Connection") : LocalizedStringKey("Test Again"),
                   action: retry)
            .disabled(model.isBusy)
        }
    }

    // MARK: Footer & navigation

    private var footer: some View {
        HStack {
            if step == .welcome {
                Button("Not Now") { dismiss() }
            } else {
                Button("Back", action: goBack).disabled(model.isBusy)
            }
            Spacer()
            if step == .test {
                Button(model.lastCheckOK == true ? LocalizedStringKey("Start Printing") : LocalizedStringKey("Finish")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy)
            } else {
                Button(step == .welcome ? LocalizedStringKey("Get Started") : LocalizedStringKey("Continue"), action: advance)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
        }
    }

    private var canContinue: Bool {
        switch step {
        case .location: return model.hasLocationAccess
        case .network: return !scanning
        case .key: return key.trimmingCharacters(in: .whitespaces).count >= 8
        default: return true
        }
    }

    private func advance() {
        switch step {
        case .welcome: step = model.hasLocationAccess ? .network : .location
        case .location: step = .network
        case .network: step = .key
        case .key:
            model.ssid = selectedSSID
            model.password = key.trimmingCharacters(in: .whitespaces)
            step = .test
            model.checkPrinter(showAlert: false)
        case .test: break
        }
    }

    /// Test again with the key as it is now in the field (it may have been corrected).
    private func retry() {
        let k = key.trimmingCharacters(in: .whitespaces)
        if !k.isEmpty && k != model.password { model.password = k }
        model.checkPrinter(showAlert: false)
    }

    private func goBack() {
        switch step {
        case .welcome: break
        case .location: step = .welcome
        case .network: step = model.hasLocationAccess ? .welcome : .location
        case .key: step = .network
        case .test: step = .key
        }
    }

    private func scan() {
        scanning = true
        scanError = nil
        Thread.detachNewThread {
            let result = Result { try WiFi.shared.scanForPrinters() }
            DispatchQueue.main.async {
                scanning = false
                switch result {
                case .success(let nets):
                    found = nets
                    // Pick the only printer around
                    if nets.count == 1, selectedSSID.isEmpty { selectedSSID = nets[0].ssid }
                case .failure(let error):
                    scanError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Location permission

/// The app's Location permission with what to do in each state.
struct LocationPermissionView: View {
    @EnvironmentObject var model: PrintModel
    /// Set when the user asked but macOS showed no prompt.
    @State private var promptMissing = false

    private static let privacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon.name)
                    .foregroundStyle(icon.color)
                    .font(.title2)
                title.font(.headline)
            }
            if let detail {
                detail
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
    }

    private enum Permission { case wrongFolder, servicesOff, notDetermined, denied, restricted, granted }

    private var state: Permission {
        if model.runningFromHomeFolder && !WiFi.isGranted(model.locationStatus) { return .wrongFolder }
        if !model.locationServicesOn { return .servicesOff }
        switch model.locationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        default: return WiFi.isGranted(model.locationStatus) ? .granted : .denied
        }
    }

    private var icon: (name: String, color: Color) {
        switch state {
        case .granted: return ("checkmark.circle.fill", .green)
        case .notDetermined: return ("circle.dashed", .secondary)
        case .wrongFolder: return ("folder.badge.questionmark", .orange)
        case .denied, .servicesOff: return ("xmark.circle.fill", .orange)
        case .restricted: return ("lock.circle.fill", .orange)
        }
    }

    private var title: Text {
        switch state {
        case .granted: return Text("Access granted")
        case .notDetermined: return Text("Not allowed yet")
        case .denied: return Text("Access denied")
        case .restricted: return Text("Restricted on this Mac")
        case .servicesOff: return Text("Location Services is off")
        case .wrongFolder: return Text("Move QX20 Print to Applications")
        }
    }

    private var detail: Text? {
        switch state {
        case .granted:
            return nil
        case .notDetermined:
            return promptMissing
                ? Text("No dialog appeared? Open System Settings and turn on QX20 Print under Location Services.")
                : Text("Click the button and choose Allow in the dialog macOS shows.")
        case .denied:
            return Text("QX20 Print was denied before. Open System Settings › Privacy & Security › Location Services and turn on QX20 Print, then come back here.")
        case .restricted:
            return Text("Location access is blocked by this Mac’s configuration (for example Screen Time or a management profile). An administrator has to allow it.")
        case .wrongFolder:
            return Text("macOS can’t verify apps inside your user folder, so it never grants them Location access. QX20 Print will be copied to the Applications folder and reopened from there.")
        case .servicesOff:
            return Text("Location Services is turned off for the whole Mac, so macOS can’t ask for permission. Turn it on in System Settings › Privacy & Security › Location Services, then allow QX20 Print.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .granted, .restricted:
            EmptyView()
        case .notDetermined:
            HStack {
                Button("Allow Location Access") {
                    WiFi.shared.requestLocationAccess()
                    // If macOS shows nothing, point to System Settings
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if model.locationStatus == .notDetermined { promptMissing = true }
                    }
                }
                .buttonStyle(.borderedProminent)
                if promptMissing {
                    Button("Open Privacy Settings") { NSWorkspace.shared.open(Self.privacyURL) }
                }
            }
        case .wrongFolder:
            Button("Move to Applications") { model.moveToApplications() }
                .buttonStyle(.borderedProminent)
        case .denied, .servicesOff:
            Button("Open Privacy Settings") { NSWorkspace.shared.open(Self.privacyURL) }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Pieces

private struct StepHeader: View {
    let symbol: String
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36)
            Text(title).font(.title2.bold())
        }
    }
}

private struct Bullet: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        Label { Text(text) } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 20)
        }
    }
}

private struct NetworkRow: View {
    let title: Text
    let bars: Int?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                title
                Spacer()
                if let bars {
                    Image(systemName: "wifi", variableValue: Double(bars) / 3)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
    }
}

private struct StepDots: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i <= current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: i == current ? 22 : 8, height: 8)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: current)
    }
}
