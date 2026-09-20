// Copyright (c) 2026 DOTS
// Image generation routing.

import AppKit
import CryptoKit
import Foundation
import HarnessPluginKit
import Network
import PluginRuntime

extension RouterController {
    public func generateImage(prompt: String, session: URLSession = .shared) async throws -> ProviderImageGeneration {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw ProviderImageGenerationError.unsupported(AppCopy.text("media.promptMissing")) }
        guard let primary = imagePrimaryAccount else {
            throw ProviderImageGenerationError.unsupported(AppCopy.text("media.unsupportedStatus"))
        }
        let primaryModel = imageModel(for: primary)
        let primaryRoute = imageRoute(for: primary, model: primaryModel)
        let primaryAdapter = imageAdapters.adapter(for: primaryRoute)
        let primaryAdapterID = primaryAdapter?.id ?? "none"

        if imageAdapters.capability(for: primaryRoute, adapterID: primaryAdapterID) != .unsupported,
           let primaryAdapter {
            let result = try await imageAttemptWithRefresh(
                account: primary,
                adapter: primaryAdapter,
                route: primaryRoute,
                model: primaryModel,
                prompt: prompt,
                session: session
            )
            switch result {
            case .generated(let output):
                imageAdapters.record(.supported, for: primaryRoute, adapterID: primaryAdapterID)
                return ProviderImageGeneration(output: output, provider: RouterCatalog.label(for: primary.provider), model: primaryModel)
            case .failed(let failure):
                throw ProviderImageGenerationError.failed(failure)
            case .unsupported:
                imageAdapters.record(.unsupported, for: primaryRoute, adapterID: primaryAdapterID)
            }
        }

        let fallbackSource = "\(RouterCatalog.label(for: primary.provider))/\(primaryModel)"
        let candidates = store.state.accounts
            .filter { $0.active && $0.imageFallbackEnabled }
            .sorted { $0.priority < $1.priority }
        for account in candidates {
            let model = effectiveModel(for: account)
            let route = imageRoute(for: account, model: model)
            let adapter = imageAdapters.adapter(for: route, includeFallbackOnly: true)
            let adapterID = adapter?.id ?? "none"
            if imageAdapters.capability(for: route, adapterID: adapterID) == .unsupported { continue }
            guard let adapter else {
                continue
            }
            // An image fallback is deliberately a one-shot side request. It
            // receives only the image prompt and never enters chat routing,
            // sticky-provider state, or the conversation prompt cache.
            let result = try await imageAttemptWithRefresh(
                account: account,
                adapter: adapter,
                route: route,
                model: model,
                prompt: prompt,
                session: session
            )
            switch result {
            case .generated(let output):
                imageAdapters.record(.supported, for: route, adapterID: adapterID)
                let generatedModel = adapterID == "openai.images.fallback" ? "gpt-image-1.5" : model
                return ProviderImageGeneration(
                    output: output,
                    provider: RouterCatalog.label(for: account.provider),
                    model: generatedModel,
                    fallbackFrom: fallbackSource
                )
            case .unsupported:
                imageAdapters.record(.unsupported, for: route, adapterID: adapterID)
            case .failed(let failure):
                throw ProviderImageGenerationError.failed(failure)
            }
        }
        throw ProviderImageGenerationError.unsupported(
            AppCopy.format("media.imageUnsupportedWithFallbackHint", fallbackSource)
        )
    }

    var imagePrimaryAccount: StoredProviderAccount? {
        let selected = selectedModelID == ModelRouter.autoModelID ? "" : selectedModelID
        let active = store.state.accounts.filter(\.active).sorted { $0.priority < $1.priority }
        return active.first(where: { canServe($0, model: selected) }) ?? active.first
    }

    private func imageModel(for account: StoredProviderAccount) -> String {
        let selected = selectedModelID == ModelRouter.autoModelID ? "" : selectedModelID
        return selected.isEmpty ? effectiveModel(for: account) : selected
    }

    private func imageRoute(for account: StoredProviderAccount, model: String) -> ProviderImageRoute {
        ProviderImageRoute(
            accountID: account.id,
            providerID: account.provider,
            baseURL: account.baseURL,
            api: account.api,
            model: model,
            authType: account.authType,
            sessionAccountID: account.sessionAccountID
        )
    }

    private func imageConfiguration(for account: StoredProviderAccount, model: String) throws -> AgentConfiguration {
        try configuration(for: account, model: model)
    }

    private func imageAttemptWithRefresh(
        account: StoredProviderAccount,
        adapter: any ProviderImageAdapter,
        route: ProviderImageRoute,
        model: String,
        prompt: String,
        session: URLSession
    ) async throws -> ProviderImageResult {
        var refreshed = false
        while true {
            let result = try await imageAttempt(
                adapter: adapter,
                route: route,
                configuration: try imageConfiguration(for: account, model: model),
                prompt: prompt,
                session: session
            )
            guard case .failed(let failure) = result,
                  failure.kind == .auth,
                  !refreshed else { return result }
            guard await refreshCredential(for: account) else { return result }
            refreshed = true
        }
    }

    private func imageAttempt(
        adapter: any ProviderImageAdapter,
        route: ProviderImageRoute,
        configuration: AgentConfiguration,
        prompt: String,
        session: URLSession
    ) async throws -> ProviderImageResult {
        do {
            let prepared = try adapter.prepareImageRequest(prompt: prompt, model: route.model, route: route)
            var request = URLRequest(url: prepared.url, timeoutInterval: 180)
            request.httpMethod = "POST"
            request.httpBody = prepared.body
            for (header, value) in prepared.headers { request.setValue(value, forHTTPHeaderField: header) }
            if let key = configuration.apiKey, !key.isEmpty {
                switch prepared.authentication {
                case .none: break
                case .bearer: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                case .rawHeader(let header): request.setValue(key, forHTTPHeaderField: header)
                }
            }
            if configuration.api == RouterAPIKind.chatGPT.rawValue {
                if configuration.transportSpec?.quirks.requiresSessionAccountID == true,
                   let accountID = configuration.sessionAccountID, !accountID.isEmpty {
                    request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
                    request.setValue("codex", forHTTPHeaderField: "OAI-Product-Sku")
                    request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
                }
                request.setValue(UUID().uuidString, forHTTPHeaderField: "session-id")
                let threadID = UUID().uuidString
                request.setValue(threadID, forHTTPHeaderField: "thread-id")
                request.setValue(threadID, forHTTPHeaderField: "x-client-request-id")
            }
            for (header, value) in configuration.transportSpec?.extraHeaders ?? [:] {
                request.setValue(value, forHTTPHeaderField: header)
            }
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] {
                headers[String(describing: key)] = String(describing: value)
            }
            return adapter.parseImageResponse(data: data, status: http?.statusCode ?? 0, headers: headers)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            return .failed(ProviderImageFailure(kind: .network, message: error.localizedDescription))
        } catch let error as NativeAgentError {
            return .failed(ProviderImageFailure(kind: .other, message: error.message))
        } catch {
            return .failed(ProviderImageFailure(kind: .other, message: error.localizedDescription))
        }
    }
}
