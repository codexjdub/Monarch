import AppKit
import Carbon.HIToolbox

// Default: ⌥⌘Space (Option-Command-Space)
let kHotkeyKeyCodeKey   = "hotkeyKeyCode"
let kHotkeyModifiersKey = "hotkeyModifiers"      // Carbon modifier mask
let kHotkeyDisplayKey   = "hotkeyDisplay"        // human-readable string
let kHotkeyEnabledKey   = "hotkeyEnabled"

let defaultHotkeyKeyCode: UInt32 = UInt32(kVK_Space)
let defaultHotkeyModifiers: UInt32 = UInt32(cmdKey | optionKey)
let defaultHotkeyDisplay = "⌥⌘Space"

@MainActor
final class HotkeyManager {

    static let shared = HotkeyManager()

    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let signature: OSType = 0x464D4B59 // 'FMKY'

    private init() {}

    // MARK: - Public

    func installFromDefaults() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: kHotkeyEnabledKey) as? Bool ?? true
        guard enabled else { unregister(); return }

        let keyCode = UInt32(defaults.object(forKey: kHotkeyKeyCodeKey) as? Int ?? Int(defaultHotkeyKeyCode))
        let modifiers = UInt32(defaults.object(forKey: kHotkeyModifiersKey) as? Int ?? Int(defaultHotkeyModifiers))
        register(keyCode: keyCode, modifiers: modifiers)
    }

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()

        // Install event handler (once per registration)
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: OSType(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { (_, eventRef, userData) -> OSStatus in
            guard let userData, let eventRef else { return noErr }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(eventRef,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &hkID)
            if err == noErr {
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { mgr.onTrigger?() }
            }
            return noErr
        }, 1, &eventType, selfPtr, &eventHandlerRef)

        guard status == noErr else {
            NSLog("FolderMenu: failed to install hotkey handler (\(status))")
            return
        }

        var hkID = EventHotKeyID(signature: signature, id: 1)
        let regStatus = RegisterEventHotKey(keyCode, modifiers, hkID,
                                            GetApplicationEventTarget(), 0, &hotKeyRef)
        if regStatus != noErr {
            NSLog("FolderMenu: failed to register hotkey (\(regStatus))")
        }
        _ = hkID  // silence unused
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    // MARK: - Helpers

    /// Convert an NSEvent's modifierFlags to Carbon modifier mask.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command)  { m |= UInt32(cmdKey) }
        if flags.contains(.option)   { m |= UInt32(optionKey) }
        if flags.contains(.shift)    { m |= UInt32(shiftKey) }
        if flags.contains(.control)  { m |= UInt32(controlKey) }
        return m
    }

    /// Build a display string like "⌥⌘F" from an NSEvent.
    static func displayString(for event: NSEvent) -> String {
        var s = ""
        let f = event.modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option)  { s += "⌥" }
        if f.contains(.shift)   { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        s += keyString(forKeyCode: UInt32(event.keyCode),
                       fallback: event.charactersIgnoringModifiers?.uppercased() ?? "")
        return s
    }

    /// Map common non-printable keys; fallback to the supplied character string.
    static func keyString(forKeyCode code: UInt32, fallback: String) -> String {
        switch Int(code) {
        case kVK_Return:        return "↩"
        case kVK_Tab:            return "⇥"
        case kVK_Space:          return "Space"
        case kVK_Delete:         return "⌫"
        case kVK_Escape:         return "⎋"
        case kVK_LeftArrow:      return "←"
        case kVK_RightArrow:     return "→"
        case kVK_UpArrow:        return "↑"
        case kVK_DownArrow:      return "↓"
        case kVK_F1:  return "F1";  case kVK_F2:  return "F2"
        case kVK_F3:  return "F3";  case kVK_F4:  return "F4"
        case kVK_F5:  return "F5";  case kVK_F6:  return "F6"
        case kVK_F7:  return "F7";  case kVK_F8:  return "F8"
        case kVK_F9:  return "F9";  case kVK_F10: return "F10"
        case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default: return fallback.isEmpty ? "?" : fallback
        }
    }
}
