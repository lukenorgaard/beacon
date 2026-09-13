import Foundation
import os

struct OllamaModel: Equatable {
    var name: String
    /// `4.0B`, `7B`, `70b` — whatever `/api/tags` reported, if anything.
    var parameterSize: String?

    /// Parameters in billions, for "the smallest qwen3.5" (SPEC §11.2). Reads the declared size
    /// first and falls back to the `:4b` in the tag.
    var billions: Double? {
        OllamaModel.billions(parameterSize) ?? OllamaModel.billions(sizeTag)
    }

    /// `qwen3.5:4b` → `4b`.
    private var sizeTag: String? {
        guard let colon = name.lastIndex(of: ":") else { return nil }
        return String(name[name.index(after: colon)...])
    }

    static func billions(_ raw: String?) -> Double? {
        guard let raw = Session.text(raw)?.lowercased() else { return nil }
        let digits = raw.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits), value > 0 else { return nil }
        let unit = raw.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        if unit.hasPrefix("m") { return value / 1000 }
        return value
    }
}

/// A model through the configured Ollama endpoint (localhost by default). Every
/// piece of parsing is a static function, so the JSON shapes are testable without a server.
enum Ollama {
    static let defaultBaseURL = URL(string: "http://localhost:11434")!
    static let timeout: TimeInterval = 8
    /// A one-line answer, and the field it lands in is small.
    static let maxLength = 300
    /// SPEC §11.2 — the whole system prompt, verbatim.
    static let systemPrompt =
        "You are helping a developer answer a coding agent's request. "
        + "Reply with only the one-line answer the developer should send."
    /// The family §11.2 prefers when it is installed.
    static let preferredPrefix = "qwen3.5"

    // MARK: - Parsing

    static func parseTags(_ data: Data) -> [OllamaModel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]]
        else { return [] }
        return models.compactMap { entry in
            guard let name = Session.text(entry["name"] as? String)
                ?? Session.text(entry["model"] as? String)
            else { return nil }
            let details = entry["details"] as? [String: Any]
            return OllamaModel(
                name: name,
                parameterSize: Session.text(details?["parameter_size"] as? String)
            )
        }
    }

    /// `/api/chat` with `stream:false` answers `{"message":{"content":"…"}}`.
    static func parseChat(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let message = root["message"] as? [String: Any],
           let content = message["content"] as? String {
            return clean(content)
        }
        // `/api/generate` shape, in case the model picker ever points at one.
        if let response = root["response"] as? String { return clean(response) }
        return nil
    }

    /// SPEC §11.2's default: the smallest `qwen3.5*` present, else the smallest model at all.
    static func defaultModel(_ models: [OllamaModel]) -> String? {
        guard !models.isEmpty else { return nil }
        let preferred = models.filter { $0.name.lowercased().hasPrefix(preferredPrefix) }
        let pool = preferred.isEmpty ? models : preferred
        let sized = pool.compactMap { model -> (OllamaModel, Double)? in
            guard let billions = model.billions else { return nil }
            return (model, billions)
        }
        if let smallest = sized.min(by: { $0.1 == $1.1 ? $0.0.name < $1.0.name : $0.1 < $1.1 }) {
            return smallest.0.name
        }
        return pool.map(\.name).sorted().first
    }

    /// Reasoning models wrap their thinking in `<think>…</think>`; a chat model likes to quote
    /// itself. Both are noise in a one-line reply.
    static func clean(_ raw: String) -> String {
        var text = raw
        while let start = text.range(of: "<think>"),
              let end = text.range(of: "</think>", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        text = text.replacingOccurrences(of: "</think>", with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Requests

    static func tagsRequest(base: URL = defaultBaseURL) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        return request
    }

    static func chatRequest(
        model: String, context: SuggestionContext, base: URL = defaultBaseURL
    ) -> URLRequest? {
        var request = URLRequest(url: base.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": context.promptText],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = data
        return request
    }
}

/// Produces the card's suggestion: heuristic instantly, Ollama in the background with the
