import Cocoa

@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray?

enum MissionControl {
    /// The processes that may host the overview's accessibility tree: the Dock up to macOS 26,
    /// WindowManager on macOS 27.
    private static var hostPIDs: [pid_t] {
        ["com.apple.dock", "com.apple.WindowManager"].compactMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.processIdentifier
        }
    }

    /// A host exposes one of these groups only while that overview is on screen: "mc" for Mission
    /// Control, "appexpose" for App Exposé (three-finger swipe down / ⌃↓). WindowManager names them
    /// "mc.display" / "appexpose.display". Both lay out window thumbnails the same way, so everything
    /// else treats them alike.
    private static let overviewIdentifiers = ["mc", "appexpose", "mc.display", "appexpose.display"]

    /// One overview group per display that shows it (a display with several spaces and no windows
    /// still has its Spaces bar). On macOS 27 the Dock still exposes an empty "mc" group while
    /// WindowManager holds the thumbnails, so a group only counts if it has children.
    static func roots() -> [AXUIElement] {
        var groups: [AXUIElement] = []
        for pid in hostPIDs {
            let host = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(host, 0.5) // polled on the main thread; don't let a hung host stall it
            groups += host.children.filter {
                guard let identifier = $0.identifier, overviewIdentifiers.contains(identifier) else { return false }
                return !$0.children.isEmpty
            }
        }
        return groups
    }

    static func root() -> AXUIElement? { roots().first }

    /// The space each display is showing. Private CoreGraphics API; empty if it is unavailable.
    private static func currentSpaceIDs() -> Set<Int> {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] else { return [] }
        return Set(displays.compactMap { ($0["Current Space"] as? [String: Any])?["id64"] as? Int })
    }

    /// Thumbnails are identified "<bundle id>.space.<space id>". The overview's tree also lists windows
    /// from the other spaces, which would get buttons too, so keep only those on a visible space.
    /// Thumbnails without that tag, or an unreadable space list, are kept.
    private static func isOnCurrentSpace(_ e: AXUIElement, current: Set<Int>) -> Bool {
        guard !current.isEmpty, let id = e.identifier, let range = id.range(of: ".space.", options: .backwards),
              let space = Int(id[range.upperBound...]) else { return true }
        return current.contains(space)
    }

    /// Window thumbnails: the buttons in the overview, skipping Mission Control's Spaces bar
    /// and windows that live on other spaces.
    static func thumbnails(in mc: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        let current = currentSpaceIDs()
        func walk(_ e: AXUIElement, depth: Int) {
            guard depth < 8 else { return }
            if let id = e.identifier, id.hasPrefix("mc.spaces") { return }
            if e.role == kAXButtonRole as String, let f = e.frame, f.width > 40, f.height > 40 {
                if isOnCurrentSpace(e, current: current) { result.append(e) }
                return
            }
            e.children.forEach { walk($0, depth: depth + 1) }
        }
        walk(mc, depth: 0)
        return result
    }
}
