// Copyright (c) 2026 DOTS
// OpenAI-compatible local/remote audio transcription.

import Foundation

public enum VoiceAPITranscriber {
    public static func transcribe(
        samples: [Float],
        sampleRate: Double,
        configuration: VoiceAPIConfiguration
    ) async throws -> String {
        guard configuration.isConfigured else {
            throw NativeAgentError(AppCopy.text("voice.apiSettingsMissing"))
        }

        let endpoint = try transcriptionURL(from: configuration.endpoint)
        let boundary = "DotsHarness-\(UUID().uuidString)"
        let audio = makeWAV(samples: samples, sampleRate: sampleRate)
        var body = Data()
        appendField("model", value: configuration.model, boundary: boundary, to: &body)
        appendField("response_format", value: "json", boundary: boundary, to: &body)
        appendFile(
            name: "file",
            filename: "recording.wav",
            mimeType: "audio/wav",
            data: audio,
            boundary: boundary,
            to: &body
        )
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = String(data: data, encoding: .utf8) ?? AppCopy.format("voice.httpStatus", status)
            throw NativeAgentError(AppCopy.format("voice.apiError", String(detail.prefix(220))))
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            throw NativeAgentError(AppCopy.text("voice.apiNoTranscript"))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func transcriptionURL(from rawValue: String) throws -> URL {
        guard var components = URLComponents(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme != nil,
              components.host != nil else {
            throw NativeAgentError(AppCopy.text("voice.invalidAPIURL"))
        }

        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/audio/transcriptions") {
            if path.isEmpty { path = "/v1" }
            if !path.hasSuffix("/v1") { path += "/v1" }
            path += "/audio/transcriptions"
        }
        components.path = path
        guard let url = components.url else {
            throw NativeAgentError(AppCopy.text("voice.invalidAPIURL"))
        }
        return url
    }

    private static func appendField(_ name: String, value: String, boundary: String, to data: inout Data) {
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        data.append(Data("\(value)\r\n".utf8))
    }

    private static func appendFile(
        name: String,
        filename: String,
        mimeType: String,
        data fileData: Data,
        boundary: String,
        to data: inout Data
    ) {
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        data.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        data.append(fileData)
        data.append(Data("\r\n".utf8))
    }

    private static func makeWAV(samples: [Float], sampleRate: Double) -> Data {
        let rate = max(1, Int(sampleRate.rounded()))
        var pcm = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clipped = max(-1, min(1, sample))
            pcm.appendLittleEndian(Int16(clipped * 32_767))
        }

        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(rate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        var wav = Data("RIFF".utf8)
        wav.appendLittleEndian(UInt32(36 + pcm.count))
        wav.append(Data("WAVEfmt ".utf8))
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(channels)
        wav.appendLittleEndian(UInt32(rate))
        wav.appendLittleEndian(byteRate)
        wav.appendLittleEndian(blockAlign)
        wav.appendLittleEndian(bitsPerSample)
        wav.append(Data("data".utf8))
        wav.appendLittleEndian(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
