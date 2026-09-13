import Foundation

/// One reusable one-line reply (SPEC §17.4). `id` is stable across reorders, which is what a
/// ⌘-binding and a SwiftUI `ForEach` both need — the array's index moves, the id never does.
struct AnswerPreset: Codable, Equatable, Identifiable {
    var id: UUID
    var text: String
    /// 1…9, or nil for no binding. SPEC §17.4's ⌘1…⌘9 — at most one preset holds a given key.
    var keyBinding: Int?

    init(id: UUID = UUID(), text: String, keyBinding: Int? = nil) {
        self.id = id
        self.text = text
        self.keyBinding = keyBinding
    }
}

/// SPEC §17.4's four defaults, in order.
enum AnswerPresetsDefaults {
    static let values: [AnswerPreset] = [
        AnswerPreset(text: "Go ahead", keyBinding: 1),
        AnswerPreset(text: "Skip it, continue with the next task", keyBinding: 2),
        AnswerPreset(text: "Commit what you have and stop", keyBinding: 3),
        AnswerPreset(text: "Ask me again in the terminal", keyBinding: 4),
    ]
}

/// Persistence and the small rules around key bindings — kept pure so both are testable without
/// `Settings` or a window.
enum AnswerPresets {
    static let maxKeyBinding = 9

    static func load(_ defaults: UserDefaults, key: String) -> [AnswerPreset] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([AnswerPreset].self, from: data)
        else { return AnswerPresetsDefaults.values }
        return decoded
    }

    static func persist(_ presets: [AnswerPreset], in defaults: UserDefaults, key: String) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: key)
    }

    /// SPEC §17.4: each key 1…9 belongs to at most one preset — giving it to one takes it away
    /// from whoever had it, so the picker never has to explain a conflict.
    static func assign(_ presets: [AnswerPreset], id: UUID, keyBinding: Int?) -> [AnswerPreset] {
        presets.map { preset in
            var copy = preset
            if copy.id == id {
                copy.keyBinding = keyBinding
            } else if keyBinding != nil, copy.keyBinding == keyBinding {
                copy.keyBinding = nil
            }
            return copy
        }
    }

    /// The preset bound to ⌘*n*, if any — what the card's `.keyboardShortcut(_:modifiers:.command)`
    /// looks up.
    static func preset(for key: Int, in presets: [AnswerPreset]) -> AnswerPreset? {
        presets.first { $0.keyBinding == key }
    }
}
