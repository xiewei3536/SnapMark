import AppKit
import SwiftUI

/// All model state for one editor window.
@MainActor
final class EditorState: ObservableObject {
    struct Snapshot {
        var base: CGImage
        var annotations: [Annotation]
        var badgeCounter: Int
    }

    @Published private(set) var base: CGImage
    let scale: CGFloat
    var originalURL: URL?

    @Published var annotations: [Annotation] = []
    @Published var draft: Annotation?
    @Published var selectedID: UUID? { didSet { if selectedID != oldValue { syncInspectorFromSelection() } } }
    @Published var editingTextID: UUID? { didSet { if editingTextID != oldValue { syncInspectorFromSelection() } } }
    @Published var tool: Tool = .arrow {
        didSet {
            if tool != .select { selectedID = nil }
            if tool != .crop { cropRect = nil }
            commitTextEditing()
        }
    }

    // Inspector values. They describe the *next* annotation, and — when something is selected
    // or a text is being edited — they also apply live to that annotation.
    @Published var color: RGBA = RGBA.presets[0] {
        didSet { if color != oldValue { applyToInspected { $0.color = color } } }
    }
    @Published var lineWidthPt: CGFloat = 4 {
        didSet { if lineWidthPt != oldValue { applyToInspected(excluding: [.text]) { $0.lineWidth = lineWidthPx } } }
    }
    @Published var fontSizePt: CGFloat = 22 {
        didSet { if fontSizePt != oldValue { applyToInspected(only: [.text]) { $0.fontSize = fontSizePx } } }
    }
    @Published var textStyle = TextStyle() {
        didSet { if textStyle != oldValue { applyToInspected(only: [.text]) { $0.textStyle = textStyle } } }
    }
    @Published var mosaicBlur = false
    @Published var zoom: CGFloat = 1
    @Published var cropRect: CGRect?

    /// Transient feedback shown in the status bar ("Copied", "Saved …"). Auto-clears.
    @Published private(set) var statusMessage: String?
    private var statusClearWork: DispatchWorkItem?

    var badgeCounter = 1
    let filters = FilteredImageCache()
    var viewportSize: CGSize = .zero

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    // Dirty tracking: what was last written to disk (or the pristine capture).
    private var savedAnnotations: [Annotation] = []
    private var savedBase: CGImage

    var isDirty: Bool { annotations != savedAnnotations || base !== savedBase }

    // Gesture bookkeeping.
    private enum GestureMode {
        case none
        case drawing
        case movingAnnotation(id: UUID, last: CGPoint)
        case resizingAnnotation(id: UUID, handle: ShapeHandle, anchor: CGPoint)
        case scalingText(id: UUID, handle: ShapeHandle)
        case croppingNew(start: CGPoint)
    }
    private var gestureMode: GestureMode = .none
    private var gestureStart: CGPoint = .zero
    private var pushedUndoThisGesture = false

    /// `start`/`end` are line endpoints; the corner cases are visual rect corners (anchor = opposite corner).
    enum ShapeHandle { case start, end, cornerTL, cornerTR, cornerBL, cornerBR }

    init(image: CapturedImage, originalURL: URL?) {
        self.base = image.cgImage
        self.savedBase = image.cgImage
        self.scale = image.scale
        self.originalURL = originalURL
    }

    // MARK: Derived geometry

    var pixelSize: CGSize { CGSize(width: base.width, height: base.height) }
    var pointSize: CGSize { CGSize(width: CGFloat(base.width) / scale, height: CGFloat(base.height) / scale) }
    /// View points per image pixel at the current zoom.
    var pxToView: CGFloat { zoom / scale }
    var displaySize: CGSize { CGSize(width: pixelSize.width * pxToView, height: pixelSize.height * pxToView) }

    var lineWidthPx: CGFloat { lineWidthPt * scale }
    var fontSizePx: CGFloat { fontSizePt * scale }

    func fitZoom() -> CGFloat {
        guard viewportSize.width > 40, viewportSize.height > 40 else { return 1 }
        let fit = min((viewportSize.width - 48) / pointSize.width,
                      (viewportSize.height - 48) / pointSize.height)
        return min(1, fit)
    }

    func zoomToFit() { zoom = fitZoom() }

    func setZoom(_ z: CGFloat) { zoom = min(8, max(0.05, z)) }

    // MARK: Status

    func showStatus(_ text: String, duration: TimeInterval = 4) {
        statusClearWork?.cancel()
        statusMessage = text
        let work = DispatchWorkItem { [weak self] in
            withAnimation { self?.statusMessage = nil }
        }
        statusClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func markSaved() {
        savedAnnotations = annotations
        savedBase = base
    }

    // MARK: Inspector ↔ selection

    /// The annotation the inspector controls: the text being edited, else the selection.
    var inspectedID: UUID? { editingTextID ?? selectedID }
    var inspected: Annotation? { inspectedID.flatMap { id in annotations.first { $0.id == id } } }
    var inspectedIsText: Bool { inspected?.kind == .text }

    private var syncingInspector = false
    private var lastInspectorUndo = Date.distantPast

    private func applyToInspected(only: Set<Annotation.Kind>? = nil, excluding: Set<Annotation.Kind> = [],
                                  _ mutate: (inout Annotation) -> Void) {
        guard !syncingInspector, let id = inspectedID,
              let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        let kind = annotations[idx].kind
        if let only, !only.contains(kind) { return }
        if excluding.contains(kind) { return }
        // Slider drags produce many changes; one undo step per burst.
        if Date().timeIntervalSince(lastInspectorUndo) > 1.2 { pushUndo() }
        lastInspectorUndo = Date()
        mutate(&annotations[idx])
    }

    /// Mirrors the selected/edited annotation's attributes into the inspector controls.
    private func syncInspectorFromSelection() {
        guard let a = inspected else { return }
        syncingInspector = true
        color = a.color
        switch a.kind {
        case .text:
            fontSizePt = a.fontSize / scale
            textStyle = a.textStyle
        default:
            lineWidthPt = a.lineWidth / scale
        }
        syncingInspector = false
    }

    // MARK: Text editing operations

    func adjustFontSize(by delta: CGFloat) {
        fontSizePt = min(200, max(6, fontSizePt + delta))
    }

    func updateText(id: UUID, _ text: String) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }), annotations[idx].text != text else { return }
        annotations[idx].text = text
    }

    /// Moves a text annotation by a pixel delta (used by the grip while editing).
    func moveText(id: UUID, by delta: CGPoint, begin: Bool) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        if begin { pushUndo() }
        annotations[idx].translate(by: delta)
        let box = annotations[idx].textBox
        annotations[idx].start.x = min(max(-box.width + 20, annotations[idx].start.x), pixelSize.width - 20)
        annotations[idx].start.y = min(max(-box.height + 20, annotations[idx].start.y), pixelSize.height - 20)
    }

    /// Scales a text annotation by dragging one of its corners; the opposite corner stays put.
    func scaleText(id: UUID, handle: ShapeHandle, to p: CGPoint, begin: Bool) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        if begin {
            pushUndo()
            let box = annotations[idx].textBox
            textScaleAnchor = Self.oppositeCorner(of: handle, in: box)
            textScaleStartSize = annotations[idx].fontSize
            textScaleStartDistance = max(1, hypot(p.x - textScaleAnchor.x, p.y - textScaleAnchor.y))
        }
        let factor = hypot(p.x - textScaleAnchor.x, p.y - textScaleAnchor.y) / textScaleStartDistance
        let newSize = min(400 * scale, max(6 * scale, textScaleStartSize * factor))
        annotations[idx].fontSize = newSize
        let box = annotations[idx].measuredTextSize()
        switch handle {
        case .cornerBR, .end: annotations[idx].start = textScaleAnchor
        case .cornerTL, .start: annotations[idx].start = CGPoint(x: textScaleAnchor.x - box.width, y: textScaleAnchor.y - box.height)
        case .cornerTR: annotations[idx].start = CGPoint(x: textScaleAnchor.x, y: textScaleAnchor.y - box.height)
        case .cornerBL: annotations[idx].start = CGPoint(x: textScaleAnchor.x - box.width, y: textScaleAnchor.y)
        }
        if inspectedID == id {
            syncingInspector = true
            fontSizePt = newSize / scale
            syncingInspector = false
        }
    }

    private var textScaleAnchor: CGPoint = .zero
    private var textScaleStartSize: CGFloat = 1
    private var textScaleStartDistance: CGFloat = 1

    private static func oppositeCorner(of handle: ShapeHandle, in box: CGRect) -> CGPoint {
        switch handle {
        case .cornerTL, .start: return CGPoint(x: box.maxX, y: box.maxY)
        case .cornerTR: return CGPoint(x: box.minX, y: box.maxY)
        case .cornerBL: return CGPoint(x: box.maxX, y: box.minY)
        case .cornerBR, .end: return CGPoint(x: box.minX, y: box.minY)
        }
    }

    // MARK: Undo / redo

    private func snapshot() -> Snapshot {
        Snapshot(base: base, annotations: annotations, badgeCounter: badgeCounter)
    }

    func pushUndo() {
        undoStack.append(snapshot())
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        commitTextEditing()
        guard let snap = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        restore(snap)
    }

    func redo() {
        guard let snap = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        restore(snap)
    }

    private func restore(_ snap: Snapshot) {
        base = snap.base
        annotations = snap.annotations
        badgeCounter = snap.badgeCounter
        selectedID = nil
        editingTextID = nil
        draft = nil
    }

    // MARK: Gestures (all points in image pixel coordinates)

    func gestureBegan(at p: CGPoint) {
        gestureStart = p
        pushedUndoThisGesture = false
        commitTextEditing()

        switch tool {
        case .select:
            if let id = selectedID, let a = annotations.first(where: { $0.id == id }),
               let handle = handleAt(p, for: a) {
                if a.kind == .text {
                    scaleText(id: id, handle: handle, to: p, begin: true)
                    pushedUndoThisGesture = true
                    gestureMode = .scalingText(id: id, handle: handle)
                    return
                }
                pushUndoOnce()
                let r = a.shapeRect
                let anchor: CGPoint
                switch handle {
                case .cornerTL: anchor = CGPoint(x: r.maxX, y: r.maxY)
                case .cornerTR: anchor = CGPoint(x: r.minX, y: r.maxY)
                case .cornerBL: anchor = CGPoint(x: r.maxX, y: r.minY)
                case .cornerBR: anchor = CGPoint(x: r.minX, y: r.minY)
                case .start: anchor = a.end
                case .end: anchor = a.start
                }
                gestureMode = .resizingAnnotation(id: id, handle: handle, anchor: anchor)
                return
            }
            if let id = hitTest(p) {
                selectedID = id
                gestureMode = .movingAnnotation(id: id, last: p)
            } else {
                selectedID = nil
                gestureMode = .none
            }
        case .crop:
            gestureMode = .croppingNew(start: p)
            cropRect = CGRect(origin: p, size: .zero)
        case .text, .badge:
            gestureMode = .none // handled on tap in gestureEnded
        case .pen, .highlighter, .mosaic:
            pushUndoOnce()
            var a = Annotation(kind: tool == .pen ? .pen : (tool == .highlighter ? .highlighter : .mosaic))
            a.color = color
            a.lineWidth = lineWidthPx
            a.points = [p]
            a.mosaicBlur = mosaicBlur
            if tool == .mosaic { filters.prepare(for: base) }
            draft = a
            gestureMode = .drawing
        case .line, .arrow, .rect, .ellipse:
            pushUndoOnce()
            var a = Annotation(kind: tool == .line ? .line : tool == .arrow ? .arrow : tool == .rect ? .rect : .ellipse)
            a.color = color
            a.lineWidth = lineWidthPx
            a.start = p
            a.end = p
            draft = a
            gestureMode = .drawing
        }
    }

    func gestureChanged(to p: CGPoint, shiftDown: Bool) {
        switch gestureMode {
        case .drawing:
            guard var a = draft else { return }
            switch a.kind {
            case .pen, .highlighter, .mosaic:
                if let last = a.points.last, hypot(p.x - last.x, p.y - last.y) < 1.5 { return }
                a.points.append(p)
            default:
                a.end = shiftDown ? constrained(from: a.start, to: p, kind: a.kind) : p
            }
            draft = a
        case .movingAnnotation(let id, let last):
            guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
            pushUndoOnce()
            annotations[idx].translate(by: CGPoint(x: p.x - last.x, y: p.y - last.y))
            gestureMode = .movingAnnotation(id: id, last: p)
        case .resizingAnnotation(let id, let handle, let anchor):
            guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
            var a = annotations[idx]
            switch handle {
            case .start: a.start = p
            case .end: a.end = p
            case .cornerTL, .cornerTR, .cornerBL, .cornerBR:
                a.start = anchor
                a.end = shiftDown ? constrained(from: anchor, to: p, kind: a.kind) : p
            }
            annotations[idx] = a
        case .scalingText(let id, let handle):
            scaleText(id: id, handle: handle, to: p, begin: false)
        case .croppingNew(let start):
            cropRect = CGRect(corner: start, corner: clampToImage(p))
                .intersection(CGRect(origin: .zero, size: pixelSize))
        case .none:
            break
        }
    }

    func gestureEnded(at p: CGPoint) {
        defer { gestureMode = .none }
        let wasTap = hypot(p.x - gestureStart.x, p.y - gestureStart.y) < 3 * scale

        switch tool {
        case .text where wasTap:
            // Tap on existing text edits it; otherwise create a new label here.
            if let existing = annotations.last(where: { $0.kind == .text && $0.bounds.contains(p) }) {
                selectedID = nil
                editingTextID = existing.id
                return
            }
            pushUndoOnce()
            var a = Annotation(kind: .text)
            a.color = color
            a.fontSize = fontSizePx
            a.textStyle = textStyle
            a.start = CGPoint(x: p.x, y: max(0, p.y - a.fontSize / 2))
            annotations.append(a)
            editingTextID = a.id
            selectedID = nil
            return
        case .badge where wasTap:
            pushUndoOnce()
            var a = Annotation(kind: .badge)
            a.color = color
            a.lineWidth = lineWidthPx
            a.badgeNumber = badgeCounter
            a.start = p
            badgeCounter += 1
            annotations.append(a)
            return
        case .select where wasTap:
            return
        case .crop where wasTap:
            cropRect = nil
            return
        default:
            break
        }

        if case .drawing = gestureMode, let a = draft {
            draft = nil
            let tooSmall: Bool
            switch a.kind {
            case .pen, .highlighter, .mosaic: tooSmall = a.points.count < 2
            default: tooSmall = hypot(a.end.x - a.start.x, a.end.y - a.start.y) < 3
            }
            if !tooSmall {
                annotations.append(a)
            } else if pushedUndoThisGesture {
                _ = undoStack.popLast()
            }
        }
    }

    private func pushUndoOnce() {
        guard !pushedUndoThisGesture else { return }
        pushUndo()
        pushedUndoThisGesture = true
    }

    private func constrained(from start: CGPoint, to p: CGPoint, kind: Annotation.Kind) -> CGPoint {
        let dx = p.x - start.x, dy = p.y - start.y
        switch kind {
        case .line, .arrow:
            // Snap to 45° increments.
            let angle = atan2(dy, dx)
            let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            return CGPoint(x: start.x + cos(snapped) * len, y: start.y + sin(snapped) * len)
        default:
            // Square / circle.
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        }
    }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), pixelSize.width), y: min(max(0, p.y), pixelSize.height))
    }

    // MARK: Hit testing

    /// Tolerance in image pixels that corresponds to ~7 screen points at the current zoom.
    private var hitTolerancePx: CGFloat { 7 * scale / max(zoom, 0.2) }

    func hitTest(_ p: CGPoint) -> UUID? {
        // Pass 1: precise (strokes, outlines, glyph boxes) — topmost first.
        for a in annotations.reversed() where a.hits(p, tolerance: hitTolerancePx) {
            return a.id
        }
        // Pass 2: inside closed shapes.
        for a in annotations.reversed() where a.hitsLoosely(p) {
            return a.id
        }
        return nil
    }

    func handleAt(_ p: CGPoint, for a: Annotation) -> ShapeHandle? {
        let tolerance = 12 * scale / max(zoom, 0.2)
        func near(_ q: CGPoint) -> Bool { hypot(p.x - q.x, p.y - q.y) <= tolerance }
        switch a.kind {
        case .line, .arrow:
            if near(a.start) { return .start }
            if near(a.end) { return .end }
        case .rect, .ellipse:
            let r = a.shapeRect
            if near(CGPoint(x: r.minX, y: r.minY)) { return .cornerTL }
            if near(CGPoint(x: r.maxX, y: r.minY)) { return .cornerTR }
            if near(CGPoint(x: r.minX, y: r.maxY)) { return .cornerBL }
            if near(CGPoint(x: r.maxX, y: r.maxY)) { return .cornerBR }
        case .text:
            let r = a.textBox
            if near(CGPoint(x: r.maxX, y: r.maxY)) { return .cornerBR }
            if near(CGPoint(x: r.minX, y: r.minY)) { return .cornerTL }
            if near(CGPoint(x: r.maxX, y: r.minY)) { return .cornerTR }
            if near(CGPoint(x: r.minX, y: r.maxY)) { return .cornerBL }
        default:
            break
        }
        return nil
    }

    // MARK: Editing operations

    func deleteSelected() {
        guard let id = selectedID, let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        let removed = annotations.remove(at: idx)
        selectedID = nil
        if removed.kind == .badge { renumberBadges() }
    }

    /// Keeps step badges sequential (1, 2, 3 …) after one is removed.
    private func renumberBadges() {
        var n = 1
        for i in annotations.indices where annotations[i].kind == .badge {
            annotations[i].badgeNumber = n
            n += 1
        }
        badgeCounter = n
    }

    func nudgeSelected(dx: CGFloat, dy: CGFloat) {
        guard let id = selectedID, let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[idx].translate(by: CGPoint(x: dx, y: dy))
    }

    func commitTextEditing() {
        guard let id = editingTextID else { return }
        editingTextID = nil
        if let idx = annotations.firstIndex(where: { $0.id == id }),
           annotations[idx].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            annotations.remove(at: idx)
        }
    }

    func applyCrop() {
        guard let rect = cropRect?.integral, rect.width >= 8, rect.height >= 8,
              let newBase = base.cropped(toPixels: rect) else {
            cropRect = nil
            tool = .select
            return
        }
        pushUndo()
        base = newBase
        let delta = CGPoint(x: -rect.minX, y: -rect.minY)
        for i in annotations.indices { annotations[i].translate(by: delta) }
        cropRect = nil
        tool = .select
    }

    // MARK: Export

    func flatten() -> CGImage {
        commitTextEditing()
        let w = base.width, h = base.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return base }
        ctx.interpolationQuality = .high
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        if annotations.contains(where: { $0.kind == .mosaic }) {
            filters.prepare(for: base)
        }
        AnnotationRenderer.render(annotations, in: ctx, imageSize: pixelSize,
                                  pixelated: filters.pixelated, blurred: filters.blurred)
        return ctx.makeImage() ?? base
    }

    func flattenedCapture() -> CapturedImage {
        CapturedImage(cgImage: flatten(), scale: scale)
    }
}
