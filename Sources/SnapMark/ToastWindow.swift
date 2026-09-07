import AppKit
import SwiftUI

/// Lightweight transient HUD notifications (works without a signed bundle,
/// unlike UserNotifications).
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var dismissWork: DispatchWorkItem?

    static func show(icon: String, text: String, subtitle: String? = nil, duration: TimeInterval = 2.2) {
        dismissWork?.cancel()
        panel?.orderOut(nil)

        let view = ToastView(icon: icon, text: text, subtitle: subtitle)
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize

        let p = NSPanel(contentRect: CGRect(origin: .zero, size: host.fittingSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.contentView = host
        p.alphaValue = 0

        let screen = NSScreen.main ?? NSScreen.screens.first
        if let f = screen?.visibleFrame {
            p.setFrameOrigin(CGPoint(x: f.midX - host.fittingSize.width / 2,
                                     y: f.maxY - host.fittingSize.height - 18))
        }
        p.orderFrontRegardless()
        panel = p

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak p] in
            guard let p else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                p.animator().alphaValue = 0
            }, completionHandler: {
                p.orderOut(nil)
                if panel === p { panel = nil }
            })
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

private struct ToastView: View {
    let icon: String
    let text: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LinearGradient(
                    colors: [Color(red: 0.45, green: 0.38, blue: 1.0), Color(red: 0.62, green: 0.32, blue: 0.96)],
                    startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 1) {
                Text(text).font(.system(size: 12.5, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 260, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .fixedSize()
    }
}
