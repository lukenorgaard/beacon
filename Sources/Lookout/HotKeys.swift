import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import SwiftUI

/// One global shortcut: a virtual key code plus Carbon's modifier bits (SPEC §17.2). Persisted as
/// `{keyCode, modifiers}` — never as the label, so nothing here can be corrupted by a keyboard
/// layout change or a localisation.
struct HotKeyBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// SPEC §17.2's defaults are all ⌃⌥-something.
    static let defaultModifiers = UInt32(controlKey | optionKey)

    /// `⌃⌥L` — built from the same bits Carbon defines, so the label and the registration can
    /// never drift apart.
    var label: String {
        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols + (HotKeyBinding.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    /// SPEC §17.2's recorder: a `keyDown` becomes a binding once at least one modifier is held —
    /// a bare letter is never a *global* shortcut, so it is rejected rather than recorded.
    static func from(event: NSEvent) -> HotKeyBinding? {
        var modifiers: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        guard modifiers != 0 else { return nil }
        return HotKeyBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    /// US/ANSI key names for the recorder's label. Deliberately not layout-translated: Carbon's
    /// hot-key codes are positional, and a small fixed table is far less to get wrong than a
    /// `UCKeyTranslate` round trip for a feature that only ever needs a handful of keys.
    static let keyNames: [UInt32: String] = {
        var names: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "Return", UInt32(kVK_Tab): "Tab",
            UInt32(kVK_Delete): "Delete", UInt32(kVK_Escape): "Esc",
            UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
            UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
            UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        ]
        names.reserveCapacity(names.count)
        return names
    }()
}

/// Load/persist for `Settings.hotKeyBindings` — the same shape `AnswerPresets` uses for its own
/// JSON-in-`UserDefaults` array.
enum HotKeyStorage {
    static func load(_ defaults: UserDefaults, key: String) -> [String: HotKeyBinding] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: HotKeyBinding].self, from: data)
        else { return [:] }
        return decoded
    }

    static func persist(_ bindings: [String: HotKeyBinding], in defaults: UserDefaults, key: String) {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: key)
    }
}

/// SPEC §17.2's five global shortcuts.
enum HotKeyAction: String, CaseIterable, Codable {
    case togglePanel
    case jumpLongestWaiting
    case focusReply
    case allow
    case deny

    var label: String {
        switch self {
        case .togglePanel: return "Toggle the panel"
        case .jumpLongestWaiting: return "Jump to the session that needs you"
        case .focusReply: return "Focus the card's reply field"
        case .allow: return "Allow the current permission"
        case .deny: return "Deny the current permission"
        }
    }

    /// SPEC §17.2: ⌃⌥L / ⌃⌥J / ⌃⌥R / ⌃⌥A / ⌃⌥D.
    var defaultBinding: HotKeyBinding {
        let modifiers = HotKeyBinding.defaultModifiers
        switch self {
        case .togglePanel: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_L), modifiers: modifiers)
        case .jumpLongestWaiting: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_J), modifiers: modifiers)
        case .focusReply: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_R), modifiers: modifiers)
        case .allow: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: modifiers)
        case .deny: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_D), modifiers: modifiers)
        }
    }

    /// The Carbon hot-key id each action registers under, stable across relaunches so a
    /// `kEventHotKeyPressed` callback maps straight back to an action.
    var carbonID: UInt32 {
        UInt32(1 + (HotKeyAction.allCases.firstIndex(of: self) ?? 0))
    }
}

/// Registers/unregisters one Carbon global hot key. The real implementation is the only thing
/// that ever calls into Carbon; a test gets a fake that remembers what was asked and can be told
/// to fail, which is what "in use by another app" looks like without provoking a real conflict.
protocol HotKeyRegistering: AnyObject {
    var onPress: ((UInt32) -> Void)? { get set }
    /// `true` on success; `false` when Carbon refused the combination (SPEC §17.2's conflict).
    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> Bool
    func unregister(id: UInt32)
}

/// The real thing: one Carbon event handler for the whole app (installed once), and one
/// `EventHotKeyRef` per registered action.
final class CarbonHotKeyRegistrar: HotKeyRegistering {
    var onPress: ((UInt32) -> Void)?

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    /// `'Lkot'` as an `OSType` — Carbon hot keys are namespaced by a four-char signature so two
    /// apps registering "id 1" never collide.
    private static let signature = OSType(
        (UInt32(UInt8(ascii: "L")) << 24) | (UInt32(UInt8(ascii: "k")) << 16)
            | (UInt32(UInt8(ascii: "o")) << 8) | UInt32(UInt8(ascii: "t"))
    )

    init() { installHandler() }

    deinit {
        for id in Array(refs.keys) { unregister(id: id) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    private func installHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
            registrar.onPress?(hotKeyID.id)
            return noErr
        }
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(), callback, 1, &spec, selfPointer, &handlerRef
        )
    }

    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> Bool {
        unregister(id: id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: CarbonHotKeyRegistrar.signature, id: id)
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }

    func unregister(id: UInt32) {
        guard let ref = refs.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(ref)
    }
}

/// Owns every SPEC §17.2 shortcut: reads bindings from `Settings`, registers them through
/// `HotKeyRegistering`, and reports which ones lost to another app's registration. What each
/// shortcut actually *does* is not this type's business — `perform` is wired by whoever owns the
/// panel, the card and the requests.
final class HotKeyCenter: ObservableObject {
    private let settings: Settings
    private let registrar: HotKeyRegistering

    /// Actions whose current binding could not be registered — SPEC §17.2's "in use by another
    /// app", shown next to that action's recorder field.
    @Published private(set) var conflicts: Set<HotKeyAction> = []

    var perform: (HotKeyAction) -> Void = { _ in }

    init(settings: Settings, registrar: HotKeyRegistering = CarbonHotKeyRegistrar()) {
        self.settings = settings
        self.registrar = registrar
        registrar.onPress = { [weak self] id in
            guard let self, let action = HotKeyAction.allCases.first(where: { $0.carbonID == id })
            else { return }
            let perform = self.perform
            DispatchQueue.main.async { perform(action) }
        }
    }

    /// Registers every action's current binding. Call once, after the app is up.
    func start() {
        for action in HotKeyAction.allCases {
            apply(action, binding: settings.hotKey(for: action))
        }
    }

    /// SPEC §17.2's recorder committing a new combo. Returns whether it actually registered.
    @discardableResult
    func rebind(_ action: HotKeyAction, to binding: HotKeyBinding) -> Bool {
        settings.setHotKey(binding, for: action)
        return apply(action, binding: binding)
    }

    /// SPEC §17.2's Clear: no shortcut at all — the binding is removed and unregistered, not
    /// merely reset to the default.
    func clear(_ action: HotKeyAction) {
        settings.clearHotKey(for: action)
        _ = apply(action, binding: nil)
    }

    /// SPEC §17.2's Reset: restores the action's own default and re-registers it.
    @discardableResult
    func reset(_ action: HotKeyAction) -> Bool {
        settings.resetHotKey(for: action)
        return apply(action, binding: settings.hotKey(for: action))
    }

    /// `nil` unregisters and clears any conflict flag — that is what "no shortcut" means for a
    /// Carbon registration, not a failure to register one.
    @discardableResult
    private func apply(_ action: HotKeyAction, binding: HotKeyBinding?) -> Bool {
        guard let binding else {
            registrar.unregister(id: action.carbonID)
            conflicts.remove(action)
            return true
        }
        let ok = registrar.register(keyCode: binding.keyCode, modifiers: binding.modifiers, id: action.carbonID)
        if ok {
            conflicts.remove(action)
        } else {
            conflicts.insert(action)
        }
        return ok
    }
}

// MARK: - The recorder control (SPEC §17.2)

/// Click, press a combo, the label updates. Escape cancels without changing the binding — the
/// same convention every other Lookout panel uses for its own Escape key.
struct HotKeyRecorderField: NSViewRepresentable {
    var isRecording: Bool
    var onStart: () -> Void
    var onCapture: (HotKeyBinding) -> Void
    var onCancel: () -> Void

    final class RecorderView: NSView {
        var onStart: () -> Void = {}
        var onCapture: (HotKeyBinding) -> Void = { _ in }
        var onCancel: () -> Void = {}
        var isRecording = false

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            onStart()
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else {
                super.keyDown(with: event)
                return
            }
            if Int(event.keyCode) == kVK_Escape {
                onCancel()
                return
            }
            guard let captured = HotKeyBinding.from(event: event) else {
                NSSound.beep()
                return
            }
            onCapture(captured)
        }
    }

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onStart = onStart
        view.onCapture = onCapture
        view.onCancel = onCancel
        view.isRecording = isRecording
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onStart = onStart
        view.onCapture = onCapture
        view.onCancel = onCancel
        view.isRecording = isRecording
    }
}
