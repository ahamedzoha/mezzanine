// Prints the window id of an app's largest on-screen window: swift window.swift <pid>
// (screencapture -l takes it, so only that window is ever captured.)
import CoreGraphics
import Foundation

let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let windows = list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
func area(_ w: [String: Any]) -> Double {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (b["Width"] ?? 0) * (b["Height"] ?? 0)
}
guard let best = windows.max(by: { area($0) < area($1) }), let id = best[kCGWindowNumber as String] as? Int else { exit(1) }
print(id)
