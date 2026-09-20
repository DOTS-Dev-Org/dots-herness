// Copyright (c) 2026 DOTS
// Inline terminal transcript and audio playback for the conversation.

import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers
import DotsHarnessCore

struct TerminalView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        // ponytail: keep the existing transcript renderer; add full ANSI terminal
        // emulation only if full-screen TUI fidelity becomes a requirement.
        TerminalTranscriptView(
            output: session.output.isEmpty ? AppCopy.text("conversation.startingShell") : session.output,
            isInputEnabled: session.isRunning,
            onInput: session.sendInput
        )
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct TerminalTranscriptView: NSViewRepresentable {
    let output: String
    let isInputEnabled: Bool
    let onInput: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let editor = TerminalNSTextView()
        editor.onInput = onInput
        editor.isInputEnabled = isInputEnabled
        editor.string = output
        editor.isEditable = true
        editor.isSelectable = true
        editor.isRichText = false
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textColor = .textColor
        editor.insertionPointColor = .textColor
        editor.textContainerInset = NSSize(width: 14, height: 12)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.drawsBackground = false
        editor.setSelectedRange(NSRange(location: output.utf16.count, length: 0))

        scrollView.documentView = editor
        editor.scrollToEndOfDocument(nil)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let editor = nsView.documentView as? TerminalNSTextView else { return }
        editor.onInput = onInput
        editor.isInputEnabled = isInputEnabled

        guard editor.string != output else { return }
        editor.string = output
        editor.setSelectedRange(NSRange(location: output.utf16.count, length: 0))
        editor.scrollToEndOfDocument(nil)
    }
}

final class TerminalNSTextView: NSTextView {
    var onInput: ((String) -> Void)?
    var isInputEnabled = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copy(nil)
            case "v": paste(nil)
            case "a": selectAll(nil)
            default: break
            }
            return
        }

        guard isInputEnabled else { return }

        if let input = input(for: event, modifiers: modifiers) {
            onInput?(input)
            return
        }

        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        guard isInputEnabled,
              let value = NSPasteboard.general.string(forType: .string),
              !value.isEmpty else { return }
        onInput?(value)
    }

    private func input(for event: NSEvent, modifiers: NSEvent.ModifierFlags) -> String? {
        if modifiers.contains(.control),
           let scalar = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first {
            let value = scalar.value == 0x20 ? 0 : scalar.value & 0x1F
            return String(UnicodeScalar(value)!)
        }

        switch event.keyCode {
        case 36, 76: return "\r"
        case 48: return "\t"
        case 51: return "\u{7f}"
        case 53: return "\u{1b}"
        case 115: return "\u{1b}[H"
        case 119: return "\u{1b}[F"
        case 123: return "\u{1b}[D"
        case 124: return "\u{1b}[C"
        case 125: return "\u{1b}[B"
        case 126: return "\u{1b}[A"
        default: break
        }

        return event.characters
    }
}

@MainActor
final class InlineAudioPlayback: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: TimeInterval = 0

    private let url: URL
    private var player: AVAudioPlayer?
    private var timer: Timer?

    init(url: URL) {
        self.url = url
    }

    func load() {
        guard player == nil else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
            duration = player.duration
        } catch {
            self.player = nil
        }
    }

    func toggle() {
        load()
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else if player.play() {
            isPlaying = true
            startTimer()
        }
    }

    func seek(to value: Double) {
        guard let player, duration > 0 else { return }
        player.currentTime = min(duration, max(0, value * duration))
        progress = player.currentTime / duration
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        progress = 0
        isPlaying = false
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                if player.duration > 0 {
                    self.progress = min(1, player.currentTime / player.duration)
                }
                if !player.isPlaying, self.progress >= 1 {
                    self.isPlaying = false
                    self.stopTimer()
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

struct InlineAudioPlayer: View {
    @StateObject private var playback: InlineAudioPlayback

    init(url: URL) {
        _playback = StateObject(wrappedValue: InlineAudioPlayback(url: url))
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                playback.toggle()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(playback.isPlaying ? "Pause audio" : "Play audio")

            Slider(
                value: Binding(
                    get: { playback.progress },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...1
            )
            .disabled(playback.duration <= 0)

            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 620)
        .onAppear { playback.load() }
        .onDisappear { playback.stop() }
    }
}
