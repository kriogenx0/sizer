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
/// Each snap position has a fixed anchor corner/edge that stays at the screen
/// boundary even when `size` is clamped by the window's minimum-size constraint.
private func axOrigin(snap: WindowSnap, size s: CGSize, visibleFrame v: CGRect, primaryH: CGFloat) -> CGPoint {
    let topAX    = primaryH - v.maxY
    let bottomAX = primaryH - (v.minY + s.height)
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
        // Re-center using the actual (possibly clamped) size so the window is
        // truly centered for whatever dimensions it could achieve.
        return CGPoint(x: v.minX + (v.width - s.width) / 2,
                       y: primaryH - v.midY - s.height / 2)
    }
}

// MARK: - Front-window resolution

private func frontWindow(for axApp: AXUIElement) -> AXUIElement? {
    var ref: CFTypeRef?

    if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
       let ref {
        let win = ref as! AXUIElement
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           (subroleRef as? String) == "AXSheet" {
            var mainRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &mainRef) == .success,
               let mainRef { return (mainRef as! AXUIElement) }
        }
        return win
    }

    if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &ref) == .success,
       let ref { return (ref as! AXUIElement) }

    return nil
}

// MARK: - Animation

private var pendingAnimations: [DispatchWorkItem] = []

private func easeInOut(_ t: Double) -> Double {
    t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t
}

/// Animate the AX window from `start` to `end` over ~180 ms.
/// Size is applied instantly first (to resolve clamping); only position is animated.
private func animatePosition(_ axWindow: AXUIElement,
                              from start: CGPoint, to end: CGPoint,
                              finalSize: CGSize) {
    pendingAnimations.forEach { $0.cancel() }
    pendingAnimations.removeAll()

    let steps = 12
    let duration = 0.18

    for i in 1...steps {
        let t  = Double(i) / Double(steps)
        let et = easeInOut(t)
        var pos = CGPoint(x: start.x + (end.x - start.x) * et,
                          y: start.y + (end.y - start.y) * et)
        let isLast = i == steps
        var sz = finalSize

        let item = DispatchWorkItem {
            if let pv = AXValueCreate(.cgPoint, &pos) {
                AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, pv)
            }
            if isLast, let sv = AXValueCreate(.cgSize, &sz) {
                AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sv)
            }
        }
        pendingAnimations.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration * t, execute: item)
    }
}

// MARK: - Window snapping

func snapFrontWindow(to snap: WindowSnap) {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }

    let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
    guard let axWindow = frontWindow(for: axApp) else { return }

    // Determine the screen from the window's current position.
    var axPosRef0: CFTypeRef?
    AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &axPosRef0)
    var prePos = CGPoint.zero
    if let ref = axPosRef0 { AXValueGetValue(ref as! AXValue, .cgPoint, &prePos) }

    let screen = NSScreen.screens.first(where: {
        prePos.x >= $0.frame.minX && prePos.x < $0.frame.maxX
    }) ?? NSScreen.main ?? NSScreen.screens[0]

    let v  = screen.visibleFrame
    let ph = primaryScreenHeight()

    let desiredSize: CGSize = {
        switch snap {
        case .left, .right:      return CGSize(width: v.width / 2, height: v.height)
        case .top, .bottom:      return CGSize(width: v.width,     height: v.height / 2)
        case .topLeft, .topRight,
             .bottomLeft, .bottomRight:
                                  return CGSize(width: v.width / 2, height: v.height / 2)
        case .maximize:          return CGSize(width: v.width,     height: v.height)
        case .center:            return CGSize(width: v.width * 0.75, height: v.height * 0.75)
        }
    }()

    // Apply desired size instantly – resolves minimum-size clamping before position math.
    var sz = desiredSize
    if let sv = AXValueCreate(.cgSize, &sz) {
        AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sv)
    }

    // Read back the actual size (may be clamped by the app's minimum-size constraint).
    var sizeRef: CFTypeRef?
    AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
    var actualSize = desiredSize
    if let ref = sizeRef { AXValueGetValue(ref as! AXValue, .cgSize, &actualSize) }

    // Read the position *after* the size change — some apps shift the window origin
    // when resized, so animating from the post-resize position avoids a visual jump.
    var axPosRef: CFTypeRef?
    AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &axPosRef)
    var currentOrigin = CGPoint.zero
    if let ref = axPosRef { AXValueGetValue(ref as! AXValue, .cgPoint, &currentOrigin) }

    // Compute the target AX origin anchored to the correct corner/edge using the
    // actual post-resize size. For .center this means the window is truly centered
    // for whatever dimensions it could achieve.
    let targetOrigin = axOrigin(snap: snap, size: actualSize, visibleFrame: v, primaryH: ph)

    // Animate position from where the window is now to the target.
    animatePosition(axWindow, from: currentOrigin, to: targetOrigin, finalSize: sz)
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

    let snap: WindowSnap? = {
        switch hkID.id {
        case 1:  return .left
        case 2:  return .right
        case 3:  return .top
        case 4:  return .bottom
        case 5:  return .topLeft
        case 6:  return .topRight
        case 7:  return .bottomRight
        case 8:  return .bottomLeft
        case 9:  return .maximize
        case 10: return .center
        default: return nil
        }
    }()

    if let snap { snapFrontWindow(to: snap) }
    return noErr
}

// MARK: - Four-char code helper

private func fcc(_ s: String) -> FourCharCode {
    s.utf8.prefix(4).reduce(0) { ($0 << 8) | FourCharCode($1) }
}

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    static weak var shared: AppDelegate?

    var statusItem: NSStatusItem!
    var hotKeyRefs: [EventHotKeyRef] = []
    var eventHandlerRef: EventHandlerRef?
    private var settingsController: SettingsWindowController?

    private var isEnabled: Bool = UserDefaults.standard.object(forKey: "sizerEnabled") as? Bool ?? true
    private weak var toggleMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        checkAccessibility()
        registerHotkeys()
    }

    // MARK: Menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            btn.image = makeSizerIcon()
            applyIconState()
        }

        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "Sizer", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "Enabled",
                                action: #selector(toggleEnabled(_:)),
                                keyEquivalent: "")
        toggle.state = isEnabled ? .on : .off
        toggleMenuItem = toggle
        menu.addItem(toggle)

        menu.addItem(.separator())
        addSection("Halves", items: [
            "⌃⌥⌘← — Left", "⌃⌥⌘→ — Right",
            "⌃⌥⌘↑ — Top",  "⌃⌥⌘↓ — Bottom",
        ], to: menu)

        menu.addItem(.separator())
        addSection("Quarters", items: [
            "⌃⌥⇧← — Top-Left",    "⌃⌥⇧↑ — Top-Right",
            "⌃⌥⇧→ — Bottom-Right", "⌃⌥⇧↓ — Bottom-Left",
        ], to: menu)

        menu.addItem(.separator())
        for label in ["⌃⌥⌘M — Maximize", "⌃⌥⌘C — Center (75%)"] {
            let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…",
                                action: #selector(openSettings(_:)),
                                keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit Sizer",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func addSection(_ header: String, items: [String], to menu: NSMenu) {
        let h = NSMenuItem(title: header, action: nil, keyEquivalent: "")
        h.isEnabled = false
        menu.addItem(h)
        for label in items {
            let item = NSMenuItem(title: "  \(label)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    // MARK: Toggle

    @objc func toggleEnabled(_ sender: Any?) {
        isEnabled.toggle()
        UserDefaults.standard.set(isEnabled, forKey: "sizerEnabled")
        toggleMenuItem?.state = isEnabled ? .on : .off
        applyIconState()
        isEnabled ? reloadHotkeys() : suspendHotkeys()
    }

    private func applyIconState() {
        statusItem.button?.alphaValue = isEnabled ? 1.0 : 0.5
    }

    // MARK: Settings

    @objc func openSettings(_ sender: Any?) {
        if settingsController == nil {
            let ctrl = SettingsWindowController()
            ctrl.onHotkeysChanged = { [weak self] in self?.reloadHotkeys() }
            ctrl.onStartRecording = { [weak self] in self?.suspendHotkeys() }
            ctrl.onStopRecording  = { [weak self] in self?.reloadHotkeys() }
            settingsController = ctrl
        }
        settingsController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        reloadHotkeys()
    }

    func reloadHotkeys() {
        suspendHotkeys()
        guard isEnabled else { return }
        for def in BindingStore.shared.definitions {
            let hkID = EventHotKeyID(signature: fcc("SIZE"), id: def.id)
            var ref: EventHotKeyRef?
            RegisterEventHotKey(
                BindingStore.shared.keyCode(for: def.id),
                BindingStore.shared.modifiers(for: def.id),
                hkID, GetApplicationEventTarget(), 0, &ref
            )
            if let ref { hotKeyRefs.append(ref) }
        }
    }

    func suspendHotkeys() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        suspendHotkeys()
        if let handler = eventHandlerRef { RemoveEventHandler(handler) }
    }
}

// MARK: - Status bar icon

/// Draws an "S" with four outward-pointing arrowheads as a template image.
private func makeSizerIcon() -> NSImage {
    let dim: CGFloat = 18
    let img = NSImage(size: NSSize(width: dim, height: dim), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

        // "S" centred in the icon
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.boldSystemFont(ofSize: 10),
            .foregroundColor: NSColor.black,
        ]
        let str = "S" as NSString
        let sz  = str.size(withAttributes: attrs)
        str.draw(at: CGPoint(x: (dim - sz.width) / 2, y: (dim - sz.height) / 2),
                 withAttributes: attrs)

        // Solid arrowhead helper
        func arrow(tip: CGPoint, l: CGPoint, r: CGPoint) {
            ctx.beginPath(); ctx.move(to: tip)
            ctx.addLine(to: l); ctx.addLine(to: r)
            ctx.closePath(); ctx.fillPath()
        }

        ctx.setFillColor(NSColor.black.cgColor)
        let m = dim / 2
        arrow(tip: CGPoint(x: m,       y: dim - 1), l: CGPoint(x: m - 2.5, y: dim - 4.5), r: CGPoint(x: m + 2.5, y: dim - 4.5)) // ▲
        arrow(tip: CGPoint(x: m,       y: 1),       l: CGPoint(x: m - 2.5, y: 4.5),       r: CGPoint(x: m + 2.5, y: 4.5))       // ▼
        arrow(tip: CGPoint(x: 1,       y: m),       l: CGPoint(x: 4.5,     y: m - 2.5),   r: CGPoint(x: 4.5,     y: m + 2.5))   // ◀
        arrow(tip: CGPoint(x: dim - 1, y: m),       l: CGPoint(x: dim-4.5, y: m - 2.5),   r: CGPoint(x: dim-4.5, y: m + 2.5))   // ▶
        return true
    }
    img.isTemplate = true
    return img
}

// MARK: - Entry point

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
