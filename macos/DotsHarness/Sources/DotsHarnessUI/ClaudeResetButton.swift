// Copyright (c) 2026 DOTS

import SwiftUI
import DotsHarnessCore

/// Account-specific handoff to Claude's supported reset redemption flow.
struct ClaudeResetButton: View {
    let connection: RouterConnection
    let resetsAvailable: Int?
    @ObservedObject var router: RouterController
    @State private var showsConfirmation = false
    @State private var showsOpenFailure = false

    var body: some View {
        HStack(spacing: 8) {
            if let count = resetsAvailable {
                Text(AppCopy.format("usage.resetsAvailable", count))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(AppCopy.text(resetsAvailable == nil ? "usage.manageResets" : "usage.useReset")) {
                showsConfirmation = true
            }
            .font(.caption)
            .disabled(resetsAvailable.map { $0 <= 0 } ?? false)
        }
        .alert(AppCopy.text("usage.resetTitle"), isPresented: $showsConfirmation) {
            Button(AppCopy.text("common.cancel"), role: .cancel) {}
            Button(AppCopy.text("usage.openClaude")) {
                showsOpenFailure = !router.openClaudeResetPage(accountID: connection.id)
            }
        } message: {
            Text(AppCopy.format("usage.resetConfirmation", connection.email ?? connection.name))
        }
        .alert(AppCopy.text("usage.resetOpenFailed"), isPresented: $showsOpenFailure) {
            Button(AppCopy.text("common.done"), role: .cancel) {}
        }
    }
}
