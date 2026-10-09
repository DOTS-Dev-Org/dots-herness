// Copyright (c) 2026 DOTS
// Retain provider-listed models across launches without reading credentials.

import Foundation

private struct ModelCatalogCache: Codable {
    struct Account: Codable, Equatable {
        let id: String
        let provider: String
        let baseURL: String
        let api: String
        let model: String
        let contextWindow: Int?
    }

    let version: Int
    let accounts: [Account]
    let models: [RouterModel]
}

extension RouterController {
    /// Account identity and endpoint configuration scope the cache. Credentials,
    /// email addresses and other account profile data are never copied into it.
    private var modelCatalogAccounts: [ModelCatalogCache.Account] {
        store.state.accounts.filter(\.active).sorted { $0.id < $1.id }.map {
            ModelCatalogCache.Account(
                id: $0.id, provider: $0.provider, baseURL: $0.baseURL,
                api: $0.api, model: $0.model, contextWindow: $0.contextWindow
            )
        }
    }

    func cachedModelCatalog() -> [RouterModel]? {
        guard let data = try? Data(contentsOf: modelCatalogCacheURL),
              let cache = try? JSONDecoder().decode(ModelCatalogCache.self, from: data),
              cache.version == 1,
              cache.accounts == modelCatalogAccounts else { return nil }
        let restored = activeCatalogModels(cache.models)
        return restored.isEmpty ? nil : restored
    }

    /// A live refresh replaces this snapshot, so a retired model is also removed
    /// from the next launch's catalog. Choosing a listed model saves it immediately.
    func persistModelCatalog() {
        let listed = activeCatalogModels(models)
        let cache = ModelCatalogCache(version: 1, accounts: modelCatalogAccounts, models: listed)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: modelCatalogCacheURL, options: .atomic)
    }

    private func activeCatalogModels(_ catalog: [RouterModel]) -> [RouterModel] {
        let providers = Set(store.state.accounts.filter(\.active).map(\.provider))
        return catalog.compactMap { model in
            guard !model.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  model.id != ModelRouter.autoModelID,
                  providers.contains(model.provider) else { return nil }
            var normalized = model
            if let documented = RouterCatalog.documentedContextWindow(for: model.id, provider: model.provider) {
                normalized.contextWindow = documented
            }
            return normalized
        }
    }
}
