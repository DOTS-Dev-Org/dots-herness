// Copyright (c) 2026 DOTS
// Persisted voice engine choices shared by the core and UI layers.

import Foundation

public enum VoiceInputProvider: String, CaseIterable, Hashable, Identifiable, Sendable {
    case whisperLargeV3Turbo = "whisper-large-v3-turbo"
    case nemotron = "nemotron-3.5-asr"
    case customLocal = "custom-local"
    case api = "api"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .whisperLargeV3Turbo: return VoiceCopy.sourceWhisper
        case .nemotron: return VoiceCopy.sourceNemotron
        case .customLocal: return VoiceCopy.sourceCustomLocal
        case .api: return VoiceCopy.sourceAPI
        }
    }

    public var isFileBacked: Bool {
        self == .whisperLargeV3Turbo || self == .nemotron || self == .customLocal
    }

    public var sizeLabel: String {
        switch self {
        case .whisperLargeV3Turbo: return VoiceCopy.whisperTurboSize
        case .nemotron: return VoiceCopy.nemotronSize
        case .customLocal: return VoiceCopy.customLocalSize
        case .api: return VoiceCopy.customAPISize
        }
    }
}

public struct VoiceAPIConfiguration: Equatable, Sendable {
    public var endpoint: String
    public var apiKey: String
    public var model: String

    public init(endpoint: String, apiKey: String, model: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
    }

    public var isConfigured: Bool {
        !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
