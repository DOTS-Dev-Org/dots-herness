// Copyright (c) 2026 DOTS
// Native keyboard shortcut editor for Settings > General.

import AppKit
import SwiftUI
import DotsHarnessCore

struct KeyboardShortcutsSettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var capture: ShortcutCaptureSession
    private let onClose: () -> Void

    init(model: AppModel, onClose: @escaping () -> Void = {}) {
        self.model = model
        _capture = StateObject(wrappedValue: ShortcutCaptureSession(model: model))
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(AppCopy.text("settings.shortcuts"))
                        .font(.title2.weight(.semibold))
                    Text(AppCopy.text("settings.shortcuts.hint"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.bordered)
                .help(AppCopy.text("common.done"))
                .accessibilityLabel(AppCopy.text("common.done"))
            }
            .padding(.bottom, 18)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(KeyboardShortcutAction.allCases) { action in
                        shortcutRow(action)
                        if action != KeyboardShortcutAction.allCases.last {
                            Divider()
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            HStack(alignment: .center, spacing: 12) {
                if let conflictMessage = capture.conflictMessage {
                    Label(conflictMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(AppCopy.text("settings.shortcuts.reset")) {
                    model.resetKeyboardShortcuts()
                    capture.clearConflict()
                }
            }
            .padding(.top, 14)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .onAppear {
            capture.start()
        }
        .onDisappear {
            capture.stop()
        }
    }

    private func shortcutRow(_ action: KeyboardShortcutAction) -> some View {
        HStack(spacing: 14) {
            Label(action.title, systemImage: action.systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                capture.beginRecording(action)
            } label: {
                Text(
                    capture.recordingAction == action
                        ? AppCopy.text("settings.shortcuts.pressKeys")
                        : model.shortcut(for: action).displayValue
                )
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .frame(minWidth: 126)
            }
            .buttonStyle(.bordered)
            .help(AppCopy.text("settings.shortcuts.pressKeys"))
            .accessibilityLabel(action.title)
            .accessibilityValue(
                capture.recordingAction == action
                    ? AppCopy.text("settings.shortcuts.pressKeys")
                    : model.shortcut(for: action).displayValue
            )
        }
        .padding(.vertical, 9)
    }

}

@MainActor
private final class ShortcutCaptureSession: ObservableObject {
    @Published private(set) var recordingAction: KeyboardShortcutAction?
    @Published private(set) var conflictMessage: String?

    private let model: AppModel
    private var monitor: Any?

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.recordingAction else { return event }

            // Escape cancels the current capture instead of becoming a shortcut.
            if event.keyCode == 53 {
                self.recordingAction = nil
                self.conflictMessage = nil
                return nil
            }

            // While recording, consume the event even when it is not a supported
            // shortcut so a command in the app menu cannot fire accidentally.
            guard let shortcut = UserKeyboardShortcut(event: event) else { return nil }
            self.recordingAction = nil
            switch self.model.updateShortcut(shortcut, for: action) {
            case .saved:
                self.conflictMessage = nil
            case .conflict(let existingAction):
                self.conflictMessage = AppCopy.format(
                    "settings.shortcuts.conflict",
                    shortcut.displayValue,
                    existingAction.title
                )
            }
            return nil
        }
    }

    func beginRecording(_ action: KeyboardShortcutAction) {
        conflictMessage = nil
        recordingAction = action
    }

    func clearConflict() {
        conflictMessage = nil
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        recordingAction = nil
        conflictMessage = nil
    }
}
