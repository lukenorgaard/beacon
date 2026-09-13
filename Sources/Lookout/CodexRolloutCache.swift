import Foundation

/// Queue-confined metadata for recently active rollouts. Tool output may push the model and
/// task name out of the short tail; absent fields must not erase facts already read.
final class CodexRolloutCache {
    private struct Entry {
        var file: CodexRolloutDiscovery.Rollout
        var meta: CodexRolloutDiscovery.Meta
        var look: CodexRolloutDiscovery.Look
    }

    /// Cold starts and large bursts get a bounded look further back for their current context.
    static let contextBytes = 2 * 1024 * 1024
    private var entries: [String: Entry] = [:]

    func read(
        _ file: CodexRolloutDiscovery.Rollout, io: CodexRolloutDiscovery.IO
    ) -> (CodexRolloutDiscovery.Meta, CodexRolloutDiscovery.Look)? {
        var previous = entries[file.path]
        if let entry = previous, entry.file == file { return (entry.meta, entry.look) }
        if let entry = previous,
           file.size < entry.file.size || file.modifiedAt < entry.file.modifiedAt {
            previous = nil
            entries.removeValue(forKey: file.path)
        }

        guard let head = io.head(file.path, CodexRolloutDiscovery.headBytes),
              let meta = CodexRolloutDiscovery.meta(head: head)
        else { return nil }
        if previous?.meta.id != meta.id { previous = nil }
        guard let tail = io.tail(file.path, CodexRolloutDiscovery.tailBytes) else {
            // A transient read failure should neither erase a row nor mark this stat as read.
            return previous.map { ($0.meta, $0.look) }
        }
        var look = CodexRolloutDiscovery.look(tail: tail)
        let unread = file.size - (previous?.file.size ?? 0)
        if unread > CodexRolloutDiscovery.tailBytes,
           look.model == nil || look.lastUserMessage == nil,
           let context = io.tail(file.path, Self.contextBytes) {
            look = Self.retainingMetadata(new: look, old: CodexRolloutDiscovery.look(tail: context))
        }
        if let previous { look = Self.retainingMetadata(new: look, old: previous.look) }
        entries[file.path] = Entry(file: file, meta: meta, look: look)
        return (meta, look)
    }

    func retain(paths: Set<String>) {
        entries = entries.filter { paths.contains($0.key) }
    }

    private static func retainingMetadata(
        new: CodexRolloutDiscovery.Look, old: CodexRolloutDiscovery.Look
    ) -> CodexRolloutDiscovery.Look {
        var result = new
        result.model = new.model ?? old.model
        result.lastUserMessage = new.lastUserMessage ?? old.lastUserMessage
        result.lastAgentMessage = new.lastAgentMessage ?? old.lastAgentMessage
        result.lastToolName = new.lastToolName ?? old.lastToolName
        result.usage = new.usage ?? old.usage
        // State comes from the current tail; an old completion must not override new output.
        return result
    }
}
