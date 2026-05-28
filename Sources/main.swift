import Cocoa
import Carbon.HIToolbox
import ApplicationServices

// MARK: - Types

enum WindowSnap {
    case left, right, top, bottom                       // halves  (⌃⌥⌘+arrow)
    case topLeft, topRight, bottomLeft, bottomRight     // quarters (⌃⌥⇧+arrow)
    case maximize                                        // ⌃⌥⌘M
    case center                                          // ⌃⌥⌘C – 75% of visible frame
}

// MARK: - Coordinate helpers

private func primaryScreenHeight() -> CGFloat {
    NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
        ?? NSScreen.main?.frame.height
        ?? 900
}

/// AX origin (top-left corner, y downward) for a window of `size` placed at `snap`
/// inside `v` (NS visible frame, bottom-left origin).
///
/// Each snap position has a fixed anchor corner/edge that remains at the screen
/// boundary even when `size` is clamped by a window's minimum-size constraint.
private func axOrigin(snap: WindowSnap, size s: CGSize, visibleFrame v: CGRect, primaryH: CGFloat) -> CGPoint {
    // AX y where the window's TOP edge is flush with the TOP of the visible frame
    let topAX    = primaryH - v.maxY
    // AX y where the window's BOTTOM edge is flush with the BOTTOM of the visible frame
    let bottomAX = primaryH - (v.minY + s.height)
    // AX x where the window's RIGHT edge is flush with the RIGHT of the visible frame
    let rightX   = v.maxX - s.width

    switch snap {
    case .left:        return CGPoint(x: v.minX, y: topAX)
    case .right:       return CGPoint(x: rightX, y: topAX)
    case .top:         return CGPoint(x: v.minX, y: topAX)
    case .bottom:      return CGPoint(x: v.minX, y: bottomAX)
    case .topLeft:     return CGPoint(x: v.minX, y: topAX)
    case .topRight:    return CGPoint(x: rightX, y: topAX)
    case .bottomLeft:  return CGPoint(x: v.minX, y: bottomAX)
    case .bottomRight: return CGPoint(x: rightX, y: bottomAX)
    case .maximize:    return CGPoint(x: v.minX, y: topAX)
    case .center:
        // Re-center using the actual (possibly clamped) size.
        let cx = v.minX + (v.width - s.width)  / 2
        let ay = primaryH - v.midY - s.height / 2
        return CGPoint(x: cx, y: ay)
    }
}

// MARK: - Front-window resolution

/// Returns the window to operate on for the frontmost app.
///
/// If the AX-focused window is a sheet (modal dialog attached to a parent), we
/// redirect to the app's main window so the sheet travels with it.
private func frontWindow(for axApp: AXUIElement) -> AXUIElement? {
    var ref: CFTypeRef?

    if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
       let ref {
        let win = ref as! AXUIElement

        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           (subroleRef as? String) == "AXSheet" {
            // Sheet has focus; operate on the owning main window instead.
            var mainRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &mainRef) == .success,
               let mainRef {
                return (mainRef as! AXUIElement)
            }
        }
        return win
    }

    // Fallback: main window attribute.
    if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &ref) == .success,
       let ref {
        return (ref as! AXUIElement)
    }

    return nil
}

// MARK: - Window snapping

func snapFrontWindow(to snap: WindowSnap) {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }

    let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
    guard let axWindow = frontWindow(for: axApp) else { return }

    // Use the window's current AX position to pick the right screen.
    var axPosRef: CFTypeRef?
    AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &axPosRef)
    var axPos = CGPoint.zero
    if let ref = axPosRef { AXValueGetValue(ref as! AXValue, .cgPoint, &axPos) }

    let screen = NSScreen.screens.first(where: {
        axPos.x >= $0.frame.minX && axPos.x < $0.frame.maxX
    }) ?? NSScreen.main ?? NSScreen.screens[0]

    let v  = screen.visibleFrame  // NS coords, bottom-left origin, excludes menu bar/dock
    let ph = primaryScreenHeight()

    // Desired size for the snap action.
    let desiredSize: CGSize = {
        let half = CGSize(width: v.width / 2, height: v.height / 2)
        switch snap {
        case .left, .right:       return CGSize(width: v.width / 2, height: v.height)
        case .top, .bottom:       return CGSize(width: v.width,     height: v.height / 2)
        case .topLeft, .topRight,
             .bottomLeft, .bottomRight: return half
        case .maximize:           return CGSize(width: v.width,     height: v.height)
        case .center:             return CGSize(width: v.width * 0.75, height: v.height * 0.75)
        }
    }()

    // 1. Apply desired size.
    var sz = desiredSize
    if let sv = AXValueCreate(.cgSize, &sz) {
        AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sv)
    }

    // 2. Read back the actual size – may be clamped by the app's minimum-size constraint.
    var sizeRef: CFTypeRef?
    AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
    var actualSize = desiredSize
    if let ref = sizeRef { AXValueGetValue(ref as! AXValue, .cgSize, &actualSize) }

    // 3. Compute the AX origin using the actual size so the anchor edge/corner
    //    stays at the correct screen boundary even if the window was clamped.
    var origin = axOrigin(snap: snap, size: actualSize, visibleFrame: v, primaryH: ph)

    // 4. Apply position.
    if let pv = AXValueCreate(.cgPoint, &origin) {
        AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, pv)
    }

    // 5. Re-apply size – some apps adjust layout after a position change.
    if let sv = AXValueCreate(.cgSize, &sz) {
        AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sv)
    }
}

// MARK: - Carbon hotkey callback (C-compatible global function)

func hotkeyCallback(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hkID = EventHotKeyID()
    GetEventParameter(
        event!,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hkID
    )
    switch hkID.id {
    // Halves — ⌃⌥⌘+arrow
    case 1:  snapFrontWindow(to: .left)
    case 2:  snapFrontWindow(to: .right)
    case 3:  snapFrontWindow(to: .top)
    case 4:  snapFrontWindow(to: .bottom)
    // Quarters — ⌃⌥⇧+arrow (clockwise from top-left: ←↑→↓)
    case 5:  snapFrontWindow(to: .topLeft)
    case 6:  snapFrontWindow(to: .topRight)
    case 7:  snapFrontWindow(to: .bottomRight)
    case 8:  snapFrontWindow(to: .bottomLeft)
    // Other — ⌃⌥⌘+key
    case 9:  snapFrontWindow(to: .maximize)
    case 10: snapFrontWindow(to: .center)
    default: break
    }
    return noErr
}

// MARK: - Four-char code helper

private func fcc(_ s: String) -> FourCharCode {
    s.utf8.prefix(4).reduce(0) { ($0 << 8) | FourCharCode($1) }
}

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!
    var hotKeyRefs: [EventHotKeyRef] = []
    var eventHandlerRef: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        checkAccessibility()
        registerHotkeys()
    }

    // MARK: Menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            let img = NSImage(systemSymbolName: "rectangle.split.2x2", accessibilityDescription: "Sizer")
                   ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Sizer")
            img?.isTemplate = true
            btn.image = img
        }

        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "Sizer", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(.separator())
        addSection("Halves", items: [
            "⌃⌥⌘← — Left",
            "⌃⌥⌘→ — Right",
            "⌃⌥⌘↑ — Top",
            "⌃⌥⌘↓ — Bottom",
        ], to: menu)

        menu.addItem(.separator())
        addSection("Quarters", items: [
            "⌃⌥⇧← — Top-Left",
            "⌃⌥⇧↑ — Top-Right",
            "⌃⌥⇧→ — Bottom-Right",
            "⌃⌥⇧↓ — Bottom-Left",
        ], to: menu)

        menu.addItem(.separator())
        for label in ["⌃⌥⌘M — Maximize", "⌃⌥⌘C — Center (75%)"] {
            let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Sizer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func addSection(_ header: String, items: [String], to menu: NSMenu) {
        let hItem = NSMenuItem(title: header, action: nil, keyEquivalent: "")
        hItem.isEnabled = false
        menu.addItem(hItem)
        for label in items {
            let item = NSMenuItem(title: "  \(label)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    // MARK: Accessibility

    private func checkAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(opts) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = """
                Sizer needs Accessibility access to resize windows and capture global hotkeys.

                Please grant access in:
                System Settings → Privacy & Security → Accessibility
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                )
            }
        }
    }

    // MARK: Hotkeys

    private func registerHotkeys() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind:  UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), hotkeyCallback, 1, &spec, nil, &eventHandlerRef)

        let halves   = UInt32(controlKey | optionKey | cmdKey)
        let quarters = UInt32(controlKey | optionKey | shiftKey)

        // key codes: left=123, right=124, up=126, down=125, m=46, c=8
        let bindings: [(mods: UInt32, key: UInt32, id: UInt32)] = [
            // Halves
            (halves,   123, 1),   // ⌃⌥⌘← — left
            (halves,   124, 2),   // ⌃⌥⌘→ — right
            (halves,   126, 3),   // ⌃⌥⌘↑ — top
            (halves,   125, 4),   // ⌃⌥⌘↓ — bottom
            // Quarters (clockwise from top-left)
            (quarters, 123, 5),   // ⌃⌥⇧← — top-left
            (quarters, 126, 6),   // ⌃⌥⇧↑ — top-right
            (quarters, 124, 7),   // ⌃⌥⇧→ — bottom-right
            (quarters, 125, 8),   // ⌃⌥⇧↓ — bottom-left
            // Other
            (halves,    46, 9),   // ⌃⌥⌘M — maximize
            (halves,     8, 10),  // ⌃⌥⌘C — center
        ]

        for b in bindings {
            let hkID = EventHotKeyID(signature: fcc("SIZE"), id: b.id)
            var ref: EventHotKeyRef?
            RegisterEventHotKey(b.key, b.mods, hkID, GetApplicationEventTarget(), 0, &ref)
            if let ref { hotKeyRefs.append(ref) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        if let handler = eventHandlerRef { RemoveEventHandler(handler) }
    }
}

// MARK: - Entry point

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
