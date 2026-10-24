// Copyright (c) 2026 DOTS
// Voice input, speech synthesis and local model downloads.

import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import HarnessPluginKit

@MainActor
extension AppModel {
    public func ensureVoiceRuntimeReady() {
        refreshVoiceModel()
        refreshSpeechModel()
        prewarmNemotron()
    }

    public func refreshVoiceModel() {
        let provider = voiceProvider
        guard provider.isFileBacked,
              voiceModelState(for: provider) != .downloading,
              voiceModelState(for: provider) != .paused else { return }
        switch provider {
        case .whisperTinyQ5:
            if voice.selectedModel.id != LocalVoiceModel.whisperTinyQ5.id {
                voice.configure(model: .whisperTinyQ5)
            }
            setVoiceModelState(voice.isModelInstalled ? .installed : .notInstalled, for: provider)
        case .whisperLargeV3Turbo:
            if voice.selectedModel.id != LocalVoiceModel.whisperLargeV3Turbo.id {
                voice.configure(model: .whisperLargeV3Turbo)
            }
            setVoiceModelState(voice.isModelInstalled ? .installed : .notInstalled, for: provider)
        case .customLocal:
            if voice.selectedModel.id != LocalVoiceModel.custom.id {
                voice.configure(model: .custom)
            }
            setVoiceModelState(voice.isModelInstalled ? .installed : .notInstalled, for: provider)
        case .nemotron:
            setVoiceModelState(nemotron.isReady ? .installed : .notInstalled, for: provider)
        case .api:
            break
        }
    }

    public func refreshSpeechModel() {
        setSpeechModelState(localSpeech.isModelInstalled ? .installed : .notInstalled)
    }

    public func requestVoiceModelDownload() {
        refreshVoiceModel()
        let provider = voiceProvider
        guard provider == .whisperTinyQ5 || provider == .whisperLargeV3Turbo || provider == .nemotron,
              !isVoiceModelInstalled,
              !isVoiceModelDownloading,
              !isVoiceDownloadPromptShowing else { return }

        isVoiceDownloadPromptShowing = true
        defer { isVoiceDownloadPromptShowing = false }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = VoiceCopy.downloadTitle
        let selected: LocalVoiceModel = switch provider {
        case .whisperTinyQ5: LocalVoiceModel.whisperTinyQ5
        case .whisperLargeV3Turbo: LocalVoiceModel.whisperLargeV3Turbo
        case .nemotron: LocalVoiceModel.nemotron
        case .customLocal, .api: LocalVoiceModel.whisperTinyQ5
        }
        alert.informativeText = VoiceCopy.downloadMessage(
            model: selected.name,
            size: selected.sizeLabel
        )
        if provider == .nemotron {
            alert.informativeText += "\n\n\(VoiceCopy.nemotronHint)"
        }
        alert.addButton(withTitle: VoiceCopy.downloadAction)
        alert.addButton(withTitle: VoiceCopy.downloadCancel)

        if alert.runModal() == .alertFirstButtonReturn {
            downloadVoiceModel()
        }
    }

    public func downloadVoiceModel() {
        let wasPaused = voiceModelState == .paused
        refreshVoiceModel()
        let provider = voiceProvider
        guard provider == .whisperTinyQ5 || provider == .whisperLargeV3Turbo || provider == .nemotron,
              !isVoiceModelInstalled,
              !isVoiceModelDownloading else { return }

        setVoiceModelState(.downloading, for: provider)
        let hadRuntime = provider == .nemotron
            ? (wasPaused ? voiceDownloadHadRuntime : nemotron.runtimeInstalled())
            : false
        voiceDownloadHadRuntime = hadRuntime
        voiceDownloadStopReason = nil
        let selectedModel: LocalVoiceModel = switch provider {
        case .whisperTinyQ5: LocalVoiceModel.whisperTinyQ5
        case .whisperLargeV3Turbo: LocalVoiceModel.whisperLargeV3Turbo
        case .nemotron: LocalVoiceModel.nemotron
        case .customLocal, .api: LocalVoiceModel.whisperTinyQ5
        }
        setVoiceModelProgress(
            FileDownloader.Progress(received: 0, expected: selectedModel.bytes),
            for: provider
        )
        let transcriber: LocalVoiceTranscriber? = switch provider {
        case .whisperTinyQ5:
            LocalVoiceTranscriber(paths: paths, model: .whisperTinyQ5)
        case .whisperLargeV3Turbo:
            LocalVoiceTranscriber(paths: paths, model: .whisperLargeV3Turbo)
        case .nemotron, .customLocal, .api:
            nil
        }

        voiceDownloadTask = Task { @MainActor [weak self] in
            do {
                guard let self else { return }
                let progressHandler: @Sendable (FileDownloader.Progress) -> Void = { [weak self] progress in
                    Task { @MainActor in
                        self?.setVoiceModelProgress(progress, for: provider)
                    }
                }
                if provider == .nemotron {
                    try await self.nemotron.ensureRuntime(progress: progressHandler)
                    try await self.nemotron.ensureModel(progress: progressHandler)
                } else if let transcriber {
                    try await transcriber.ensureModel(progress: progressHandler)
                }
                try Task.checkCancellation()
                let ready = provider == .nemotron ? self.nemotron.isReady : (transcriber?.isModelInstalled ?? false)
                self.setVoiceModelState(ready ? .installed : .failed(AppCopy.text("voice.modelIncomplete")), for: provider)
                self.prewarmNemotron()
                self.finishVoiceDownload()
            } catch {
                guard let self else { return }
                switch self.voiceDownloadStopReason {
                case .pause:
                    self.setVoiceModelState(.paused, for: provider)
                    self.voiceDownloadTask = nil
                    self.voiceDownloadStopReason = nil
                case .cancel:
                    self.discardVoiceDownload(for: provider, hadRuntime: hadRuntime)
                    self.setVoiceModelState(.notInstalled, for: provider)
                    self.finishVoiceDownload()
                case nil:
                    if provider == .nemotron && !hadRuntime {
                        try? self.nemotron.removeRuntimeArtifacts()
                    }
                    self.setVoiceModelState(.failed(error.localizedDescription), for: provider)
                    self.finishVoiceDownload()
                }
            }
        }
    }

    public func requestVoiceInputSetup() {
        refreshVoiceModel()
        guard !isVoiceReady else { return }

        switch voiceProvider {
        case .whisperTinyQ5:
            requestVoiceModelDownload()
        case .whisperLargeV3Turbo:
            requestVoiceModelDownload()
        case .customLocal:
            importLocalVoiceModel()
        case .nemotron:
            requestVoiceModelDownload()
        case .api:
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = VoiceCopy.setupTitle
            alert.informativeText = VoiceCopy.setupMessage
            alert.addButton(withTitle: VoiceCopy.openSettings)
            alert.addButton(withTitle: VoiceCopy.setupCancel)
            if alert.runModal() == .alertFirstButtonReturn {
                presentSettings()
            }
        }
    }

    public func setVoiceProvider(_ provider: VoiceInputProvider) {
        if voiceProvider == .nemotron, provider != .nemotron {
            nemotron.stop()
        }
        voiceProvider = provider
        if provider == .whisperTinyQ5 {
            voice.configure(model: .whisperTinyQ5)
        } else if provider == .whisperLargeV3Turbo {
            voice.configure(model: .whisperLargeV3Turbo)
        } else if provider == .customLocal {
            voice.configure(model: .custom)
        }
        refreshVoiceModel()
        prewarmNemotron()
        persistVoiceInputSettings()
    }

    private func prewarmNemotron() {
        guard voiceProvider == .nemotron, nemotron.isReady else { return }
        Task { @MainActor [weak self] in
            // The ASR server loads a model onto the GPU. Started at launch it competes
            // with the first frame; a few seconds later nobody notices, and dictation
            // pressed sooner still starts it on demand.
            try? await Task.sleep(for: .seconds(4))
            guard let self else { return }
            guard self.voiceProvider == .nemotron, self.nemotron.isReady else { return }
            do {
                _ = try self.nemotron.start()
                _ = await self.nemotron.waitUntilReady()
            } catch {
                // The transcription path reports the actionable error on use.
            }
        }
    }

    public func importLocalVoiceModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.allowsOtherFileTypes = true
        panel.prompt = VoiceCopy.importModel
        panel.message = VoiceCopy.localModelHint
        panel.begin { [weak self] response in
            guard response == .OK, let source = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    self.setVoiceProvider(.customLocal)
                    self.voice.configure(model: .custom)
                    try self.voice.importModel(from: source)
                    self.setVoiceModelState(.installed, for: .customLocal)
                    self.persistVoiceInputSettings()
                } catch {
                    self.setVoiceModelState(.failed(error.localizedDescription), for: .customLocal)
                }
            }
        }
    }

    public func makeVoiceStreamingSession(
        onUpdate: @escaping @Sendable (VoiceTranscriptUpdate) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws -> VoiceStreamingSession {
        switch voiceProvider {
        case .whisperTinyQ5, .whisperLargeV3Turbo, .customLocal:
            refreshVoiceModel()
            guard isVoiceModelInstalled else {
                throw NativeAgentError(AppCopy.text("voice.modelNotReady"))
            }
            let transcriber = voice
            return VoiceStreamingSession(
                mode: .rollingWhisper,
                batchTranscriber: { samples in
                    try await transcriber.transcribe(samples: samples, sampleRate: 16_000)
                },
                onUpdate: onUpdate,
                onError: onError
            )
        case .nemotron:
            guard nemotron.isReady else {
                throw NativeAgentError(AppCopy.text("voice.modelNotReady"))
            }
            _ = try nemotron.start()
            guard await nemotron.waitUntilReady() else {
                nemotron.stop()
                throw NativeAgentError(AppCopy.text("voice.runtime.notReady"))
            }
            let client = VoiceAPIRealtimeClient(
                configuration: VoiceAPIConfiguration(
                    endpoint: nemotron.serverURL.absoluteString,
                    apiKey: "",
                    model: "default"
                ),
                onUpdate: onUpdate,
                onError: onError
            )
            try await client.start()
            let runtime = nemotron
            return VoiceStreamingSession(
                mode: .realtime,
                realtimePush: { samples in client.send(samples: samples) },
                realtimeCommit: { client.commit() },
                realtimeCancel: { client.cancel() },
                onUpdate: onUpdate,
                onError: onError,
                onActivity: { runtime.noteActivity() }
            )
        case .api:
            let configuration = VoiceAPIConfiguration(
                endpoint: voiceAPIEndpoint,
                apiKey: voiceAPIKey,
                model: voiceAPIModel,
                realtimeEndpoint: voiceAPIRealtimeEndpoint
            )
            guard configuration.isConfigured else {
                throw NativeAgentError(AppCopy.text("voice.apiSettingsMissing"))
            }
            if !configuration.realtimeEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    let client = VoiceAPIRealtimeClient(
                        configuration: configuration,
                        onUpdate: onUpdate,
                        onError: onError
                    )
                    try await client.start()
                    return VoiceStreamingSession(
                        mode: .realtime,
                        realtimePush: { samples in client.send(samples: samples) },
                        realtimeCommit: { client.commit() },
                        realtimeCancel: { client.cancel() },
                        onUpdate: onUpdate,
                        onError: onError
                    )
                } catch {
                    // An incompatible or unavailable WebSocket endpoint falls back
                    // to the existing HTTP transcription path for this session.
                }
            }
            return VoiceStreamingSession(
                mode: .utteranceHTTP,
                batchTranscriber: { samples in
                    try await VoiceAPITranscriber.transcribe(
                        samples: samples,
                        sampleRate: 16_000,
                        configuration: configuration
                    )
                },
                onUpdate: onUpdate,
                onError: onError
            )
        }
    }

    /// Translates `text` into the app language (into English when it already is in
    /// it) with the lightest connected model at its lowest effort.
    public func translate(_ text: String) async throws -> String {
        let language = AppCopy.effectiveLanguage.nativeName
        let system = "Translate the user's text into \(language). If it is already in \(language), translate it into English. Output only the translation, nothing else."
        let response = try await router.completeCheapest(messages: [
            AgentMessage(role: .system, content: system),
            AgentMessage(role: .user, content: String(text.prefix(8000))),
        ])
        return response.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func toggleSpeech(_ text: String, messageID: String? = nil) {
        if speech.isSpeaking {
            speechRequestID = nil
            speechTask?.cancel()
            speechTask = nil
            speech.stop()
            return
        }

        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let requestID = UUID()
        speechRequestID = requestID
        speech.beginRemoteSpeech(messageID: messageID)
        speechTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.speechRequestID == requestID {
                    self.speechRequestID = nil
                    self.speechTask = nil
                }
            }

            do {
                let url: URL
                if self.localSpeech.isModelInstalled,
                   LocalSpeechSynthesizer.languageCode(for: text)?.hasPrefix("tr") == true {
                    url = try await self.localSpeech.synthesize(text)
                } else {
                    url = try await self.bridge.synthesizeSpeech(text)
                }
                guard !Task.isCancelled, self.speechRequestID == requestID else { return }
                if !self.speech.play(url, messageID: messageID) {
                    self.speech.speak(text, messageID: messageID)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.speechRequestID == requestID else { return }
                do {
                    let url = try await self.bridge.synthesizeSpeech(text)
                    guard !Task.isCancelled, self.speechRequestID == requestID else { return }
                    if !self.speech.play(url, messageID: messageID) {
                        self.speech.speak(text, messageID: messageID)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self.speech.speak(text, messageID: messageID)
                }
            }
        }
    }

    public func shutdownVoice() {
        speechRequestID = nil
        speechTask?.cancel()
        speechTask = nil
        createdSpeech?.stop()
        nemotron.stop()
    }

    /// Publishes only a real change. Every write to `voiceModelStates` re-evaluates
    /// each view observing the model, and startup refreshes it with the same value.
    private func setVoiceModelState(_ state: LocalVoiceModelState, for provider: VoiceInputProvider) {
        guard voiceModelState(for: provider) != state else { return }
        var states = voiceModelStates
        states[provider.rawValue] = state
        voiceModelStates = states
    }

    private func setVoiceModelProgress(_ progress: FileDownloader.Progress, for provider: VoiceInputProvider) {
        var progresses = voiceModelProgress
        progresses[provider.rawValue] = progress
        voiceModelProgress = progresses
    }

    private func setVoiceModelProgress(_ progress: FileDownloader.Progress, forKey key: String) {
        var progresses = voiceModelProgress
        progresses[key] = progress
        voiceModelProgress = progresses
    }

    private func discardVoiceDownload(for provider: VoiceInputProvider, hadRuntime: Bool) {
        switch provider {
        case .whisperTinyQ5:
            voice.configure(model: .whisperTinyQ5)
            try? voice.deleteModel()
        case .whisperLargeV3Turbo:
            voice.configure(model: .whisperLargeV3Turbo)
            try? voice.deleteModel()
        case .nemotron:
            try? nemotron.deleteModel()
            if !hadRuntime {
                try? nemotron.removeRuntimeArtifacts(includePartial: true)
            }
        case .customLocal, .api:
            break
        }
    }

    private func finishVoiceDownload() {
        voiceDownloadTask = nil
        voiceDownloadStopReason = nil
        voiceDownloadHadRuntime = false
    }

    private func setSpeechModelState(_ state: LocalVoiceModelState) {
        guard speechModelState != state else { return }
        var states = voiceModelStates
        states[LocalSpeechModel.turkishPiper.id] = state
        voiceModelStates = states
    }

    /// The common case (no legacy plaintext setting) only reads the stored key. A
    /// Keychain read blocks for milliseconds, so it runs off the main thread once the
    /// first frame is up; nothing needs the key before the user picks the API provider.
    func loadVoiceAPIKeyInBackground() {
        let vault = router.store.vault
        let id = Self.voiceCredentialID
        Task { @MainActor [weak self] in
            let stored = await Task.detached(priority: .utility) { try? vault.get(id) }.value
            guard let self, let stored, self.voiceAPIKey.isEmpty else { return }
            self.voiceAPIKey = stored
        }
    }

    func migrateVoiceAPIKey(legacy: String?) {
        // Nothing to migrate: defer the Keychain read (see loadVoiceAPIKeyInBackground).
        guard legacy != nil else {
            deferredVoiceKeyLoad = true
            return
        }
        do {
            if let stored = try router.store.vault.get(Self.voiceCredentialID) {
                voiceAPIKey = stored
                if legacy != nil {
                    host.settings.remove(Self.voiceCredentialID)
                    persistSettings()
                }
                return
            }
            guard let legacy, !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if legacy != nil {
                    host.settings.remove(Self.voiceCredentialID)
                    persistSettings()
                }
                return
            }
            try router.store.vault.set(legacy, for: Self.voiceCredentialID)
            guard try router.store.vault.get(Self.voiceCredentialID) == legacy else {
                throw ProviderStoreError.credentialUnavailable
            }
            voiceAPIKey = legacy
            host.settings.remove(Self.voiceCredentialID)
            persistSettings()
        } catch {
            voiceAPIKey = legacy ?? ""
            router.error = "Voice API key migration failed; the existing setting was preserved: \(error.localizedDescription)"
        }
    }

    private func persistVoiceInputSettings() {
        host.settings.set("voice.provider", .string(voiceProvider.rawValue))
        host.settings.set("voice.api.endpoint", .string(voiceAPIEndpoint))
        host.settings.set("voice.api.model", .string(voiceAPIModel))
        host.settings.set("voice.api.realtimeEndpoint", .string(voiceAPIRealtimeEndpoint))
        persistSettings()
    }
}
