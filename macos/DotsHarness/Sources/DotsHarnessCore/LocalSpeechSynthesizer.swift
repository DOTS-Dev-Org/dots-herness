// Copyright (c) 2026 DOTS
// Offline text-to-speech using the macOS system voices.

@preconcurrency import AVFoundation
import Combine
import Foundation
import NaturalLanguage

@MainActor
public final class LocalSpeechSynthesizer: NSObject, ObservableObject {
    @Published public private(set) var activeMessageID: String?

    private let synthesizer = AVSpeechSynthesizer()

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public var isSpeaking: Bool {
        synthesizer.isSpeaking
    }

    public func toggle(_ text: String, messageID: String? = nil) {
        if synthesizer.isSpeaking {
            stop()
        } else {
            speak(text, messageID: messageID)
        }
    }

    public func speak(_ text: String, messageID: String? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        synthesizer.stopSpeaking(at: .immediate)
        activeMessageID = messageID

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        synthesizer.speak(utterance)
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        activeMessageID = nil
    }

    /// Returns the BCP-47 voice code selected for a text body, when detected.
    /// The system voice list decides whether that language is installed.
    nonisolated public static func languageCode(for text: String) -> String? {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else {
            return nil
        }
        switch language.rawValue {
        case "tr": return "tr-TR"
        case "en": return "en-US"
        default: return language.rawValue
        }
    }

    private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        guard let language = languageCode(for: text) else { return nil }
        if let exact = AVSpeechSynthesisVoice(language: language) {
            return exact
        }
        let baseLanguage = String(language.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .first { $0.language.hasPrefix(baseLanguage) }
    }

}

extension LocalSpeechSynthesizer: @preconcurrency AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        activeMessageID = nil
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        activeMessageID = nil
    }
}
