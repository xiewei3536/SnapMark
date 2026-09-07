import AppKit

/// Command-line options: `SnapMark --edit <image>` (or bare image paths) opens the editor.
enum LaunchOptions {
    static var filesToOpen: [URL] = []
}

var pendingArgs = Array(CommandLine.arguments.dropFirst())
while let arg = pendingArgs.first {
    pendingArgs.removeFirst()
    if arg == "--edit", let path = pendingArgs.first {
        pendingArgs.removeFirst()
        LaunchOptions.filesToOpen.append(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    } else if !arg.hasPrefix("-"), FileManager.default.fileExists(atPath: arg) {
        LaunchOptions.filesToOpen.append(URL(fileURLWithPath: arg))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar app; the Dock icon appears only while editing
app.run()
