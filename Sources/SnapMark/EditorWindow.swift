import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// One annotation-editor window per capture. Retains itself while open.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [EditorWindowController] = []

    /// The editor the user is working in (key window), used by main-menu actions.
    static var frontmost: EditorWindowController? {
        if let c = NSApp.keyWindow?.windowController as? EditorWindowController { return c }
        return openControllers.last
    }

    let state: EditorState
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var changeObserver: AnyCancellable?
    private var closeConfirmed = false

    @discardableResult
    static func open(image: CapturedImage, savedURL: URL?) -> EditorWindowController {
        let controller = EditorWindowController(image: image, savedURL: savedURL)
        openControllers.append(controller)
        updateActivationPolicy()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    static func open(fileURL: URL) {
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

    private init(image: CapturedImage, savedURL: URL?) {
        state = EditorState(image: image, originalURL: savedURL)

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

    func save() {
        let settings = Settings.shared
        let url = state.originalURL ?? settings.nextFileURL(ext: settings.imageFormat.fileExtension)
        guard ImageFile.write(state.flattenedCapture(), to: url) else {
            Toast.show(icon: "exclamationmark.triangle.fill", text: L("toast.save_failed"))
            return
        }
        state.originalURL = url
        state.markSaved()
        updateTitle()
        HistoryManager.shared.add(fileURL: url, kind: .image)
        state.showStatus(L("editor.status_saved", url.lastPathComponent))
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
            guard ImageFile.write(self.state.flattenedCapture(), to: url) else {
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

    /// Physical key codes, so shortcuts work under any keyboard layout or IME
    /// (with 注音/拼音 active, `characters` returns Zhuyin/Pinyin glyphs instead of letters).
    private enum Key {
        static let a: UInt16 = 0, s: UInt16 = 1, h: UInt16 = 4, z: UInt16 = 6, c: UInt16 = 8, v: UInt16 = 9, u: UInt16 = 32, i: UInt16 = 34
        static let b: UInt16 = 11, w: UInt16 = 13, e: UInt16 = 14, r: UInt16 = 15, t: UInt16 = 17
        static let equal: UInt16 = 24, nine: UInt16 = 25, minus: UInt16 = 27, zero: UInt16 = 29
        static let p: UInt16 = 35, l: UInt16 = 37, m: UInt16 = 46, ret: UInt16 = 36, esc: UInt16 = 53
        static let delete: UInt16 = 51, fwdDelete: UInt16 = 117
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    }

    private static let toolKeys: [UInt16: Tool] = [
        Key.v: .select, Key.p: .pen, Key.h: .highlighter, Key.l: .line, Key.a: .arrow,
        Key.r: .rect, Key.e: .ellipse, Key.t: .text, Key.m: .mosaic, Key.b: .badge, Key.c: .crop,
    ]

    private func handleKey(_ event: NSEvent) -> Bool {
        // Arrow keys carry .function/.numericPad; strip them so "shift + arrow" compares cleanly.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])
        let code = event.keyCode

        // While editing text: Escape commits; ⌘B/I/U and ⌥⌘↑↓ restyle; everything else is typing.
        if state.editingTextID != nil {
            if code == Key.esc {
                state.commitTextEditing()
                return true
            }
            if handleTextStyleShortcut(code: code, flags: flags) { return true }
            return false
        }
        if state.inspectedIsText, handleTextStyleShortcut(code: code, flags: flags) { return true }
        // Let native text fields (save panel, popovers) work normally.
        if window?.firstResponder is NSTextView { return false }

        if flags == [.command] {
            switch code {
            case Key.z: state.undo(); return true
            case Key.c: copyToClipboard(); return true
            case Key.s: save(); return true
            case Key.equal: state.setZoom(state.zoom * 1.25); return true
            case Key.minus: state.setZoom(state.zoom / 1.25); return true
            case Key.zero: state.setZoom(1); return true
            case Key.nine: state.zoomToFit(); return true
            default: break
            }
        }
        if flags == [.command, .shift] {
            switch code {
            case Key.z: state.redo(); return true
            case Key.s: saveAs(); return true
            case Key.equal: state.setZoom(state.zoom * 1.25); return true // ⌘+ on US layouts
            default: break
            }
        }
        if flags.isEmpty || flags == [.shift] {
            switch code {
            case Key.delete, Key.fwdDelete:
                state.deleteSelected()
                return true
            case Key.esc:
                if state.tool == .crop { state.cropRect = nil; state.tool = .select; return true }
                if state.selectedID != nil { state.selectedID = nil; return true }
                return false
            case Key.ret where state.tool == .crop && state.cropRect != nil:
                state.applyCrop()
                return true
            case Key.left, Key.right, Key.down, Key.up:
                guard state.selectedID != nil else { return false }
                let step: CGFloat = (flags == [.shift] ? 10 : 1) * state.scale
                switch code {
                case Key.left: state.nudgeSelected(dx: -step, dy: 0)
                case Key.right: state.nudgeSelected(dx: step, dy: 0)
                case Key.down: state.nudgeSelected(dx: 0, dy: step)
                default: state.nudgeSelected(dx: 0, dy: -step)
                }
                return true
            default:
                break
            }
            if flags.isEmpty, let tool = Self.toolKeys[code] {
                state.tool = tool
                return true
            }
        }
        return false
    }

    /// ⌘B bold · ⌘I italic · ⌘U underline · ⌥⌘↑/↓ font size (for the selected or edited text).
    private func handleTextStyleShortcut(code: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        if flags == [.command] {
            switch code {
            case Key.b: state.textStyle.bold.toggle(); return true
            case Key.i: state.textStyle.italic.toggle(); return true
            case Key.u: state.textStyle.underline.toggle(); return true
            default: return false
            }
        }
        if flags == [.command, .option] {
            switch code {
            case Key.up: state.adjustFontSize(by: 2); return true
            case Key.down: state.adjustFontSize(by: -2); return true
            default: return false
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
                self.save()
                guard !self.state.isDirty else { return } // save failed; stay open
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
