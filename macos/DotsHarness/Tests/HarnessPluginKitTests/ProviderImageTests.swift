import Foundation
import XCTest
import HarnessPluginKit
import PluginRuntime
@testable import DotsHarnessCore

@MainActor
final class ProviderImageTests: XCTestCase {
    func testRegistryMatchesAdaptersAndUnmountRemovesPluginAdapter() throws {
        let paths = temporaryPaths()
        let catalog = PluginCatalog(paths: paths)
        catalog.registerBuiltin(ImageAdapterPlugin.self)
        let host = PluginHost(catalog: catalog)
        let route = ProviderImageRoute(
            accountID: "account",
            providerID: "test-image",
            baseURL: "https://example.test/v1",
            api: RouterAPIKind.openAICompatible.rawValue,
            model: "model"
        )

        let issues = host.mount(CompositionDocument(
            plane: .host,
            entries: [CompositionEntry(id: "image-plugin", plugin: ImageAdapterPlugin.manifest.id)]
        ))

        XCTAssertTrue(issues.isEmpty, issues.map(\.message).joined(separator: "; "))
        XCTAssertEqual(host.imageAdapters.adapter(for: route)?.id, "test.image")
        host.unmountAll()
        XCTAssertNil(host.imageAdapters.adapter(for: route))
    }

    func testUntrustedPluginCannotRegisterNetworkAdapter() {
        let registry = ProviderImageAdapterRegistry()
        XCTAssertThrowsError(try registry.register(TestImageAdapter(), owner: "untrusted", trust: .untrusted)) { error in
            XCTAssertEqual(error as? ProviderImageAdapterRegistryError, .untrustedPlugin)
        }
    }

    func testBuiltInAdaptersMatchByWireProtocolWithoutProviderCapabilityMetadata() {
        let registry = ProviderImageAdapterRegistry()
        BuiltInProviderImageAdapters.register(on: registry)
        let openAI = ProviderImageRoute(accountID: "1", providerID: "openai", baseURL: "https://api.openai.com/v1", api: "openai-compatible", model: "gpt-4.1-mini")
        let chatGPT = ProviderImageRoute(accountID: "2", providerID: "gpt", baseURL: "https://chatgpt.com/backend-api/codex", api: RouterAPIKind.chatGPT.rawValue, model: "gpt-5.6")
        let other = ProviderImageRoute(accountID: "3", providerID: "deepseek", baseURL: "https://example.test/v1", api: "openai-compatible", model: "deepseek-chat")

        XCTAssertEqual(registry.adapter(for: openAI)?.id, "openai.responses.image")
        XCTAssertEqual(registry.adapter(for: chatGPT)?.id, "openai.responses.image")
        XCTAssertNil(registry.adapter(for: other))
        XCTAssertNil(ProviderRegistry.shared.spec("openai")?.media?.spec(for: .image))
    }

    func testOpenAIResponsesParsesJSONAndSSEImageCalls() throws {
        let adapter = OpenAIResponsesImageAdapter()
        let json = Data(#"{"output":[{"type":"image_generation_call","result":"AQID"}]}"#.utf8)
        let sse = Data("data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"image_generation_call\",\"result\":\"AQID\"}}\n\ndata: [DONE]\n".utf8)

        for data in [json, sse] {
            let result = adapter.parseImageResponse(data: data, status: 200, headers: [:])
            guard case .generated(let output) = result else {
                return XCTFail("Responses image output was not parsed")
            }
            XCTAssertEqual(output.data, Data([1, 2, 3]))
        }
    }

    func testGeminiInlineDataAndFailureCategories() throws {
        let adapter = GeminiNativeImageAdapter()
        let image = Data(#"{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/jpeg","data":"AQID"}}]}}]}"#.utf8)
        let generated = adapter.parseImageResponse(data: image, status: 200, headers: [:])
        guard case .generated(let output) = generated else { return XCTFail("Gemini inlineData was not parsed") }
        XCTAssertEqual(output.data, Data([1, 2, 3]))
        XCTAssertEqual(output.mimeType, "image/jpeg")

        let unsupported = adapter.parseImageResponse(
            data: Data(#"{"error":{"message":"model does not support responseModalities IMAGE"}}"#.utf8),
            status: 400,
            headers: [:]
        )
        XCTAssertEqual(unsupported, .unsupported("model does not support responseModalities IMAGE"))

        let auth = adapter.parseImageResponse(data: Data(#"{"error":{"message":"invalid API key"}}"#.utf8), status: 401, headers: [:])
        XCTAssertEqual(failure(from: auth)?.kind, .auth)
        let rate = adapter.parseImageResponse(data: Data(#"{"error":{"message":"slow down"}}"#.utf8), status: 429, headers: [:])
        XCTAssertEqual(failure(from: rate)?.kind, .rateLimit)
        let safety = adapter.parseImageResponse(data: Data(#"{"error":{"message":"safety policy blocked this request"}}"#.utf8), status: 400, headers: [:])
        XCTAssertEqual(failure(from: safety)?.kind, .safety)
        let invalid = adapter.parseImageResponse(data: Data("{}".utf8), status: 200, headers: [:])
        XCTAssertEqual(failure(from: invalid)?.kind, .invalidOutput)
    }

    func testCapabilityCacheIsScopedToAccountEndpointAdapterAndModel() {
        let registry = ProviderImageAdapterRegistry()
        let first = ProviderImageRoute(accountID: "account", providerID: "openai", baseURL: "https://one.test/v1", api: "openai-compatible", model: "model-a")
        let sameModel = first
        let otherModel = ProviderImageRoute(accountID: first.accountID, providerID: first.providerID, baseURL: first.baseURL, api: first.api, model: "model-b")
        let otherEndpoint = ProviderImageRoute(accountID: first.accountID, providerID: first.providerID, baseURL: "https://two.test/v1", api: first.api, model: first.model)

        registry.record(.supported, for: first, adapterID: "adapter")
        XCTAssertEqual(registry.capability(for: sameModel, adapterID: "adapter"), .supported)
        XCTAssertNil(registry.capability(for: otherModel, adapterID: "adapter"))
        XCTAssertNil(registry.capability(for: otherEndpoint, adapterID: "adapter"))
        registry.record(.unsupported, for: otherModel, adapterID: "adapter")
        XCTAssertEqual(registry.capability(for: otherModel, adapterID: "adapter"), .unsupported)
    }

    func testMissingFallbackFlagMigratesToFalse() throws {
        let account = StoredProviderAccount(
            provider: "openai",
            name: "OpenAI",
            model: "gpt-4.1-mini",
            baseURL: "https://api.openai.com/v1",
            credentialID: "account.key"
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any])
        object.removeValue(forKey: "imageFallbackEnabled")
        let decoded = try JSONDecoder().decode(StoredProviderAccount.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(decoded.imageFallbackEnabled)
    }

    func testRouterUsesUnsupportedPrimaryResponseThenFlaggedFallback() async throws {
        let paths = temporaryPaths()
        let router = RouterController(paths: paths)
        let provider = try XCTUnwrap(RouterCatalog.kind(for: "openai"))
        let account = try router.store.addAccount(
            provider: provider,
            name: "OpenAI",
            secret: "key",
            model: "gpt-4.1-mini"
        )
        try router.store.setImageFallback(account.id, true)
        router.selectedModelID = account.model
        ImageRouterURLProtocol.paths = []
        ImageRouterURLProtocol.responses = [
            (400, Data(#"{"error":{"message":"image_generation is not supported by this model"}}"#.utf8)),
            (200, Data(#"{"data":[{"b64_json":"AQID"}]}"#.utf8)),
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageRouterURLProtocol.self]

        let generated = try await router.generateImage(
            prompt: "a red fox",
            session: URLSession(configuration: configuration)
        )

        XCTAssertEqual(generated.output.data, Data([1, 2, 3]))
        XCTAssertEqual(generated.provider, "OpenAI")
        XCTAssertEqual(generated.model, "gpt-image-1.5")
        XCTAssertEqual(generated.fallbackFrom, "OpenAI/gpt-4.1-mini")
        XCTAssertEqual(ImageRouterURLProtocol.paths, ["/v1/responses", "/v1/images/generations"])
        let route = ProviderImageRoute(accountID: account.id, providerID: "openai", baseURL: account.baseURL, api: account.api, model: account.model, authType: account.authType)
        XCTAssertEqual(router.imageAdapters.capability(for: route, adapterID: "openai.responses.image"), .unsupported)
        XCTAssertEqual(router.imageAdapters.capability(for: route, adapterID: "openai.images.fallback"), .supported)
    }

    func testRouterRefreshesExpiredChatGPTCredentialBeforeRetryingImage() async throws {
        let paths = temporaryPaths()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageRouterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let router = RouterController(paths: paths, oauthSession: session)
        let provider = try XCTUnwrap(RouterCatalog.kind(for: "gpt"))
        let account = try router.store.addAccount(
            provider: provider,
            name: "GPT",
            secret: "expired-token",
            model: "gpt-5.6-luna",
            api: RouterAPIKind.chatGPT.rawValue,
            authType: "chatgpt",
            sessionAccountID: "account-1",
            refreshSecret: "refresh-token"
        )
        router.selectedModelID = account.model
        ImageRouterURLProtocol.responses = [
            (401, Data(#"{"error":{"message":"Provided authentication token is expired."}}"#.utf8)),
            (200, Data(#"{"access_token":"fresh-token","refresh_token":"next-refresh"}"#.utf8)),
            (200, Data(#"{"output":[{"type":"image_generation_call","result":"AQID"}]}"#.utf8)),
        ]
        ImageRouterURLProtocol.paths = []
        ImageRouterURLProtocol.requests = []
        ImageRouterURLProtocol.bodies = []

        let generated = try await router.generateImage(prompt: "a red fox", session: session)

        XCTAssertEqual(generated.output.data, Data([1, 2, 3]))
        XCTAssertEqual(
            ImageRouterURLProtocol.paths,
            ["/backend-api/codex/responses", "/oauth/token", "/backend-api/codex/responses"]
        )
        XCTAssertEqual(
            ImageRouterURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization"),
            "Bearer expired-token"
        )
        XCTAssertEqual(
            ImageRouterURLProtocol.requests[2].value(forHTTPHeaderField: "Authorization"),
            "Bearer fresh-token"
        )
        let refreshBody = try XCTUnwrap(ImageRouterURLProtocol.bodies[1])
        XCTAssertTrue(String(decoding: refreshBody, as: UTF8.self).contains("refresh_token=refresh-token"))
        XCTAssertEqual(try router.store.credential(for: account), "fresh-token")
        XCTAssertEqual(try router.store.refreshCredential(for: account), "next-refresh")
    }

    func testRouterDoesNotCacheTransientFailureOrFallBack() async throws {
        let paths = temporaryPaths()
        let router = RouterController(paths: paths)
        let provider = try XCTUnwrap(RouterCatalog.kind(for: "openai"))
        let account = try router.store.addAccount(provider: provider, name: "OpenAI", secret: "key", model: "gpt-4.1-mini")
        try router.store.setImageFallback(account.id, true)
        router.selectedModelID = account.model
        ImageRouterURLProtocol.paths = []
        ImageRouterURLProtocol.responses = [(429, Data(#"{"error":{"message":"rate limit"}}"#.utf8))]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageRouterURLProtocol.self]

        do {
            _ = try await router.generateImage(prompt: "a red fox", session: URLSession(configuration: configuration))
            XCTFail("rate limit should fail")
        } catch let error as ProviderImageGenerationError {
            guard case .failed(let failure) = error else { return XCTFail("rate limit should be failed, not unsupported") }
            XCTAssertEqual(failure.kind, .rateLimit)
        }
        let route = ProviderImageRoute(accountID: account.id, providerID: "openai", baseURL: account.baseURL, api: account.api, model: account.model, authType: account.authType)
        XCTAssertNil(router.imageAdapters.capability(for: route, adapterID: "openai.responses.image"))
    }

    func testUnsupportedCacheKeepsCommandVisibleButUnknownModelRetries() async throws {
        let paths = temporaryPaths()
        let router = RouterController(paths: paths)
        let provider = try XCTUnwrap(RouterCatalog.kind(for: "openai"))
        let account = try router.store.addAccount(provider: provider, name: "OpenAI", secret: "key", model: "gpt-4.1-mini")
        router.selectedModelID = account.model
        ImageRouterURLProtocol.paths = []
        ImageRouterURLProtocol.responses = [(400, Data(#"{"error":{"message":"image_generation unsupported"}}"#.utf8))]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageRouterURLProtocol.self]

        XCTAssertTrue(router.imageGenerationCommandVisible)
        _ = try? await router.generateImage(prompt: "a red fox", session: URLSession(configuration: configuration))
        XCTAssertTrue(router.imageGenerationCommandVisible)
        router.selectedModelID = "unknown-model"
        XCTAssertTrue(router.imageGenerationCommandVisible)
    }

    func testProviderWithoutImageAdapterKeepsCommandDiscoverable() throws {
        let paths = temporaryPaths()
        let router = RouterController(paths: paths)
        let provider = try XCTUnwrap(RouterCatalog.kind(for: "deepseek"))
        let account = try router.store.addAccount(
            provider: provider,
            name: "DeepSeek",
            secret: "key",
            model: "deepseek-chat"
        )
        router.selectedModelID = account.model

        XCTAssertNil(router.imageAdapters.adapter(for: ProviderImageRoute(
            accountID: account.id,
            providerID: account.provider,
            baseURL: account.baseURL,
            api: account.api,
            model: account.model,
            authType: account.authType
        )))
        XCTAssertTrue(router.imageGenerationCommandVisible)
    }

    private func failure(from result: ProviderImageResult) -> ProviderImageFailure? {
        guard case .failed(let failure) = result else { return nil }
        return failure
    }

    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DotsHarnessImageTests-\(UUID().uuidString)", isDirectory: true)
        let paths = SupportPaths(
            root: root,
            plugins: root.appendingPathComponent("plugins", isDirectory: true),
            presets: root.appendingPathComponent("presets", isDirectory: true),
            settings: root.appendingPathComponent("settings.json"),
            hostPatch: root.appendingPathComponent("host.patch.yml"),
            trust: root.appendingPathComponent("trust.json"),
            models: root.appendingPathComponent("models", isDirectory: true),
            runtime: root.appendingPathComponent("runtime", isDirectory: true)
        )
        paths.ensure()
        return paths
    }
}

private final class TestImageAdapter: ProviderImageAdapter {
    let id = "test.image"

    func matches(_ route: ProviderImageRoute) -> Bool { route.providerID == "test-image" }

    func prepareImageRequest(prompt: String, model: String, route: ProviderImageRoute) throws -> ProviderImageRequest {
        ProviderImageRequest(url: URL(string: "https://example.test/image")!, body: Data())
    }

    func parseImageResponse(data: Data, status: Int, headers: [String: String]) -> ProviderImageResult {
        .unsupported("test")
    }
}

private final class ImageAdapterPlugin: DefaultPlugin {
    static let manifest = PluginManifest(
        id: "dots.test-image-adapter",
        name: "Image adapter",
        version: "1.0.0",
        plane: .host,
        inject: ["provider.imageAdapters"]
    )

    init() {}

    func apply(_ ctx: PluginContext) throws {
        let registry = try ctx.require("provider.imageAdapters") as! ProviderImageAdapterRegistry
        try registry.register(TestImageAdapter(), owner: ctx.rowId, trust: ctx.trust)
    }
}

private final class ImageRouterURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [(Int, Data)] = []
    nonisolated(unsafe) static var paths: [String] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data?] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = buffer.withUnsafeMutableBufferPointer { pointer in
                    stream.read(pointer.baseAddress!, maxLength: pointer.count)
                }
                if count <= 0 { break }
                data.append(contentsOf: buffer[0..<count])
            }
            stream.close()
            body = data
        }
        Self.bodies.append(body)
        Self.paths.append(request.url?.path ?? "")
        let response = Self.responses.isEmpty ? (500, Data()) : Self.responses.removeFirst()
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.0,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
