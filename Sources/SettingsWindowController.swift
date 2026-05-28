import Cocoa
import Carbon.HIToolbox

// MARK: - Shortcut formatting

// Hardware key-code → display string (US QWERTY layout)
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

    var onHotkeysChanged: (() -> Void)?
    var onStartRecording: (() -> Void)?
    var onStopRecording:  (() -> Void)?

    private var tableView: NSTableView!
    private var recordingRow: Int?
    private var keyMonitor: Any?

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 406),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Sizer — Keyboard Shortcuts"
        win.center()
        win.isReleasedWhenClosed = false
        self.init(window: win)
        win.delegate = self
        buildUI()
    }

    // MARK: UI

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .bezelBorder
        cv.addSubview(scroll)

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate   = self
        tableView.allowsColumnResizing    = false
        tableView.allowsMultipleSelection = false
        tableView.rowHeight   = 26
        tableView.focusRingType = .none
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.intercellSpacing = .zero

        let c1 = NSTableColumn(identifier: .init("action"))
        c1.title = "Action"; c1.width = 200
        let c2 = NSTableColumn(identifier: .init("shortcut"))
        c2.title = "Shortcut"; c2.width = 180
        tableView.addTableColumn(c1)
        tableView.addTableColumn(c2)

        scroll.documentView = tableView
        tableView.reloadData()

        let helpLabel = NSTextField(labelWithString: "Click a shortcut to record a new one. Press ⎋ to cancel.")
        helpLabel.translatesAutoresizingMaskIntoConstraints = false
        helpLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        helpLabel.textColor = .secondaryLabelColor
        cv.addSubview(helpLabel)

        let resetBtn = NSButton(title: "Reset Defaults", target: self, action: #selector(resetDefaults))
        resetBtn.translatesAutoresizingMaskIntoConstraints = false
        resetBtn.bezelStyle = .rounded
        cv.addSubview(resetBtn)

        let doneBtn = NSButton(title: "Done", target: self, action: #selector(close))
        doneBtn.translatesAutoresizingMaskIntoConstraints = false
        doneBtn.bezelStyle = .rounded
        doneBtn.keyEquivalent = "\r"
        cv.addSubview(doneBtn)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: cv.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: helpLabel.topAnchor, constant: -12),

            helpLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            helpLabel.bottomAnchor.constraint(equalTo: resetBtn.topAnchor, constant: -10),

            resetBtn.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            resetBtn.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -16),

            doneBtn.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
            doneBtn.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -16),
        ])
    }

    // MARK: Window delegate

    func windowWillClose(_ notification: Notification) {
        stopRecording(cancelled: true)
    }

    // MARK: Actions

    @objc private func resetDefaults() {
        stopRecording(cancelled: true)
        BindingStore.shared.resetAll()
        tableView.reloadData()
        onHotkeysChanged?()
    }

    // MARK: Recording

    private func startRecording(row: Int) {
        guard recordingRow != row else { return }
        stopRecording(cancelled: true)
        recordingRow = row
        onStartRecording?()
        refreshShortcutCell(row)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return nil  // consume — prevents hotkeys from firing while recording
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard let row = recordingRow else { return }

        if event.keyCode == 53 { stopRecording(cancelled: true); return }  // Escape

        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if f.contains(.control) { mods |= UInt32(controlKey) }
        if f.contains(.option)  { mods |= UInt32(optionKey)  }
        if f.contains(.shift)   { mods |= UInt32(shiftKey)   }
        if f.contains(.command) { mods |= UInt32(cmdKey)     }
        guard mods != 0 else { return }  // require at least one modifier

        BindingStore.shared.save(
            id: BindingStore.shared.definitions[row].id,
            keyCode: UInt32(event.keyCode),
            modifiers: mods
        )
        stopRecording(cancelled: false)
        refreshShortcutCell(row)
        onHotkeysChanged?()
    }

    private func stopRecording(cancelled: Bool) {
        let wasRecording = recordingRow != nil
        let prevRow = recordingRow
        recordingRow = nil

        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        guard wasRecording else { return }

        onStopRecording?()
        if cancelled, let row = prevRow { refreshShortcutCell(row) }
    }

    private func refreshShortcutCell(_ row: Int) {
        tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                             columnIndexes: IndexSet(integer: 1))
    }
}

// MARK: - Table data source / delegate

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        BindingStore.shared.definitions.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let def = BindingStore.shared.definitions[row]

        switch tableColumn?.identifier.rawValue {
        case "action":
            let cell = NSTableCellView()
            let tf = NSTextField(labelWithString: def.label)
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf); cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell

        case "shortcut":
            let cell = NSTableCellView()
            let isRec = recordingRow == row
            let btn = NSButton(
                title: "",
                target: self,
                action: #selector(shortcutTapped(_:))
            )
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.tag = row
            btn.bezelStyle = .roundRect
            btn.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

            if isRec {
                btn.attributedTitle = NSAttributedString(
                    string: "Type shortcut…",
                    attributes: [.foregroundColor: NSColor.placeholderTextColor,
                                 .font: NSFont.systemFont(ofSize: 12, weight: .light)]
                )
            } else {
                btn.title = formatShortcut(
                    keyCode:   BindingStore.shared.keyCode(for: def.id),
                    modifiers: BindingStore.shared.modifiers(for: def.id)
                )
            }

            cell.addSubview(btn)
            NSLayoutConstraint.activate([
                btn.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                btn.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            ])
            return cell

        default: return nil
        }
    }

    @objc private func shortcutTapped(_ sender: NSButton) {
        startRecording(row: sender.tag)
    }
}
