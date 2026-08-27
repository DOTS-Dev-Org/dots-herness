// Copyright (c) 2026 DOTS
// Compact usage surface opened from the account menu.

import SwiftUI
import DotsHarnessCore

struct UsageSummaryView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 34, height: 34)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(AppCopy.text("usage.title"))
                        .font(.title3.weight(.semibold))
                    Text(AppCopy.text("usage.accountSummary"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(AppCopy.text("usage.period"))
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(AppCopy.text("usage.remaining"))
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                }

                ProgressView(value: 0.7)
                    .tint(.orange)

                HStack {
                    Text(AppCopy.text("usage.used"))
                    Spacer()
                    Text(AppCopy.text("usage.refreshing"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(AppCopy.text("usage.description"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(AppCopy.text("common.done")) {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 390)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
