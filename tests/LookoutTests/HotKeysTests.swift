import Carbon.HIToolbox
import XCTest
@testable import Lookout

/// A fake `HotKeyRegistering`: remembers what was asked and can be told which ids to refuse —
/// SPEC §17.2's "in use by another app" without ever touching a real system-wide shortcut.
final class FakeHotKeyRegistrar: HotKeyRegistering {
    var onPress: ((UInt32) -> Void)?
    /// ids that should fail to register, simulating another app already holding that key.
    var refusedIDs: Set<UInt32> = []
    private(set) var registered: [UInt32: (keyCode: UInt32, modifiers: UInt32)] = [:]
    private(set) var unregisteredIDs: [UInt32] = []

    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> Bool {
        guard !refusedIDs.contains(id) else { return false }
        registered[id] = (keyCode, modifiers)
        return true
    }

    func unregister(id: UInt32) {
        registered.removeValue(forKey: id)
        unregisteredIDs.append(id)
    }
}

/// SPEC §17.2: the binding model's encode/decode, the default combos, and `HotKeyCenter`'s
/// conflict state — all driven through the fake registrar above.
final class HotKeysTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "io.github.lukenorgaard.beacon.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Defaults (SPEC §17.2: ⌃⌥L / ⌃⌥J / ⌃⌥R / ⌃⌥A / ⌃⌥D)

    func testDefaultBindingsMatchTheSpec() {
        XCTAssertEqual(HotKeyAction.togglePanel.defaultBinding.label, "⌃⌥L")
        XCTAssertEqual(HotKeyAction.jumpLongestWaiting.defaultBinding.label, "⌃⌥J")
        XCTAssertEqual(HotKeyAction.focusReply.defaultBinding.label, "⌃⌥R")
        XCTAssertEqual(HotKeyAction.allow.defaultBinding.label, "⌃⌥A")
        XCTAssertEqual(HotKeyAction.deny.defaultBinding.label, "⌃⌥D")
    }

    func testEveryActionHasItsOwnCarbonID() {
        let ids = Set(HotKeyAction.allCases.map(\.carbonID))
        XCTAssertEqual(ids.count, HotKeyAction.allCases.count, "every action registers separately")
    }

    // MARK: - Binding encode/decode

    func testABindingRoundTripsThroughJSON() throws {
        let binding = HotKeyBinding(keyCode: UInt32(kVK_ANSI_J), modifiers: HotKeyBinding.defaultModifiers)
        let data = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(HotKeyBinding.self, from: data)
        XCTAssertEqual(decoded, binding)
        XCTAssertEqual(decoded.label, "⌃⌥J")
    }

    func testTheLabelCombinesEveryModifierInOrder() {
        let all = HotKeyBinding(
            keyCode: UInt32(kVK_ANSI_L),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
        )
        XCTAssertEqual(all.label, "⌃⌥⇧⌘L")
    }

    func testHotKeyStorageLoadsAndPersistsTheOverrideDictionary() {
        let bindings: [String: HotKeyBinding] = [
            HotKeyAction.togglePanel.rawValue: HotKeyBinding(
                keyCode: UInt32(kVK_ANSI_K), modifiers: HotKeyBinding.defaultModifiers
            ),
        ]
        HotKeyStorage.persist(bindings, in: defaults, key: "hotKeyBindings")
        let loaded = HotKeyStorage.load(defaults, key: "hotKeyBindings")
        XCTAssertEqual(loaded, bindings)
    }

    func testHotKeyStorageIsEmptyWhenNothingWasStored() {
        XCTAssertTrue(HotKeyStorage.load(defaults, key: "hotKeyBindings").isEmpty)
    }

    // MARK: - `Settings.hotKey(for:)` (SPEC §17.2)

    func testSettingsFallsBackToTheDefaultUntilOverridden() {
        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.hotKey(for: .allow), HotKeyAction.allow.defaultBinding)

        let custom = HotKeyBinding(keyCode: UInt32(kVK_ANSI_Z), modifiers: HotKeyBinding.defaultModifiers)
        settings.setHotKey(custom, for: .allow)
        XCTAssertEqual(settings.hotKey(for: .allow), custom)
        XCTAssertEqual(Settings(defaults: defaults).hotKey(for: .allow), custom)
        // Every other action is untouched.
        XCTAssertEqual(settings.hotKey(for: .deny), HotKeyAction.deny.defaultBinding)
    }

    // MARK: - `HotKeyCenter`: registration and conflicts (SPEC §17.2)

    func testStartRegistersEveryActionsCurrentBinding() {
        let settings = Settings(defaults: defaults)
        let registrar = FakeHotKeyRegistrar()
        let center = HotKeyCenter(settings: settings, registrar: registrar)

        center.start()

        XCTAssertEqual(registrar.registered.count, HotKeyAction.allCases.count)
        XCTAssertTrue(center.conflicts.isEmpty)
        let toggle = registrar.registered[HotKeyAction.togglePanel.carbonID]
        XCTAssertEqual(toggle?.keyCode, UInt32(kVK_ANSI_L))
    }

    /// SPEC §17.2: a combination Carbon refuses shows up in `conflicts` — "in use by another
    /// app" — without touching any binding that registered fine.
    func testAConflictingBindingIsReportedAndOthersAreNot() {
        let settings = Settings(defaults: defaults)
        let registrar = FakeHotKeyRegistrar()
        registrar.refusedIDs = [HotKeyAction.togglePanel.carbonID]
        let center = HotKeyCenter(settings: settings, registrar: registrar)

        center.start()

        XCTAssertEqual(center.conflicts, [.togglePanel])
        XCTAssertFalse(center.conflicts.contains(.jumpLongestWaiting))
    }

    func testRebindPersistsAndReRegisters() {
        let settings = Settings(defaults: defaults)
        let registrar = FakeHotKeyRegistrar()
        let center = HotKeyCenter(settings: settings, registrar: registrar)
        center.start()

        let newBinding = HotKeyBinding(keyCode: UInt32(kVK_ANSI_K), modifiers: HotKeyBinding.defaultModifiers)
        let ok = center.rebind(.togglePanel, to: newBinding)

        XCTAssertTrue(ok)
        XCTAssertEqual(settings.hotKey(for: .togglePanel), newBinding)
        XCTAssertEqual(registrar.registered[HotKeyAction.togglePanel.carbonID]?.keyCode, UInt32(kVK_ANSI_K))
    }

    /// Rebinding to a combination Carbon refuses still saves the choice (so the recorder shows
    /// what was typed) but marks it a conflict.
    func testRebindingToARefusedComboIsSavedButFlaggedAConflict() {
        let settings = Settings(defaults: defaults)
        let registrar = FakeHotKeyRegistrar()
        let center = HotKeyCenter(settings: settings, registrar: registrar)
        center.start()

        registrar.refusedIDs = [HotKeyAction.deny.carbonID]
        let attempted = HotKeyBinding(keyCode: UInt32(kVK_ANSI_Q), modifiers: HotKeyBinding.defaultModifiers)
        let ok = center.rebind(.deny, to: attempted)

        XCTAssertFalse(ok)
        XCTAssertEqual(settings.hotKey(for: .deny), attempted, "the typed combo is still remembered")
        XCTAssertTrue(center.conflicts.contains(.deny))
    }

    /// SPEC §17.2's Clear button: rebinding to the action's own default.
    func testClearingRebindsToTheDefault() {
        let settings = Settings(defaults: defaults)
        let registrar = FakeHotKeyRegistrar()
        let center = HotKeyCenter(settings: settings, registrar: registrar)
        center.start()

        let custom = HotKeyBinding(keyCode: UInt32(kVK_ANSI_K), modifiers: HotKeyBinding.defaultModifiers)
        center.rebind(.togglePanel, to: custom)
        XCTAssertEqual(settings.hotKey(for: .togglePanel), custom)

        center.rebind(.togglePanel, to: HotKeyAction.togglePanel.defaultBinding)
        XCTAssertEqual(settings.hotKey(for: .togglePanel), HotKeyAction.togglePanel.defaultBinding)
    }

    // MARK: - Dispatch (SPEC §17.2's five actions)

    func testAPressRoutesToPerformOnTheMainQueue() {
        let settings = Settings(defaults: defaults)
        let registrar = FakeHotKeyRegistrar()
        let center = HotKeyCenter(settings: settings, registrar: registrar)
        center.start()

        let expectation = expectation(description: "performed")
        var performed: HotKeyAction?
        center.perform = { action in
            performed = action
            expectation.fulfill()
        }

        registrar.onPress?(HotKeyAction.jumpLongestWaiting.carbonID)
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(performed, .jumpLongestWaiting)
    }

    func testAPressForAnUnknownIDIsIgnored() {
        let settings = Settings(defaults: defaults)
        let registrar = FakeHotKeyRegistrar()
        let center = HotKeyCenter(settings: settings, registrar: registrar)
        center.start()
        center.perform = { _ in XCTFail("no action has this id") }
        registrar.onPress?(999)
        // Give the main-queue dispatch a turn to prove nothing was scheduled.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    // MARK: - Clear vs. Reset (SPEC §17.2)

    /// Clear means *no* shortcut — a third state a missing dictionary entry cannot represent on
    /// its own, since that already means "use the default".
    func testClearRemovesTheShortcutEntirely() {
        let settings = Settings(defaults: defaults)
        let registrar = FakeHotKeyRegistrar()
        let center = HotKeyCenter(settings: settings, registrar: registrar)
        center.start()
        XCTAssertNotNil(registrar.registered[HotKeyAction.togglePanel.carbonID])

        center.clear(.togglePanel)

        XCTAssertNil(settings.hotKey(for: .togglePanel), "Clear means no shortcut, not the default")
        XCTAssertNil(
            registrar.registered[HotKeyAction.togglePanel.carbonID],
            "the binding is unregistered from Carbon, not merely re-pointed at the default"
        )
        XCTAssertTrue(
            registrar.unregisteredIDs.contains(HotKeyAction.togglePanel.carbonID)
        )
        XCTAssertFalse(
            center.conflicts.contains(.togglePanel), "no binding cannot itself be a conflict"
        )
    }

    /// Reset restores the action's own default, distinct from Clear.
    func testResetRestoresTheDefaultAfterAClear() {
        let settings = Settings(defaults: defaults)
        let registrar = FakeHotKeyRegistrar()
        let center = HotKeyCenter(settings: settings, registrar: registrar)
        center.start()

        center.clear(.jumpLongestWaiting)
        XCTAssertNil(settings.hotKey(for: .jumpLongestWaiting))

        let ok = center.reset(.jumpLongestWaiting)
        XCTAssertTrue(ok)
        XCTAssertEqual(settings.hotKey(for: .jumpLongestWaiting), HotKeyAction.jumpLongestWaiting.defaultBinding)
        XCTAssertEqual(
            registrar.registered[HotKeyAction.jumpLongestWaiting.carbonID]?.keyCode,
            HotKeyAction.jumpLongestWaiting.defaultBinding.keyCode
        )
    }

    /// Reset also clears a *custom* binding back to the default, not only a cleared one.
    func testResetAlsoOverridesACustomBinding() {
        let settings = Settings(defaults: defaults)
        let registrar = FakeHotKeyRegistrar()
        let center = HotKeyCenter(settings: settings, registrar: registrar)
        center.start()

        let custom = HotKeyBinding(keyCode: UInt32(kVK_ANSI_K), modifiers: HotKeyBinding.defaultModifiers)
        center.rebind(.allow, to: custom)
        XCTAssertEqual(settings.hotKey(for: .allow), custom)

        center.reset(.allow)
        XCTAssertEqual(settings.hotKey(for: .allow), HotKeyAction.allow.defaultBinding)
    }

    /// Rebinding after a Clear un-clears it — recording a new combo always wins.
    func testRebindingAfterAClearUnClearsIt() {
        let settings = Settings(defaults: defaults)
        settings.clearHotKey(for: .deny)
        XCTAssertNil(settings.hotKey(for: .deny))

        let custom = HotKeyBinding(keyCode: UInt32(kVK_ANSI_Z), modifiers: HotKeyBinding.defaultModifiers)
        settings.setHotKey(custom, for: .deny)
        XCTAssertEqual(settings.hotKey(for: .deny), custom)
    }

    /// The cleared state persists exactly like every other Settings value.
    func testClearedStatePersistsAcrossSettingsInstances() {
        let settings = Settings(defaults: defaults)
        settings.clearHotKey(for: .focusReply)
        XCTAssertNil(settings.hotKey(for: .focusReply))

        let reopened = Settings(defaults: defaults)
        XCTAssertNil(reopened.hotKey(for: .focusReply), "Clear survives a relaunch")
        // Every other action is untouched by the persisted clear.
        XCTAssertEqual(reopened.hotKey(for: .allow), HotKeyAction.allow.defaultBinding)
    }

    /// `start()` skips registering a cleared action at all.
    func testStartNeverRegistersAClearedAction() {
        let settings = Settings(defaults: defaults)
        settings.clearHotKey(for: .deny)
        let registrar = FakeHotKeyRegistrar()
        let center = HotKeyCenter(settings: settings, registrar: registrar)

        center.start()

        XCTAssertNil(registrar.registered[HotKeyAction.deny.carbonID])
        XCTAssertEqual(registrar.registered.count, HotKeyAction.allCases.count - 1)
    }

    // MARK: - `HotKeyBinding.from(event:)` (SPEC §17.2's recorder)

    func testFromEventRejectsAComboWithNoModifier() {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "l", charactersIgnoringModifiers: "l",
            isARepeat: false, keyCode: UInt16(kVK_ANSI_L)
        )
        XCTAssertNil(event.flatMap(HotKeyBinding.from(event:)), "a bare letter is not a global shortcut")
    }

    func testFromEventBuildsTheBindingFromCocoaModifierFlags() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control, .option],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "l", charactersIgnoringModifiers: "l",
            isARepeat: false, keyCode: UInt16(kVK_ANSI_L)
        ))
        let binding = try XCTUnwrap(HotKeyBinding.from(event: event))
        XCTAssertEqual(binding.keyCode, UInt32(kVK_ANSI_L))
        XCTAssertEqual(binding.modifiers, HotKeyBinding.defaultModifiers)
        XCTAssertEqual(binding.label, "⌃⌥L")
    }
}
