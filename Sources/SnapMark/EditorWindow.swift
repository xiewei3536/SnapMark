import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// One annotation-editor window per capture. Retains itself while open.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [EditorWindowController] = []

    /// The editor the user is working in, used by main-menu actions. Nil while some other window
    /// (the capture overlay, preferences…) has the keyboard, so a menu shortcut never edits a
    /// background editor by surprise.
    static var frontmost: EditorWindowController? {
        guard let key = NSApp.keyWindow else { return openControllers.last }
        if let c = key.windowController as? EditorWindowController { return c }
        // A popover (font list, OCR result) opened from an editor.
        if let c = key.parent?.windowController as? EditorWindowController { return c }
        return nil
    }

    let state: EditorState
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var changeObserver: AnyCancellable?
    private var closeConfirmed = false

    /// Opens an editor. `annotations` arrive live (still movable) — from the capture overlay, or
    /// restored from a file SnapMark saved earlier.
    @discardableResult
    static func open(image: CapturedImage, savedURL: URL?, annotations: [Annotation] = [],
                     badgeCounter: Int? = nil, annotationsAreSaved: Bool = true) -> EditorWindowController {
        let controller = EditorWindowController(image: image, savedURL: savedURL, annotations: annotations,
                                                badgeCounter: badgeCounter, annotationsAreSaved: annotationsAreSaved)
        openControllers.append(controller)
        updateActivationPolicy()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    /// For the self-test: a fully built editor that is never shown.
    static func makeForTesting(image: CapturedImage) -> EditorWindowController {
        EditorWindowController(image: image, savedURL: nil, annotations: [], badgeCounter: nil, annotationsAreSaved: true)
    }

    func closeForTesting() {
        closeConfirmed = true
        window?.close()
    }

    static func open(fileURL: URL) {
        // A file SnapMark saved with annotations comes back editable.
        if let data = try? Data(contentsOf: fileURL), let project = ProjectStore.load(fileData: data) {
            let controller = open(image: project.image, savedURL: fileURL, annotations: project.document.annotations,
                                  badgeCounter: project.document.badgeCounter)
            controller.state.tool = .select
            controller.state.showStatus(L("editor.status_restored"), duration: 6)
            return
        }
        guard let nsImage = NSImage(contentsOf: fileURL), let cg = nsImage.cgImageAnyScale else {
            Toast.show(icon: "exclamationmark.triangle.fill", text: L("toast.open_failed"))
            return
        }
        // Retina PNGs saved by SnapMark carry DPI metadata, so size (points) < pixels.
        let scale: CGFloat = nsImage.size.width > 0 ? max(1, (CGFloat(cg.width) / nsImage.size.width).rounded()) : 1
        open(image: CapturedImage(cgImage: cg, scale: scale), savedURL: fileURL)
    }

    /// Editing is a longer session: show a Dock icon / ⌘-Tab entry while any editor is open,
    /// and go back to being an invisible menu-bar app afterwards.
    private static func updateActivationPolicy() {
        let wantsDock = !openControllers.isEmpty
        if wantsDock, NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            // AppKit quirk: after accessory → regular the menu bar keeps showing the previous
            // app until focus bounces once. Bounce through the Dock (it has no windows), then return.
            if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
                dock.activate(options: [])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.activate(ignoringOtherApps: true)
                openControllers.last?.window?.makeKeyAndOrderFront(nil)
            }
        } else if !wantsDock, NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private init(image: CapturedImage, savedURL: URL?, annotations: [Annotation], badgeCounter: Int?,
                 annotationsAreSaved: Bool) {
        state = EditorState(image: image, originalURL: savedURL, annotations: annotations,
                            badgeCounter: badgeCounter, annotationsAreSaved: annotationsAreSaved)

        let pointSize = image.pointSize
        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let contentW = min(max(pointSize.width + 64, 960), screenFrame.width * 0.92)
        let contentH = min(max(pointSize.height + 140, 520), screenFrame.height * 0.92)

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: contentW, height: contentH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 960, height: 480)
        window.tabbingMode = .disallowed

        super.init(window: window)

        let actions = EditorActions(
            done: { [weak self] in self?.done() },
            save: { [weak self] in self?.save() },
            saveAs: { [weak self] in self?.saveAs() },
            copy: { [weak self] in self?.copyToClipboard() },
            pin: { [weak self] in self?.pin() },
            reveal: { [weak self] in self?.revealInFinder() }
        )
        window.contentView = NSHostingView(rootView: EditorRootView(state: state, actions: actions))
        window.delegate = self
        updateTitle()
        installMonitors()

        // Keep the title bar's "edited" dot and title in sync with the model.
        changeObserver = state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateTitle() {
        guard let window else { return }
        let name = state.originalURL?.lastPathComponent ?? L("editor.untitled")
        if window.title != name { window.title = name }
        let subtitle = "\(state.base.width) × \(state.base.height) px"
        if window.subtitle != subtitle { window.subtitle = subtitle }
        if window.representedURL != state.originalURL { window.representedURL = state.originalURL }
        let dirty = state.isDirty
        if window.isDocumentEdited != dirty { window.isDocumentEdited = dirty }
    }

    // MARK: Actions

    /// What it takes to reopen a saved file with live annotations.
    private var projectSource: ProjectStore.Source? {
        state.commitTextEditing()
        guard !state.annotations.isEmpty else { return nil }
        return ProjectStore.Source(base: state.base, scale: state.scale,
                                   annotations: state.annotations, badgeCounter: state.badgeCounter)
    }

    @discardableResult
    func save() -> Bool {
        let settings = Settings.shared
        let url = state.originalURL ?? settings.nextFileURL(ext: settings.imageFormat.fileExtension)
        guard ImageFile.write(state.flattenedCapture(), to: url, project: projectSource) else {
            Toast.show(icon: "exclamationmark.triangle.fill", text: L("toast.save_failed"))
            return false
        }
        state.originalURL = url
        state.markSaved()
        updateTitle()
        HistoryManager.shared.add(fileURL: url, kind: .image)
        state.showStatus(L("editor.status_saved", url.lastPathComponent))
        return true
    }

    func saveAs() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canCreateDirectories = true
        panel.directoryURL = state.originalURL?.deletingLastPathComponent() ?? Settings.shared.saveDirectory
        panel.nameFieldStringValue = state.originalURL?.lastPathComponent
            ?? "SnapMark.\(Settings.shared.imageFormat.fileExtension)"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard ImageFile.write(self.state.flattenedCapture(), to: url, project: self.projectSource) else {
                Toast.show(icon: "exclamationmark.triangle.fill", text: L("toast.save_failed"))
                return
            }
            self.state.originalURL = url
            self.state.markSaved()
            self.updateTitle()
            HistoryManager.shared.add(fileURL: url, kind: .image)
            self.state.showStatus(L("editor.status_saved", url.lastPathComponent))
        }
    }

    /// Finish in one step: copy the result, keep the file up to date, close without asking.
    func done() {
        state.commitTextEditing()
        let image = state.flattenedCapture()
        Clipboard.copy(image: image.cgImage, scale: image.scale)
        var savedName: String?
        let needsWrite = state.originalURL == nil ? Settings.shared.autoSaveToDisk : state.isDirty
        if needsWrite {
            guard save() else { return } // stay open if the file could not be written
            savedName = state.originalURL?.lastPathComponent
        }
        closeConfirmed = true
        window?.close()
        Toast.show(icon: "checkmark.circle.fill",
                   text: savedName == nil ? L("toast.copied") : L("toast.copied_saved"),
                   subtitle: savedName)
    }

    func copyToClipboard() {
        Clipboard.copy(image: state.flatten(), scale: state.scale)
        state.showStatus(L("editor.status_copied"))
    }

    func pin() {
        PinWindowController.show(image: state.flattenedCapture(), near: window?.frame.center)
    }

    func revealInFinder() {
        if state.originalURL == nil { save() }
        if let url = state.originalURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: Keyboard & scroll

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window, window.isKeyWindow else { return event }
            return self.handleKey(event) ? nil : event
        }
        // ⌘ + scroll wheel zooms the canvas.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  event.modifierFlags.contains(.command) else { return event }
            let factor = 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.05)
            self.state.setZoom(self.state.zoom * factor)
            return nil
        }
    }

    private typealias Key = EditorState.Key

    /// Typing undo inside the open text box, if it has any.
    private var editingTextView: EditingTextView? { window?.firstResponder as? EditingTextView }

    func handleKey(_ event: NSEvent) -> Bool {
        let flags = EditorState.cleanFlags(event)
        let code = event.keyCode

        // While typing: ⌘Z first undoes the typing, then the document; Esc / ↩ finish (handled by the
        // text view); ⌘B/I/U and ⌥⌘↑↓ restyle; everything else is text input.
        if state.editingTextID != nil {
            if code == Key.z, flags == [.command] {
                if let um = editingTextView?.undoManager, um.canUndo { um.undo() } else { state.undo() }
                return true
            }
            if code == Key.z, flags == [.command, .shift] {
                if let um = editingTextView?.undoManager, um.canRedo { um.redo() } else { state.redo() }
                return true
            }
            if code == Key.esc {
                state.commitTextEditing()
                return true
            }
            if flags == [.command], code == Key.ret || code == Key.enter {
                done()
                return true
            }
            return state.handleTextStyleShortcut(code: code, flags: flags)
        }
        // Let native text fields (save panel, popovers, font search) work normally.
        if window?.firstResponder is NSTextView { return false }

        if state.handleAnnotationKey(code: code, flags: flags) { return true }

        if flags == [.command] {
            switch code {
            case Key.c: copyToClipboard(); return true
            case Key.s: save(); return true
            case Key.equal: state.setZoom(state.zoom * 1.25); return true
            case Key.minus: state.setZoom(state.zoom / 1.25); return true
            case Key.zero: state.setZoom(1); return true
            case Key.nine: state.zoomToFit(); return true
            case Key.ret, Key.enter: done(); return true
            default: break
            }
        }
        if flags == [.command, .shift] {
            switch code {
            case Key.s: saveAs(); return true
            case Key.equal: state.setZoom(state.zoom * 1.25); return true // ⌘+ on US layouts
            default: break
            }
        }
        if flags.isEmpty || flags == [.shift] {
            switch code {
            case Key.esc:
                if state.tool == .crop { state.cropRect = nil; state.tool = .select; return true }
                if state.selectedID != nil { state.selectedID = nil; return true }
                return false
            case Key.ret where state.tool == .crop && state.cropRect != nil:
                state.applyCrop()
                return true
            default:
                break
            }
            if flags.isEmpty, let tool = EditorState.toolKeys[code] {
                state.tool = tool
                return true
            }
        }
        return false
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeConfirmed || !state.isDirty { return true }
        let alert = NSAlert()
        alert.messageText = L("editor.unsaved_title")
        alert.informativeText = L("editor.unsaved_body")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("editor.save"))
        alert.addButton(withTitle: L("editor.dont_save"))
        alert.addButton(withTitle: L("editor.cancel"))
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                guard self.save() else { return } // save failed; stay open
                self.closeConfirmed = true
                sender.close()
            case .alertSecondButtonReturn:
                self.closeConfirmed = true
                sender.close()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        keyMonitor = nil
        scrollMonitor = nil
        changeObserver = nil
        Self.openControllers.removeAll { $0 === self }
        Self.updateActivationPolicy()
    }
}
