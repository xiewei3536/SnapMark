import AppKit
import SwiftUI

struct EditorActions {
    var save: () -> Void
    var saveAs: () -> Void
    var copy: () -> Void
    var pin: () -> Void
    var reveal: () -> Void
}

let accentGradient = LinearGradient(
    colors: [Color(nsColor: Brand.accentTop), Color(nsColor: Brand.accentBottom)],
    startPoint: .top, endPoint: .bottom)

// MARK: - Root

struct EditorRootView: View {
    @ObservedObject var state: EditorState
    @ObservedObject private var l10n = L10n.shared
    let actions: EditorActions

    var body: some View {
        VStack(spacing: 0) {
            EditorTopBar(state: state, actions: actions)
            if state.tool == .text || state.inspectedIsText {
                Divider().opacity(0.4)
                TextFormatBar(state: state)
            }
            Divider().opacity(0.6)
            EditorCanvasArea(state: state)
            Divider().opacity(0.6)
            EditorBottomBar(state: state)
        }
        .frame(minWidth: 960, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .id(l10n.revision)
    }
}

// MARK: - Top bar

struct EditorTopBar: View {
    @ObservedObject var state: EditorState
    let actions: EditorActions

    @State private var showColorPopover = false
    @State private var showWidthPopover = false
    @State private var showOCRPopover = false
    @State private var ocrText: String?
    @State private var ocrRunning = false

    private let drawTools: [Tool] = [.select, .pen, .highlighter, .line, .arrow, .rect, .ellipse, .text, .mosaic, .badge, .crop]

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(drawTools) { tool in
                    ToolButton(tool: tool, isActive: state.tool == tool) { state.tool = tool }
                }
            }
            .padding(3)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Divider().frame(height: 20)

            // Color swatch.
            Button { showColorPopover.toggle() } label: {
                Circle()
                    .fill(state.color.color)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("editor.color"))
            .popover(isPresented: $showColorPopover, arrowEdge: .bottom) { ColorPopover(state: state) }

            // Stroke width / font size.
            Button { showWidthPopover.toggle() } label: {
                Image(systemName: "lineweight")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("editor.size"))
            .popover(isPresented: $showWidthPopover, arrowEdge: .bottom) { SizePopover(state: state) }

            if state.tool == .mosaic {
                Picker("", selection: $state.mosaicBlur) {
                    Text(L("editor.pixelate")).tag(false)
                    Text(L("editor.blur")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }

            if state.tool == .crop {
                Button(L("editor.apply_crop")) { state.applyCrop() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Color(nsColor: Brand.accent))
                    .disabled(state.cropRect == nil || (state.cropRect?.width ?? 0) < 8)
                Button(L("editor.cancel_crop")) {
                    state.cropRect = nil
                    state.tool = .select
                }
                .controlSize(.small)
            }

            Divider().frame(height: 20)

            IconButton(symbol: "arrow.uturn.backward", help: L("editor.undo"), disabled: !state.canUndo) { state.undo() }
            IconButton(symbol: "arrow.uturn.forward", help: L("editor.redo"), disabled: !state.canRedo) { state.redo() }

            Spacer(minLength: 8)

            // OCR
            Button { runOCR() } label: {
                HStack(spacing: 5) {
                    if ocrRunning {
                        ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "text.viewfinder").font(.system(size: 12, weight: .semibold))
                    }
                    Text(L("editor.ocr")).font(.system(size: 12, weight: .medium)).fixedSize()
                }
                .padding(.horizontal, 10)
                .frame(height: 27)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(ocrRunning)
            .help(L("editor.ocr_help"))
            .popover(isPresented: $showOCRPopover, arrowEdge: .bottom) { OCRResultView(text: ocrText ?? "") }

            secondaryButton("pin", L("editor.pin"), help: L("editor.pin_help"), action: actions.pin)
            secondaryButton("doc.on.doc", L("editor.copy"), help: L("editor.copy_help") + "  ⌘C", action: actions.copy)

            // Save (primary) + overflow menu sharing one pill.
            HStack(spacing: 0) {
                Button(action: actions.save) {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 12, weight: .semibold))
                        Text(L("editor.save")).font(.system(size: 12, weight: .semibold)).fixedSize()
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 8)
                    .frame(height: 27)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("editor.save_help") + "  ⌘S")

                Rectangle().fill(.white.opacity(0.35)).frame(width: 1, height: 15)

                Menu {
                    Button(L("editor.save_as") + "…") { actions.saveAs() }
                    Button(L("editor.reveal")) { actions.reveal() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 27)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22, height: 27)
                .help(L("editor.more"))
            }
            .foregroundStyle(.white)
            .background(accentGradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: Color(nsColor: Brand.accent).opacity(0.35), radius: 6, y: 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func secondaryButton(_ symbol: String, _ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium)).fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(height: 27)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func runOCR() {
        guard !ocrRunning else { return }
        ocrRunning = true
        let image = state.flatten()
        OCRService.recognize(image: image) { text in
            Task { @MainActor in
                ocrRunning = false
                ocrText = text
                if let text, !text.isEmpty {
                    Clipboard.copy(text: text)
                    showOCRPopover = true
                    state.showStatus(L("toast.ocr_copied"))
                } else {
                    state.showStatus(L("toast.ocr_empty"))
                }
            }
        }
    }
}

struct ToolButton: View {
    let tool: Tool
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 26)
                .background(
                    isActive ? AnyShapeStyle(accentGradient) :
                        (hovering ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(Color.clear)),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .foregroundStyle(isActive ? .white : .primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L(tool.labelKey) + (tool.shortcutKey.map { "  \($0.uppercased())" } ?? ""))
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(help)
    }
}

struct ColorPopover: View {
    @ObservedObject var state: EditorState

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(Array(RGBA.presets.enumerated()), id: \.offset) { _, preset in
                    Button { state.color = preset } label: {
                        Circle()
                            .fill(preset.color)
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
                            .overlay {
                                if state.color == preset {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(preset.r + preset.g + preset.b > 2 ? .black : .white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            ColorPicker(L("editor.custom_color"), selection: Binding(
                get: { state.color.color },
                set: { newValue in
                    let ns = NSColor(newValue).usingColorSpace(.sRGB) ?? .black
                    state.color = RGBA(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: 1)
                }
            ))
            .font(.system(size: 12))
        }
        .padding(12)
    }
}

struct SizePopover: View {
    @ObservedObject var state: EditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.tool == .text {
                Text(L("editor.font_size") + ": \(Int(state.fontSizePt)) pt").font(.system(size: 11))
                Slider(value: $state.fontSizePt, in: 10...72, step: 1).frame(width: 180)
                Text("Aa 文字")
                    .font(.system(size: min(36, state.fontSizePt), weight: .semibold))
                    .foregroundStyle(state.color.color)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Text(L("editor.stroke_width") + ": \(Int(state.lineWidthPt)) pt").font(.system(size: 11))
                Slider(value: $state.lineWidthPt, in: 1...14, step: 1).frame(width: 180)
                Circle()
                    .fill(state.color.color)
                    .frame(width: max(3, state.lineWidthPt * 2), height: max(3, state.lineWidthPt * 2))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
        }
        .padding(12)
    }
}

struct OCRResultView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "text.viewfinder")
                Text(L("editor.ocr_result")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(L("editor.copy")) { Clipboard.copy(text: text) }
                    .controlSize(.small)
            }
            ScrollView {
                Text(text.isEmpty ? L("toast.ocr_empty") : text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 320, height: 180)
            .padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
    }
}

// MARK: - Canvas area

struct EditorCanvasArea: View {
    @ObservedObject var state: EditorState
    @FocusState private var textFieldFocused: Bool
    @State private var gestureActive = false
    @State private var magnifyBase: CGFloat?

    private var pxToView: CGFloat { state.pxToView }

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    canvas
                    textEditingOverlay
                }
                .coordinateSpace(name: "canvas")
                .frame(width: max(1, state.displaySize.width), height: max(1, state.displaySize.height))
                .background(
                    Rectangle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
                )
                // Centered with breathing room; grows the scrollable area when zoomed in.
                .frame(width: max(state.displaySize.width + 48, geo.size.width),
                       height: max(state.displaySize.height + 48, geo.size.height))
            }
            .background(CheckerboardBackground())
            .onAppear {
                state.viewportSize = geo.size
                state.zoomToFit()
            }
            .onChange(of: geo.size) { newSize in
                state.viewportSize = newSize
            }
        }
    }

    private var canvas: some View {
        Canvas(rendersAsynchronously: false) { gc, _ in
            gc.withCGContext { cg in
                cg.saveGState()
                cg.scaleBy(x: pxToView, y: pxToView)
                cg.interpolationQuality = pxToView >= 1 ? .none : .high
                AnnotationRenderer.drawImageInFlippedContext(
                    state.base, rect: CGRect(origin: .zero, size: state.pixelSize), in: cg)
                if state.annotations.contains(where: { $0.kind == .mosaic }) || state.draft?.kind == .mosaic {
                    state.filters.prepare(for: state.base)
                }
                var toDraw = state.annotations
                if let d = state.draft { toDraw.append(d) }
                if let editing = state.editingTextID {
                    toDraw.removeAll { $0.id == editing } // the TextField shows this one
                }
                AnnotationRenderer.render(toDraw, in: cg, imageSize: state.pixelSize,
                                          pixelated: state.filters.pixelated, blurred: state.filters.blurred)
                cg.restoreGState()
            }
            drawSelectionChrome(gc)
            drawCropChrome(gc)
        }
        .frame(width: max(state.displaySize.width, 1), height: max(state.displaySize.height, 1))
        .gesture(dragGesture)
        .simultaneousGesture(doubleTapGesture)
        .simultaneousGesture(magnifyGesture)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if !gestureActive {
                    gestureActive = true
                    state.gestureBegan(at: pixelPoint(value.startLocation))
                }
                state.gestureChanged(to: pixelPoint(value.location),
                                     shiftDown: NSEvent.modifierFlags.contains(.shift))
            }
            .onEnded { value in
                if !gestureActive { // a plain click can end without any .onChanged
                    state.gestureBegan(at: pixelPoint(value.startLocation))
                }
                gestureActive = false
                state.gestureEnded(at: pixelPoint(value.location))
            }
    }

    private var doubleTapGesture: some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .local)
            .onEnded { value in
                guard state.tool == .select else { return }
                let p = pixelPoint(value.location)
                if let id = state.hitTest(p),
                   let a = state.annotations.first(where: { $0.id == id }), a.kind == .text {
                    state.selectedID = nil
                    state.editingTextID = id
                }
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if magnifyBase == nil { magnifyBase = state.zoom }
                state.setZoom((magnifyBase ?? state.zoom) * value)
            }
            .onEnded { _ in magnifyBase = nil }
    }

    private func pixelPoint(_ viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: viewPoint.x / pxToView, y: viewPoint.y / pxToView)
    }

    // Selection dashed bounds + handles (view coordinates → constant on-screen size).
    private func drawSelectionChrome(_ gc: GraphicsContext) {
        guard state.tool == .select, let id = state.selectedID,
              let a = state.annotations.first(where: { $0.id == id }) else { return }
        let b = a.bounds
        let viewRect = CGRect(x: b.minX * pxToView, y: b.minY * pxToView,
                              width: b.width * pxToView, height: b.height * pxToView)
        let path = Path(viewRect)
        gc.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 1.5))
        gc.stroke(path, with: .color(Color(nsColor: Brand.accent)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))

        var handlePts: [CGPoint] = []
        switch a.kind {
        case .line, .arrow:
            handlePts = [a.start, a.end]
        case .rect, .ellipse:
            let r = a.shapeRect
            handlePts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
        case .text:
            let r = a.textBox
            handlePts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
        default:
            break
        }
        for pt in handlePts {
            let v = CGPoint(x: pt.x * pxToView, y: pt.y * pxToView)
            let rect = CGRect(x: v.x - 4.5, y: v.y - 4.5, width: 9, height: 9)
            gc.fill(Path(ellipseIn: rect), with: .color(.white))
            gc.stroke(Path(ellipseIn: rect), with: .color(Color(nsColor: Brand.accent)), style: StrokeStyle(lineWidth: 1.5))
        }
    }

    private func drawCropChrome(_ gc: GraphicsContext) {
        guard state.tool == .crop, let crop = state.cropRect, crop.width > 0, crop.height > 0 else { return }
        let v = CGRect(x: crop.minX * pxToView, y: crop.minY * pxToView,
                       width: crop.width * pxToView, height: crop.height * pxToView)
        var dim = Path()
        dim.addRect(CGRect(origin: .zero, size: state.displaySize))
        dim.addRect(v)
        gc.fill(dim, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
        gc.stroke(Path(v), with: .color(.white), style: StrokeStyle(lineWidth: 1.5))
        var guides = Path()
        for i in 1...2 {
            let x = v.minX + v.width * CGFloat(i) / 3
            let y = v.minY + v.height * CGFloat(i) / 3
            guides.move(to: CGPoint(x: x, y: v.minY)); guides.addLine(to: CGPoint(x: x, y: v.maxY))
            guides.move(to: CGPoint(x: v.minX, y: y)); guides.addLine(to: CGPoint(x: v.maxX, y: y))
        }
        gc.stroke(guides, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 0.5))
        let label = Text("\(Int(crop.width)) × \(Int(crop.height))")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
        gc.draw(label, at: CGPoint(x: v.midX, y: max(10, v.minY - 12)))
    }

    // Live text editor for the annotation being edited, with a move grip and a resize handle.
    @ViewBuilder
    private var textEditingOverlay: some View {
        if let id = state.editingTextID, let a = state.annotations.first(where: { $0.id == id }) {
            let box = a.textBox
            let viewBox = CGRect(x: box.minX * pxToView, y: box.minY * pxToView,
                                 width: box.width * pxToView, height: box.height * pxToView)

            // Plate preview + dashed outline so the box is visible while typing.
            RoundedRectangle(cornerRadius: a.textPadding * pxToView, style: .continuous)
                .fill(a.textStyle.plate ? Color(nsColor: a.plateColor) : Color.black.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: a.textPadding * pxToView, style: .continuous)
                    .strokeBorder(Color(nsColor: Brand.accent), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .frame(width: max(24, viewBox.width), height: max(12, viewBox.height))
                .offset(x: viewBox.minX, y: viewBox.minY)
                .allowsHitTesting(false)

            AnnotationTextEditor(state: state, annotation: a, pxToView: pxToView)
                .fixedSize()
                .offset(x: viewBox.minX, y: viewBox.minY)

            // Move grip (left of the box).
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color(nsColor: Brand.accent), in: Circle())
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .offset(x: viewBox.minX - 24, y: viewBox.minY - 2)
                .help(L("text.grip_help"))
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                        .onChanged { value in
                            let last = gripLast ?? value.startLocation
                            let delta = CGPoint(x: (value.location.x - last.x) / pxToView,
                                                y: (value.location.y - last.y) / pxToView)
                            state.moveText(id: id, by: delta, begin: gripLast == nil)
                            gripLast = value.location
                        }
                        .onEnded { _ in gripLast = nil }
                )

            // Resize handle (bottom-right corner) scales the font.
            Circle()
                .fill(.white)
                .overlay(Circle().strokeBorder(Color(nsColor: Brand.accent), lineWidth: 2))
                .frame(width: 12, height: 12)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .offset(x: viewBox.maxX - 6, y: viewBox.maxY - 6)
                .help(L("text.scale_help"))
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                        .onChanged { value in
                            state.scaleText(id: id, handle: .cornerBR, to: pixelPoint(value.location), begin: !scaling)
                            scaling = true
                        }
                        .onEnded { _ in scaling = false }
                )
        }
    }

    @State private var gripLast: CGPoint?
    @State private var scaling = false
}

struct CheckerboardBackground: View {
    var body: some View {
        Canvas { gc, size in
            let cell: CGFloat = 12
            gc.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .underPageBackgroundColor)))
            let tint = Color.primary.opacity(0.035)
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : cell
                while x < size.width {
                    gc.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(tint))
                    x += cell * 2
                }
                y += cell
                row += 1
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Bottom bar

struct EditorBottomBar: View {
    @ObservedObject var state: EditorState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.tool.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(nsColor: Brand.accent))
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if let status = state.statusMessage {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(status).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: 360)
                .transition(.opacity)
            }

            Spacer()

            HStack(spacing: 4) {
                IconButton(symbol: "minus.magnifyingglass", help: L("editor.zoom_out")) {
                    state.setZoom(state.zoom / 1.25)
                }
                Text("\(Int((state.zoom * 100).rounded()))%")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 44)
                IconButton(symbol: "plus.magnifyingglass", help: L("editor.zoom_in")) {
                    state.setZoom(state.zoom * 1.25)
                }
                Button(L("editor.fit")) { state.zoomToFit() }
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .help(L("menu.zoom_fit") + "  ⌘9")
                Button("1:1") { state.setZoom(1) }
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .help(L("menu.zoom_actual") + "  ⌘0")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .animation(.easeInOut(duration: 0.2), value: state.statusMessage)
    }

    private var hint: String {
        switch state.tool {
        case .select: return L("hint.select")
        case .crop: return L("hint.crop")
        case .text: return L("hint.text")
        case .badge: return L("hint.badge")
        case .line, .arrow, .rect, .ellipse: return L("hint.shape")
        default: return L("hint.draw")
        }
    }
}

// MARK: - Text format bar (font, size, style, alignment, plate/outline/shadow)

struct TextFormatBar: View {
    @ObservedObject var state: EditorState
    @State private var showFonts = false

    private var familyLabel: String {
        guard let family = state.textStyle.fontFamily else { return L("text.system_font") }
        return NSFontManager.shared.localizedName(forFamily: family, face: nil)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "t.square")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: Brand.accent))

            // Font family
            Button { showFonts.toggle() } label: {
                HStack(spacing: 6) {
                    Text(familyLabel)
                        .font(Font(state.textStyle.font(size: 12)))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .frame(width: 170, height: 26)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("text.font"))
            .popover(isPresented: $showFonts, arrowEdge: .bottom) {
                FontPickerPopover(state: state, isPresented: $showFonts)
            }

            // Size
            HStack(spacing: 0) {
                stepButton("minus") { state.adjustFontSize(by: -2) }
                Text("\(Int(state.fontSizePt.rounded()))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .frame(width: 34)
                stepButton("plus") { state.adjustFontSize(by: 2) }
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .help(L("text.size") + "  ⌥⌘↑ / ⌥⌘↓")
            Slider(value: $state.fontSizePt, in: 6...120, step: 1)
                .frame(width: 110)
                .controlSize(.small)

            Divider().frame(height: 18)

            styleToggle("bold", isOn: $state.textStyle.bold, help: L("text.bold"))
            styleToggle("italic", isOn: $state.textStyle.italic, help: L("text.italic"))
            styleToggle("underline", isOn: $state.textStyle.underline, help: L("text.underline"))
            styleToggle("strikethrough", isOn: $state.textStyle.strikethrough, help: L("text.strike"))

            Divider().frame(height: 18)

            alignToggle(.left, "text.alignleft", L("text.align_left"))
            alignToggle(.center, "text.aligncenter", L("text.align_center"))
            alignToggle(.right, "text.alignright", L("text.align_right"))

            Divider().frame(height: 18)

            chip(L("text.plate"), isOn: $state.textStyle.plate, help: L("text.plate_help"))
            chip(L("text.outline"), isOn: $state.textStyle.outline, help: L("text.outline_help"))
            chip(L("text.shadow"), isOn: $state.textStyle.shadow, help: L("text.shadow_help"))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func styleToggle(_ symbol: String, isOn: Binding<Bool>, help: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(isOn.wrappedValue ? AnyShapeStyle(accentGradient) : AnyShapeStyle(Color.primary.opacity(0.06)),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .foregroundStyle(isOn.wrappedValue ? .white : .primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func alignToggle(_ align: TextAlign, _ symbol: String, _ help: String) -> some View {
        let active = state.textStyle.alignment == align
        return Button { state.textStyle.alignment = align } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(active ? AnyShapeStyle(accentGradient) : AnyShapeStyle(Color.primary.opacity(0.06)),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .foregroundStyle(active ? .white : .primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func chip(_ title: String, isOn: Binding<Bool>, help: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(isOn.wrappedValue ? AnyShapeStyle(accentGradient) : AnyShapeStyle(Color.primary.opacity(0.06)),
                            in: Capsule())
                .foregroundStyle(isOn.wrappedValue ? .white : .primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Searchable font list; each family is previewed in its own face.
struct FontPickerPopover: View {
    @ObservedObject var state: EditorState
    @Binding var isPresented: Bool
    @State private var query = ""

    private static let preferred = [
        "PingFang TC", "PingFang SC", "Heiti TC", "Songti TC", "Songti SC", "Kaiti TC", "Kaiti SC",
        "Yuanti TC", "Yuanti SC", "Hiragino Sans", "Helvetica Neue", "Avenir Next", "Futura", "Georgia",
        "Menlo", "Marker Felt", "Chalkboard SE", "American Typewriter", "Noteworthy",
    ]
    private let allFamilies: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    private var common: [String] { Self.preferred.filter { allFamilies.contains($0) } }
    private var filtered: [String] {
        guard !query.isEmpty else { return allFamilies }
        return allFamilies.filter {
            $0.localizedCaseInsensitiveContains(query)
                || NSFontManager.shared.localizedName(forFamily: $0, face: nil).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField(L("text.search_font"), text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    row(nil)
                    if query.isEmpty {
                        header(L("text.common_fonts"))
                        ForEach(common, id: \.self) { row($0) }
                        header(L("text.all_fonts"))
                    }
                    ForEach(filtered, id: \.self) { row($0) }
                }
            }
            .frame(width: 270, height: 330)
        }
        .padding(10)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .padding(.horizontal, 6)
    }

    private func row(_ family: String?) -> some View {
        let selected = state.textStyle.fontFamily == family
        let name = family.map { NSFontManager.shared.localizedName(forFamily: $0, face: nil) } ?? L("text.system_font")
        let preview = family.flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: 14) }
            ?? NSFont.systemFont(ofSize: 14)
        return Button {
            state.textStyle.fontFamily = family
            isPresented = false
        } label: {
            HStack {
                Text(name).font(Font(preview)).lineLimit(1)
                Spacer()
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(nsColor: Brand.accent))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(selected ? Color(nsColor: Brand.accent).opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - In-place text editor (AppKit, so IME, alignment and newlines behave natively)

struct AnnotationTextEditor: NSViewRepresentable {
    let state: EditorState
    let annotation: Annotation
    let pxToView: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(state: state, id: annotation.id) }

    func makeNSView(context: Context) -> EditingTextView {
        let tv = EditingTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.drawsBackground = false
        tv.isFieldEditor = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.string = annotation.text
        apply(to: tv)
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        }
        return tv
    }

    func updateNSView(_ tv: EditingTextView, context: Context) {
        context.coordinator.id = annotation.id
        if tv.string != annotation.text, !tv.hasMarkedText() {
            tv.string = annotation.text
        }
        apply(to: tv)
    }

    private func apply(to tv: EditingTextView) {
        let resolved = annotation.textStyle.resolvedFont(size: max(4, annotation.fontSize * pxToView))
        let font = resolved.font
        let color = annotation.color.nsColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = annotation.textStyle.alignment.ns
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        if resolved.syntheticItalic { attrs[.obliqueness] = 0.22 }
        if annotation.textStyle.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if annotation.textStyle.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let pad = annotation.textPadding * pxToView
        tv.textContainerInset = NSSize(width: pad, height: pad)
        tv.font = font
        tv.textColor = color
        tv.alignment = annotation.textStyle.alignment.ns
        tv.insertionPointColor = color
        tv.typingAttributes = attrs
        if let storage = tv.textStorage, storage.length > 0, !tv.hasMarkedText() {
            storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
        }
        tv.fitContainerToContent()
        tv.invalidateIntrinsicContentSize()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let state: EditorState
        var id: UUID
        init(state: EditorState, id: UUID) { self.state = state; self.id = id }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            state.updateText(id: id, tv.string)
            tv.invalidateIntrinsicContentSize()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                let mods = NSApp.currentEvent?.modifierFlags ?? []
                if mods.contains(.shift) || mods.contains(.option) {
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                } else {
                    state.commitTextEditing()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                state.commitTextEditing()
                return true
            default:
                return false
            }
        }
    }
}

final class EditingTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }

    /// Sizes the container to the longest line so paragraph alignment shows while typing
    /// (an unbounded container would make every line look left-aligned).
    func fitContainerToContent() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        tc.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let natural = lm.usedRect(for: tc).width
        tc.containerSize = NSSize(width: max(24, ceil(natural) + 2), height: CGFloat.greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
    }

    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else { return super.intrinsicContentSize }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).size
        return NSSize(width: max(24, ceil(tc.containerSize.width)) + textContainerInset.width * 2,
                      height: max(ceil(used.height), (font?.pointSize ?? 12) * 1.3) + textContainerInset.height * 2)
    }

    override func didChangeText() {
        super.didChangeText()
        fitContainerToContent()
        invalidateIntrinsicContentSize()
    }
}
