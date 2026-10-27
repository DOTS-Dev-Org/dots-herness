// Copyright (c) 2026 DOTS

import Foundation

enum WorkspacePathResolver {
    static func resolve(_ path: String, workspace: URL, allowAbsolute: Bool = false) -> URL? {
        if allowAbsolute, path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        // Append to the base before resolving aliases, so /var and /private/var compare equally.
        let url = workspace.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.hasSuffix("/") ? root : root + "/"
        return url.path == root || url.path.hasPrefix(rootPath) ? url : nil
    }
}
