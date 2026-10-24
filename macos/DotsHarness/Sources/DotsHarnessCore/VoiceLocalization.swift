// Copyright (c) 2026 DOTS
// Localized copy for the voice input surface.

import Foundation

public enum VoiceCopy {
    private static func text(_ key: String) -> String {
        AppCopy.text(key)
    }

    public static var statusNotInstalled: String { text("voice.status.notInstalled") }
    public static var statusDownloading: String { text("voice.status.downloading") }
    public static var statusInstalled: String { text("voice.status.installed") }
    public static var statusFailed: String { text("voice.status.failed") }

    public static var downloadTitle: String { text("voice.download.title") }
    public static var downloadAction: String { text("voice.download.action") }
    public static var downloadCancel: String { text("voice.download.cancel") }
    public static var downloadMessageTemplate: String { text("voice.download.message") }

    public static var setupTitle: String { text("voice.setup.title") }
    public static var openSettings: String { text("voice.setup.openSettings") }
    public static var setupCancel: String { text("voice.setup.cancel") }
    public static var setupMessage: String { text("voice.setup.message") }
    public static var sourceWhisperTiny: String { text("voice.source.whisperTiny") }
    public static var sourceWhisper: String { text("voice.source.whisper") }
    public static var sourceNemotron: String { text("voice.source.nemotron") }
    public static var sourceCustomLocal: String { text("voice.source.customLocal") }
    public static var sourceAPI: String { text("voice.source.api") }
    public static var statusPaused: String { text("voice.status.paused") }
    public static var whisperTinySize: String { text("voice.model.whisperTinySize") }
    public static var whisperTurboSize: String { text("voice.model.whisperTurboSize") }
    public static var nemotronSize: String { text("voice.model.nemotronSize") }
    public static var customLocalSize: String { text("voice.model.customLocalSize") }
    public static var customAPISize: String { text("voice.model.customAPISize") }
    public static var downloadModel: String { text("voice.local.download") }
    public static var importModel: String { text("voice.local.import") }
    public static var deleteModel: String { text("voice.local.delete") }
    public static var localModelHint: String { text("voice.local.hint") }
    public static var nemotronHint: String { text("voice.nemotron.hint") }
    public static var endpoint: String { text("voice.api.endpoint") }
    public static var apiKey: String { text("voice.api.key") }
    public static var realtimeEndpoint: String { text("voice.api.realtimeEndpoint") }
    public static var microphoneReady: String { text("voice.input.ready") }
    public static var microphoneNeedsModel: String { text("voice.input.needsModel") }
    public static var microphoneNeedsSetup: String { text("voice.input.needsSetup") }
    public static var downloading: String { text("voice.input.downloading") }

    public static func downloadMessage(model: String, size: String) -> String {
        String(format: downloadMessageTemplate, model, size)
    }
}
