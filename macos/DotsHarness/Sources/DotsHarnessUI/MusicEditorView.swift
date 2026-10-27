// Copyright (c) 2026 DOTS
// Music editor: the arrangement board (sections over a bar ruler, one lane per track)
// with the inspector for whatever is selected on the right.

import AppKit
import AVFoundation
import SwiftUI
import DotsHarnessCore

// AVFoundation brings in AudioToolbox's own `MusicTrack`.
private typealias Track = DotsHarnessCore.MusicTrack

/// Plays every track's file at once, each at its own level.
@MainActor
private final class MusicMixer: ObservableObject {
    @Published private(set) var isPlaying = false
    /// Where playback starts from, in seconds.
    @Published private(set) var cue: TimeInterval = 0

    private var players: [String: AVAudioPlayer] = [:]
    /// Bumped on every start and stop, so a finished run cannot stop the one after it.
    private var run = 0

    /// The playhead, in seconds.
    var time: TimeInterval { players.values.map(\.currentTime).max() ?? cue }

    func play(_ project: MusicProject, store: MusicStudioStore) {
        halt()
        for track in project.tracks {
            guard let clip = track.clips.first(where: { $0.sectionID == nil }),
                  let player = try? AVAudioPlayer(
                      contentsOf: store.assetURL(projectID: project.id, name: clip.assetName)
                  ), player.duration > cue else { continue }
            player.currentTime = cue
            player.prepareToPlay()
            players[track.id] = player
        }
        guard let first = players.values.first else { return }
        apply(project)
        // One shared start time, or the tracks sit apart by however long each took to start.
        let start = first.deviceCurrentTime + 0.1
        players.values.forEach { $0.play(atTime: start) }
        isPlaying = true
        let current = run
        let remaining = (players.values.map(\.duration).max() ?? 0) - cue
        Task {
            try? await Task.sleep(for: .seconds(remaining + 0.3))
            if current == run { stop() }
        }
    }

    /// Stops and returns to the start.
    func stop() {
        halt()
        cue = 0
    }

    func seek(to seconds: TimeInterval, in project: MusicProject, store: MusicStudioStore) {
        let wasPlaying = isPlaying
        halt()
        cue = max(seconds, 0)
        if wasPlaying { play(project, store: store) }
    }

    func apply(_ project: MusicProject) {
        for track in project.tracks { players[track.id]?.volume = Float(project.gain(of: track)) }
    }

    private func halt() {
        players.values.forEach { $0.stop() }
        players = [:]
        isPlaying = false
        run += 1
    }
}

private enum Waveform {
    /// The loudest sample in each of `count` slices, scaled so the loudest is 1, and the file's length in seconds.
    static func read(_ url: URL, count: Int = 320) -> (peaks: [Float], seconds: Double)? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let format = file.processingFormat
        let slice = AVAudioFrameCount(max(file.length / Int64(count), 1))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: slice) else { return nil }
        var peaks: [Float] = []
        while peaks.count < count, (try? file.read(into: buffer, frameCount: slice)) != nil,
              buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] {
            var peak: Float = 0
            for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[index])) }
            peaks.append(peak)
        }
        let loudest = max(peaks.max() ?? 0, 0.001)
        return (peaks.map { $0 / loudest }, Double(file.length) / format.sampleRate)
    }
}

/// One track's audio drawn across its lane, as wide as its share of the song.
private struct WaveformLane: View {
    let url: URL
    let color: Color
    let songSeconds: Double

    @State private var wave: (peaks: [Float], seconds: Double)?

    var body: some View {
        Canvas { context, size in
            guard let wave, !wave.peaks.isEmpty else { return }
            let width = size.width * min(wave.seconds / max(songSeconds, 1), 1)
            context.fill(
                Path(roundedRect: CGRect(x: 0, y: 4, width: width, height: size.height - 8), cornerRadius: 6),
                with: .color(color.opacity(0.16))
            )
            let step = width / CGFloat(wave.peaks.count)
            var bars = Path()
            for (index, peak) in wave.peaks.enumerated() {
                let height = max(CGFloat(peak) * (size.height - 18), 1)
                bars.addRect(CGRect(
                    x: CGFloat(index) * step, y: (size.height - height) / 2,
                    width: max(step - 1, 0.5), height: height
                ))
            }
            context.fill(bars, with: .color(color))
        }
        .task(id: url) {
            let url = url
            wave = await Task.detached { Waveform.read(url) }.value
        }
    }
}

struct MusicEditorView: View {
    private enum Selection: Equatable {
        case song
        case section(String)
        case track(String)
    }

    @ObservedObject var model: AppModel
    @ObservedObject private var studio: MediaStudioStore

    @State private var project: MusicProject
    @StateObject private var mixer = MusicMixer()
    @State private var selection: Selection = .song
    /// Ids of the tracks being generated.
    @State private var busy: Set<String> = []
    @State private var error: String?
    @State private var showSettings = false
    /// Nil follows the window: open when there is room beside the board, closed when there is not.
    @State private var inspectorOpen: Bool?

    private static let laneHeight: CGFloat = 54

    init(model: AppModel, project: MusicProject) {
        self.model = model
        self.studio = model.mediaStudio
        _project = State(initialValue: project)
    }

    private var store: MusicStudioStore { model.musicStudio }
    private var totalBars: Int { max(project.sections.reduce(0) { $0 + $1.bars }, 1) }
    private var seconds: Double { Double(project.seconds) }

    var body: some View {
        GeometryReader { proxy in
            // Too narrow to hold both: the inspector then opens over the board instead of beside it.
            let compact = proxy.size.width < 720
            let open = inspectorOpen ?? !compact
            VStack(spacing: 0) {
                toolbar(open: open, compact: compact)
                Divider()
                HStack(spacing: 0) {
                    board
                        .layoutPriority(1)
                    if open, !compact {
                        Divider()
                        inspector(compact: false).frame(width: 264)
                    }
                }
                .overlay(alignment: .trailing) {
                    if open, compact {
                        inspector(compact: true)
                            .frame(width: min(300, max(proxy.size.width - 40, 200)))
                            .overlay(alignment: .leading) { Divider() }
                            .shadow(color: .black.opacity(0.3), radius: 14, x: -4)
                    }
                }
            }
            .onChange(of: selection) { _, selection in
                // In a narrow window a selection is a request to edit it; song is where closing leaves it.
                if compact, selection != .song { inspectorOpen = true }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showSettings) { MediaSettingsSheet(model: model) }
        .onChange(of: project) { _, project in
            store.save(project)
            mixer.apply(project)
        }
        .onDisappear { mixer.stop() }
    }

    // MARK: Toolbar

    private func toolbar(open: Bool, compact: Bool) -> some View {
        HStack(spacing: 10) {
            Button { store.openProjectID = nil } label: {
                Label(AppCopy.text("studio.music"), systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            TextField(AppCopy.text("studio.projectName"), text: $project.name)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: 60, maxWidth: 220)

            Spacer(minLength: 8)

            if !compact {
                Button { selection = .song } label: {
                    Text(verbatim: "\(project.bpm) BPM   \(project.key)   \(Self.clock(seconds))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help(AppCopy.text("studio.music.song"))
                Divider().frame(height: 16)
            }

            Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                .help(AppCopy.text("studio.settings.title"))
            Button { inspectorOpen = !open } label: { Image(systemName: "sidebar.right") }
                .help(AppCopy.text("studio.music.inspector"))
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    // MARK: Board

    private var board: some View {
        GeometryReader { proxy in
            // The lane names give way before the timeline does.
            let header: CGFloat = proxy.size.width < 480 ? 104 : 168
            let lane = max(proxy.size.width - header, 1)
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                    .onTapGesture { selection = .song }

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: header)
                        ruler(width: lane)
                    }
                    .frame(height: 24)
                    HStack(spacing: 0) {
                        Button {
                            let section = MusicSection(name: AppCopy.text("studio.music.section.default"))
                            project.sections.append(section)
                            selection = .section(section.id)
                        } label: {
                            Label(AppCopy.text("studio.music.section.add"), systemImage: "plus")
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .frame(width: header, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        sectionBlocks(width: lane)
                    }
                    .frame(height: 46)
                    Divider()
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(project.tracks) { track in
                                laneRow(track, header: header)
                                Divider().opacity(0.5)
                            }
                            Button {
                                let track = Track(instrument: "")
                                project.tracks.append(track)
                                selection = .track(track.id)
                            } label: {
                                Label(AppCopy.text("studio.music.track.add"), systemImage: "plus")
                                    .font(.system(size: 11))
                                    .padding(.horizontal, 10)
                                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        // Room for the dock, so the last lane can scroll clear of it.
                        .padding(.bottom, 96)
                    }
                }

                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !mixer.isPlaying)) { _ in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 1.5, height: proxy.size.height)
                        .offset(x: header + lane * min(mixer.time / max(seconds, 1), 1))
                }
                .allowsHitTesting(false)

                VStack(spacing: 8) {
                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(3)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .onTapGesture { self.error = nil }
                    }
                    dock
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
            }
            .clipped()
        }
        .frame(minWidth: 300)
    }

    /// Bar numbers; a press or drag moves the playhead.
    private func ruler(width: CGFloat) -> some View {
        let bars = totalBars
        return Canvas { context, size in
            let barWidth = size.width / CGFloat(bars)
            // Label every bar when there is room, else every 2nd, 4th, 8th…
            let step = [1, 2, 4, 8, 16, 32, 64].first { CGFloat($0) * barWidth >= 34 } ?? 64
            for bar in 0..<bars {
                let x = CGFloat(bar) * barWidth
                let labelled = bar % step == 0
                context.fill(
                    Path(CGRect(x: x, y: labelled ? 12 : 18, width: 1, height: labelled ? 12 : 6)),
                    with: .color(.primary.opacity(labelled ? 0.35 : 0.15))
                )
                if labelled {
                    context.draw(
                        Text(verbatim: "\(bar + 1)").font(.system(size: 9).monospacedDigit()).foregroundColor(.secondary),
                        at: CGPoint(x: x + 4, y: 8), anchor: .leading
                    )
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            mixer.seek(to: Double(min(max(value.location.x / width, 0), 1)) * seconds, in: project, store: store)
        })
    }

    private func sectionBlocks(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(project.sections) { section in
                let selected = selection == .section(section.id)
                let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(section.lines.first(where: { !$0.text.isEmpty })?.text
                        ?? AppCopy.format("studio.music.section.bars", section.bars))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(selected ? 0.34 : 0.13), in: shape)
                .overlay(shape.stroke(Color.accentColor.opacity(selected ? 0.9 : 0), lineWidth: 1))
                .padding(.horizontal, 1)
                .padding(.vertical, 5)
                .frame(width: width * CGFloat(section.bars) / CGFloat(totalBars))
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { selection = .section(section.id) }
                .contextMenu {
                    Button(AppCopy.text("studio.music.section.delete"), role: .destructive) { remove(section: section.id) }
                }
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func laneRow(_ track: Track, header: CGFloat) -> some View {
        let selected = selection == .track(track.id)
        let color = Self.color(of: track)
        let audible = project.gain(of: track) > 0
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: 26)
                Text(title(of: track))
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                laneToggle("M", on: track.muted, tint: .orange, help: "studio.music.mute", id: track.id) { $0.muted.toggle() }
                laneToggle("S", on: track.solo, tint: .yellow, help: "studio.music.solo", id: track.id) { $0.solo.toggle() }
            }
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .frame(width: header, alignment: .leading)

            ZStack {
                boundaries
                if busy.contains(track.id) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(AppCopy.text("studio.music.composing")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if let clip = track.clips.first(where: { $0.sectionID == nil }) {
                    WaveformLane(url: assetURL(clip), color: color, songSeconds: seconds)
                        .opacity(audible ? 1 : 0.3)
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .padding(.vertical, 6)
                        .overlay(alignment: .leading) {
                            Text(AppCopy.text("studio.music.track.empty"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                        }
                }
            }
        }
        .frame(height: Self.laneHeight)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selection = .track(track.id) }
        .contextMenu {
            Button(AppCopy.text("studio.music.track.generate")) { generate([track.id]) }
                .disabled(!canGenerate(track))
            if let clip = track.clips.first {
                Button(AppCopy.text("media.showInFinder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([assetURL(clip)])
                }
            }
            Divider()
            Button(AppCopy.text("studio.music.track.delete"), role: .destructive) { remove(track: track.id) }
        }
    }

    /// Faint lines where one section ends and the next begins, so audio reads against the song's shape.
    private var boundaries: some View {
        Canvas { context, size in
            var bar = 0
            for section in project.sections.dropLast() {
                bar += section.bars
                let x = size.width * CGFloat(bar) / CGFloat(totalBars)
                context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.primary.opacity(0.08)))
            }
        }
    }

    private func laneToggle(
        _ letter: String, on: Bool, tint: Color, help: String, id: String, change: @escaping (inout Track) -> Void
    ) -> some View {
        Button {
            if let index = project.tracks.firstIndex(where: { $0.id == id }) { change(&project.tracks[index]) }
        } label: {
            Text(letter)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .foregroundStyle(on ? Color.black : Color.secondary)
                .background(on ? tint : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(AppCopy.text(help))
    }

    // MARK: Dock

    private var dock: some View {
        HStack(spacing: 10) {
            Button {
                if mixer.isPlaying { mixer.stop() } else { mixer.play(project, store: store) }
            } label: {
                Image(systemName: mixer.isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 14))
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!project.tracks.contains { !$0.clips.isEmpty })

            TimelineView(.animation(minimumInterval: 0.25, paused: !mixer.isPlaying)) { _ in
                Text(verbatim: "\(Self.clock(min(mixer.time, seconds))) / \(Self.clock(seconds))")
                    .font(.system(size: 12).monospacedDigit())
                    .fixedSize()
            }

            Divider().frame(height: 18).overlay(Color.white.opacity(0.2))

            if busy.isEmpty {
                Button { generate(project.tracks.filter(canGenerate).map(\.id)) } label: {
                    Label(AppCopy.text("studio.music.generateAll"), systemImage: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!project.tracks.contains(where: canGenerate))
                .help(MediaSettingsView.summary(of: studio.settings, for: .music))
            } else {
                ProgressView().controlSize(.small).colorScheme(.dark)
                Text(AppCopy.format("studio.music.generating", busy.count))
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
        }
        .editorDockChrome()
    }

    // MARK: Inspector

    private func inspector(compact: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch selection {
                case .track(let id):
                    if let index = project.tracks.firstIndex(where: { $0.id == id }) {
                        trackInspector($project.tracks[index])
                    }
                case .section(let id):
                    if let index = project.sections.firstIndex(where: { $0.id == id }) {
                        sectionInspector($project.sections[index])
                    }
                case .song:
                    songInspector
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.small)
        .textFieldStyle(.roundedBorder)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topTrailing) {
            if compact {
                Button {
                    inspectorOpen = false
                    selection = .song
                } label: {
                    Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(6)
                .help(AppCopy.text("common.done"))
            }
        }
    }

    @ViewBuilder
    private var songInspector: some View {
        group(AppCopy.text("studio.music.script")) {
            TextEditor(text: $project.script)
                .font(.system(size: 12))
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        group(AppCopy.text("studio.music.tempo")) {
            Stepper(AppCopy.format("studio.music.bpm", project.bpm), value: $project.bpm, in: 40...240)
            LabeledContent(AppCopy.text("studio.music.key")) {
                TextField("", text: $project.key).frame(maxWidth: 130)
            }
            Text(verbatim: "\(AppCopy.format("studio.music.section.bars", totalBars))   \(Self.clock(seconds))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        group(AppCopy.text("studio.music.artists")) {
            ForEach($project.artists) { $artist in
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        TextField(AppCopy.text("studio.music.artist.name"), text: $artist.name)
                        removeButton { remove(artist: artist.id) }
                    }
                    TextField(AppCopy.text("studio.music.artist.style"), text: $artist.style, axis: .vertical)
                        .lineLimit(1...3)
                }
                .padding(.bottom, 4)
            }
            Button(action: addArtist) { Label(AppCopy.text("studio.music.artist.add"), systemImage: "plus") }
                .buttonStyle(.link)
        }
    }

    @ViewBuilder
    private func sectionInspector(_ section: Binding<MusicSection>) -> some View {
        group(AppCopy.text("studio.music.section")) {
            TextField(AppCopy.text("studio.music.section.default"), text: section.name)
            Stepper(AppCopy.format("studio.music.section.bars", section.wrappedValue.bars), value: section.bars, in: 1...64)
        }
        group(AppCopy.text("studio.music.lyrics")) {
            ForEach(section.lines) { $line in
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Picker("", selection: $line.artistID) {
                            Text(AppCopy.text("studio.music.line.unsung")).tag(String?.none)
                            ForEach(project.artists) { Text($0.name).tag(String?.some($0.id)) }
                        }
                        .labelsHidden()
                        removeButton { section.wrappedValue.lines.removeAll { $0.id == line.id } }
                    }
                    TextField(AppCopy.text("studio.music.line.placeholder"), text: $line.text, axis: .vertical)
                        .lineLimit(1...3)
                }
                .padding(.bottom, 4)
            }
            Button {
                let lines = section.wrappedValue.lines
                section.wrappedValue.lines.append(MusicLine(artistID: lines.last?.artistID ?? project.artists.first?.id))
            } label: {
                Label(AppCopy.text("studio.music.line.add"), systemImage: "plus")
            }
            .buttonStyle(.link)
        }
        group(nil) {
            Button(AppCopy.text("studio.music.section.delete"), role: .destructive) { remove(section: section.wrappedValue.id) }
        }
    }

    @ViewBuilder
    private func trackInspector(_ track: Binding<Track>) -> some View {
        let value = track.wrappedValue
        group(AppCopy.text("studio.music.track")) {
            if let artist = project.artists.first(where: { $0.id == value.artistID }) {
                Label(AppCopy.format("studio.music.track.vocal", artist.name), systemImage: "music.mic")
                    .font(.system(size: 12, weight: .medium))
            } else {
                TextField(AppCopy.text("studio.music.track.instrument"), text: track.instrument)
            }
            TextField(AppCopy.text("studio.music.track.prompt"), text: track.prompt, axis: .vertical)
                .lineLimit(2...6)
            if busy.contains(value.id) {
                HStack(spacing: 6) {
                    ProgressView()
                    Text(AppCopy.text("studio.music.composing")).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button { generate([value.id]) } label: {
                    Label(
                        AppCopy.text(value.clips.isEmpty ? "studio.music.track.generate" : "studio.music.regenerate"),
                        systemImage: "sparkles"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!canGenerate(value))
            }
        }
        group(AppCopy.text("studio.music.mix")) {
            HStack(spacing: 6) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: track.volume, in: 0...1)
                Text(verbatim: "\(Int((value.volume * 100).rounded()))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .trailing)
            }
            HStack {
                Toggle(AppCopy.text("studio.music.mute"), isOn: track.muted)
                Toggle(AppCopy.text("studio.music.solo"), isOn: track.solo)
            }
            .toggleStyle(.button)
        }
        group(nil) {
            if let clip = value.clips.first {
                Button(AppCopy.text("media.showInFinder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([assetURL(clip)])
                }
            }
            Button(AppCopy.text("studio.music.track.delete"), role: .destructive) { remove(track: value.id) }
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func group<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.system(size: 11, weight: .semibold)) }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        Divider()
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "xmark") }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(AppCopy.text("common.remove"))
    }

    private func title(of track: Track) -> String {
        if let artist = project.artists.first(where: { $0.id == track.artistID }) { return artist.name }
        return track.instrument.isEmpty ? AppCopy.text("studio.music.track.instrument") : track.instrument
    }

    /// A hue of its own for each track, the same every time the song is opened.
    private static func color(of track: Track) -> Color {
        let seed = track.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }
        return Color(hue: Double(seed) / 360, saturation: 0.55, brightness: 0.9)
    }

    private static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.down))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }

    private func assetURL(_ clip: MusicClip) -> URL {
        store.assetURL(projectID: project.id, name: clip.assetName)
    }

    /// A vocal track sings its artist's lines; any other needs to be told what to play.
    private func canGenerate(_ track: Track) -> Bool {
        track.artistID != nil || !track.instrument.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Edits

    /// An artist always comes with the vocal track that sings their lines.
    private func addArtist() {
        let artist = MusicArtist(name: AppCopy.format("studio.music.artist.default", project.artists.count + 1))
        project.artists.append(artist)
        project.tracks.append(Track(instrument: "vocals", artistID: artist.id))
    }

    private func remove(artist id: String) {
        for track in project.tracks where track.artistID == id { remove(track: track.id) }
        project.artists.removeAll { $0.id == id }
        for section in project.sections.indices {
            for line in project.sections[section].lines.indices where project.sections[section].lines[line].artistID == id {
                project.sections[section].lines[line].artistID = nil
            }
        }
    }

    private func remove(section id: String) {
        if selection == .section(id) { selection = .song }
        project.sections.removeAll { $0.id == id }
    }

    private func remove(track id: String) {
        guard let track = project.tracks.first(where: { $0.id == id }) else { return }
        if selection == .track(id) { selection = .song }
        mixer.stop()
        deleteFiles(of: track)
        project.tracks.removeAll { $0.id == id }
    }

    private func deleteFiles(of track: Track) {
        for clip in track.clips { try? FileManager.default.removeItem(at: assetURL(clip)) }
    }

    // MARK: Generation

    private func generate(_ ids: [String]) {
        let pending = ids.filter { !busy.contains($0) }
        guard !pending.isEmpty else { return }
        busy.formUnion(pending)
        error = nil
        mixer.stop()
        let snapshot = project
        let settings = studio.settings
        if settings.musicEndpoint.map({ $0.format == .standard }) ?? (settings.musicSource == .local) {
            // A server of your own renders one request at a time; queued here, each keeps its own request timeout.
            Task { for id in pending { await render(id, in: snapshot, settings: settings) } }
        } else {
            for id in pending { Task { await render(id, in: snapshot, settings: settings) } }
        }
    }

    /// Replaces the track's audio with a fresh take of whatever the track says now.
    private func render(_ id: String, in snapshot: MusicProject, settings: MediaStudioSettings) async {
        defer { busy.remove(id) }
        guard let track = snapshot.tracks.first(where: { $0.id == id }) else { return }
        do {
            let clip = try await MusicStudioAI.render(
                track, in: snapshot, router: model.router, settings: settings, paths: model.paths, store: store
            )
            guard let index = project.tracks.firstIndex(where: { $0.id == id }) else {
                try? FileManager.default.removeItem(at: assetURL(clip))
                return
            }
            deleteFiles(of: project.tracks[index])
            project.tracks[index].clips = [clip]
        } catch {
            self.error = "\(title(of: track)): " + ((error as? NativeAgentError)?.message ?? error.localizedDescription)
        }
    }
}
