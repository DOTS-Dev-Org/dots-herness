// Copyright (c) 2026 DOTS
// User-editable keyboard shortcut definitions shared by the native shell.

import AppKit
import Foundation
import SwiftUI

/// Actions exposed in Settings > General > Keyboard shortcuts.
public enum KeyboardShortcutAction: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case toggleSidebar
    case pullRequests
    case scheduled
    case review
    case terminal
    case browser
    case files
    case sideChat
    case simulator

    public var id: String { rawValue }

    public var settingsKey: String { "ui.keyboardShortcut.\(rawValue)" }

    public var title: String {
        switch self {
        case .toggleSidebar:
            return AppCopy.text("settings.shortcuts.sidebar")
        case .pullRequests:
            return AppCopy.text("sidebar.pullRequests")
        case .scheduled:
            return AppCopy.text("sidebar.scheduled")
        case .review:
            return AppCopy.text("conversation.review")
        case .sideChat:
            return AppCopy.text("conversation.sideChat")
        case .simulator:
            return AppCopy.text("simulator.title")
        case .files:
            return AppCopy.text("conversation.files")
        case .browser:
            return AppCopy.text("conversation.browser")
        case .terminal:
            return AppCopy.text("conversation.terminal")
        }
    }

    public var systemImage: String {
        switch self {
        case .toggleSidebar: return "sidebar.left"
        case .pullRequests: return "arrow.triangle.branch"
        case .scheduled: return "clock"
        case .files: return "folder"
        case .review: return "plusminus.circle"
        case .sideChat: return "plus.bubble"
        case .simulator: return "iphone.gen3"
        case .browser: return "globe"
        case .terminal: return "terminal"
        }
    }

    public var defaultShortcut: UserKeyboardShortcut {
        switch self {
        case .toggleSidebar:
            return UserKeyboardShortcut(key: "b", modifierMask: UserKeyboardShortcut.command)!
        case .pullRequests:
            return UserKeyboardShortcut(
                key: "p",
                modifierMask: UserKeyboardShortcut.command | UserKeyboardShortcut.shift
            )!
        case .scheduled:
            return UserKeyboardShortcut(
                key: "t",
                modifierMask: UserKeyboardShortcut.command | UserKeyboardShortcut.shift
            )!
        case .review:
            return UserKeyboardShortcut(
                key: "g",
                modifierMask: UserKeyboardShortcut.control | UserKeyboardShortcut.shift
            )!
        case .sideChat:
            return UserKeyboardShortcut(
                key: "s",
                modifierMask: UserKeyboardShortcut.option | UserKeyboardShortcut.command
            )!
        case .simulator:
            return UserKeyboardShortcut(
                key: "e",
                modifierMask: UserKeyboardShortcut.option | UserKeyboardShortcut.command
            )!
        case .files:
            return UserKeyboardShortcut(key: "p", modifierMask: UserKeyboardShortcut.command)!
        case .browser:
            return UserKeyboardShortcut(key: "t", modifierMask: UserKeyboardShortcut.command)!
        case .terminal:
            return UserKeyboardShortcut(key: "`", modifierMask: UserKeyboardShortcut.control)!
        }
    }
}

/// A serializable shortcut value. The stored representation is deliberately
/// small (`key|modifierMask`) so it remains compatible with the app settings
/// JSON and can be safely ignored if a future version encounters bad data.
public struct UserKeyboardShortcut: Codable, Equatable, Hashable, Sendable {
    public static let command: UInt8 = 1 << 0
    public static let option: UInt8 = 1 << 1
    public static let shift: UInt8 = 1 << 2
    public static let control: UInt8 = 1 << 3
    public static let allModifiers: UInt8 = command | option | shift | control

    public let key: String
    public let modifierMask: UInt8

    public init?(key: String, modifierMask: UInt8) {
        guard key.count == 1,
              modifierMask != 0,
              modifierMask & Self.allModifiers == modifierMask else {
            return nil
        }
        self.key = key.lowercased()
        self.modifierMask = modifierMask
    }

    public init?(storedValue: String) {
        let pieces = storedValue.split(separator: "|", omittingEmptySubsequences: false)
        guard pieces.count == 2, let mask = UInt8(pieces[1]) else { return nil }
        self.init(key: String(pieces[0]), modifierMask: mask)
    }

    public var storedValue: String { "\(key)|\(modifierMask)" }

    public var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifierMask & Self.command != 0 { result.insert(.command) }
        if modifierMask & Self.option != 0 { result.insert(.option) }
        if modifierMask & Self.shift != 0 { result.insert(.shift) }
        if modifierMask & Self.control != 0 { result.insert(.control) }
        return result
    }

    public var swiftUIShortcut: KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(Character(key)), modifiers: eventModifiers)
    }

    public var displayValue: String {
        var value = ""
        if modifierMask & Self.command != 0 { value += "⌘" }
        if modifierMask & Self.option != 0 { value += "⌥" }
        if modifierMask & Self.shift != 0 { value += "⇧" }
        if modifierMask & Self.control != 0 { value += "⌃" }
        value += displayKey
        return value
    }

    @MainActor
    public init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard let characters = event.charactersIgnoringModifiers,
              let key = characters.first,
              !flags.isEmpty else {
            return nil
        }
        self.init(
            key: String(key),
            modifierMask: Self.modifierMask(for: flags)
        )
    }

    private var displayKey: String {
        switch key {
        case " ": return "Space"
        case "\r", "\n": return "↩"
        case "\t": return "⇥"
        case "\u{7f}": return "⌫"
        default: return key.uppercased()
        }
    }

    private static func modifierMask(for flags: NSEvent.ModifierFlags) -> UInt8 {
        var result: UInt8 = 0
        if flags.contains(.command) { result |= Self.command }
        if flags.contains(.option) { result |= Self.option }
        if flags.contains(.shift) { result |= Self.shift }
        if flags.contains(.control) { result |= Self.control }
        return result
    }
}

public enum KeyboardShortcutUpdateResult: Equatable, Sendable {
    case saved
    case conflict(KeyboardShortcutAction)
}
