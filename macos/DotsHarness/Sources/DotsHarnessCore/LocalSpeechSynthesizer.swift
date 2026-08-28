// Copyright (c) 2026 DOTS
// Text-to-speech playback using provider audio with a macOS voice fallback.

@preconcurrency import AVFoundation
import Combine
import Foundation
import NaturalLanguage

@MainActor
public final class LocalSpeechSynthesizer: NSObject, ObservableObject {
    @Published public private(set) var activeMessageID: String?

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var remoteAudioPending = false
    private var activeUtterance: AVSpeechUtterance?

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public var isSpeaking: Bool {
        synthesizer.isSpeaking || audioPlayer?.isPlaying == true || remoteAudioPending
    }

    public func toggle(_ text: String, messageID: String? = nil) {
        if isSpeaking {
            stop()
        } else {
            speak(text, messageID: messageID)
        }
    }

    public func speak(_ text: String, messageID: String? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        synthesizer.stopSpeaking(at: .immediate)
        activeUtterance = nil
        audioPlayer?.stop()
        audioPlayer = nil
        remoteAudioPending = false
        activeMessageID = messageID

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        utterance.pitchMultiplier = 1
        utterance.volume = 1
        utterance.preUtteranceDelay = 0.05
        utterance.postUtteranceDelay = 0.1
        activeUtterance = utterance
        synthesizer.speak(utterance)
    }

    public func beginRemoteSpeech(messageID: String? = nil) {
        activeUtterance = nil
        stop()
        remoteAudioPending = true
        activeMessageID = messageID
    }

    @discardableResult
    public func play(_ url: URL, messageID: String? = nil) -> Bool {
        synthesizer.stopSpeaking(at: .immediate)
        activeUtterance = nil
        audioPlayer?.stop()
        remoteAudioPending = false

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            audioPlayer = player
            player.prepareToPlay()
            guard player.play() else {
                audioPlayer = nil
                activeMessageID = nil
                return false
            }
            activeMessageID = messageID
            return true
        } catch {
            audioPlayer = nil
            activeMessageID = nil
            return false
        }
    }

    public func stop() {
        activeUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        remoteAudioPending = false
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
        let normalizedLanguage = language.lowercased()
        let baseLanguage = normalizedLanguage.split(separator: "-").first.map(String.init) ?? normalizedLanguage
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            let voiceLanguage = voice.language.lowercased()
            let sameLanguage = voiceLanguage == normalizedLanguage
                || voiceLanguage.hasPrefix("\(baseLanguage)-")
            return sameLanguage && !voice.voiceTraits.contains(.isNoveltyVoice)
        }

        return voices.sorted { left, right in
            if left.quality.rawValue != right.quality.rawValue {
                return left.quality.rawValue > right.quality.rawValue
            }
            return left.language.lowercased() == normalizedLanguage
                && right.language.lowercased() != normalizedLanguage
        }.first ?? AVSpeechSynthesisVoice(language: language)
    }

}

extension LocalSpeechSynthesizer: @preconcurrency AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard activeUtterance === utterance else { return }
        activeUtterance = nil
        activeMessageID = nil
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard activeUtterance === utterance else { return }
        activeUtterance = nil
        activeMessageID = nil
    }
}

extension LocalSpeechSynthesizer: @preconcurrency AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard audioPlayer === player else { return }
        audioPlayer = nil
        activeMessageID = nil
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard audioPlayer === player else { return }
        audioPlayer = nil
        activeMessageID = nil
    }
}
