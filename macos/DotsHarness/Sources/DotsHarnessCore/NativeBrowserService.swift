// Copyright (c) 2026 DOTS
// Native in-app live browser service backed by Apple WebKit on macOS.
// Shared between the Right Dock UI and agent tools with zero external overhead.

import AppKit
import Foundation
import WebKit

@MainActor
public final class NativeBrowserService: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    /// Resolve the omnibox separately from agent URL navigation.
    public static func addressURL(for input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let lower = value.lowercased()
        if lower == "about:blank" { return URL(string: lower) }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: value), url.host != nil else { return nil }
            return url
        }
        // Never turn active/local schemes into executable navigation.
        if lower.hasPrefix("javascript:") || lower.hasPrefix("file:") || lower.hasPrefix("data:") {
            return nil
        }
        let host = value.split(separator: "/", maxSplits: 1).first.map { String($0).lowercased() } ?? lower
        let local = host == "localhost" || host.hasPrefix("localhost:")
            || host == "127.0.0.1" || host.hasPrefix("127.0.0.1:")
            || host == "[::1]" || host.hasPrefix("[::1]:")
        if !value.contains(where: { $0.isWhitespace }), local || host.contains(".") {
            let url = URL(string: (local ? "http://" : "https://") + value)
            if url?.host != nil { return url }
        }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: value)]
        return search.url
    }

    public private(set) static var shared = NativeBrowserService()

    /// Agent tools follow the selected dock browser tab.
    public static func activate(_ service: NativeBrowserService) { shared = service }

    public let engineName: String = "Apple WebKit (WKWebView)"

    @Published public var currentURLString: String = ""
    @Published public var pageTitle: String = ""
    @Published public var isLoading: Bool = false
    @Published public var canGoBack: Bool = false
    @Published public var canGoForward: Bool = false
    @Published public var navigationError: String?
    @Published public var agentActivity: String? = nil

    /// Callback invoked when an agent or code requests navigation, allowing RightDock to open or focus.
    public var onNavigateRequested: ((_ urlString: String) -> Void)?

    private var navigationContinuation: CheckedContinuation<String, Error>?
    private var pendingNavigation: WKNavigation?
    private var navigationID = UUID()
    private var observations: [NSKeyValueObservation] = []

    public private(set) lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // WebKit's bare embedded-view user agent makes some sites serve their
        // legacy layout. Keep the engine's own UA and append Safari compatibility.
        let safari = Bundle(url: URL(fileURLWithPath: "/Applications/Safari.app"))
        let version = safari?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        config.applicationNameForUserAgent = (version.map { "Version/\($0) " } ?? "") + "Safari/605.1.15 HerNess"
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        observations = [
            view.observe(\.url, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.updateState() }
            },
            view.observe(\.title, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.updateState() }
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.updateState() }
            },
            view.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.updateState() }
            },
            view.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.updateState() }
            },
        ]
        return view
    }()

    public override init() {
        super.init()
    }

    public func loadAddress(_ input: String) {
        guard let url = Self.addressURL(for: input) else {
            navigationError = AppCopy.text("dock.invalidAddress")
            return
        }
        Self.activate(self)
        onNavigateRequested?(url.absoluteString)
        cancelPendingNavigation()
        navigationError = nil
        currentURLString = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    public func stop() {
        webView.stopLoading()
        cancelPendingNavigation()
        updateState()
    }

    private func cancelPendingNavigation() {
        navigationID = UUID()
        pendingNavigation = nil
        if let pending = navigationContinuation {
            navigationContinuation = nil
            pending.resume(throwing: CancellationError())
        }
        agentActivity = nil
    }

    // MARK: - Navigation

    /// An agent may only open an address that the web tools would accept:
    /// a public one. `about:blank` is the single exception.
    static func isAllowedAgentURL(_ url: URL) async -> Bool {
        if url.scheme?.lowercased() == "about" { return url.absoluteString == "about:blank" }
        do {
            try await WebTools.requirePublicURL(url)
            return true
        } catch {
            return false
        }
    }

    public func navigate(to candidate: String) async throws -> String {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NativeBrowserError("URL cannot be empty.")
        }
        // ponytail: agent-initiated nav limited to http(s); file/data would leak local files / cookies.
        let lower = trimmed.lowercased()
        if lower.hasPrefix("file:") || lower.hasPrefix("data:") || lower.hasPrefix("javascript:") {
            throw NativeBrowserError("URL scheme not allowed for agent navigation.")
        }

        let resolvedURLString: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            resolvedURLString = trimmed
        } else if trimmed.hasPrefix("about:") {
            // Only the empty page; other about: URLs expose browser internals.
            resolvedURLString = "about:blank"
        } else if trimmed.hasPrefix("localhost") || trimmed.hasPrefix("127.0.0.1") {
            resolvedURLString = "http://" + trimmed
        } else {
            resolvedURLString = "https://" + trimmed
        }

        guard let url = URL(string: resolvedURLString), url.scheme != nil else {
            throw NativeBrowserError("Invalid URL format: \(candidate)")
        }

        // The browser runs with the user's cookies, so an agent that could
        // reach a loopback or private address could read the services that
        // run on this machine — the provider gateway and the remote-control
        // port among them. The same policy the web tools use applies here.
        guard await Self.isAllowedAgentURL(url) else {
            throw NativeBrowserError("That address is not available to the agent.")
        }

        cancelPendingNavigation()
        navigationError = nil
        let requestID = navigationID
        agentActivity = "Navigating to \(resolvedURLString)..."
        onNavigateRequested?(resolvedURLString)

        let request = URLRequest(url: url)
        isLoading = true
        currentURLString = resolvedURLString

        return try await withCheckedThrowingContinuation { continuation in
            self.navigationContinuation = continuation
            self.pendingNavigation = self.webView.load(request)

            // Fallback timeout in case navigation delegates take too long
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard let self, self.navigationID == requestID, let pending = self.navigationContinuation else { return }
                self.navigationContinuation = nil
                self.pendingNavigation = nil
                self.isLoading = false
                self.agentActivity = nil
                self.updateState()
                pending.resume(returning: "Loaded (timeout reached): \(self.webView.url?.absoluteString ?? resolvedURLString)")
            }
        }
    }

    public func reload() {
        Self.activate(self)
        webView.reload()
        updateState()
    }

    public func goBack() {
        Self.activate(self)
        if webView.canGoBack {
            webView.goBack()
            updateState()
        }
    }

    public func goForward() {
        Self.activate(self)
        if webView.canGoForward {
            webView.goForward()
            updateState()
        }
    }

    // MARK: - Snapshot & Screenshot

    public func takeSnapshot(path: String?, workspace: URL?) async throws -> (data: Data, savedPath: String) {
        agentActivity = "Capturing snapshot..."
        defer { agentActivity = nil }

        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: nil) { img, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let img {
                    continuation.resume(returning: img)
                } else {
                    continuation.resume(throwing: NativeBrowserError("Failed to render snapshot."))
                }
            }
        }

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            throw NativeBrowserError("Failed to encode snapshot to PNG.")
        }

        let relativePath = path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? (path ?? "native_browser.png")
            : "native_browser.png"

        let targetURL: URL
        if let workspace {
            targetURL = try resolveInWorkspace(relativePath, workspace: workspace)
            try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try pngData.write(to: targetURL, options: .atomic)
        } else {
            let tempDir = FileManager.default.temporaryDirectory
            targetURL = tempDir.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try pngData.write(to: targetURL, options: .atomic)
        }

        return (pngData, targetURL.path)
    }

    // MARK: - JavaScript & Interaction

    public func evaluateJavaScript(_ script: String) async throws -> String {
        agentActivity = "Evaluating script..."
        defer { agentActivity = nil }

        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result {
                    if let string = result as? String {
                        continuation.resume(returning: string)
                    } else if let number = result as? NSNumber {
                        continuation.resume(returning: number.stringValue)
                    } else if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]),
                              let jsonString = String(data: data, encoding: .utf8) {
                        continuation.resume(returning: jsonString)
                    } else {
                        continuation.resume(returning: String(describing: result))
                    }
                } else {
                    continuation.resume(returning: "undefined")
                }
            }
        }
    }

    public func getContent() async throws -> String {
        let script = """
        (() => {
            const title = document.title;
            const text = document.body ? document.body.innerText.trim() : '';
            return JSON.stringify({ title, url: window.location.href, textLength: text.length, sampleText: text.slice(0, 4000) });
        })()
        """
        return try await evaluateJavaScript(script)
    }

    public func click(selector: String?, x: Int?, y: Int?) async throws -> String {
        let script: String
        if let selector, !selector.isEmpty {
            // ponytail: JSON-encode untrusted strings into JS instead of quote-escaping.
            let encoded = jsString(selector)
            script = """
            (() => {
                const el = document.querySelector(\(encoded));
                if (!el) return 'Error: Element not found';
                el.click();
                return 'Clicked element';
            })()
            """
        } else if let x, let y {
            script = """
            (() => {
                const el = document.elementFromPoint(\(x), \(y));
                if (!el) return 'Error: No element at point (\(x), \(y))';
                el.click();
                return 'Clicked element at (\(x), \(y)): ' + el.tagName;
            })()
            """
        } else {
            throw NativeBrowserError("Either selector or coordinates (x, y) must be specified for click.")
        }
        return try await evaluateJavaScript(script)
    }

    public func typeText(text: String, selector: String?) async throws -> String {
        let encodedText = jsString(text)

        let script: String
        if let selector, !selector.isEmpty {
            let encodedSelector = jsString(selector)
            script = """
            (() => {
                const el = document.querySelector(\(encodedSelector));
                if (!el) return 'Error: Element not found';
                el.focus();
                el.value = \(encodedText);
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
                return 'Typed into element';
            })()
            """
        } else {
            script = """
            (() => {
                const el = document.activeElement;
                if (!el) return 'Error: No active focused element.';
                el.value = (el.value || '') + \(encodedText);
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
                return 'Typed into active element ' + el.tagName;
            })()
            """
        }
        return try await evaluateJavaScript(script)
    }

    private func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value], options: [])
        if let data, let encoded = String(data: data, encoding: .utf8) {
            return String(encoded.dropFirst().dropLast())
        }
        return "\"\""
    }

    // MARK: - Tool Dispatch

    public func execute(arguments: [String: Any], workspace: URL?) async throws -> String {
        guard let actionStr = arguments["action"] as? String,
              let action = NativeBrowserAction(rawValue: actionStr) else {
            return "Missing or invalid action for native_browser."
        }

        switch action {
        case .open, .navigate:
            guard let url = arguments["url"] as? String else {
                return "Missing 'url' parameter for \(action.rawValue)."
            }
            return try await navigate(to: url)

        case .screenshot:
            let path = arguments["path"] as? String
            let (_, savedPath) = try await takeSnapshot(path: path, workspace: workspace)
            return "Saved native in-app browser screenshot to \(savedPath)."

        case .evaluateJs:
            guard let script = arguments["script"] as? String else {
                return "Missing 'script' parameter for evaluate_js."
            }
            return try await evaluateJavaScript(script)

        case .getContent:
            return try await getContent()

        case .click:
            let selector = arguments["selector"] as? String
            let x = arguments["x"] as? Int
            let y = arguments["y"] as? Int
            return try await click(selector: selector, x: x, y: y)

        case .type:
            guard let text = arguments["text"] as? String else {
                return "Missing 'text' parameter for type action."
            }
            let selector = arguments["selector"] as? String
            return try await typeText(text: text, selector: selector)

        case .reload:
            reload()
            return "Reloaded native in-app browser."

        case .back:
            goBack()
            return "Navigated back."

        case .forward:
            goForward()
            return "Navigated forward."
        }
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Links requesting another window remain usable inside the dock.
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationError = nil
        updateState()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        agentActivity = nil
        updateState()
        if let continuation = navigationContinuation, navigation === pendingNavigation {
            navigationContinuation = nil
            pendingNavigation = nil
            continuation.resume(returning: "Loaded page: \(pageTitle) (\(currentURLString))")
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishFailedNavigation(navigation, error: error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishFailedNavigation(navigation, error: error)
    }

    private func finishFailedNavigation(_ navigation: WKNavigation?, error: Error) {
        isLoading = false
        agentActivity = nil
        if (error as NSError).code != NSURLErrorCancelled { navigationError = error.localizedDescription }
        updateState()
        if let continuation = navigationContinuation, navigation === pendingNavigation {
            navigationContinuation = nil
            pendingNavigation = nil
            continuation.resume(throwing: error)
        }
    }

    private func updateState() {
        isLoading = webView.isLoading
        currentURLString = webView.url?.absoluteString ?? currentURLString
        pageTitle = webView.title ?? ""
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    private func resolveInWorkspace(_ candidate: String, workspace: URL) throws -> URL {
        let base = workspace.resolvingSymlinksInPath().standardizedFileURL
        let destination = base.appendingPathComponent(candidate).resolvingSymlinksInPath().standardizedFileURL
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard destination.path == base.path || destination.path.hasPrefix(basePath) else {
            throw NativeBrowserError("Cannot write screenshot outside the workspace: \(candidate)")
        }
        return destination
    }
}

public struct NativeBrowserError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
