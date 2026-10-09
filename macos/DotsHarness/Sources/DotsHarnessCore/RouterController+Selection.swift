// Copyright (c) 2026 DOTS
// Catalog-validated model selection and the single model label every surface uses.

import Foundation

extension RouterController {
    /// The catalog entry behind `id`, or nil when no catalog lists it. Everything
    /// that displays or routes a model resolves through here first.
    public func catalogModel(forID id: String) -> RouterModel? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ModelRouter.autoModelID else { return nil }
        return models.first { $0.id == trimmed }
    }

    /// The only model label a view may render. A name the provider publishes is
    /// shown exactly as published; an id no catalog describes yet is still read out
    /// in full, because shortening it invents a model the user cannot pick.
    public func modelLabel(forID id: String) -> String {
        if let item = catalogModel(forID: id) { return RouterCatalog.modelDisplayName(for: item) }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ModelRouter.autoModelID else {
            return AppCopy.text("modelPicker.selectModel")
        }
        return RouterCatalog.modelDisplayName(for: RouterModel(id: trimmed))
    }

    /// Adopt `id` as the selection when a catalog knows it. An unknown id keeps
    /// automatic routing in charge and is only remembered, so a retired or mistyped
    /// model can never be sent to a provider or shown as if it existed.
    /// Returns the id that is selected now.
    @discardableResult
    public func select(modelID: String) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != ModelRouter.autoModelID else {
            pendingModelID = nil
            selectedModelID = trimmed
            return trimmed
        }
        guard trimmed.isEmpty || catalogModel(forID: trimmed) != nil else {
            pendingModelID = trimmed
            selectedModelID = ModelRouter.autoModelID
            return selectedModelID
        }
        pendingModelID = nil
        selectedModelID = trimmed
        return trimmed
    }

    /// Sanitizes a model id that came from stored or generated data (a scheduled
    /// task, an assistant-authored patch, a restored pin) down to one a catalog
    /// knows. Empty means automatic routing decides, so a retired or invented
    /// model can never be chosen on the user's behalf.
    public func usableModelID(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalogModel(forID: trimmed) == nil ? "" : trimmed
    }

    /// Re-checks the selection against a catalog that just changed: restores a
    /// remembered id that has now appeared, and releases one that disappeared.
    func reconcileSelection() {
        if let pending = pendingModelID, catalogModel(forID: pending) != nil {
            pendingModelID = nil
            selectedModelID = pending
            return
        }
        let current = selectedModelID
        guard !current.isEmpty, current != ModelRouter.autoModelID, catalogModel(forID: current) == nil else { return }
        // A listing that dropped the model means it was retired. Stay usable on
        // automatic routing and retry the id if the provider brings it back.
        pendingModelID = current
        selectedModelID = ModelRouter.autoModelID
    }
}
