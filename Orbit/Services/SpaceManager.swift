import AppKit
import ApplicationServices

/// Adds and removes macOS desktops by driving Mission Control through Accessibility, the way Hammerspoon does.
/// There is no public API for Spaces; Mission Control exposes "mc.spaces.add" and desktop buttons with
/// AXPress / AXRemoveDesktop. On macOS 27 they live in WindowManager, earlier in Dock.
/// Everything here blocks for up to a few seconds — call it off the main thread.
enum SpaceManager {
    /// The desktop Orbit created, found again by its title ("Desktop 7").
    struct Desktop: Codable, Hashable {
        var title: String
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security → Accessibility.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Adds a desktop and switches to it; nil if Mission Control didn't cooperate (nothing is left open then).
    static func createAndSwitch() -> Desktop? {
        guard isTrusted, let bar = openSpacesBar(), let add = bar.add else { closeMissionControl(); return nil }
        let before = desktops(bar.list).count
        AXUIElementPerformAction(add, kAXPressAction as CFString)
        guard let fresh = wait({ desktops(bar.list).count > before ? desktops(bar.list).last : nil }),
              let title = string(fresh, kAXTitleAttribute) else { closeMissionControl(); return nil }
        // Pressing a desktop switches to it and closes Mission Control.
        AXUIElementPerformAction(fresh, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.7)
        return Desktop(title: title)
    }

    /// Removes the desktop Orbit created; its remaining windows move to a neighbouring desktop.
    @discardableResult
    static func remove(_ desktop: Desktop) -> Bool {
        guard isTrusted, let bar = openSpacesBar() else { closeMissionControl(); return false }
        guard let button = desktops(bar.list).first(where: { string($0, kAXTitleAttribute) == desktop.title }) else {
            closeMissionControl()
            return false
        }
        let before = desktops(bar.list).count
        AXUIElementPerformAction(button, "AXRemoveDesktop" as CFString)
        _ = wait { desktops(bar.list).count < before ? true : nil }
        closeMissionControl()
        return true
    }

    // MARK: - Mission Control

    private static let missionControl = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
    private static let hosts = ["com.apple.WindowManager", "com.apple.dock"]

    private static func openSpacesBar() -> (list: AXUIElement, add: AXUIElement?)? {
        NSWorkspace.shared.open(missionControl)
        return wait(timeout: 3) {
            for bundle in hosts {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) {
                    let root = AXUIElementCreateApplication(app.processIdentifier)
                    if let list = find(root, id: "mc.spaces.list"), !desktops(list).isEmpty {
                        let add = list.parent.flatMap { find($0, id: "mc.spaces.add") }
                        return (list, add)
                    }
                }
            }
            return nil
        }
    }

    private static func closeMissionControl() {
        guard isMissionControlOpen else { return }
        NSWorkspace.shared.open(missionControl)
        Thread.sleep(forTimeInterval: 0.5)
    }

    private static var isMissionControlOpen: Bool {
        hosts.contains { bundle in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundle).contains { app in
                find(AXUIElementCreateApplication(app.processIdentifier), id: "mc.spaces.list").map { !desktops($0).isEmpty } ?? false
            }
        }
    }

    private static func desktops(_ list: AXUIElement) -> [AXUIElement] {
        children(list).filter { actions($0).contains("AXRemoveDesktop") }
    }

    // MARK: - AX helpers

    private static func find(_ element: AXUIElement, id: String, depth: Int = 0) -> AXUIElement? {
        guard depth < 6 else { return nil }
        for child in children(element) {
            if string(child, kAXIdentifierAttribute) == id { return child }
            if let hit = find(child, id: id, depth: depth + 1) { return hit }
        }
        return nil
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &value)
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(e, attribute as CFString, &value)
        return value as? String
    }

    private static func actions(_ e: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(e, &names)
        return names as? [String] ?? []
    }

    private static func wait<T>(timeout: TimeInterval = 2, _ probe: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = probe() { return value }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }
}

private extension AXUIElement {
    var parent: AXUIElement? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(self, kAXParentAttribute as CFString, &value)
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
