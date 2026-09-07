import AppKit
import Carbon.HIToolbox

/// A user-configurable global keyboard shortcut.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier mask

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + KeyNames.name(for: keyCode)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }
}

enum HotkeyAction: String, CaseIterable, Identifiable {
    case captureRegion
    case captureFullScreen
    case captureWindow
    case recordRegion
    case recordFullScreen
    case ocrRegion
    case pinRegion
    case repeatLastRegion

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .captureRegion: return "action.capture_region"
        case .captureFullScreen: return "action.capture_fullscreen"
        case .captureWindow: return "action.capture_window"
        case .recordRegion: return "action.record_region"
        case .recordFullScreen: return "action.record_fullscreen"
        case .ocrRegion: return "action.ocr_region"
        case .pinRegion: return "action.pin_region"
        case .repeatLastRegion: return "action.repeat_last"
        }
    }

    var defaultHotkey: Hotkey {
        // Defaults avoid the system's ⇧⌘3/4/5/6 shortcuts.
        switch self {
        case .captureRegion: return Hotkey(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey | shiftKey))
        case .captureFullScreen: return Hotkey(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey))
        case .captureWindow: return Hotkey(keyCode: UInt32(kVK_ANSI_7), modifiers: UInt32(cmdKey | shiftKey))
        case .recordRegion: return Hotkey(keyCode: UInt32(kVK_ANSI_8), modifiers: UInt32(cmdKey | shiftKey))
        case .recordFullScreen: return Hotkey(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(cmdKey | shiftKey))
        case .ocrRegion: return Hotkey(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .pinRegion: return Hotkey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .repeatLastRegion: return Hotkey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        }
    }
}

/// Registers Carbon global hotkeys and dispatches them to app actions.
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotkeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var actionIDs: [HotkeyAction: UInt32] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1

    /// Actions whose shortcut could not be registered (usually taken by another app).
    private(set) var failedActions: Set<HotkeyAction> = []

    var onTrigger: ((HotkeyAction) -> Void)?

    private init() {}

    func start() {
        installEventHandler()
        reloadAll()
    }

    /// Current hotkey for an action (nil means disabled by user).
    func hotkey(for action: HotkeyAction) -> Hotkey? {
        let d = UserDefaults.standard
        if d.bool(forKey: "hotkey.disabled.\(action.rawValue)") { return nil }
        if let data = d.data(forKey: "hotkey.\(action.rawValue)"),
           let hk = try? JSONDecoder().decode(Hotkey.self, from: data) {
            return hk
        }
        return action.defaultHotkey
    }

    func setHotkey(_ hotkey: Hotkey?, for action: HotkeyAction) {
        let d = UserDefaults.standard
        if let hotkey {
            d.set(try? JSONEncoder().encode(hotkey), forKey: "hotkey.\(action.rawValue)")
            d.set(false, forKey: "hotkey.disabled.\(action.rawValue)")
        } else {
            d.set(true, forKey: "hotkey.disabled.\(action.rawValue)")
        }
        reloadAll()
    }

    func resetToDefaults() {
        let d = UserDefaults.standard
        for action in HotkeyAction.allCases {
            d.removeObject(forKey: "hotkey.\(action.rawValue)")
            d.set(false, forKey: "hotkey.disabled.\(action.rawValue)")
        }
        reloadAll()
    }

    func reloadAll() {
        unregisterAll()
        failedActions.removeAll()
        for action in HotkeyAction.allCases {
            guard let hk = hotkey(for: action) else { continue }
            register(hk, for: action)
        }
    }

    // MARK: - Internals

    private func installEventHandler() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            DispatchQueue.main.async {
                HotkeyManager.shared.handlers[hkID.id]?()
            }
            return noErr
        }, 1, &eventType, nil, &eventHandlerRef)
    }

    private func register(_ hotkey: Hotkey, for action: HotkeyAction) {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x534E_4D4B) /* 'SNMK' */, id: id)
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, hkID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("SnapMark: failed to register hotkey \(hotkey.display) for \(action.rawValue) (status \(status))")
            failedActions.insert(action)
            return
        }
        hotkeyRefs[id] = ref
        actionIDs[action] = id
        handlers[id] = { [weak self] in self?.onTrigger?(action) }
    }

    private func unregisterAll() {
        for (_, ref) in hotkeyRefs { UnregisterEventHotKey(ref) }
        hotkeyRefs.removeAll()
        handlers.removeAll()
        actionIDs.removeAll()
    }
}
