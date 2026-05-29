import Cocoa
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

// MARK: - Toggle switch

final class ToggleSwitch: NSControl {

    var isOn: Bool = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 24) }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 1, dy: 1)
        let r = track.height / 2
        (isOn ? NSColor.controlAccentColor : NSColor(white: 0.65, alpha: 1)).setFill()
        NSBezierPath(roundedRect: track, xRadius: r, yRadius: r).fill()

        let pad: CGFloat = 2
        let td = track.height - pad * 2
        let tx = isOn ? track.maxX - td - pad : track.minX + pad
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: tx, y: track.minY + pad, width: td, height: td)).fill()
    }
}

private class NonClickableHeaderView: NSTableHeaderView {
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}

// MARK: - Settings window

final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    var onHotkeysChanged: (() -> Void)?
    var onStartRecording: (() -> Void)?
    var onStopRecording:  (() -> Void)?

    private var tableView: NSTableView!
    private var recordingRow: Int?
    private var keyMonitor: Any?
    private weak var enabledSwitch: ToggleSwitch?
    private weak var axStatusLabel: NSTextField?
    private weak var axOpenBtn: NSButton?
    private weak var finderCheckbox: NSButton?
    private weak var finderTextField: NSTextField?

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 580),
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

        // Header: icon + title + enabled toggle

        let iconView = NSImageView(image: makeSizerIcon(dim: 32))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleNone
        cv.addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: "Sizer")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .boldSystemFont(ofSize: 15)
        cv.addSubview(titleLabel)

        let enabledLabel = NSTextField(labelWithString: "Enabled")
        enabledLabel.translatesAutoresizingMaskIntoConstraints = false
        enabledLabel.font = .systemFont(ofSize: 13)
        cv.addSubview(enabledLabel)

        let sw = ToggleSwitch()
        sw.translatesAutoresizingMaskIntoConstraints = false
        sw.isOn = AppDelegate.shared?.isEnabled ?? true
        sw.target = self
        sw.action = #selector(enabledToggled)
        cv.addSubview(sw)
        enabledSwitch = sw

        let divider1 = NSBox()
        divider1.translatesAutoresizingMaskIntoConstraints = false
        divider1.boxType = .separator
        cv.addSubview(divider1)

        // Accessibility status banner

        let axLabel = NSTextField(labelWithString: "")
        axLabel.translatesAutoresizingMaskIntoConstraints = false
        axLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        axLabel.maximumNumberOfLines = 0
        axLabel.lineBreakMode = .byWordWrapping
        cv.addSubview(axLabel)
        axStatusLabel = axLabel

        let axBtn = NSButton(title: "Open Settings", target: self,
                             action: #selector(openAccessibilitySettings))
        axBtn.translatesAutoresizingMaskIntoConstraints = false
        axBtn.bezelStyle = .rounded
        axBtn.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        cv.addSubview(axBtn)
        axOpenBtn = axBtn

        let divider2 = NSBox()
        divider2.translatesAutoresizingMaskIntoConstraints = false
        divider2.boxType = .separator
        cv.addSubview(divider2)

        // Shortcut table

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
        tableView.headerView = NonClickableHeaderView()

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

        let speedLabel = NSTextField(labelWithString: "Animation:")
        speedLabel.translatesAutoresizingMaskIntoConstraints = false
        speedLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        speedLabel.textColor = .secondaryLabelColor
        cv.addSubview(speedLabel)

        let speedControl = NSSegmentedControl(labels: ["Off", "Fast", "Slow"],
                                              trackingMode: .selectOne,
                                              target: self,
                                              action: #selector(speedChanged(_:)))
        speedControl.translatesAutoresizingMaskIntoConstraints = false
        speedControl.selectedSegment = BindingStore.shared.animationSpeed.rawValue
        cv.addSubview(speedControl)

        let resetBtn = NSButton(title: "Reset Defaults", target: self, action: #selector(resetDefaults))
        resetBtn.translatesAutoresizingMaskIntoConstraints = false
        resetBtn.bezelStyle = .rounded
        cv.addSubview(resetBtn)

        let finderLabel = NSTextField(labelWithString: "Finder sidebar:")
        finderLabel.translatesAutoresizingMaskIntoConstraints = false
        finderLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        finderLabel.textColor = .secondaryLabelColor
        cv.addSubview(finderLabel)

        let finderCheck = NSButton(checkboxWithTitle: "Hide if ≥", target: self, action: #selector(finderCheckboxChanged(_:)))
        finderCheck.translatesAutoresizingMaskIntoConstraints = false
        finderCheck.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        finderCheck.state = BindingStore.shared.finderSidebarHideEnabled ? .on : .off
        cv.addSubview(finderCheck)
        finderCheckbox = finderCheck

        let finderField = NSTextField()
        finderField.translatesAutoresizingMaskIntoConstraints = false
        finderField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        finderField.stringValue = "\(BindingStore.shared.finderSidebarHideThreshold)"
        finderField.isEnabled = BindingStore.shared.finderSidebarHideEnabled
        finderField.delegate = self
        finderField.placeholderString = "5"
        cv.addSubview(finderField)
        finderTextField = finderField

        let finderWindowsLabel = NSTextField(labelWithString: "windows")
        finderWindowsLabel.translatesAutoresizingMaskIntoConstraints = false
        finderWindowsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        finderWindowsLabel.textColor = .secondaryLabelColor
        cv.addSubview(finderWindowsLabel)

        let doneBtn = NSButton(title: "Done", target: self, action: #selector(close))
        doneBtn.translatesAutoresizingMaskIntoConstraints = false
        doneBtn.bezelStyle = .rounded
        doneBtn.keyEquivalent = "\r"
        cv.addSubview(doneBtn)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: cv.topAnchor, constant: 14),
            iconView.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            sw.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
            sw.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            sw.widthAnchor.constraint(equalToConstant: 44),
            sw.heightAnchor.constraint(equalToConstant: 24),

            enabledLabel.trailingAnchor.constraint(equalTo: sw.leadingAnchor, constant: -6),
            enabledLabel.centerYAnchor.constraint(equalTo: sw.centerYAnchor),

            divider1.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),
            divider1.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            divider1.trailingAnchor.constraint(equalTo: cv.trailingAnchor),

            axLabel.topAnchor.constraint(equalTo: divider1.bottomAnchor, constant: 8),
            axLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            axLabel.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),

            axBtn.topAnchor.constraint(equalTo: axLabel.bottomAnchor, constant: 6),
            axBtn.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),

            divider2.topAnchor.constraint(equalTo: axBtn.bottomAnchor, constant: 8),
            divider2.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            divider2.trailingAnchor.constraint(equalTo: cv.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: divider2.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: helpLabel.topAnchor, constant: -12),

            helpLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            helpLabel.bottomAnchor.constraint(equalTo: speedLabel.topAnchor, constant: -10),

            speedLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            speedLabel.centerYAnchor.constraint(equalTo: speedControl.centerYAnchor),

            speedControl.leadingAnchor.constraint(equalTo: speedLabel.trailingAnchor, constant: 8),
            speedControl.bottomAnchor.constraint(equalTo: finderCheck.topAnchor, constant: -8),

            finderLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            finderLabel.centerYAnchor.constraint(equalTo: finderCheck.centerYAnchor),

            finderCheck.leadingAnchor.constraint(equalTo: finderLabel.trailingAnchor, constant: 8),
            finderCheck.bottomAnchor.constraint(equalTo: resetBtn.topAnchor, constant: -10),

            finderField.leadingAnchor.constraint(equalTo: finderCheck.trailingAnchor, constant: 6),
            finderField.centerYAnchor.constraint(equalTo: finderCheck.centerYAnchor),
            finderField.widthAnchor.constraint(equalToConstant: 40),

            finderWindowsLabel.leadingAnchor.constraint(equalTo: finderField.trailingAnchor, constant: 4),
            finderWindowsLabel.centerYAnchor.constraint(equalTo: finderCheck.centerYAnchor),

            resetBtn.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            resetBtn.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -16),

            doneBtn.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
            doneBtn.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -16),
        ])

        refreshAccessibilityStatus()
    }

    private func refreshAccessibilityStatus() {
        let trusted = AXIsProcessTrusted()
        axStatusLabel?.stringValue = trusted ? "✓ Accessibility granted" : "⚠ Accessibility not granted — remove and re-add Sizer in Settings"
        axStatusLabel?.textColor   = trusted ? .systemGreen : .systemOrange
        axOpenBtn?.isHidden        = trusted
    }

    // MARK: Window delegate

    func windowDidBecomeKey(_ notification: Notification) {
        refreshAccessibilityStatus()
        enabledSwitch?.isOn = AppDelegate.shared?.isEnabled ?? true
        enabledSwitch?.needsDisplay = true
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording(cancelled: true)
    }

    // MARK: Actions

    @objc private func enabledToggled() {
        AppDelegate.shared?.toggleEnabled(nil)
        enabledSwitch?.isOn = AppDelegate.shared?.isEnabled ?? true
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    @objc private func resetDefaults() {
        stopRecording(cancelled: true)
        BindingStore.shared.resetAll()
        tableView.reloadData()
        onHotkeysChanged?()
    }

    @objc private func speedChanged(_ sender: NSSegmentedControl) {
        BindingStore.shared.animationSpeed = AnimationSpeed(rawValue: sender.selectedSegment) ?? .fast
    }

    private func sidebarThresholdDescription(_ threshold: Int) -> String {
        threshold == 0 ? "Never hide Finder sidebar" : "Hide Finder sidebar if ≥ \(threshold) windows"
    }

    @objc private func finderCheckboxChanged(_ sender: NSButton) {
        BindingStore.shared.finderSidebarHideEnabled = sender.state == .on
        finderTextField?.isEnabled = sender.state == .on
    }

    @objc private func finderThresholdChanged(_ sender: NSStepper) {
        BindingStore.shared.finderSidebarHideThreshold = sender.integerValue
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
            return nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard let row = recordingRow else { return }

        if event.keyCode == 53 { stopRecording(cancelled: true); return }

        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if f.contains(.control) { mods |= UInt32(controlKey) }
        if f.contains(.option)  { mods |= UInt32(optionKey)  }
        if f.contains(.shift)   { mods |= UInt32(shiftKey)   }
        if f.contains(.command) { mods |= UInt32(cmdKey)     }
        guard mods != 0 else { return }

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

extension SettingsWindowController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === finderTextField else { return }
        let v = max(1, Int(field.stringValue) ?? BindingStore.shared.finderSidebarHideThreshold)
        BindingStore.shared.finderSidebarHideThreshold = v
        field.stringValue = "\(v)"
    }
}

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
            let btn = NSButton(title: "", target: self, action: #selector(shortcutTapped(_:)))
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
                let shortcut = formatShortcut(
                    keyCode:   BindingStore.shared.keyCode(for: def.id),
                    modifiers: BindingStore.shared.modifiers(for: def.id)
                )
                btn.attributedTitle = NSAttributedString(
                    string: shortcut,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                        .kern: 2.5,
                    ]
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
