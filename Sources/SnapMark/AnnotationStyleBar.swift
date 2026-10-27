import AppKit
import SwiftUI

/// Colors, stroke sizes, quick text options and actions for the selection — shared by the editor
/// window and the capture overlay. Everything applies to the selected annotation as well as the
/// next one drawn.
struct AnnotationStyleBar: View {
    @ObservedObject var state: EditorState
    /// The overlay variant: no popovers or color panel (they would open behind the full-screen overlay),
    /// and the quick text options live here instead of in the editor's text format bar.
    var compact = false
    var onHint: (String?) -> Void = { _ in }

    static let sizeSteps: [CGFloat] = [2, 4, 7, 12]

    /// What the controls are describing: the selected/edited annotation, else the active tool.
    private var kind: Annotation.Kind? {
        if let a = state.inspected { return a.kind }
        switch state.tool {
        case .pen: return .pen
        case .highlighter: return .highlighter
        case .line: return .line
        case .arrow: return .arrow
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .text: return .text
        case .mosaic: return .mosaic
        case .badge: return .badge
        case .select, .crop: return nil
        }
    }

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            if state.tool == .crop, state.selectedID == nil {
                EmptyView()
            } else if kind != .mosaic {
                swatches
            }
            if let kind, kind != .text {
                if kind != .mosaic { divider }
                sizeDots(for: kind)
            }
            if kind == .mosaic {
                divider
                mosaicMode
            }
            if compact, kind == .text {
                divider
                quickText
            }
            if state.selectedID != nil {
                divider
                selectionActions
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1, height: 16)
    }

    // MARK: Colors

    private var swatches: some View {
        HStack(spacing: compact ? 5 : 6) {
            ForEach(Array(RGBA.presets.enumerated()), id: \.offset) { _, preset in
                let selected = state.color == preset
                Button { state.color = preset } label: {
                    Circle()
                        .fill(preset.color)
                        .frame(width: compact ? 15 : 16, height: compact ? 15 : 16)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.5))
                        .padding(2.5)
                        .overlay(Circle().strokeBorder(selected ? Color(nsColor: Brand.accent) : .clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { onHint($0 ? L("editor.color") : nil) }
            }
            if !compact {
                customColorButton
            }
        }
    }

    /// Opens the system color panel (editor only: it can't show above the full-screen overlay).
    private var customColorButton: some View {
        let isCustom = !RGBA.presets.contains(state.color)
        return Button {
            ColorPanelBridge.shared.open(with: state.color) { [weak state] color in state?.color = color }
        } label: {
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                if isCustom {
                    Circle().fill(state.color.color).frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                }
            }
            .frame(width: 16, height: 16)
            .padding(2.5)
            .overlay(Circle().strokeBorder(isCustom ? Color(nsColor: Brand.accent) : .clear, lineWidth: 2))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L("editor.custom_color"))
    }

    // MARK: Sizes

    private func sizeDots(for kind: Annotation.Kind) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(Self.sizeSteps.enumerated()), id: \.offset) { index, size in
                let selected = abs(state.lineWidthPt - size) < 0.5
                Button { state.lineWidthPt = size } label: {
                    Circle()
                        .fill(selected ? Color(nsColor: Brand.accent) : Color.primary.opacity(0.55))
                        .frame(width: 4 + CGFloat(index) * 3.5, height: 4 + CGFloat(index) * 3.5)
                        .frame(width: 22, height: 22)
                        .background(selected ? Color(nsColor: Brand.accent).opacity(0.14) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { onHint($0 ? L(kind == .badge ? "style.badge_size" : (kind == .mosaic ? "style.brush" : "editor.stroke_width")) : nil) }
            }
        }
        .help(L("editor.stroke_width"))
    }

    private var mosaicMode: some View {
        HStack(spacing: 2) {
            modeButton(L("editor.pixelate"), "square.grid.3x3.fill", selected: !state.mosaicBlur) { state.mosaicBlur = false }
            modeButton(L("editor.blur"), "drop.fill", selected: state.mosaicBlur) { state.mosaicBlur = true }
        }
    }

    private func modeButton(_ title: String, _ symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium)).fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(selected ? AnyShapeStyle(accentGradient) : AnyShapeStyle(Color.primary.opacity(0.06)),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .foregroundStyle(selected ? .white : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Text (overlay)

    private var quickText: some View {
        HStack(spacing: 4) {
            HStack(spacing: 0) {
                smallIcon("minus") { state.adjustFontSize(by: -2) }
                Text("\(Int(state.fontSizePt.rounded()))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(width: 26)
                smallIcon("plus") { state.adjustFontSize(by: 2) }
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { onHint($0 ? L("text.size") + "  ⌥⌘↑ ⌥⌘↓" : nil) }
            toggle("bold", isOn: $state.textStyle.bold, hint: L("text.bold"))
            toggle("rectangle.fill", isOn: $state.textStyle.plate, hint: L("text.plate"))
            toggle("character.textbox", isOn: $state.textStyle.outline, hint: L("text.outline"))
        }
    }

    private func smallIcon(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ symbol: String, isOn: Binding<Bool>, hint: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22)
                .background(isOn.wrappedValue ? AnyShapeStyle(accentGradient) : AnyShapeStyle(Color.primary.opacity(0.06)),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(isOn.wrappedValue ? .white : .primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hint)
        .onHover { onHint($0 ? hint : nil) }
    }

    // MARK: Selection

    private var selectionActions: some View {
        HStack(spacing: 2) {
            actionIcon("plus.square.on.square", hint: L("ctx.duplicate") + "  ⌘D") { state.duplicateSelected() }
            actionIcon("square.3.layers.3d.top.filled", hint: L("ctx.front") + "  ⌘]") { state.bringSelectedToFront() }
            actionIcon("trash", hint: L("ctx.delete") + "  ⌫", tint: .red) { state.deleteSelected() }
        }
    }

    private func actionIcon(_ symbol: String, hint: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hint)
        .onHover { onHint($0 ? hint : nil) }
    }
}

/// Routes the shared NSColorPanel to whoever opened it last.
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((RGBA) -> Void)?

    func open(with color: RGBA, onChange: @escaping (RGBA) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.color = color.nsColor
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let c = sender.color.usingColorSpace(.sRGB) else { return }
        onChange?(RGBA(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: 1))
    }
}
