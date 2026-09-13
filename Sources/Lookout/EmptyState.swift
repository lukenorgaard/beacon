import SwiftUI

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(spacing: metrics.controlGap) {
            Image(systemName: symbol)
                .font(metrics.font(20, .light))
                .foregroundStyle(Theme.textTertiary)
            Text(title)
                .font(metrics.rowTitle)
                .foregroundStyle(Theme.textSecondary)
            Text(message)
                .font(metrics.rowSecondary)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, metrics.padding + metrics.scaled(10))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
