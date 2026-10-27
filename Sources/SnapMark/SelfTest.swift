import AppKit
import SwiftUI

/// `SnapMark --selftest <dir>` — exercises annotation editing in-process: the model, the canvas,
/// the editor window and the capture overlay. Events are synthesized and handed straight to the
/// views (nothing is posted to the system, no window is ever shown), so it can run while you use
/// the Mac. Renders are written to `<dir>` for a visual check; exits 0 when every check passes.
@MainActor
enum SelfTest {
    private static var failures: [String] = []
    private static var passes = 0
    private static var outDir = URL(fileURLWithPath: "/tmp")

    static func run(outDir dir: URL) -> Never {
        outDir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ProjectStore.directoryOverride = dir.appendingPathComponent("projects", isDirectory: true)

        section("model: handles and transforms", modelTests)
        section("state: drawing, moving, stretching, undo", stateTests)
        section("state: text editing and undo", textTests)
        section("state: badges, duplicate, order, nudge, crop", miscTests)
        section("state: undo grouping and redo safety", undoEdgeTests)
        section("canvas: real mouse events", canvasTests)
        section("editor window: keys, render", editorWindowTests)
        section("overlay: annotate in place", overlayTests)
        section("project store: re-editable saves", projectTests)
        section("capture preview thumbnail", previewTests)

        print("\nSELFTEST \(failures.isEmpty ? "PASS" : "FAIL") — \(passes) passed, \(failures.count) failed")
        for f in failures { print("  ✗ \(f)") }
        fflush(stdout)
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: Harness

    private static var current = ""

    private static func section(_ name: String, _ body: () -> Void) {
        current = name
        print("▸ \(name)")
        body()
    }

    private static func check(_ condition: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            passes += 1
        } else {
            let d = detail()
            failures.append("[\(current)] \(what)" + (d.isEmpty ? "" : " — \(d)"))
            print("  ✗ \(what) \(d)")
        }
    }

    private static func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.6) -> Bool { abs(a - b) <= tol }
    private static func near(_ a: CGRect, _ b: CGRect, _ tol: CGFloat = 0.6) -> Bool {
        near(a.minX, b.minX, tol) && near(a.minY, b.minY, tol) && near(a.width, b.width, tol) && near(a.height, b.height, tol)
    }

    /// Lets Combine sinks scheduled on the main run loop (canvas sync, toolbar layout) run.
    private static func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// A synthetic screenshot: gradient, blocks and some text, `pts` points at `scale`.
    static func sampleImage(points pts: CGSize = CGSize(width: 640, height: 400), scale: CGFloat = 2) -> CapturedImage {
        let w = Int(pts.width * scale), h = Int(pts.height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let colors = [CGColor(srgbRed: 0.93, green: 0.95, blue: 0.99, alpha: 1), CGColor(srgbRed: 0.80, green: 0.86, blue: 0.97, alpha: 1)]
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: w / 10, y: h / 6, width: w * 8 / 10, height: h * 2 / 3))
        for i in 0..<8 {
            ctx.setFillColor(CGColor(srgbRed: 0.3 + 0.08 * CGFloat(i), green: 0.45, blue: 0.85 - 0.06 * CGFloat(i), alpha: 1))
            ctx.fill(CGRect(x: w / 8 + i * w / 11, y: h / 4, width: w / 14, height: h / 9))
        }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15 * scale, weight: .semibold),
                                                    .foregroundColor: NSColor.darkGray]
        for (i, line) in ["SnapMark self-test 截圖標註測試", "Move · Stretch · Undo · 復原", "0800-080-212  ⌘Z ⇧⌘Z"].enumerated() {
            (line as NSString).draw(at: CGPoint(x: CGFloat(w) * 0.14, y: CGFloat(h) * 0.62 - CGFloat(i) * 26 * scale), withAttributes: attrs)
        }
        NSGraphicsContext.current = previous
        return CapturedImage(cgImage: ctx.makeImage()!, scale: scale)
    }

    private static func mouse(_ type: NSEvent.EventType, _ p: CGPoint, in view: NSView,
                              clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: flags,
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
                           context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// Press, drag in steps, release — delivered to `view` (view-local, flipped points).
    private static func drag(_ view: NSView, from a: CGPoint, to b: CGPoint, steps: Int = 8,
                             flags: NSEvent.ModifierFlags = []) {
        view.mouseDown(with: mouse(.leftMouseDown, a, in: view, flags: flags))
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                                          in: view, flags: flags))
        }
        view.mouseUp(with: mouse(.leftMouseUp, b, in: view, flags: flags))
    }

    private static func click(_ view: NSView, _ p: CGPoint, clicks: Int = 1) {
        for n in 1...clicks {
            view.mouseDown(with: mouse(.leftMouseDown, p, in: view, clicks: n))
            view.mouseUp(with: mouse(.leftMouseUp, p, in: view, clicks: n))
        }
    }

    private static func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], _ chars: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    private static func savePNG(_ view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(name))
    }

    private static func savePNG(_ image: CGImage, _ name: String) {
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: outDir.appendingPathComponent(name))
    }

    private static func makeState(scale: CGFloat = 2) -> EditorState {
        let st = EditorState(image: sampleImage(scale: scale), originalURL: nil)
        st.zoom = 1 // pxToView = 1/scale
        return st
    }

    // MARK: Model

    private static func modelTests() {
        var r = Annotation(kind: .rect)
        r.start = CGPoint(x: 100, y: 100); r.end = CGPoint(x: 300, y: 200)
        check(near(r.resized(.bottomRight, by: CGPoint(x: 50, y: 20), keepAspect: false).frame,
                   CGRect(x: 100, y: 100, width: 250, height: 120)), "rect corner stretch")
        check(near(r.resized(.right, by: CGPoint(x: 40, y: 99), keepAspect: false).frame,
                   CGRect(x: 100, y: 100, width: 240, height: 100)), "rect edge stretch only moves one edge")
        let aspect = r.resized(.bottomRight, by: CGPoint(x: 100, y: 0), keepAspect: true).frame
        check(near(aspect.width / aspect.height, 2, 0.01) && near(aspect.minX, 100) && near(aspect.minY, 100),
              "⇧ corner keeps 2:1 and the anchor", "\(aspect)")
        let mirrored = r.resized(.left, by: CGPoint(x: 260, y: 0), keepAspect: false).frame
        check(near(mirrored, CGRect(x: 300, y: 100, width: 60, height: 100)), "dragging past the opposite edge mirrors", "\(mirrored)")

        var pen = Annotation(kind: .pen)
        pen.points = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 50), CGPoint(x: 200, y: 100)]
        let scaled = pen.resized(.bottomRight, by: CGPoint(x: 200, y: 100), keepAspect: false)
        check(near(scaled.frame, CGRect(x: 0, y: 0, width: 400, height: 200)) && near(scaled.points[1].x, 200)
              && near(scaled.points[1].y, 100), "pen stroke scales with its box")
        var flat = Annotation(kind: .pen)
        flat.points = [CGPoint(x: 10, y: 50), CGPoint(x: 110, y: 50)]
        check(flat.handlePoints().count == 2, "a straight stroke only offers usable handles", "\(flat.handlePoints().map(\.0))")
        let flatMoved = flat.resized(.right, by: CGPoint(x: 50, y: 0), keepAspect: false)
        check(near(flatMoved.frame.width, 150) && flatMoved.points.allSatisfy { near($0.y, 50) }, "straight stroke stretches without NaN")

        var line = Annotation(kind: .arrow)
        line.start = CGPoint(x: 10, y: 10); line.end = CGPoint(x: 110, y: 10)
        let moved = line.resized(.lineEnd, by: CGPoint(x: 5, y: 40), keepAspect: false)
        check(moved.end == CGPoint(x: 115, y: 50) && moved.start == line.start, "arrow endpoint drags alone")
        let snapped = line.resized(.lineEnd, by: CGPoint(x: 0, y: 95), keepAspect: true)
        check(near(abs(snapped.end.x - snapped.start.x), abs(snapped.end.y - snapped.start.y), 0.5), "⇧ endpoint snaps to 45°")

        var text = Annotation(kind: .text)
        text.text = "Hello 你好"
        text.fontSize = 40
        text.start = CGPoint(x: 50, y: 60)
        let box = text.textBox
        let bigger = text.resized(.bottomRight, by: CGPoint(x: box.width, y: box.height), keepAspect: false)
        check(near(bigger.fontSize, 80, 0.5) && near(bigger.start.x, 50) && near(bigger.start.y, 60),
              "text corner scales the font, top-left stays", "font \(bigger.fontSize)")
        let fromTopLeft = text.resized(.topLeft, by: CGPoint(x: box.width / 2, y: box.height / 2), keepAspect: false)
        check(near(fromTopLeft.textBox.maxX, box.maxX, 1.5) && near(fromTopLeft.textBox.maxY, box.maxY, 1.5),
              "text scaled from top-left keeps bottom-right")

        var badge = Annotation(kind: .badge)
        badge.lineWidth = 8
        badge.start = CGPoint(x: 100, y: 100)
        let r0 = badge.badgeRadius
        let grown = badge.resized(.bottomRight, by: CGPoint(x: r0, y: r0), keepAspect: false)
        check(near(grown.badgeRadius, r0 * 1.5, 0.6) && near(grown.frame.minX, badge.frame.minX, 0.6),
              "badge grows from its corner", "r \(r0)→\(grown.badgeRadius)")

        let data = try? JSONEncoder().encode([r, pen, line, text, badge])
        let back = data.flatMap { try? JSONDecoder().decode([Annotation].self, from: $0) }
        check(back == [r, pen, line, text, badge], "annotations survive JSON round trip")
    }

    // MARK: State

    private static func stateTests() {
        let st = makeState()
        st.tool = .rect
        st.pointerDown(at: CGPoint(x: 100, y: 100))
        st.pointerDragged(to: CGPoint(x: 200, y: 160))
        st.pointerDragged(to: CGPoint(x: 300, y: 200))
        st.pointerUp(at: CGPoint(x: 300, y: 200))
        check(st.annotations.count == 1 && st.selectedID == st.annotations.first?.id, "new rect is drawn and stays selected")
        check(st.canUndo, "drawing is undoable")
        let id = st.annotations[0].id

        // Pressing on a handle stretches (handles win over moving)…
        st.pointerDown(at: CGPoint(x: 100, y: 150))
        st.pointerDragged(to: CGPoint(x: 120, y: 150))
        st.pointerUp(at: CGPoint(x: 120, y: 150))
        check(near(st.annotations[0].frame, CGRect(x: 120, y: 100, width: 180, height: 100)), "left handle stretches",
              "\(st.annotations[0].frame)")
        st.undo()
        // …and grabbing the outline between handles moves it, with the rect tool still active.
        st.pointerDown(at: CGPoint(x: 100, y: 125))
        st.pointerDragged(to: CGPoint(x: 140, y: 165))
        st.pointerUp(at: CGPoint(x: 140, y: 165))
        check(st.annotations.count == 1 && near(st.annotations[0].frame, CGRect(x: 140, y: 140, width: 200, height: 100)),
              "dragging the outline moves the rect (any tool)", "\(st.annotations[0].frame)")

        // Stretch from the right edge handle.
        st.pointerDown(at: CGPoint(x: 340, y: 190))
        st.pointerDragged(to: CGPoint(x: 400, y: 190))
        st.pointerUp(at: CGPoint(x: 400, y: 190))
        check(near(st.annotations[0].frame, CGRect(x: 140, y: 140, width: 260, height: 100)), "edge handle stretches",
              "\(st.annotations[0].frame)")

        st.undo()
        check(near(st.annotations[0].frame, CGRect(x: 140, y: 140, width: 200, height: 100)), "undo stretch")
        st.undo()
        check(near(st.annotations[0].frame, CGRect(x: 100, y: 100, width: 200, height: 100)), "undo move")
        st.undo()
        check(st.annotations.isEmpty, "undo draw")
        st.redo(); st.redo(); st.redo()
        check(!st.canRedo, "redo stack used up")
        check(st.annotations.count == 1 && near(st.annotations[0].frame, CGRect(x: 140, y: 140, width: 260, height: 100)),
              "redo all three")

        // Pressing inside a selected rect with the rect tool draws a new one (not a move).
        st.selectedID = id
        st.pointerDown(at: CGPoint(x: 200, y: 180))
        st.pointerDragged(to: CGPoint(x: 260, y: 220))
        st.pointerUp(at: CGPoint(x: 260, y: 220))
        check(st.annotations.count == 2, "drawing inside a selected box still draws")

        // The select tool grabs the inside of closed shapes.
        st.tool = .select
        let before = st.annotations[0].frame
        st.pointerDown(at: CGPoint(x: 160, y: 230)) // inside rect 0, outside rect 1
        st.pointerDragged(to: CGPoint(x: 170, y: 240))
        st.pointerUp(at: CGPoint(x: 170, y: 240))
        check(near(st.annotations[0].frame, before.offsetBy(dx: 10, dy: 10)), "select tool moves from inside")

        // Clicking empty space with the select tool deselects.
        st.pointerDown(at: CGPoint(x: 20, y: 20)); st.pointerUp(at: CGPoint(x: 20, y: 20))
        check(st.selectedID == nil, "click on nothing deselects")

        // Freehand tools draw over marks; ⌘ turns them into a mover.
        st.tool = .pen
        let count = st.annotations.count
        let frame0 = st.annotations[0].frame
        st.pointerDown(at: CGPoint(x: frame0.minX, y: frame0.midY))
        st.pointerDragged(to: CGPoint(x: frame0.minX + 30, y: frame0.midY + 10))
        st.pointerDragged(to: CGPoint(x: frame0.minX + 60, y: frame0.midY + 20))
        st.pointerUp(at: CGPoint(x: frame0.minX + 60, y: frame0.midY + 20))
        check(st.annotations.count == count + 1 && near(st.annotations[0].frame, frame0), "pen draws over a rect")
        check(st.selectedID == nil, "freehand strokes don't grab selection")
        st.pointerDown(at: CGPoint(x: frame0.minX, y: frame0.midY), modifiers: [.command])
        st.pointerDragged(to: CGPoint(x: frame0.minX + 20, y: frame0.midY), modifiers: [.command])
        st.pointerUp(at: CGPoint(x: frame0.minX + 20, y: frame0.midY), modifiers: [.command])
        check(st.annotations.count == count + 1, "⌘-drag with the pen moves instead of drawing")

        // A click with a shape tool on empty space adds nothing and keeps redo intact.
        st.tool = .arrow
        st.undo()
        let redoable = st.canRedo
        st.pointerDown(at: CGPoint(x: 600, y: 700)); st.pointerUp(at: CGPoint(x: 600, y: 700))
        check(redoable && st.canRedo, "a stray click doesn't wipe the redo history")

        // Inspector edits apply to the selection and undo.
        st.tool = .select
        st.selectedID = st.annotations[0].id
        let oldColor = st.annotations[0].color
        st.color = RGBA.presets[4]
        check(st.annotations[0].color == RGBA.presets[4], "color applies to the selection")
        st.undo()
        check(st.annotations[0].color == oldColor, "color change undoes")

        // The overlay region: drawing stays inside it.
        let ov = makeState()
        ov.region = CGRect(x: 200, y: 200, width: 400, height: 300)
        ov.tool = .rect
        ov.pointerDown(at: CGPoint(x: 300, y: 300))
        ov.pointerDragged(to: CGPoint(x: 900, y: 900))
        ov.pointerUp(at: CGPoint(x: 900, y: 900))
        check(ov.annotations.first.map { near($0.frame.maxX, 600) && near($0.frame.maxY, 500) } ?? false,
              "shapes are clamped to the region")
        let flat = ov.flatten(cropTo: ov.region)
        check(flat.width == 400 && flat.height == 300, "flatten crops to the region")
    }

    private static func textTests() {
        let st = makeState()
        st.tool = .text
        st.pointerDown(at: CGPoint(x: 100, y: 100)); st.pointerUp(at: CGPoint(x: 100, y: 100))
        guard let first = st.editingTextID else { check(false, "tap with the text tool opens a text box"); return }
        st.updateText(id: first, "Hello")
        // Clicking elsewhere only finishes the text (no second empty box).
        st.pointerDown(at: CGPoint(x: 600, y: 500)); st.pointerUp(at: CGPoint(x: 600, y: 500))
        check(st.editingTextID == nil && st.annotations.count == 1 && st.selectedID == first,
              "click outside commits the text and keeps it selected")
        // The next click starts a new text; ⌘Z right away drops just that empty box.
        st.pointerDown(at: CGPoint(x: 600, y: 500)); st.pointerUp(at: CGPoint(x: 600, y: 500))
        check(st.editingTextID != nil && st.editingTextID != first, "second click starts a new text")
        check(st.canUndo, "undo is available while typing")
        st.undo()
        check(st.editingTextID == nil && st.annotations.count == 1 && st.annotations[0].text == "Hello",
              "⌘Z in an empty new box removes only that box", "\(st.annotations.map(\.text))")
        st.undo()
        check(st.annotations.isEmpty, "next ⌘Z removes the committed text")
        st.redo()
        check(st.annotations.first?.text == "Hello", "redo brings the text back")

        // Editing an existing text is its own undo step.
        let id = st.annotations[0].id
        let box = st.annotations[0].textBox
        st.tool = .select
        st.pointerDown(at: CGPoint(x: box.midX, y: box.midY), clickCount: 1); st.pointerUp(at: CGPoint(x: box.midX, y: box.midY))
        st.pointerDown(at: CGPoint(x: box.midX, y: box.midY), clickCount: 2); st.pointerUp(at: CGPoint(x: box.midX, y: box.midY))
        check(st.editingTextID == id, "double-click edits text")
        st.updateText(id: id, "Hello world")
        st.commitTextEditing()
        st.undo()
        check(st.annotations.first?.text == "Hello", "undo restores the previous wording (not a deletion)",
              "\(st.annotations.map(\.text))")

        // Opening and closing without changes leaves no extra step.
        st.redo()
        st.beginEditingText(id)
        st.commitTextEditing()
        st.undo()
        check(st.annotations.first?.text == "Hello", "an unchanged edit adds no undo step")

        // Emptying an existing text deletes it, and undo restores it.
        st.redo()
        st.beginEditingText(id)
        st.updateText(id: id, "   ")
        st.commitTextEditing()
        check(st.annotations.isEmpty, "emptied text is removed")
        st.undo()
        check(st.annotations.first?.text == "Hello world", "undo restores the emptied text")

        // Text tool: tap on a text edits it, drag moves it.
        st.tool = .text
        let b2 = st.annotations[0].textBox
        st.pointerDown(at: CGPoint(x: b2.midX, y: b2.midY))
        st.pointerDragged(to: CGPoint(x: b2.midX + 40, y: b2.midY + 30))
        st.pointerUp(at: CGPoint(x: b2.midX + 40, y: b2.midY + 30))
        check(st.editingTextID == nil && near(st.annotations[0].textBox.minX, b2.minX + 40), "text tool drags text to move it")
        let b3 = st.annotations[0].textBox
        st.pointerDown(at: CGPoint(x: b3.midX, y: b3.midY)); st.pointerUp(at: CGPoint(x: b3.midX, y: b3.midY))
        check(st.editingTextID == st.annotations[0].id, "text tool tap edits existing text")
        // Corner handle while typing scales the font.
        let fs = st.annotations[0].fontSize
        let b4 = st.annotations[0].textBox
        st.pointerDown(at: CGPoint(x: b4.maxX, y: b4.maxY))
        st.pointerDragged(to: CGPoint(x: b4.maxX + b4.width, y: b4.maxY + b4.height))
        st.pointerUp(at: CGPoint(x: b4.maxX + b4.width, y: b4.maxY + b4.height))
        check(st.editingTextID != nil && st.annotations[0].fontSize > fs * 1.8, "corner handle scales text while typing",
              "\(fs)→\(st.annotations[0].fontSize)")
        check(near(st.fontSizePt, st.annotations[0].fontSize / st.scale, 0.01), "inspector follows the scaled size")
    }

    private static func miscTests() {
        let st = makeState()
        st.tool = .badge
        for x in [100, 200, 300] {
            st.pointerDown(at: CGPoint(x: x, y: 600)); st.pointerUp(at: CGPoint(x: x, y: 600))
        }
        check(st.annotations.map(\.badgeNumber) == [1, 2, 3], "badges number 1 2 3")
        // Tapping an existing badge selects it instead of stacking a new one.
        st.pointerDown(at: CGPoint(x: 200, y: 600)); st.pointerUp(at: CGPoint(x: 200, y: 600))
        check(st.annotations.count == 3 && st.selected?.badgeNumber == 2, "tap on a badge selects it")
        st.deleteSelected()
        check(st.annotations.map(\.badgeNumber) == [1, 2] && st.badgeCounter == 3, "delete renumbers")
        st.selectedID = st.annotations[0].id
        st.duplicateSelected()
        check(st.annotations.count == 3 && st.selected?.badgeNumber == 3, "duplicate gets the next number")
        let dupID = st.selectedID
        st.sendSelectedToBack()
        check(st.annotations.first?.id == dupID, "send to back")
        st.bringSelectedToFront()
        check(st.annotations.last?.id == dupID, "bring to front")

        // Nudges: a burst is a single undo step.
        let start = st.selected!.start
        for _ in 0..<5 { st.nudgeSelected(dx: 2, dy: 0) }
        check(near(st.selected!.start.x, start.x + 10), "nudge moves")
        st.undo()
        check(near(st.annotations.first(where: { $0.id == dupID })!.start.x, start.x), "one undo reverts the whole nudge burst")

        // Keyboard shortcuts through the shared handler.
        st.selectedID = dupID
        check(st.handleAnnotationKey(code: EditorState.Key.d, flags: [.command]) && st.annotations.count == 4, "⌘D duplicates")
        check(st.handleAnnotationKey(code: EditorState.Key.delete, flags: []) && st.annotations.count == 3, "⌫ deletes")
        check(st.handleAnnotationKey(code: EditorState.Key.z, flags: [.command]) && st.annotations.count == 4, "⌘Z undoes")
        check(st.handleAnnotationKey(code: EditorState.Key.z, flags: [.command, .shift]) && st.annotations.count == 3, "⇧⌘Z redoes")
        st.removeAllAnnotations()
        check(st.annotations.isEmpty, "remove all")
        st.undo()
        check(st.annotations.count == 3, "remove all is undoable")

        // Crop with handles.
        st.tool = .crop
        st.pointerDown(at: CGPoint(x: 100, y: 100)); st.pointerDragged(to: CGPoint(x: 500, y: 400)); st.pointerUp(at: CGPoint(x: 500, y: 400))
        check(st.cropRect.map { near($0, CGRect(x: 100, y: 100, width: 400, height: 300)) } ?? false, "crop rect drawn")
        st.pointerDown(at: CGPoint(x: 500, y: 250)); st.pointerDragged(to: CGPoint(x: 700, y: 250)); st.pointerUp(at: CGPoint(x: 700, y: 250))
        check(st.cropRect.map { near($0.width, 600) } ?? false, "crop edge handle stretches", "\(String(describing: st.cropRect))")
        st.pointerDown(at: CGPoint(x: 300, y: 250)); st.pointerDragged(to: CGPoint(x: 350, y: 300)); st.pointerUp(at: CGPoint(x: 350, y: 300))
        check(st.cropRect.map { near($0.minX, 150) && near($0.minY, 150) } ?? false, "crop rect moves")
        st.applyCrop()
        check(st.base.width == 600 && st.base.height == 300, "crop applies", "\(st.base.width)×\(st.base.height)")
        st.undo()
        check(st.base.width == 1280, "crop undoes")
    }

    private static func undoEdgeTests() {
        let st = makeState()
        st.tool = .rect
        st.pointerDown(at: CGPoint(x: 100, y: 100)); st.pointerDragged(to: CGPoint(x: 300, y: 200)); st.pointerUp(at: CGPoint(x: 300, y: 200))
        let start = st.selected!.frame

        // Nudge, undo, nudge again, undo: the second undo only reverts the second nudge.
        st.nudgeSelected(dx: 10, dy: 0)
        st.undo()
        st.nudgeSelected(dx: 0, dy: 10)
        st.undo()
        check(st.annotations.count == 1 && near(st.annotations[0].frame, start), "nudge after undo is its own step",
              "\(st.annotations.map(\.frame))")

        // Colour, undo, another colour: the new edit clears redo and stays.
        st.selectedID = st.annotations[0].id
        st.color = RGBA.presets[4]
        st.undo()
        check(st.color == RGBA.presets[0], "controls show the restored colour after undo", "\(st.color)")
        st.color = RGBA.presets[3]
        check(!st.canRedo, "a new edit after undo clears redo")
        st.redo()
        check(st.annotations[0].color == RGBA.presets[3], "the newer colour survives a redo attempt")

        // Restyling a fresh text before typing doesn't leave an empty step behind.
        st.tool = .text
        st.pointerDown(at: CGPoint(x: 500, y: 500)); st.pointerUp(at: CGPoint(x: 500, y: 500))
        st.textStyle.bold.toggle()
        st.adjustFontSize(by: 4)
        if let id = st.editingTextID { st.updateText(id: id, "styled") }
        st.commitTextEditing()
        st.undo()
        check(st.annotations.count == 1 && st.annotations[0].kind == .rect, "one undo removes the styled new text")
        st.undo()
        check(st.annotations[0].color == RGBA.presets[0], "the next undo reaches the step before (no dead step)")
        st.redo(); st.redo()
        check(st.annotations.last?.text == "styled" && st.annotations.last?.textStyle.bold != TextStyle().bold, "redo restores the styled text")

        // Opening a text and closing it unchanged, or a stray text click, keeps redo.
        st.undo()
        check(st.canRedo, "redo available")
        if let rect = st.annotations.first { st.selectedID = rect.id }
        st.tool = .text
        st.pointerDown(at: CGPoint(x: 900, y: 650)); st.pointerUp(at: CGPoint(x: 900, y: 650))
        st.undo() // closes the empty box only
        check(st.canRedo && st.editingTextID == nil, "a stray text click + undo keeps redo")
        st.redo()
        guard let t = st.annotations.last, t.kind == .text else { check(false, "text back"); return }
        st.beginEditingText(t.id)
        st.commitTextEditing()
        st.undo()
        check(st.canRedo, "opening a text unchanged keeps redo")

        // Restyling an existing text while typing is one step with the typing.
        st.redo()
        st.beginEditingText(t.id)
        st.textStyle.plate = true
        st.commitTextEditing()
        check(st.annotation(t.id)?.textStyle.plate == true, "plate applied")
        st.undo()
        check(st.annotation(t.id)?.textStyle.plate == false, "style-only edit is undoable")
    }

    // MARK: Canvas with real events

    private static func canvasTests() {
        let st = makeState()
        let canvas = AnnotationCanvasView(state: st)
        canvas.allowsContextMenu = true
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: st.displaySize), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        canvas.frame = CGRect(origin: .zero, size: st.displaySize)

        st.tool = .arrow
        drag(canvas, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 260, y: 160))
        check(st.annotations.count == 1 && st.annotations[0].kind == .arrow, "mouse drag draws an arrow")
        let arrow = st.annotations[0]
        check(near(arrow.start.x, 120) && near(arrow.end.y, 320), "view points map to image pixels", "\(arrow.start) \(arrow.end)")

        // Grab the arrow's shaft and move it.
        drag(canvas, from: CGPoint(x: 160, y: 110), to: CGPoint(x: 190, y: 140))
        check(near(st.annotations[0].start.x, arrow.start.x + 60) && st.annotations.count == 1, "drag on the arrow moves it")
        // Drag its end handle.
        let end = canvas.toView(st.annotations[0].end)
        drag(canvas, from: end, to: CGPoint(x: end.x + 40, y: end.y - 50))
        check(near(st.annotations[0].end.x, arrow.end.x + 60 + 80), "end handle reshapes the arrow")

        st.tool = .rect
        drag(canvas, from: CGPoint(x: 330, y: 60), to: CGPoint(x: 480, y: 170))
        st.tool = .text
        click(canvas, CGPoint(x: 340, y: 240))
        pump()
        let tv = canvas.subviews.compactMap { $0 as? EditingTextView }.first
        check(tv != nil, "text box appears in place")
        if let tv {
            tv.insertText("標註 Note", replacementRange: tv.selectedRange())
            pump()
            check(st.annotation(st.editingTextID)?.text == "標註 Note", "typing reaches the model")
            if let a = st.annotation(st.editingTextID) {
                for corner in [AnnotationHandle.bottomRight, .topRight, .bottomLeft] {
                    let p = canvas.toView(a.textBox.point(for: corner))
                    check(window.contentView?.hitTest(canvas.convert(p, to: nil)) === canvas,
                          "\(corner) handle stays grabbable while typing")
                }
                let inside = canvas.toView(a.textBox.center)
                check(window.contentView?.hitTest(canvas.convert(inside, to: nil)) === tv, "inside the box the text view gets clicks")
            }
            check(canvas.undoTyping(), "⌘Z undoes typing first")
            check(st.annotation(st.editingTextID)?.text == "", "typing undone")
            tv.insertText("標註 Note", replacementRange: tv.selectedRange())
            tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            pump()
            check(st.editingTextID == nil && st.annotations.last?.text == "標註 Note", "↩ finishes the text")
            check(canvas.subviews.compactMap { $0 as? EditingTextView }.isEmpty, "text box goes away")
        }
        st.tool = .highlighter
        drag(canvas, from: CGPoint(x: 80, y: 260), to: CGPoint(x: 300, y: 262), steps: 12)
        st.tool = .mosaic
        drag(canvas, from: CGPoint(x: 400, y: 300), to: CGPoint(x: 560, y: 330), steps: 12)
        st.tool = .badge
        click(canvas, CGPoint(x: 560, y: 80))
        click(canvas, CGPoint(x: 600, y: 120))

        // Double-click on the text with another tool active edits it.
        st.tool = .ellipse
        if let t = st.annotations.first(where: { $0.kind == .text }) {
            let c = canvas.toView(t.textBox.center)
            click(canvas, c, clicks: 2)
            pump()
            check(st.editingTextID == t.id, "double-click edits text with any tool")
            st.commitTextEditing()
            pump()
        }
        // Context menu.
        if let r = st.annotations.first(where: { $0.kind == .rect }) {
            let p = canvas.toView(CGPoint(x: r.frame.minX, y: r.frame.midY))
            let menu = canvas.menu(for: mouse(.rightMouseDown, p, in: canvas))
            check(menu?.items.count ?? 0 >= 4 && st.selectedID == r.id, "right-click selects and offers a menu")
        }
        st.tool = .select
        st.selectedID = st.annotations.first(where: { $0.kind == .rect })?.id
        pump()
        savePNG(canvas, "canvas.png")
        savePNG(st.flatten(), "canvas-flattened.png")
        check(st.annotations.count == 7, "all marks present", "\(st.annotations.map(\.kind.rawValue))")
    }

    // MARK: Editor window

    private static func editorWindowTests() {
        let editor = EditorWindowController.makeForTesting(image: sampleImage(points: CGSize(width: 900, height: 560)))
        let st = editor.state
        guard let window = editor.window, let content = window.contentView else { check(false, "editor window"); return }
        window.setContentSize(CGSize(width: 1100, height: 760))
        content.layoutSubtreeIfNeeded()
        pump(0.2)
        st.viewportSize = CGSize(width: 1100, height: 600)
        st.zoomToFit()
        pump(0.2)

        let canvas = findCanvas(in: content)
        check(canvas != nil, "editor hosts the annotation canvas")
        guard let canvas else { return }
        let probe = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        check(content.hitTest(canvas.convert(probe, to: nil)) === canvas,
              "the editor's hosting view hit-tests down to the canvas (cursor ownership)",
              "\(String(describing: content.hitTest(canvas.convert(probe, to: nil)).map { type(of: $0) }))")
        st.tool = .rect
        drag(canvas, from: CGPoint(x: 80, y: 80), to: CGPoint(x: 300, y: 200))
        check(st.annotations.count == 1, "drawing in the editor")
        check(editor.handleKey(key(EditorState.Key.z, [.command], "z")) && st.annotations.isEmpty, "⌘Z in the editor")
        check(editor.handleKey(key(EditorState.Key.z, [.command, .shift], "z")) && st.annotations.count == 1, "⇧⌘Z in the editor")

        // The reported bug: ⌘Z while a fresh text box is open.
        st.tool = .text
        click(canvas, CGPoint(x: 400, y: 300))
        pump()
        let tv = canvas.subviews.compactMap { $0 as? EditingTextView }.first
        if let tv { window.makeFirstResponder(tv) }
        check(st.editingTextID != nil, "text box open")
        check(editor.handleKey(key(EditorState.Key.z, [.command], "z")), "⌘Z handled while typing")
        pump()
        check(st.editingTextID == nil && st.annotations.count == 1, "⌘Z closes the empty box, rect remains")
        check(editor.handleKey(key(EditorState.Key.z, [.command], "z")) && st.annotations.isEmpty, "then undoes the rect")
        check(editor.handleKey(key(EditorState.Key.z, [.command, .shift], "z")) && st.annotations.count == 1, "redo the rect")

        // Tool keys by physical key code (注音 doesn't matter).
        check(editor.handleKey(key(EditorState.Key.a, [], "ㄇ")) && st.tool == .arrow, "A selects the arrow under 注音")
        st.selectedID = st.annotations[0].id
        check(editor.handleKey(key(EditorState.Key.right, [.shift, .function, .numericPad], "")), "⇧→ nudges")
        check(near(st.annotations[0].frame.minX, 80 / st.pxToView + 10 * st.scale, 1), "nudged 10 pt")
        st.tool = .ellipse
        drag(canvas, from: CGPoint(x: 420, y: 120), to: CGPoint(x: 560, y: 220))
        st.tool = .text
        click(canvas, CGPoint(x: 120, y: 300))
        pump()
        if let id = st.editingTextID { st.updateText(id: id, "可移動、可拉伸、可復原") }
        st.commitTextEditing()
        pump(0.2)
        content.layoutSubtreeIfNeeded()
        savePNG(content, "editor.png")
        editor.closeForTesting()
    }

    private static func findCanvas(in view: NSView) -> AnnotationCanvasView? {
        if let c = view as? AnnotationCanvasView { return c }
        for sub in view.subviews { if let c = findCanvas(in: sub) { return c } }
        return nil
    }

    // MARK: Overlay

    private static func overlayTests() {
        guard let screen = NSScreen.main else { check(false, "a screen"); return }
        let frozen = sampleImage(points: screen.frame.size, scale: screen.backingScaleFactor)
        let window = OverlayWindow(screen: screen, frozen: frozen, controller: SelectionController.shared)
        guard let view = window.overlayView else { check(false, "overlay view"); return }
        let size = view.bounds.size
        func brightness(_ name: String, at p: CGPoint) -> CGFloat {
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
            view.cacheDisplay(in: view.bounds, to: rep)
            let sx = CGFloat(rep.pixelsWide) / view.bounds.width
            let c = rep.colorAt(x: Int(p.x * sx), y: Int(p.y * sx))?.usingColorSpace(.sRGB)
            return c.map { ($0.redComponent + $0.greenComponent + $0.blueComponent) / 3 } ?? -1
        }
        let frozenRep = NSBitmapImageRep(cgImage: frozen.cgImage)
        let probe = CGPoint(x: 20, y: 20)
        let original = frozenRep.colorAt(x: Int(probe.x * frozen.scale), y: Int(probe.y * frozen.scale))?.usingColorSpace(.sRGB)
            .map { ($0.redComponent + $0.greenComponent + $0.blueComponent) / 3 } ?? -1
        let aiming = brightness("aim", at: probe)
        check(aiming < original * 0.75, "aiming dims the frozen screen", "original \(original) rendered \(aiming)")

        let selStart = CGPoint(x: size.width * 0.2, y: size.height * 0.2)
        let selEnd = CGPoint(x: size.width * 0.7, y: size.height * 0.65)
        drag(view, from: selStart, to: selEnd)
        pump(0.1)
        check(view.canvas != nil && view.annotation != nil, "selecting an area enables annotation")
        guard let canvas = view.canvas, let st = view.annotation else { return }
        check(near(canvas.frame, CGRect(corner: selStart, corner: selEnd).integral, 1), "canvas covers the selection")
        check(canvas.hitTest(view.convert(CGPoint(x: canvas.frame.midX, y: canvas.frame.midY), to: view)) == nil,
              "before a tool is picked, clicks go to the region (adjust)")

        view.setTool(.rect)
        check(view.session.activeTool == .rect, "tool picked")
        drag(canvas, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 220, y: 140))
        check(st.annotations.count == 1, "draw a rect in place")
        let rectPixels = st.annotations[0].frame
        check(near(rectPixels.minX, (canvas.frame.minX + 40) * frozen.scale, 2), "overlay marks live in screen pixels")

        check(window.performKeyEquivalent(with: key(EditorState.Key.z, [.command], "z")) && st.annotations.isEmpty, "⌘Z in the overlay")
        check(window.performKeyEquivalent(with: key(EditorState.Key.z, [.command, .shift], "z")) && st.annotations.count == 1,
              "⇧⌘Z in the overlay")

        // Move and stretch the mark.
        drag(canvas, from: CGPoint(x: 40, y: 90), to: CGPoint(x: 70, y: 110))
        check(near(st.annotations[0].frame.minX, rectPixels.minX + 30 * frozen.scale, 2), "move a mark in the overlay")
        let br = canvas.toView(CGPoint(x: st.annotations[0].frame.maxX, y: st.annotations[0].frame.maxY))
        drag(canvas, from: br, to: CGPoint(x: br.x + 60, y: br.y + 40))
        check(near(st.annotations[0].frame.width, rectPixels.width + 60 * frozen.scale, 2), "stretch a mark in the overlay")

        // Tool keys and the style row.
        view.handleKeyDown(key(EditorState.Key.a, [], "ㄇ"))
        check(view.session.activeTool == .arrow, "A picks the arrow (keyCode, 注音-safe)")
        drag(canvas, from: CGPoint(x: 360, y: 40), to: CGPoint(x: 460, y: 120))
        view.handleKeyDown(key(EditorState.Key.t, [], "ㄔ"))
        click(canvas, CGPoint(x: 80, y: 250))
        pump(0.1)
        check(window.level.rawValue == NSWindow.Level.popUpMenu.rawValue - 1, "typing lowers the overlay for the IME candidate window")
        if let tv = canvas.subviews.compactMap({ $0 as? EditingTextView }).first {
            tv.insertText("這裡要改", replacementRange: tv.selectedRange())
            check(window.performKeyEquivalent(with: key(EditorState.Key.z, [.command], "z")), "⌘Z while typing in the overlay")
            check(st.annotation(st.editingTextID)?.text == "", "undoes the typing first")
            tv.insertText("這裡要改", replacementRange: tv.selectedRange())
            tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        }
        pump(0.1)
        check(window.level == .screenSaver, "level restored after typing")
        view.handleKeyDown(key(EditorState.Key.m, [], "ㄩ"))
        drag(canvas, from: CGPoint(x: 400, y: 170), to: CGPoint(x: 540, y: 210), steps: 10)
        view.handleKeyDown(key(EditorState.Key.b, [], "ㄖ"))
        click(canvas, CGPoint(x: 330, y: 265))
        click(canvas, CGPoint(x: 390, y: 265))
        check(st.annotations.count == 6, "six marks in place", "\(st.annotations.map(\.kind.rawValue))")

        // Hit-testing decides who gets real clicks (a never-shown window won't dispatch events itself,
        // so deliver them to whatever the window's hit test picks — exactly what AppKit does next).
        view.setTool(.ellipse)
        let routedBefore = st.annotations.count
        func routed(_ p: CGPoint) -> NSView? {
            guard let content = window.contentView else { return nil }
            return content.hitTest(view.convert(p, to: nil))
        }
        let a = CGPoint(x: canvas.frame.minX + 470, y: canvas.frame.minY + 250)
        check(routed(a) === canvas, "while drawing, presses inside the selection hit the canvas",
              "\(String(describing: routed(a).map { type(of: $0) }))")
        if let target = routed(a) {
            target.mouseDown(with: mouse(.leftMouseDown, a, in: view))
            for i in 1...6 { target.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: a.x + CGFloat(i) * 10, y: a.y + CGFloat(i) * 6), in: view)) }
            target.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: a.x + 60, y: a.y + 36), in: view))
        }
        check(st.annotations.count == routedBefore + 1, "routed drag draws", "\(st.annotations.count - routedBefore) added")
        if let toolbar = view.subviews.last {
            let onBar = CGPoint(x: toolbar.frame.midX, y: toolbar.frame.midY)
            check(routed(onBar).map { $0 === toolbar || $0.isDescendant(of: toolbar) } ?? false, "the toolbar gets its own clicks")
        }
        // A press beside the region while drawing must not start a new selection.
        let outsideSel = CGPoint(x: canvas.frame.minX - 30, y: canvas.frame.minY - 30)
        check(routed(outsideSel) === view, "beside the selection the overlay itself gets the press")
        view.mouseDown(with: mouse(.leftMouseDown, outsideSel, in: view))
        view.mouseUp(with: mouse(.leftMouseUp, outsideSel, in: view))
        check(view.canvas === canvas && near(canvas.frame.width, CGRect(corner: selStart, corner: selEnd).integral.width, 1),
              "a click beside the region keeps it")

        // Esc with marks only warns the first time.
        view.handleKeyDown(key(EditorState.Key.esc, [], "\u{1b}"))
        check(view.isEscArmed && view.canvas != nil, "first Esc with marks asks for a second press")

        // Back to adjusting: the region moves, marks stay put on screen.
        view.setTool(nil)
        check(view.session.activeTool == nil && routed(CGPoint(x: canvas.frame.midX, y: canvas.frame.midY)) === view,
              "clicking the active tool again returns to adjusting (presses reach the region)")
        let before = st.annotations.map(\.frame)
        let sel = canvas.frame
        drag(view, from: CGPoint(x: sel.midX, y: sel.midY), to: CGPoint(x: sel.midX + 40, y: sel.midY + 20))
        check(near(canvas.frame.minX, sel.minX + 40, 1) && st.annotations.map(\.frame) == before,
              "moving the region keeps the marks where they were")
        view.setTool(.select)
        st.selectedID = st.annotations.first?.id
        pump(0.2)
        let outside = brightness("selected", at: probe)
        if outside >= original * 0.75 {
            for sub in view.subviews { sub.isHidden = true }
            print("    debug: own drawing only \(brightness("own", at: probe))")
            for sub in view.subviews {
                sub.isHidden = false
                print("    debug: + \(type(of: sub)) frame \(sub.frame) → \(brightness("one", at: probe))")
                sub.isHidden = true
            }
            for sub in view.subviews { sub.isHidden = false }
        }
        check(outside < original * 0.75, "outside the selection stays dimmed", "original \(original) rendered \(outside)")
        savePNG(view, "overlay.png")

        // Output: the cropped, flattened capture.
        let region = st.region ?? .zero
        let flat = st.flatten(cropTo: region)
        check(flat.width == Int(region.width) && flat.height == Int(region.height), "done renders exactly the region")
        savePNG(flat, "overlay-result.png")
        let moved = st.annotations(relativeTo: region)
        check(near(moved[0].frame.minX, st.annotations[0].frame.minX - region.minX), "marks handed to the editor are re-based")
        window.close()
    }

    // MARK: Capture preview

    private static func previewTests() {
        let image = sampleImage(points: CGSize(width: 900, height: 500))
        let controller = CapturePreviewController(capture: AppCoordinator.ResolvedCapture(image: image),
                                                  savedURL: URL(fileURLWithPath: "/tmp/x.png"), copied: true)
        guard let content = controller.contentForTesting() else { check(false, "preview content"); return }
        content.layoutSubtreeIfNeeded()
        pump(0.1)
        check(content.frame.width <= 220 && content.frame.height <= 150 && content.frame.width > 80, "thumbnail fits the corner",
              "\(content.frame.size)")
        savePNG(content, "preview.png")
    }

    // MARK: Project store

    private static func projectTests() {
        let st = makeState()
        st.tool = .ellipse
        st.pointerDown(at: CGPoint(x: 100, y: 100)); st.pointerDragged(to: CGPoint(x: 400, y: 300)); st.pointerUp(at: CGPoint(x: 400, y: 300))
        st.tool = .text
        st.pointerDown(at: CGPoint(x: 500, y: 500)); st.pointerUp(at: CGPoint(x: 500, y: 500))
        if let id = st.editingTextID { st.updateText(id: id, "re-editable 可再編輯") }
        st.commitTextEditing()
        let url = outDir.appendingPathComponent("project-test.png")
        let source = ProjectStore.Source(base: st.base, scale: st.scale, annotations: st.annotations, badgeCounter: st.badgeCounter)
        check(ImageFile.write(st.flattenedCapture(), to: url, project: source), "write annotated PNG")
        guard let data = try? Data(contentsOf: url), let restored = ProjectStore.load(fileData: data) else {
            check(false, "project found for the written file")
            return
        }
        check(restored.document.annotations == st.annotations, "annotations restored exactly")
        check(restored.image.cgImage.width == st.base.width && restored.image.scale == st.scale, "original pixels restored")
        var tampered = data
        tampered.append(0)
        check(ProjectStore.load(fileData: tampered) == nil, "a modified file opens as a plain image")
    }
}
