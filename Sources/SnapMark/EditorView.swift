import AppKit
import SwiftUI

struct EditorActions {
    var done: () -> Void
    var save: () -> Void
    var saveAs: () -> Void
    var copy: () -> Void
    var pin: () -> Void
    var reveal: () -> Void
}

let accentGradient = LinearGradient(
    colors: [Color(nsColor: Brand.accentTop), Color(nsColor: Brand.accentBottom)],
    startPoint: .top, endPoint: .bottom)

// MARK: - Root

struct EditorRootView: View {
    @ObservedObject var state: EditorState
    @ObservedObject private var l10n = L10n.shared
    let actions: EditorActions

    var body: some View {
        VStack(spacing: 0) {
            EditorTopBar(state: state, actions: actions)
            Divider().opacity(0.4)
            EditorStyleRow(state: state)
            if state.tool == .text || state.inspectedIsText {
                Divider().opacity(0.4)
                TextFormatBar(state: state)
            }
            Divider().opacity(0.6)
            EditorCanvasArea(state: state)
            Divider().opacity(0.6)
            EditorBottomBar(state: state)
        }
        .frame(minWidth: 960, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .id(l10n.revision)
    }
}

// MARK: - Top bar

struct EditorTopBar: View {
    @ObservedObject var state: EditorState
    let actions: EditorActions

    @State private var showOCRPopover = false
    @State private var ocrText: String?
    @State private var ocrRunning = false

    private let drawTools: [Tool] = [.select, .pen, .highlighter, .line, .arrow, .rect, .ellipse, .text, .mosaic, .badge, .crop]

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(drawTools) { tool in
                    ToolButton(tool: tool, isActive: state.tool == tool) { state.tool = tool }
                }
            }
            .padding(3)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Divider().frame(height: 20)

            if state.tool == .crop {
                Button(L("editor.apply_crop")) { state.applyCrop() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Color(nsColor: Brand.accent))
                    .disabled(state.cropRect == nil || (state.cropRect?.width ?? 0) < 8)
                Button(L("editor.cancel_crop")) {
                    state.cropRect = nil
                    state.tool = .select
                }
                .controlSize(.small)
            }

            Divider().frame(height: 20)

            HistoryButtons(state: state)

            Spacer(minLength: 8)

            // OCR
            Button { runOCR() } label: {
                HStack(spacing: 5) {
                    if ocrRunning {
                        ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "text.viewfinder").font(.system(size: 12, weight: .semibold))
                    }
                    Text(L("editor.ocr")).font(.system(size: 12, weight: .medium)).fixedSize()
                }
                .padding(.horizontal, 10)
                .frame(height: 27)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(ocrRunning)
            .help(L("editor.ocr_help"))
            .popover(isPresented: $showOCRPopover, arrowEdge: .bottom) { OCRResultView(text: ocrText ?? "") }

            secondaryButton("pin", L("editor.pin"), help: L("editor.pin_help"), action: actions.pin)
            secondaryButton("doc.on.doc", L("editor.copy"), help: L("editor.copy_help") + "  ⌘C", action: actions.copy)

            // Save + overflow menu sharing one pill.
            HStack(spacing: 0) {
                Button(action: actions.save) {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 12, weight: .semibold))
                        Text(L("editor.save")).font(.system(size: 12, weight: .medium)).fixedSize()
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 7)
                    .frame(height: 27)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("editor.save_help") + "  ⌘S")

                Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 15)

                Menu {
                    Button(L("editor.save_as") + "…") { actions.saveAs() }
                    Button(L("editor.reveal")) { actions.reveal() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 27)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22, height: 27)
                .help(L("editor.more"))
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Done: the one primary action — copy, save, close.
            Button(action: actions.done) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                    Text(L("editor.done")).font(.system(size: 12, weight: .semibold)).fixedSize()
                }
                .padding(.horizontal, 14)
                .frame(height: 27)
                .foregroundStyle(.white)
                .background(accentGradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: Color(nsColor: Brand.accent).opacity(0.35), radius: 6, y: 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("editor.done_help") + "  ⌘↩")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func secondaryButton(_ symbol: String, _ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium)).fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(height: 27)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func runOCR() {
        guard !ocrRunning else { return }
        ocrRunning = true
        let image = state.flatten()
        OCRService.recognize(image: image) { text in
            Task { @MainActor in
                ocrRunning = false
                ocrText = text
                if let text, !text.isEmpty {
                    Clipboard.copy(text: text)
                    showOCRPopover = true
                    state.showStatus(L("toast.ocr_copied"))
                } else {
                    state.showStatus(L("toast.ocr_empty"))
                }
            }
        }
    }
}

struct ToolButton: View {
    let tool: Tool
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 26)
                .background(
                    isActive ? AnyShapeStyle(accentGradient) :
                        (hovering ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(Color.clear)),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .foregroundStyle(isActive ? .white : .primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L(tool.labelKey) + (tool.shortcutKey.map { "  \($0.uppercased())" } ?? ""))
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(help)
    }
}

/// Undo / redo buttons; observes the history so they enable as soon as there is something to undo.
struct HistoryButtons: View {
    @ObservedObject var state: EditorState

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "arrow.uturn.backward", help: L("editor.undo"), disabled: !state.canUndo) { state.undo() }
            IconButton(symbol: "arrow.uturn.forward", help: L("editor.redo"), disabled: !state.canRedo) { state.redo() }
        }
    }
}

/// Second toolbar row: colors, sizes, mosaic mode and selection actions.
struct EditorStyleRow: View {
    @ObservedObject var state: EditorState

    var body: some View {
        HStack(spacing: 10) {
            AnnotationStyleBar(state: state)
            Spacer(minLength: 0)
            if !state.annotations.isEmpty {
                Button {
                    state.removeAllAnnotations()
                } label: {
                    Label(L("editor.clear_all"), systemImage: "eraser")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("editor.clear_all_help"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(minHeight: 34)
        .background(.bar)
    }
}

struct OCRResultView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "text.viewfinder")
                Text(L("editor.ocr_result")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(L("editor.copy")) { Clipboard.copy(text: text) }
                    .controlSize(.small)
            }
            ScrollView {
                Text(text.isEmpty ? L("toast.ocr_empty") : text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 320, height: 180)
            .padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
    }
}

// MARK: - Canvas area

struct EditorCanvasArea: View {
    @ObservedObject var state: EditorState

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                AnnotationCanvasRepresentable(state: state)
                    .frame(width: max(1, state.displaySize.width), height: max(1, state.displaySize.height))
                    .background(
                        Rectangle()
                            .fill(Color.white)
                            .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
                    )
                    // Centered with breathing room; grows the scrollable area when zoomed in.
                    .frame(width: max(state.displaySize.width + 48, geo.size.width),
                           height: max(state.displaySize.height + 48, geo.size.height))
            }
            .background(CheckerboardBackground())
            .onAppear {
                state.viewportSize = geo.size
                state.zoomToFit()
            }
            .onChange(of: geo.size) { newSize in
                state.viewportSize = newSize
            }
        }
    }
}

struct CheckerboardBackground: View {
    var body: some View {
        Canvas { gc, size in
            let cell: CGFloat = 12
            gc.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .underPageBackgroundColor)))
            let tint = Color.primary.opacity(0.035)
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : cell
                while x < size.width {
                    gc.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(tint))
                    x += cell * 2
                }
                y += cell
                row += 1
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Bottom bar

struct EditorBottomBar: View {
    @ObservedObject var state: EditorState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.tool.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(nsColor: Brand.accent))
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if let status = state.statusMessage {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(status).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: 360)
                .transition(.opacity)
            }

            Spacer()

            HStack(spacing: 4) {
                IconButton(symbol: "minus.magnifyingglass", help: L("editor.zoom_out")) {
                    state.setZoom(state.zoom / 1.25)
                }
                Text("\(Int((state.zoom * 100).rounded()))%")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 44)
                IconButton(symbol: "plus.magnifyingglass", help: L("editor.zoom_in")) {
                    state.setZoom(state.zoom * 1.25)
                }
                Button(L("editor.fit")) { state.zoomToFit() }
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .help(L("menu.zoom_fit") + "  ⌘9")
                Button("1:1") { state.setZoom(1) }
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .help(L("menu.zoom_actual") + "  ⌘0")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .animation(.easeInOut(duration: 0.2), value: state.statusMessage)
    }

    private var hint: String {
        switch state.tool {
        case .select: return L("hint.select")
        case .crop: return L("hint.crop")
        case .text: return L("hint.text")
        case .badge: return L("hint.badge")
        case .line, .arrow, .rect, .ellipse: return L("hint.shape")
        default: return L("hint.draw")
        }
    }
}

// MARK: - Text format bar (font, size, style, alignment, plate/outline/shadow)

struct TextFormatBar: View {
    @ObservedObject var state: EditorState
    @State private var showFonts = false

    private var familyLabel: String {
        guard let family = state.textStyle.fontFamily else { return L("text.system_font") }
        return NSFontManager.shared.localizedName(forFamily: family, face: nil)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "t.square")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: Brand.accent))

            // Font family
            Button { showFonts.toggle() } label: {
                HStack(spacing: 6) {
                    Text(familyLabel)
                        .font(Font(state.textStyle.font(size: 12)))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .frame(width: 170, height: 26)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("text.font"))
            .popover(isPresented: $showFonts, arrowEdge: .bottom) {
                FontPickerPopover(state: state, isPresented: $showFonts)
            }

            // Size
            HStack(spacing: 0) {
                stepButton("minus") { state.adjustFontSize(by: -2) }
                Text("\(Int(state.fontSizePt.rounded()))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .frame(width: 34)
                stepButton("plus") { state.adjustFontSize(by: 2) }
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .help(L("text.size") + "  ⌥⌘↑ / ⌥⌘↓")
            Slider(value: $state.fontSizePt, in: 6...120, step: 1)
                .frame(width: 110)
                .controlSize(.small)

            Divider().frame(height: 18)

            styleToggle("bold", isOn: $state.textStyle.bold, help: L("text.bold"))
            styleToggle("italic", isOn: $state.textStyle.italic, help: L("text.italic"))
            styleToggle("underline", isOn: $state.textStyle.underline, help: L("text.underline"))
            styleToggle("strikethrough", isOn: $state.textStyle.strikethrough, help: L("text.strike"))

            Divider().frame(height: 18)

            alignToggle(.left, "text.alignleft", L("text.align_left"))
            alignToggle(.center, "text.aligncenter", L("text.align_center"))
            alignToggle(.right, "text.alignright", L("text.align_right"))

            Divider().frame(height: 18)

            chip(L("text.plate"), isOn: $state.textStyle.plate, help: L("text.plate_help"))
            chip(L("text.outline"), isOn: $state.textStyle.outline, help: L("text.outline_help"))
            chip(L("text.shadow"), isOn: $state.textStyle.shadow, help: L("text.shadow_help"))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func styleToggle(_ symbol: String, isOn: Binding<Bool>, help: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(isOn.wrappedValue ? AnyShapeStyle(accentGradient) : AnyShapeStyle(Color.primary.opacity(0.06)),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .foregroundStyle(isOn.wrappedValue ? .white : .primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func alignToggle(_ align: TextAlign, _ symbol: String, _ help: String) -> some View {
        let active = state.textStyle.alignment == align
        return Button { state.textStyle.alignment = align } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(active ? AnyShapeStyle(accentGradient) : AnyShapeStyle(Color.primary.opacity(0.06)),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .foregroundStyle(active ? .white : .primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func chip(_ title: String, isOn: Binding<Bool>, help: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(isOn.wrappedValue ? AnyShapeStyle(accentGradient) : AnyShapeStyle(Color.primary.opacity(0.06)),
                            in: Capsule())
                .foregroundStyle(isOn.wrappedValue ? .white : .primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Searchable font list; each family is previewed in its own face.
struct FontPickerPopover: View {
    @ObservedObject var state: EditorState
    @Binding var isPresented: Bool
    @State private var query = ""

    private static let preferred = [
        "PingFang TC", "PingFang SC", "Heiti TC", "Songti TC", "Songti SC", "Kaiti TC", "Kaiti SC",
        "Yuanti TC", "Yuanti SC", "Hiragino Sans", "Helvetica Neue", "Avenir Next", "Futura", "Georgia",
        "Menlo", "Marker Felt", "Chalkboard SE", "American Typewriter", "Noteworthy",
    ]
    private let allFamilies: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    private var common: [String] { Self.preferred.filter { allFamilies.contains($0) } }
    private var filtered: [String] {
        guard !query.isEmpty else { return allFamilies }
        return allFamilies.filter {
            $0.localizedCaseInsensitiveContains(query)
                || NSFontManager.shared.localizedName(forFamily: $0, face: nil).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField(L("text.search_font"), text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    row(nil)
                    if query.isEmpty {
                        header(L("text.common_fonts"))
                        ForEach(common, id: \.self) { row($0) }
                        header(L("text.all_fonts"))
                    }
                    ForEach(filtered, id: \.self) { row($0) }
                }
            }
            .frame(width: 270, height: 330)
        }
        .padding(10)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .padding(.horizontal, 6)
    }

    private func row(_ family: String?) -> some View {
        let selected = state.textStyle.fontFamily == family
        let name = family.map { NSFontManager.shared.localizedName(forFamily: $0, face: nil) } ?? L("text.system_font")
        let preview = family.flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: 14) }
            ?? NSFont.systemFont(ofSize: 14)
        return Button {
            state.textStyle.fontFamily = family
            isPresented = false
        } label: {
            HStack {
                Text(name).font(Font(preview)).lineLimit(1)
                Spacer()
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(nsColor: Brand.accent))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(selected ? Color(nsColor: Brand.accent).opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
