// Copyright (c) 2026 DOTS
// Composer prompt text view and slash-command palette.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DotsHarnessCore
import HarnessPluginKit

struct PromptTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    let onSubmit: (PromptMode) -> Void
    let onAcceptSlashCommand: () -> Bool
    let onMoveSlashCommand: (Int) -> Bool
    let followUpSuggestion: String?
    var onDropFiles: (([URL]) -> Void)? = nil
    var onDropImageData: ((Data, String) -> Void)? = nil
    var onPasteImage: ((Data) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let editor = PromptNSTextView()
        editor.delegate = context.coordinator
        editor.onSubmit = onSubmit
        editor.onAcceptSlashCommand = onAcceptSlashCommand
        editor.onMoveSlashCommand = onMoveSlashCommand
        editor.followUpSuggestion = followUpSuggestion
        editor.onDropFiles = onDropFiles
        editor.onDropImageData = onDropImageData
        editor.onPasteImage = onPasteImage
        editor.onSuggestionAccepted = { [weak coordinator = context.coordinator] text in
            coordinator?.suggestionAccepted(text)
        }
        editor.string = text
        editor.isEditable = isEnabled
        editor.isRichText = false
        editor.font = .systemFont(ofSize: 15)
        editor.textContainerInset = NSSize(width: 5, height: 5)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        // Kill the default 5pt line-fragment padding so the caret sits flush
        // with the placeholder's leading edge (9pt SwiftUI + 5pt inset = 14pt).
        editor.textContainer?.lineFragmentPadding = 0
        editor.drawsBackground = false

        scrollView.documentView = editor
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let editor = nsView.documentView as? PromptNSTextView else { return }
        context.coordinator.update(parent: self)
        editor.onSubmit = onSubmit
        editor.onAcceptSlashCommand = onAcceptSlashCommand
        editor.onMoveSlashCommand = onMoveSlashCommand
        editor.followUpSuggestion = followUpSuggestion
        editor.onDropFiles = onDropFiles
        editor.onDropImageData = onDropImageData
        editor.onPasteImage = onPasteImage
        editor.isEditable = isEnabled

        if editor.string != text {
            editor.string = text
        }
        editor.setAccessibilityHelp(
            text.isEmpty && followUpSuggestion != nil ? AppCopy.text("composer.followUp.hint") : nil
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private var parent: PromptTextEditor

        init(_ parent: PromptTextEditor) {
            self.parent = parent
        }

        func update(parent: PromptTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? PromptNSTextView else { return }
            parent.text = editor.string
        }

        func suggestionAccepted(_ text: String) {
            parent.text = text
        }
    }
}

final class PromptNSTextView: NSTextView {
    var onSubmit: ((PromptMode) -> Void)?
    var onAcceptSlashCommand: (() -> Bool)?
    var onMoveSlashCommand: ((Int) -> Bool)?
    var onSuggestionAccepted: ((String) -> Void)?
    var followUpSuggestion: String?
    var onDropFiles: (([URL]) -> Void)?
    var onDropImageData: ((Data, String) -> Void)?
    var onPasteImage: ((Data) -> Void)?

    private enum ImagePasteboardSource: Sendable {
        case data(Data, typeIdentifier: String)
        case file(URL)
    }

    // An in-window card drawn over the editor keeps its own cursor: AppKit
    // tracking ignores what SwiftUI draws on top, hit testing does not.
    private func isCovered(_ event: NSEvent) -> Bool {
        guard let content = window?.contentView,
              let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
        else { return false }
        return !hit.isDescendant(of: self)
    }
    override func mouseMoved(with event: NSEvent) {
        if !isCovered(event) { super.mouseMoved(with: event) }
    }
    override func cursorUpdate(with event: NSEvent) {
        if !isCovered(event) { super.cursorUpdate(with: event) }
    }

    override func paste(_ sender: Any?) {
        guard pasteImage(from: .general) else {
            super.paste(sender)
            return
        }
    }

    @discardableResult
    func pasteImage(from pasteboard: NSPasteboard) -> Bool {
        guard let onPasteImage,
              let source = Self.imageSource(from: pasteboard) else { return false }
        Task { @MainActor in
            let png = await Task.detached(priority: .utility) {
                let data: Data?
                switch source {
                case .data(let imageData, _):
                    data = imageData
                case .file(let url):
                    data = try? Data(contentsOf: url)
                }
                return data.flatMap(Self.pngImageData(from:))
            }.value
            guard let png else { return }
            onPasteImage(png)
        }
        return true
    }

    private static func imageSource(from pasteboard: NSPasteboard) -> ImagePasteboardSource? {
        let imageTypes = [UTType.png, .tiff, .jpeg, .heic, .gif].map {
            NSPasteboard.PasteboardType($0.identifier)
        }
        for item in pasteboard.pasteboardItems ?? [] {
            for type in imageTypes {
                if let data = item.data(forType: type) {
                    return .data(data, typeIdentifier: type.rawValue)
                }
            }
        }

        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        if let url = fileURLs.first(where: {
            UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true
        }) {
            return .file(url)
        }

        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation else { return nil }
        return .data(tiff, typeIdentifier: UTType.tiff.identifier)
    }

    static func pngImageData(from pasteboard: NSPasteboard) -> Data? {
        let imageTypes = [UTType.png, .tiff, .jpeg, .heic, .gif].map {
            NSPasteboard.PasteboardType($0.identifier)
        }
        for item in pasteboard.pasteboardItems ?? [] {
            for type in imageTypes {
                guard let data = item.data(forType: type),
                      let png = pngImageData(from: data) else { continue }
                return png
            }
        }

        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        for url in fileURLs where UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            guard let data = try? Data(contentsOf: url),
                  let png = pngImageData(from: data) else { continue }
            return png
        }

        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation else { return nil }
        return pngImageData(from: tiff)
    }

    nonisolated private static func pngImageData(from data: Data) -> Data? {
        ImageAttachmentData.png(from: data)
    }

    // NSTextView would otherwise swallow a file drop and insert its path as text,
    // so the surrounding SwiftUI `onDrop` never sees it.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty, let onDropFiles {
            onDropFiles(urls)
            return true
        }

        guard let onDropImageData,
              case let .data(data, typeIdentifier) = Self.imageSource(from: sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        onDropImageData(data, typeIdentifier)
        return true
    }

    func acceptFollowUpSuggestion() -> Bool {
        guard string.isEmpty,
              !hasMarkedText(),
              let suggestion = followUpSuggestion,
              !suggestion.isEmpty,
              let textStorage else { return false }

        let acceptedTextColor = NSColor.labelColor
        let acceptedText = NSAttributedString(
            string: suggestion,
            attributes: [
                .foregroundColor: acceptedTextColor,
                .font: font ?? NSFont.systemFont(ofSize: 15),
            ]
        )
        textStorage.beginEditing()
        textStorage.setAttributedString(acceptedText)
        textStorage.endEditing()
        setSelectedRange(NSRange(location: (suggestion as NSString).length, length: 0))
        var acceptedTypingAttributes = typingAttributes
        acceptedTypingAttributes[.foregroundColor] = acceptedTextColor
        typingAttributes = acceptedTypingAttributes
        setAccessibilityHelp(nil)
        onSuggestionAccepted?(suggestion)
        return true
    }

    override func keyDown(with event: NSEvent) {
        let keyModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasTextModifiers = keyModifiers.contains(.command)
            || keyModifiers.contains(.control)
            || keyModifiers.contains(.option)
            || keyModifiers.contains(.shift)

        switch event.keyCode {
        case 48 where !hasTextModifiers:
            if onAcceptSlashCommand?() == true { return }
            if acceptFollowUpSuggestion() { return }
        case 126 where !hasTextModifiers:
            if onMoveSlashCommand?(-1) == true { return }
        case 125 where !hasTextModifiers:
            if onMoveSlashCommand?(1) == true { return }
        default:
            break
        }

        guard event.keyCode == 36 || event.keyCode == 76 else {
            super.keyDown(with: event)
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) || modifiers.contains(.control) {
            onSubmit?(.steer)
        } else if modifiers.contains(.shift) == false {
            onSubmit?(.queue)
        } else {
            super.keyDown(with: event)
        }
    }
}

enum SlashCommandKind: Equatable {
    case setting
    case media
    case skill
    case template
}

struct SlashCommand: Identifiable {
    var id: String
    var title: String
    var detail: String
    var icon: String
    var kind: SlashCommandKind
    var command: String? = nil
}

struct SlashCommandPalette: View {
    let settings: [SlashCommand]
    let media: [SlashCommand]
    let templates: [SlashCommand]
    let skills: [SlashCommand]
    @Binding var highlightedID: String?
    let onSelect: (SlashCommand) -> Void

    private var commands: [SlashCommand] {
        settings + media + templates + skills
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if !settings.isEmpty {
                    sectionTitle(AppCopy.text("composer.settings"))
                    ForEach(settings) { command in
                        commandRow(command)
                    }
                }

                if !media.isEmpty {
                    sectionTitle(AppCopy.text("composer.generate"))
                        .padding(.top, 7)
                    ForEach(media) { command in
                        commandRow(command)
                    }
                }

                if !templates.isEmpty {
                    sectionTitle(AppCopy.text("composer.prompts"))
                        .padding(.top, 7)
                    ForEach(templates) { command in
                        commandRow(command)
                    }
                }

                if !skills.isEmpty {
                    sectionTitle(AppCopy.text("composer.skills"))
                        .padding(.top, 7)
                    ForEach(skills) { command in
                        commandRow(command)
                    }
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 360)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .onAppear {
            if !commands.contains(where: { $0.id == highlightedID }) {
                highlightedID = commands.first?.id
            }
        }
        .onChange(of: commands.map(\.id)) { _, ids in
            if !ids.contains(where: { $0 == highlightedID }) {
                highlightedID = ids.first
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
    }

    private func commandRow(_ command: SlashCommand) -> some View {
        Button {
            onSelect(command)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: command.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 17)
                    .foregroundStyle(.secondary)
                Text(command.title)
                    .lineLimit(1)
                Spacer(minLength: 10)
                Text(command.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if command.kind == .skill {
                    Text(AppCopy.text("composer.personal"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .frame(minHeight: 29)
            .background(
                highlightedID == command.id ? Color.primary.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isInside in
            if isInside { highlightedID = command.id }
        }
    }
}
