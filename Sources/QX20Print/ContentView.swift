import QX20Core
import SwiftUI
import UniformTypeIdentifiers

enum ImportTarget: Identifiable {
    case newPages, currentPage
    var id: Int { self == .newPages ? 0 : 1 }
}

struct ContentView: View {
    @EnvironmentObject var model: PrintModel
    @State private var importTarget: ImportTarget?
    @State private var showLog = true
    @AppStorage("showInspector") private var showInspector = true

    var body: some View {
        NavigationSplitView {
            PageList(importTarget: $importTarget)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            VStack(spacing: 0) {
                CanvasPane(importTarget: $importTarget)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showLog {
                    Divider()
                    LogPanel()
                        .frame(height: 140)
                }
            }
            .inspector(isPresented: $showInspector) {
                Inspector(importTarget: $importTarget)
                    .inspectorColumnWidth(min: 280, ideal: 310, max: 380)
            }
            .toolbar {
                ToolbarItemGroup {
                    Menu {
                        Button("Photos as New Sheets…") { importTarget = .newPages }
                        Button("Images on This Sheet…") { importTarget = .currentPage }
                        Divider()
                        Button("Empty Sheet") { model.newEmptyPage() }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .disabled(!model.canUndo)
                    Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                        .disabled(!model.canRedo)
                    Button { withAnimation { showLog.toggle() } } label: {
                        Label("Log", systemImage: "list.bullet.rectangle")
                    }
                    .help("Show or hide the log")
                    Button { showInspector.toggle() } label: {
                        Label("Sheet Settings", systemImage: "sidebar.right")
                    }
                    .help("Show or hide the sheet panel")
                }
            }
        }
        .fileImporter(isPresented: Binding(get: { importTarget != nil }, set: { if !$0 { importTarget = nil } }),
                      allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            if importTarget == .currentPage { model.addToCurrentPage(urls) } else { model.addAsNewPages(urls) }
            importTarget = nil
        }
        .sheet(isPresented: $model.showWizard) {
            ConnectWizard()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
                .environmentObject(model)
                .padding(.top, 8)
                .overlay(alignment: .bottomTrailing) {
                    Button("Done") { model.showSettings = false }
                        .keyboardShortcut(.defaultAction)
                        .padding()
                }
        }
        .alert("QX20 Print", isPresented: Binding(get: { model.alertMessage != nil },
                                                set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

struct PageList: View {
    @EnvironmentObject var model: PrintModel
    @Binding var importTarget: ImportTarget?
    @State private var dropTargeted = false

    var body: some View {
        List(selection: $model.selectedPageID) {
            ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                HStack(spacing: 10) {
                    Thumbnail(image: model.renders[page.id]?.image, paper: model.paper)
                        .frame(width: 40, height: 50)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(page.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        (page.layers.count == 1 ? Text("Sheet \(index + 1)") : Text("Sheet \(index + 1) · \(page.layers.count) images"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .tag(page.id)
                .contextMenu {
                    Button("Print This Sheet") { model.printPages([page]) }
                    Button("Duplicate Sheet") { model.duplicatePage(page.id) }
                    Divider()
                    Button("Delete Sheet", role: .destructive) { model.removePage(page.id) }
                }
            }
        }
        .onDeleteCommand { if let id = model.selectedPageID { model.removePage(id) } }
        .overlay {
            if model.pages.isEmpty {
                ContentUnavailableView {
                    Label("No sheets", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Drag photos here: each one becomes a sheet.")
                } actions: {
                    Button("Add Photos…") { importTarget = .newPages }
                }
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(4)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addAsNewPages(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .safeAreaInset(edge: .bottom) {
            if !model.pages.isEmpty {
                HStack {
                    Text("Sheets: \(model.pages.count)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove All") { model.removeAllPages() }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
}

struct Thumbnail: View {
    let image: CGImage?
    let paper: Paper

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(CGFloat(paper.width) / CGFloat(paper.height), contentMode: .fit)
            } else {
                Rectangle().fill(.white)
                    .aspectRatio(CGFloat(paper.width) / CGFloat(paper.height), contentMode: .fit)
            }
        }
        .overlay(Rectangle().stroke(.black.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
    }
}
