import Cocoa
import SwiftUI
import Carbon.HIToolbox

// MARK: - Shortcut formatting

let keyNames: [UInt32: String] = [
    // Arrows
    123: "←", 124: "→", 125: "↓", 126: "↑",
    // Letters
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
    8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
    16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 37: "L", 38: "J",
    40: "K", 45: "N", 46: "M",
    // Numbers
    18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
    25: "9", 26: "7", 28: "8", 29: "0",
    // Special
    36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
    // Function
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
    98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
]

func formatShortcut(keyCode: UInt32, modifiers: UInt32) -> String {
    var m = ""
    if modifiers & UInt32(controlKey) != 0 { m += "⌃" }
    if modifiers & UInt32(optionKey)  != 0 { m += "⌥" }
    if modifiers & UInt32(shiftKey)   != 0 { m += "⇧" }
    if modifiers & UInt32(cmdKey)     != 0 { m += "⌘" }
    return m + (keyNames[keyCode] ?? "(\(keyCode))")
}

// MARK: - Settings window

final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    let state = SettingsState()

    var onHotkeysChanged: (() -> Void)? {
        get { state.onHotkeysChanged }
        set { state.onHotkeysChanged = newValue }
    }
    var onStartRecording: (() -> Void)? {
        get { state.onStartRecording }
        set { state.onStartRecording = newValue }
    }
    var onStopRecording: (() -> Void)? {
        get { state.onStopRecording }
        set { state.onStopRecording = newValue }
    }

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Sizer Settings"
        win.center()
        win.isReleasedWhenClosed = false
        self.init(window: win)
        win.delegate = self
        win.contentViewController = NSHostingController(rootView: SettingsView(state: state))
    }

    func windowDidBecomeKey(_ notification: Notification) {
        state.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        state.stopRecording(cancelled: true)
    }
}
