// Copyright (c) 2026 DOTS
// Music studio: a song as a project — a script, sections with lyrics, artists,
// and tracks that each keep their own audio file so they can be mixed and replaced.

import Foundation
import PluginRuntime

public struct MusicArtist: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// The voice in words ("warm alto, breathy"); sent with every vocal the artist sings.
    public var style: String

    public init(id: String = UUID().uuidString, name: String, style: String = "") {
        self.id = id
        self.name = name
        self.style = style
    }
}

public struct MusicLine: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    /// Who sings it. Nil leaves the line unsung until someone is picked.
    public var artistID: String?
    public var text: String

    public init(id: String = UUID().uuidString, artistID: String? = nil, text: String = "") {
        self.id = id
        self.artistID = artistID
        self.text = text
    }
}

public struct MusicSection: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var bars: Int
    public var lines: [MusicLine]

    public init(id: String = UUID().uuidString, name: String, bars: Int = 8, lines: [MusicLine] = []) {
        self.id = id
        self.name = name
        self.bars = bars
        self.lines = lines
    }
}

/// One audio file on a track.
public struct MusicClip: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    /// The section it covers; nil spans the whole song.
    public var sectionID: String?
    /// File name inside the project's `assets` folder.
    public var assetName: String

    public init(id: String = UUID().uuidString, sectionID: String? = nil, assetName: String) {
        self.id = id
        self.sectionID = sectionID
        self.assetName = assetName
    }
}

public struct MusicTrack: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    /// What plays on it: "drums", "violin", "vocals". Changing it and generating again replaces the audio.
    public var instrument: String
    /// How it should play.
    public var prompt: String
    /// Set on a vocal track: the artist whose lines it sings.
    public var artistID: String?
    public var volume: Double
    public var muted: Bool
    public var solo: Bool
    // ponytail: generation writes one whole-song clip; per-section clips need a backend that takes
    // reference audio, and a player that places clips on the bar grid.
    public var clips: [MusicClip]

    public init(
        id: String = UUID().uuidString, instrument: String, prompt: String = "", artistID: String? = nil,
        volume: Double = 0.8, muted: Bool = false, solo: Bool = false, clips: [MusicClip] = []
    ) {
        self.id = id
        self.instrument = instrument
        self.prompt = prompt
        self.artistID = artistID
        self.volume = volume
        self.muted = muted
        self.solo = solo
        self.clips = clips
    }
}

public struct MusicProject: StudioProject, Sendable, Equatable {
    public static let beatsPerBar = 4

    public var id: String
    public var name: String
    /// The brief the song is written from.
    public var script: String
    public var bpm: Int
    public var key: String
    public var artists: [MusicArtist]
    public var sections: [MusicSection]
    public var tracks: [MusicTrack]
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString, name: String, script: String = "", bpm: Int = 120, key: String = "C major",
        artists: [MusicArtist] = [], sections: [MusicSection] = [], tracks: [MusicTrack] = [], updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.script = script
        self.bpm = bpm
        self.key = key
        self.artists = artists
        self.sections = sections
        self.tracks = tracks
        self.updatedAt = updatedAt
    }

    /// Length of the song: every track is generated to it, which is what keeps separate files aligned.
    public var seconds: Int {
        let bars = max(sections.reduce(0) { $0 + $1.bars }, 1)
        return Int((Double(bars * Self.beatsPerBar) * 60 / Double(max(bpm, 1))).rounded())
    }

    /// What a track plays at: muted tracks are silent, and one solo silences every track that is not.
    public func gain(of track: MusicTrack) -> Double {
        if track.muted || (tracks.contains(where: \.solo) && !track.solo) { return 0 }
        return min(max(track.volume, 0), 1)
    }
}

/// What a music backend needs to render one track so it lines up with the others.
/// The same facts are in the prompt for servers that only read text.
public struct MusicStemRequest: Sendable, Equatable {
    public var instrument: String
    public var bpm: Int
    public var key: String
    public var lyrics: String?

    public init(instrument: String, bpm: Int, key: String, lyrics: String? = nil) {
        self.instrument = instrument
        self.bpm = bpm
        self.key = key
        self.lyrics = lyrics
    }
}

/// A music API connected by address: a server on the network or a cloud service.
public struct MusicEndpoint: Identifiable, Codable, Sendable, Equatable {
    public enum Format: String, Codable, Sendable, CaseIterable {
        /// `POST {base}/audio/generations` and `GET {base}/models`, which `tools/music_server.py` answers.
        case standard
        case elevenLabs = "elevenlabs"

        public var defaultBaseURL: String {
            self == .elevenLabs ? "https://api.elevenlabs.io/v1" : "http://127.0.0.1:8090/v1"
        }

        /// ElevenLabs has no call that lists music models; these are the documented ones.
        public var knownModels: [String] { self == .elevenLabs ? ["music_v1", "music_v2", "music_v2_5"] : [] }
    }

    public var id: String
    public var name: String
    public var baseURL: String
    public var format: Format
    public var model: String

    public init(id: String = UUID().uuidString, name: String, format: Format = .standard) {
        self.id = id
        self.name = name
        self.format = format
        baseURL = format.defaultBaseURL
        model = format.knownModels.first ?? ""
    }

    private static let keychainService = "com.dots.herness.music"

    /// Kept in the Keychain, so settings.json never holds a credential.
    public var apiKey: String? { MCPKeychain.token(for: id, service: Self.keychainService) }

    /// Nil or empty forgets the key.
    public func setAPIKey(_ key: String?) {
        MCPKeychain.setToken(key, for: id, service: Self.keychainService)
    }
}

@MainActor
public final class MusicStudioStore: StudioProjectStore<MusicProject> {
    public init(root: URL) {
        super.init(root: root, fallbackAssetExtension: "mp3")
    }
}

/// Turns a brief into a song plan, and each track of the plan into audio.
public enum MusicStudioAI {
    public static let maxTracks = 12

    static let instructions = """
    You plan songs for a multitrack music studio. Reply with a single JSON object and nothing else:
    {"name":"song title","bpm":120,"key":"A minor","artists":[{"name":"","style":"how the voice sounds"}],\
    "sections":[{"name":"Verse 1","bars":8,"lines":[{"artist":"artist name","text":"one sung line"}]}],\
    "tracks":[{"instrument":"drums","prompt":"how this instrument plays in this song"}]}
    The time signature is 4/4. "sections" are in playing order; an instrumental section has no lines. Every \
    line names the artist who sings it, spelled as in "artists". "tracks" lists the instruments only, one per \
    track, at most \(maxTracks); do not list vocals, each artist gets a vocal track automatically. Each track is \
    generated on its own, so its "prompt" must describe that instrument's part alone: pattern, feel, register. \
    Use as many artists as the request asks for, one when it does not say. Write lyrics and names in the \
    language of the request; keep "instrument" in English.
    """

    public static func planMessages(brief: String) -> [AgentMessage] {
        [
            AgentMessage(role: .system, content: instructions),
            AgentMessage(role: .user, content: brief),
        ]
    }

    /// Tolerant of prose or code fences around the object; entries the model got wrong are dropped, not fatal.
    public static func parsePlan(_ text: String, brief: String) -> MusicProject? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let root = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
        else { return nil }

        func string(_ value: Any?) -> String { (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

        let artists: [MusicArtist] = ((root["artists"] as? [[String: Any]]) ?? []).compactMap { item in
            let name = string(item["name"])
            return name.isEmpty ? nil : MusicArtist(name: name, style: string(item["style"]))
        }
        func artistID(_ name: Any?) -> String? {
            let name = string(name)
            return artists.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id ?? artists.first?.id
        }
        let sections: [MusicSection] = ((root["sections"] as? [[String: Any]]) ?? []).compactMap { item in
            let name = string(item["name"])
            guard !name.isEmpty else { return nil }
            let lines: [MusicLine] = ((item["lines"] as? [[String: Any]]) ?? []).compactMap { line in
                let text = string(line["text"])
                return text.isEmpty ? nil : MusicLine(artistID: artistID(line["artist"]), text: text)
            }
            return MusicSection(name: name, bars: min(max(int(item["bars"]) ?? 8, 1), 64), lines: lines)
        }
        var tracks: [MusicTrack] = ((root["tracks"] as? [[String: Any]]) ?? []).prefix(maxTracks).compactMap { item in
            let instrument = string(item["instrument"])
            return instrument.isEmpty ? nil : MusicTrack(instrument: instrument, prompt: string(item["prompt"]))
        }
        guard !sections.isEmpty, !tracks.isEmpty else { return nil }
        let singing = Set(sections.flatMap(\.lines).compactMap(\.artistID))
        tracks += artists.filter { singing.contains($0.id) }.map { MusicTrack(instrument: "vocals", artistID: $0.id) }

        let name = string(root["name"])
        let key = string(root["key"])
        return MusicProject(
            name: name.isEmpty ? AppCopy.text("studio.untitled") : String(name.prefix(60)),
            script: brief,
            bpm: min(max(int(root["bpm"]) ?? 120, 40), 240),
            key: key.isEmpty ? "C major" : key,
            artists: artists, sections: sections, tracks: tracks
        )
    }

    @MainActor
    public static func plan(brief: String, router: RouterController, settings: MediaStudioSettings) async throws -> MusicProject {
        let model = router.usableModelID(settings.plannerModelID)
        let response = try await router.complete(messages: planMessages(brief: brief), model: model.isEmpty ? nil : model)
        guard let project = parsePlan(response.message.content, brief: brief) else {
            throw NativeAgentError(AppCopy.text("studio.music.noPlan"))
        }
        return project
    }

    /// Model ids a server offers at `{base}/models`; empty when it has no such listing.
    public static func models(baseURL: String, apiKey: String?, session: URLSession = .shared) async -> [String] {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/models"),
              ["http", "https"].contains(url.scheme?.lowercased()) else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 5)
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        guard let (data, _) = try? await session.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { $0["id"] as? String }
    }

    /// The lines a vocal track sings, in song order, under their section names.
    public static func lyrics(for track: MusicTrack, in project: MusicProject) -> String? {
        guard let artistID = track.artistID else { return nil }
        let parts: [String] = project.sections.compactMap { section in
            let lines = section.lines.filter { $0.artistID == artistID && !$0.text.isEmpty }.map(\.text)
            return lines.isEmpty ? nil : "[\(section.name)]\n" + lines.joined(separator: "\n")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Asks for one track alone, pinned to the song's tempo and key so it sits with the others.
    public static func stemPrompt(for track: MusicTrack, in project: MusicProject) -> String {
        var parts: [String]
        if let artist = project.artists.first(where: { $0.id == track.artistID }) {
            parts = ["Isolated lead vocals only, a cappella, no instruments, no backing track."]
            if !artist.style.isEmpty { parts.append("Voice: \(artist.style).") }
        } else {
            parts = ["Isolated \(track.instrument) stem only, solo \(track.instrument), no other instruments, no vocals."]
        }
        if !track.prompt.isEmpty { parts.append(track.prompt) }
        parts.append("\(project.bpm) BPM, \(project.key), 4/4 time.")
        let script = project.script.trimmingCharacters(in: .whitespacesAndNewlines)
        if !script.isEmpty { parts.append("Song: \(script.prefix(300))") }
        if let lyrics = lyrics(for: track, in: project) { parts.append("Lyrics:\n\(lyrics)") }
        return parts.joined(separator: " ")
    }

    /// Generates the track's audio and files it in the project. The caller puts the clip on the track.
    @MainActor
    public static func render(
        _ track: MusicTrack,
        in project: MusicProject,
        router: RouterController,
        settings: MediaStudioSettings,
        paths: SupportPaths,
        store: MusicStudioStore
    ) async throws -> MusicClip {
        let media = try await MediaStudioAI.generate(
            kind: .music,
            prompt: stemPrompt(for: track, in: project),
            router: router, settings: settings, paths: paths,
            seconds: project.seconds,
            stem: MusicStemRequest(
                instrument: track.instrument, bpm: project.bpm, key: project.key,
                lyrics: lyrics(for: track, in: project)
            )
        )
        return MusicClip(assetName: try store.importAsset(from: media.url, into: project.id))
    }
}
