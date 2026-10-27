// Copyright (c) 2026 DOTS
// Keychain accessibility classes for the credentials this app stores.

import Foundation
import Security

/// Keychain items must not travel to another machine: an encrypted Time
/// Machine or iCloud backup, or a restored device, would carry the provider
/// keys, OAuth tokens, MCP tokens and pairing tokens along with it.
/// `ThisDeviceOnly` keeps every item on the machine that stored it, and
/// `WhenUnlocked` keeps it out of reach while the screen is locked.
enum KeychainAccess {
    /// Provider API keys, SSH passwords, MCP bearer tokens, device pairing
    /// tokens: only readable while the user is at the machine.
    static var whenUnlocked: CFString { kSecAttrAccessibleWhenUnlockedThisDeviceOnly }
    /// Tokens that a background refresh has to read while the screen is
    /// locked — still never leaves this device.
    static var afterFirstUnlock: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
}
