import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppCoordinator.shared.start()
    }

    /// Images dropped on the Dock icon / opened with SnapMark land in the editor.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { AppCoordinator.shared.openFile(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WelcomeWindowController.show() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if RecorderEngine.shared.isRecording {
            RecorderEngine.shared.stop()
        }
    }
}

// MARK: - Coordinator: wires status bar, menus, hotkeys and capture flows together

@MainActor
final class AppCoordinator: NSObject, NSMenuItemValidation {
    static let shared = AppCoordinator()

    private var statusItem: NSStatusItem?
    private var recordingTimer: Timer?

    func start() {
        buildMainMenu()
        setUpStatusItem()

        HotkeyManager.shared.onTrigger = { [weak self] action in
            Task { @MainActor in self?.handleHotkey(action) }
        }
        HotkeyManager.shared.start()

        HistoryManager.shared.onChange = { [weak self] in
            Task { @MainActor in self?.rebuildStatusMenu() }
        }
        NotificationCenter.default.addObserver(forName: .snapMarkLanguageChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.buildMainMenu()
                self?.rebuildStatusMenu()
            }
        }

        let defaults = UserDefaults.standard
        let firstRun = !defaults.bool(forKey: "hasLaunchedBefore")
        defaults.set(true, forKey: "hasLaunchedBefore")

        if !CaptureEngine.hasPermission() {
            CaptureEngine.requestPermission() // system prompt on first ask
        }
        if firstRun || !CaptureEngine.hasPermission() {
            WelcomeWindowController.show()
        } else if LaunchOptions.filesToOpen.isEmpty {
            let hk = HotkeyManager.shared.hotkey(for: .captureRegion)?.display
            Toast.show(icon: "camera.viewfinder", text: L("toast.ready"),
                       subtitle: hk.map { L("toast.ready_hint", $0) }, duration: 2.6)
        }
        for url in LaunchOptions.filesToOpen { openFile(url) }
    }

    func openFile(_ url: URL) {
        let imageExts = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "bmp", "webp"]
        if imageExts.contains(url.pathExtension.lowercased()) {
            EditorWindowController.open(fileURL: url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        if let button = item.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SnapMark")
            image?.isTemplate = true
            button.image = image
            if button.image == nil { button.title = "◉" }
            button.toolTip = "SnapMark"
        }
        statusItem = item
        rebuildStatusMenu()
    }

    func recordingStateChanged() {
        rebuildStatusMenu()
        recordingTimer?.invalidate()
        recordingTimer = nil
        guard let button = statusItem?.button else { return }

        if RecorderEngine.shared.isRecording {
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            button.image?.isTemplate = false
            button.contentTintColor = Brand.recordRed
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, RecorderEngine.shared.isRecording else { return }
                    self.statusItem?.button?.title = " " + formatDuration(RecorderEngine.shared.elapsed)
                    self.statusItem?.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            recordingTimer = timer
        } else {
            button.title = ""
            button.contentTintColor = nil
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SnapMark")
            button.image?.isTemplate = true
        }
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu()

        if RecorderEngine.shared.isRecording {
            menu.addClosureItem(L("menu.stop_recording"), symbol: "stop.circle.fill", owner: self) {
                RecordingSession.shared.stop()
            }
            menu.addClosureItem(L("menu.discard_recording"), symbol: "trash", owner: self) {
                RecordingSession.shared.stop(discard: true)
            }
            menu.addItem(.separator())
        } else {
            menu.addItem(hotkeyMenuItem(.captureRegion, symbol: "rectangle.dashed"))
            menu.addItem(hotkeyMenuItem(.captureFullScreen, symbol: "macwindow"))
            menu.addItem(hotkeyMenuItem(.captureWindow, symbol: "macwindow.on.rectangle"))
            menu.addItem(.separator())
            menu.addItem(hotkeyMenuItem(.recordRegion, symbol: "record.circle"))
            menu.addItem(hotkeyMenuItem(.recordFullScreen, symbol: "video.fill"))
            menu.addItem(.separator())
            menu.addItem(hotkeyMenuItem(.ocrRegion, symbol: "text.viewfinder"))
            menu.addItem(hotkeyMenuItem(.pinRegion, symbol: "pin"))
            menu.addItem(hotkeyMenuItem(.repeatLastRegion, symbol: "arrow.counterclockwise"))
            menu.addItem(.separator())
        }

        // Recent captures (always present so the folder is one click away).
        let recentItem = NSMenuItem(title: L("menu.recent"), action: nil, keyEquivalent: "")
        recentItem.image = symbolImage("clock")
        let sub = NSMenu()
        let recent = HistoryManager.shared.validEntries()
        if recent.isEmpty {
            let empty = NSMenuItem(title: L("menu.no_recent"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
        }
        for entry in recent.prefix(8) {
            let item = NSMenuItem(title: entry.url.lastPathComponent, action: #selector(openHistoryEntry(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.path
            item.image = HistoryManager.shared.thumbnail(for: entry) ?? symbolImage(entry.kind == .video ? "film" : "photo")
            item.toolTip = entry.path
            sub.addItem(item)
        }
        sub.addItem(.separator())
        sub.addClosureItem(L("menu.open_folder"), symbol: "folder", owner: self) {
            NSWorkspace.shared.open(Settings.shared.saveDirectory)
        }
        recentItem.submenu = sub
        menu.addItem(recentItem)
        menu.addItem(.separator())

        menu.addClosureItem(L("menu.open_image"), symbol: "photo.on.rectangle", owner: self) { [weak self] in
            self?.openImageDialog()
        }
        menu.addClosureItem(L("menu.preferences"), symbol: "gearshape", keyEquivalent: ",", owner: self) {
            PreferencesWindowController.show()
        }
        menu.addClosureItem(L("menu.quick_start"), symbol: "questionmark.circle", owner: self) {
            WelcomeWindowController.show()
        }

        if !CaptureEngine.hasPermission() {
            menu.addItem(.separator())
            let perm = menu.addClosureItem(L("menu.grant_permission"), symbol: "lock.shield", owner: self) { [weak self] in
                self?.openScreenRecordingSettings()
            }
            perm.attributedTitle = NSAttributedString(string: L("menu.grant_permission"), attributes: [
                .foregroundColor: NSColor.systemOrange,
                .font: NSFont.menuFont(ofSize: 13),
            ])
            menu.addClosureItem(L("perm.reset_record"), symbol: "arrow.counterclockwise", owner: self) { [weak self] in
                self?.resetPermissionRecord()
            }
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    /// Menu item for a capture action; shows its global shortcut as the key equivalent
    /// (informational — the Carbon hotkey fires first, so it never double-triggers).
    private func hotkeyMenuItem(_ action: HotkeyAction, symbol: String?) -> NSMenuItem {
        let item = NSMenuItem(title: L(action.titleKey), action: #selector(menuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
        if let symbol { item.image = symbolImage(symbol) }
        if let hk = HotkeyManager.shared.hotkey(for: action), let (key, mods) = hk.cocoaKeyEquivalent {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = mods
        }
        return item
    }

    private func symbolImage(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        img?.isTemplate = true
        return img
    }

    @objc func runClosure(_ sender: NSMenuItem) {
        (sender.representedObject as? ClosureBox)?.closure()
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = HotkeyAction(rawValue: raw) else { return }
        handleHotkey(action)
    }

    @objc private func openHistoryEntry(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openFile(URL(fileURLWithPath: path))
    }

    private func openImageDialog() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .bmp, .webP]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = Settings.shared.saveDirectory
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            for url in panel.urls { EditorWindowController.open(fileURL: url) }
        }
    }

    // MARK: Main menu (visible while an editor is open; also powers ⌘-shortcuts)

    private func buildMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addClosureItem(L("menu.about"), owner: self) { PreferencesWindowController.show(tab: .about) }
        appMenu.addClosureItem(L("menu.quick_start"), owner: self) { WelcomeWindowController.show() }
        appMenu.addItem(.separator())
        appMenu.addClosureItem(L("menu.preferences"), keyEquivalent: ",", owner: self) { PreferencesWindowController.show() }
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: L("menu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: L("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(wrap(appMenu, title: "SnapMark"))

        let file = NSMenu(title: L("menu.file"))
        for action in HotkeyAction.allCases {
            file.addItem(hotkeyMenuItem(action, symbol: nil))
        }
        file.addItem(.separator())
        file.addClosureItem(L("menu.open_image"), keyEquivalent: "o", owner: self) { [weak self] in self?.openImageDialog() }
        file.addItem(.separator())
        file.addItem(editorItem(L("menu.save"), key: "s", mods: [.command], #selector(menuSave(_:))))
        file.addItem(editorItem(L("menu.save_as"), key: "s", mods: [.command, .shift], #selector(menuSaveAs(_:))))
        file.addItem(editorItem(L("menu.reveal"), key: "", mods: [], #selector(menuReveal(_:))))
        file.addItem(.separator())
        file.addItem(NSMenuItem(title: L("menu.close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        main.addItem(wrap(file, title: L("menu.file")))

        let edit = NSMenu(title: L("menu.edit"))
        edit.addItem(editorItem(L("menu.undo"), key: "z", mods: [.command], #selector(menuUndo(_:))))
        edit.addItem(editorItem(L("menu.redo"), key: "z", mods: [.command, .shift], #selector(menuRedo(_:))))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: L("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(editorItem(L("menu.copy"), key: "c", mods: [.command], #selector(menuCopy(_:))))
        edit.addItem(NSMenuItem(title: L("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(editorItem(L("menu.delete"), key: "", mods: [], #selector(menuDelete(_:))))
        edit.addItem(NSMenuItem(title: L("menu.select_all"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        main.addItem(wrap(edit, title: L("menu.edit")))

        let view = NSMenu(title: L("menu.view"))
        view.addItem(editorItem(L("menu.zoom_in"), key: "+", mods: [.command], #selector(menuZoomIn(_:))))
        view.addItem(editorItem(L("menu.zoom_out"), key: "-", mods: [.command], #selector(menuZoomOut(_:))))
        view.addItem(editorItem(L("menu.zoom_actual"), key: "0", mods: [.command], #selector(menuZoomActual(_:))))
        view.addItem(editorItem(L("menu.zoom_fit"), key: "9", mods: [.command], #selector(menuZoomFit(_:))))
        main.addItem(wrap(view, title: L("menu.view")))

        let windowMenu = NSMenu(title: L("menu.window"))
        windowMenu.addItem(NSMenuItem(title: L("menu.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: L("menu.zoom_window"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: L("menu.bring_all_front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        main.addItem(wrap(windowMenu, title: L("menu.window")))
        NSApp.windowsMenu = windowMenu

        let help = NSMenu(title: L("menu.help"))
        help.addClosureItem(L("menu.quick_start"), owner: self) { WelcomeWindowController.show() }
        help.addClosureItem(L("menu.open_folder"), owner: self) { NSWorkspace.shared.open(Settings.shared.saveDirectory) }
        main.addItem(wrap(help, title: L("menu.help")))
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    private func wrap(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func editorItem(_ title: String, key: String, mods: NSEvent.ModifierFlags, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = self
        return item
    }

    private var keyEditor: EditorWindowController? { EditorWindowController.frontmost }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return true }
        switch action {
        case #selector(menuSave(_:)), #selector(menuSaveAs(_:)), #selector(menuReveal(_:)),
             #selector(menuZoomIn(_:)), #selector(menuZoomOut(_:)), #selector(menuZoomActual(_:)), #selector(menuZoomFit(_:)):
            return keyEditor != nil
        case #selector(menuUndo(_:)):
            if NSApp.keyWindow?.firstResponder is NSTextView { return true }
            return keyEditor?.state.canUndo ?? false
        case #selector(menuRedo(_:)):
            if NSApp.keyWindow?.firstResponder is NSTextView { return true }
            return keyEditor?.state.canRedo ?? false
        case #selector(menuCopy(_:)):
            return keyEditor != nil || NSApp.keyWindow?.firstResponder is NSTextView
        case #selector(menuDelete(_:)):
            return keyEditor?.state.selectedID != nil
        case #selector(menuAction(_:)):
            return !RecorderEngine.shared.isRecording
        default:
            return true
        }
    }

    @objc private func menuSave(_ sender: Any?) { keyEditor?.save() }
    @objc private func menuSaveAs(_ sender: Any?) { keyEditor?.saveAs() }
    @objc private func menuReveal(_ sender: Any?) { keyEditor?.revealInFinder() }
    @objc private func menuUndo(_ sender: Any?) {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView { tv.undoManager?.undo(); return }
        keyEditor?.state.undo()
    }
    @objc private func menuRedo(_ sender: Any?) {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView { tv.undoManager?.redo(); return }
        keyEditor?.state.redo()
    }
    @objc private func menuCopy(_ sender: Any?) {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView { tv.copy(nil); return }
        keyEditor?.copyToClipboard()
    }
    @objc private func menuDelete(_ sender: Any?) { keyEditor?.state.deleteSelected() }
    @objc private func menuZoomIn(_ sender: Any?) { if let s = keyEditor?.state { s.setZoom(s.zoom * 1.25) } }
    @objc private func menuZoomOut(_ sender: Any?) { if let s = keyEditor?.state { s.setZoom(s.zoom / 1.25) } }
    @objc private func menuZoomActual(_ sender: Any?) { keyEditor?.state.setZoom(1) }
    @objc private func menuZoomFit(_ sender: Any?) { keyEditor?.state.zoomToFit() }

    // MARK: Hotkey routing

    private func handleHotkey(_ action: HotkeyAction) {
        if RecordingSession.shared.isCountingDown {
            if action == .recordRegion || action == .recordFullScreen { RecordingSession.shared.cancelCountdown() }
            return
        }
        if RecorderEngine.shared.isRecording {
            if action == .recordRegion || action == .recordFullScreen { RecordingSession.shared.stop() }
            return
        }
        guard !SelectionController.shared.isActive else { return }

        switch action {
        case .captureRegion: beginSelection(.screenshot)
        case .captureWindow: beginSelection(.windowPick)
        case .recordRegion: beginSelection(.recording)
        case .ocrRegion: beginSelection(.ocr)
        case .pinRegion: beginSelection(.pin)
        case .captureFullScreen: captureFullScreen()
        case .recordFullScreen: recordFullScreen()
        case .repeatLastRegion: repeatLastRegion()
        }
    }

    // MARK: Capture flows

    private func beginSelection(_ purpose: SelectionPurpose) {
        SelectionController.shared.begin(purpose: purpose) { [weak self] result in
            guard let self, let result else { return }
            Task { @MainActor in self.handleSelection(result) }
        }
    }

    private func handleSelection(_ result: SelectionResult) {
        switch result.action {
        case .record:
            // Give focus back so the recorded app doesn't look inactive in the video.
            SelectionController.shared.restorePreviousApp()
            RecordingSession.shared.begin(screen: result.screen, localRect: result.localRect)
        case .capture, .copy, .pin, .ocr:
            Task { @MainActor in
                guard let image = await self.resolveImage(for: result) else {
                    Toast.show(icon: "exclamationmark.triangle.fill", text: L("toast.capture_failed"))
                    return
                }
                switch result.action {
                case .capture:
                    self.deliverCapture(image, pinOrigin: result.globalCocoaRect.center)
                case .copy:
                    Sounds.playShutter()
                    Clipboard.copy(image: image.cgImage, scale: image.scale)
                    SelectionController.shared.restorePreviousApp()
                    Toast.show(icon: "doc.on.doc.fill", text: L("toast.copied"))
                case .pin:
                    Sounds.playShutter()
                    SelectionController.shared.restorePreviousApp()
                    PinWindowController.show(image: image, near: result.globalCocoaRect.center)
                case .ocr:
                    SelectionController.shared.restorePreviousApp()
                    self.runOCRFlow(image)
                default:
                    break
                }
            }
        }
    }

    /// Produces the final image for a selection: a clean whole-window capture when a window
    /// was clicked, otherwise a crop of the frozen screenshot.
    private func resolveImage(for result: SelectionResult) async -> CapturedImage? {
        if let windowID = result.windowID, let img = try? await CaptureEngine.captureWindow(windowID: windowID) {
            return img
        }
        let scale = result.frozen.scale
        let pixelRect = CGRect(x: result.localRect.minX * scale, y: result.localRect.minY * scale,
                               width: result.localRect.width * scale, height: result.localRect.height * scale)
        guard let cropped = result.frozen.cgImage.cropped(toPixels: pixelRect) else { return nil }
        return CapturedImage(cgImage: cropped, scale: scale)
    }

    /// Applies the user's after-capture routine to a fresh screenshot.
    private func deliverCapture(_ image: CapturedImage, pinOrigin: CGPoint?) {
        Sounds.playShutter()
        let settings = Settings.shared

        var savedURL: URL?
        if settings.autoSaveToDisk, let url = ImageFile.saveToCaptureFolder(image) {
            savedURL = url
            HistoryManager.shared.add(fileURL: url, kind: .image)
        }
        if settings.autoCopyToClipboard {
            Clipboard.copy(image: image.cgImage, scale: image.scale)
        }

        switch settings.afterCapture {
        case .openEditor:
            let editor = EditorWindowController.open(image: image, savedURL: savedURL)
            var parts: [String] = []
            if settings.autoCopyToClipboard { parts.append(L("editor.status_copied")) }
            if savedURL != nil { parts.append(L("toast.saved")) }
            if !parts.isEmpty { editor.state.showStatus(parts.joined(separator: " · "), duration: 6) }
        case .copyOnly:
            SelectionController.shared.restorePreviousApp()
            let text = settings.autoCopyToClipboard ? L("toast.captured_copied") : L("toast.captured")
            Toast.show(icon: "camera.fill", text: text, subtitle: savedURL?.lastPathComponent)
        case .pin:
            SelectionController.shared.restorePreviousApp()
            PinWindowController.show(image: image, near: pinOrigin)
        }
    }

    private func runOCRFlow(_ image: CapturedImage) {
        OCRService.recognize(image: image.cgImage) { text in
            Task { @MainActor in
                if let text, !text.isEmpty {
                    Clipboard.copy(text: text)
                    let preview = text.count > 60 ? String(text.prefix(60)) + "…" : text
                    Toast.show(icon: "text.viewfinder", text: L("toast.ocr_copied"),
                               subtitle: preview.replacingOccurrences(of: "\n", with: " "), duration: 3.2)
                } else {
                    Toast.show(icon: "text.magnifyingglass", text: L("toast.ocr_empty"))
                }
            }
        }
    }

    private func captureFullScreen() {
        let screen = screenUnderMouse()
        Task { @MainActor in
            do {
                let image = try await CaptureEngine.captureDisplay(
                    screen: screen, showCursor: Settings.shared.showCursorInScreenshot)
                deliverCapture(image, pinOrigin: screen.frame.center)
            } catch {
                handleMissingPermission()
                if CaptureEngine.hasPermission() {
                    Toast.show(icon: "exclamationmark.triangle.fill", text: L("toast.capture_failed"))
                }
            }
        }
    }

    private func recordFullScreen() {
        RecordingSession.shared.begin(screen: screenUnderMouse(), localRect: nil)
    }

    private func repeatLastRegion() {
        guard let last = SelectionController.lastRegion,
              let screen = NSScreen.screens.first(where: { $0.frame == last.screenFrame }) else {
            beginSelection(.screenshot)
            return
        }
        Task { @MainActor in
            do {
                let full = try await CaptureEngine.captureDisplay(screen: screen, showCursor: false)
                let scale = full.scale
                let pixelRect = CGRect(x: last.localRect.minX * scale, y: last.localRect.minY * scale,
                                       width: last.localRect.width * scale, height: last.localRect.height * scale)
                guard let cropped = full.cgImage.cropped(toPixels: pixelRect) else { return }
                deliverCapture(CapturedImage(cgImage: cropped, scale: scale), pinOrigin: nil)
            } catch {
                handleMissingPermission()
            }
        }
    }

    private func screenUnderMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: Permission

    /// Called when a capture failed: if the Screen Recording permission is the reason,
    /// explain it in the welcome window (which also offers a relaunch button).
    func handleMissingPermission() {
        guard !CaptureEngine.hasPermission() else { return }
        Toast.show(icon: "lock.shield.fill", text: L("perm.title"), duration: 3)
        WelcomeWindowController.show()
    }

    func showPermissionAlertIfNeeded() { handleMissingPermission() }

    /// macOS keys privacy records by bundle ID and remembers the *signature* of the build that
    /// first asked. After a rebuild with a different signature the existing record never matches,
    /// and toggling it in System Settings changes nothing. Resetting the record makes macOS
    /// register the current build and ask again.
    func resetPermissionRecord() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.snapmark.app"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "ScreenCapture", bundleID]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            NSLog("SnapMark: tccutil failed: \(error)")
        }
        CaptureEngine.requestPermission() // fresh record → macOS shows its own prompt
        PermissionMonitor.shared.refresh()
        Toast.show(icon: "arrow.counterclockwise", text: L("toast.perm_reset"), duration: 3.5)
    }

    func openScreenRecordingSettings() {
        CaptureEngine.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Relaunches the app (permission changes only take effect after a restart).
    func relaunch() {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else {
            NSApp.terminate(nil)
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open -n \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Hotkey → Cocoa key equivalent

extension Hotkey {
    /// (key, modifiers) for `NSMenuItem`, or nil for keys that menus can't display.
    var cocoaKeyEquivalent: (String, NSEvent.ModifierFlags)? {
        let name = KeyNames.name(for: keyCode)
        guard name.count == 1, let ch = name.lowercased().first, ch.isLetter || ch.isNumber || "-=[];',./\\`".contains(ch) else {
            return nil
        }
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return (String(ch), flags)
    }
}
