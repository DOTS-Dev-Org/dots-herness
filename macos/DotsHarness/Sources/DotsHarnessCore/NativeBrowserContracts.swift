// Copyright (c) 2026 DOTS
// Tool definitions and contracts for the native in-app live browser (WebKit on macOS).

import Foundation
import HarnessPluginKit

public enum NativeBrowserAction: String, CaseIterable, Codable, Sendable {
    case open
    case navigate
    case screenshot
    case evaluateJs = "evaluate_js"
    case getContent = "get_content"
    case click
    case type
    case reload
    case back
    case forward
}

public enum NativeBrowserTools {
    public static let toolName = "native_browser"

    public static let definitions: [AgentToolDefinition] = [
        AgentToolDefinition(
            name: toolName,
            description: """
            Interact directly with the native in-app live browser located in the Right Dock (Apple WebKit). \
            Zero overhead (0 MB download, minimal RAM/CPU). Use it to open URLs, preview local web servers, \
            capture pixel-perfect screenshots, evaluate JavaScript, read DOM text, click elements, or type input.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "enum": .array(NativeBrowserAction.allCases.map { .string($0.rawValue) }),
                        "description": .string("Action to perform on the in-app live browser."),
                    ]),
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("URL to navigate to for 'open' or 'navigate' (e.g. 'http://localhost:3000' or 'https://example.com')."),
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Screenshot destination path relative to workspace (defaults to 'native_browser.png')."),
                    ]),
                    "script": .object([
                        "type": .string("string"),
                        "description": .string("JavaScript snippet to evaluate for 'evaluate_js' (e.g. 'document.title' or 'document.body.innerText')."),
                    ]),
                    "selector": .object([
                        "type": .string("string"),
                        "description": .string("CSS selector for 'click' or 'type' actions (e.g. '#submit-btn' or 'input[name=\"email\"]')."),
                    ]),
                    "text": .object([
                        "type": .string("string"),
                        "description": .string("Text to enter into the element for 'type' action."),
                    ]),
                    "x": .object([
                        "type": .string("integer"),
                        "description": .string("Optional X coordinate for 'click' action."),
                    ]),
                    "y": .object([
                        "type": .string("integer"),
                        "description": .string("Optional Y coordinate for 'click' action."),
                    ]),
                ]),
                "required": .array([.string("action")]),
            ])
        ),
    ]
}
