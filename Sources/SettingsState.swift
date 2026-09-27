import Cocoa
import Carbon.HIToolbox
import Combine

final class SettingsState: ObservableObject {

    struct ShortcutBinding: Identifiable {
        let id: UInt32
        let label: String
        var keyCode: UInt32
        var modifiers: UInt32
    }

    @Published var isEnabled: Bool
    @Published var axTrusted: Bool = AXIsProcessTrusted()
    @Published var animationSpeed: AnimationSpeed
    @Published var finderSidebarHideEnabled: Bool
    @Published var finderSidebarHideThreshold: Int
    @Published var launchAtLogin: Bool
    @Published var shortcuts: [ShortcutBinding]
    @Published var recordingID: UInt32?

    var onHotkeysChanged: (() -> Void)?
    var onStartRecording: (() -> Void)?
    var onStopRecording: (() -> Void)?

    private var keyMonitor: Any?

    init() {
        isEnabled = AppDelegate.shared?.isEnabled ?? true
        animationSpeed = BindingStore.shared.animationSpeed
        finderSidebarHideEnabled = BindingStore.shared.finderSidebarHideEnabled
        finderSidebarHideThreshold = BindingStore.shared.finderSidebarHideThreshold
        launchAtLogin = BindingStore.shared.launchAtLogin
        shortcuts = SettingsState.loadShortcuts()
    }

    private static func loadShortcuts() -> [ShortcutBinding] {
        BindingStore.shared.definitions.map {
            ShortcutBinding(id: $0.id, label: $0.label,
                             keyCode: BindingStore.shared.keyCode(for: $0.id),
                             modifiers: BindingStore.shared.modifiers(for: $0.id))
        }
    }

    func refresh() {
        axTrusted = AXIsProcessTrusted()
        isEnabled = AppDelegate.shared?.isEnabled ?? true
        AppDelegate.shared?.syncLaunchAtLoginState()
        launchAtLogin = BindingStore.shared.launchAtLogin
    }

    func toggleEnabled() {
        AppDelegate.shared?.toggleEnabled(nil)
        isEnabled = AppDelegate.shared?.isEnabled ?? true
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        AppDelegate.shared?.setLaunchAtLogin(enabled)
        launchAtLogin = BindingStore.shared.launchAtLogin
    }

    func setAnimationSpeed(_ speed: AnimationSpeed) {
        animationSpeed = speed
        BindingStore.shared.animationSpeed = speed
    }

    func setFinderSidebarHideEnabled(_ enabled: Bool) {
        finderSidebarHideEnabled = enabled
        BindingStore.shared.finderSidebarHideEnabled = enabled
    }

    func setFinderSidebarHideThreshold(_ threshold: Int) {
        let clamped = max(1, threshold)
        finderSidebarHideThreshold = clamped
        BindingStore.shared.finderSidebarHideThreshold = clamped
    }

    func resetDefaults() {
        stopRecording(cancelled: true)
        BindingStore.shared.resetAll()
        shortcuts = SettingsState.loadShortcuts()
        onHotkeysChanged?()
    }

    // MARK: Shortcut recording

    func startRecording(id: UInt32) {
        guard recordingID != id else { return }
        stopRecording(cancelled: true)
        recordingID = id
        onStartRecording?()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard let id = recordingID else { return }

        if event.keyCode == 53 { stopRecording(cancelled: true); return }

        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if f.contains(.control) { mods |= UInt32(controlKey) }
        if f.contains(.option)  { mods |= UInt32(optionKey)  }
        if f.contains(.shift)   { mods |= UInt32(shiftKey)   }
        if f.contains(.command) { mods |= UInt32(cmdKey)     }
        guard mods != 0 else { return }

        BindingStore.shared.save(id: id, keyCode: UInt32(event.keyCode), modifiers: mods)
        if let idx = shortcuts.firstIndex(where: { $0.id == id }) {
            shortcuts[idx].keyCode = UInt32(event.keyCode)
            shortcuts[idx].modifiers = mods
        }
        stopRecording(cancelled: false)
        onHotkeysChanged?()
    }

    func stopRecording(cancelled: Bool) {
        guard recordingID != nil else { return }
        recordingID = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        onStopRecording?()
    }
}
