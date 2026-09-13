import Foundation
import os

/// heuristic still on screen until it answers (SPEC §11.4).
final class Suggester {
    private let log = Logger(subsystem: "io.github.lukenorgaard.beacon", category: "suggest")
    let session: URLSession
    let base: URL
    /// SPEC §13.2 — the subscription path, through `claude -p`.
    let claude: ClaudeCLISuggester

    /// Models `/api/tags` reported at startup, for the Settings picker.
    var models: [OllamaModel] = []
    /// Whether the last probe reached Ollama at all.
    private(set) var isReachable = false

    init(
        base: URL = Ollama.defaultBaseURL,
        session: URLSession? = nil,
        claude: ClaudeCLISuggester? = nil,
        home: LookoutHome = LookoutHome()
    ) {
        self.base = base
        self.claude = claude ?? ClaudeCLISuggester(home: home)
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Ollama.timeout
            configuration.timeoutIntervalForResource = Ollama.timeout
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    /// SPEC §11.4: at startup the app asks Ollama what it has; that answer decides both the
    /// default source and the model picker's contents.
    func probe(completion: @escaping (Bool, [OllamaModel]) -> Void) {
        let task = session.dataTask(with: Ollama.tagsRequest(base: base)) { [weak self] data, _, _ in
            let models = data.map(Ollama.parseTags) ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                self.models = models
                self.isReachable = !models.isEmpty
                completion(self.isReachable, models)
            }
        }
        task.resume()
    }

    /// What the Claude path needs from Settings, in one value so the signature stays readable.
    struct ClaudeOptions: Equatable {
        var model: String = ClaudeCLI.defaultModel
        /// The Settings override; nil means "discover it" (SPEC §13.2).
        var binaryPath: String?
        /// Nil means "read `~/.lookout/suggest-prompt.md`", which is what the app does.
        var template: String?

        init(
            model: String = ClaudeCLI.defaultModel,
            binaryPath: String? = nil,
            template: String? = nil
        ) {
            self.model = model
            self.binaryPath = binaryPath
            self.template = template
        }
    }

    /// The suggestion for one card. `.off` yields nothing, `.heuristic` answers instantly, and
    /// `.ollama` / `.claude` fall back to the heuristic on any failure — a card without a
    /// suggestion is still a card, but a card that waits forever is not.
    func suggest(
        for context: SuggestionContext,
        source: SuggestionSource,
        model: String?,
        claude options: ClaudeOptions = ClaudeOptions(),
        completion: @escaping (SuggestionOutcome) -> Void
    ) {
        switch source {
        case .off:
            completion(SuggestionOutcome.value(nil, from: .off))
        case .heuristic:
            completion(SuggestionOutcome.value(Heuristic.suggestion(for: context), from: .heuristic))
        case .ollama:
            let fallback = Heuristic.suggestion(for: context)
            guard let name = Session.text(model) ?? Ollama.defaultModel(models),
                  let request = Ollama.chatRequest(model: name, context: context, base: base)
            else {
                completion(SuggestionOutcome.value(fallback, from: .heuristic))
                return
            }
            let task = session.dataTask(with: request) { data, _, error in
                let suggestion = data.flatMap(Ollama.parseChat)
                DispatchQueue.main.async {
                    if let error, suggestion == nil {
                        completion(SuggestionOutcome.value(fallback, from: .heuristic))
                        _ = error
                        return
                    }
                    guard let text = Session.text(suggestion) else {
                        completion(SuggestionOutcome.value(fallback, from: .heuristic))
                        return
                    }
                    completion(SuggestionOutcome.value(text, from: .ollama))
                }
            }
            task.resume()
        case .claude:
            // SPEC §13.2: failure or timeout → the heuristic, and the card says so.
            let fallback = Heuristic.suggestion(for: context)
            self.claude.suggest(
                for: context,
                model: options.model,
                binaryOverride: options.binaryPath,
                template: options.template
            ) { outcome in
                guard let text = Session.text(outcome.text) else {
                    completion(
                        SuggestionOutcome(
                            text: fallback, source: .heuristic,
                            note: SuggestionOutcome.claudeFallbackNote
                        )
                    )
                    return
                }
                completion(SuggestionOutcome.value(text, from: .claude))
            }
        }
    }
}
