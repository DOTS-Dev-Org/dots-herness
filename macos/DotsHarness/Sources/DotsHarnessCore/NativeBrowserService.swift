// Copyright (c) 2026 DOTS
// Native in-app live browser service backed by Apple WebKit on macOS.
// Shared between the Right Dock UI and agent tools with zero external overhead.

import AppKit
import Foundation
import WebKit

@MainActor
public final class NativeBrowserService: NSObject, ObservableObject, WKNavigationDelegate {
    public static let shared = NativeBrowserService()

    public let engineName: String = "Apple WebKit (WKWebView)"

    @Published public var currentURLString: String = ""
    @Published public var pageTitle: String = ""
    @Published public var isLoading: Bool = false
    @Published public var canGoBack: Bool = false
    @Published public var canGoForward: Bool = false
    @Published public var agentActivity: String? = nil

    /// Callback invoked when an agent or code requests navigation, allowing RightDock to open or focus.
    public var onNavigateRequested: ((_ urlString: String) -> Void)?

    private var navigationContinuation: CheckedContinuation<String, Error>?
    private var isConfigured = false

    public private(set) lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        view.navigationDelegate = self
        return view
    }()

    override private init() {
        super.init()
    }

    // MARK: - Navigation

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
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            || trimmed.hasPrefix("about:") {
            resolvedURLString = trimmed
        } else if trimmed.hasPrefix("localhost") || trimmed.hasPrefix("127.0.0.1") {
            resolvedURLString = "http://" + trimmed
        } else {
            resolvedURLString = "https://" + trimmed
        }

        guard let url = URL(string: resolvedURLString), url.scheme != nil else {
            throw NativeBrowserError("Invalid URL format: \(candidate)")
        }

        agentActivity = "Navigating to \(resolvedURLString)..."
        onNavigateRequested?(resolvedURLString)

        let request = URLRequest(url: url)
        isLoading = true
        currentURLString = resolvedURLString

        return try await withCheckedThrowingContinuation { continuation in
            self.navigationContinuation = continuation
            self.webView.load(request)

            // Fallback timeout in case navigation delegates take too long
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard let self, let pending = self.navigationContinuation else { return }
                self.navigationContinuation = nil
                self.isLoading = false
                self.agentActivity = nil
                self.updateState()
                pending.resume(returning: "Loaded (timeout reached): \(self.webView.url?.absoluteString ?? resolvedURLString)")
            }
        }
    }

    public func reload() {
        webView.reload()
        updateState()
    }

    public func goBack() {
        if webView.canGoBack {
            webView.goBack()
            updateState()
        }
    }

    public func goForward() {
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

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        agentActivity = nil
        updateState()
        if let continuation = navigationContinuation {
            navigationContinuation = nil
            continuation.resume(returning: "Loaded page: \(pageTitle) (\(currentURLString))")
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        agentActivity = nil
        updateState()
        if let continuation = navigationContinuation {
            navigationContinuation = nil
            continuation.resume(throwing: error)
        }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        agentActivity = nil
        updateState()
        if let continuation = navigationContinuation {
            navigationContinuation = nil
            continuation.resume(throwing: error)
        }
    }

    private func updateState() {
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
