// Copyright (c) 2026 DOTS

import AppKit
import Combine
import Foundation

extension RouterController {
    /// Call only from the user's confirmation action. Claude currently documents
    /// redemption on its Usage page, not a public OAuth reset endpoint.
    /// Opening the page does not consume a reset or prove that one was used.
    @discardableResult
    public func openClaudeResetPage(accountID: String) -> Bool {
        guard connections.contains(where: {
            $0.id == accountID && $0.active && $0.provider == "claude" && $0.authType == "oauth"
        }) else { return false }
        guard NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) else { return false }
        pendingClaudeResetAccountID = accountID
        return true
    }

    func observeClaudeResetReturn() {
        // Observe in the controller: the originating popover may close as soon
        // as the browser opens, so a view-local listener would lose the refresh.
        claudeResetReturnObserver = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.pendingClaudeResetAccountID != nil else { return }
                    self.pendingClaudeResetAccountID = nil
                    await self.refreshAccountUsage(force: true)
                    await self.refreshClaudeUsage()
                }
            }
    }
}
