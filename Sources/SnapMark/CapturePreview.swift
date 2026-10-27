import AppKit
import SwiftUI

/// The optional floating thumbnail shown after a capture (like macOS's own screenshot preview):
/// slides in at the bottom-right corner and leaves by itself. Click to annotate, drag it into any
/// app, or use its quick buttons. Nothing to close.
@MainActor
enum CapturePreview {
    private static var current: CapturePreviewController?

    static func show(_ capture: AppCoordinator.ResolvedCapture, savedURL: URL?, copied: Bool) {
        current?.dismiss(animated: false)
        let controller = CapturePreviewController(capture: capture, savedURL: savedURL, copied: copied)
        current = controller
        controller.present()
    }

    fileprivate static func didDismiss(_ controller: CapturePreviewController) {
        if current === controller { current = nil }
    }
}

@MainActor
final class CapturePreviewController: NSObject {
    private let capture: AppCoordinator.ResolvedCapture
    private let savedURL: URL?
    private let panel: KeyablePanel
    private var dismissWork: DispatchWorkItem?
    private var finalFrame: CGRect = .zero
    private var dismissed = false

    init(capture: AppCoordinator.ResolvedCapture, savedURL: URL?, copied: Bool) {
        self.capture = capture
        self.savedURL = savedURL

        let image = capture.image
        let maxSize = CGSize(width: 220, height: 150)
        let pt = image.pointSize
        let fit = min(maxSize.width / max(pt.width, 1), maxSize.height / max(pt.height, 1), 1)
        let size = CGSize(width: max(90, (pt.width * fit).rounded()), height: max(56, (pt.height * fit).rounded()))

        panel = KeyablePanel(contentRect: CGRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        super.init()

        let content = PreviewContentView(image: image, savedURL: savedURL, caption: Self.caption(saved: savedURL, copied: copied))
        content.onOpen = { [weak self] in self?.openEditor() }
        content.onCopy = { [weak self] in self?.copy() }
        content.onPin = { [weak self] in self?.pin() }
        content.onReveal = { [weak self] in self?.reveal() }
        content.onClose = { [weak self] in self?.dismiss(animated: true) }
        content.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        panel.contentView = content
    }

    /// For the self-test: the thumbnail's content, laid out at its final size but never shown.
    func contentForTesting() -> NSView? {
        panel.contentView?.frame = CGRect(origin: .zero, size: panel.frame.size)
        return panel.contentView
    }

    private static func caption(saved: URL?, copied: Bool) -> String {
        switch (saved != nil, copied) {
        case (true, true): return L("toast.copied_saved")
        case (true, false): return L("toast.saved")
        default: return L("toast.copied")
        }
    }

    func present() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let size = panel.frame.size
        finalFrame = CGRect(x: vf.maxX - size.width - 18, y: vf.minY + 18, width: size.width, height: size.height)
        panel.setFrame(finalFrame.offsetBy(dx: 40, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }
        scheduleDismiss(after: 6)
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss(animated: true) }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func hoverChanged(_ inside: Bool) {
        if inside { dismissWork?.cancel() } else { scheduleDismiss(after: 3) }
    }

    func dismiss(animated: Bool) {
        guard !dismissed else { return }
        dismissed = true
        dismissWork?.cancel()
        CapturePreview.didDismiss(self)
        let panel = self.panel
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().setFrame(panel.frame.offsetBy(dx: 40, dy: 0), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    // MARK: Actions

    private func openEditor() {
        dismiss(animated: false)
        let editor = EditorWindowController.open(image: capture.base, savedURL: savedURL, annotations: capture.annotations,
                                                 badgeCounter: capture.badgeCounter, annotationsAreSaved: savedURL != nil)
        if !capture.annotations.isEmpty { editor.state.tool = .select }
    }

    private func copy() {
        Clipboard.copy(image: capture.image.cgImage, scale: capture.image.scale)
        Toast.show(icon: "doc.on.doc.fill", text: L("toast.copied"))
        dismiss(animated: true)
    }

    private func pin() {
        dismiss(animated: false)
        PinWindowController.show(image: capture.image, near: finalFrame.center)
    }

    private func reveal() {
        guard let savedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
        dismiss(animated: true)
    }
}

/// Thumbnail + hover controls; a click opens the editor, a drag carries the file (or image) away.
private final class PreviewContentView: NSView {
    var onOpen: (() -> Void)?
    var onCopy: (() -> Void)?
    var onPin: (() -> Void)?
    var onReveal: (() -> Void)?
    var onClose: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private let image: CapturedImage
    private let savedURL: URL?
    private let caption: String
    private var controls: NSHostingView<PreviewControls>?
    private var trackingArea: NSTrackingArea?

    init(image: CapturedImage, savedURL: URL?, caption: String) {
        self.image = image
        self.savedURL = savedURL
        self.caption = caption
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image.cgImage
        layer?.contentsGravity = .resizeAspectFill
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        installControlsIfNeeded()
        controls?.frame = bounds
    }

    private func installControlsIfNeeded() {
        guard controls == nil else { return }
        let url = savedURL
        let nsImage = image.cgImage.nsImage(scale: image.scale)
        let view = PreviewControls(caption: caption, canReveal: savedURL != nil,
                                   dragItem: { url.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider(object: nsImage) },
                                   onCopy: { [weak self] in self?.onCopy?() },
                                   onPin: { [weak self] in self?.onPin?() },
                                   onReveal: { [weak self] in self?.onReveal?() },
                                   onClose: { [weak self] in self?.onClose?() },
                                   onEdit: { [weak self] in self?.onOpen?() })
        let host = NSHostingView(rootView: view)
        host.frame = bounds
        addSubview(host)
        controls = host
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ inside: Bool) {
        controls?.rootView.hovering = inside
        onHover?(inside)
    }
}

private struct PreviewControls: View {
    let caption: String
    let canReveal: Bool
    let dragItem: () -> NSItemProvider
    let onCopy: () -> Void
    let onPin: () -> Void
    let onReveal: () -> Void
    let onClose: () -> Void
    let onEdit: () -> Void
    var hovering = false

    var body: some View {
        ZStack {
            // The whole thumbnail: click to annotate, drag into any app.
            Color.white.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture(perform: onEdit)
                .onDrag(dragItem)
            if hovering {
                Color.black.opacity(0.38).allowsHitTesting(false)
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        circleButton("xmark", action: onClose)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        pill("pencil.tip.crop.circle", L("preview.annotate"), action: onEdit)
                        circleButton("doc.on.doc", action: onCopy)
                        circleButton("pin", action: onPin)
                        if canReveal { circleButton("folder", action: onReveal) }
                    }
                }
                .padding(7)
            } else {
                VStack {
                    Spacer()
                    HStack {
                        Label(caption, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                        Spacer()
                    }
                }
                .padding(7)
                .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.black.opacity(0.55), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.25)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func pill(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .bold))
                Text(title).font(.system(size: 11, weight: .semibold)).fixedSize()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(accentGradient, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
