// Copyright (c) 2026 DOTS
// Minimal animated pet overlay and its settings surface.

import AppKit
import Combine
import SwiftUI
import DotsHarnessCore

struct PetAvatar: Identifiable {
    let id: Int
    let name: String
    let description: String
    let accent: Color
}

enum PetPosition: String, CaseIterable, Identifiable {
    case bottomTrailing
    case bottomLeading
    case topTrailing
    case topLeading

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottomTrailing: return AppCopy.text("pet.position.bottomTrailing")
        case .bottomLeading: return AppCopy.text("pet.position.bottomLeading")
        case .topTrailing: return AppCopy.text("pet.position.topTrailing")
        case .topLeading: return AppCopy.text("pet.position.topLeading")
        }
    }

    var alignment: Alignment {
        switch self {
        case .bottomTrailing: return .bottomTrailing
        case .bottomLeading: return .bottomLeading
        case .topTrailing: return .topTrailing
        case .topLeading: return .topLeading
        }
    }
}

enum PetAvatarCatalog {
    private static let definitions: [(String, String)] = [
        ("Developer", "Yazılımcı"),
        ("Designer", "Tasarımcı"),
        ("Filmmaker", "Videocu"),
        ("Assistant", "Asistan"),
        ("DJ", "Müzisyen / DJ"),
        ("Gamer", "Oyuncu"),
        ("Hacker", "Hacker"),
        ("Chef", "Şef Aşçı"),
        ("Astronaut", "Kozmonot"),
        ("Scientist", "Bilim İnsanı"),
        ("Detective", "Dedektif"),
        ("Doctor", "Doktor"),
        ("Painter", "Ressam"),
        ("Guitarist", "Gitarist"),
        ("Writer", "Yazar"),
        ("Female Coder", "Kadın Yazılımcı"),
        ("Security Expert", "Güvenlik Uzmanı"),
        ("Photographer", "Fotoğrafçı"),
        ("Firefighter", "İtfaiyeci"),
        ("Teacher", "Öğretmen"),
        ("Builder", "İnşaatçı"),
        ("Gardener", "Bahçıvan"),
        ("Pilot", "Pilot"),
        ("Diver", "Dalgıç"),
        ("Space Explorer", "Uzay Gezgini"),
        ("Female Designer", "Kadın Tasarımcı"),
        ("Crypto Miner", "Kripto Madencisi"),
        ("Engineer", "Donanım Mühendisi"),
        ("Data Analyst", "Veri Analisti"),
        ("Cloud Engineer", "Bulut Uzmanı"),
        ("CEO", "Yönetici"),
        ("Fitness Coach", "Spor Eğitmeni"),
        ("Magician", "Sihirbaz"),
        ("Superhero", "Süper Kahraman"),
        ("Ninja", "Ninja"),
        ("Pirate", "Korsan"),
        ("King", "Kral"),
        ("Explorer", "Kaşif"),
        ("Gamer Girl", "Oyuncu Kız"),
        ("AI Researcher", "Yapay Zeka Araştırmacısı"),
        ("Video Editor", "Video Editörü"),
        ("Sound Engineer", "Ses Mühendisi"),
        ("Animator", "Animatör"),
        ("Female Hacker", "Kadın Hacker"),
        ("DB Admin", "Veritabanı Yöneticisi"),
        ("UX Researcher", "UX Araştırmacısı"),
        ("Devops", "DevOps Mühendisi"),
        ("Blockchain Dev", "Blokzincir Geliştiricisi"),
        ("Mobile App Dev", "Mobil Geliştirici"),
        ("Prompt Engineer", "Prompt Mühendisi"),
        ("Female DJ", "Kadın DJ"),
        ("Female Gamer", "Kadın Oyuncu"),
        ("Female Astronaut", "Kadın Kozmonot"),
        ("Female Scientist", "Kadın Bilim İnsanı"),
        ("Female Chef", "Kadın Şef Aşçı"),
        ("Female Detective", "Kadın Dedektif"),
        ("Female Doctor", "Kadın Doktor"),
        ("Female Painter", "Kadın Ressam"),
        ("Female Guitarist", "Kadın Gitarist"),
        ("Female Writer", "Kadın Yazar"),
        ("Female Teacher", "Kadın Öğretmen"),
        ("Female Gardener", "Kadın Bahçıvan"),
        ("Female Diver", "Kadın Dalgıç"),
        ("Female Space Explorer", "Kadın Uzay Gezgini"),
        ("Female Engineer", "Kadın Donanım Mühendisi"),
        ("Female Data Analyst", "Kadın Veri Analisti"),
        ("Female Cloud Engineer", "Kadın Bulut Uzmanı"),
        ("Female CEO", "Kadın Yönetici"),
        ("Female Fitness Coach", "Kadın Spor Eğitmeni"),
        ("Female Magician", "Kadın Sihirbaz"),
        ("Female Superhero", "Kadın Süper Kahraman"),
        ("Female Ninja", "Kadın Ninja"),
        ("Female Pirate", "Kadın Korsan"),
        ("Female Queen", "Kraliçe"),
        ("Female Explorer", "Kadın Kaşif"),
        ("Female AI Researcher", "Yapay Zeka Uzmanı (K)"),
        ("Female Video Editor", "Kadın Video Editörü"),
        ("Female Sound Engineer", "Kadın Ses Mühendisi"),
        ("Female Animator", "Kadın Animatör"),
        ("Female DB Admin", "Kadın Veritabanı Yöneticisi"),
        ("Female UX Researcher", "Kadın UX Araştırmacısı"),
        ("Female DevOps", "Kadın DevOps Mühendisi"),
        ("Female Blockchain Dev", "Kadın Kripto Geliştiricisi"),
        ("Female Mobile App Dev", "Kadın Mobil Geliştirici"),
        ("Female Prompt Engineer", "Kadın Prompt Mühendisi"),
        ("Baby Octopus", "Bebek Ahtapot"),
        ("Party Octopus", "Parti Ahtapotu"),
        ("Sleepy Octopus", "Uykulu Ahtapot"),
        ("Bookworm Octopus", "Kitap Kurdu"),
        ("Hipster Octopus", "Hipster Ahtapot"),
        ("Cool Octopus", "Havalı Ahtapot"),
        ("Cyberpunk Octopus", "Cyberpunk Ahtapot"),
        ("Steampunk Octopus", "Steampunk Ahtapot"),
        ("Arcade Gamer", "Retro Atari Oyuncusu"),
        ("Pixel Artist", "Piksel Sanatçısı"),
        ("VR Gamer", "Sanal Gerçeklik Oyuncusu"),
        ("Hologram Assistant", "Hologram Asistan"),
        ("Cyber Guard", "Siber Koruyucu"),
        ("Sys Admin", "Sistem Yöneticisi"),
        ("Ultimate Creator", "Kreatör Ahtapot"),
    ]

    private static let accents: [Color] = [.orange, .blue, .purple, .pink, .teal, .green, .indigo, .yellow]

    static let avatars: [PetAvatar] = definitions.enumerated().map { index, definition in
        PetAvatar(
            id: index + 1,
            name: definition.0,
            description: definition.1,
            accent: accents[index % accents.count]
        )
    }
}

struct PetFloatingOverlay: View {
    @ObservedObject var model: AppModel
    private let onDragChanged: ((CGSize) -> Void)?
    private let onDragEnded: (() -> Void)?
    private let voiceEnabled: Bool

    @AppStorage("dots.pet.selected") private var selectedID = 100
    @AppStorage("dots.pet.size") private var petSize = 104.0
    @StateObject private var voiceInput: PetVoiceInput
    @State private var isFloating = false
    @State private var isPulsing = false
    @State private var isDragging = false

    init(
        model: AppModel,
        onDragChanged: ((CGSize) -> Void)? = nil,
        onDragEnded: (() -> Void)? = nil,
        voiceEnabled: Bool = true
    ) {
        self.model = model
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
        self.voiceEnabled = voiceEnabled
        self._voiceInput = StateObject(wrappedValue: PetVoiceInput(model: model))
    }

    private var selectedAvatar: PetAvatar {
        PetAvatarCatalog.avatars.first(where: { $0.id == selectedID }) ?? PetAvatarCatalog.avatars[0]
    }

    var body: some View {
        VStack(spacing: 3) {
            if voiceEnabled && voiceInput.state != .idle {
                // Keep the status slot while dragging so the panel does not jump,
                // but hide the recording indicator itself.
                voiceStatus
                    .opacity(isDragging ? 0 : 1)
            }

            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(Color.black.opacity(0.18))
                    .frame(width: CGFloat(petSize * 0.82), height: CGFloat(petSize * 0.82))
                    .blur(radius: 8)

                if voiceEnabled && !isDragging && voiceInput.state.isActive {
                    Circle()
                        .stroke(voiceInput.state.tint.opacity(0.82), lineWidth: 2.5)
                        .frame(width: CGFloat(petSize + 9), height: CGFloat(petSize + 9))
                        .scaleEffect(voiceInput.isListening && isFloating ? 1.06 : 1)
                }

                PetAssets.image(for: selectedAvatar.id)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: CGFloat(petSize), height: CGFloat(petSize))
                    .scaleEffect(isPulsing && !isDragging ? 1.09 : 1)
                    .rotationEffect(.degrees(isDragging ? 0 : (isFloating ? 1.5 : -1.5)))
                    .offset(y: isDragging ? 0 : (isFloating ? -3 : 3))
                    .shadow(color: selectedAvatar.accent.opacity(0.32), radius: 10, y: 5)

                if voiceEnabled && !isDragging && voiceInput.state != .idle {
                    Circle()
                        .fill(voiceInput.state.tint)
                        .frame(width: 21, height: 21)
                        .overlay {
                            if voiceInput.state == .transcribing || voiceInput.state == .sending {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(.white)
                            } else {
                                Image(systemName: voiceInput.state.icon)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .offset(x: -1, y: -2)
                } else if model.bridge.isBusy && !isDragging {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .offset(x: -3, y: -5)
                }
            }
            .frame(width: CGFloat(petSize + 16), height: CGFloat(petSize + 16))
            .contentShape(Circle())
            .onTapGesture {
                animateInteraction()
            }
            .help(helpText)
            .contextMenu {
                Button(AppCopy.text("pet.settings"), systemImage: "gearshape") {
                    model.presentSettings()
                }
                Button(AppCopy.text("pet.hide"), systemImage: "eye.slash") {
                    model.hidePet()
                }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            voiceInput.cancelListening()
                        }
                        onDragChanged?(value.translation)
                    }
                    .onEnded { _ in
                        onDragEnded?()
                        isDragging = false
                    }
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) {
                    isFloating = true
                }
            }
        }
    }

    private func animateInteraction() {
        guard !isDragging else { return }
        if voiceEnabled {
            voiceInput.toggle()
        }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.62)) {
            isPulsing = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
            withAnimation(.easeOut(duration: 0.22)) {
                isPulsing = false
            }
        }
    }

    private var helpText: String {
        guard voiceEnabled else { return AppCopy.text("pet.dragHint") }
        return voiceInput.isListening
            ? AppCopy.text("pet.stopAndSend")
            : "\(model.voiceInputHelp) · \(AppCopy.text("pet.dragHint"))"
    }

    private var voiceStatus: some View {
        HStack(spacing: 5) {
            Image(systemName: voiceInput.state.icon)
                .font(.system(size: 10, weight: .bold))
            Text(voiceStatusText)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(voiceInput.state.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 174)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(voiceInput.state.tint.opacity(0.35), lineWidth: 1)
        }
    }

    private var voiceStatusText: String {
        switch voiceInput.state {
        case .requesting:
            return AppCopy.text("pet.micOpening")
        case .listening:
            let text = voiceInput.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? AppCopy.text("pet.listening") : text
        case .transcribing:
            return AppCopy.text("pet.transcribing")
        case .sending:
            return AppCopy.text("pet.sending")
        case .failed(let message):
            return message
        case .idle:
            return ""
        }
    }
}

struct PetSettingsView: View {
    @ObservedObject var model: AppModel

    @AppStorage("dots.pet.selected") private var selectedID = 100
    @AppStorage("dots.pet.size") private var petSize = 104.0
    @AppStorage("dots.pet.position") private var petPosition = PetPosition.bottomTrailing.rawValue
    @State private var showAvatarPicker = false

    private var selectedAvatar: PetAvatar {
        PetAvatarCatalog.avatars.first(where: { $0.id == selectedID }) ?? PetAvatarCatalog.avatars[0]
    }

    var body: some View {
        Form {
            Section(AppCopy.text("pet.visibility")) {
                Toggle(AppCopy.text("pet.show"), isOn: Binding(
                    get: { model.isPetVisible },
                    set: { model.isPetVisible = $0 }
                ))

                Text(AppCopy.text("pet.visibilityHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(VoiceCopy.settingsSection) {
                Picker(VoiceCopy.settingsSource, selection: Binding(
                    get: { model.voiceProvider },
                    set: { model.setVoiceProvider($0) }
                )) {
                    ForEach(VoiceInputProvider.allCases) { provider in
                        Text("\(provider.title) · \(provider.sizeLabel)").tag(provider)
                    }
                }

                voiceProviderSettings
            }

            Section(AppCopy.text("pet.appearance")) {
                Picker(AppCopy.text("pet.position"), selection: $petPosition) {
                    ForEach(PetPosition.allCases) { position in
                        Text(position.title).tag(position.rawValue)
                    }
                }

                HStack {
                    Text(AppCopy.text("pet.size"))
                    Slider(value: $petSize, in: 72...148, step: 4)
                    Text(AppCopy.format("pet.sizeValue", Int(petSize)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
            }

            Section(AppCopy.text("pet.avatar")) {
                Button {
                    showAvatarPicker = true
                } label: {
                    HStack(spacing: 12) {
                        PetAssets.image(for: selectedAvatar.id)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(width: 54, height: 54)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedAvatar.name)
                                .font(.headline)
                            Text(selectedAvatar.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable()
                .accessibilityLabel(Text(selectedAvatar.name))
                .accessibilityHint(Text(AppCopy.text("pet.avatarHint")))
                .popover(isPresented: $showAvatarPicker, arrowEdge: .bottom) {
                    avatarPicker
                }
            }

            Section(AppCopy.text("pet.preview")) {
                HStack {
                    Spacer()
                    PetFloatingOverlay(model: model, voiceEnabled: false)
                    Spacer()
                }
                .frame(minHeight: 150)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(AppCopy.text("pet.title"))
    }

    @ViewBuilder
    private var voiceProviderSettings: some View {
        switch model.voiceProvider {
        case .whisperLargeV3Turbo:
            localModelSettings(
                name: LocalVoiceModel.whisperLargeV3Turbo.name,
                size: LocalVoiceModel.whisperLargeV3Turbo.sizeLabel,
                hint: VoiceCopy.localModelHint,
                importAction: nil
            )
        case .customLocal:
            localModelSettings(
                name: VoiceCopy.sourceCustomLocal,
                size: LocalVoiceModel.custom.sizeLabel,
                hint: VoiceCopy.localModelHint,
                importAction: model.importLocalVoiceModel
            )
        case .nemotron:
            localModelSettings(
                name: LocalVoiceModel.nemotron.name,
                size: LocalVoiceModel.nemotron.sizeLabel,
                hint: VoiceCopy.nemotronHint,
                importAction: nil
            )
        case .api:
            Text(VoiceCopy.apiHint)
                .font(.caption)
                .foregroundStyle(.secondary)
            apiFields
        }
    }

    private func localModelSettings(
        name: String,
        size: String,
        hint: String,
        importAction: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: model.isVoiceModelInstalled ? "checkmark.circle.fill" : "mic.circle")
                    .foregroundStyle(model.isVoiceModelInstalled ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    Text(model.isVoiceModelInstalled ? VoiceCopy.modelReady : VoiceCopy.localModelNotInstalled)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(size)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.isVoiceModelDownloading {
                ProgressView()
                Text(VoiceCopy.downloading)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.isVoiceModelInstalled {
                Button(VoiceCopy.deleteModel, role: .destructive) {
                    model.deleteVoiceModel()
                }
            } else if let importAction {
                Button(VoiceCopy.importModel, action: importAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Button(VoiceCopy.downloadModel) {
                    model.requestVoiceModelDownload()
                }
                .buttonStyle(.borderedProminent)
            }

            if case .failed(let message) = model.voiceModelState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var avatarPicker: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(76), spacing: 10), count: 5),
                spacing: 10
            ) {
                ForEach(PetAvatarCatalog.avatars) { avatar in
                    Button {
                        selectedID = avatar.id
                        showAvatarPicker = false
                    } label: {
                        VStack(spacing: 4) {
                            PetAssets.image(for: avatar.id)
                                .resizable()
                                .interpolation(.none)
                                .scaledToFit()
                                .frame(width: 58, height: 58)

                            Text(avatar.name)
                                .font(.caption2)
                                .lineLimit(1)
                                .frame(width: 70)
                        }
                        .padding(7)
                        .background(
                            selectedID == avatar.id ? avatar.accent.opacity(0.18) : Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(
                                    selectedID == avatar.id ? avatar.accent.opacity(0.85) : Color.primary.opacity(0.08),
                                    lineWidth: selectedID == avatar.id ? 1.5 : 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .accessibilityLabel(Text(avatar.name))
                    .accessibilityHint(Text(avatar.description))
                    .accessibilityAddTraits(selectedID == avatar.id ? .isSelected : [])
                }
            }
            .padding(16)
        }
        .frame(width: 460, height: 420)
    }

    private var apiFields: some View {
        VStack(spacing: 8) {
            TextField(VoiceCopy.endpoint, text: Binding(
                get: { model.voiceAPIEndpoint },
                set: { model.setVoiceAPIEndpoint($0) }
            ))
            SecureField(VoiceCopy.apiKey, text: Binding(
                get: { model.voiceAPIKey },
                set: { model.setVoiceAPIKey($0) }
            ))
            TextField(VoiceCopy.apiModel, text: Binding(
                get: { model.voiceAPIModel },
                set: { model.setVoiceAPIModel($0) }
            ), prompt: Text(VoiceCopy.apiModelPlaceholder))
        }
    }
}

private enum PetAssets {
    static func image(for id: Int) -> Image {
        guard let url = Bundle.module.url(forResource: "pet-\(id)", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return Image(systemName: "pawprint.fill")
        }
        return Image(nsImage: image)
    }
}

@MainActor
struct PetFloatingWindowHost: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        context.coordinator.update()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator {
        private let controller: PetFloatingWindowController

        init(model: AppModel) {
            controller = PetFloatingWindowController(model: model)
        }

        func update() {
            controller.sync()
        }

        func teardown() {
            controller.close()
        }
    }
}

@MainActor
private final class PetFloatingWindowController: NSObject {
    private static let positionXKey = "dots.pet.screen.x"
    private static let positionYKey = "dots.pet.screen.y"
    private static let positionPreferenceKey = "dots.pet.position"

    private let model: AppModel
    private let defaults = UserDefaults.standard
    private let windowSize = CGSize(width: 180, height: 180)
    private var panel: PetPanel?
    private var modelObservation: AnyCancellable?
    private var defaultsObservation: NSObjectProtocol?
    private var dragStartOrigin: NSPoint?
    private var lastPositionPreference: String?

    init(model: AppModel) {
        self.model = model
        super.init()

        modelObservation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.sync()
            }
        }

        defaultsObservation = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.sync()
            }
        }
    }

    func sync() {
        guard model.isPetVisible, !model.isFirstLaunch else {
            panel?.orderOut(nil)
            return
        }

        ensurePanel()
        syncPositionPreference()
        panel?.orderFrontRegardless()
    }

    func close() {
        modelObservation?.cancel()
        modelObservation = nil
        if let defaultsObservation {
            NotificationCenter.default.removeObserver(defaultsObservation)
        }
        defaultsObservation = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let panel = PetPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let hostingView = NSHostingView(
            rootView: PetFloatingOverlay(
                model: model,
                onDragChanged: { [weak self] translation in
                    self?.movePet(by: translation)
                },
                onDragEnded: { [weak self] in
                    self?.finishDragging()
                }
            )
            .frame(width: windowSize.width, height: windowSize.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        panel.delegate = self

        self.panel = panel
        lastPositionPreference = positionPreference
        positionPanel(for: positionPreference, usingStoredOrigin: true)
    }

    private func syncPositionPreference() {
        guard let panel else { return }
        let preference = positionPreference

        if let lastPositionPreference, lastPositionPreference != preference {
            self.lastPositionPreference = preference
            positionPanel(for: preference, usingStoredOrigin: false)
        } else if lastPositionPreference == nil {
            lastPositionPreference = preference
            positionPanel(for: preference, usingStoredOrigin: true)
        }

        if panel.isVisible == false {
            panel.orderFrontRegardless()
        }
    }

    private func positionPanel(for preference: String, usingStoredOrigin: Bool) {
        guard let panel else { return }

        if usingStoredOrigin,
           defaults.object(forKey: Self.positionXKey) != nil,
           defaults.object(forKey: Self.positionYKey) != nil {
            let x = defaults.double(forKey: Self.positionXKey)
            let y = defaults.double(forKey: Self.positionYKey)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        let bounds = mainWindowBounds
        let margin: CGFloat = 18
        let position = PetPosition(rawValue: preference) ?? .bottomTrailing
        let origin: NSPoint

        switch position {
        case .bottomTrailing:
            origin = NSPoint(x: bounds.maxX - windowSize.width - margin, y: bounds.minY + 112)
        case .bottomLeading:
            origin = NSPoint(x: bounds.minX + margin, y: bounds.minY + 112)
        case .topTrailing:
            origin = NSPoint(x: bounds.maxX - windowSize.width - margin, y: bounds.maxY - windowSize.height - margin)
        case .topLeading:
            origin = NSPoint(x: bounds.minX + margin, y: bounds.maxY - windowSize.height - margin)
        }

        panel.setFrameOrigin(origin)
        savePanelOrigin()
    }

    private func movePet(by translation: CGSize) {
        guard let panel else { return }
        if dragStartOrigin == nil {
            dragStartOrigin = panel.frame.origin
        }

        guard let dragStartOrigin else { return }
        panel.setFrameOrigin(
            NSPoint(
                x: dragStartOrigin.x + translation.width,
                y: dragStartOrigin.y - translation.height
            )
        )
    }

    private func finishDragging() {
        savePanelOrigin()
        dragStartOrigin = nil
    }

    private func savePanelOrigin() {
        guard let origin = panel?.frame.origin else { return }
        defaults.set(Double(origin.x), forKey: Self.positionXKey)
        defaults.set(Double(origin.y), forKey: Self.positionYKey)
    }

    private var positionPreference: String {
        defaults.string(forKey: Self.positionPreferenceKey) ?? PetPosition.bottomTrailing.rawValue
    }

    private var mainWindowBounds: NSRect {
        if let window = NSApplication.shared.windows.first(where: {
            $0 !== panel && $0.isVisible && $0.styleMask.contains(.titled)
        }) {
            return window.frame
        }

        return NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
}

@MainActor
private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension PetFloatingWindowController: NSWindowDelegate {}
