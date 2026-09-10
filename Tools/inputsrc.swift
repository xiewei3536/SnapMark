import Carbon
// inputsrc → prints the current keyboard input source ID; inputsrc <ID> → selects it.
let args = CommandLine.arguments
if args.count > 1 {
    let filter = [kTISPropertyInputSourceID as String: args[1]] as CFDictionary
    if let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource], let src = list.first {
        TISSelectInputSource(src)
    } else { print("not found: \(args[1])") }
} else {
    let cur = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    print(Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(cur, kTISPropertyInputSourceID)).takeUnretainedValue() as String)
}
