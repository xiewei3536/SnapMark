import AppKit
import SwiftUI

/// What the user launched the selection overlay for.
enum SelectionPurpose {
    case screenshot
    case recording
    case ocr
    case pin
    case windowPick
}

/// The action chosen from the overlay toolbar or keyboard.
enum SelectionAction {
    case capture, copy, record, pin, ocr
}

struct SelectionResult {
    let screen: NSScreen
    let localRect: CGRect // top-left origin, points, relative to the screen
    let frozen: CapturedImage
    let action: SelectionAction
    let windowID: CGWindowID? // set when the user clicked a whole window

    var globalCocoaRect: CGRect {
        CGRect(x: screen.frame.minX + localRect.minX,
               y: screen.frame.maxY - localRect.maxY,
               width: localRect.width, height: localRect.height)
    }
}

/// Runs an interactive region-selection session across all displays,
/// working on frozen screenshots so the UI never pollutes the capture.
@MainActor
final class SelectionController {
    static let shared = SelectionController()

    private var windows: [OverlayWindow] = []
    private(set) var purpose: SelectionPurpose = .screenshot
    private var completion: ((SelectionResult?) -> Void)?
    private(set) var windowList: [WindowInfo] = []

    var isActive: Bool { !windows.isEmpty }

    /// The app that was frontmost before we took over, so focus can be handed back
    /// (matters for recordings: the recorded app shouldn't look inactive).
    private var previousApp: NSRunningApplication?

    static var lastRegion: (screenFrame: CGRect, localRect: CGRect)?

    func begin(purpose: SelectionPurpose, completion: @escaping (SelectionResult?) -> Void) {
        guard !isActive else { return }
        self.purpose = purpose
        self.completion = completion
        self.windowList = WindowEnumerator.onScreenWindows()
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = (front?.processIdentifier == ProcessInfo.processInfo.processIdentifier) ? nil : front

        Task { @MainActor in
            var captures: [(NSScreen, CapturedImage)] = []
            for screen in NSScreen.screens {
                if let image = try? await CaptureEngine.captureDisplay(screen: screen, showCursor: false) {
                    captures.append((screen, image))
                }
            }
            guard !captures.isEmpty else {
                let done = self.completion
                self.completion = nil
                done?(nil)
                AppCoordinator.shared.handleMissingPermission()
                return
            }
            for (screen, image) in captures {
                let window = OverlayWindow(screen: screen, frozen: image, controller: self)
                self.windows.append(window)
                window.orderFrontRegardless()
            }
            NSApp.activate(ignoringOtherApps: true)
            let mouse = NSEvent.mouseLocation
            let under = self.windows.first(where: { $0.targetScreen.frame.contains(mouse) }) ?? self.windows.first
            under?.makeKey()
        }
    }

    func cancel() {
        finishSession(with: nil)
        restorePreviousApp()
    }

    /// Re-activates whatever app was frontmost before the overlay appeared.
    func restorePreviousApp() {
        previousApp?.activate(options: [])
        previousApp = nil
    }

    func confirm(screen: NSScreen, localRect: CGRect, frozen: CapturedImage,
                 action: SelectionAction, windowID: CGWindowID? = nil) {
        SelectionController.lastRegion = (screen.frame, localRect)
        finishSession(with: SelectionResult(screen: screen, localRect: localRect, frozen: frozen,
                                            action: action, windowID: windowID))
    }

    /// Called when a drag starts on one screen: other screens clear their state.
    func selectionBegan(on window: OverlayWindow) {
        for w in windows where w !== window { w.overlayView?.clearSelection() }
    }

    private func finishSession(with result: SelectionResult?) {
        let done = completion
        completion = nil
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        done?(result)
    }
}

// MARK: - Overlay window

final class OverlayWindow: NSWindow {
    weak var overlayView: OverlayView?
    let targetScreen: NSScreen

    init(screen: NSScreen, frozen: CapturedImage, controller: SelectionController) {
        targetScreen = screen
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = true
        backgroundColor = .black
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true

        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size),
                               screen: screen, frozen: frozen, controller: controller)
        contentView = view
        overlayView = view
        initialFirstResponder = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        overlayView?.handleKeyDown(event)
    }

    override func cancelOperation(_ sender: Any?) {
        Task { @MainActor in SelectionController.shared.cancel() }
    }
}

// MARK: - Overlay view

final class OverlayView: NSView {
    private let overlayScreen: NSScreen
    private let frozen: CapturedImage
    private let bitmap: NSBitmapImageRep
    private weak var controller: SelectionController?

    private enum DragMode {
        case none
        case creating(start: CGPoint)
        case moving(grabOffset: CGPoint)
        case resizing(handle: Handle, anchor: CGRect)
    }

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private var selection: CGRect? { didSet { repositionToolbar(); needsDisplay = true } }
    private var isSelected = false // selection finalized (adjustable, toolbar showing)
    private var dragMode: DragMode = .none
    private var mouseLocation: CGPoint = .zero
    private var hoveredWindow: WindowInfo?
    private var toolbarHost: NSHostingView<OverlayToolbar>?
    private var trackingArea: NSTrackingArea?

    private let accent = Brand.accent

    init(frame: NSRect, screen: NSScreen, frozen: CapturedImage, controller: SelectionController) {
        self.overlayScreen = screen
        self.frozen = frozen
        self.bitmap = NSBitmapImageRep(cgImage: frozen.cgImage)
        self.controller = controller
        super.init(frame: frame)
        wantsLayer = true
        mouseLocation = convertGlobalToLocal(NSEvent.mouseLocation)
        updateHoveredWindow(at: NSEvent.mouseLocation)
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if let host = toolbarHost {
            addCursorRect(host.frame, cursor: .arrow)
        }
    }

    // MARK: Coordinates

    private func convertGlobalToLocal(_ globalCocoa: CGPoint) -> CGPoint {
        CGPoint(x: globalCocoa.x - overlayScreen.frame.minX,
                y: overlayScreen.frame.maxY - globalCocoa.y)
    }

    private func localRect(fromGlobalCocoa f: CGRect) -> CGRect {
        CGRect(x: f.minX - overlayScreen.frame.minX,
               y: overlayScreen.frame.maxY - f.maxY,
               width: f.width, height: f.height)
    }

    // MARK: State

    func clearSelection() {
        selection = nil
        isSelected = false
        dragMode = .none
        removeToolbar()
        needsDisplay = true
    }

    private var purpose: SelectionPurpose { controller?.purpose ?? .screenshot }

    /// The action a bare click / Return performs for this session.
    private var defaultAction: SelectionAction {
        switch purpose {
        case .recording: return .record
        case .ocr: return .ocr
        case .pin: return .pin
        case .screenshot, .windowPick: return .capture
        }
    }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
    }

    override func mouseMoved(with event: NSEvent) {
        mouseLocation = convert(event.locationInWindow, from: nil)
        if !isSelected {
            updateHoveredWindow(at: NSEvent.mouseLocation)
            NSCursor.crosshair.set()
        } else if let sel = selection {
            if let h = handleAt(mouseLocation, in: sel) {
                cursorFor(handle: h).set()
            } else if sel.contains(mouseLocation) {
                NSCursor.openHand.set()
            } else {
                NSCursor.crosshair.set()
            }
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouseLocation = p
        if let w = window as? OverlayWindow {
            Task { @MainActor in SelectionController.shared.selectionBegan(on: w) }
        }
        if isSelected, let sel = selection {
            if let h = handleAt(p, in: sel) {
                dragMode = .resizing(handle: h, anchor: sel)
                return
            }
            if sel.insetBy(dx: -4, dy: -4).contains(p) {
                dragMode = .moving(grabOffset: CGPoint(x: p.x - sel.minX, y: p.y - sel.minY))
                NSCursor.closedHand.set()
                return
            }
            // Click outside the current selection: start a new one.
            clearSelection()
            updateHoveredWindow(at: NSEvent.mouseLocation)
        }
        dragMode = .creating(start: p)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = clamp(convert(event.locationInWindow, from: nil))
        mouseLocation = p
        switch dragMode {
        case .creating(let start):
            hoveredWindow = nil
            selection = CGRect(corner: start, corner: p)
        case .moving(let offset):
            guard var sel = selection else { return }
            sel.origin = CGPoint(x: p.x - offset.x, y: p.y - offset.y)
            sel.origin.x = min(max(0, sel.origin.x), bounds.width - sel.width)
            sel.origin.y = min(max(0, sel.origin.y), bounds.height - sel.height)
            selection = sel
        case .resizing(let handle, let anchor):
            selection = resize(anchor: anchor, handle: handle, to: p)
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer { dragMode = .none; needsDisplay = true }

        switch dragMode {
        case .creating(let start):
            let dist = hypot(p.x - start.x, p.y - start.y)
            if dist < 4 {
                // A plain click: act on the hovered window.
                guard let win = hoveredWindow else {
                    selection = nil
                    return
                }
                if purpose == .recording {
                    // Recording works on screen regions, so snap the selection to the window.
                    let rect = localRect(fromGlobalCocoa: win.frame).intersection(bounds)
                    guard !rect.isEmpty else { return }
                    selection = rect.integral
                    enterSelectedState()
                } else {
                    confirmWholeWindow(win, action: defaultAction)
                }
            } else if let sel = selection, sel.width >= 4, sel.height >= 4 {
                selection = sel.integral
                enterSelectedState()
            } else {
                clearSelection()
            }
        case .moving, .resizing:
            if let sel = selection { selection = sel.integral }
            repositionToolbar()
            if let sel = selection, sel.contains(p) { NSCursor.openHand.set() }
        case .none:
            break
        }
    }

    private func enterSelectedState() {
        isSelected = true
        hoveredWindow = nil
        installToolbarIfNeeded()
        repositionToolbar()
        needsDisplay = true
    }

    // MARK: Keyboard

    func handleKeyDown(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])
        switch event.keyCode {
        case 53: // Esc
            Task { @MainActor in SelectionController.shared.cancel() }
        case 36, 76: // Return / Enter
            if isSelected { performAction(defaultAction) }
        case 8 where flags.contains(.command): // ⌘C → copy only
            if isSelected { performAction(.copy) }
        case 123, 124, 125, 126: // Arrows nudge the selection
            guard isSelected, var sel = selection else { return }
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 123: sel.origin.x -= step
            case 124: sel.origin.x += step
            case 125: sel.origin.y += step
            case 126: sel.origin.y -= step
            default: break
            }
            sel.origin.x = min(max(0, sel.origin.x), bounds.width - sel.width)
            sel.origin.y = min(max(0, sel.origin.y), bounds.height - sel.height)
            selection = sel
        default:
            break
        }
    }

    // MARK: Actions

    private func performAction(_ action: SelectionAction) {
        guard let sel = selection?.integral, sel.width >= 2, sel.height >= 2 else { return }
        removeToolbar()
        Task { @MainActor in
            SelectionController.shared.confirm(screen: overlayScreen, localRect: sel,
                                               frozen: frozen, action: action)
        }
    }

    private func confirmWholeWindow(_ win: WindowInfo, action: SelectionAction) {
        let rect = localRect(fromGlobalCocoa: win.frame).intersection(bounds).integral
        guard rect.width >= 2, rect.height >= 2 else { return }
        Task { @MainActor in
            SelectionController.shared.confirm(screen: overlayScreen, localRect: rect,
                                               frozen: frozen, action: action, windowID: win.windowID)
        }
    }

    // MARK: Toolbar

    private func makeToolbar() -> OverlayToolbar {
        let sel = selection ?? .zero
        return OverlayToolbar(
            purpose: purpose,
            sizeText: "\(Int(sel.width * frozen.scale)) × \(Int(sel.height * frozen.scale))",
            onAction: { [weak self] action in self?.performAction(action) },
            onCancel: { Task { @MainActor in SelectionController.shared.cancel() } }
        )
    }

    private func installToolbarIfNeeded() {
        guard toolbarHost == nil else { return }
        let host = NSHostingView(rootView: makeToolbar())
        host.frame.size = host.fittingSize
        addSubview(host)
        toolbarHost = host
    }

    private func repositionToolbar() {
        guard let host = toolbarHost, let sel = selection else { return }
        host.rootView = makeToolbar()
        let size = host.fittingSize
        var origin = CGPoint(x: sel.midX - size.width / 2, y: sel.maxY + 10)
        if origin.y + size.height > bounds.height - 8 {
            origin.y = sel.minY - size.height - 10
            if origin.y < 8 { origin.y = sel.maxY - size.height - 10 }
        }
        origin.x = min(max(8, origin.x), bounds.width - size.width - 8)
        host.frame = CGRect(origin: origin, size: size)
        window?.invalidateCursorRects(for: self)
    }

    private func removeToolbar() {
        toolbarHost?.removeFromSuperview()
        toolbarHost = nil
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Geometry helpers

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), bounds.width), y: min(max(0, p.y), bounds.height))
    }

    private func handlePoints(for rect: CGRect) -> [(Handle, CGPoint)] {
        [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.top, CGPoint(x: rect.midX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.right, CGPoint(x: rect.maxX, y: rect.midY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottom, CGPoint(x: rect.midX, y: rect.maxY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.left, CGPoint(x: rect.minX, y: rect.midY)),
        ]
    }

    private func handleAt(_ p: CGPoint, in rect: CGRect) -> Handle? {
        for (h, pt) in handlePoints(for: rect) where hypot(p.x - pt.x, p.y - pt.y) <= 10 {
            return h
        }
        return nil
    }

    private func cursorFor(handle: Handle) -> NSCursor {
        switch handle {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        default: return .crosshair
        }
    }

    private func resize(anchor: CGRect, handle: Handle, to p: CGPoint) -> CGRect {
        var minX = anchor.minX, minY = anchor.minY, maxX = anchor.maxX, maxY = anchor.maxY
        switch handle {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        }
        return CGRect(corner: CGPoint(x: minX, y: minY), corner: CGPoint(x: maxX, y: maxY))
    }

    private func updateHoveredWindow(at globalCocoa: CGPoint) {
        guard let list = controller?.windowList else { hoveredWindow = nil; return }
        hoveredWindow = list.first(where: { $0.frame.contains(globalCocoa) })
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. Frozen screenshot — drawn with an explicit flip so it is upright in this flipped view.
        ctx.saveGState()
        ctx.interpolationQuality = .high
        AnnotationRenderer.drawImageInFlippedContext(frozen.cgImage, rect: bounds, in: ctx)
        ctx.restoreGState()

        // 2. Dim everything outside the selection.
        NSColor.black.withAlphaComponent(0.42).setFill()
        if let sel = selection {
            let bands = [
                CGRect(x: 0, y: 0, width: bounds.width, height: sel.minY),
                CGRect(x: 0, y: sel.maxY, width: bounds.width, height: bounds.height - sel.maxY),
                CGRect(x: 0, y: sel.minY, width: sel.minX, height: sel.height),
                CGRect(x: sel.maxX, y: sel.minY, width: bounds.width - sel.maxX, height: sel.height),
            ]
            for r in bands where !r.isEmpty { ctx.fill(r) }
            drawSelectionChrome(sel, in: ctx)
        } else {
            ctx.fill(bounds)
            if !isSelected, let win = hoveredWindow {
                let r = localRect(fromGlobalCocoa: win.frame).intersection(bounds)
                if !r.isEmpty {
                    ctx.saveGState()
                    ctx.clip(to: r)
                    AnnotationRenderer.drawImageInFlippedContext(frozen.cgImage, rect: bounds, in: ctx)
                    ctx.restoreGState()
                    NSColor.black.withAlphaComponent(0.10).setFill()
                    ctx.fill(r)
                    let path = NSBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8)
                    path.lineWidth = 3
                    accent.setStroke()
                    path.stroke()
                    drawLabel(win.ownerName + (win.title.isEmpty ? "" : " — \(win.title)"),
                              centeredAbove: CGPoint(x: r.midX, y: r.minY))
                }
            }
        }

        // 3. Hint pill (bottom center), unless it would cover the selection.
        drawHint()

        // 4. Crosshair guides + magnifier while aiming or creating.
        var aiming = !isSelected
        if case .creating = dragMode { aiming = true }
        if aiming {
            drawGuides(in: ctx)
            drawMagnifier(in: ctx)
        }

        // 5. Size badge while dragging out a new selection (selected state draws its own).
        if case .creating = dragMode, let sel = selection {
            drawSizeBadge(for: sel)
        }
    }

    private func drawSelectionChrome(_ sel: CGRect, in ctx: CGContext) {
        // Outer white line with soft shadow for contrast on any background.
        let border = NSBezierPath(rect: sel.insetBy(dx: -0.75, dy: -0.75))
        border.lineWidth = 1.5
        NSColor.white.setStroke()
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 4
        shadow.set()
        border.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()

        // Accent inner hairline.
        let inner = NSBezierPath(rect: sel.insetBy(dx: 0.5, dy: 0.5))
        inner.lineWidth = 1
        accent.withAlphaComponent(0.9).setStroke()
        inner.stroke()

        // Rule-of-thirds guides while adjusting.
        var adjusting = false
        if case .moving = dragMode { adjusting = true }
        if case .resizing = dragMode { adjusting = true }
        if adjusting, sel.width > 60, sel.height > 60 {
            NSColor.white.withAlphaComponent(0.25).setStroke()
            for i in 1...2 {
                let x = sel.minX + sel.width * CGFloat(i) / 3
                let y = sel.minY + sel.height * CGFloat(i) / 3
                let v = NSBezierPath(); v.move(to: CGPoint(x: x, y: sel.minY)); v.line(to: CGPoint(x: x, y: sel.maxY))
                let h = NSBezierPath(); h.move(to: CGPoint(x: sel.minX, y: y)); h.line(to: CGPoint(x: sel.maxX, y: y))
                v.lineWidth = 0.5; h.lineWidth = 0.5
                v.stroke(); h.stroke()
            }
        }

        if isSelected {
            for (_, pt) in handlePoints(for: sel) {
                let r = CGRect(x: pt.x - 4.5, y: pt.y - 4.5, width: 9, height: 9)
                let dot = NSBezierPath(ovalIn: r)
                NSColor.white.setFill()
                dot.fill()
                accent.setStroke()
                dot.lineWidth = 1.5
                dot.stroke()
            }
            drawSizeBadge(for: sel)
        }
    }

    private func drawSizeBadge(for sel: CGRect) {
        let text = "\(Int(sel.width * frozen.scale)) × \(Int(sel.height * frozen.scale)) px"
        var pos = CGPoint(x: sel.minX + 2, y: sel.minY - 26)
        if pos.y < 4 { pos.y = sel.minY + 6 }
        drawPill(text, at: pos)
    }

    private func drawHint() {
        let hint: String
        if isSelected {
            hint = purpose == .recording ? L("overlay.hint_selected_record") : L("overlay.hint_selected")
        } else if purpose == .windowPick {
            hint = L("overlay.hint_window")
        } else if purpose == .recording {
            hint = L("overlay.hint_record")
        } else {
            hint = L("overlay.hint")
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: hint, attributes: attrs)
        let size = str.size()
        let pad: CGFloat = 14
        var rect = CGRect(x: bounds.midX - size.width / 2 - pad, y: bounds.height - 24 - size.height - 14,
                          width: size.width + pad * 2, height: size.height + 14)
        func collides(_ r: CGRect) -> Bool {
            if let sel = selection, sel.insetBy(dx: -12, dy: -12).intersects(r) { return true }
            if let host = toolbarHost, host.frame.insetBy(dx: -12, dy: -12).intersects(r) { return true }
            return false
        }
        if collides(rect) {
            rect.origin.y = 24 // fall back to the top edge
            if collides(rect) { return }
        }
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.black.withAlphaComponent(0.55).setFill()
        path.fill()
        str.draw(at: CGPoint(x: rect.minX + pad, y: rect.minY + 7))
    }

    private func drawLabel(_ text: String, centeredAbove p: CGPoint) {
        guard !text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        var display = text
        if display.count > 60 { display = String(display.prefix(60)) + "…" }
        let str = NSAttributedString(string: display, attributes: attrs)
        let size = str.size()
        let pad: CGFloat = 10
        var rect = CGRect(x: p.x - size.width / 2 - pad, y: p.y - size.height - 22,
                          width: size.width + pad * 2, height: size.height + 10)
        if rect.minY < 4 { rect.origin.y = p.y + 12 }
        rect.origin.x = min(max(4, rect.minX), bounds.width - rect.width - 4)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        accent.withAlphaComponent(0.92).setFill()
        path.fill()
        str.draw(at: CGPoint(x: rect.minX + pad, y: rect.minY + 5))
    }

    @discardableResult
    private func drawPill(_ text: String, at origin: CGPoint, trailingSpace: CGFloat = 0) -> CGRect {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let pad: CGFloat = 8
        var rect = CGRect(x: origin.x, y: origin.y, width: size.width + pad * 2 + trailingSpace, height: size.height + 8)
        rect.origin.x = min(max(2, rect.minX), bounds.width - rect.width - 2)
        rect.origin.y = min(max(2, rect.minY), bounds.height - rect.height - 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor.black.withAlphaComponent(0.72).setFill()
        path.fill()
        str.draw(at: CGPoint(x: rect.minX + pad, y: rect.minY + 4))
        return rect
    }

    private func drawGuides(in ctx: CGContext) {
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let v = NSBezierPath()
        v.move(to: CGPoint(x: mouseLocation.x + 0.5, y: 0))
        v.line(to: CGPoint(x: mouseLocation.x + 0.5, y: bounds.height))
        v.lineWidth = 1
        v.setLineDash([4, 3], count: 2, phase: 0)
        v.stroke()
        let h = NSBezierPath()
        h.move(to: CGPoint(x: 0, y: mouseLocation.y + 0.5))
        h.line(to: CGPoint(x: bounds.width, y: mouseLocation.y + 0.5))
        h.lineWidth = 1
        h.setLineDash([4, 3], count: 2, phase: 0)
        h.stroke()
    }

    private func drawMagnifier(in ctx: CGContext) {
        let scale = frozen.scale
        let px = Int(mouseLocation.x * scale)
        let py = Int(mouseLocation.y * scale)
        guard px >= 0, py >= 0, px < frozen.cgImage.width, py < frozen.cgImage.height else { return }

        let zoomPixels = 19 // odd → centered pixel
        let magSize: CGFloat = 114
        let half = zoomPixels / 2
        let srcRect = CGRect(x: px - half, y: py - half, width: zoomPixels, height: zoomPixels)

        var origin = CGPoint(x: mouseLocation.x + 24, y: mouseLocation.y + 24)
        if origin.x + magSize > bounds.width - 8 { origin.x = mouseLocation.x - magSize - 24 }
        if origin.y + magSize + 40 > bounds.height - 8 { origin.y = mouseLocation.y - magSize - 40 - 24 }
        let magRect = CGRect(x: origin.x, y: origin.y, width: magSize, height: magSize)

        ctx.saveGState()
        NSBezierPath(roundedRect: magRect, xRadius: 10, yRadius: 10).addClip()
        ctx.interpolationQuality = .none
        if let sub = frozen.cgImage.cropped(toPixels: srcRect) {
            // Keep the crop anchored even at the screen edge, where cropping clamps the rect.
            let dx = CGFloat(max(0, -(px - half))) * (magSize / CGFloat(zoomPixels))
            let dy = CGFloat(max(0, -(py - half))) * (magSize / CGFloat(zoomPixels))
            let cell = magSize / CGFloat(zoomPixels)
            let drawRect = CGRect(x: magRect.minX + dx, y: magRect.minY + dy,
                                  width: CGFloat(sub.width) * cell, height: CGFloat(sub.height) * cell)
            AnnotationRenderer.drawImageInFlippedContext(sub, rect: drawRect, in: ctx)
        }
        let cell = magSize / CGFloat(zoomPixels)
        let cx = magRect.minX + CGFloat(half) * cell
        let cy = magRect.minY + CGFloat(half) * cell
        NSColor.white.setStroke()
        let cellPath = NSBezierPath(rect: CGRect(x: cx, y: cy, width: cell, height: cell))
        cellPath.lineWidth = 1.5
        cellPath.stroke()
        ctx.restoreGState()

        let border = NSBezierPath(roundedRect: magRect, xRadius: 10, yRadius: 10)
        border.lineWidth = 2
        accent.setStroke()
        border.stroke()

        // Info line: coordinates + hex color, with a swatch inside the pill's right end.
        let color = bitmap.colorAt(x: px, y: py) ?? .black
        let info = "(\(Int(mouseLocation.x)), \(Int(mouseLocation.y)))  \(color.hexString)"
        let pill = drawPill(info, at: CGPoint(x: magRect.minX, y: magRect.maxY + 6), trailingSpace: 20)
        let swatch = CGRect(x: pill.maxX - 22, y: pill.midY - 7, width: 14, height: 14)
        let sw = NSBezierPath(roundedRect: swatch, xRadius: 3, yRadius: 3)
        color.setFill()
        sw.fill()
        NSColor.white.setStroke()
        sw.lineWidth = 1
        sw.stroke()
    }
}

// MARK: - SwiftUI toolbar shown next to the selection

struct OverlayToolbar: View {
    let purpose: SelectionPurpose
    let sizeText: String
    let onAction: (SelectionAction) -> Void
    let onCancel: () -> Void

    private var primary: SelectionAction {
        switch purpose {
        case .recording: return .record
        case .ocr: return .ocr
        case .pin: return .pin
        case .screenshot, .windowPick: return .capture
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(sizeText)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)

            Divider().frame(height: 18)

            toolButton("camera.fill", L("overlay.capture"), .capture, hint: "↩")
            toolButton("doc.on.doc.fill", L("overlay.copy"), .copy, hint: "⌘C")
            toolButton("record.circle", L("overlay.record"), .record, hint: nil)
            toolButton("pin.fill", L("overlay.pin"), .pin, hint: nil)
            toolButton("text.viewfinder", L("overlay.ocr"), .ocr, hint: nil)

            Divider().frame(height: 18)

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("overlay.cancel_help"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
        .fixedSize()
    }

    @ViewBuilder
    private func toolButton(_ symbol: String, _ label: String, _ action: SelectionAction, hint: String?) -> some View {
        let prominent = action == primary
        Button {
            onAction(action)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                if prominent {
                    Text(label).font(.system(size: 12, weight: .semibold))
                }
            }
            .padding(.horizontal, prominent ? 12 : 8)
            .frame(height: 28)
            .background(
                prominent
                    ? AnyShapeStyle(LinearGradient(colors: [Color(nsColor: Brand.accentTop), Color(nsColor: Brand.accentBottom)],
                                                   startPoint: .top, endPoint: .bottom))
                    : AnyShapeStyle(Color.primary.opacity(0.06)),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .foregroundStyle(prominent ? .white : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hint.map { "\(label)  \($0)" } ?? label)
    }
}
