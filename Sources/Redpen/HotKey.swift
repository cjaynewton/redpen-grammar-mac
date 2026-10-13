import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut (Control-Option-R) that works whichever app is in front. Carbon's hot keys need no
/// extra permission and never see other keystrokes.
@MainActor
final class HotKey {
    nonisolated(unsafe) private static var action: (() -> Void)?
    private var ref: EventHotKeyRef?

    init(keyCode: Int = kVK_ANSI_R, modifiers: Int = controlKey | optionKey, action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5244_504E), id: 1)  // "RDPN"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
        Log.note(status == noErr ? "shortcut Control-Option-R ready" : "shortcut Control-Option-R failed (\(status)), another app may own it")
    }
}
