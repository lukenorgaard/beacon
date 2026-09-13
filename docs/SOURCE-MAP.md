# Source map: 1.4 file cleanup

Existing Swift type names and tests are retained. Stored properties remain in their owning
types; related behavior moves into extensions. All paths below are relative to this folder.

## Swift app

- `Sources/Lookout/AppState.swift` → `AppState.swift`, `AppStateSessions.swift`, `AppStatePresentation.swift`, `AppStateSentinel.swift`, `AppStateHistory.swift`
- `Sources/Lookout/AttentionCardModel.swift` → `AttentionCardModel.swift`, `AttentionCardActions.swift`
- `Sources/Lookout/AttentionCardView.swift` → `AttentionCardView.swift`, `AttentionCardComponents.swift`
- `Sources/Lookout/Jumper.swift` → `WorkspaceIndex.swift`, `Jumper.swift`, `JumperDesktop.swift`, `JumperAccessibility.swift`, `JumperEditors.swift`, `JumperTerminals.swift`
- `Sources/Lookout/Metrics.swift` → `Metrics.swift`, `SentinelMetrics.swift`, `PanelMetrics.swift`, `MetricsEnvironment.swift`
- `Sources/Lookout/ProcessSnapshot.swift` → `ProcessInfoCache.swift`, `ProcessSnapshot.swift`
- `Sources/Lookout/SessionModel.swift` → `SessionTypes.swift`, `SessionModel.swift`, `SessionPresentation.swift`, `SessionMessaging.swift`, `SessionOrdering.swift`, `SessionFormatting.swift`
- `Sources/Lookout/SessionsListView.swift` → `SessionsListView.swift`, `SessionRow.swift`
- `Sources/Lookout/Settings.swift` → `SettingsModes.swift`, `Settings.swift`, `SettingsKeys.swift`, `SettingsStorage.swift`, `SeenSet.swift`
- `Sources/Lookout/SettingsView.swift` → `SettingsView.swift`, `SettingsGeneralView.swift`, `SettingsAppearanceView.swift`, `SettingsAgentsView.swift`, `SettingsCardsView.swift`, `SettingsSentinelView.swift`, `SettingsPresetsView.swift`, `SettingsClaudeView.swift`, `SettingsShortcutsView.swift`, `SettingsUsageView.swift`, `SettingsAppearanceControls.swift`, `SettingsWindowController.swift`
- `Sources/Lookout/SetupView.swift` → `SetupView.swift`, `SetupComponents.swift`, `SetupWindowController.swift`
- `Sources/Lookout/Suggester.swift` → `SuggestionContext.swift`, `Ollama.swift`, `Suggester.swift`
- `Sources/Lookout/SystemWatch/SystemRules.swift` → `SystemThresholds.swift`, `SystemRules.swift`, `SystemMemoryRules.swift`, `SystemCPURules.swift`, `SystemStorageRules.swift`

## Swift tests

- `tests/LookoutTests/AttentionCardTests.swift` → `AttentionCardTests.swift`, `AttentionCardExpiryTests.swift`, `AttentionCardActionTests.swift`, `AttentionCardCompanionTests.swift`, `AttentionCardLayoutTests.swift`
- `tests/LookoutTests/ClaudeSuggesterTests.swift` → `ClaudeSuggesterTests.swift`, `ClaudeSuggesterRunnerTests.swift`
- `tests/LookoutTests/CodexQuestionWatcherTests.swift` → `CodexQuestionWatcherTests.swift`, `CodexQuestionIntegrationTests.swift`, `CodexQuestionCardTests.swift`
- `tests/LookoutTests/EditorCompanionTests.swift` → `FakeCompanionServer.swift`, `EditorCompanionTests.swift`, `EditorCompanionEndpointTests.swift`
- `tests/LookoutTests/PanelRenderTests.swift` → `PanelRenderTests.swift`, `PanelRowRenderTests.swift`, `PanelScaleRenderTests.swift`, `PanelHistoryRenderTests.swift`, `PanelSentinelRenderTests.swift`, `PanelContextRenderTests.swift`
- `tests/LookoutTests/ProcessScannerTests.swift` → `ProcessScannerTests.swift`, `ProcessSnapshotTests.swift`, `ProcessInfoCacheTests.swift`
- `tests/LookoutTests/ReadmeScreenshotTests.swift` → `ReadmeScreenshotTests.swift`, `ReadmeTabScreenshotTests.swift`
- `tests/LookoutTests/SentinelViewTests.swift` → `SentinelViewTests.swift`, `SentinelActionViewTests.swift`, `SentinelSettingsViewTests.swift`
- `tests/LookoutTests/SessionMessengerTests.swift` → `FakeSocketServer.swift`, `SessionMessengerTests.swift`
- `tests/LookoutTests/SystemWatchRulesTests.swift` → `SystemWatchRulesTests.swift`, `SystemWatchHealthRulesTests.swift`, `SystemWatchCadenceRulesTests.swift`

## Reporter

`hooks/lookout-report.py` remains the hook command entry point. Its implementation is in
`hooks/lookout_reporter/`:

- `cli.py`: argument parsing and dispatch; `hook.py`: lifecycle orchestration.
- `manual.py`: manual reporting; `events.py`: event-to-state mapping.
- `identity.py`: process and host identity; `storage.py`: atomic state, tokens and history.
- `usage.py`: cumulative usage and Codex limits; `context.py`: current context measurement.
- `transcript.py`: titles and models; `subagents.py`: subagent tracking.
- `requests.py`: permission/question request lifecycle; `common.py`: shared utilities.

`tests/test_reporter.sh` still runs the full integration suite. Its cases now live under
`tests/reporter/`, grouped by feature. `test_failures.py` verifies parser-failure recovery.
