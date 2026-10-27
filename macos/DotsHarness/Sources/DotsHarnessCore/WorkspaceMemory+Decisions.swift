// Copyright (c) 2026 DOTS
// The review of the project's decisions: once enough have been recorded, a light model
// merges the ones saying the same thing and names the ones a later decision replaced.
// Merges are written to `.mem/facts.md` like any other recorded decision; a stale one is
// only suggested, and the suggestion is the person's, kept in their folder for the project.
//
// Mirrors the review half of shared/ProjectDecisions.cs.

import Foundation

extension WorkspaceMemory {
    private var decisionReviewURL: URL? { ProjectDecisions.reviewURL(in: userMemoryDirectory) }

    private var projectDecisions: [MemoryTransferFact] { projectMemoryFacts().filter { $0.kind == "decision" } }

    /// What a review suggested removing and the person has not decided on yet.
    public var decisionProposals: [DecisionProposal] {
        let keys = Set(projectDecisions.map(\.key))
        return ProjectDecisions.loadReview(decisionReviewURL).proposals.filter { keys.contains($0.key) }
    }

    public func decisionProposalReason(key: String) -> String? {
        decisionProposals.first { $0.key == key }?.reason
    }

    /// The person keeps a decision a review suggested removing.
    public func keepProjectDecision(key: String) {
        var review = ProjectDecisions.loadReview(decisionReviewURL)
        let before = review.proposals.count
        review.proposals.removeAll { $0.key == key }
        if review.proposals.count != before { ProjectDecisions.saveReview(review, to: decisionReviewURL) }
    }

    /// Every decision, for a light model to review, once enough have been added since the last
    /// review. Memory that came with the repository and was never trusted is not reviewed: its
    /// rewrite would be committed as if the person had written it.
    func decisionConsolidationPayload() -> String? {
        guard enabled, projectMemoryTrusted, decisionReviewURL != nil else { return nil }
        return ProjectDecisions.consolidationPayload(projectDecisions, reviewed: ProjectDecisions.loadReview(decisionReviewURL).consolidatedCount)
    }

    /// Folds the model's reply into the decisions; see `ProjectDecisions.parseReview`. The count
    /// is noted whatever the reply says, so the model is asked again only after more have been
    /// decided. Returns whether a decision changed.
    @discardableResult
    func applyDecisionConsolidation(reply: String) -> Bool {
        let decisions = projectDecisions
        let (merges, stale) = ProjectDecisions.parseReview(reply, decisions: decisions, now: isoNow())
        var changed = false
        if !merges.isEmpty {
            changed = (try? updateProjectMemoryFacts { ProjectDecisions.applying(merges, to: $0) }) != nil
        }
        var review = ProjectDecisions.loadReview(decisionReviewURL)
        let gone = changed ? Set(merges.flatMap(\.drop)) : []
        review.proposals.removeAll { proposal in gone.contains(proposal.key) || stale.contains { $0.key == proposal.key } }
        review.proposals += stale
        review.consolidatedCount = decisions.count - (changed ? gone.count : 0)
        ProjectDecisions.saveReview(review, to: decisionReviewURL)
        return changed
    }
}
