import AppKit
import Carbon.HIToolbox

/// Global hotkeys through Carbon, which still has the only API that works
/// without the Accessibility permission.
///
/// The bindings avoid plain `⌘↩`, because a global `⌘↩` would break confirm in
/// every other app. They all carry `⌥⌘`.
@MainActor
final class HotKeyCenter {
    struct Binding {
        let id: UInt32
        let keyCode: UInt32
        let modifiers: UInt32
        let action: () -> Void
    }

    static let shared = HotKeyCenter()

    private var bindings: [UInt32: Binding] = [:]
    private var handlers: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?
    private var nextId: UInt32 = 1

    private init() {}

    /// `⌥⌘` for every binding.
    private static let optionCommand = UInt32(optionKey | cmdKey)

    /// Registers the app's bindings. Call once at launch.
    func install(
        toggleQueue: @escaping () -> Void,
        markDone: @escaping () -> Void,
        sendBack: @escaping () -> Void
    ) {
        installEventHandler()
        register(keyCode: UInt32(kVK_ANSI_B), modifiers: Self.optionCommand, action: toggleQueue)
        register(keyCode: UInt32(kVK_Return), modifiers: Self.optionCommand, action: markDone)
        register(keyCode: UInt32(kVK_Delete), modifiers: Self.optionCommand, action: sendBack)
    }

    private func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        let id = nextId
        nextId += 1
        bindings[id] = Binding(id: id, keyCode: keyCode, modifiers: modifiers, action: action)

        var reference: EventHotKeyRef?
        let hotKeyId = EventHotKeyID(signature: OSType(0x4254_4E31), id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyId, GetEventDispatcherTarget(), 0, &reference)
        if status == noErr {
            handlers.append(reference)
        } else {
            // Another app owns the combination. Fail quietly; the menu bar and the
            // notch still work without it.
            bindings[id] = nil
        }
    }

    private func installEventHandler() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyId = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyId
                )
                guard status == noErr else { return status }
                let id = hotKeyId.id
                // The Carbon callback is a C function pointer, so it cannot
                // capture. Hop to the main actor and look the binding up.
                Task { @MainActor in
                    HotKeyCenter.shared.fire(id: id)
                }
                return noErr
            },
            1,
            &spec,
            nil,
            &eventHandler
        )
    }

    fileprivate func fire(id: UInt32) {
        bindings[id]?.action()
    }
}
