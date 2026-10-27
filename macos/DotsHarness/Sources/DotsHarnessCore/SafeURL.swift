// Copyright (c) 2026 DOTS
// One place that decides which addresses may be handed to the system.

import AppKit
import Foundation

public enum SafeURL {
    /// Opens a network address in the user's browser. Only http and https may
    /// leave the app: `file://`, `x-apple-...` and friends can run things in
    /// the user's name, and several of the addresses here come from a remote
    /// server or from a model-chosen endpoint.
    @discardableResult
    public static func openWeb(_ url: URL) -> Bool {
        guard canOpenWeb(url) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    /// True for an address that may be opened in the browser.
    public static func canOpenWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil,
              url.host?.isEmpty == false else { return false }
        return true
    }

    /// Opens a local file or folder. Only `file://` is accepted, and the path
    /// has to be inside one of the given roots, so a crafted address cannot
    /// reach into the rest of the disk.
    @discardableResult
    public static func openFile(_ url: URL, allowedRoots: [URL]) -> Bool {
        guard canOpenFile(url, allowedRoots: allowedRoots) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    /// True for a local address inside one of the given roots.
    public static func canOpenFile(_ url: URL, allowedRoots: [URL]) -> Bool {
        guard url.isFileURL, url.user == nil, url.password == nil else { return false }
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        return allowedRoots.contains { root in
            let base = root.resolvingSymlinksInPath().standardizedFileURL.path
            return target == base || target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }
}
