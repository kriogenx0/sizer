import Foundation
import Carbon.HIToolbox

enum AnimationSpeed: Int {
    case off = 0, fast = 1, slow = 2
    var duration: TimeInterval {
        switch self {
        case .off:  return 0
        case .fast: return 0.06
        case .slow: return 0.15
        }
    }
}

struct HotkeyDef {
    let id: UInt32
    let label: String
    let snap: WindowSnap?
    let defaultKeyCode: UInt32
    let defaultModifiers: UInt32
}

final class BindingStore {
    static let shared = BindingStore()
    private init() {}

    let definitions: [HotkeyDef] = [
        HotkeyDef(id:  1, label: "Left Half",            snap: .left,         defaultKeyCode: 123, defaultModifiers: UInt32(controlKey | optionKey | cmdKey)),
        HotkeyDef(id:  2, label: "Right Half",           snap: .right,        defaultKeyCode: 124, defaultModifiers: UInt32(controlKey | optionKey | cmdKey)),
        HotkeyDef(id:  3, label: "Top Half",             snap: .top,          defaultKeyCode: 126, defaultModifiers: UInt32(controlKey | optionKey | cmdKey)),
        HotkeyDef(id:  4, label: "Bottom Half",          snap: .bottom,       defaultKeyCode: 125, defaultModifiers: UInt32(controlKey | optionKey | cmdKey)),
        HotkeyDef(id:  5, label: "Top-Left Quarter",     snap: .topLeft,      defaultKeyCode: 123, defaultModifiers: UInt32(controlKey | optionKey | shiftKey)),
        HotkeyDef(id:  6, label: "Top-Right Quarter",    snap: .topRight,     defaultKeyCode: 126, defaultModifiers: UInt32(controlKey | optionKey | shiftKey)),
        HotkeyDef(id:  7, label: "Bottom-Right Quarter", snap: .bottomRight,  defaultKeyCode: 124, defaultModifiers: UInt32(controlKey | optionKey | shiftKey)),
        HotkeyDef(id:  8, label: "Bottom-Left Quarter",  snap: .bottomLeft,   defaultKeyCode: 125, defaultModifiers: UInt32(controlKey | optionKey | shiftKey)),
        HotkeyDef(id:  9, label: "Maximize",             snap: .maximize,     defaultKeyCode:  46, defaultModifiers: UInt32(controlKey | optionKey | cmdKey)),
        HotkeyDef(id: 10, label: "Center (75%)",         snap: .center,       defaultKeyCode:   8, defaultModifiers: UInt32(controlKey | optionKey | cmdKey)),
        HotkeyDef(id: 11, label: "Center (50%)",         snap: .center50,     defaultKeyCode:   7, defaultModifiers: UInt32(controlKey | optionKey | cmdKey)),
        HotkeyDef(id: 12, label: "Auto Arrange Columns", snap: nil,           defaultKeyCode:   9, defaultModifiers: UInt32(controlKey | optionKey | cmdKey)),
        HotkeyDef(id: 13, label: "Auto Arrange 2 Rows",  snap: nil,           defaultKeyCode:   1, defaultModifiers: UInt32(controlKey | optionKey | cmdKey)),
    ]

    func keyCode(for id: UInt32) -> UInt32 {
        (UserDefaults.standard.object(forKey: "hk_\(id)_key") as? Int).map { UInt32($0) }
            ?? definitions.first { $0.id == id }?.defaultKeyCode ?? 0
    }

    func modifiers(for id: UInt32) -> UInt32 {
        (UserDefaults.standard.object(forKey: "hk_\(id)_mod") as? Int).map { UInt32($0) }
            ?? definitions.first { $0.id == id }?.defaultModifiers ?? 0
    }

    func save(id: UInt32, keyCode: UInt32, modifiers: UInt32) {
        UserDefaults.standard.set(Int(keyCode),   forKey: "hk_\(id)_key")
        UserDefaults.standard.set(Int(modifiers), forKey: "hk_\(id)_mod")
    }

    func resetAll() {
        definitions.forEach {
            UserDefaults.standard.removeObject(forKey: "hk_\($0.id)_key")
            UserDefaults.standard.removeObject(forKey: "hk_\($0.id)_mod")
        }
    }

    var animationSpeed: AnimationSpeed {
        get {
            guard let raw = UserDefaults.standard.object(forKey: "animationSpeed") as? Int else { return .fast }
            return AnimationSpeed(rawValue: raw) ?? .fast
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "animationSpeed") }
    }

    var finderSidebarHideEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "finderSidebarEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "finderSidebarEnabled") }
    }

    var finderSidebarHideThreshold: Int {
        get { UserDefaults.standard.object(forKey: "finderSidebarThreshold") as? Int ?? 5 }
        set { UserDefaults.standard.set(newValue, forKey: "finderSidebarThreshold") }
    }
}
