import AppKit
import SwiftUI

/// Polls the Screen Recording permission while a UI that displays it is visible.
final class PermissionMonitor: ObservableObject {
    static let shared = PermissionMonitor()

    @Published private(set) var granted = CaptureEngine.hasPermission()
    private var timer: Timer?
    private var observers = 0

    func startPolling() {
        observers += 1
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stopPolling() {
        observers = max(0, observers - 1)
        if observers == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    func refresh() {
        let g = CaptureEngine.hasPermission()
        if g != granted { granted = g }
    }
}

/// First-run / quick-start window: what SnapMark is, permission status, the shortcuts.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private static var current: WelcomeWindowController?

    static func show() {
        if let current {
            current.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = WelcomeWindowController()
        current = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 640),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = "SnapMark"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: WelcomeView(onClose: { [weak self] in self?.window?.close() }))
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }
}

struct WelcomeView: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var perm = PermissionMonitor.shared
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                AppIconView(size: 84)
                Text("SnapMark").font(.system(size: 26, weight: .bold, design: .rounded))
                Text(L("welcome.subtitle"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            .padding(.top, 36)
            .padding(.bottom, 22)

            VStack(spacing: 12) {
                PermissionCard()
                HotkeyCard()
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                Toggle(L("prefs.launch_at_login"), isOn: $settings.launchAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Spacer()
                Picker("", selection: Binding(get: { l10n.language }, set: { l10n.setLanguage($0) })) {
                    ForEach(L10n.Language.allCases) { lang in Text(lang.displayName).tag(lang) }
                }
                .labelsHidden()
                .frame(width: 130)
                Button(L("welcome.prefs")) { PreferencesWindowController.show() }
                Button(L("welcome.start")) { onClose() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(nsColor: Brand.accent))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 520, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { perm.startPolling() }
        .onDisappear { perm.stopPolling() }
        .id(l10n.revision)
    }
}

/// Screen Recording permission status with the exact steps to fix it.
struct PermissionCard: View {
    @ObservedObject private var perm = PermissionMonitor.shared
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: perm.granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(perm.granted ? Color.green : Color.orange)
                .frame(width: 28)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                Text(perm.granted ? L("perm.status_granted") : L("perm.status_missing"))
                    .font(.system(size: 13, weight: .semibold))
                Text(perm.granted ? L("perm.granted_body") : L("perm.missing_body"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !perm.granted {
                    if !compact {
                        Text(L("perm.regrant_note"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button(L("perm.open_settings")) { AppCoordinator.shared.openScreenRecordingSettings() }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .controlSize(.small)
                        Button(L("perm.reset_record")) { AppCoordinator.shared.resetPermissionRecord() }
                            .controlSize(.small)
                            .help(L("perm.reset_record_help"))
                        Button(L("perm.relaunch")) { AppCoordinator.shared.relaunch() }
                            .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((perm.granted ? Color.green : Color.orange).opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder((perm.granted ? Color.green : Color.orange).opacity(0.25))
        )
        .animation(.easeInOut(duration: 0.2), value: perm.granted)
    }
}

/// The main shortcuts, read live from the hotkey manager.
struct HotkeyCard: View {
    private let rows: [(HotkeyAction, String)] = [
        (.captureRegion, "rectangle.dashed"),
        (.captureWindow, "macwindow.on.rectangle"),
        (.captureFullScreen, "macwindow"),
        (.recordRegion, "record.circle"),
        (.ocrRegion, "text.viewfinder"),
        (.pinRegion, "pin"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("welcome.hotkeys_title")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(L("welcome.hotkeys_hint")).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider().opacity(0.5)
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                HStack(spacing: 10) {
                    Image(systemName: row.1)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(nsColor: Brand.accent))
                        .frame(width: 18)
                    Text(L(row.0.titleKey)).font(.system(size: 12))
                    Spacer()
                    Text(HotkeyManager.shared.hotkey(for: row.0)?.display ?? L("prefs.hotkey_none"))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                if idx < rows.count - 1 { Divider().opacity(0.3).padding(.leading, 42) }
            }
            Spacer().frame(height: 6)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// The app icon rendered live (so it always matches the .icns).
struct AppIconView: View {
    var size: CGFloat = 96

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.36, green: 0.31, blue: 0.98), Color(red: 0.55, green: 0.30, blue: 0.98), Color(red: 0.78, green: 0.28, blue: 0.90)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: Color(nsColor: Brand.accent).opacity(0.4), radius: size * 0.18, y: size * 0.06)
            Image(systemName: "camera.viewfinder")
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}
