import AppKit
import Carbon

/// Carbon event handler. Defined at file scope (not inside a @MainActor
/// method) so it is a plain, non-isolated C function pointer.
private let suiyiHotKeyHandler: EventHandlerUPP = { (_: EventHandlerCallRef?, event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus in
    guard let event = event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let err = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    if err != 0 { return err }
    let id = hotKeyID.id
    Task { @MainActor in
        HotKeyCenter.shared.fire(id)
    }
    return 0
}

/// Global hot keys via Carbon RegisterEventHotKey (no Accessibility needed
/// for the key itself).
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    static let keyT: UInt32 = 0x11            // kVK_ANSI_T
    static let keyR: UInt32 = 0x0F            // kVK_ANSI_R
    static let keyP: UInt32 = 0x23            // kVK_ANSI_P
    static let optionCommand: UInt32 = UInt32(cmdKey | optionKey)

    private static let signature: OSType = 0x464E_5949   // 'FNYI'

    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    private init() {}

    private func installHandlerIfNeeded() -> Bool {
        if handlerRef != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), suiyiHotKeyHandler, 1, &spec, nil, &handlerRef)
        return status == 0
    }

    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32,
                  action: @escaping @MainActor () -> Void) -> Bool {
        guard installHandlerIfNeeded() else { return false }
        if let old = refs[id] {
            UnregisterEventHotKey(old)
            refs[id] = nil
        }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: HotKeyCenter.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == 0, let hotKeyRef = ref else { return false }
        refs[id] = hotKeyRef
        actions[id] = action
        return true
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }
}
