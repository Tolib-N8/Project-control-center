import AppKit
import ApplicationServices

/// Closes the windows on the current desktop the way a click on the red button would, so apps still ask
/// about unsaved work. Window ownership comes from CGWindowList (all desktops), closing goes through
/// Accessibility (current desktop only).
enum DesktopCleaner {
    struct Window {
        let pid: pid_t
        let element: AXUIElement
        let appName: String
    }

    /// Never quit, even without windows.
    private static let keepRunning: Set<String> = ["com.apple.finder", Bundle.main.bundleIdentifier ?? "dev.tolib.orbit"]

    /// Regular app windows on the desktop being shown, matched to their Accessibility elements by frame.
    static func windowsOnCurrentDesktop() -> [Window] {
        let own = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var result: [Window] = []
        var cache: [pid_t: [AXUIElement]] = [:]
        for w in info where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary else { continue }
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &bounds) else { continue }
            let candidates = cache[pid] ?? axWindows(pid)
            cache[pid] = candidates
            if let element = candidates.first(where: { frame($0).map { matches($0, bounds) } ?? false }),
               !result.contains(where: { CFEqual($0.element, element) }) {
                result.append(Window(pid: pid, element: element, appName: app.localizedName ?? "?"))
            }
        }
        return result
    }

    /// Presses each window's close button.
    static func close(_ windows: [Window]) {
        for w in windows {
            var button: AnyObject?
            if AXUIElementCopyAttributeValue(w.element, kAXCloseButtonAttribute as CFString, &button) == .success, let button {
                AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            }
        }
    }

    /// Open only while its app is alive and the window still answers: a closed window's element goes stale,
    /// and an app that quit with its last window (Calculator does) answers with a different error.
    static func isOpen(_ w: Window) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: w.pid), !app.isTerminated else { return false }
        var role: AnyObject?
        let result = AXUIElementCopyAttributeValue(w.element, kAXRoleAttribute as CFString, &role)
        return result == .success || result == .cannotComplete // a busy app (showing a dialog) may not answer at once
    }

    /// Quits apps that have no windows left on any desktop.
    static func quitWindowless(_ pids: Set<pid_t>) {
        for pid in pids {
            guard let app = NSRunningApplication(processIdentifier: pid), !keepRunning.contains(app.bundleIdentifier ?? ""),
                  windowCount(pid) == 0 else { continue }
            app.terminate()
        }
    }

    /// Real windows of a process on every desktop; tiny helper windows don't count.
    static func windowCount(_ pid: pid_t) -> Int {
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.filter { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary else { return false }
            var r = CGRect.zero
            CGRectMakeWithDictionaryRepresentation(dict as CFDictionary, &r)
            return r.width >= 120 && r.height >= 80
        }.count
    }

    static func matches(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
            abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private static func axWindows(_ pid: pid_t) -> [AXUIElement] {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
        return value as? [AXUIElement] ?? []
    }

    private static func frame(_ w: AXUIElement) -> CGRect? {
        var p: AnyObject?, s: AnyObject?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
}
