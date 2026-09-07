import AppKit
import SwiftUI

enum PrefsTab: Int { case general, recording, hotkeys, about }

final class PrefsSelection: ObservableObject {
    @Published var tab: PrefsTab = .general
}

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private static var current: PreferencesWindowController?
    private let selection = PrefsSelection()

    static func show(tab: PrefsTab = .general) {
        let controller: PreferencesWindowController
        if let current {
            controller = current
        } else {
            controller = PreferencesWindowController()
            current = controller
        }
        controller.selection.tab = tab
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 580, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = L("prefs.title")
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: PreferencesView(selection: selection))
        window.delegate = self
        NotificationCenter.default.addObserver(forName: .snapMarkLanguageChanged, object: nil, queue: .main) { [weak window] _ in
            window?.title = L("prefs.title")
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }
}

// MARK: - Root preferences view

struct PreferencesView: View {
    @ObservedObject var selection: PrefsSelection
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selection.tab) {
                Label(L("prefs.general"), systemImage: "gearshape").tag(PrefsTab.general)
                Label(L("prefs.recording"), systemImage: "video").tag(PrefsTab.recording)
                Label(L("prefs.hotkeys"), systemImage: "keyboard").tag(PrefsTab.hotkeys)
                Label(L("prefs.about"), systemImage: "info.circle").tag(PrefsTab.about)
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .labelsHidden()
            .padding(14)

            Divider()

            Group {
                switch selection.tab {
                case .general: GeneralPrefs()
                case .recording: RecordingPrefs()
                case .hotkeys: HotkeyPrefs()
                case .about: AboutPrefs()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 580, height: 560)
        .id(l10n.revision)
    }
}

// MARK: - General

struct GeneralPrefs: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var perm = PermissionMonitor.shared

    var body: some View {
        Form {
            Section {
                PermissionCard(compact: true)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                Picker(L("prefs.language"), selection: Binding(
                    get: { l10n.language },
                    set: { l10n.setLanguage($0) }
                )) {
                    ForEach(L10n.Language.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                Toggle(L("prefs.launch_at_login"), isOn: $settings.launchAtLogin)
            }

            Section(L("prefs.after_capture")) {
                Picker(L("prefs.after_capture_action"), selection: $settings.afterCapture) {
                    ForEach(AfterCaptureAction.allCases) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                Toggle(L("prefs.auto_copy"), isOn: $settings.autoCopyToClipboard)
                Toggle(L("prefs.auto_save"), isOn: $settings.autoSaveToDisk)
                Toggle(L("prefs.play_sound"), isOn: $settings.playSound)
                Toggle(L("prefs.show_cursor_shot"), isOn: $settings.showCursorInScreenshot)
            }

            Section(L("prefs.files")) {
                Picker(L("prefs.image_format"), selection: $settings.imageFormat) {
                    ForEach(ImageFormat.allCases) { f in Text(f.displayName).tag(f) }
                }
                if settings.imageFormat == .jpeg {
                    HStack {
                        Text(L("prefs.jpeg_quality"))
                        Slider(value: $settings.jpegQuality, in: 0.3...1.0)
                        Text("\(Int(settings.jpegQuality * 100))%").monospacedDigit().frame(width: 42)
                    }
                }
                HStack {
                    TextField(L("prefs.save_location"), text: $settings.saveDirectoryPath)
                        .textFieldStyle(.roundedBorder)
                    Button(L("prefs.choose")) { pickFolder() }
                    Button {
                        NSWorkspace.shared.open(Settings.shared.saveDirectory)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help(L("menu.open_folder"))
                }
                TextField(L("prefs.filename_template"), text: $settings.filenameTemplate)
                    .textFieldStyle(.roundedBorder)
                Text(L("prefs.filename_hint"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { perm.startPolling() }
        .onDisappear { perm.stopPolling() }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Settings.shared.saveDirectory
        if panel.runModal() == .OK, let url = panel.url {
            Settings.shared.saveDirectoryPath = url.path
        }
    }
}

// MARK: - Recording

struct RecordingPrefs: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                Picker(L("prefs.video_format"), selection: $settings.videoFormat) {
                    ForEach(VideoFormat.allCases) { f in Text(f.displayName).tag(f) }
                }
                Picker(L("prefs.video_codec"), selection: $settings.videoCodec) {
                    ForEach(VideoCodec.allCases) { c in Text(c.displayName).tag(c) }
                }
                Picker(L("prefs.frame_rate"), selection: $settings.frameRate) {
                    Text("24 fps").tag(24)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker(L("prefs.countdown"), selection: $settings.countdownSeconds) {
                    Text(L("prefs.countdown_off")).tag(0)
                    Text("3 s").tag(3)
                    Text("5 s").tag(5)
                    Text("10 s").tag(10)
                }
            }
            Section(L("prefs.audio")) {
                Toggle(L("prefs.system_audio"), isOn: $settings.captureSystemAudio)
                Toggle(L("prefs.microphone"), isOn: $settings.captureMicrophone)
                if #unavailable(macOS 15.0) {
                    Text(L("prefs.mic_requires_15"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Toggle(L("prefs.show_cursor_rec"), isOn: $settings.showCursorInRecording)
            }
            Section {
                Text(L("prefs.record_tip"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Hotkeys

struct HotkeyPrefs: View {
    @State private var revision = 0

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(HotkeyAction.allCases) { action in
                        HotkeyRow(action: action, revision: $revision)
                    }
                }
            }
            .formStyle(.grouped)
            .id(revision)

            HStack {
                Text(L("prefs.hotkey_hint"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L("prefs.reset_hotkeys")) {
                    HotkeyManager.shared.resetToDefaults()
                    revision += 1
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
    }
}

struct HotkeyRow: View {
    let action: HotkeyAction
    @Binding var revision: Int

    private var conflicting: Bool { HotkeyManager.shared.failedActions.contains(action) }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L(action.titleKey))
                if conflicting {
                    Label(L("prefs.hotkey_conflict"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            HotkeyRecorderView(action: action) { revision += 1 }
            Button {
                HotkeyManager.shared.setHotkey(nil, for: action)
                revision += 1
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("prefs.hotkey_disable"))
            .opacity(HotkeyManager.shared.hotkey(for: action) == nil ? 0.3 : 1)
        }
    }
}

/// Click, then press the new shortcut. Esc cancels.
struct HotkeyRecorderView: View {
    let action: HotkeyAction
    let onChange: () -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stopRecording() : startRecording()
        } label: {
            Text(recording ? L("prefs.press_keys") : (HotkeyManager.shared.hotkey(for: action)?.display ?? L("prefs.hotkey_none")))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(minWidth: 110)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    recording ? Color(nsColor: Brand.accent).opacity(0.18) : Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(recording ? Color(nsColor: Brand.accent) : .clear, lineWidth: 1.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("prefs.hotkey_record_help"))
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc cancels
                stopRecording()
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let carbonMods = Hotkey.carbonModifiers(from: flags)
            guard carbonMods != 0 else { return nil } // require at least one modifier
            let hotkey = Hotkey(keyCode: UInt32(event.keyCode), modifiers: carbonMods)
            HotkeyManager.shared.setHotkey(hotkey, for: action)
            stopRecording()
            onChange()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - About

struct AboutPrefs: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer().frame(height: 10)
            AppIconView(size: 96)
            Text("SnapMark").font(.system(size: 24, weight: .bold, design: .rounded))
            Text(L("about.tagline"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Version 1.1.1 · Universal (Apple Silicon + Intel) · macOS 13+")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Divider().frame(width: 320)

            VStack(alignment: .leading, spacing: 6) {
                aboutRow("camera.viewfinder", L("about.f1"))
                aboutRow("video.badge.waveform", L("about.f2"))
                aboutRow("pencil.and.outline", L("about.f3"))
                aboutRow("text.viewfinder", L("about.f4"))
                aboutRow("pin", L("about.f5"))
            }
            .frame(width: 360, alignment: .leading)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func aboutRow(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: Brand.accent))
                .frame(width: 20)
            Text(text).font(.system(size: 12))
        }
    }
}
