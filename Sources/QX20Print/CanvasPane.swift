import QX20Core
import SwiftUI

enum CanvasStyle: String, CaseIterable, Identifiable {
    case edit, result
    var id: String { rawValue }
    var title: LocalizedStringKey { self == .edit ? "Edit" : "Result" }
}

struct CanvasPane: View {
    @EnvironmentObject var model: PrintModel
    @Binding var importTarget: ImportTarget?
    @AppStorage("canvasStyle") private var style: CanvasStyle = .edit

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let page = model.currentPage {
                    GeometryReader { geo in
                        let avail = CGSize(width: geo.size.width - 56, height: geo.size.height - 56)
                        Group {
                            if style == .edit {
                                CanvasEditor(page: page, available: avail)
                            } else if let rendered = model.renders[page.id] {
                                ResultView(page: rendered, available: avail)
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Preview", systemImage: "printer")
                    } description: {
                        Text("Drag photos to the sidebar (one per sheet)\nor create a sheet and drop images on it.")
                    } actions: {
                        Button("Add Photos…") { importTarget = .newPages }
                    }
                }
            }

            Divider()
            HStack(spacing: 12) {
                Picker("View", selection: $style) {
                    ForEach(CanvasStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Spacer()
                if model.croppingLayerID != nil {
                    Label("Cropping", systemImage: "crop")
                        .font(.callout.bold())
                    Button("Reset") { model.resetCrop() }
                    Button("Cancel") { model.cancelCrop() }
                    Button("Done") { model.finishCrop() }
                        .buttonStyle(.borderedProminent)
                } else if model.currentPage != nil {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button { model.exportPreview() } label: { Image(systemName: "square.and.arrow.down") }
                        .buttonStyle(.borderless)
                        .help("Save the sheet as PNG")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private var caption: String {
        let v = model.paper.visibleRect
        let mm = { (px: CGFloat) in String(format: "%.0f", pxToMM(Int(px))) }
        let hint = style == .edit ? String(localized: "Red: cut off · ") : ""
        return "\(hint)\(model.paper.title) · ≈ \(mm(v.width)) × \(mm(v.height)) mm"
    }
}

// MARK: - Exact print result

struct ResultView: View {
    let page: RenderedPage
    let available: CGSize

    var body: some View {
        let vis = page.visibleRect
        if let cropped = page.image.cropping(to: vis) {
            let s = min(available.width / vis.width, available.height / vis.height)
            Image(decorative: cropped, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: vis.width * s, height: vis.height * s)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        }
    }
}

// MARK: - Editor

struct CanvasEditor: View {
    @EnvironmentObject var model: PrintModel
    let page: Page
    let available: CGSize
    @FocusState private var focused: Bool
    @State private var dropTargeted = false

    var body: some View {
        let paper = model.paper
        let s = max(0.05, min(available.width / CGFloat(paper.width), available.height / CGFloat(paper.height)))
        let size = CGSize(width: CGFloat(paper.width) * s, height: CGFloat(paper.height) * s)

        ZStack(alignment: .topLeading) {
            // Paper + layers (clipped to the canvas)
            ZStack(alignment: .topLeading) {
                Color.white
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.selectedLayerID = nil
                        focused = true
                    }
                ForEach(page.layers) { layer in
                    LayerItem(layer: layer, scale: s, focus: { focused = true })
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)

            BleedShade(visible: paper.visibleRect, scale: s, size: size)
                .allowsHitTesting(false)

            SmartGuides(guides: model.guides, scale: s, size: size)
                .allowsHitTesting(false)

            if model.cutGuides {
                ForEach(page.layers) { layer in
                    Rectangle()
                        .stroke(Color.gray, lineWidth: 0.75)
                        .frame(width: layer.placement.size.width * s, height: layer.placement.size.height * s)
                        .rotationEffect(.degrees(layer.placement.rotation))
                        .position(x: layer.placement.center.x * s, y: layer.placement.center.y * s)
                        .allowsHitTesting(false)
                }
            }

            if let cropping = page.layers.first(where: { $0.id == model.croppingLayerID }) {
                CropOverlay(layer: cropping, scale: s)
            } else if let selected = page.layers.first(where: { $0.id == model.selectedLayerID }) {
                SelectionOverlay(layer: selected, scale: s)
            }

            if page.layers.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.largeTitle)
                    Text("Drop images here")
                }
                .foregroundStyle(.secondary)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
            }

            if dropTargeted {
                Rectangle()
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "canvas")
        .dropDestination(for: URL.self) { urls, location in
            model.addToCurrentPage(urls, at: CGPoint(x: location.x / s, y: location.y / s))
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard model.selectedLayerID != nil, model.croppingLayerID == nil else { return .ignored }
            let step: CGFloat = press.modifiers.contains(.shift) ? 10 : 1
            switch press.key {
            case .leftArrow: model.nudgeSelected(dx: -step, dy: 0)
            case .rightArrow: model.nudgeSelected(dx: step, dy: 0)
            case .upArrow: model.nudgeSelected(dx: 0, dy: -step)
            default: model.nudgeSelected(dx: 0, dy: step)
            }
            return .handled
        }
        .onKeyPress(keys: [.delete, .deleteForward, .escape, .return, .tab]) { press in
            switch press.key {
            case .escape:
                if model.croppingLayerID != nil { model.cancelCrop() } else { model.selectedLayerID = nil }
            case .return:
                guard model.croppingLayerID != nil else { return .ignored }
                model.finishCrop()
            case .tab:
                guard model.croppingLayerID == nil else { return .handled }
                model.selectAdjacentLayer(forward: !press.modifiers.contains(.shift))
            default:  // backspace / forward delete
                guard model.croppingLayerID == nil, model.selectedLayerID != nil else { return .ignored }
                model.removeSelectedLayer()
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "cC+=-_")) { press in
            guard model.selectedLayerID != nil, press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
            switch press.characters {
            case "c", "C":
                if model.croppingLayerID != nil { model.finishCrop() } else { model.beginCrop() }
            case "+", "=":
                model.scaleSelected(by: 1.05)
            default:
                model.scaleSelected(by: 1 / 1.05)
            }
            return .handled
        }
    }
}

/// Magenta alignment lines shown while dragging (like Canva).
struct SmartGuides: View {
    let guides: [PrintModel.SnapGuide]
    let scale: CGFloat
    let size: CGSize
    static let color = Color(red: 1, green: 0.18, blue: 0.62)

    var body: some View {
        Path { path in
            for g in guides {
                switch g.axis {
                case .vertical:
                    path.move(to: CGPoint(x: g.position * scale, y: g.from * scale))
                    path.addLine(to: CGPoint(x: g.position * scale, y: g.to * scale))
                case .horizontal:
                    path.move(to: CGPoint(x: g.from * scale, y: g.position * scale))
                    path.addLine(to: CGPoint(x: g.to * scale, y: g.position * scale))
                }
            }
        }
        .stroke(Self.color, lineWidth: 1)
        .frame(width: size.width, height: size.height)
    }
}

/// Red shading over what borderless printing cuts off, plus the dashed cut line.
struct BleedShade: View {
    let visible: CGRect
    let scale: CGFloat
    let size: CGSize

    var body: some View {
        let v = CGRect(x: visible.minX * scale, y: visible.minY * scale,
                       width: visible.width * scale, height: visible.height * scale)
        ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRect(v)
            }
            .fill(Color.red.opacity(0.22), style: FillStyle(eoFill: true))
            Path { $0.addRect(v) }
                .stroke(Color.red.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .frame(width: size.width, height: size.height)
    }
}

struct LayerItem: View {
    @EnvironmentObject var model: PrintModel
    let layer: Layer
    let scale: CGFloat
    let focus: () -> Void
    @State private var startCenter: CGPoint?

    var body: some View {
        let p = layer.placement
        Image(decorative: ImagePrep.crop(layer.source.preview, to: p.crop) ?? layer.source.preview, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: p.fillsFrame ? .fill : .fit)
            .frame(width: p.size.width * scale, height: p.size.height * scale)
            .clipped()
            .contentShape(Rectangle())
            .rotationEffect(.degrees(p.rotation))
            .position(x: p.center.x * scale, y: p.center.y * scale)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
                    .onChanged { value in
                        if startCenter == nil {
                            startCenter = p.center
                            model.selectedLayerID = layer.id
                            model.beginInteraction()
                            focus()
                        }
                        guard let start = startCenter else { return }
                        let c = CGPoint(x: start.x + value.translation.width / scale,
                                        y: start.y + value.translation.height / scale)
                        // ⌘ while dragging: place freely, no snapping
                        if NSEvent.modifierFlags.contains(.command) {
                            model.clearGuides()
                            model.moveLayer(layer.id, to: c)
                        } else {
                            model.moveLayer(layer.id, to: model.snapMove(layer.id, to: c, tolerance: 6 / scale))
                        }
                    }
                    .onEnded { _ in
                        startCenter = nil
                        model.clearGuides()
                        model.endInteraction()
                    }
            )
            .simultaneousGesture(TapGesture().onEnded {
                model.selectedLayerID = layer.id
                focus()
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                model.selectedLayerID = layer.id
                model.beginCrop()
                focus()
            })
    }
}

/// Selection like Photoshop / GIMP transform: corner squares scale from the
/// opposite corner, edge bars crop that side (⌥ + corner crops two sides),
/// the small knob above rotates.
struct SelectionOverlay: View {
    @EnvironmentObject var model: PrintModel
    let layer: Layer
    let scale: CGFloat
    @State private var drag: DragStart?

    enum Mode { case scale, crop([CropEdge]), rotate }

    struct DragStart {
        let placement: LayerPlacement
        let fullCenter: CGPoint
        let anchor: CGPoint
        let distance: CGFloat
        let mode: Mode
    }

    struct Corner { let sx: CGFloat; let sy: CGFloat; let cropEdges: [CropEdge] }
    struct Side { let sx: CGFloat; let sy: CGFloat; let edge: CropEdge }
    static let corners = [
        Corner(sx: -1, sy: -1, cropEdges: [.minX, .minY]), Corner(sx: 1, sy: -1, cropEdges: [.maxX, .minY]),
        Corner(sx: 1, sy: 1, cropEdges: [.maxX, .maxY]), Corner(sx: -1, sy: 1, cropEdges: [.minX, .maxY]),
    ]
    static let sides = [
        Side(sx: 0, sy: -1, edge: .minY), Side(sx: 1, sy: 0, edge: .maxX),
        Side(sx: 0, sy: 1, edge: .maxY), Side(sx: -1, sy: 0, edge: .minX),
    ]

    private var p: LayerPlacement { layer.placement }
    private var radians: CGFloat { CGFloat(p.rotation * Double.pi / 180) }

    /// Canvas-pixel point at local offset (dx, dy) from the layer centre.
    private func point(_ dx: CGFloat, _ dy: CGFloat, in pl: LayerPlacement? = nil) -> CGPoint {
        let pl = pl ?? p
        let r = CGFloat(pl.rotation * Double.pi / 180)
        return CGPoint(x: pl.center.x + dx * cos(r) - dy * sin(r), y: pl.center.y + dx * sin(r) + dy * cos(r))
    }

    private var isCropping: Bool { if case .crop = drag?.mode { return true } else { return false } }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isCropping, let d = drag { cropGhost(d) }
            outline
            rotationKnob
            ForEach(0..<Self.sides.count, id: \.self) { i in sideHandle(Self.sides[i]) }
            ForEach(0..<Self.corners.count, id: \.self) { i in cornerHandle(Self.corners[i]) }
        }
    }

    private var outline: some View {
        Rectangle()
            .stroke(Color.accentColor, lineWidth: 1)
            .frame(width: p.size.width * scale, height: p.size.height * scale)
            .rotationEffect(.degrees(p.rotation))
            .position(x: p.center.x * scale, y: p.center.y * scale)
            .allowsHitTesting(false)
    }

    /// The whole image, dimmed, while an edge is being cropped.
    private func cropGhost(_ d: DragStart) -> some View {
        let full = CropMath.fullSize(d.placement)
        let kept: CGImage = ImagePrep.crop(layer.source.preview, to: p.crop) ?? layer.source.preview
        return ZStack(alignment: .topLeading) {
            Image(decorative: layer.source.preview, scale: 1)
                .resizable()
                .frame(width: full.width * scale, height: full.height * scale)
                .opacity(0.3)
                .rotationEffect(.degrees(p.rotation))
                .position(x: d.fullCenter.x * scale, y: d.fullCenter.y * scale)
            Image(decorative: kept, scale: 1)
                .resizable()
                .frame(width: p.size.width * scale, height: p.size.height * scale)
                .rotationEffect(.degrees(p.rotation))
                .position(x: p.center.x * scale, y: p.center.y * scale)
        }
        .allowsHitTesting(false)
    }

    private var rotationKnob: some View {
        let h = p.size.height * scale
        let top = point(0, -p.size.height / 2)
        let gap: CGFloat = 20 / scale
        let knob = point(0, -p.size.height / 2 - gap)
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: top.x * scale, y: top.y * scale))
                path.addLine(to: CGPoint(x: knob.x * scale, y: knob.y * scale))
            }
            .stroke(Color.accentColor, lineWidth: 1)
            .allowsHitTesting(false)
            .opacity(h > 30 ? 1 : 0)

            TransformHandle(kind: .knob)
                .position(x: knob.x * scale, y: knob.y * scale)
                .help("Drag to rotate (snaps every 45°)")
                .gesture(
                    DragGesture(coordinateSpace: .named("canvas"))
                        .onChanged { v in
                            if drag == nil { begin(.rotate) }
                            let c = CGPoint(x: p.center.x * scale, y: p.center.y * scale)
                            var a = atan2(v.location.y - c.y, v.location.x - c.x) * 180 / .pi + 90
                            let snap = (a / 45).rounded() * 45
                            if abs(a - snap) < 4 { a = snap }
                            model.rotateLayer(layer.id, to: a)
                        }
                        .onEnded { _ in end() }
                )
        }
    }

    private func cornerHandle(_ corner: Corner) -> some View {
        let at = point(corner.sx * p.size.width / 2, corner.sy * p.size.height / 2)
        return TransformHandle(kind: .corner)
            .rotationEffect(.degrees(p.rotation))
            .position(x: at.x * scale, y: at.y * scale)
            .help("Drag to resize · ⌥ drag to crop")
            .gesture(
                DragGesture(coordinateSpace: .named("canvas"))
                    .onChanged { v in
                        if drag == nil {
                            if NSEvent.modifierFlags.contains(.option) {
                                begin(.crop(corner.cropEdges))
                            } else {
                                let anchor = point(-corner.sx * p.size.width / 2, -corner.sy * p.size.height / 2)
                                begin(.scale, anchor: anchor, distance: hypot(at.x - anchor.x, at.y - anchor.y))
                            }
                        }
                        update(to: CGPoint(x: v.location.x / scale, y: v.location.y / scale))
                    }
                    .onEnded { _ in end() }
            )
    }

    private func sideHandle(_ side: Side) -> some View {
        let at = point(side.sx * p.size.width / 2, side.sy * p.size.height / 2)
        return TransformHandle(kind: side.sx == 0 ? .horizontalBar : .verticalBar)
            .rotationEffect(.degrees(p.rotation))
            .position(x: at.x * scale, y: at.y * scale)
            .help("Drag to crop this side")
            .gesture(
                DragGesture(coordinateSpace: .named("canvas"))
                    .onChanged { v in
                        if drag == nil { begin(.crop([side.edge])) }
                        update(to: CGPoint(x: v.location.x / scale, y: v.location.y / scale))
                    }
                    .onEnded { _ in end() }
            )
    }

    private func begin(_ mode: Mode, anchor: CGPoint = .zero, distance: CGFloat = 1) {
        model.beginInteraction()
        if case .crop = mode { model.prepareForCrop(layer.id) }
        let start = model.placement(of: layer.id) ?? p
        drag = DragStart(placement: start, fullCenter: PrintModel.fullImageCenter(start),
                         anchor: anchor, distance: max(distance, 1), mode: mode)
    }

    private func update(to location: CGPoint) {
        guard let d = drag else { return }
        switch d.mode {
        case .scale:
            let sp = d.placement
            let minSide = min(sp.size.width, sp.size.height)
            let f = max(12 / max(minSide, 1), hypot(location.x - d.anchor.x, location.y - d.anchor.y) / d.distance)
            let center = CGPoint(x: d.anchor.x + (sp.center.x - d.anchor.x) * f,
                                 y: d.anchor.y + (sp.center.y - d.anchor.y) * f)
            model.setFrame(layer.id, center: center,
                           size: CGSize(width: sp.size.width * f, height: sp.size.height * f))
        case .crop(let edges):
            let r = CropMath.drag(edges, to: location, from: d.placement, fullCenter: d.fullCenter)
            model.setCrop(layer.id, crop: r.crop, center: r.center, size: r.size)
        case .rotate:
            break
        }
    }

    private func end() {
        drag = nil
        model.endInteraction()
    }
}

/// Small, discreet transform handles (Photoshop / GIMP style).
struct TransformHandle: View {
    enum Kind { case corner, horizontalBar, verticalBar, knob }
    let kind: Kind

    var body: some View {
        shape
            .shadow(color: .black.opacity(0.25), radius: 0.5)
            .frame(width: 18, height: 18)   // larger hit area than the mark
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var shape: some View {
        switch kind {
        case .corner:
            Rectangle()
                .fill(Color.white)
                .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                .frame(width: 7, height: 7)
        case .horizontalBar:
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 1).stroke(Color.accentColor, lineWidth: 1))
                .frame(width: 14, height: 4)
        case .verticalBar:
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 1).stroke(Color.accentColor, lineWidth: 1))
                .frame(width: 4, height: 14)
        case .knob:
            Circle()
                .fill(Color.white)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 1))
                .frame(width: 7, height: 7)
        }
    }
}

// MARK: - Crop

/// Crop editor: the whole image dimmed, the kept part bright, 8 handles to
/// move the edges and dragging inside to slide the image under the frame.
struct CropOverlay: View {
    @EnvironmentObject var model: PrintModel
    let layer: Layer
    let scale: CGFloat
    @State private var start: (placement: LayerPlacement, fullCenter: CGPoint)?

    struct HandleSpec {
        let x: CGFloat
        let y: CGFloat
        let edges: [CropEdge]
    }
    static let handles: [HandleSpec] = [
        HandleSpec(x: -0.5, y: -0.5, edges: [.minX, .minY]), HandleSpec(x: 0, y: -0.5, edges: [.minY]),
        HandleSpec(x: 0.5, y: -0.5, edges: [.maxX, .minY]), HandleSpec(x: 0.5, y: 0, edges: [.maxX]),
        HandleSpec(x: 0.5, y: 0.5, edges: [.maxX, .maxY]), HandleSpec(x: 0, y: 0.5, edges: [.maxY]),
        HandleSpec(x: -0.5, y: 0.5, edges: [.minX, .maxY]), HandleSpec(x: -0.5, y: 0, edges: [.minX]),
    ]
    private var placement: LayerPlacement { layer.placement }
    private var radians: CGFloat { CGFloat(placement.rotation * Double.pi / 180) }
    private var fullSize: CGSize {
        CGSize(width: placement.size.width / placement.crop.width,
               height: placement.size.height / placement.crop.height)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            dimmedImage
            keptImage
            panArea
            ForEach(0..<Self.handles.count, id: \.self) { i in
                handle(Self.handles[i])
            }
        }
        .help("Drag the edges to crop · drag inside to move the image · Return applies, Esc cancels")
    }

    private var dimmedImage: some View {
        let c = PrintModel.fullImageCenter(placement)
        let full = fullSize
        return Image(decorative: layer.source.preview, scale: 1)
            .resizable()
            .frame(width: full.width * scale, height: full.height * scale)
            .opacity(0.35)
            .rotationEffect(.degrees(placement.rotation))
            .position(x: c.x * scale, y: c.y * scale)
            .allowsHitTesting(false)
    }

    private var keptImage: some View {
        let img: CGImage = ImagePrep.crop(layer.source.preview, to: placement.crop) ?? layer.source.preview
        return Image(decorative: img, scale: 1)
            .resizable()
            .frame(width: placement.size.width * scale, height: placement.size.height * scale)
            .overlay(CropGrid())
            .overlay(Rectangle().stroke(Color.white, lineWidth: 2))
            .rotationEffect(.degrees(placement.rotation))
            .position(x: placement.center.x * scale, y: placement.center.y * scale)
            .allowsHitTesting(false)
    }

    /// Drag inside: slide the image under the crop frame.
    private var panArea: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: placement.size.width * scale, height: placement.size.height * scale)
            .rotationEffect(.degrees(placement.rotation))
            .position(x: placement.center.x * scale, y: placement.center.y * scale)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                    .onChanged { v in pan(by: v.translation) }
                    .onEnded { _ in start = nil }
            )
    }

    private func handle(_ h: HandleSpec) -> some View {
        let r = radians
        let x: CGFloat = h.x * placement.size.width * scale
        let y: CGFloat = h.y * placement.size.height * scale
        let ox: CGFloat = x * cos(r) - y * sin(r)
        let oy: CGFloat = x * sin(r) + y * cos(r)
        let kind: TransformHandle.Kind = h.edges.count == 2 ? .corner : (h.x == 0 ? .horizontalBar : .verticalBar)
        return TransformHandle(kind: kind)
            .rotationEffect(.degrees(placement.rotation))
            .position(x: placement.center.x * scale + ox, y: placement.center.y * scale + oy)
            .gesture(
                DragGesture(coordinateSpace: .named("canvas"))
                    .onChanged { v in drag(edges: h.edges, to: v.location) }
                    .onEnded { _ in start = nil }
            )
    }

    private func beginIfNeeded() -> (placement: LayerPlacement, fullCenter: CGPoint) {
        if let start { return start }
        let st = (placement, PrintModel.fullImageCenter(placement))
        start = st
        return st
    }

    private func pan(by translation: CGSize) {
        let st = beginIfNeeded()
        let sp = st.placement
        let r = CGFloat(sp.rotation * Double.pi / 180)
        let fullW: CGFloat = sp.size.width / sp.crop.width
        let fullH: CGFloat = sp.size.height / sp.crop.height
        // Pointer delta in the image's own (unrotated) axes
        let tx: CGFloat = translation.width / scale
        let ty: CGFloat = translation.height / scale
        let lx: CGFloat = tx * cos(r) + ty * sin(r)
        let ly: CGFloat = -tx * sin(r) + ty * cos(r)
        var c = sp.crop
        c.origin.x = min(max(0, c.origin.x - lx / fullW), 1 - c.width)
        c.origin.y = min(max(0, c.origin.y - ly / fullH), 1 - c.height)
        model.setCrop(layer.id, crop: c, center: sp.center, size: sp.size)
    }

    private func drag(edges: [CropEdge], to location: CGPoint) {
        let st = beginIfNeeded()
        let r = CropMath.drag(edges, to: CGPoint(x: location.x / scale, y: location.y / scale),
                              from: st.placement, fullCenter: st.fullCenter)
        model.setCrop(layer.id, crop: r.crop, center: r.center, size: r.size)
    }
}

/// Rule-of-thirds lines inside the crop frame.
struct CropGrid: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                for f in [1.0 / 3, 2.0 / 3] {
                    p.move(to: CGPoint(x: g.size.width * f, y: 0))
                    p.addLine(to: CGPoint(x: g.size.width * f, y: g.size.height))
                    p.move(to: CGPoint(x: 0, y: g.size.height * f))
                    p.addLine(to: CGPoint(x: g.size.width, y: g.size.height * f))
                }
            }
            .stroke(Color.white.opacity(0.6), lineWidth: 0.5)
        }
    }
}

// MARK: - Crop math (shared by the selection and the crop mode)

enum CropEdge { case minX, maxX, minY, maxY }

enum CropMath {
    static let minCrop: CGFloat = 0.04

    /// Size of the whole (uncropped) image for a placement, in canvas pixels.
    static func fullSize(_ p: LayerPlacement) -> CGSize {
        CGSize(width: p.size.width / p.crop.width, height: p.size.height / p.crop.height)
    }

    /// Move crop `edges` to `location` (canvas pixels), keeping the whole image
    /// fixed on the page. Returns the new crop, frame centre and frame size.
    static func drag(_ edges: [CropEdge], to location: CGPoint, from sp: LayerPlacement,
                     fullCenter fc: CGPoint) -> (crop: CGRect, center: CGPoint, size: CGSize) {
        let r = CGFloat(sp.rotation * Double.pi / 180)
        let full = fullSize(sp)
        // Pointer in the image's own axes, normalized 0...1
        let px: CGFloat = location.x - fc.x
        let py: CGFloat = location.y - fc.y
        let lx: CGFloat = px * cos(r) + py * sin(r)
        let ly: CGFloat = -px * sin(r) + py * cos(r)
        let u: CGFloat = lx / full.width + 0.5
        let v: CGFloat = ly / full.height + 0.5

        var minX = sp.crop.minX, maxX = sp.crop.maxX, minY = sp.crop.minY, maxY = sp.crop.maxY
        for e in edges {
            switch e {
            case .minX: minX = min(max(0, u), maxX - minCrop)
            case .maxX: maxX = max(min(1, u), minX + minCrop)
            case .minY: minY = min(max(0, v), maxY - minCrop)
            case .maxY: maxY = max(min(1, v), minY + minCrop)
            }
        }
        let crop = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let size = CGSize(width: crop.width * full.width, height: crop.height * full.height)
        let dx: CGFloat = (crop.midX - 0.5) * full.width
        let dy: CGFloat = (crop.midY - 0.5) * full.height
        let center = CGPoint(x: fc.x + dx * cos(r) - dy * sin(r), y: fc.y + dx * sin(r) + dy * cos(r))
        return (crop, center, size)
    }
}
