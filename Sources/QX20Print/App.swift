import AppKit
import QX20Core
import SwiftUI

@main
struct QX20PrintApp: App {
    @StateObject private var model = PrintModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("QX20 Print", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1120, minHeight: 680)
                .onAppear { WiFi.shared.requestLocationAccess() }
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New empty sheet") { model.newEmptyPage() }
                    .keyboardShortcut("n")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }
                    .keyboardShortcut("z")
                    .disabled(!model.canUndo)
                Button("Redo") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
            }
            CommandMenu("Image") {
                Button("Duplicate") { model.duplicateSelected() }
                    .keyboardShortcut("d")
                    .disabled(model.selectedLayerID == nil)
                Button("Rotate 90°") { model.rotateSelected(by: 90) }
                    .keyboardShortcut("r")
                    .disabled(model.selectedLayerID == nil)
                Button("Bring to Front") { model.reorderSelected(toFront: true) }
                    .keyboardShortcut("]")
                    .disabled(model.selectedLayerID == nil)
                Button("Send to Back") { model.reorderSelected(toFront: false) }
                    .keyboardShortcut("[")
                    .disabled(model.selectedLayerID == nil)
                Button(model.croppingLayerID == nil ? LocalizedStringKey("Crop") : LocalizedStringKey("Apply Crop")) {
                    if model.croppingLayerID != nil { model.finishCrop() } else { model.beginCrop() }
                }
                .keyboardShortcut("k")
                .disabled(model.selectedLayerID == nil)
                Button("Remove Crop") { model.resetCrop() }
                    .disabled(!(model.selectedLayer?.placement.isCropped ?? false))
                Button("Remove from Sheet  (⌫)") { model.removeSelectedLayer() }
                    .disabled(model.selectedLayerID == nil || model.croppingLayerID != nil)
                Divider()
                Button("Auto-Arrange Sheet") { model.autoArrange() }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                    .disabled(model.currentPage?.layers.isEmpty ?? true)
            }
            CommandMenu("Print") {
                Button("Print Sheet") {
                    if let p = model.currentPage { model.printPages([p]) }
                }
                .keyboardShortcut("p")
                .disabled(model.isBusy || (model.currentPage?.layers.isEmpty ?? true))
                Button("Print All") { model.printPages(model.printablePages) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(model.isBusy || model.printablePages.isEmpty)
                Divider()
                Button("Connect Printer…") { model.showWizard = true }
                    .disabled(model.isBusy)
                Button("Check Printer") { model.checkPrinter() }
                    .disabled(model.isBusy)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

/// Receives images opened from Finder ("Open With") or dropped on the Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: PrintModel? {
        didSet { flushPending() }
    }
    private var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        pending += urls.filter(\.isFileURL)
        flushPending()
    }

    private func flushPending() {
        guard let model, !pending.isEmpty else { return }
        let urls = pending
        pending = []
        Task { @MainActor in model.addAsNewPages(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.saveNow() }
    }
}
