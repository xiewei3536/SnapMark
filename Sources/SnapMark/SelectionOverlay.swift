import AppKit
import Combine
import SwiftUI

/// What the user launched the selection overlay for.
enum SelectionPurpose {
    case screenshot
    case recording
    case ocr
    case pin
    case windowPick

    /// Screenshots are annotated right on the frozen screen before they leave the overlay.
    var canAnnotate: Bool { self == .screenshot || self == .windowPick }
}

/// The action chosen from the overlay toolbar or keyboard.
enum SelectionAction {
    case capture // finish: copy and/or save per preferences
    case copy, save, saveAs, edit, record, pin, ocr
}

struct SelectionResult {
    let screen: NSScreen
    let localRect: CGRect // top-left origin, points, relative to the screen
    let frozen: CapturedImage
    let action: SelectionAction
    let windowID: CGWindowID? // set when the selection is exactly a clicked window
    /// That window captured on its own when it was clicked (clean edges, nothing overlapping).
    let windowImage: CapturedImage?
    /// The annotation session, in the frozen screen's pixel space (nil when nothing was drawn).
    let annotations: EditorState?

    var globalCocoaRect: CGRect {
        CGRect(x: screen.frame.minX + localRect.minX,
               y: screen.frame.maxY - localRect.maxY,
               width: localRect.width, height: localRect.height)
    }

    /// The selection in the frozen image's pixels.
    var pixelRect: CGRect {
        let s = frozen.scale
        return CGRect(x: localRect.minX * s, y: localRect.minY * s,
                      width: localRect.width * s, height: localRect.height * s).integral
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

    func confirm(screen: NSScreen, localRect: CGRect, frozen: CapturedImage, action: SelectionAction,
                 windowID: CGWindowID? = nil, windowImage: CapturedImage? = nil, annotations: EditorState? = nil) {
        SelectionController.lastRegion = (screen.frame, localRect)
        finishSession(with: SelectionResult(screen: screen, localRect: localRect, frozen: frozen, action: action,
                                            windowID: windowID, windowImage: windowImage, annotations: annotations))
    }

    /// Called when a drag starts on one screen: other screens clear their state.
    func selectionBegan(on window: OverlayWindow) {
        for w in windows where w !== window { w.overlayView?.clearSelection() }
    }

    /// Whether a screen other than `window`'s matches (with several displays, the screen that holds
    /// the chosen area keeps the keyboard, and its marks can't be wiped by a click elsewhere).
    func otherOverlay(than window: NSWindow?, where test: (OverlayView) -> Bool) -> Bool {
        windows.contains { $0 !== window && ($0.overlayView.map(test) ?? false) }
    }

    private func finishSession(with result: SelectionResult?) {
        let done = completion
        completion = nil
        for w in windows {
            w.overlayView?.rememberStyle()
            w.orderOut(nil)
        }
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

    /// ⌘-shortcuts reach the window before the main menu, so ⌘Z / ⌘C act on the capture.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if overlayView?.handleKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        overlayView?.requestCancel()
    }

    /// While typing, sit just below pop-up menu level so the input method's candidate window
    /// (注音／拼音 選字窗) shows above the overlay; screen-saver level otherwise covers everything.
    func setTypingLevel(_ typing: Bool) {
        level = typing ? NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1) : .screenSaver
    }
}

/// Published bits the toolbar shows.
final class OverlaySession: ObservableObject {
    /// The annotation tool in use; nil while the region itself is being adjusted.
    @Published var activeTool: Tool?
    @Published var sizeText = ""
}

/// Transparent top layer for the overlay's UI chrome (selection frame, handles, magnifier, hints);
/// sits above the annotation canvas and never takes clicks.
final class OverlayChromeView: NSView {
    var drawer: ((CGContext) -> Void)?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawer?(ctx)
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

    private var selection: CGRect? { didSet { selectionDidChange() } }
    private var isSelected = false // selection finalized (adjustable, toolbar showing)
    private var dragMode: DragMode = .none
    private var mouseLocation: CGPoint = .zero
    private var hoveredWindow: WindowInfo?
    private var toolbarHost: NSHostingView<AnyView>?
    private var trackingArea: NSTrackingArea?
    private let chrome = OverlayChromeView()

    // Annotation (screenshot purposes only).
    private(set) var annotation: EditorState?
    private(set) var canvas: AnnotationCanvasView?
    let session = OverlaySession()
    private var snappedWindow: WindowInfo? {
        didSet { if snappedWindow?.windowID != oldValue?.windowID { captureSnappedWindow() } }
    }
    /// The snapped window captured on its own right when it was clicked (used when nothing is drawn).
    private var snappedImage: CapturedImage?
    private var snapTask: Task<Void, Never>?
    /// Esc with marks on screen asks for a second press instead of throwing them away.
    private var escArmedUntil = Date.distantPast
    private var transientHint: String?
    private var toolbarHint: String? { didSet { if toolbarHint != oldValue { chrome.needsDisplay = true } } }
    private var cancellables: Set<AnyCancellable> = []
    private var toolbarLayoutPending = false

    private let accent = Brand.accent

    /// Annotation style carries over from one capture to the next.
    private struct RememberedStyle {
        var color = RGBA.presets[0]
        var lineWidthPt: CGFloat = 4
        var fontSizePt: CGFloat = 22
        var textStyle = TextStyle()
        var mosaicBlur = false
    }
    private static var remembered = RememberedStyle()

    init(frame: NSRect, screen: NSScreen, frozen: CapturedImage, controller: SelectionController) {
        self.overlayScreen = screen
        self.frozen = frozen
        self.bitmap = NSBitmapImageRep(cgImage: frozen.cgImage)
        self.controller = controller
        super.init(frame: frame)
        wantsLayer = true
        chrome.frame = bounds
        chrome.autoresizingMask = [.width, .height]
        chrome.drawer = { [weak self] ctx in self?.drawChrome(ctx) }
        addSubview(chrome)
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
        guard !isSelected else { return } // the selected state drives the cursor from mouseMoved
        addCursorRect(bounds, cursor: .crosshair)
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

    private func pixelRect(_ r: CGRect) -> CGRect {
        let s = frozen.scale
        return CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s)
    }

    // MARK: State

    private var annotating: Bool { session.activeTool != nil }
    var hasAnnotations: Bool { !(annotation?.annotations.isEmpty ?? true) }
    var isEscArmed: Bool { Date() <= escArmedUntil }
    var hasChosenArea: Bool { isSelected && selection != nil }

    private func captureSnappedWindow() {
        snapTask?.cancel()
        snappedImage = nil
        guard let id = snappedWindow?.windowID else { return }
        snapTask = Task { @MainActor [weak self] in
            let image = try? await CaptureEngine.captureWindow(windowID: id)
            guard let self, !Task.isCancelled, self.snappedWindow?.windowID == id else { return }
            self.snappedImage = image
        }
    }

    /// Esc / ✕: leave at once, unless that would throw away marks — then the first press only warns.
    func requestCancel(force: Bool = false) {
        if !force, hasAnnotations, Date() > escArmedUntil {
            escArmedUntil = Date().addingTimeInterval(2.5)
            transientHint = L("overlay.esc_again")
            chrome.needsDisplay = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, Date() >= self.escArmedUntil else { return }
                self.transientHint = nil
                self.chrome.needsDisplay = true
            }
            return
        }
        Task { @MainActor in SelectionController.shared.cancel() }
    }

    func clearSelection() {
        selection = nil
        isSelected = false
        dragMode = .none
        snappedWindow = nil
        removeToolbar()
        removeAnnotationLayer()
        window?.invalidateCursorRects(for: self)
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

    private func selectionDidChange() {
        if let sel = selection {
            session.sizeText = "\(Int(sel.width * frozen.scale)) × \(Int(sel.height * frozen.scale))"
        }
        layoutCanvas()
        repositionToolbar()
        needsDisplay = true
        chrome.needsDisplay = true
    }

    /// Persists the annotation style for the next capture.
    func rememberStyle() {
        guard let st = annotation else { return }
        Self.remembered = RememberedStyle(color: st.color, lineWidthPt: st.lineWidthPt, fontSizePt: st.fontSizePt,
                                          textStyle: st.textStyle, mosaicBlur: st.mosaicBlur)
    }

    // MARK: Annotation layer

    private func installAnnotationLayer() {
        guard purpose.canAnnotate, annotation == nil else { return }
        let st = EditorState(image: frozen, originalURL: nil)
        let style = Self.remembered
        st.color = style.color
        st.lineWidthPt = style.lineWidthPt
        st.fontSizePt = style.fontSizePt
        st.textStyle = style.textStyle
        st.mosaicBlur = style.mosaicBlur
        let cv = AnnotationCanvasView(state: st)
        cv.isInteractive = false
        cv.onTextEditingChanged = { [weak self] typing in
            (self?.window as? OverlayWindow)?.setTypingLevel(typing)
        }
        addSubview(cv, positioned: .below, relativeTo: chrome)
        annotation = st
        canvas = cv
        st.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.annotationDidChange() }
            .store(in: &cancellables)
        layoutCanvas()
    }

    private func removeAnnotationLayer() {
        cancellables.removeAll()
        canvas?.removeFromSuperview()
        canvas = nil
        annotation = nil
        session.activeTool = nil
    }

    private func layoutCanvas() {
        guard let canvas, let sel = selection else { return }
        canvas.frame = sel
        canvas.pixelOrigin = CGPoint(x: sel.minX * frozen.scale, y: sel.minY * frozen.scale)
        annotation?.region = pixelRect(sel)
    }

    /// The toolbar's size only depends on which style controls it shows; re-measure when that changes.
    private var toolbarSignature = ""

    private func annotationDidChange() {
        guard let st = annotation else { return }
        let signature = "\(String(describing: session.activeTool))|\(st.selectedID != nil)|\(st.editingTextID != nil)|\(String(describing: st.inspected?.kind))"
        if signature != toolbarSignature {
            toolbarSignature = signature
            scheduleToolbarLayout()
        }
    }

    /// Switches the annotation tool; picking the active tool again (or nil) returns to adjusting the region.
    func setTool(_ tool: Tool?) {
        guard purpose.canAnnotate, isSelected, let st = annotation else { return }
        if let tool, tool != session.activeTool {
            st.tool = tool
            session.activeTool = tool
            canvas?.isInteractive = true
        } else {
            st.commitTextEditing()
            st.selectedID = nil
            session.activeTool = nil
            canvas?.isInteractive = false
        }
        window?.invalidateCursorRects(for: self)
        scheduleToolbarLayout()
        chrome.needsDisplay = true
    }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) {
        // Follow the pointer between screens only while aiming; once an area is chosen, keys stay with it.
        guard !SelectionController.shared.otherOverlay(than: window, where: { $0.hasChosenArea }) else { return }
        window?.makeKey()
    }

    override func mouseMoved(with event: NSEvent) {
        mouseLocation = convert(event.locationInWindow, from: nil)
        if !isSelected {
            let previous = hoveredWindow?.windowID
            updateHoveredWindow(at: NSEvent.mouseLocation)
            NSCursor.crosshair.set()
            if hoveredWindow?.windowID != previous { needsDisplay = true } // window highlight
        } else if let sel = selection {
            if let host = toolbarHost, host.frame.contains(mouseLocation) {
                NSCursor.arrow.set()
            } else if annotating {
                if !sel.contains(mouseLocation) { NSCursor.arrow.set() } // inside: the canvas decides
            } else if let h = handleAt(mouseLocation, in: sel) {
                cursorFor(handle: h).set()
            } else if sel.contains(mouseLocation) {
                NSCursor.openHand.set()
            } else {
                (hasAnnotations ? NSCursor.arrow : NSCursor.crosshair).set()
            }
        }
        // Guides and magnifier follow the pointer while aiming; the toolbar caption follows it over the bar.
        if !isSelected || toolbarHint != nil { chrome.needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouseLocation = p
        // Marks on another screen are never thrown away by a stray click here.
        if SelectionController.shared.otherOverlay(than: window, where: { $0.hasAnnotations }) { return }
        window?.makeKey()
        if let w = window as? OverlayWindow {
            Task { @MainActor in SelectionController.shared.selectionBegan(on: w) }
        }
        if isSelected, let sel = selection {
            if annotating {
                // A click beside the region while drawing just finishes typing / drops the selection.
                annotation?.commitTextEditing()
                annotation?.selectedID = nil
                return
            }
            if event.clickCount >= 2, sel.contains(p) {
                performAction(defaultAction) // double-click = done
                return
            }
            if let h = handleAt(p, in: sel) {
                dragMode = .resizing(handle: h, anchor: sel)
                return
            }
            if sel.insetBy(dx: -4, dy: -4).contains(p) {
                dragMode = .moving(grabOffset: CGPoint(x: p.x - sel.minX, y: p.y - sel.minY))
                NSCursor.closedHand.set()
                return
            }
            // Once something is drawn the region stays (it can still be moved and resized).
            if hasAnnotations { return }
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
            sel.origin = CGPoint(x: (p.x - offset.x).rounded(), y: (p.y - offset.y).rounded())
            sel.origin.x = min(max(0, sel.origin.x), bounds.width - sel.width)
            sel.origin.y = min(max(0, sel.origin.y), bounds.height - sel.height)
            selection = sel
        case .resizing(let handle, let anchor):
            selection = resize(anchor: anchor, handle: handle, to: p)
        case .none:
            break
        }
        chrome.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer { dragMode = .none; needsDisplay = true; chrome.needsDisplay = true }

        switch dragMode {
        case .creating(let start):
            let dist = hypot(p.x - start.x, p.y - start.y)
            if dist < 4 {
                // A plain click: act on the hovered window.
                guard let win = hoveredWindow else {
                    selection = nil
                    return
                }
                switch purpose {
                case .recording, .screenshot, .windowPick:
                    // Snap the selection to the window; a screenshot of exactly that window later
                    // uses the clean window capture (no overlapping windows, crisp rounded corners).
                    let full = localRect(fromGlobalCocoa: win.frame).integral
                    let rect = full.intersection(bounds)
                    guard rect.width >= 4, rect.height >= 4 else { return }
                    selection = rect
                    snappedWindow = (purpose != .recording && rect == full) ? win : nil
                    enterSelectedState()
                case .ocr, .pin:
                    confirmWholeWindow(win, action: defaultAction)
                }
            } else if let sel = selection, sel.width >= 4, sel.height >= 4 {
                selection = sel.integral
                snappedWindow = nil
                enterSelectedState()
            } else {
                clearSelection()
            }
        case .moving, .resizing:
            if let sel = selection { selection = sel.integral }
            if let win = snappedWindow, selection != localRect(fromGlobalCocoa: win.frame).integral {
                snappedWindow = nil
            }
            if let sel = selection, sel.contains(p) { NSCursor.openHand.set() }
        case .none:
            break
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // Right-click backs out of an untouched selection (pick again); with annotations it does nothing.
        guard isSelected, !hasAnnotations, !annotating else { return }
        clearSelection()
        updateHoveredWindow(at: NSEvent.mouseLocation)
        chrome.needsDisplay = true
    }

    private func enterSelectedState() {
        isSelected = true
        hoveredWindow = nil
        installAnnotationLayer()
        installToolbarIfNeeded()
        window?.invalidateCursorRects(for: self)
        selectionDidChange()
    }

    // MARK: Keyboard

    private typealias Key = EditorState.Key

    func handleKeyDown(_ event: NSEvent) {
        let flags = EditorState.cleanFlags(event)
        guard !flags.contains(.command) else { return } // ⌘-keys go through handleKeyEquivalent
        let code = event.keyCode
        switch code {
        case Key.esc:
            requestCancel()
            return
        case Key.ret, Key.enter:
            if isSelected { performAction(defaultAction) }
            return
        default:
            break
        }
        guard isSelected else { return }
        if let st = annotation, st.handleAnnotationKey(code: code, flags: flags) { return }
        switch code {
        case Key.left, Key.right, Key.down, Key.up:
            // Arrows nudge the region (a selected annotation took them above).
            guard !annotating, var sel = selection else { return }
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            switch code {
            case Key.left: sel.origin.x -= step
            case Key.right: sel.origin.x += step
            case Key.down: sel.origin.y += step
            default: sel.origin.y -= step
            }
            sel.origin.x = min(max(0, sel.origin.x), bounds.width - sel.width)
            sel.origin.y = min(max(0, sel.origin.y), bounds.height - sel.height)
            selection = sel
            if let win = snappedWindow, sel != localRect(fromGlobalCocoa: win.frame).integral { snappedWindow = nil }
        default:
            if flags.isEmpty, purpose.canAnnotate, let tool = EditorState.toolKeys[code], tool != .crop {
                setTool(tool)
            }
        }
    }

    /// ⌘-shortcuts. Returns false to let the menu / text view have the key.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = EditorState.cleanFlags(event)
        guard flags.contains(.command) else { return false }
        let code = event.keyCode

        if let st = annotation, st.editingTextID != nil {
            switch code {
            case Key.z where flags == [.command]:
                if canvas?.undoTyping() != true { st.undo() }
                return true
            case Key.z where flags == [.command, .shift]:
                if canvas?.redoTyping() != true { st.redo() }
                return true
            case Key.c where canvas?.hasTextSelection == true:
                return false // copy the selected text
            case Key.s, Key.c, Key.e, Key.ret, Key.enter:
                st.commitTextEditing() // finish typing, then act on the capture below
            default:
                return st.handleTextStyleShortcut(code: code, flags: flags) ? true : false
            }
        }
        guard isSelected else { return false }
        switch (code, flags) {
        case (Key.c, [.command]): performAction(.copy); return true
        case (Key.s, [.command]): performAction(purpose.canAnnotate ? .save : defaultAction); return true
        case (Key.s, [.command, .shift]) where purpose.canAnnotate: performAction(.saveAs); return true
        case (Key.e, [.command]) where purpose.canAnnotate: performAction(.edit); return true
        case (Key.ret, [.command]), (Key.enter, [.command]): performAction(defaultAction); return true
        default:
            return annotation?.handleAnnotationKey(code: code, flags: flags) ?? false
        }
    }

    // MARK: Actions

    func performAction(_ action: SelectionAction) {
        guard let sel = selection?.integral, sel.width >= 2, sel.height >= 2 else { return }
        annotation?.commitTextEditing()
        removeToolbar()
        var windowID: CGWindowID?
        var windowImage: CapturedImage?
        if let win = snappedWindow, sel == localRect(fromGlobalCocoa: win.frame).integral {
            windowID = win.windowID
            windowImage = snappedImage
        }
        let session = hasAnnotations ? annotation : nil
        Task { @MainActor in
            SelectionController.shared.confirm(screen: overlayScreen, localRect: sel, frozen: frozen, action: action,
                                               windowID: windowID, windowImage: windowImage, annotations: session)
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

    private func installToolbarIfNeeded() {
        guard toolbarHost == nil else { return }
        let onAction: (SelectionAction) -> Void = { [weak self] action in self?.performAction(action) }
        let onCancel: () -> Void = { [weak self] in self?.requestCancel(force: true) }
        let onHint: (String?) -> Void = { [weak self] hint in self?.toolbarHint = hint }
        let root: AnyView
        if purpose.canAnnotate, let st = annotation {
            root = AnyView(AnnotateToolbar(state: st, session: session,
                                           onTool: { [weak self] tool in self?.setTool(tool) },
                                           onAction: onAction, onCancel: onCancel, onHint: onHint))
        } else {
            root = AnyView(ActionToolbar(purpose: purpose, session: session,
                                         onAction: onAction, onCancel: onCancel, onHint: onHint))
        }
        let host = NSHostingView(rootView: root)
        host.frame.size = host.fittingSize
        addSubview(host) // above the chrome
        toolbarHost = host
    }

    private func scheduleToolbarLayout() {
        guard !toolbarLayoutPending else { return }
        toolbarLayoutPending = true
        DispatchQueue.main.async { [weak self] in
            self?.toolbarLayoutPending = false
            self?.repositionToolbar()
        }
    }

    /// Below the selection, right-aligned; above it when there is no room; inside as a last resort.
    private func repositionToolbar() {
        guard let host = toolbarHost, let sel = selection else { return }
        let size = host.fittingSize
        let gap: CGFloat = 8
        var origin = CGPoint(x: sel.maxX - size.width, y: sel.maxY + gap)
        if origin.y + size.height > bounds.height - 6 {
            origin.y = sel.minY - size.height - gap
            if origin.y < 6 { origin.y = sel.maxY - size.height - gap }
        }
        origin.x = min(max(6, origin.x), bounds.width - size.width - 6)
        let frame = CGRect(origin: origin, size: size).integral
        if host.frame != frame { host.frame = frame }
        chrome.needsDisplay = true
    }

    private func removeToolbar() {
        toolbarHost?.removeFromSuperview()
        toolbarHost = nil
        toolbarHint = nil
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
        let map: [Handle: AnnotationHandle] = [
            .topLeft: .topLeft, .top: .top, .topRight: .topRight, .right: .right,
            .bottomRight: .bottomRight, .bottom: .bottom, .bottomLeft: .bottomLeft, .left: .left,
        ]
        return AnnotationCanvasView.resizeCursor(for: map[handle] ?? .topLeft)
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

    // MARK: Drawing — the frozen screen, dimming and window highlight (UI chrome is drawn above)

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
    }

    /// Everything drawn above the annotation canvas.
    private func drawChrome(_ ctx: CGContext) {
        if let sel = selection { drawSelectionChrome(sel, in: ctx) }

        drawHint()

        // Crosshair guides + magnifier while aiming or creating.
        var aiming = !isSelected
        if case .creating = dragMode { aiming = true }
        if aiming {
            drawGuides(in: ctx)
            drawMagnifier(in: ctx)
        }

        drawToolbarHint()
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

        // Accent hairline just outside the image (the canvas covers the inside).
        let inner = NSBezierPath(rect: sel.insetBy(dx: -2, dy: -2))
        inner.lineWidth = 1
        accent.withAlphaComponent(annotating ? 0.95 : 0.6).setStroke()
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

        if isSelected, !annotating {
            for (_, pt) in handlePoints(for: sel) {
                let r = CGRect(x: pt.x - 4.5, y: pt.y - 4.5, width: 9, height: 9)
                let dot = NSBezierPath(ovalIn: r)
                NSColor.white.setFill()
                dot.fill()
                accent.setStroke()
                dot.lineWidth = 1.5
                dot.stroke()
            }
        }
        if isSelected || { if case .creating = dragMode { return true }; return false }() {
            drawSizeBadge(for: sel)
        }
    }

    private func drawSizeBadge(for sel: CGRect) {
        var text = "\(Int(sel.width * frozen.scale)) × \(Int(sel.height * frozen.scale)) px"
        if snappedWindow != nil, isSelected { text += "  ·  " + L("overlay.window_snapped") }
        var pos = CGPoint(x: sel.minX + 2, y: sel.minY - 26)
        if pos.y < 4 { pos.y = sel.minY + 6 }
        drawPill(text, at: pos)
    }

    private func drawHint() {
        var hint: String
        if isSelected {
            if purpose == .recording {
                hint = L("overlay.hint_selected_record")
            } else if purpose.canAnnotate {
                hint = annotating ? L("overlay.hint_annotating") : L("overlay.hint_selected_annotate")
            } else {
                hint = L("overlay.hint_selected")
            }
        } else if purpose == .windowPick {
            hint = L("overlay.hint_window")
        } else if purpose == .recording {
            hint = L("overlay.hint_record")
        } else {
            hint = L("overlay.hint")
        }
        if let transientHint { hint = transientHint }
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
            if let host = toolbarHost, host.frame.insetBy(dx: -12, dy: -40).intersects(r) { return true }
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

    /// Caption for the toolbar button under the pointer (tooltips can't show above the overlay).
    private func drawToolbarHint() {
        guard let text = toolbarHint, !text.isEmpty, let host = toolbarHost else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        var rect = CGRect(x: 0, y: 0, width: size.width + 18, height: size.height + 8)
        let localMouse = mouseLocation
        rect.origin.x = min(max(host.frame.minX, localMouse.x - rect.width / 2), host.frame.maxX - rect.width)
        rect.origin.y = host.frame.maxY + 6
        if rect.maxY > bounds.height - 4 { rect.origin.y = host.frame.minY - rect.height - 6 }
        rect.origin.x = min(max(4, rect.minX), bounds.width - rect.width - 4)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.black.withAlphaComponent(0.78).setFill()
        path.fill()
        str.draw(at: CGPoint(x: rect.minX + 9, y: rect.minY + 4))
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

// MARK: - Toolbars (SwiftUI)

/// One toolbar button. Tooltips can't appear above the overlay, so hovering reports a caption instead.
private struct BarButton: View {
    let symbol: String
    var title: String? = nil
    var isActive = false
    var isProminent = false
    var disabled = false
    let hint: String
    let onHint: (String?) -> Void
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 12.5, weight: .semibold))
                if let title { Text(title).font(.system(size: 12, weight: .semibold)).fixedSize() }
            }
            .padding(.horizontal, title == nil ? 0 : 11)
            .frame(minWidth: 28, minHeight: 28)
            .background(background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .foregroundStyle(isActive || isProminent ? Color.white : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .onHover { inside in
            hovering = inside
            onHint(inside ? hint : nil)
        }
    }

    private var background: AnyShapeStyle {
        if isActive || isProminent { return AnyShapeStyle(accentGradient) }
        return AnyShapeStyle(Color.primary.opacity(hovering ? 0.12 : 0.0))
    }
}

private struct BarDivider: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1, height: 18) }
}

private extension View {
    func barBackground() -> some View {
        self
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.16)))
            .shadow(color: .black.opacity(0.32), radius: 12, y: 4)
    }
}

/// Screenshot toolbar: annotation tools, undo/redo, output actions. A style row (colors, sizes,
/// text options) appears beneath it while a tool or an annotation is active.
struct AnnotateToolbar: View {
    @ObservedObject var state: EditorState
    @ObservedObject var session: OverlaySession
    let onTool: (Tool) -> Void
    let onAction: (SelectionAction) -> Void
    let onCancel: () -> Void
    let onHint: (String?) -> Void

    static let tools: [Tool] = [.select, .pen, .highlighter, .line, .arrow, .rect, .ellipse, .text, .mosaic, .badge]

    private var showsStyleRow: Bool {
        (session.activeTool != nil && session.activeTool != .select) || state.selectedID != nil || state.editingTextID != nil
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 3) {
                ForEach(Self.tools) { tool in
                    BarButton(symbol: tool.symbol, isActive: session.activeTool == tool,
                              hint: L(tool.labelKey) + (tool.shortcutKey.map { "  \($0.uppercased())" } ?? ""),
                              onHint: onHint) { onTool(tool) }
                }
                BarDivider().padding(.horizontal, 3)
                BarButton(symbol: "arrow.uturn.backward", disabled: !state.canUndo, hint: L("editor.undo"),
                          onHint: onHint) { state.undo() }
                BarButton(symbol: "arrow.uturn.forward", disabled: !state.canRedo, hint: L("editor.redo"),
                          onHint: onHint) { state.redo() }
                BarDivider().padding(.horizontal, 3)
                BarButton(symbol: "pin", hint: L("overlay.pin"), onHint: onHint) { onAction(.pin) }
                BarButton(symbol: "text.viewfinder", hint: L("overlay.ocr"), onHint: onHint) { onAction(.ocr) }
                BarButton(symbol: "record.circle", hint: L("overlay.record"), onHint: onHint) { onAction(.record) }
                BarButton(symbol: "macwindow.badge.plus", hint: L("overlay.edit") + "  ⌘E", onHint: onHint) { onAction(.edit) }
                BarButton(symbol: "square.and.arrow.down", hint: L("overlay.save") + "  ⌘S", onHint: onHint) { onAction(.save) }
                BarDivider().padding(.horizontal, 3)
                BarButton(symbol: "xmark", hint: L("overlay.cancel_help"), onHint: onHint, action: onCancel)
                BarButton(symbol: "doc.on.doc", hint: L("overlay.copy") + "  ⌘C", onHint: onHint) { onAction(.copy) }
                BarButton(symbol: "checkmark", title: L("overlay.done"), isProminent: true,
                          hint: L("overlay.done_help") + "  ↩", onHint: onHint) { onAction(.capture) }
            }
            .barBackground()

            if showsStyleRow {
                AnnotationStyleBar(state: state, compact: true, onHint: onHint)
                    .padding(.horizontal, 4)
                    .barBackground()
            }
        }
        .fixedSize()
    }
}

/// Toolbar for recording / OCR / pin selections (no annotation).
struct ActionToolbar: View {
    let purpose: SelectionPurpose
    @ObservedObject var session: OverlaySession
    let onAction: (SelectionAction) -> Void
    let onCancel: () -> Void
    let onHint: (String?) -> Void

    private var primary: SelectionAction {
        switch purpose {
        case .recording: return .record
        case .ocr: return .ocr
        case .pin: return .pin
        case .screenshot, .windowPick: return .capture
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(session.sizeText)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            BarDivider()
            item("camera.fill", L("overlay.capture"), .capture, hint: "↩")
            item("doc.on.doc.fill", L("overlay.copy"), .copy, hint: "⌘C")
            item("record.circle", L("overlay.record"), .record, hint: nil)
            item("pin.fill", L("overlay.pin"), .pin, hint: nil)
            item("text.viewfinder", L("overlay.ocr"), .ocr, hint: nil)
            BarDivider()
            BarButton(symbol: "xmark", hint: L("overlay.cancel_help"), onHint: onHint, action: onCancel)
        }
        .barBackground()
        .fixedSize()
    }

    private func item(_ symbol: String, _ label: String, _ action: SelectionAction, hint: String?) -> some View {
        let prominent = action == primary
        return BarButton(symbol: symbol, title: prominent ? label : nil, isProminent: prominent,
                         hint: hint.map { "\(label)  \($0)" } ?? label, onHint: onHint) { onAction(action) }
    }
}
