import AppKit
import Carbon.HIToolbox

/// Registers system-wide hotkeys via Carbon's RegisterEventHotKey. Carbon is
/// used (rather than an NSEvent global monitor) because it delivers reliable
/// global shortcuts without requiring Accessibility permission and lets us
/// swallow the key event.
final class HotKeyManager {

    /// Weak back-reference so the C event callback can route to the instance.
    static weak var shared: HotKeyManager?

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    private let signature: OSType = 0x534E4150 // 'SNAP'

    init() {
        HotKeyManager.shared = self
        installEventHandler()
    }

    /// Registers a global hotkey for an action id (must be unique). Modifiers are
    /// Carbon flags (cmdKey/shiftKey/optionKey/controlKey), default ⌘⇧.
    func register(id: UInt32,
                  keyCode: UInt32,
                  carbonModifiers: UInt32 = UInt32(cmdKey | shiftKey),
                  handler: @escaping () -> Void) {
        handlers[id] = handler

        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode,
                                         carbonModifiers,
                                         hotKeyID,
                                         GetEventDispatcherTarget(),
                                         0,
                                         &ref)
        if status == noErr, let ref {
            refs.append(ref)
        } else {
            NSLog("SnapFlow: failed to register hotkey id \(id) (status \(status))")
        }
    }

    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
    }

    fileprivate func handle(id: UInt32) {
        guard let handler = handlers[id] else { return }
        // Carbon dispatches on the main run loop; hop explicitly to be safe.
        DispatchQueue.main.async(execute: handler)
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(),
                            hotKeyEventCallback,
                            1,
                            &eventType,
                            nil,
                            &eventHandler)
    }
}

/// C callback: extracts the EventHotKeyID and forwards to the shared manager.
private func hotKeyEventCallback(_ handlerCall: EventHandlerCallRef?,
                                 _ event: EventRef?,
                                 _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    if status == noErr {
        HotKeyManager.shared?.handle(id: hotKeyID.id)
    }
    return noErr
}
