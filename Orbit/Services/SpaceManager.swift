import AppKit
import ApplicationServices

/// Adds and removes macOS desktops by driving Mission Control through Accessibility, the way Hammerspoon does.
/// There is no public API for Spaces; Mission Control exposes "mc.spaces.add" and desktop buttons with
/// AXPress / AXRemoveDesktop. On macOS 27 they live in WindowManager, earlier in Dock.
/// Everything here blocks for up to a few seconds — call it off the main thread.
enum SpaceManager {
    /// The desktop Orbit created. `spaceID` stays the same when desktops are renumbered;
    /// the title is only a fallback for records written by 1.1.0.
    struct Desktop: Codable, Hashable {
        var title: String
        var spaceID: UInt64?
        /// Where you were before "Начать разработку"; "Стоп" brings you back there.
        var returnTo: UInt64?
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
        let origin = Spaces.active()
        guard isTrusted, let bar = openSpacesBar(), let add = bar.add else { closeMissionControl(); return nil }
        let before = desktops(bar.list).count
        AXUIElementPerformAction(add, kAXPressAction as CFString)
        guard let fresh = wait({ desktops(bar.list).count > before ? desktops(bar.list).last : nil }),
              let title = string(fresh, kAXTitleAttribute) else { closeMissionControl(); return nil }
        // Pressing a desktop switches to it and closes Mission Control.
        AXUIElementPerformAction(fresh, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.7)
        return Desktop(title: title, spaceID: Spaces.active(), returnTo: origin)
    }

    /// Switches to the desktop and confirms by its id that it is really there; false changes nothing on screen.
    static func switchTo(_ desktop: Desktop) -> Bool {
        if let id = desktop.spaceID, Spaces.active() == id { return true }
        guard isTrusted, let bar = openSpacesBar(), let button = button(for: desktop, in: bar.list) else { closeMissionControl(); return false }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard let id = desktop.spaceID else { Thread.sleep(forTimeInterval: 0.7); return true }
        return wait { Spaces.active() == id ? true : nil } ?? false
    }

    /// Whether Orbit's desktop still exists.
    static func exists(_ desktop: Desktop) -> Bool {
        guard let id = desktop.spaceID else { return true }
        return Spaces.ids().contains(id)
    }

    /// Removes the desktop Orbit created; its remaining windows move to a neighbouring desktop.
    @discardableResult
    static func remove(_ desktop: Desktop) -> Bool {
        guard exists(desktop) else { return true }
        guard isTrusted, let bar = openSpacesBar(), let button = button(for: desktop, in: bar.list) else {
            closeMissionControl()
            return false
        }
        let before = desktops(bar.list).count
        AXUIElementPerformAction(button, "AXRemoveDesktop" as CFString)
        _ = wait { desktops(bar.list).count < before ? true : nil }
        closeMissionControl()
        let removed = !exists(desktop)
        if removed, let back = desktop.returnTo, back != desktop.spaceID, Spaces.ids().contains(back) {
            Thread.sleep(forTimeInterval: 0.3)
            _ = switchTo(Desktop(title: "", spaceID: back))
        }
        return removed
    }

    /// The Mission Control button of a desktop: by position of its id among the display's spaces, so a renumbered
    /// "Desktop 5" is never mistaken for another one. Without an id (1.1.0 records) the title is used.
    private static func button(for desktop: Desktop, in list: AXUIElement) -> AXUIElement? {
        let buttons = children(list)
        guard let id = desktop.spaceID else {
            return desktops(list).first { string($0, kAXTitleAttribute) == desktop.title }
        }
        let order = Spaces.ids()
        guard order.count == buttons.count, let index = order.firstIndex(of: id) else { return nil }
        return buttons[index]
    }

    // MARK: - Mission Control

    private static let missionControl = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
    private static let hosts = ["com.apple.WindowManager", "com.apple.dock"]

    private static func openSpacesBar() -> (list: AXUIElement, add: AXUIElement?)? {
        NSWorkspace.shared.open(missionControl)
        return wait(timeout: 4) {
            for pid in hostPIDs() {
                    let root = AXUIElementCreateApplication(pid)
                    if let list = find(root, id: "mc.spaces.list"), !desktops(list).isEmpty {
                        let add = list.parent.flatMap { find($0, id: "mc.spaces.add") }
                        return (list, add)
                    }
            }
            return nil
        }
    }

    /// WindowManager (macOS 27) and Dock; pgrep backs up the running-apps list, which can lag behind.
    private static func hostPIDs() -> [pid_t] {
        var pids = hosts.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier) }
        for name in ["WindowManager", "Dock"] { pids += pgrep(name) }
        var seen = Set<pid_t>()
        return pids.filter { seen.insert($0).inserted }
    }

    private static func closeMissionControl() {
        guard isMissionControlOpen else { return }
        NSWorkspace.shared.open(missionControl)
        Thread.sleep(forTimeInterval: 0.5)
    }

    private static func pgrep(_ name: String) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", name]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: "\n").compactMap { pid_t($0) }
    }

    private static var isMissionControlOpen: Bool {
        hostPIDs().contains { pid in
            find(AXUIElementCreateApplication(pid), id: "mc.spaces.list").map { !desktops($0).isEmpty } ?? false
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

/// Space ids through private CoreGraphics calls (the same ones Hammerspoon and yabai read). Looked up at runtime,
/// so a macOS without them simply turns the desktop feature off instead of crashing.
enum Spaces {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Active = @convention(c) (Int32) -> UInt64
    private typealias Managed = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
    private static let connection: Int32? = dlsym(handle, "CGSMainConnectionID").map { unsafeBitCast($0, to: Connection.self)() }

    static func active() -> UInt64? {
        guard let connection, let fn = dlsym(handle, "CGSGetActiveSpace") else { return nil }
        let id = unsafeBitCast(fn, to: Active.self)(connection)
        return id == 0 ? nil : id
    }

    /// Spaces of the display that shows the active space, in Mission Control order.
    static func ids() -> [UInt64] {
        guard let connection, let fn = dlsym(handle, "CGSCopyManagedDisplaySpaces"),
              let displays = unsafeBitCast(fn, to: Managed.self)(connection)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        let all = displays.map { ($0["Spaces"] as? [[String: Any]] ?? []).compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value } }
        let current = active()
        return all.first { current.map($0.contains) ?? false } ?? all.first ?? []
    }
}
