import AppKit
import CoreGraphics
// usage: winlist <pid>  -> prints id, layer, bounds, name for on-screen windows of pid
for s in NSScreen.screens { print("screen", s.frame, s.backingScaleFactor) }
let pid = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1])! : -1
let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in info {
    let p = w[kCGWindowOwnerPID as String] as! Int
    if pid != -1 && p != pid { continue }
    let b = w[kCGWindowBounds as String] as! [String: Any]
    print(w[kCGWindowNumber as String]!, "layer", w[kCGWindowLayer as String]!, "onscreen", w[kCGWindowIsOnscreen as String] ?? 0, b["X"]!, b["Y"]!, b["Width"]!, b["Height"]!, w[kCGWindowName as String] ?? "-", w[kCGWindowOwnerName as String] ?? "-")
}
