import AppKit
import Carbon.HIToolbox

// UI test driver: posts synthetic HID events. Coordinates are global, top-left origin (points).
//   uidrv key <keycode> [cmd] [shift] [alt] [ctrl] | move x y | click x y [count] | rclick x y
//   uidrv drag x1 y1 x2 y2 [steps] | type "text" | scroll x y dy | sleep seconds
let args = Array(CommandLine.arguments.dropFirst())
func p(_ i: Int) -> Double { Double(args[i]) ?? 0 }
func flags(from words: ArraySlice<String>) -> CGEventFlags {
    var f: CGEventFlags = []
    for w in words {
        switch w { case "cmd": f.insert(.maskCommand); case "shift": f.insert(.maskShift)
        case "alt": f.insert(.maskAlternate); case "ctrl": f.insert(.maskControl); default: break }
    }
    return f
}
func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }
func moveTo(_ pt: CGPoint) { post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)) }
var i = 0
while i < args.count {
    switch args[i] {
    case "key":
        let code = CGKeyCode(UInt16(args[i+1]) ?? 0)
        var j = i + 2; var mods: [String] = []
        while j < args.count, ["cmd","shift","alt","ctrl"].contains(args[j]) { mods.append(args[j]); j += 1 }
        let f = flags(from: mods[...])
        let d = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!; d.flags = f; post(d); usleep(30_000)
        let u = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)!; u.flags = f; post(u)
        i = j
    case "move": moveTo(CGPoint(x: p(i+1), y: p(i+2))); i += 3
    case "click", "rclick":
        let pt = CGPoint(x: p(i+1), y: p(i+2)); let right = args[i] == "rclick"
        var count = 1; var next = i + 3
        if !right, next < args.count, let c = Int(args[next]) { count = c; next += 1 }
        moveTo(pt); usleep(60_000)
        for n in 1...count {
            let d = CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: pt, mouseButton: right ? .right : .left)!
            d.setIntegerValueField(.mouseEventClickState, value: Int64(n)); post(d); usleep(40_000)
            let u = CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: pt, mouseButton: right ? .right : .left)!
            u.setIntegerValueField(.mouseEventClickState, value: Int64(n)); post(u); usleep(80_000)
        }
        i = next
    case "drag":
        let a = CGPoint(x: p(i+1), y: p(i+2)), b = CGPoint(x: p(i+3), y: p(i+4))
        var steps = 20; var next = i + 5
        if next < args.count, let s = Int(args[next]) { steps = s; next += 1 }
        moveTo(a); usleep(80_000)
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left)); usleep(60_000)
        for s in 1...steps {
            let t = Double(s) / Double(steps)
            post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), mouseButton: .left)); usleep(16_000)
        }
        usleep(60_000)
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left))
        i = next
    case "type":
        for ch in args[i+1].utf16 {
            var c = ch
            let d = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!; d.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c); post(d)
            let u = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!; u.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c); post(u)
            usleep(25_000)
        }
        i += 2
    case "scroll":
        let pt = CGPoint(x: p(i+1), y: p(i+2)); moveTo(pt); usleep(40_000)
        post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(p(i+3)), wheel2: 0, wheel3: 0)); i += 4
    case "sleep": usleep(UInt32(p(i+1) * 1_000_000)); i += 2
    default: print("unknown: \(args[i])"); i += 1
    }
    usleep(50_000)
}
