// Copyright (c) 2026 DOTS
// Application-wide localized copy shared by the native core and SwiftUI shell.

import Foundation

public enum AppCopy {
    public static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, comment: "")
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), arguments: arguments)
    }
}
