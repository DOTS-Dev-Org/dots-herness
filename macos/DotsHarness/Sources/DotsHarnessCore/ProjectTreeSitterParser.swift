// Copyright (c) 2026 DOTS
// Tree-sitter grammar adapters and syntax-tree extraction for project code graphs.

import Foundation
import SwiftTreeSitter
import TreeSitterC
import TreeSitterCSharp
import TreeSitterGo
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterPHP
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterCPP
import TreeSitterTypeScript

enum ProjectCodeParser {
    private struct Grammar {
        var name: String
        var language: Language
    }

    static let supportedExtensions: Set<String> = [
        "swift", "cs", "ts", "tsx", "js", "jsx", "py", "go", "rs", "java", "php", "rb",
        "c", "h", "cpp", "cc", "cxx", "hpp", "hh",
    ]

    static func languageName(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "swift": "swift"
        case "cs": "c_sharp"
        case "ts": "typescript"
        case "tsx": "tsx"
        case "js", "jsx": "javascript"
        case "py": "python"
        case "go": "go"
        case "rs": "rust"
        case "java": "java"
        case "php": "php"
        case "rb": "ruby"
        case "c", "h": "c"
        case "cpp", "cc", "cxx", "hpp", "hh": "cpp"
        default: nil
        }
    }

    static func parse(path: String, source: String, stamp: CodeGraphFileStamp, digest: String) -> CodeGraphFile? {
        guard let grammar = grammar(forExtension: (path as NSString).pathExtension) else { return nil }
        let parser = Parser()
        guard (try? parser.setLanguage(grammar.language)) != nil,
              let tree = parser.parse(source),
              let root = tree.rootNode else { return nil }

        let fileID = "file:\(path)"
        let fileNode = CodeGraphNode(
            id: fileID,
            kind: "file",
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            line: 1,
            language: grammar.name,
            signature: nil
        )
        var nodes = [fileNode]
        var edges: [CodeGraphEdge] = []
        var references: [CodeGraphReference] = []
        var seenDeclarations = Set<String>()
        var seenNodeIDs: Set<String> = [fileID]
        let lineStarts = makeLineStarts(source)
        var stack: [(node: Node, parentSymbolID: String?)] = [(root, nil)]

        while let (node, parentSymbolID) = stack.popLast() {
            let nodeType = node.nodeType ?? ""
            let kind = declarationKind(nodeType)
            var currentParent = parentSymbolID

            if let kind, let name = declarationName(node, source: source), !name.isEmpty {
                let line = lineNumber(atUTF16Offset: node.range.location, lineStarts: lineStarts)
                let identity = "\(line)|\(name)|\(kind)"
                let id = "symbol:\(path)#\(line):\(name):\(kind)"
                if seenDeclarations.insert(identity).inserted && seenNodeIDs.insert(id).inserted {
                    nodes.append(CodeGraphNode(
                        id: id,
                        kind: kind,
                        name: name,
                        path: path,
                        line: line,
                        language: grammar.name,
                        signature: nil
                    ))
                    edges.append(CodeGraphEdge(
                        from: parentSymbolID ?? fileID,
                        to: id,
                        relation: "CONTAINS",
                        provenance: "EXTRACTED",
                        confidence: 1
                    ))
                    currentParent = id
                }
            }

            if isImportNode(nodeType),
               let importText = text(of: node, in: source),
               !importText.isEmpty {
                let sourceName = importSource(node, fullText: importText, source: source)
                if !sourceName.isEmpty {
                    let line = lineNumber(atUTF16Offset: node.range.location, lineStarts: lineStarts)
                    let importID = "import:\(path)#\(line):\(sourceName)"
                    if seenNodeIDs.insert(importID).inserted {
                        nodes.append(CodeGraphNode(
                            id: importID,
                            kind: "import",
                            name: sourceName,
                            path: path,
                            line: line,
                            language: grammar.name,
                            signature: nil
                        ))
                        edges.append(CodeGraphEdge(from: fileID, to: importID, relation: "IMPORTS", provenance: "EXTRACTED", confidence: 1))
                        references.append(CodeGraphReference(from: importID, name: sourceName, relation: "RESOLVES_TO"))
                    }
                }
            }

            if isInheritanceNode(nodeType), let from = currentParent {
                for name in identifierNames(in: node, source: source) {
                    references.append(CodeGraphReference(from: from, name: name, relation: "INHERITS"))
                }
            }

            if isCallNode(nodeType),
               let from = currentParent,
               let name = callName(node, source: source),
               !name.isEmpty {
                references.append(CodeGraphReference(from: from, name: name, relation: "CALLS"))
            }

            if node.namedChildCount > 0 {
                for index in stride(from: node.namedChildCount - 1, through: 0, by: -1) {
                    if let child = node.namedChild(at: index) {
                        stack.append((child, currentParent))
                    }
                }
            }
        }

        return CodeGraphFile(stamp: stamp, sha256: digest, nodes: nodes, extractedEdges: edges, references: references)
    }

    private static func grammar(forExtension ext: String) -> Grammar? {
        switch ext.lowercased() {
        case "swift": Grammar(name: "swift", language: Language(language: tree_sitter_swift()))
        case "cs": Grammar(name: "c_sharp", language: Language(language: tree_sitter_c_sharp()))
        case "ts": Grammar(name: "typescript", language: Language(language: tree_sitter_typescript()))
        case "tsx": Grammar(name: "tsx", language: Language(language: tree_sitter_tsx()))
        case "js", "jsx": Grammar(name: "javascript", language: Language(language: tree_sitter_javascript()))
        case "py": Grammar(name: "python", language: Language(language: tree_sitter_python()))
        case "go": Grammar(name: "go", language: Language(language: tree_sitter_go()))
        case "rs": Grammar(name: "rust", language: Language(language: tree_sitter_rust()))
        case "java": Grammar(name: "java", language: Language(language: tree_sitter_java()))
        case "php": Grammar(name: "php", language: Language(language: tree_sitter_php()))
        case "rb": Grammar(name: "ruby", language: Language(language: tree_sitter_ruby()))
        case "c", "h": Grammar(name: "c", language: Language(language: tree_sitter_c()))
        case "cpp", "cc", "cxx", "hpp", "hh": Grammar(name: "cpp", language: Language(language: tree_sitter_cpp()))
        default: nil
        }
    }

    private static func declarationName(_ node: Node, source: String) -> String? {
        if let nameNode = node.child(byFieldName: "name"),
           let fieldName = text(of: nameNode, in: source) {
            return fieldName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for index in 0..<node.namedChildCount {
            guard let child = node.namedChild(at: index), isIdentifier(child.nodeType ?? ""),
                  let childText = text(of: child, in: source)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !childText.isEmpty else { continue }
            return childText
        }
        return nil
    }

    private static func declarationKind(_ type: String) -> String? {
        switch type {
        case "class_declaration", "class_definition", "class_item", "class_specifier", "class_declaration_statement": "class"
        case "interface_declaration", "trait_item", "protocol_declaration", "trait_declaration": "interface"
        case "struct_declaration", "struct_item", "struct_specifier": "struct"
        case "enum_declaration", "enum_item", "enum_specifier", "enum_declaration_statement": "enum"
        case "record_declaration", "record_definition": "record"
        case "function_declaration", "function_definition", "function_item", "function_signature_item": "function"
        case "method_declaration", "method_definition", "method_item", "method_signature": "method"
        case "constructor_declaration", "constructor_definition", "constructor_declaration_statement": "constructor"
        case "type_alias_declaration", "type_item", "type_declaration": "type"
        default: nil
        }
    }

    private static func isImportNode(_ type: String) -> Bool {
        ["import_declaration", "import_statement", "import_from_statement", "use_declaration", "use_item", "using_directive", "package_import_declaration"].contains(type)
    }

    private static func isInheritanceNode(_ type: String) -> Bool {
        let value = type.lowercased()
        return value.contains("base_clause") || value.contains("base_class") || value.contains("extends_clause")
            || value.contains("superclass") || value.contains("super_class") || value.contains("super_interfaces")
            || value.contains("implements_interfaces") || value == "extends_interfaces"
    }

    private static func isCallNode(_ type: String) -> Bool {
        let value = type.lowercased()
        return value == "call_expression" || value == "call" || value == "method_invocation"
            || value == "invocation_expression" || value == "function_call_expression"
    }

    private static func callName(_ node: Node, source: String) -> String? {
        let candidateNode = node.child(byFieldName: "function")
            ?? node.child(byFieldName: "method")
            ?? node.child(byFieldName: "name")
            ?? node.namedChild(at: 0)
        let candidate = candidateNode.flatMap { text(of: $0, in: source) }
        guard let candidate else { return nil }
        let base = candidate
            .split(whereSeparator: { $0 == "." || $0 == "?" || $0 == "!" })
            .last.map(String.init) ?? candidate
        let cleaned = base.trimmingCharacters(in: CharacterSet(charactersIn: "`\"' "))
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func identifierNames(in node: Node, source: String) -> [String] {
        var names: [String] = []
        var pending = [node]
        while let current = pending.popLast() {
            let type = current.nodeType ?? ""
            if isIdentifier(type),
               let value = text(of: current, in: source)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                names.append(value)
            }
            if current.namedChildCount > 0 {
                for index in stride(from: current.namedChildCount - 1, through: 0, by: -1) {
                    if let child = current.namedChild(at: index) { pending.append(child) }
                }
            }
        }
        return names
    }

    private static func isIdentifier(_ type: String) -> Bool {
        ["identifier", "type_identifier", "simple_identifier", "field_identifier", "property_identifier", "constant"].contains(type)
    }

    private static func importSource(_ node: Node, fullText: String, source: String) -> String {
        var pending = [node]
        while let current = pending.popLast() {
            let type = current.nodeType?.lowercased() ?? ""
            if type.contains("string"), let value = text(of: current, in: source) {
                let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
                if !trimmed.isEmpty { return trimmed }
            }
            if current.namedChildCount > 0 {
                for index in stride(from: current.namedChildCount - 1, through: 0, by: -1) {
                    if let child = current.namedChild(at: index) { pending.append(child) }
                }
            }
        }
        for prefix in ["import ", "use ", "using "] where fullText.hasPrefix(prefix) {
            return String(fullText.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "; \n\t"))
        }
        return fullText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// SwiftTreeSitter's Node.range is an NSRange over UTF-16, matching NSString.
    private static func text(of node: Node, in source: String) -> String? {
        let value = source as NSString
        let range = node.range
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= value.length else { return nil }
        return value.substring(with: range)
    }

    private static func makeLineStarts(_ source: String) -> [Int] {
        var starts = [0]
        for (index, unit) in Array(source.utf16).enumerated() where unit == 10 {
            starts.append(index + 1)
        }
        return starts
    }

    private static func lineNumber(atUTF16Offset offset: Int, lineStarts: [Int]) -> Int {
        var lower = 0
        var upper = lineStarts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lineStarts[middle] <= offset { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

}
