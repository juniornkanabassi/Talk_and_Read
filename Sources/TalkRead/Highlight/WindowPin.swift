// Which window the highlight belongs to, and where it may be drawn (H2). Window-server facts only: one
// CGWindowListCopyWindowInfo per tick tells whether the source window is on screen (not minimised, hidden, closed or on
// another Space), its bounds and layer, and whether the overlay panel still sits above it with nothing foreign between.
// Everything that covers the source window is above the panel too, so the window server hides the box where it is covered.
import AppKit

struct WindowInfo: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let layer: Int
    let bounds: CGRect   // top-left global coordinates, as CGWindowList and AX report them
    let onScreen: Bool
    let alpha: Double

    init(id: CGWindowID, pid: pid_t, layer: Int = 0, bounds: CGRect, onScreen: Bool = true, alpha: Double = 1) {
        (self.id, self.pid, self.layer, self.bounds, self.onScreen, self.alpha) = (id, pid, layer, bounds, onScreen, alpha)
    }

    /// One CGWindowListCopyWindowInfo entry. kCGWindowIsOnscreen is present only when true.
    init?(_ entry: [String: Any]) {
        guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let dict = entry[kCGWindowBounds as String], let bounds = CGRect(dictionaryRepresentation: dict as! CFDictionary)
        else { return nil }
        self.init(id: id, pid: pid, layer: (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0, bounds: bounds,
                  onScreen: (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                  alpha: (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
    }
}

enum WindowPin {
    /// Where the panel is: directly above the window (nothing to do), above it with other windows between (it would draw
    /// over them), or not above it at all (none yet, the window was raised over it, or it is stuck on another Space).
    enum PanelOrder { case directlyAbove, separated, missing }

    enum Placement: Equatable {
        case hidden
        case shown(bounds: CGRect, layer: Int, panel: PanelOrder)
    }

    /// `list`: the windows on screen above `source` and `source` itself, front to back (`snapshot(above:)`). When the
    /// source is not on screen the window server leaves it out and lists everything instead, so it must be last.
    static func placement(_ list: [WindowInfo], source: CGWindowID, panel: CGWindowID?) -> Placement {
        guard let window = list.last, window.id == source, window.onScreen, window.alpha > 0 else { return .hidden }
        let above = list.dropLast()
        let order = panel.flatMap { p in above.lastIndex { $0.id == p } }
            .map { $0 == above.endIndex - 1 ? PanelOrder.directlyAbove : .separated } ?? .missing
        return .shown(bounds: window.bounds, layer: window.layer, panel: order)
    }

    static func snapshot(above source: CGWindowID) -> [WindowInfo] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .optionIncludingWindow], source) as? [[String: Any]]
        return (list ?? []).compactMap(WindowInfo.init)
    }

    /// The pid's on-screen window whose bounds are closest to the AX window frame (both top-left); with no frame, its
    /// frontmost one. Ties go to the frontmost (the list is front to back). Slivers (title strips, helpers) never count.
    static func windowID(pid: pid_t, axFrame: CGRect?, in list: [WindowInfo]) -> CGWindowID? {
        let candidates = list.filter { $0.pid == pid && $0.onScreen && $0.bounds.width >= 40 && $0.bounds.height >= 40 }
        guard let axFrame else { return candidates.first?.id }
        func distance(_ r: CGRect) -> CGFloat { abs(r.minX - axFrame.minX) + abs(r.minY - axFrame.minY) + abs(r.width - axFrame.width) + abs(r.height - axFrame.height) }
        return candidates.min { distance($0.bounds) < distance($1.bounds) }?.id
    }

    static func windowID(pid: pid_t, axFrame: CGRect?) -> CGWindowID? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        return windowID(pid: pid, axFrame: axFrame, in: (list ?? []).compactMap(WindowInfo.init))
    }
}
