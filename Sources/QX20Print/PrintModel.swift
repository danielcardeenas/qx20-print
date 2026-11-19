import AppKit
import CoreLocation
import CoreGraphics
import Foundation
import QX20Core

struct Layer: Identifiable {
    let id = UUID()
    let source: LayerSource
    var placement: LayerPlacement
}

/// One sheet of paper: one or more images (layers), auto-arranged or placed by hand.
struct Page: Identifiable {
    let id = UUID()
    var layers: [Layer] = []
    /// Re-arranged automatically whenever settings change, until the user moves something.
    var autoLayout = true
    var grid: GridPreset = .auto

    var name: String {
        guard let first = layers.first else { return String(localized: "Empty sheet") }
        let base = (first.source.name as NSString).deletingPathExtension
        return layers.count > 1 ? "\(base) + \(layers.count - 1)" : base
    }
}

struct LogLine: Identifiable {
    let id = UUID()
    let time: Date
    let text: String
}

@MainActor
final class PrintModel: ObservableObject {
    // Pages & selection
    @Published var pages: [Page] = [] { didSet { scheduleSave() } }
    @Published var selectedPageID: Page.ID? {
        didSet {
            if oldValue != selectedPageID { selectedLayerID = nil }
            scheduleSave()
        }
    }
    @Published private(set) var isRestoring = false
    private var saveWork: DispatchWorkItem?
    @Published var selectedLayerID: Layer.ID? {
        didSet { if croppingLayerID != nil && croppingLayerID != selectedLayerID { finishCrop() } }
    }
    /// Layer whose crop is being edited.
    @Published private(set) var croppingLayerID: Layer.ID?

    // Settings (persisted)
    @Published var paper: Paper { didSet { paperChanged(from: oldValue) } }
    @Published var mode: FitMode { didSet { settingsChanged() } }
    @Published var borderMM: Double { didSet { settingsChanged() } }
    @Published var gapMM: Double { didSet { settingsChanged() } }
    @Published var allowRotation: Bool { didSet { settingsChanged() } }
    @Published var cutGuides: Bool { didSet { settingsChanged(relayout: false) } }
    @Published var ssid: String { didSet { save(); if ssid != oldValue { lastCheckOK = nil } } }
    @Published var returnToNetwork: Bool { didSet { save() } }
    /// Optional override of the square media code (empty = default 17).
    @Published var squareSizeCode: String { didSet { save() } }

    // Rendered pages (exact print output) for thumbnails and the "Result" view
    @Published private(set) var renders: [Page.ID: RenderedPage] = [:]
    private var dirty = Set<Page.ID>()
    private var renderScheduled = false

    // Undo
    private var undoStack: [[Page]] = []
    private var redoStack: [[Page]] = []
    private var interacting = false
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // Job state
    @Published private(set) var isBusy = false
    @Published private(set) var statusText = String(localized: "Ready")
    @Published private(set) var progress: Double?
    @Published private(set) var printerSummary: String?
    @Published private(set) var log: [LogLine] = []
    @Published var showSettings = false
    /// The "connect a printer" assistant.
    @Published var showWizard = false
    @Published private(set) var locationStatus: CLAuthorizationStatus = WiFi.shared.locationStatus
    /// Result of the last "Check printer": nil while unknown.
    @Published private(set) var lastCheckOK: Bool?
    @Published private(set) var lastCheckError: String?

    /// Location Services on for the whole Mac (checked in the background).
    @Published private(set) var locationServicesOn = true
    var hasLocationAccess: Bool { locationServicesOn && WiFi.isGranted(locationStatus) }
    private var activationObserver: NSObjectProtocol?

    /// Re-check Location Services and the app's permission.
    func refreshLocation() {
        WiFi.shared.refreshLocationStatus()
        DispatchQueue.global(qos: .userInitiated).async {
            let on = WiFi.locationServicesEnabled
            DispatchQueue.main.async {
                self.locationServicesOn = on
                self.logLocation()
            }
        }
    }

    /// macOS's location service can't read (and so can't verify) apps inside
    /// the user's home folder, so it never grants them Location access.
    var runningFromHomeFolder: Bool {
        Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/")
    }

    /// Copy the app to /Applications and relaunch it from there.
    func moveToApplications() {
        let fm = FileManager.default
        let dest = URL(fileURLWithPath: "/Applications").appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
        do {
            if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
            try fm.copyItem(at: Bundle.main.bundleURL, to: dest)
        } catch {
            alertMessage = String(localized: "Couldn’t copy QX20 Print to Applications: \(error.localizedDescription)")
            return
        }
        saveNow()
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: dest, configuration: config) { _, error in
            DispatchQueue.main.async {
                if let error {
                    self.alertMessage = error.localizedDescription
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private var lastLocationLog = ""

    /// Diagnostic line in the log when the permission state changes.
    private func logLocation() {
        let names: [Int32: String] = [0: "notDetermined", 1: "restricted", 2: "denied",
                                      3: "authorizedAlways", 4: "authorizedWhenInUse"]
        let raw = locationStatus.rawValue
        let line = "Location: status=\(raw) (\(names[raw] ?? "?")), services=\(locationServicesOn ? "on" : "off"), inHomeFolder=\(runningFromHomeFolder)"
        guard line != lastLocationLog else { return }
        lastLocationLog = line
        appendLog(line)
        NSLog("QX20 Print: %@", line)
    }
    @Published var alertMessage: String?

    private let defaults = UserDefaults.standard

    init() {
        paper = Paper(rawValue: defaults.string(forKey: "paper") ?? "") ?? .card
        mode = FitMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .fit
        borderMM = defaults.object(forKey: "borderMM") as? Double ?? 0
        gapMM = defaults.object(forKey: "gapMM") as? Double ?? 1.5
        allowRotation = defaults.object(forKey: "allowRotation") as? Bool ?? true
        cutGuides = defaults.object(forKey: "cutGuides") as? Bool ?? false
        ssid = defaults.string(forKey: "ssid") ?? ""
        returnToNetwork = defaults.object(forKey: "returnToNetwork") as? Bool ?? true
        squareSizeCode = defaults.string(forKey: "squareSizeCode") ?? ""
        restore()
        WiFi.shared.onAuthorizationChange = { [weak self] status in
            DispatchQueue.main.async {
                self?.locationStatus = status
                self?.logLocation()
            }
        }
        refreshLocation()
        // Coming back from System Settings: pick up permission changes
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLocation() }
        }
        // First launch: walk the user through connecting the printer
        if password.isEmpty { showWizard = true }
    }

    // MARK: Persistence

    private func scheduleSave() {
        guard !isRestoring else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            PageStore.save(self.pages, selected: self.selectedPageID)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Save immediately (on quit).
    func saveNow() {
        saveWork?.cancel()
        guard !isRestoring else { return }
        PageStore.save(pages, selected: selectedPageID)
    }

    private func restore() {
        isRestoring = true
        let launchedAt = Date()
        Task.detached(priority: .userInitiated) {
            let state = PageStore.load(launchedAt: launchedAt)
            await MainActor.run {
                defer { self.isRestoring = false }
                guard let state else { return }
                var restored: [Page] = []
                var missing = 0
                for (saved, sources) in state.pages {
                    var page = Page()
                    page.autoLayout = saved.autoLayout
                    page.grid = saved.grid > 0 ? .count(saved.grid) : .auto
                    for (l, src) in zip(saved.layers, sources) {
                        guard let src else { missing += 1; continue }
                        page.layers.append(Layer(source: src, placement: LayerPlacement(
                            center: CGPoint(x: l.cx, y: l.cy), size: CGSize(width: l.w, height: l.h),
                            rotation: l.rotation, fillsFrame: l.fills,
                            crop: l.crop.flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
                                ?? LayerPlacement.fullCrop)))
                    }
                    restored.append(page)
                }
                let added = self.pages
                self.pages = restored + added
                if added.isEmpty, let i = state.selected, restored.indices.contains(i) {
                    self.selectedPageID = restored[i].id
                } else if self.selectedPageID == nil {
                    self.selectedPageID = self.pages.first?.id
                }
                // Settings may have changed while the app was closed
                for i in self.pages.indices { self.relayout(i) }
                self.markAllDirty()
                if missing > 0 { self.appendLog(String(localized: "Couldn’t restore \(missing) saved image(s).")) }
                if !restored.isEmpty { self.appendLog(String(localized: "Restored \(restored.count) saved sheet(s).")) }
                NSLog("QX20 Print: restored %d page(s), %d missing image(s)", restored.count, missing)
            }
        }
    }
    private func save() {
        defaults.set(paper.rawValue, forKey: "paper")
        defaults.set(mode.rawValue, forKey: "mode")
        defaults.set(borderMM, forKey: "borderMM")
        defaults.set(gapMM, forKey: "gapMM")
        defaults.set(allowRotation, forKey: "allowRotation")
        defaults.set(cutGuides, forKey: "cutGuides")
        defaults.set(ssid, forKey: "ssid")
        defaults.set(returnToNetwork, forKey: "returnToNetwork")
        defaults.set(squareSizeCode, forKey: "squareSizeCode")
    }

    /// The printer's Wi-Fi key (printed inside the ink cassette cover). Kept in
    /// the app's preferences: it only opens the printer's own local network.
    var password: String {
        get { defaults.string(forKey: "printerPassword") ?? "" }
        set { defaults.set(newValue, forKey: "printerPassword"); lastCheckOK = nil; objectWillChange.send() }
    }

    var sizeCode: Int? {
        switch paper {
        case .card: return paper.defaultSizeCode
        case .square: return Int(squareSizeCode.trimmingCharacters(in: .whitespaces)) ?? paper.defaultSizeCode
        }
    }

    // MARK: Current page / layer

    var currentIndex: Int? {
        if let id = selectedPageID, let i = pages.firstIndex(where: { $0.id == id }) { return i }
        return pages.isEmpty ? nil : 0
    }

    var currentPage: Page? { currentIndex.map { pages[$0] } }

    var selectedLayer: Layer? {
        currentPage?.layers.first { $0.id == selectedLayerID }
    }

    var printablePages: [Page] { pages.filter { !$0.layers.isEmpty } }

    private func layerIndex(_ id: Layer.ID) -> (Int, Int)? {
        guard let p = currentIndex, let l = pages[p].layers.firstIndex(where: { $0.id == id }) else { return nil }
        return (p, l)
    }

    // MARK: Undo

    private func checkpoint() {
        undoStack.append(pages)
        if undoStack.count > 80 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(pages)
        pages = previous
        afterHistoryChange()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(pages)
        pages = next
        afterHistoryChange()
    }

    private func afterHistoryChange() {
        if let id = selectedPageID, !pages.contains(where: { $0.id == id }) { selectedPageID = pages.first?.id }
        if let id = selectedLayerID, currentPage?.layers.contains(where: { $0.id == id }) != true { selectedLayerID = nil }
        markAllDirty()
    }

    /// Call when a drag starts / ends so the whole gesture is one undo step.
    func beginInteraction() {
        guard !interacting else { return }
        interacting = true
        checkpoint()
    }

    func endInteraction() {
        interacting = false
        if let p = currentPage { markDirty(p.id) }
    }

    // MARK: Layout & rendering

    private func settingsChanged(relayout: Bool = true) {
        save()
        if relayout { for i in pages.indices { self.relayout(i) } }
        markAllDirty()
    }

    private func paperChanged(from old: Paper) {
        save()
        // Keep hand-placed layers centred horizontally on the new canvas
        let dx = CGFloat(paper.width - old.width) / 2
        for i in pages.indices where !pages[i].autoLayout {
            for j in pages[i].layers.indices { pages[i].layers[j].placement.center.x += dx }
        }
        for i in pages.indices { relayout(i) }
        markAllDirty()
    }

    private func relayout(_ i: Int) {
        guard pages[i].autoLayout, !pages[i].layers.isEmpty else { return }
        let page = pages[i]
        let single = page.layers.count == 1 && page.grid == .auto
        let area = Layout.area(paper: paper, mode: mode, borderMM: borderMM, singleImage: single)
        let aspects = page.layers.map { $0.placement.croppedAspect($0.source.aspect) }
        let placements = Layout.arrange(aspects: aspects, in: area,
                                        gap: Double(mmToPx(gapMM)), mode: mode,
                                        grid: page.grid, allowRotation: allowRotation)
        for (j, p) in placements.enumerated() {
            var placement = p
            placement.crop = pages[i].layers[j].placement.crop  // keep the user's crop
            pages[i].layers[j].placement = placement
        }
    }

    private func markDirty(_ id: Page.ID) {
        dirty.insert(id)
        scheduleRender()
    }

    private func markAllDirty() {
        dirty.formUnion(pages.map(\.id))
        scheduleRender()
    }

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in self?.renderDirty() }
    }

    private func renderDirty() {
        renderScheduled = false
        let ids = dirty
        dirty.removeAll()
        let live = Set(pages.map(\.id))
        renders = renders.filter { live.contains($0.key) }
        for page in pages where ids.contains(page.id) {
            renders[page.id] = try? render(page)
        }
    }

    private func render(_ page: Page) throws -> RenderedPage {
        try ImagePrep.renderComposition(page.layers.map { CompositionLayer(source: $0.source, placement: $0.placement) },
                                        paper: paper, cutGuides: cutGuides)
    }

    // MARK: Pages

    /// Each image becomes its own page.
    func addAsNewPages(_ urls: [URL]) {
        load(urls) { [weak self] sources in
            guard let self, !sources.isEmpty else { return }
            self.checkpoint()
            var first: Page.ID?
            for src in sources {
                var page = Page()
                page.layers = [Layer(source: src, placement: LayerPlacement(center: .zero, size: .zero))]
                self.pages.append(page)
                self.relayout(self.pages.count - 1)
                self.markDirty(page.id)
                first = first ?? page.id
            }
            if self.selectedPageID == nil || sources.count == 1 { self.selectedPageID = first }
        }
    }

    /// Add images as layers of the current page, optionally dropped at `point` (canvas pixels).
    func addToCurrentPage(_ urls: [URL], at point: CGPoint? = nil) {
        load(urls) { [weak self] sources in
            guard let self, !sources.isEmpty else { return }
            self.checkpoint()
            if self.currentIndex == nil {
                self.pages.append(Page())
                self.selectedPageID = self.pages.last?.id
            }
            guard let i = self.currentIndex else { return }
            var lastID: Layer.ID?
            for (k, src) in sources.enumerated() {
                let placement = self.manualPlacement(for: src, at: point.map { CGPoint(x: $0.x + CGFloat(k) * 24, y: $0.y + CGFloat(k) * 24) })
                let layer = Layer(source: src, placement: placement)
                self.pages[i].layers.append(layer)
                lastID = layer.id
            }
            // An empty page or a still-automatic one keeps arranging itself
            if self.pages[i].autoLayout { self.relayout(i) }
            self.selectedLayerID = lastID
            self.markDirty(self.pages[i].id)
        }
    }

    private func manualPlacement(for src: LayerSource, at point: CGPoint?) -> LayerPlacement {
        let vis = paper.visibleRect
        let target = min(vis.width, vis.height) * 0.45
        let size = src.aspect >= 1
            ? CGSize(width: target, height: target / src.aspect)
            : CGSize(width: target * src.aspect, height: target)
        let c = point ?? CGPoint(x: vis.midX, y: vis.midY)
        return LayerPlacement(center: c, size: size)
    }

    private func load(_ urls: [URL], completion: @escaping @MainActor ([LayerSource]) -> Void) {
        Task.detached(priority: .userInitiated) {
            var sources: [LayerSource] = []
            var failed: [String] = []
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                // Keep a copy in the app's library so the sheet survives the original moving
                if let copy = try? PageStore.importFile(url),
                   let s = try? LayerSource.load(copy, name: url.lastPathComponent) {
                    sources.append(s)
                } else {
                    failed.append(url.lastPathComponent)
                }
            }
            let loaded = sources, errors = failed
            await MainActor.run {
                for f in errors { self.appendLog(String(localized: "Couldn’t open \(f)")) }
                completion(loaded)
            }
        }
    }

    func newEmptyPage() {
        checkpoint()
        let page = Page()
        pages.append(page)
        selectedPageID = page.id
    }

    func duplicatePage(_ id: Page.ID) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        var copy = Page()
        copy.layers = pages[i].layers.map { Layer(source: $0.source, placement: $0.placement) }
        copy.autoLayout = pages[i].autoLayout
        copy.grid = pages[i].grid
        pages.insert(copy, at: i + 1)
        selectedPageID = copy.id
        markDirty(copy.id)
    }

    func removePage(_ id: Page.ID) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        pages.remove(at: i)
        if selectedPageID == id { selectedPageID = pages.isEmpty ? nil : pages[min(i, pages.count - 1)].id }
    }

    func removeAllPages() {
        checkpoint()
        pages.removeAll()
        selectedPageID = nil
        renders.removeAll()
    }

    func setGrid(_ grid: GridPreset) {
        guard let i = currentIndex, pages[i].grid != grid else { return }
        checkpoint()
        pages[i].grid = grid
        pages[i].autoLayout = true
        relayout(i)
        markDirty(pages[i].id)
    }

    func autoArrange() {
        guard let i = currentIndex else { return }
        checkpoint()
        pages[i].autoLayout = true
        relayout(i)
        markDirty(pages[i].id)
    }

    /// Repeat the page's images until every grid cell is used (sticker sheets).
    func fillWithCopies() {
        guard let i = currentIndex, let n = pages[i].grid.cellCount else { return }
        let originals = pages[i].layers
        guard !originals.isEmpty, originals.count < n else { return }
        checkpoint()
        var k = 0
        while pages[i].layers.count < n {
            let o = originals[k % originals.count]
            pages[i].layers.append(Layer(source: o.source, placement: o.placement))
            k += 1
        }
        pages[i].autoLayout = true
        relayout(i)
        markDirty(pages[i].id)
    }

    // MARK: Layers

    private func editLayer(_ id: Layer.ID, _ change: (inout LayerPlacement) -> Void) {
        guard let (p, l) = layerIndex(id) else { return }
        if !interacting { checkpoint() }
        change(&pages[p].layers[l].placement)
        pages[p].autoLayout = false
        if !interacting { markDirty(pages[p].id) }
    }

    func moveLayer(_ id: Layer.ID, to center: CGPoint) { editLayer(id) { $0.center = center } }

    func setFrame(_ id: Layer.ID, center: CGPoint, size: CGSize) {
        editLayer(id) {
            $0.center = center
            $0.size = size
        }
    }

    func placement(of id: Layer.ID) -> LayerPlacement? {
        layerIndex(id).map { pages[$0.0].layers[$0.1].placement }
    }

    func resizeLayer(_ id: Layer.ID, to size: CGSize) {
        editLayer(id) { $0.size = CGSize(width: max(size.width, 12), height: max(size.height, 12)) }
    }

    func rotateLayer(_ id: Layer.ID, to degrees: Double) {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        editLayer(id) { $0.rotation = d }
    }

    func rotateSelected(by degrees: Double) {
        guard let layer = selectedLayer else { return }
        rotateLayer(layer.id, to: layer.placement.rotation + degrees)
    }

    func nudgeSelected(dx: CGFloat, dy: CGFloat) {
        guard let layer = selectedLayer else { return }
        moveLayer(layer.id, to: CGPoint(x: layer.placement.center.x + dx, y: layer.placement.center.y + dy))
    }

    func scaleSelected(by factor: CGFloat) {
        guard let layer = selectedLayer, croppingLayerID == nil else { return }
        let s = layer.placement.size
        resizeLayer(layer.id, to: CGSize(width: s.width * factor, height: s.height * factor))
    }

    /// Select the next (or previous) image on the page, wrapping around.
    func selectAdjacentLayer(forward: Bool) {
        guard let layers = currentPage?.layers, !layers.isEmpty else { return }
        guard let id = selectedLayerID, let i = layers.firstIndex(where: { $0.id == id }) else {
            selectedLayerID = (forward ? layers.last : layers.first)?.id
            return
        }
        let n = layers.count
        selectedLayerID = layers[(i + (forward ? -1 : 1) + n) % n].id
    }

    // MARK: Crop

    /// Start editing the selected image's crop. Filled frames are converted so
    /// the frame shows exactly the cropped image.
    func beginCrop() {
        guard croppingLayerID == nil, let id = selectedLayerID, layerIndex(id) != nil else { return }
        beginInteraction()
        prepareForCrop(id)
        croppingLayerID = id
    }

    /// Before editing a crop: a filled frame becomes an explicit crop of what
    /// is visible, so the frame shows exactly the cropped image.
    /// Call inside an interaction (no undo checkpoint of its own).
    func prepareForCrop(_ id: Layer.ID) {
        guard let (p, l) = layerIndex(id) else { return }
        var placement = pages[p].layers[l].placement
        if placement.fillsFrame {
            let a = placement.croppedAspect(pages[p].layers[l].source.aspect)
            let f = Double(placement.size.width / placement.size.height)
            var c = placement.crop
            if a > f {
                let keep = CGFloat(f / a)
                c.origin.x += c.width * (1 - keep) / 2
                c.size.width *= keep
            } else {
                let keep = CGFloat(a / f)
                c.origin.y += c.height * (1 - keep) / 2
                c.size.height *= keep
            }
            placement.crop = c
            placement.fillsFrame = false
            pages[p].layers[l].placement = placement
        }
        pages[p].autoLayout = false
    }

    func finishCrop() {
        guard croppingLayerID != nil else { return }
        croppingLayerID = nil
        endInteraction()
    }

    func cancelCrop() {
        guard croppingLayerID != nil else { return }
        croppingLayerID = nil
        interacting = false
        undo()
    }

    /// Update crop + frame together while dragging crop handles.
    func setCrop(_ id: Layer.ID, crop: CGRect, center: CGPoint, size: CGSize) {
        editLayer(id) {
            $0.crop = crop
            $0.center = center
            $0.size = size
        }
    }

    /// Show the whole image again, keeping it where it is on the page.
    func resetCrop() {
        guard let layer = selectedLayer else { return }
        let p = layer.placement
        let full = CGSize(width: p.size.width / p.crop.width, height: p.size.height / p.crop.height)
        let center = Self.fullImageCenter(p)
        if croppingLayerID == nil { beginInteraction() }
        setCrop(layer.id, crop: LayerPlacement.fullCrop, center: center, size: full)
        if croppingLayerID == nil { endInteraction() }
    }

    /// Centre of the uncropped image for a placement (canvas pixels).
    static func fullImageCenter(_ p: LayerPlacement) -> CGPoint {
        let full = CGSize(width: p.size.width / p.crop.width, height: p.size.height / p.crop.height)
        let dx = (p.crop.midX - 0.5) * full.width, dy = (p.crop.midY - 0.5) * full.height
        let r = p.rotation * .pi / 180
        return CGPoint(x: p.center.x - (dx * cos(r) - dy * sin(r)),
                       y: p.center.y - (dx * sin(r) + dy * cos(r)))
    }

    func duplicateSelected() {
        guard let (p, l) = selectedLayerID.flatMap(layerIndex) else { return }
        checkpoint()
        let o = pages[p].layers[l]
        var placement = o.placement
        placement.center.x += 24
        placement.center.y += 24
        let copy = Layer(source: o.source, placement: placement)
        pages[p].layers.insert(copy, at: l + 1)
        if pages[p].autoLayout { relayout(p) }
        selectedLayerID = copy.id
        markDirty(pages[p].id)
    }

    func removeSelectedLayer() {
        guard let (p, l) = selectedLayerID.flatMap(layerIndex) else { return }
        checkpoint()
        pages[p].layers.remove(at: l)
        if pages[p].autoLayout { relayout(p) }
        selectedLayerID = nil
        markDirty(pages[p].id)
    }

    /// Move the selected layer up (towards the front) or down in the stack.
    func reorderSelected(toFront: Bool) {
        guard let (p, l) = selectedLayerID.flatMap(layerIndex) else { return }
        let target = toFront ? pages[p].layers.count - 1 : 0
        guard l != target else { return }
        checkpoint()
        let layer = pages[p].layers.remove(at: l)
        pages[p].layers.insert(layer, at: target)
        markDirty(pages[p].id)
    }

    // MARK: Smart guides

    /// Alignment line shown while dragging (canvas pixels).
    struct SnapGuide: Hashable {
        enum Axis { case vertical, horizontal }
        let axis: Axis
        /// x for vertical lines, y for horizontal ones
        let position: CGFloat
        /// Extent along the line
        let from: CGFloat
        let to: CGFloat
    }

    @Published private(set) var guides: [SnapGuide] = []

    private struct SnapTarget {
        let value: CGFloat
        let from: CGFloat
        let to: CGFloat
    }

    /// Axis-aligned box of a (possibly rotated) placement.
    private static func box(_ p: LayerPlacement) -> CGRect {
        let b = p.boundingSize
        return CGRect(x: p.center.x - b.width / 2, y: p.center.y - b.height / 2, width: b.width, height: b.height)
    }

    /// Snap a dragged layer's edges / centre to the page, the cut line and the
    /// other images on the sheet, and publish the guide lines to draw.
    func snapMove(_ id: Layer.ID, to proposed: CGPoint, tolerance: CGFloat) -> CGPoint {
        guard let page = currentPage, let layer = page.layers.first(where: { $0.id == id }) else { return proposed }
        var moving = layer.placement
        moving.center = proposed
        let box = Self.box(moving)
        let W = CGFloat(paper.width), H = CGFloat(paper.height)
        let v = paper.visibleRect

        var xs = [SnapTarget(value: 0, from: 0, to: H), SnapTarget(value: W / 2, from: 0, to: H), SnapTarget(value: W, from: 0, to: H),
                  SnapTarget(value: v.minX, from: 0, to: H), SnapTarget(value: v.maxX, from: 0, to: H)]
        var ys = [SnapTarget(value: 0, from: 0, to: W), SnapTarget(value: H / 2, from: 0, to: W), SnapTarget(value: H, from: 0, to: W),
                  SnapTarget(value: v.minY, from: 0, to: W), SnapTarget(value: v.maxY, from: 0, to: W)]
        for other in page.layers where other.id != id {
            let o = Self.box(other.placement)
            for x in [o.minX, o.midX, o.maxX] { xs.append(SnapTarget(value: x, from: o.minY, to: o.maxY)) }
            for y in [o.minY, o.midY, o.maxY] { ys.append(SnapTarget(value: y, from: o.minX, to: o.maxX)) }
        }

        // Best correction per axis: any of the moving box's 3 lines to any target
        func best(_ lines: [CGFloat], _ targets: [SnapTarget]) -> CGFloat? {
            var bestDelta: CGFloat?
            for l in lines {
                for t in targets {
                    let d = t.value - l
                    if abs(d) <= tolerance, abs(d) < abs(bestDelta ?? .infinity) { bestDelta = d }
                }
            }
            return bestDelta
        }
        let dx = best([box.minX, box.midX, box.maxX], xs) ?? 0
        let dy = best([box.minY, box.midY, box.maxY], ys) ?? 0
        let snapped = box.offsetBy(dx: dx, dy: dy)

        // Guides for every line that now coincides with a target
        var found = Set<SnapGuide>()
        for l in [snapped.minX, snapped.midX, snapped.maxX] {
            for t in xs where abs(t.value - l) < 0.5 {
                found.insert(SnapGuide(axis: .vertical, position: t.value,
                                       from: min(t.from, snapped.minY), to: max(t.to, snapped.maxY)))
            }
        }
        for l in [snapped.minY, snapped.midY, snapped.maxY] {
            for t in ys where abs(t.value - l) < 0.5 {
                found.insert(SnapGuide(axis: .horizontal, position: t.value,
                                       from: min(t.from, snapped.minX), to: max(t.to, snapped.maxX)))
            }
        }
        guides = Array(found)
        return CGPoint(x: proposed.x + dx, y: proposed.y + dy)
    }

    func clearGuides() {
        if !guides.isEmpty { guides = [] }
    }

    func exportPreview() {
        guard let page = currentPage, let rendered = try? render(page) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = page.name + "-qx20.png"
        if panel.runModal() == .OK, let url = panel.url {
            try? ImagePrep.writePNG(rendered.image, to: url)
        }
    }

    // MARK: Log

    func appendLog(_ text: String) {
        log.append(LogLine(time: Date(), text: text))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    func clearLog() { log.removeAll() }

    // MARK: Printing

    private func makeOptions() -> PrintOptions? {
        guard let sizeCode else {
            alertMessage = String(localized: "The media code for square paper isn’t known yet. You can try one in Settings › Advanced.")
            return nil
        }
        let pass = password
        guard !pass.isEmpty else {
            alertMessage = String(localized: "Enter the printer key in the Printer section. It’s printed inside the ink cassette cover.")
            return nil
        }
        var options = PrintOptions(settings: PrintSettings(paper: paper, mode: mode, borderMM: borderMM),
                                   sizeCode: sizeCode, ssid: ssid, password: pass)
        options.returnToNetwork = returnToNetwork
        return options
    }

    private func handle(_ event: JobEvent) {
        switch event {
        case .log(let s): appendLog(s)
        case .status(let s, let p):
            statusText = s
            if let p { progress = p }
        case .itemStarted(let i, let total, let name):
            statusText = String(localized: "Printing \(i + 1) of \(total): \(name)")
            progress = 0.02
        case .itemFinished:
            progress = nil
        }
    }

    private func printItem(for page: Page) -> PrintItem {
        let layers = page.layers.map { CompositionLayer(source: $0.source, placement: $0.placement) }
        let paper = self.paper, guides = self.cutGuides
        return PrintItem(name: page.name) {
            try ImagePrep.renderComposition(layers, paper: paper, cutGuides: guides)
        }
    }

    func printPages(_ pages: [Page]) {
        let pages = pages.filter { !$0.layers.isEmpty }
        guard !isBusy, !pages.isEmpty, let options = makeOptions() else { return }
        WiFi.shared.requestLocationAccess()
        isBusy = true
        progress = nil
        let items = pages.map(printItem(for:))
        let onEvent: (JobEvent) -> Void = { [weak self] ev in
            DispatchQueue.main.async { self?.handle(ev) }
        }
        Thread.detachNewThread { [weak self] in
            var message: String
            var ok = false
            do {
                let failed = try PrintJob.run(items, options: options, onEvent: onEvent)
                ok = failed == 0
                message = ok
                    ? (items.count == 1 ? String(localized: "Print finished") : String(localized: "\(items.count) prints finished"))
                    : String(localized: "\(failed) of \(items.count) failed (see the log)")
            } catch {
                message = error.localizedDescription
                onEvent(.log("Error: \(message)"))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.progress = nil
                self.statusText = message
                if ok {
                    NSSound(named: "Glass")?.play()
                } else {
                    self.alertMessage = message
                }
            }
        }
    }

    /// Join the printer, read its status and come back. `showAlert` is off when
    /// the assistant shows the result itself.
    func checkPrinter(showAlert: Bool = true) {
        guard !isBusy else { return }
        let pass = password
        guard !pass.isEmpty else {
            alertMessage = String(localized: "Enter the printer key in the Printer section. It’s printed inside the ink cassette cover.")
            return
        }
        lastCheckOK = nil
        lastCheckError = nil
        WiFi.shared.requestLocationAccess()
        var options = PrintOptions(settings: PrintSettings(), sizeCode: 18, ssid: ssid, password: pass)
        options.returnToNetwork = returnToNetwork
        isBusy = true
        statusText = String(localized: "Checking the printer…")
        let onEvent: (JobEvent) -> Void = { [weak self] ev in
            DispatchQueue.main.async { self?.handle(ev) }
        }
        Thread.detachNewThread { [weak self] in
            let result: Result<(String, PrinterStatus), Error> = Result {
                try PrintJob.checkStatus(options: options, onEvent: onEvent)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                switch result {
                case .success(let (device, status)):
                    let model = device.components(separatedBy: ";")
                        .first { $0.hasPrefix("MDL:") }?.replacingOccurrences(of: "MDL:", with: "") ?? "QX20"
                    self.printerSummary = status.error == 0 ? String(localized: "\(model) · no errors") : String(localized: "\(model) · error \(status.error)")
                    self.statusText = String(localized: "Printer ready")
                    self.lastCheckOK = true
                    self.appendLog(device)
                    self.appendLog(status.summary)
                case .failure(let error):
                    self.statusText = error.localizedDescription
                    self.appendLog("Error: \(error.localizedDescription)")
                    self.lastCheckOK = false
                    self.lastCheckError = error.localizedDescription
                    if showAlert { self.alertMessage = error.localizedDescription }
                }
            }
        }
    }
}
