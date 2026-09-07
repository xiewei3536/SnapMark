import AppKit
import SwiftUI

/// A borderless panel that can become key without activating the app, so its buttons
/// respond to the first click even while another app is frontmost.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// "Pin to screen": floats a capture above all windows — great for referencing designs,
/// error messages, or comparing content while you work.
@MainActor
final class PinWindowController: NSWindowController, NSWindowDelegate {
    private static var pins: [PinWindowController] = []

    private let image: CapturedImage
    private let baseSize: CGSize
    private var zoomFactor: CGFloat = 1

    static func show(image: CapturedImage, near point: CGPoint? = nil) {
        let controller = PinWindowController(image: image, near: point)
        pins.append(controller)
        controller.present()
    }

    static func closeAll() {
        for pin in pins { pin.window?.close() }
    }

    private init(image: CapturedImage, near point: CGPoint?) {
        self.image = image

        var size = image.pointSize
        let maxSide: CGFloat = (NSScreen.main?.visibleFrame.width ?? 1440) * 0.5
        if size.width > maxSide || size.height > maxSide {
            let f = min(maxSide / size.width, maxSide / size.height)
            size = CGSize(width: size.width * f, height: size.height * f)
        }
        baseSize = size

        let panel = KeyablePanel(contentRect: CGRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false // dragging is handled by the content view

        super.init(window: panel)

        let handlers = PinContentView.Handlers(
            close: { [weak self] in self?.window?.close() },
            edit: { [weak self] in
                guard let self else { return }
                self.window?.close()
                EditorWindowController.open(image: self.image, savedURL: nil)
            },
            copy: { [weak self] in
                guard let self else { return }
                Clipboard.copy(image: self.image.cgImage, scale: self.image.scale)
                Toast.show(icon: "doc.on.doc.fill", text: L("toast.copied"))
            },
            save: { [weak self] in self?.saveImage() },
            opacity: { [weak self] value in self?.window?.animator().alphaValue = value },
            zoom: { [weak self] delta in self?.zoom(by: delta) }
        )
        panel.contentView = PinContentView(image: image, handlers: handlers)
        panel.delegate = self

        var origin: CGPoint
        if let p = point {
            origin = CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2)
        } else if let f = NSScreen.main?.visibleFrame {
            origin = CGPoint(x: f.maxX - size.width - 30, y: f.maxY - size.height - 30)
        } else {
            origin = .zero
        }
        // Keep the whole pin on screen.
        let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)) })
            ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            origin.x = min(max(vf.minX, origin.x), vf.maxX - size.width)
            origin.y = min(max(vf.minY, origin.y), vf.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func present() {
        guard let window else { return }
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            window.animator().alphaValue = 1
        }
    }

    private func zoom(by delta: CGFloat) {
        guard let window else { return }
        let newFactor = min(3, max(0.2, zoomFactor * (1 + delta)))
        guard abs(newFactor - zoomFactor) > 0.001 else { return }
        zoomFactor = newFactor
        let newSize = CGSize(width: baseSize.width * newFactor, height: baseSize.height * newFactor)
        let center = window.frame.center
        window.setFrame(CGRect(x: center.x - newSize.width / 2, y: center.y - newSize.height / 2,
                               width: newSize.width, height: newSize.height), display: true)
    }

    private func saveImage() {
        if let url = ImageFile.saveToCaptureFolder(image) {
            HistoryManager.shared.add(fileURL: url, kind: .image)
            Toast.show(icon: "checkmark.circle.fill", text: L("toast.saved"), subtitle: url.lastPathComponent)
        } else {
            Toast.show(icon: "exclamationmark.triangle.fill", text: L("toast.save_failed"))
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.pins.removeAll { $0 === self }
    }
}

// MARK: - Content view (AppKit, so dragging / scrolling / context menus are reliable)

final class PinContentView: NSView {
    struct Handlers {
        let close: () -> Void
        let edit: () -> Void
        let copy: () -> Void
        let save: () -> Void
        let opacity: (CGFloat) -> Void
        let zoom: (CGFloat) -> Void
    }

    private let image: CapturedImage
    private let handlers: Handlers
    private var toolbarHost: NSHostingView<PinToolbar>?
    private var hintHost: NSHostingView<PinHint>?
    private var trackingArea: NSTrackingArea?
    private var hovering = false {
        didSet { if hovering != oldValue { updateHoverUI() } }
    }

    init(image: CapturedImage, handlers: Handlers) {
        self.image = image
        self.handlers = handlers
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        if let layer {
            layer.contents = image.cgImage
            layer.contentsGravity = .resizeAspect
            layer.minificationFilter = .trilinear
            layer.cornerRadius = 10
            layer.masksToBounds = true
            layer.borderWidth = 2
            layer.borderColor = Brand.accent.withAlphaComponent(0.45).cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            handlers.close()
            return
        }
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        handlers.zoom(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.004 : 0.03))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addClosureItem(L("pin.edit"), symbol: "pencil.tip.crop.circle", owner: self, handler: handlers.edit)
        menu.addClosureItem(L("pin.copy"), symbol: "doc.on.doc", owner: self, handler: handlers.copy)
        menu.addClosureItem(L("pin.save"), symbol: "square.and.arrow.down", owner: self, handler: handlers.save)
        let opacityItem = NSMenuItem(title: L("pin.opacity"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for pct in [100, 85, 70, 50] {
            let opacity = handlers.opacity
            sub.addClosureItem("\(pct)%", owner: self) { opacity(CGFloat(pct) / 100) }
        }
        opacityItem.submenu = sub
        menu.addItem(opacityItem)
        menu.addItem(.separator())
        menu.addClosureItem(L("pin.close"), symbol: "xmark.circle", owner: self, handler: handlers.close)
        return menu
    }

    @objc func runClosure(_ sender: NSMenuItem) {
        (sender.representedObject as? ClosureBox)?.closure()
    }

    override func layout() {
        super.layout()
        positionOverlays()
    }

    private func updateHoverUI() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        layer?.borderColor = Brand.accent.withAlphaComponent(hovering ? 0.95 : 0.45).cgColor
        CATransaction.commit()

        if hovering && toolbarHost == nil {
            let toolbar = NSHostingView(rootView: PinToolbar(onEdit: handlers.edit, onCopy: handlers.copy, onClose: handlers.close))
            toolbar.frame.size = toolbar.fittingSize
            addSubview(toolbar)
            toolbarHost = toolbar

            let hint = NSHostingView(rootView: PinHint())
            hint.frame.size = hint.fittingSize
            addSubview(hint)
            hintHost = hint
            positionOverlays()
        }
        toolbarHost?.isHidden = !hovering
        hintHost?.isHidden = !hovering
    }

    private func positionOverlays() {
        if let host = toolbarHost {
            host.frame.origin = CGPoint(x: bounds.width - host.frame.width - 8, y: 8)
        }
        if let hint = hintHost {
            hint.frame.origin = CGPoint(x: bounds.width - hint.frame.width - 8,
                                        y: bounds.height - hint.frame.height - 8)
        }
    }
}

struct PinToolbar: View {
    let onEdit: () -> Void
    let onCopy: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            pinButton("pencil.tip.crop.circle", help: L("pin.edit"), action: onEdit)
            pinButton("doc.on.doc", help: L("pin.copy"), action: onCopy)
            pinButton("xmark.circle.fill", help: L("pin.close"), action: onClose)
        }
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .fixedSize()
    }

    private func pinButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct PinHint: View {
    var body: some View {
        Text(L("pin.hint"))
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .fixedSize()
    }
}
