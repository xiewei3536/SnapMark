import AppKit
import SwiftUI

/// All model state for one annotation session: an editor window, or the capture overlay.
@MainActor
final class EditorState: ObservableObject {
    struct Snapshot {
        var base: CGImage
        var annotations: [Annotation]
        var badgeCounter: Int
        var serial = 0 // identifies a step, so "is my step still on top?" survives the stack cap
    }

    /// What lies under the pointer: decides both the cursor and what a press does.
    enum PointerTarget: Equatable {
        case none
        case handle(AnnotationHandle) // on the selected (or edited) annotation
        case move(UUID)
        case cropHandle(AnnotationHandle)
        case cropMove
    }

    @Published private(set) var base: CGImage
    let scale: CGFloat
    var originalURL: URL?

    @Published var annotations: [Annotation] = []
    /// The shape being drawn. Not published: the canvas redraws it on every drag itself, and
    /// re-rendering the toolbars per mouse event would only cost time.
    var draft: Annotation?
    @Published var selectedID: UUID? { didSet { if selectedID != oldValue { syncInspectorFromSelection() } } }
    @Published private(set) var editingTextID: UUID? { didSet { if editingTextID != oldValue { syncInspectorFromSelection() } } }
    @Published var tool: Tool = .arrow {
        didSet {
            guard tool != oldValue else { return }
            commitTextEditing()
            if tool != .select { selectedID = nil }
            if tool != .crop { cropRect = nil }
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
    @Published var mosaicBlur = false {
        didSet { if mosaicBlur != oldValue { applyToInspected(only: [.mosaic]) { $0.mosaicBlur = mosaicBlur } } }
    }
    @Published var zoom: CGFloat = 1
    @Published var cropRect: CGRect?

    /// Bumped whenever the undo/redo stacks change so toolbar buttons refresh.
    @Published private(set) var historyRevision = 0

    /// Transient feedback shown in the status bar ("Copied", "Saved …"). Auto-clears.
    @Published private(set) var statusMessage: String?
    private var statusClearWork: DispatchWorkItem?

    var badgeCounter = 1
    let filters = FilteredImageCache()
    var viewportSize: CGSize = .zero

    /// Limits drawing and moving to part of the image (pixels). The capture overlay's base is the
    /// entire frozen screen and only the selected region is in play; the editor uses the whole image.
    var region: CGRect?

    var interactionBounds: CGRect { region ?? CGRect(origin: .zero, size: pixelSize) }

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
        case moving(id: UUID, origin: Annotation, tapEditsText: Bool)
        case resizing(id: UUID, handle: AnnotationHandle, origin: Annotation)
        case pendingTap // text / badge: placed on release
        case croppingNew(start: CGPoint)
        case movingCrop(origin: CGRect)
        case resizingCrop(handle: AnnotationHandle, origin: CGRect)
    }
    private var gestureMode: GestureMode = .none
    private var gestureStart: CGPoint = .zero
    private var movedThisGesture = false
    private var pushedUndoThisGesture = false

    // Text-edit session: one undo step per edit, none for an edit that changed nothing. The step is
    // provisional (it doesn't clear redo) until the edit turns out to change something.
    private var textEditStep: Int?
    private var textEditOriginal: Annotation?
    private var textEditIsNew = false

    // Bursts (slider drags, arrow-key nudges) share one step while nothing else touched the history.
    private var burstKey: String?
    private var burstStep = -1
    private var burstTime = Date.distantPast
    private var nextSerial = 1

    init(image: CapturedImage, originalURL: URL?, annotations: [Annotation] = [],
         badgeCounter: Int? = nil, annotationsAreSaved: Bool = true) {
        self.base = image.cgImage
        self.savedBase = image.cgImage
        self.scale = image.scale
        self.originalURL = originalURL
        self.annotations = annotations
        self.savedAnnotations = annotationsAreSaved ? annotations : []
        let maxBadge = annotations.filter { $0.kind == .badge }.map(\.badgeNumber).max() ?? 0
        self.badgeCounter = badgeCounter ?? (maxBadge + 1)
    }

    // MARK: Derived geometry

    var pixelSize: CGSize { CGSize(width: base.width, height: base.height) }
    var pointSize: CGSize { CGSize(width: CGFloat(base.width) / scale, height: CGFloat(base.height) / scale) }
    /// View points per image pixel at the current zoom.
    var pxToView: CGFloat { zoom / scale }
    var displaySize: CGSize { CGSize(width: pixelSize.width * pxToView, height: pixelSize.height * pxToView) }

    var lineWidthPx: CGFloat { lineWidthPt * scale }
    var fontSizePx: CGFloat { fontSizePt * scale }

    /// A distance of `points` on screen, in image pixels at the current zoom.
    func pixels(forViewPoints points: CGFloat) -> CGFloat { points / max(pxToView, 0.01) }

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

    // MARK: Lookup

    func annotation(_ id: UUID?) -> Annotation? {
        guard let id else { return nil }
        return annotations.first { $0.id == id }
    }

    private func index(of id: UUID) -> Int? { annotations.firstIndex { $0.id == id } }

    var selected: Annotation? { annotation(selectedID) }

    // MARK: Inspector ↔ selection

    /// The annotation the inspector controls: the text being edited, else the selection.
    var inspectedID: UUID? { editingTextID ?? selectedID }
    var inspected: Annotation? { annotation(inspectedID) }
    var inspectedIsText: Bool { inspected?.kind == .text }

    private var syncingInspector = false

    private func applyToInspected(only: Set<Annotation.Kind>? = nil, excluding: Set<Annotation.Kind> = [],
                                  _ mutate: (inout Annotation) -> Void) {
        guard !syncingInspector, let id = inspectedID, let idx = index(of: id) else { return }
        let kind = annotations[idx].kind
        if let only, !only.contains(kind) { return }
        if excluding.contains(kind) { return }
        // Restyling the box being typed in is part of that edit's step.
        if id == editingTextID, ownTextStepOnTop {
            mutate(&annotations[idx])
            return
        }
        // Slider drags produce many changes; one undo step per burst.
        pushUndoForBurst("inspector", within: 1.2)
        mutate(&annotations[idx])
    }

    /// Mirrors the selected/edited annotation's attributes into the inspector controls.
    private func syncInspectorFromSelection() {
        guard let a = inspected else { return }
        syncingInspector = true
        defer { syncingInspector = false }
        color = a.color
        switch a.kind {
        case .text:
            fontSizePt = a.fontSize / scale
            textStyle = a.textStyle
        case .mosaic:
            lineWidthPt = a.lineWidth / scale
            mosaicBlur = a.mosaicBlur
        default:
            lineWidthPt = a.lineWidth / scale
        }
    }

    // MARK: Text editing

    func adjustFontSize(by delta: CGFloat) {
        fontSizePt = min(200, max(6, fontSizePt + delta))
    }

    func updateText(id: UUID, _ text: String) {
        guard let idx = index(of: id), annotations[idx].text != text else { return }
        annotations[idx].text = text
    }

    /// Opens a text annotation for typing. `isNew` texts already pushed their (provisional) step
    /// when they were created.
    func beginEditingText(_ id: UUID, isNew: Bool = false) {
        guard editingTextID != id, let a = annotation(id), a.kind == .text else { return }
        commitTextEditing()
        if !isNew { pushUndo(clearsRedo: false) }
        textEditStep = undoStack.last?.serial
        textEditOriginal = a
        textEditIsNew = isNew
        selectedID = nil
        editingTextID = id
    }

    /// The edit session's own snapshot is still the latest step.
    private var ownTextStepOnTop: Bool { textEditStep != nil && undoStack.last?.serial == textEditStep }

    enum TextCommitResult { case notEditing, discardedEmptyNew, unchanged, changed }

    @discardableResult
    func commitTextEditing() -> TextCommitResult {
        guard let id = editingTextID else { return .notEditing }
        let ownStepOnTop = ownTextStepOnTop
        editingTextID = nil
        textEditStep = nil
        guard let idx = index(of: id) else { return .changed }
        if annotations[idx].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            annotations.remove(at: idx)
            if !textEditIsNew { // emptied an existing text = deleted it
                committedChange()
                return .changed
            }
            // Creating a text and leaving it empty is not worth an undo step.
            if ownStepOnTop { dropLastUndo() }
            return .discardedEmptyNew
        }
        selectedID = id // stays grabbable: drag to move, corners to scale
        if !textEditIsNew, ownStepOnTop, annotations[idx] == textEditOriginal {
            dropLastUndo() // opened, nothing changed
            return .unchanged
        }
        committedChange()
        return .changed
    }

    /// A provisional step became real: the redo future no longer applies.
    private func committedChange() {
        guard !redoStack.isEmpty else { return }
        redoStack.removeAll()
        historyRevision += 1
    }

    // MARK: Undo / redo

    private func snapshot() -> Snapshot {
        defer { nextSerial += 1 }
        return Snapshot(base: base, annotations: annotations, badgeCounter: badgeCounter, serial: nextSerial)
    }

    /// Records the current state as an undo step. Any new edit invalidates the redo future —
    /// except provisional steps (text edits), which clear it only once they turn out to change something.
    func pushUndo(clearsRedo: Bool = true) {
        undoStack.append(snapshot())
        if undoStack.count > 200 { undoStack.removeFirst() }
        if clearsRedo { redoStack.removeAll() }
        burstKey = nil
        historyRevision += 1
    }

    /// One step per burst of the same kind of edit, as long as nothing else touched the history.
    private func pushUndoForBurst(_ key: String, within window: TimeInterval) {
        let now = Date()
        defer { burstTime = now }
        if burstKey == key, undoStack.last?.serial == burstStep, now.timeIntervalSince(burstTime) < window { return }
        pushUndo()
        burstKey = key
        burstStep = undoStack.last?.serial ?? -1
    }

    private func dropLastUndo() {
        _ = undoStack.popLast()
        historyRevision += 1
    }

    var canUndo: Bool { !undoStack.isEmpty || editingTextID != nil }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        // Undo while typing: an untouched new text box just goes away; otherwise the edit is
        // committed and then undone like any other step.
        if commitTextEditing() == .discardedEmptyNew { return }
        guard let snap = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        restore(snap)
    }

    func redo() {
        commitTextEditing()
        guard let snap = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        restore(snap)
    }

    private func restore(_ snap: Snapshot) {
        base = snap.base
        // A snapshot taken mid-typing may hold a still-empty text box; it has nothing to show.
        annotations = snap.annotations.filter { $0.kind != .text || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        badgeCounter = snap.badgeCounter

        if let id = selectedID, index(of: id) == nil { selectedID = nil }
        editingTextID = nil
        textEditStep = nil
        draft = nil
        gestureMode = .none
        burstKey = nil
        syncInspectorFromSelection() // the controls show the restored values
        historyRevision += 1
    }

    // MARK: Pointer (all points in image pixel coordinates)

    private var handleTolerance: CGFloat { pixels(forViewPoints: 8) }
    private var hitTolerance: CGFloat { pixels(forViewPoints: 6) }
    private var dragThreshold: CGFloat { pixels(forViewPoints: 3) }

    func target(at p: CGPoint, command: Bool = false) -> PointerTarget {
        func near(_ q: CGPoint) -> Bool { hypot(p.x - q.x, p.y - q.y) <= handleTolerance }

        if tool == .crop {
            if let r = cropRect, r.width > 0, r.height > 0 {
                for h in AnnotationHandle.boxHandles where near(r.point(for: h)) { return .cropHandle(h) }
                if r.contains(p) { return .cropMove }
            }
            return .none
        }
        if let id = editingTextID, let a = annotation(id) {
            for (h, q) in a.handlePoints() where near(q) { return .handle(h) }
            // The text view covers the box; the band around it is the grip for moving.
            let box = a.textBox
            if box.insetBy(dx: -hitTolerance, dy: -hitTolerance).contains(p), !box.insetBy(dx: 2, dy: 2).contains(p) {
                return .move(id)
            }
            return .none
        }
        if let a = selected {
            for (h, q) in a.handlePoints() where near(q) { return .handle(h) }
        }
        if !tool.isFreehand || command, let id = hitTest(p, loose: tool == .select) {
            return .move(id)
        }
        return .none
    }

    func pointerDown(at p: CGPoint, clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
        gestureStart = p
        movedThisGesture = false
        pushedUndoThisGesture = false
        gestureMode = .none
        let command = modifiers.contains(.command)

        // While typing, a press on the box's rim/handles moves or scales it; anywhere else ends the edit.
        if let editID = editingTextID {
            switch target(at: p, command: command) {
            case .handle(let h):
                if let a = annotation(editID) { gestureMode = .resizing(id: editID, handle: h, origin: a) }
                pushedUndoThisGesture = ownTextStepOnTop // covered by the edit's step
                return
            case .move(let id) where id == editID:
                if let a = annotation(id) { gestureMode = .moving(id: id, origin: a, tapEditsText: false) }
                pushedUndoThisGesture = ownTextStepOnTop
                return
            default:
                commitTextEditing()
                if tool == .text { return } // one click = one action: finishing, not starting a new text
            }
        }

        // Double-click a text to edit it, whatever the tool.
        if clickCount >= 2, let id = hitTest(p, loose: false), annotation(id)?.kind == .text {
            beginEditingText(id)
            return
        }

        switch target(at: p, command: command) {
        case .handle(let h):
            if let a = selected { gestureMode = .resizing(id: a.id, handle: h, origin: a) }
            return
        case .move(let id):
            guard let a = annotation(id) else { return }
            selectedID = id
            gestureMode = .moving(id: id, origin: a, tapEditsText: tool == .text && a.kind == .text)
            return
        case .cropHandle(let h):
            if let r = cropRect { gestureMode = .resizingCrop(handle: h, origin: r) }
            return
        case .cropMove:
            if let r = cropRect { gestureMode = .movingCrop(origin: r) }
            return
        case .none:
            break
        }

        switch tool {
        case .select:
            selectedID = nil
        case .crop:
            let start = clampToImage(p)
            gestureMode = .croppingNew(start: start)
            cropRect = CGRect(origin: start, size: .zero)
        case .text, .badge:
            selectedID = nil
            gestureMode = .pendingTap
        case .pen, .highlighter, .mosaic:
            selectedID = nil
            var a = Annotation(kind: tool == .pen ? .pen : (tool == .highlighter ? .highlighter : .mosaic))
            a.color = color
            a.lineWidth = lineWidthPx
            a.points = [clampToBounds(p)]
            a.mosaicBlur = mosaicBlur
            if tool == .mosaic { filters.prepare(for: base, scale: scale) }
            draft = a
            gestureMode = .drawing
        case .line, .arrow, .rect, .ellipse:
            selectedID = nil
            var a = Annotation(kind: tool == .line ? .line : tool == .arrow ? .arrow : tool == .rect ? .rect : .ellipse)
            a.color = color
            a.lineWidth = lineWidthPx
            a.start = clampToBounds(p)
            a.end = a.start
            draft = a
            gestureMode = .drawing
        }
    }

    func pointerDragged(to p: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        let shift = modifiers.contains(.shift)
        let delta = CGPoint(x: p.x - gestureStart.x, y: p.y - gestureStart.y)
        if !movedThisGesture, hypot(delta.x, delta.y) >= dragThreshold { movedThisGesture = true }

        switch gestureMode {
        case .drawing:
            guard var a = draft else { return }
            let q = clampToBounds(p)
            switch a.kind {
            case .pen, .highlighter, .mosaic:
                if let last = a.points.last, hypot(q.x - last.x, q.y - last.y) < pixels(forViewPoints: 0.75) { return }
                a.points.append(q)
            default:
                a.end = shift ? constrained(from: a.start, to: q, kind: a.kind) : q
            }
            draft = a
        case .moving(let id, let origin, _):
            guard movedThisGesture, let idx = index(of: id) else { return }
            pushUndoOnce()
            var moved = origin
            moved.translate(by: clampedDelta(delta, for: origin.frame))
            annotations[idx] = moved
        case .resizing(let id, let handle, let origin):
            guard movedThisGesture || hypot(delta.x, delta.y) > 0, let idx = index(of: id) else { return }
            pushUndoOnce()
            annotations[idx] = origin.resized(handle, by: delta, keepAspect: shift)
            if origin.kind == .text, inspectedID == id {
                syncingInspector = true
                fontSizePt = annotations[idx].fontSize / scale
                syncingInspector = false
            }
        case .croppingNew(let start):
            cropRect = CGRect(corner: start, corner: clampToImage(p)).intersection(imageRect)
        case .movingCrop(let origin):
            var r = origin.offsetBy(dx: delta.x, dy: delta.y)
            r.origin.x = min(max(0, r.minX), pixelSize.width - r.width)
            r.origin.y = min(max(0, r.minY), pixelSize.height - r.height)
            cropRect = r
        case .resizingCrop(let handle, let origin):
            let (x0, y0, x1, y1) = origin.draggedEdges(handle, by: delta)
            cropRect = CGRect(corner: CGPoint(x: x0, y: y0), corner: CGPoint(x: x1, y: y1)).intersection(imageRect)
        case .pendingTap, .none:
            break
        }
    }

    func pointerUp(at p: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        let mode = gestureMode
        gestureMode = .none
        let wasTap = !movedThisGesture

        switch mode {
        case .drawing:
            guard let a = draft else { return }
            draft = nil
            let tooSmall: Bool
            switch a.kind {
            case .pen, .highlighter, .mosaic: tooSmall = a.points.count < 2
            default: tooSmall = hypot(a.end.x - a.start.x, a.end.y - a.start.y) < max(3, dragThreshold)
            }
            guard !tooSmall else { return }
            pushUndo()
            annotations.append(a)
            // Fresh shapes stay selected so they can be nudged, stretched or restyled right away.
            if !tool.isFreehand { selectedID = a.id }
        case .moving(let id, _, let tapEditsText):
            if wasTap, tapEditsText { beginEditingText(id) }
        case .pendingTap:
            let at = clampToBounds(gestureStart)
            if tool == .text {
                pushUndo(clearsRedo: false) // provisional: an abandoned empty box leaves redo alone
                var a = Annotation(kind: .text)
                a.color = color
                a.fontSize = fontSizePx
                a.textStyle = textStyle
                a.start = CGPoint(x: at.x, y: max(interactionBounds.minY, at.y - a.fontSize * 0.7))
                annotations.append(a)
                beginEditingText(a.id, isNew: true)
            } else if tool == .badge {
                pushUndo()
                var a = Annotation(kind: .badge)
                a.color = color
                a.lineWidth = lineWidthPx
                a.badgeNumber = badgeCounter
                a.start = at
                badgeCounter += 1
                annotations.append(a)
                selectedID = a.id
            }
        case .croppingNew:
            if wasTap { cropRect = nil }
        case .resizing, .movingCrop, .resizingCrop, .none:
            break
        }
    }

    /// Ends whatever gesture is in flight (e.g. the window lost focus mid-drag).
    func cancelGesture() {
        if case .drawing = gestureMode { draft = nil }
        gestureMode = .none
    }

    private func pushUndoOnce() {
        guard !pushedUndoThisGesture else { return }
        pushUndo()
        pushedUndoThisGesture = true
    }

    private func constrained(from start: CGPoint, to p: CGPoint, kind: Annotation.Kind) -> CGPoint {
        switch kind {
        case .line, .arrow:
            return Annotation.snap45(from: start, to: p)
        default:
            // Square / circle.
            let dx = p.x - start.x, dy = p.y - start.y
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        }
    }

    private var imageRect: CGRect { CGRect(origin: .zero, size: pixelSize) }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), pixelSize.width), y: min(max(0, p.y), pixelSize.height))
    }

    private func clampToBounds(_ p: CGPoint) -> CGPoint {
        let b = interactionBounds
        return CGPoint(x: min(max(b.minX, p.x), b.maxX), y: min(max(b.minY, p.y), b.maxY))
    }

    /// Limits a move so a sliver of the annotation always stays inside the work area.
    private func clampedDelta(_ d: CGPoint, for frame: CGRect) -> CGPoint {
        let b = interactionBounds
        let keep = min(pixels(forViewPoints: 16), b.width / 2, b.height / 2)
        var dx = d.x, dy = d.y
        if frame.maxX + dx < b.minX + keep { dx = b.minX + keep - frame.maxX }
        if frame.minX + dx > b.maxX - keep { dx = b.maxX - keep - frame.minX }
        if frame.maxY + dy < b.minY + keep { dy = b.minY + keep - frame.maxY }
        if frame.minY + dy > b.maxY - keep { dy = b.maxY - keep - frame.minY }
        return CGPoint(x: dx, y: dy)
    }

    // MARK: Hit testing

    /// Topmost annotation under `p`. Strokes, outlines and glyph boxes are hit precisely; `loose`
    /// also accepts the inside of closed shapes (for the select tool).
    func hitTest(_ p: CGPoint, loose: Bool = true) -> UUID? {
        for a in annotations.reversed() where a.id != editingTextID && a.hits(p, tolerance: hitTolerance) {
            return a.id
        }
        if loose {
            for a in annotations.reversed() where a.hitsLoosely(p) {
                return a.id
            }
        }
        return nil
    }

    // MARK: Editing operations

    func deleteSelected() {
        guard let id = selectedID, let idx = index(of: id) else { return }
        pushUndo()
        let removed = annotations.remove(at: idx)
        selectedID = nil
        if removed.kind == .badge { renumberBadges() }
    }

    func duplicateSelected() {
        guard let a = selected else { return }
        pushUndo()
        var copy = a
        copy.id = UUID()
        let offset = pixels(forViewPoints: 14)
        copy.translate(by: clampedDelta(CGPoint(x: offset, y: offset), for: a.frame))
        if copy.kind == .badge {
            copy.badgeNumber = badgeCounter
            badgeCounter += 1
        }
        annotations.append(copy)
        selectedID = copy.id
    }

    func bringSelectedToFront() {
        guard let id = selectedID, let idx = index(of: id), idx != annotations.count - 1 else { return }
        pushUndo()
        annotations.append(annotations.remove(at: idx))
    }

    func sendSelectedToBack() {
        guard let id = selectedID, let idx = index(of: id), idx != 0 else { return }
        pushUndo()
        annotations.insert(annotations.remove(at: idx), at: 0)
    }

    func removeAllAnnotations() {
        commitTextEditing()
        guard !annotations.isEmpty else { return }
        pushUndo()
        annotations.removeAll()
        selectedID = nil
        badgeCounter = 1
    }

    /// Keeps step badges sequential (1, 2, 3 …) after one is removed.
    private func renumberBadges() {
        let order = annotations.indices.filter { annotations[$0].kind == .badge }
            .sorted { annotations[$0].badgeNumber < annotations[$1].badgeNumber }
        for (n, i) in order.enumerated() { annotations[i].badgeNumber = n + 1 }
        badgeCounter = order.count + 1
    }

    /// Arrow-key nudge; a burst of presses is one undo step.
    func nudgeSelected(dx: CGFloat, dy: CGFloat) {
        guard let id = selectedID, let idx = index(of: id) else { return }
        pushUndoForBurst("nudge", within: 1.0)
        annotations[idx].translate(by: clampedDelta(CGPoint(x: dx, y: dy), for: annotations[idx].frame))
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

    /// Base + annotations as one image. `crop` (pixels) limits the result; the capture overlay
    /// renders only the selected part of its full-screen base.
    func flatten(cropTo crop: CGRect? = nil) -> CGImage {
        commitTextEditing()
        return AnnotationRenderer.flatten(base: base, scale: scale, annotations: annotations,
                                          crop: crop, filters: filters)
    }

    func flattenedCapture() -> CapturedImage {
        CapturedImage(cgImage: flatten(), scale: scale)
    }

    /// The annotations moved into the coordinate space of `region` (for handing a cropped
    /// overlay session to the full editor).
    func annotations(relativeTo region: CGRect) -> [Annotation] {
        commitTextEditing()
        return annotations.map { a in
            var b = a
            b.translate(by: CGPoint(x: -region.minX, y: -region.minY))
            return b
        }
    }

    // MARK: Keyboard (shared by the editor window and the capture overlay)

    /// Physical key codes, so shortcuts work under any keyboard layout or IME
    /// (with 注音/拼音 active, `characters` returns Zhuyin/Pinyin glyphs instead of letters).
    enum Key {
        static let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2, h: UInt16 = 4, z: UInt16 = 6, c: UInt16 = 8, v: UInt16 = 9
        static let b: UInt16 = 11, w: UInt16 = 13, e: UInt16 = 14, r: UInt16 = 15, t: UInt16 = 17
        static let u: UInt16 = 32, i: UInt16 = 34, p: UInt16 = 35, l: UInt16 = 37, m: UInt16 = 46
        static let equal: UInt16 = 24, nine: UInt16 = 25, minus: UInt16 = 27, zero: UInt16 = 29
        static let leftBracket: UInt16 = 33, rightBracket: UInt16 = 30
        static let ret: UInt16 = 36, enter: UInt16 = 76, esc: UInt16 = 53, space: UInt16 = 49
        static let delete: UInt16 = 51, fwdDelete: UInt16 = 117
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    }

    static let toolKeys: [UInt16: Tool] = [
        Key.v: .select, Key.p: .pen, Key.h: .highlighter, Key.l: .line, Key.a: .arrow,
        Key.r: .rect, Key.e: .ellipse, Key.t: .text, Key.m: .mosaic, Key.b: .badge, Key.c: .crop,
    ]

    static func cleanFlags(_ event: NSEvent) -> NSEvent.ModifierFlags {
        // Arrow keys carry .function/.numericPad; strip them so "shift + arrow" compares cleanly.
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock])
    }

    /// Annotation shortcuts common to every surface: undo/redo, delete, nudge, duplicate,
    /// stacking order, and text styling. Returns true when the key was used.
    func handleAnnotationKey(code: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        if inspectedIsText, handleTextStyleShortcut(code: code, flags: flags) { return true }
        if flags == [.command] {
            switch code {
            case Key.z: undo(); return true
            case Key.d where selectedID != nil: duplicateSelected(); return true
            case Key.rightBracket where selectedID != nil: bringSelectedToFront(); return true
            case Key.leftBracket where selectedID != nil: sendSelectedToBack(); return true
            default: break
            }
        }
        if flags == [.command, .shift], code == Key.z { redo(); return true }
        if flags.isEmpty || flags == [.shift] {
            switch code {
            case Key.delete, Key.fwdDelete:
                guard selectedID != nil else { return false }
                deleteSelected()
                return true
            case Key.left, Key.right, Key.down, Key.up:
                guard selectedID != nil else { return false }
                let step: CGFloat = (flags == [.shift] ? 10 : 1) * scale
                switch code {
                case Key.left: nudgeSelected(dx: -step, dy: 0)
                case Key.right: nudgeSelected(dx: step, dy: 0)
                case Key.down: nudgeSelected(dx: 0, dy: step)
                default: nudgeSelected(dx: 0, dy: -step)
                }
                return true
            default:
                break
            }
        }
        return false
    }

    /// ⌘B bold · ⌘I italic · ⌘U underline · ⌥⌘↑/↓ font size (for the selected or edited text).
    func handleTextStyleShortcut(code: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        if flags == [.command] {
            switch code {
            case Key.b: textStyle.bold.toggle(); return true
            case Key.i: textStyle.italic.toggle(); return true
            case Key.u: textStyle.underline.toggle(); return true
            default: return false
            }
        }
        if flags == [.command, .option] {
            switch code {
            case Key.up: adjustFontSize(by: 2); return true
            case Key.down: adjustFontSize(by: -2); return true
            default: return false
            }
        }
        return false
    }
}
