import CoreGraphics
import SwiftUI

/// How every SwiftUI view in Lookout gets its measurements. The default is the shipped
/// appearance, so a view rendered on its own (a test, a preview) still lays out.
private struct MetricsEnvironmentKey: EnvironmentKey {
    static let defaultValue = Theme.Metrics.standard
}

extension EnvironmentValues {
    var metrics: Theme.Metrics {
        get { self[MetricsEnvironmentKey.self] }
        set { self[MetricsEnvironmentKey.self] = newValue }
    }
}
