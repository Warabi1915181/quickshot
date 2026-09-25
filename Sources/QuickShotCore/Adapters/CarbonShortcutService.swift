import Carbon
import Foundation

/// Live `ShortcutServicing` via Carbon `RegisterEventHotKey`.
/// `binding.keyCode` is a Carbon virtual key code; `binding.modifiers` is already Carbon
/// (cmdKey=256, shiftKey=512, optionKey=2048, controlKey=4096).
/// Handler may fire on any thread — the stored `@Sendable` handler is called as-is.
final class CarbonShortcutService: ShortcutServicing, @unchecked Sendable {

    private struct Registration {
        var ref: EventHotKeyRef
        var hotKeyID: UInt32
        var handler: @Sendable () -> Void
    }

    /// 'QSHt'
    private static let signature: OSType = 0x5153_4874

    private let lock = NSLock()
    private var registrations: [String: Registration] = [:]
    private var idByHotKey: [UInt32: String] = [:]
    private var nextHotKeyID: UInt32 = 1
    private var handlerRef: EventHandlerRef?

    init() {
        installHotKeyHandler()
    }

    deinit {
        unregisterAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    func register(
        id: String,
        binding: KeyBinding,
        handler: @escaping @Sendable () -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        if let existing = registrations[id] {
            UnregisterEventHotKey(existing.ref)
            idByHotKey.removeValue(forKey: existing.hotKeyID)
            registrations.removeValue(forKey: id)
        }

        let hotKeyID = nextHotKeyID
        nextHotKeyID &+= 1

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            EventHotKeyID(signature: Self.signature, id: hotKeyID),
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            throw WorkflowError.shortcutConflict(
                "RegisterEventHotKey failed (\(status)) for key \(binding.keyCode) mods \(binding.modifiers)"
            )
        }

        registrations[id] = Registration(ref: ref, hotKeyID: hotKeyID, handler: handler)
        idByHotKey[hotKeyID] = id
    }

    func unregister(id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let registration = registrations.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(registration.ref)
        idByHotKey.removeValue(forKey: registration.hotKeyID)
    }

    func unregisterAll() {
        lock.lock()
        defer { lock.unlock() }
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
        idByHotKey.removeAll()
    }

    private func installHotKeyHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            carbonHotKeyEventHandler,
            1,
            &spec,
            userData,
            &handlerRef
        )
    }

    fileprivate func invoke(hotKeyID: UInt32) {
        lock.lock()
        let handler = idByHotKey[hotKeyID].flatMap { registrations[$0]?.handler }
        lock.unlock()
        handler?()
    }
}

/// C callback. May run on any thread.
private let carbonHotKeyEventHandler: EventHandlerUPP = { _, event, userData -> OSStatus in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let service = Unmanaged<CarbonShortcutService>.fromOpaque(userData).takeUnretainedValue()
    service.invoke(hotKeyID: hotKeyID.id)
    return noErr
}
