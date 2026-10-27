import AppKit
import Carbon.HIToolbox

/// Scorciatoie globali ⌃⌥↑ / ⌃⌥↓ / ⌃⌥← / ⌃⌥→ / ⌃⌥0 (Carbon RegisterEventHotKey: non servono permessi
/// di Accessibilità e funzionano qualunque app sia in primo piano).
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    enum Key: UInt32 {
        case up = 1, down = 2, left = 3, right = 4, reset = 5
        /// Solo il volume si ripete tenendo premuto, non la scelta dell'app.
        var repeats: Bool { self == .up || self == .down }
    }
    var onPress: ((Key) -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var handlerInstalled = false
    private var repeatTimer: Timer?

    func setEnabled(_ on: Bool) {
        on ? register() : unregister()
    }

    private func register() {
        guard refs.isEmpty else { return }
        if !handlerInstalled {
            var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                         EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, specs.count, &specs, nil, nil)
            handlerInstalled = true
        }
        let modifiers = UInt32(controlKey | optionKey)
        for (key, code) in [(Key.up, kVK_UpArrow), (Key.down, kVK_DownArrow),
                             (Key.left, kVK_LeftArrow), (Key.right, kVK_RightArrow), (Key.reset, kVK_ANSI_0)] {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x564D_5852), id: key.rawValue)   // 'VMXR'
            let err = RegisterEventHotKey(UInt32(code), modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if err == noErr, let ref { refs.append(ref) } else { NSLog("VolumeMixer: scorciatoia non registrata (\(err))") }
        }
    }

    private func unregister() {
        stopRepeat()
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }

    // MARK: Ripetizione tenendo premuto
    // Le scorciatoie Carbon segnalano solo pressione e rilascio: la ripetizione la facciamo noi,
    // con il ritardo e la velocità di ripetizione impostati per la tastiera del Mac.

    fileprivate func pressed(_ id: UInt32) {
        guard let key = Key(rawValue: id) else { return }
        stopRepeat()
        onPress?(key)
        guard key.repeats else { return }
        let interval = max(NSEvent.keyRepeatInterval, 0.06)
        repeatTimer = Timer.scheduledTimer(withTimeInterval: NSEvent.keyRepeatDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                    MainActor.assumeIsolated { self?.repeatTick(key) }
                }
            }
        }
    }

    fileprivate func released(_ id: UInt32) {
        stopRepeat()
    }

    private func repeatTick(_ key: Key) {
        // Se nel frattempo sono stati lasciati Control o Option, smetti.
        let flags = NSEvent.modifierFlags
        guard flags.contains(.control), flags.contains(.option) else { return stopRepeat() }
        onPress?(key)
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}

private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ user: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKey = EventHotKeyID()
    let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
    guard err == noErr else { return err }
    let id = hotKey.id
    let isPress = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    DispatchQueue.main.async {
        MainActor.assumeIsolated { isPress ? HotKeys.shared.pressed(id) : HotKeys.shared.released(id) }
    }
    return noErr
}
