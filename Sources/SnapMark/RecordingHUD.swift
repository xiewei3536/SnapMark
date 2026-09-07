import AppKit
import AVFoundation
import SwiftUI

/// Owns all the chrome shown while recording: countdown, region outline, control HUD.
/// (Every SnapMark window is excluded from the capture via the content filter.)
@MainActor
final class RecordingSession {
    static let shared = RecordingSession()

    private var hudPanel: NSPanel?
    private var borderWindow: NSWindow?
    private var countdownWindow: NSWindow?
    private var countdownTimer: Timer?
    private var screen: NSScreen?
    private var localRect: CGRect?

    var isActive: Bool { RecorderEngine.shared.isRecording }
    var isCountingDown: Bool { countdownWindow != nil }

    /// Full pipeline: optional countdown → start engine → show HUD.
    func begin(screen: NSScreen, localRect: CGRect?) {
        guard !RecorderEngine.shared.isRecording, !isCountingDown else { return }
        self.screen = screen
        self.localRect = localRect

        // Registered up front so an engine-side stop (stream error) also tears the HUD down.
        RecorderEngine.shared.onFinish = { [weak self] url in
            Task { @MainActor in self?.recordingFinished(url: url) }
        }

        let countdown = Settings.shared.countdownSeconds
        if countdown > 0 {
            showCountdown(seconds: countdown, on: screen, localRect: localRect)
        } else {
            reallyStart()
        }
    }

    func cancelCountdown() {
        dismissCountdown()
        Toast.show(icon: "xmark.circle", text: L("toast.record_cancelled"), duration: 1.4)
    }

    private func dismissCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownWindow?.orderOut(nil)
        countdownWindow = nil
    }

    private func reallyStart() {
        guard let screen else { return }
        Task { @MainActor in
            await RecorderEngine.shared.start(screen: screen, localRect: localRect)
            guard RecorderEngine.shared.isRecording else { return }
            showBorder()
            showHUD()
            AppCoordinator.shared.recordingStateChanged()
        }
    }

    func stop(discard: Bool = false) {
        if isCountingDown {
            cancelCountdown()
            return
        }
        RecorderEngine.shared.stop(discard: discard)
    }

    private func recordingFinished(url: URL?) {
        teardown()
        AppCoordinator.shared.recordingStateChanged()
        if let url {
            HistoryManager.shared.add(fileURL: url, kind: .video)
            RecordingDonePanel.show(url: url)
        }
    }

    private func teardown() {
        hudPanel?.orderOut(nil)
        hudPanel = nil
        borderWindow?.orderOut(nil)
        borderWindow = nil
    }

    // MARK: Countdown

    private func showCountdown(seconds: Int, on screen: NSScreen, localRect: CGRect?) {
        let targetCocoa: CGRect
        if let r = localRect {
            targetCocoa = CGRect(x: screen.frame.minX + r.minX, y: screen.frame.maxY - r.maxY,
                                 width: r.width, height: r.height)
        } else {
            targetCocoa = screen.frame
        }
        let size = CGSize(width: 170, height: 200)
        let frame = CGRect(x: targetCocoa.midX - size.width / 2, y: targetCocoa.midY - size.height / 2,
                           width: size.width, height: size.height)
        let win = KeyablePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false

        let model = CountdownModel(count: seconds)
        win.contentView = NSHostingView(rootView: CountdownView(model: model) { [weak self] in
            self?.cancelCountdown()
        })
        win.orderFrontRegardless()
        countdownWindow = win

        var remaining = seconds
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            remaining -= 1
            Task { @MainActor in
                guard let self, self.countdownWindow === win else {
                    timer.invalidate()
                    return
                }
                if remaining <= 0 {
                    self.dismissCountdown()
                    self.reallyStart()
                } else {
                    model.count = remaining
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    // MARK: Region border

    private func showBorder() {
        guard let screen, let r = localRect else { return }
        let cocoa = CGRect(x: screen.frame.minX + r.minX, y: screen.frame.maxY - r.maxY,
                           width: r.width, height: r.height).insetBy(dx: -3, dy: -3)
        let win = NSWindow(contentRect: cocoa, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: RecordingBorderView())
        win.orderFrontRegardless()
        borderWindow = win
    }

    // MARK: Control HUD

    private func showHUD() {
        guard let screen else { return }
        let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let regionText: String
        if let r = localRect {
            regionText = "\(Int(r.width * screen.backingScaleFactor)) × \(Int(r.height * screen.backingScaleFactor))"
        } else {
            regionText = L("hud.fullscreen")
        }
        let stopHotkey = HotkeyManager.shared.hotkey(for: localRect == nil ? .recordFullScreen : .recordRegion)?.display
        let view = RecordingHUDView(
            regionText: regionText,
            stopHotkey: stopHotkey,
            onStop: { [weak self] in self?.stop() },
            onDiscard: { [weak self] in self?.stop(discard: true) }
        )
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        panel.setContentSize(host.fittingSize)
        panel.contentView = host

        // Bottom center of the screen, but never on top of the recorded region.
        let f = screen.visibleFrame
        var origin = CGPoint(x: f.midX - host.fittingSize.width / 2, y: f.minY + 24)
        if let r = localRect {
            let regionCocoa = CGRect(x: screen.frame.minX + r.minX, y: screen.frame.maxY - r.maxY,
                                     width: r.width, height: r.height)
            let hudRect = CGRect(origin: origin, size: host.fittingSize)
            if hudRect.intersects(regionCocoa.insetBy(dx: -8, dy: -8)) {
                origin.y = f.maxY - host.fittingSize.height - 24
                let topRect = CGRect(origin: origin, size: host.fittingSize)
                if topRect.intersects(regionCocoa.insetBy(dx: -8, dy: -8)) {
                    origin.x = f.minX + 24 // top-left corner as a last resort
                }
            }
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        hudPanel = panel
    }
}

// MARK: - Views

final class CountdownModel: ObservableObject, @unchecked Sendable {
    @Published var count: Int
    init(count: Int) { self.count = count }
}

struct CountdownView: View {
    @ObservedObject var model: CountdownModel
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(.black.opacity(0.55))
                Circle().strokeBorder(.white.opacity(0.25), lineWidth: 2)
                Text("\(model.count)")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: model.count)
            }
            .frame(width: 140, height: 140)

            Button(action: onCancel) {
                Text(L("hud.countdown_cancel"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 170, height: 200)
    }
}

struct RecordingBorderView: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(style: StrokeStyle(lineWidth: 2.5, dash: [8, 6], dashPhase: phase))
            .foregroundStyle(Color(nsColor: Brand.recordRed))
            .padding(1)
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    phase = -14
                }
            }
    }
}

struct RecordingHUDView: View {
    let regionText: String
    let stopHotkey: String?
    let onStop: () -> Void
    let onDiscard: () -> Void

    @ObservedObject private var engine = RecorderEngine.shared
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: Brand.recordRed))
                .frame(width: 10, height: 10)
                .opacity(pulsing ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = true }

            Text(formatDuration(engine.elapsed))
                .font(.system(size: 15, weight: .semibold, design: .monospaced))

            Text(regionText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            Divider().frame(height: 18)

            Button(action: onStop) {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                    Text(L("hud.stop")).font(.system(size: 12, weight: .semibold))
                    if let stopHotkey {
                        Text(stopHotkey)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .opacity(0.75)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Color(nsColor: Brand.recordRed), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .foregroundStyle(.white)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("hud.stop_help"))

            Button(action: onDiscard) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("hud.discard_help"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .fixedSize()
    }
}

// MARK: - Recording done panel

@MainActor
final class RecordingDonePanel {
    private static var panel: NSPanel?

    static func show(url: URL) {
        dismiss()
        let p = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = RecordingDoneView(url: url, onClose: { dismiss() })
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        p.setContentSize(host.fittingSize)
        p.contentView = host

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(CGPoint(x: f.maxX - host.fittingSize.width - 24, y: f.minY + 24))
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 1
        }
        panel = p

        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak p] in
            if panel === p { dismiss() }
        }
    }

    static func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct RecordingDoneView: View {
    let url: URL
    let onClose: () -> Void

    @State private var thumbnail: NSImage?
    @State private var info: String = ""
    @State private var exportingGIF = false
    @State private var gifProgress: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(L("done.recording_saved")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(width: 96, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(info).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 220, alignment: .leading)
            }

            if exportingGIF {
                ProgressView(value: gifProgress) {
                    Text(L("done.exporting_gif")).font(.system(size: 11))
                }
                .progressViewStyle(.linear)
            }

            HStack(spacing: 8) {
                pillButton("play.fill", L("done.open")) { NSWorkspace.shared.open(url) }
                pillButton("folder", L("done.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                pillButton("doc.on.doc", L("done.copy")) {
                    Clipboard.copy(fileURL: url)
                    Toast.show(icon: "doc.on.doc.fill", text: L("toast.file_copied"))
                }
                pillButton("photo.stack", "GIF") { exportGIF() }
                    .disabled(exportingGIF)
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.14)))
        .task { await loadMeta() }
    }

    private func pillButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func loadMeta() async {
        let asset = AVURLAsset(url: url)
        var seconds: Double = 0
        if let duration = try? await asset.load(.duration) {
            seconds = CMTimeGetSeconds(duration)
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 240)
        let t = CMTime(seconds: min(0.3, seconds / 2), preferredTimescale: 600)
        let cg = try? await gen.image(at: t).image
        info = "\(formatDuration(seconds)) · \(formatBytes(bytes))"
        if let cg { thumbnail = NSImage(cgImage: cg, size: .zero) }
    }

    private func exportGIF() {
        exportingGIF = true
        gifProgress = 0
        let src = url
        let dst = src.deletingPathExtension().appendingPathExtension("gif")
        GIFExporter.export(videoURL: src, to: dst, fps: 10, maxWidth: 800) { p in
            Task { @MainActor in gifProgress = p }
        } completion: { result in
            Task { @MainActor in
                exportingGIF = false
                switch result {
                case .success:
                    HistoryManager.shared.add(fileURL: dst, kind: .video)
                    Toast.show(icon: "photo.stack", text: L("toast.gif_saved"), subtitle: dst.lastPathComponent)
                    NSWorkspace.shared.activateFileViewerSelecting([dst])
                case .failure:
                    Toast.show(icon: "exclamationmark.triangle.fill", text: L("toast.gif_failed"))
                }
            }
        }
    }
}
