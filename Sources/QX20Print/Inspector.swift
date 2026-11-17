import QX20Core
import SwiftUI

struct Inspector: View {
    @EnvironmentObject var model: PrintModel
    @Binding var importTarget: ImportTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Paper") {
                    Picker("Paper", selection: $model.paper) {
                        ForEach(Paper.allCases) { ($0 == .card ? Text("Card") : Text("Square")).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    LabeledContent("Sheet", value: model.paper.sheetSize)
                        .font(.callout)
                    if model.paper == .square && model.sizeCode == nil {
                        Label("Square paper code not verified yet: set it in Settings › Advanced.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if let layer = model.selectedLayer, layer.placement.isCropped, model.croppingLayerID == nil {
                    Section {
                        Button("Remove crop from \(layer.source.name)") { model.resetCrop() }
                    }
                }
                if let page = model.currentPage {
                    LayoutSection(page: page)
                    LayersSection(page: page, importTarget: $importTarget)
                }

                Section("Cutting") {
                    Toggle("Print cut guides", isOn: $model.cutGuides)
                    Text("A thin grey line around each image, to cut them out by hand.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Printer") {
                    HStack {
                        Image(systemName: "printer.fill")
                            .foregroundStyle(.secondary)
                        Text(model.printerSummary ?? (model.ssid.isEmpty ? "QX20" : model.ssid))
                            .lineLimit(1)
                        Spacer()
                        if model.password.isEmpty {
                            Button("Connect…") { model.showWizard = true }
                                .disabled(model.isBusy)
                        } else {
                            Button("Check") { model.checkPrinter() }
                                .disabled(model.isBusy)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            PrintFooter()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct LayoutSection: View {
    @EnvironmentObject var model: PrintModel
    let page: Page

    var body: some View {
        Section("Layout") {
            Picker("Images per sheet", selection: Binding(get: { page.grid }, set: { model.setGrid($0) })) {
                ForEach(GridPreset.all) { Text($0.title).tag($0) }
            }

            HStack {
                if page.autoLayout {
                    Label("Arranged automatically", systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Arranged by hand", systemImage: "hand.draw")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Auto-Arrange") { model.autoArrange() }
                    .disabled(page.autoLayout || page.layers.isEmpty)
            }

            if let n = page.grid.cellCount, !page.layers.isEmpty, page.layers.count < n {
                Button {
                    model.fillWithCopies()
                } label: {
                    Label("Fill all \(n) spots with copies", systemImage: "square.grid.3x3.fill")
                }
            }

            Picker("Fit", selection: $model.mode) {
                ForEach(FitMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            (model.mode == .fit
                 ? Text("Each image whole, nothing cropped.")
                 : Text("Each image covers its space; the excess is cropped."))
                .font(.caption)
                .foregroundStyle(.secondary)

            MMSlider(title: "Margin", value: $model.borderMM, range: 0...6)
            if page.layers.count > 1 || page.grid != .auto {
                MMSlider(title: "Spacing", value: $model.gapMM, range: 0...6)
            }
            Toggle("Rotate to use the space better", isOn: $model.allowRotation)
        }
    }
}

struct MMSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                (value == 0 ? Text("none") : Text(String(format: "%.1f mm", value)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: 0.5)
        }
    }
}

struct LayersSection: View {
    @EnvironmentObject var model: PrintModel
    let page: Page
    @Binding var importTarget: ImportTarget?

    var body: some View {
        Section {
            ForEach(page.layers.reversed()) { layer in
                let selected = layer.id == model.selectedLayerID
                HStack(spacing: 8) {
                    Image(decorative: layer.source.preview, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                    Text(layer.source.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if layer.source.isVector {
                        Text("SVG")
                            .font(.caption2.bold())
                            .padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 3).fill(.quaternary))
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
                .contentShape(Rectangle())
                .onTapGesture { model.selectedLayerID = selected ? nil : layer.id }
            }

            HStack(spacing: 14) {
                Button { importTarget = .currentPage } label: { Image(systemName: "plus") }
                    .help("Add images to this sheet")
                Group {
                    Button { model.duplicateSelected() } label: { Image(systemName: "plus.square.on.square") }
                        .help("Duplicate (⌘D)")
                    Button { model.rotateSelected(by: 90) } label: { Image(systemName: "rotate.right") }
                        .help("Rotate 90° (⌘R)")
                    Button {
                        if model.croppingLayerID != nil { model.finishCrop() } else { model.beginCrop() }
                    } label: { Image(systemName: "crop") }
                        .help("Crop (C or double-click)")
                    Button { model.reorderSelected(toFront: true) } label: { Image(systemName: "square.3.layers.3d.top.filled") }
                        .help("Bring to front")
                    Button { model.reorderSelected(toFront: false) } label: { Image(systemName: "square.3.layers.3d.bottom.filled") }
                        .help("Send to back")
                    Button(role: .destructive) { model.removeSelectedLayer() } label: { Image(systemName: "trash") }
                        .help("Remove from sheet (⌫)")
                }
                .disabled(model.selectedLayerID == nil)
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Images on this sheet")
        } footer: {
            if page.layers.isEmpty {
                Text("Drag images (photos, PNG, SVG) onto the canvas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.croppingLayerID != nil {
                Text("Drag the edges to crop, or the middle to move the image. Return applies · Esc cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.selectedLayerID == nil {
                Text("Click an image: drag it to move, corners resize, side bars crop (⌥ + corner crops two sides), the top knob rotates. Double-click to slide the image inside its crop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("⌫ remove · C crop · + − size · arrows move (⇧ ×10) · Tab next · Esc deselect")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PrintFooter: View {
    @EnvironmentObject var model: PrintModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isBusy {
                if let p = model.progress {
                    ProgressView(value: p)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            Text(model.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                if let p = model.currentPage { model.printPages([p]) }
            } label: {
                Label("Print Sheet", systemImage: "printer")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy || (model.currentPage?.layers.isEmpty ?? true))

            if model.printablePages.count > 1 {
                Button {
                    model.printPages(model.printablePages)
                } label: {
                    Text("Print All (\(model.printablePages.count))")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(model.isBusy)
            }
        }
        .padding(16)
    }
}
