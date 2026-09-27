import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: SettingsState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(nsImage: makeSizerIcon(dim: 32))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sizer")
                        .font(.title2.bold())
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { state.isEnabled },
                    set: { _ in state.toggleEnabled() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            .padding()

            if !state.axTrusted {
                HStack {
                    Label("Accessibility not granted — remove and re-add Sizer in Settings",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Settings") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            TabView {
                GeneralSettingsTab(state: state)
                    .tabItem { Label("General", systemImage: "gearshape") }

                ShortcutsSettingsTab(state: state)
                    .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            }
            .padding()
        }
        .frame(minWidth: 460, minHeight: 560)
    }
}

private struct GeneralSettingsTab: View {
    @ObservedObject var state: SettingsState

    var body: some View {
        Form {
            Toggle("Launch at Login", isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))
            .disabled(!isMacOS13OrLater)

            if !isMacOS13OrLater {
                Text("Requires macOS 13 or later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Animation") {
                Picker("Animation", selection: Binding(
                    get: { state.animationSpeed },
                    set: { state.setAnimationSpeed($0) }
                )) {
                    Text("Off").tag(AnimationSpeed.off)
                    Text("Faster").tag(AnimationSpeed.faster)
                    Text("Fast").tag(AnimationSpeed.fast)
                    Text("Slow").tag(AnimationSpeed.slow)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 120)
            }

            Group {
                Toggle("Hide Finder sidebar when arranging", isOn: Binding(
                    get: { state.finderSidebarHideEnabled },
                    set: { state.setFinderSidebarHideEnabled($0) }
                ))

                LabeledContent("Threshold") {
                    Stepper("\(state.finderSidebarHideThreshold) windows",
                            value: Binding(
                                get: { state.finderSidebarHideThreshold },
                                set: { state.setFinderSidebarHideThreshold($0) }
                            ), in: 1...20)
                }
                .disabled(!state.finderSidebarHideEnabled)
            }

            HStack {
                Spacer()
                Button("Reset Defaults") { state.resetDefaults() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutsSettingsTab: View {
    @ObservedObject var state: SettingsState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(state.shortcuts) { binding in
                HStack {
                    Text(binding.label)
                    Spacer()
                    ShortcutRecorderButton(binding: binding, state: state)
                }
            }
            .listStyle(.inset)

            Text("Click a shortcut to record a new one. Press ⎋ to cancel.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ShortcutRecorderButton: View {
    let binding: SettingsState.ShortcutBinding
    @ObservedObject var state: SettingsState

    var body: some View {
        Button {
            state.startRecording(id: binding.id)
        } label: {
            if state.recordingID == binding.id {
                Text("Type shortcut…")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12, weight: .light))
            } else {
                Text(formatShortcut(keyCode: binding.keyCode, modifiers: binding.modifiers))
                    .font(.system(size: 12, design: .monospaced))
                    .kerning(2.5)
            }
        }
        .buttonStyle(.bordered)
        .frame(minWidth: 90)
    }
}

private var isMacOS13OrLater: Bool {
    if #available(macOS 13.0, *) { return true }
    return false
}
