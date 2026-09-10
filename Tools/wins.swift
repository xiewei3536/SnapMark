import CoreGraphics
import Foundation
// Lists on-screen windows: id|owner|name|x|y|w|h|layer   (optional owner-substring filter)
let filter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    guard filter.isEmpty || owner.contains(filter) else { continue }
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    print("\(w[kCGWindowNumber as String] as? Int ?? 0)|\(owner)|\(w[kCGWindowName as String] as? String ?? "")|\(Int(b["X"] ?? 0))|\(Int(b["Y"] ?? 0))|\(Int(b["Width"] ?? 0))|\(Int(b["Height"] ?? 0))|\(w[kCGWindowLayer as String] as? Int ?? 0)")
}
