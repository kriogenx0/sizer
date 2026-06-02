import Cocoa
import Carbon.HIToolbox
import ApplicationServices
import ServiceManagement

// MARK: - Types

enum WindowSnap {
    case left, right, top, bottom                       // halves  (⌃⌥⌘+arrow)
    case topLeft, topRight, bottomLeft, bottomRight     // quarters (⌃⌥⇧+arrow)
    case maximize                                        // ⌃⌥⌘M
    case center                                          // ⌃⌥⌘C – 75% of visible frame
    case center50                                        // ⌃⌥X  – 50% of visible frame
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
        return CGPoint(x: v.minX + (v.width - s.width) / 2,
                       y: primaryH - v.midY - s.height / 2)
    case .center50:
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

/// Animate size and position simultaneously to the snap target.
/// On the final frame, corrects position if the window clamped to a minimum size.
private func animateSnap(_ axWindow: AXUIElement,
                          startSize: CGSize, endSize: CGSize,
                          snap: WindowSnap, visibleFrame v: CGRect, primaryH: CGFloat,
                          currentPos: CGPoint) {
    pendingAnimations.forEach { $0.cancel() }
    pendingAnimations.removeAll()

    let duration = BindingStore.shared.animationSpeed.duration

    if duration == 0 {
        // Position first so the window can grow without hitting the bottom/right screen edge
        let targetPos = axOrigin(snap: snap, size: endSize, visibleFrame: v, primaryH: primaryH)
        var pos = targetPos
        if let pv = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, pv)
        }
        var sz = endSize
        if let sv = AXValueCreate(.cgSize, &sz) {
            AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sv)
        }
        // Correct position if size was clamped to a minimum
        var actualSzRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &actualSzRef)
        var actualSize = endSize
        if let r = actualSzRef { AXValueGetValue(r as! AXValue, .cgSize, &actualSize) }
        if actualSize.width != endSize.width || actualSize.height != endSize.height {
            var correctedPos = axOrigin(snap: snap, size: actualSize, visibleFrame: v, primaryH: primaryH)
            if let pv = AXValueCreate(.cgPoint, &correctedPos) {
                AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, pv)
            }
        }
        return
    }

    let targetPos = axOrigin(snap: snap, size: endSize, visibleFrame: v, primaryH: primaryH)
    let steps = 12

    for i in 1...steps {
        let t  = easeInOut(Double(i) / Double(steps))
        var sz = CGSize(width:  startSize.width  + (endSize.width  - startSize.width)  * t,
                        height: startSize.height + (endSize.height - startSize.height) * t)
        var pos = CGPoint(x: currentPos.x + (targetPos.x - currentPos.x) * t,
                          y: currentPos.y + (targetPos.y - currentPos.y) * t)

        let item = DispatchWorkItem {
            // Position first so growth doesn't get clipped by screen bounds mid-animation
            if let pv = AXValueCreate(.cgPoint, &pos) {
                AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, pv)
            }
            if let sv = AXValueCreate(.cgSize, &sz) {
                AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sv)
            }
        }
        pendingAnimations.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration * t, execute: item)
    }

    // After the animation settles, re-read the actual size. If the window clamped to a
    // minimum size, reposition so the anchor edge stays flush.
    let correction = DispatchWorkItem {
        var actualSzRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &actualSzRef)
        var actualSize = endSize
        if let r = actualSzRef { AXValueGetValue(r as! AXValue, .cgSize, &actualSize) }
        guard actualSize.width != endSize.width || actualSize.height != endSize.height else { return }
        var correctedPos = axOrigin(snap: snap, size: actualSize, visibleFrame: v, primaryH: primaryH)
        if let pv = AXValueCreate(.cgPoint, &correctedPos) {
            AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, pv)
        }
    }
    pendingAnimations.append(correction)
    DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1, execute: correction)
}

// MARK: - Window snapping

func snapFrontWindow(to snap: WindowSnap) {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }

    let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
    guard let axWindow = frontWindow(for: axApp) else { return }

    // Determine the screen from the window's current position.
    var axPosRef: CFTypeRef?
    AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &axPosRef)
    var currentPos = CGPoint.zero
    if let ref = axPosRef { AXValueGetValue(ref as! AXValue, .cgPoint, &currentPos) }

    let screen = NSScreen.screens.first(where: {
        currentPos.x >= $0.frame.minX && currentPos.x < $0.frame.maxX
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
        case .center50:          return CGSize(width: v.width * 0.50, height: v.height * 0.50)
        }
    }()

    // Read current size as the starting point for the resize animation.
    var currentSizeRef: CFTypeRef?
    AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &currentSizeRef)
    var currentSize = desiredSize
    if let ref = currentSizeRef { AXValueGetValue(ref as! AXValue, .cgSize, &currentSize) }

    let effectiveEndSize: CGSize
    if abs(currentSize.width - desiredSize.width) <= 2 && abs(currentSize.height - desiredSize.height) <= 2 {
        effectiveEndSize = currentSize
    } else {
        effectiveEndSize = desiredSize
    }

    animateSnap(axWindow, startSize: currentSize, endSize: effectiveEndSize,
                snap: snap, visibleFrame: v, primaryH: ph, currentPos: currentPos)
}

// MARK: - Auto-arrange all app windows

private func frontAppWindows() -> (windows: [AXUIElement], v: CGRect, ph: CGFloat)? {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
    let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)

    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let rawWindows = windowsRef as? [AXUIElement] else { return nil }

    let windows = rawWindows.filter { win -> Bool in
        var subroleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subroleRef) == .success,
              (subroleRef as? String) == "AXStandardWindow" else { return false }
        var minRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minRef) == .success,
           (minRef as? Bool) == true { return false }
        return true
    }
    guard !windows.isEmpty else { return nil }

    let fw = frontWindow(for: axApp)
    var axPosRef: CFTypeRef?
    if let fw { AXUIElementCopyAttributeValue(fw, kAXPositionAttribute as CFString, &axPosRef) }
    var frontPos = CGPoint.zero
    if let r = axPosRef { AXValueGetValue(r as! AXValue, .cgPoint, &frontPos) }

    let screen = NSScreen.screens.first(where: {
        frontPos.x >= $0.frame.minX && frontPos.x < $0.frame.maxX
    }) ?? NSScreen.main ?? NSScreen.screens[0]

    return (windows, screen.visibleFrame, primaryScreenHeight())
}

private func animateArrange(_ windows: [AXUIElement], endSizes: [CGSize], endPositions: [CGPoint]) {
    pendingAnimations.forEach { $0.cancel() }
    pendingAnimations.removeAll()

    let duration = windows.count > 4 ? 0.0 : BindingStore.shared.animationSpeed.duration

    if duration == 0 {
        for (i, win) in windows.enumerated() {
            var pos = endPositions[i]
            if let pv = AXValueCreate(.cgPoint, &pos) {
                AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv)
            }
            var sz = endSizes[i]
            if let sv = AXValueCreate(.cgSize, &sz) {
                AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
            }
        }
        return
    }

    let startSizes: [CGSize] = windows.enumerated().map { i, win in
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &ref)
        var sz = endSizes[i]
        if let r = ref { AXValueGetValue(r as! AXValue, .cgSize, &sz) }
        return sz
    }
    let startPositions: [CGPoint] = windows.enumerated().map { i, win in
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &ref)
        var pos = endPositions[i]
        if let r = ref { AXValueGetValue(r as! AXValue, .cgPoint, &pos) }
        return pos
    }

    let steps = 8
    for step in 1...steps {
        let t        = Double(step) / Double(steps)   // uniform deadline spacing
        let progress = easeInOut(t)                    // eased interpolation value
        let item = DispatchWorkItem {
            for (i, win) in windows.enumerated() {
                let sp = startPositions[i], ep = endPositions[i]
                let ss = startSizes[i],     es = endSizes[i]
                var pos = CGPoint(x: sp.x + (ep.x - sp.x) * progress,
                                  y: sp.y + (ep.y - sp.y) * progress)
                var sz  = CGSize(width:  ss.width  + (es.width  - ss.width)  * progress,
                                 height: ss.height + (es.height - ss.height) * progress)
                if let pv = AXValueCreate(.cgPoint, &pos) {
                    AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv)
                }
                if let sv = AXValueCreate(.cgSize, &sz) {
                    AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
                }
            }
        }
        pendingAnimations.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration * t, execute: item)
    }
}

func arrangeFrontAppWindows() {
    guard let (windows, v, ph) = frontAppWindows() else { return }
    let n  = windows.count
    let cw = v.width / CGFloat(n)
    let endSizes     = (0..<n).map { _ in CGSize(width: cw, height: v.height) }
    let endPositions = (0..<n).map { i in CGPoint(x: v.minX + CGFloat(i) * cw, y: ph - v.maxY) }
    hideFinderSidebarsIfNeeded(windowCount: n)
    animateArrange(windows, endSizes: endSizes, endPositions: endPositions)
}

func arrangeFrontAppWindowsGrid() {
    guard let (windows, v, ph) = frontAppWindows() else { return }
    let n = windows.count

    let endSizes:     [CGSize]
    let endPositions: [CGPoint]

    if n == 1 {
        endSizes     = [CGSize(width: v.width, height: v.height)]
        endPositions = [CGPoint(x: v.minX, y: ph - v.maxY)]
    } else {
        let topCount = n / 2
        let botCount = (n + 1) / 2
        let rowH     = v.height / 2

        var sizes:     [CGSize]  = []
        var positions: [CGPoint] = []

        if topCount > 0 {
            let cw = v.width / CGFloat(topCount)
            for i in 0..<topCount {
                sizes.append(CGSize(width: cw, height: rowH))
                positions.append(CGPoint(x: v.minX + CGFloat(i) * cw, y: ph - v.maxY))
            }
        }

        let cw = v.width / CGFloat(botCount)
        for i in 0..<botCount {
            sizes.append(CGSize(width: cw, height: rowH))
            positions.append(CGPoint(x: v.minX + CGFloat(i) * cw, y: ph - (v.minY + rowH)))
        }

        endSizes     = sizes
        endPositions = positions
    }

    hideFinderSidebarsIfNeeded(windowCount: n)
    animateArrange(windows, endSizes: endSizes, endPositions: endPositions)
}

private func hideFinderSidebarsIfNeeded(windowCount: Int) {
    guard BindingStore.shared.finderSidebarHideEnabled else { return }
    let threshold = BindingStore.shared.finderSidebarHideThreshold
    guard threshold > 0,
          windowCount >= threshold,
          NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", "tell application \"Finder\" to set sidebar width of every window to 0"]
    try? task.run()
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

    if hkID.id == 12 {
        DispatchQueue.main.async { AppDelegate.shared?.pulseIcon() }
        if AXIsProcessTrusted() { arrangeFrontAppWindows() }
        else { AppDelegate.shared?.checkAccessibility() }
        return noErr
    }

    if hkID.id == 13 {
        DispatchQueue.main.async { AppDelegate.shared?.pulseIcon() }
        if AXIsProcessTrusted() { arrangeFrontAppWindowsGrid() }
        else { AppDelegate.shared?.checkAccessibility() }
        return noErr
    }

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
        case 11: return .center50
        default: return nil
        }
    }()

    if let snap {
        DispatchQueue.main.async { AppDelegate.shared?.pulseIcon() }
        if AXIsProcessTrusted() {
            snapFrontWindow(to: snap)
        } else {
            AppDelegate.shared?.checkAccessibility()
        }
    }
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

    private(set) var isEnabled: Bool = UserDefaults.standard.object(forKey: "sizerEnabled") as? Bool ?? true
    private weak var toggleMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        checkAccessibility()
        registerHotkeys()
        applyLaunchAtLogin()
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

        for group in [[1,2,3,4], [5,6,7,8], [9,10,11], [12,13]] {
            menu.addItem(.separator())
            for id in group {
                guard let def = BindingStore.shared.definitions.first(where: { $0.id == UInt32(id) }) else { continue }
                let shortcut = formatShortcut(
                    keyCode:   BindingStore.shared.keyCode(for: def.id),
                    modifiers: BindingStore.shared.modifiers(for: def.id)
                )
                let item = NSMenuItem(title: "\(def.label)\t\(shortcut)",
                                      action: #selector(menuSnapAction(_:)),
                                      keyEquivalent: "")
                item.tag = Int(def.id)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings(_:)),
                                      keyEquivalent: ",")
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: "Quit Sizer",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc func menuSnapAction(_ sender: NSMenuItem) {
        guard let def = BindingStore.shared.definitions.first(where: { $0.id == UInt32(sender.tag) }) else { return }
        if let snap = def.snap {
            snapFrontWindow(to: snap)
        } else if def.id == 12 {
            arrangeFrontAppWindows()
        } else if def.id == 13 {
            arrangeFrontAppWindowsGrid()
        }
    }

    // MARK: Launch at Login

    func applyLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            if BindingStore.shared.launchAtLogin {
                try? SMAppService.mainApp.register()
            } else {
                try? SMAppService.mainApp.unregister()
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        BindingStore.shared.launchAtLogin = enabled
        applyLaunchAtLogin()
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

    func pulseIcon() {
        statusItem.button?.alphaValue = 0.25
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.applyIconState()
        }
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

    func checkAccessibility() {
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
func makeSizerIcon(dim: CGFloat = 18) -> NSImage {
    let img = NSImage(size: NSSize(width: dim, height: dim), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

        let s = dim / 18   // scale factor relative to the original 18 pt grid

        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.boldSystemFont(ofSize: 10 * s),
            .foregroundColor: NSColor.black,
        ]
        let str = "S" as NSString
        let sz  = str.size(withAttributes: attrs)
        str.draw(at: CGPoint(x: (dim - sz.width) / 2, y: (dim - sz.height) / 2),
                 withAttributes: attrs)

        func arrow(tip: CGPoint, l: CGPoint, r: CGPoint) {
            ctx.beginPath(); ctx.move(to: tip)
            ctx.addLine(to: l); ctx.addLine(to: r)
            ctx.closePath(); ctx.fillPath()
        }

        ctx.setFillColor(NSColor.black.cgColor)
        let m = dim / 2
        arrow(tip: CGPoint(x: m,         y: dim - 1*s), l: CGPoint(x: m - 2.5*s, y: dim - 4.5*s), r: CGPoint(x: m + 2.5*s, y: dim - 4.5*s)) // ▲
        arrow(tip: CGPoint(x: m,         y: 1*s),       l: CGPoint(x: m - 2.5*s, y: 4.5*s),       r: CGPoint(x: m + 2.5*s, y: 4.5*s))       // ▼
        arrow(tip: CGPoint(x: 1*s,       y: m),         l: CGPoint(x: 4.5*s,     y: m - 2.5*s),   r: CGPoint(x: 4.5*s,     y: m + 2.5*s))   // ◀
        arrow(tip: CGPoint(x: dim - 1*s, y: m),         l: CGPoint(x: dim-4.5*s, y: m - 2.5*s),   r: CGPoint(x: dim-4.5*s, y: m + 2.5*s))   // ▶
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
