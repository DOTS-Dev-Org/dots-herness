import Foundation
import XCTest
@testable import DotsHarnessCore

final class MusicStudioTests: XCTestCase {
    func testPlanParsingBuildsTracksAndAVocalTrackPerSingingArtist() throws {
        let reply = """
        ```json
        {"name":"Gece","bpm":900,"key":"A minor",
         "artists":[{"name":"Ada","style":"warm alto"},{"name":"Can"},{"name":"Silent"}],
         "sections":[
           {"name":"Intro","bars":4},
           {"name":"Verse","bars":8,"lines":[{"artist":"ada","text":"Gece uzun"},{"artist":"Can","text":"Yol kısa"},{"text":""}]},
           {"bars":8}
         ],
         "tracks":[{"instrument":"drums","prompt":"tight"},{"instrument":""},{"instrument":"violin"}]}
        ```
        """
        let project = try XCTUnwrap(MusicStudioAI.parsePlan(reply, brief: "a night song"))

        XCTAssertEqual(project.bpm, 240)
        XCTAssertEqual(project.sections.map(\.name), ["Intro", "Verse"])
        XCTAssertEqual(project.sections[1].lines.map(\.text), ["Gece uzun", "Yol kısa"])
        XCTAssertEqual(project.tracks.map(\.instrument), ["drums", "violin", "vocals", "vocals"])
        let ada = project.artists[0]
        XCTAssertEqual(project.tracks[2].artistID, ada.id)
        XCTAssertEqual(project.seconds, 12)

        XCTAssertEqual(MusicStudioAI.lyrics(for: project.tracks[2], in: project), "[Verse]\nGece uzun")
        XCTAssertNil(MusicStudioAI.lyrics(for: project.tracks[0], in: project))
        let drums = MusicStudioAI.stemPrompt(for: project.tracks[0], in: project)
        XCTAssertTrue(drums.contains("Isolated drums stem only"))
        XCTAssertTrue(drums.contains("240 BPM, A minor"))
        XCTAssertFalse(drums.contains("Gece uzun"))
        let vocal = MusicStudioAI.stemPrompt(for: project.tracks[2], in: project)
        XCTAssertTrue(vocal.contains("warm alto"))
        XCTAssertTrue(vocal.contains("Gece uzun"))
        XCTAssertFalse(vocal.contains("Yol kısa"))

        XCTAssertNil(MusicStudioAI.parsePlan("Sorry.", brief: ""))
        XCTAssertNil(MusicStudioAI.parsePlan(#"{"sections":[{"name":"A"}],"tracks":[]}"#, brief: ""))
    }

    func testSoloSilencesOtherTracksAndMuteWins() {
        var project = MusicProject(name: "Mix", tracks: [
            MusicTrack(instrument: "drums", volume: 0.5),
            MusicTrack(instrument: "guitar", volume: 2),
        ])
        XCTAssertEqual(project.tracks.map(project.gain(of:)), [0.5, 1])
        project.tracks[1].solo = true
        XCTAssertEqual(project.tracks.map(project.gain(of:)), [0, 1])
        project.tracks[1].muted = true
        XCTAssertEqual(project.tracks.map(project.gain(of:)), [0, 0])
    }
}
