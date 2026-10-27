import AppKit
import Combine
import SwiftUI

/// The interactive annotation surface, shared by the editor window and the capture overlay.
///
/// Maps view points ↔ image pixels, forwards pointer input to `EditorState`, draws the base image,
/// the annotations and their selection handles, keeps the cursor honest (move / resize / draw), and
/// hosts the in-place text editor. AppKit rather than SwiftUI so cursors, double-clicks, modifier
/// keys and the IME-friendly text view behave natively.
@MainActor
final class AnnotationCanvasView: NSView, NSTextViewDelegate {
    let state: EditorState

    /// Image pixel shown at the view's top-left corner (the overlay shows a window onto the screen).
    var pixelOrigin: CGPoint = .zero {
        didSet { if pixelOrigin != oldValue { needsDisplay = true; layoutTextEditor() } }
    }
    /// When false the canvas only displays; mouse events fall through to the view below
    /// (the overlay uses this while the region itself is being adjusted).
    var isInteractive = true {
        didSet {
            guard isInteractive != oldValue else { return }
            hover = .none
            hoverID = nil
            needsDisplay = true
        }
    }
    var allowsZoom = false
    var allowsContextMenu = false
    /// Told when the in-place text editor appears or goes away.
    var onTextEditingChanged: ((Bool) -> Void)?

    private var cancellables: Set<AnyCancellable> = []
    private var textView: EditingTextView?
    private var trackingArea: NSTrackingArea?
    private var hover: EditorState.PointerTarget = .none
    private var hoverID: UUID?
    private var pressTarget: EditorState.PointerTarget = .none
    private var mouseIsDown = false

    init(state: EditorState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Since macOS 14 views don't clip by default and dirty rects may extend past the bounds;
        // the overlay's canvas would otherwise paint the undimmed screen around the selection.
        if #available(macOS 14.0, *) { clipsToBounds = true }
        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.stateDidChange() }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractive ? super.hitTest(point) : nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        layoutTextEditor()
    }

    // MARK: Coordinates

    private var pxToView: CGFloat { state.pxToView }

    func toPixel(_ v: CGPoint) -> CGPoint {
        CGPoint(x: v.x / pxToView + pixelOrigin.x, y: v.y / pxToView + pixelOrigin.y)
    }

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - pixelOrigin.x) * pxToView, y: (p.y - pixelOrigin.y) * pxToView)
    }

    func toView(_ r: CGRect) -> CGRect {
        let o = toView(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * pxToView, height: r.height * pxToView)
    }

    private func pixelPoint(_ event: NSEvent) -> CGPoint {
        toPixel(convert(event.locationInWindow, from: nil))
    }

    // MARK: State → view

    /// Re-syncs after any model change (also called by the SwiftUI wrapper on updates).
    func stateDidChange() {
        needsDisplay = true
        syncTextEditor()
        if !mouseIsDown { refreshCursor() }
    }

    // MARK: Drawing

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dirtyRect = rect.intersection(bounds)
        guard !dirtyRect.isEmpty else { return }
        ctx.clip(to: bounds)
        let k = pxToView
        let imageRect = CGRect(origin: .zero, size: state.pixelSize)

        ctx.saveGState()
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: -pixelOrigin.x, y: -pixelOrigin.y)
        let devicePixelsPerImagePixel = k * (window?.backingScaleFactor ?? 2)
        ctx.interpolationQuality = devicePixelsPerImagePixel >= 0.99 ? .none : .high

        // Only the visible part of the base: the overlay's base is the whole screen.
        let visible = CGRect(x: dirtyRect.minX / k + pixelOrigin.x, y: dirtyRect.minY / k + pixelOrigin.y,
                             width: dirtyRect.width / k, height: dirtyRect.height / k)
            .insetBy(dx: -2, dy: -2).integral.intersection(imageRect)
        if !visible.isEmpty, let part = state.base.cropping(to: visible) {
            AnnotationRenderer.drawImageInFlippedContext(part, rect: visible, in: ctx)
        }

        if state.annotations.contains(where: { $0.kind == .mosaic }) || state.draft?.kind == .mosaic {
            state.filters.prepare(for: state.base, scale: state.scale)
        }
        var toDraw = state.annotations
        if let d = state.draft { toDraw.append(d) }
        if let editing = state.editingTextID { toDraw.removeAll { $0.id == editing } }
        AnnotationRenderer.render(toDraw, in: ctx, imageSize: state.pixelSize,
                                  pixelated: state.filters.pixelated, blurred: state.filters.blurred)
        ctx.restoreGState()

        drawHoverHighlight(ctx)
        drawTextEditingChrome(ctx)
        drawSelectionChrome(ctx)
        drawCropChrome(ctx)
    }

    private var accent: NSColor { Brand.accent }

    /// A faint outline under the pointer says "this can be grabbed".
    private func drawHoverHighlight(_ ctx: CGContext) {
        guard isInteractive, !mouseIsDown, let id = hoverID, id != state.selectedID, id != state.editingTextID,
              let a = state.annotation(id) else { return }
        let r = toView(a.bounds).insetBy(dx: -1, dy: -1)
        let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        path.lineWidth = 1.5
        accent.withAlphaComponent(0.55).setStroke()
        path.stroke()
    }

    private func drawSelectionChrome(_ ctx: CGContext) {
        guard let a = state.selected, state.editingTextID == nil else { return }
        if a.handleLayout != .endpoints {
            let r = toView(a.frame).insetBy(dx: -0.5, dy: -0.5)
            dashedRect(r)
        } else {
            // A line's selection reads best as a faint halo along the shaft.
            let path = NSBezierPath()
            path.move(to: toView(a.start))
            path.line(to: toView(a.end))
            path.lineWidth = max(6, a.lineWidth * pxToView + 6)
            path.lineCapStyle = .round
            accent.withAlphaComponent(0.18).setStroke()
            path.stroke()
        }
        for (_, p) in a.handlePoints() { drawHandle(at: toView(p)) }
    }

    private func drawTextEditingChrome(_ ctx: CGContext) {
        guard let id = state.editingTextID, let a = state.annotation(id) else { return }
        let box = toView(a.textBox)
        let radius = a.textPadding * pxToView
        let fill = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
        (a.textStyle.plate ? a.plateColor : NSColor.black.withAlphaComponent(0.06)).setFill()
        fill.fill()
        dashedRect(box, radius: radius)
        for (_, p) in a.handlePoints() { drawHandle(at: toView(p)) }
    }

    private func dashedRect(_ r: CGRect, radius: CGFloat = 0) {
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        path.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.95).setStroke()
        path.stroke()
        path.setLineDash([5, 4], count: 2, phase: 0)
        accent.setStroke()
        path.stroke()
    }

    private func drawHandle(at p: CGPoint) {
        let r = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        let dot = NSBezierPath(ovalIn: r)
        NSColor.white.setFill()
        dot.fill()
        NSGraphicsContext.restoreGraphicsState()
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.75, dy: 0.75))
        ring.lineWidth = 1.5
        accent.setStroke()
        ring.stroke()
    }

    private func drawCropChrome(_ ctx: CGContext) {
        guard state.tool == .crop, let crop = state.cropRect, crop.width > 0, crop.height > 0 else { return }
        let v = toView(crop)
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: v))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill()
        dim.fill()
        let border = NSBezierPath(rect: v)
        border.lineWidth = 1.5
        NSColor.white.setStroke()
        border.stroke()
        let guides = NSBezierPath()
        for i in 1...2 {
            let x = v.minX + v.width * CGFloat(i) / 3
            let y = v.minY + v.height * CGFloat(i) / 3
            guides.move(to: CGPoint(x: x, y: v.minY)); guides.line(to: CGPoint(x: x, y: v.maxY))
            guides.move(to: CGPoint(x: v.minX, y: y)); guides.line(to: CGPoint(x: v.maxX, y: y))
        }
        guides.lineWidth = 0.5
        NSColor.white.withAlphaComponent(0.35).setStroke()
        guides.stroke()
        for h in AnnotationHandle.boxHandles { drawHandle(at: v.point(for: h)) }

        let label = "\(Int(crop.width)) × \(Int(crop.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attrs)
        var pill = CGRect(x: v.midX - size.width / 2 - 7, y: v.minY - size.height - 14,
                          width: size.width + 14, height: size.height + 6)
        if pill.minY < 2 { pill.origin.y = v.minY + 8 }
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        label.draw(at: CGPoint(x: pill.minX + 7, y: pill.minY + 3), withAttributes: attrs)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard isInteractive else { return }
        let p = pixelPoint(event)
        pressTarget = state.target(at: p, command: event.modifierFlags.contains(.command))
        mouseIsDown = true
        state.pointerDown(at: p, clickCount: event.clickCount, modifiers: event.modifierFlags)
        applyCursor(dragging: true)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseIsDown else { return }
        state.pointerDragged(to: pixelPoint(event), modifiers: event.modifierFlags)
        if allowsZoom { autoscroll(with: event) }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseIsDown else { return }
        mouseIsDown = false
        state.pointerUp(at: pixelPoint(event), modifiers: event.modifierFlags)
        pressTarget = .none
        needsDisplay = true
        updateHover(at: pixelPoint(event), modifiers: event.modifierFlags)
    }

    override func mouseMoved(with event: NSEvent) {
        guard isInteractive, !mouseIsDown else { return }
        updateHover(at: pixelPoint(event), modifiers: event.modifierFlags)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard isInteractive, !mouseIsDown, let w = window else { return }
        let local = convert(w.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(local) { updateHover(at: toPixel(local), modifiers: event.modifierFlags) }
    }

    override func mouseExited(with event: NSEvent) {
        guard !mouseIsDown else { return }
        if hoverID != nil { hoverID = nil; needsDisplay = true }
        hover = .none
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isInteractive else { super.cursorUpdate(with: event); return }
        updateHover(at: pixelPoint(event), modifiers: event.modifierFlags)
    }

    override func magnify(with event: NSEvent) {
        guard allowsZoom else { return }
        state.setZoom(state.zoom * (1 + event.magnification))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: .zero,
                                options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                owner: self)
        addTrackingArea(ta)
        trackingArea = ta
    }

    /// Whether the pointer is really over the canvas, not over a toolbar laid on top of it
    /// or the text box being typed in (those keep their own cursors).
    private func pointerIsOnCanvas() -> Bool {
        guard let w = window, let content = w.contentView else { return true }
        return content.hitTest(w.mouseLocationOutsideOfEventStream) === self
    }

    private func updateHover(at p: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard pointerIsOnCanvas() else {
            if hoverID != nil { hoverID = nil; needsDisplay = true }
            hover = .none
            return
        }
        let target = state.target(at: p, command: modifiers.contains(.command))
        var id: UUID?
        if case .move(let hit) = target { id = hit }
        if id != hoverID {
            hoverID = id
            needsDisplay = true
        }
        hover = target
        applyCursor(dragging: false)
    }

    private func refreshCursor() {
        guard isInteractive, let w = window else { return }
        let local = convert(w.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(local) else { return }
        updateHover(at: toPixel(local), modifiers: NSEvent.modifierFlags)
    }

    private func applyCursor(dragging: Bool) {
        guard isInteractive else { return }
        let target = dragging ? pressTarget : hover
        switch target {
        case .handle(let h), .cropHandle(let h):
            Self.resizeCursor(for: h).set()
        case .move, .cropMove:
            (dragging ? NSCursor.closedHand : NSCursor.openHand).set()
        case .none:
            switch state.tool {
            case .select: NSCursor.arrow.set()
            case .text: NSCursor.iBeam.set()
            default: NSCursor.crosshair.set()
            }
        }
    }

    static func resizeCursor(for handle: AnnotationHandle) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch handle {
            case .topLeft: position = .topLeft
            case .top: position = .top
            case .topRight: position = .topRight
            case .right: position = .right
            case .bottomRight: position = .bottomRight
            case .bottom: position = .bottom
            case .bottomLeft: position = .bottomLeft
            case .left: position = .left
            case .lineStart, .lineEnd: return .crosshair
            }
            return .frameResize(position: position, directions: .all)
        }
        switch handle {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        case .topLeft, .bottomRight: return privateCursor("_windowResizeNorthWestSouthEastCursor") ?? .crosshair
        case .topRight, .bottomLeft: return privateCursor("_windowResizeNorthEastSouthWestCursor") ?? .crosshair
        case .lineStart, .lineEnd: return .crosshair
        }
    }

    private static func privateCursor(_ name: String) -> NSCursor? {
        let sel = NSSelectorFromString(name)
        guard NSCursor.responds(to: sel) else { return nil }
        return NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard allowsContextMenu, isInteractive else { return nil }
        let p = pixelPoint(event)
        state.commitTextEditing()
        if let id = state.hitTest(p, loose: true) { state.selectedID = id }
        guard let a = state.selected else { return nil }
        let menu = NSMenu()
        if a.kind == .text {
            menu.addClosureItem(L("ctx.edit_text"), symbol: "character.cursor.ibeam", owner: self) { [weak self] in
                self?.state.beginEditingText(a.id)
            }
            menu.addItem(.separator())
        }
        menu.addClosureItem(L("ctx.duplicate") + "  ⌘D", symbol: "plus.square.on.square", owner: self) { [weak self] in
            self?.state.duplicateSelected()
        }
        menu.addClosureItem(L("ctx.front") + "  ⌘]", symbol: "square.3.layers.3d.top.filled", owner: self) { [weak self] in
            self?.state.bringSelectedToFront()
        }
        menu.addClosureItem(L("ctx.back") + "  ⌘[", symbol: "square.3.layers.3d.bottom.filled", owner: self) { [weak self] in
            self?.state.sendSelectedToBack()
        }
        menu.addItem(.separator())
        menu.addClosureItem(L("ctx.delete") + "  ⌫", symbol: "trash", owner: self) { [weak self] in
            self?.state.deleteSelected()
        }
        return menu
    }

    @objc func runClosure(_ sender: NSMenuItem) {
        (sender.representedObject as? ClosureBox)?.closure()
    }

    // MARK: In-place text editor

    var isEditingText: Bool { textView != nil }

    /// Undo/redo of typing inside the open text box. False when there is nothing to undo there,
    /// so the caller can fall back to the document's undo.
    func undoTyping() -> Bool {
        guard let um = textView?.undoManager, um.canUndo else { return false }
        um.undo()
        return true
    }

    func redoTyping() -> Bool {
        guard let um = textView?.undoManager, um.canRedo else { return false }
        um.redo()
        return true
    }

    var hasTextSelection: Bool { (textView?.selectedRange().length ?? 0) > 0 }

    private func syncTextEditor() {
        guard let id = state.editingTextID, let a = state.annotation(id) else {
            guard let tv = textView else { return }
            let hadFocus = window?.firstResponder === tv
            tv.delegate = nil
            tv.removeFromSuperview()
            textView = nil
            if hadFocus { window?.makeFirstResponder(superview) }
            onTextEditingChanged?(false)
            return
        }
        let tv: EditingTextView
        if let existing = textView, existing.annotationID == id {
            tv = existing
        } else {
            textView?.removeFromSuperview()
            tv = makeTextView(for: a)
            addSubview(tv)
            textView = tv
            applyTextStyle(a, to: tv)
            window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            onTextEditingChanged?(true)
        }
        if tv.string != a.text, !tv.hasMarkedText() {
            tv.string = a.text
        }
        applyTextStyle(a, to: tv)
        layoutTextEditor()
    }

    private func makeTextView(for a: Annotation) -> EditingTextView {
        let tv = EditingTextView(frame: .zero)
        tv.annotationID = a.id
        tv.delegate = self
        // The box's corner handles and rim belong to the canvas even where the text view overlaps them.
        tv.passesThrough = { [weak self] p in
            guard let self else { return false }
            switch self.state.target(at: self.toPixel(p)) {
            case .handle, .move: return true
            default: return false
            }
        }
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
        tv.string = a.text
        return tv
    }

    private func applyTextStyle(_ a: Annotation, to tv: EditingTextView) {
        let resolved = a.textStyle.resolvedFont(size: max(4, a.fontSize * pxToView))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = a.textStyle.alignment.ns
        var attrs: [NSAttributedString.Key: Any] = [
            .font: resolved.font, .foregroundColor: a.color.nsColor, .paragraphStyle: paragraph,
        ]
        if resolved.syntheticItalic { attrs[.obliqueness] = 0.22 }
        if a.textStyle.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if a.textStyle.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let pad = a.textPadding * pxToView
        tv.textContainerInset = NSSize(width: pad, height: pad)
        tv.font = resolved.font
        tv.textColor = a.color.nsColor
        tv.alignment = a.textStyle.alignment.ns
        tv.insertionPointColor = a.color.nsColor
        tv.typingAttributes = attrs
        if let storage = tv.textStorage, storage.length > 0, !tv.hasMarkedText() {
            storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
        }
    }

    private func layoutTextEditor() {
        guard let tv = textView, let a = state.annotation(tv.annotationID) else { return }
        tv.fitContainerToContent()
        tv.frame = CGRect(origin: toView(a.textBox.origin), size: tv.intrinsicContentSize)
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? EditingTextView else { return }
        state.updateText(id: tv.annotationID, tv.string)
        layoutTextEditor()
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

/// The NSTextView used for in-place typing. Keeps its own undo history so typing undo never
/// leaks into (or out of) the window's shared undo manager once the box closes.
final class EditingTextView: NSTextView {
    var annotationID = UUID()
    /// Points (in the superview's coordinates) that should reach the canvas instead.
    var passesThrough: ((NSPoint) -> Bool)?
    private let localUndo = UndoManager()

    override var undoManager: UndoManager? { localUndo }
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let passesThrough, passesThrough(point) { return nil }
        return super.hitTest(point)
    }

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

/// SwiftUI wrapper for the editor window.
struct AnnotationCanvasRepresentable: NSViewRepresentable {
    @ObservedObject var state: EditorState

    func makeNSView(context: Context) -> AnnotationCanvasView {
        let view = AnnotationCanvasView(state: state)
        view.allowsZoom = true
        view.allowsContextMenu = true
        return view
    }

    func updateNSView(_ view: AnnotationCanvasView, context: Context) {
        view.stateDidChange()
    }
}
