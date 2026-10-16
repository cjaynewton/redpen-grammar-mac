import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts that work whichever app is in front: Control-Option-R opens the fix card at the cursor,
/// Control-Option-Shift-R fixes every sure mistake in the paragraph. Carbon's hot keys need no extra permission
/// and never see other keystrokes.
@MainActor
final class HotKey {
    nonisolated(unsafe) private static var actions: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var installed = false
    private var ref: EventHotKeyRef?

    init(id: UInt32 = 1, keyCode: Int = kVK_ANSI_R, modifiers: Int = controlKey | optionKey, name: String = "Control-Option-R",
         action: @escaping () -> Void) {
        HotKey.actions[id] = action
        if !HotKey.installed {
            HotKey.installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            // The dispatcher target sees hot keys whichever app is in front; the application target can miss them.
            InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                DispatchQueue.main.async { HotKey.actions[id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let hid = EventHotKeyID(signature: OSType(0x5244_504E), id: id)  // "RDPN"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hid, GetEventDispatcherTarget(), 0, &ref)
        Log.note(status == noErr ? "shortcut \(name) ready" : "shortcut \(name) failed (\(status)), another app may own it")
    }
}
