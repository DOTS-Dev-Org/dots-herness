// Copyright (c) 2026 DOTS
// Media editor side panels: the layer tree on the left and the design inspector on the right.

import AppKit
import SwiftUI
import DotsHarnessCore

// MARK: - Layers

/// Every canvas on the board with its layers under it, front layer first.
struct MediaLayersPanel: View {
    @ObservedObject var state: MediaEditorState
    @State private var collapsed: Set<String> = []
    @State private var renaming: String?
    @State private var hovered: String?
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AppCopy.text("studio.layers"))
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            List {
                ForEach(state.project.canvases.filter { $0.parentID == nil }) { canvas in
                    canvasNode(canvas)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .controlSize(.small)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// A canvas with the canvases nested in it, then its own layers. Type-erased because it recurses.
    private func canvasNode(_ canvas: MediaCanvas) -> AnyView {
        AnyView(DisclosureGroup(isExpanded: Binding(
            get: { !collapsed.contains(canvas.id) },
            set: { if $0 { collapsed.remove(canvas.id) } else { collapsed.insert(canvas.id) } }
        )) {
            ForEach(state.project.canvases.filter { $0.parentID == canvas.id }) { child in
                canvasNode(child)
            }
            ForEach(canvas.layers.reversed()) { layer in
                layerRow(layer, in: canvas)
            }
            .onMove { state.moveLayers(in: canvas.id, from: $0, to: $1) }
            if canvas.layers.isEmpty, !state.project.canvases.contains(where: { $0.parentID == canvas.id }) {
                Text(AppCopy.text("studio.layers.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } label: {
            canvasRow(canvas)
        })
    }

    private func canvasRow(_ canvas: MediaCanvas) -> some View {
        row(
            id: canvas.id,
            systemImage: canvas.section == true ? "rectangle.dashed" : "number",
            name: Binding(
                get: { canvas.name },
                set: { name in
                    state.updateCanvas(canvas.id) { $0.name = name }
                    state.commit()
                }
            ),
            selected: state.canvasID == canvas.id && state.layerID == nil,
            weight: .semibold
        ) {}
        .onTapGesture { state.select(canvas: canvas.id) }
        .contextMenu {
            Button(AppCopy.text("studio.rename")) { beginRename(canvas.id) }
            Button(AppCopy.text("studio.duplicate")) {
                state.select(canvas: canvas.id)
                state.duplicateSelectedCanvas()
            }
            Divider()
            Button(AppCopy.text("studio.deleteCanvas"), role: .destructive) {
                state.select(canvas: canvas.id)
                state.deleteSelectedCanvas()
            }
        }
    }

    private func layerRow(_ layer: MediaLayer, in canvas: MediaCanvas) -> some View {
        row(
            id: layer.id,
            systemImage: Self.icon(for: layer),
            name: Binding(
                get: { layer.name },
                set: { name in
                    state.updateLayer(layer.id, in: canvas.id) { $0.name = name }
                    state.commit()
                }
            ),
            selected: state.layerID == layer.id,
            weight: .regular
        ) {
            // Shown while it matters: when the layer is locked or hidden, or the pointer is on the row.
            if layer.locked || hovered == layer.id {
                rowToggle(
                    layer.locked ? "lock.fill" : "lock.open",
                    AppCopy.text(layer.locked ? "studio.layer.unlock" : "studio.layer.lock")
                ) { state.toggle(\.locked, layer: layer.id, in: canvas.id) }
            }
            if layer.hidden || hovered == layer.id {
                rowToggle(
                    layer.hidden ? "eye.slash" : "eye",
                    AppCopy.text(layer.hidden ? "studio.layer.show" : "studio.layer.hide")
                ) { state.toggle(\.hidden, layer: layer.id, in: canvas.id) }
            }
        }
        .opacity(layer.hidden ? 0.5 : 1)
        .onTapGesture { state.select(canvas: canvas.id, layer: layer.id) }
        .contextMenu {
            Button(AppCopy.text("studio.rename")) { beginRename(layer.id) }
            Button(AppCopy.text("studio.duplicate")) { selecting(layer, canvas) { state.duplicateSelectedLayer() } }
            Divider()
            Button(AppCopy.text("studio.layer.front")) { selecting(layer, canvas) { state.reorderSelectedLayer(toFront: true) } }
            Button(AppCopy.text("studio.layer.back")) { selecting(layer, canvas) { state.reorderSelectedLayer(toFront: false) } }
            Divider()
            Button(AppCopy.text(layer.locked ? "studio.layer.unlock" : "studio.layer.lock")) {
                state.toggle(\.locked, layer: layer.id, in: canvas.id)
            }
            Button(AppCopy.text(layer.hidden ? "studio.layer.show" : "studio.layer.hide")) {
                state.toggle(\.hidden, layer: layer.id, in: canvas.id)
            }
            Divider()
            Button(AppCopy.text("common.delete"), role: .destructive) { selecting(layer, canvas) { state.deleteSelectedLayer() } }
        }
    }

    private func selecting(_ layer: MediaLayer, _ canvas: MediaCanvas, then action: () -> Void) {
        state.select(canvas: canvas.id, layer: layer.id)
        action()
    }

    private func beginRename(_ id: String) {
        renaming = id
        renameFocused = true
    }

    /// One line of the tree. The row paints its own selection so it tracks the board, not the list's focus.
    private func row<Trailing: View>(
        id: String,
        systemImage: String,
        name: Binding<String>,
        selected: Bool,
        weight: Font.Weight,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            if renaming == id {
                TextField("", text: name)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { renaming = nil }
                    .onChange(of: renameFocused) { _, focused in if !focused { renaming = nil } }
            } else {
                Text(name.wrappedValue).lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing()
        }
        .font(.system(size: 12, weight: weight))
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(
            selected ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename(id) })
    }

    private func rowToggle(_ systemImage: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 16)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    private static func icon(for layer: MediaLayer) -> String {
        switch layer.kind {
        case .text: return "textformat"
        case .image: return "photo"
        case .shape: return (MediaTool(rawValue: layer.shape.rawValue) ?? .rectangle).systemImage
        case .video: return "film"
        case .icon: return "seal"
        case .path: return layer.arrow ? "arrow.up.right" : "scribble"
        }
    }
}

// MARK: - Inspector

/// Properties of the selected layer, or of the selected canvas when no layer is.
struct MediaInspector: View {
    @ObservedObject var state: MediaEditorState
    @ObservedObject var model: AppModel
    @State private var exportFormat: MediaExportFormat = .png
    @State private var exportScale: CGFloat = 1
    @State private var openGroup: String? = "phone"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if state.tool == .frame {
                    framePresets
                } else if let canvas = state.canvas {
                    if let layer = state.layer {
                        layerInspector(layer, in: canvas)
                    } else {
                        canvasInspector(canvas)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.small)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Canvas sizes

    /// Shown while the canvas tool is active: pick a ready-made size, or drag one out on the board.
    @ViewBuilder
    private var framePresets: some View {
        Text(AppCopy.text("studio.addCanvas"))
            .font(.system(size: 12, weight: .semibold))
            .padding(12)
        Divider()
        ForEach(MediaFrameGroup.all) { group in
            DisclosureGroup(isExpanded: Binding(
                get: { openGroup == group.id },
                set: { openGroup = $0 ? group.id : nil }
            )) {
                ForEach(group.presets) { preset in
                    Button {
                        state.addCanvas(MediaCanvas(name: preset.name, width: preset.width, height: preset.height))
                        state.tool = .move
                    } label: {
                        HStack {
                            Text(preset.name).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(verbatim: "\(Int(preset.width))×\(Int(preset.height))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12))
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } label: {
                Text(group.title).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
        }
    }

    // MARK: Layer

    @ViewBuilder
    private func layerInspector(_ layer: MediaLayer, in canvas: MediaCanvas) -> some View {
        section(AppCopy.text("studio.position")) {
            HStack(spacing: 2) {
                alignButton("align.horizontal.left") { state.alignSelectedLayer(horizontal: 0) }
                alignButton("align.horizontal.center") { state.alignSelectedLayer(horizontal: 0.5) }
                alignButton("align.horizontal.right") { state.alignSelectedLayer(horizontal: 1) }
                Spacer()
                alignButton("align.vertical.top") { state.alignSelectedLayer(vertical: 0) }
                alignButton("align.vertical.center") { state.alignSelectedLayer(vertical: 0.5) }
                alignButton("align.vertical.bottom") { state.alignSelectedLayer(vertical: 1) }
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    numberField("X", bind(layer, canvas, \.x))
                    numberField("Y", bind(layer, canvas, \.y))
                }
                GridRow {
                    numberField("W", bind(layer, canvas, \.width))
                    numberField("H", bind(layer, canvas, \.height))
                }
            }
            numberField(AppCopy.text("studio.rotation"), bind(layer, canvas, \.rotation))
        }

        section(AppCopy.text("studio.appearance")) {
            labeled(AppCopy.text("studio.opacity")) {
                Slider(value: bind(layer, canvas, \.opacity, undoable: false), in: 0.05...1)
            }
            if layer.kind == .image || (layer.kind == .shape && layer.shape == .rectangle) {
                labeled(AppCopy.text("studio.cornerRadius")) {
                    Slider(
                        value: bind(layer, canvas, \.cornerRadius, undoable: false),
                        in: 0...max(1, min(layer.width, layer.height) / 2)
                    )
                }
            }
            labeled(AppCopy.text("studio.shadow")) {
                Slider(value: bind(layer, canvas, \.shadow, undoable: false), in: 0...80)
            }
        }

        if layer.comment {
            section(AppCopy.text("studio.tool.comment")) {
                TextEditor(text: bind(layer, canvas, \.text, undoable: false))
                    .font(.system(size: 12))
                    .frame(height: 90)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }

        switch layer.kind {
        case .text:
            section(AppCopy.text("studio.layer.text")) {
                TextEditor(text: bind(layer, canvas, \.text, undoable: false))
                    .font(.system(size: 12))
                    .frame(height: 70)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                HStack {
                    numberField(AppCopy.text("studio.fontSize"), bind(layer, canvas, \.fontSize))
                    Picker("", selection: bind(layer, canvas, \.fontDesign)) {
                        ForEach(MediaLayer.FontDesign.allCases, id: \.self) { design in
                            Text(AppCopy.text("studio.font.\(design.rawValue)")).tag(design)
                        }
                    }
                    .labelsHidden()
                }
                Picker("", selection: bind(layer, canvas, \.fontWeight)) {
                    ForEach(MediaLayer.Weight.allCases, id: \.self) { weight in
                        Text(AppCopy.text("studio.weight.\(weight.rawValue)")).tag(weight)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Picker("", selection: bind(layer, canvas, \.alignment)) {
                    Image(systemName: "text.alignleft").tag(MediaLayer.Alignment.leading)
                    Image(systemName: "text.aligncenter").tag(MediaLayer.Alignment.center)
                    Image(systemName: "text.alignright").tag(MediaLayer.Alignment.trailing)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Zero is a straight line; either side bends the text up or down along an arc.
                labeled(AppCopy.text("studio.tool.textPath")) {
                    Slider(value: bind(layer, canvas, \.arc, undoable: false), in: -300...300)
                }
            }
        case .shape:
            section(AppCopy.text("studio.layer.shape")) {
                Picker("", selection: bind(layer, canvas, \.shape)) {
                    ForEach(MediaLayer.Shape.allCases, id: \.self) { shape in
                        Text(AppCopy.text("studio.shape.\(shape.rawValue)")).tag(shape)
                    }
                }
                .labelsHidden()
            }
        case .path:
            section(AppCopy.text("studio.stroke")) {
                Slider(value: bind(layer, canvas, \.strokeWidth, undoable: false), in: 1...40)
                Toggle(AppCopy.text("studio.shape.arrow"), isOn: bind(layer, canvas, \.arrow))
            }
        case .icon:
            section(AppCopy.text("studio.layer.icon")) {
                TextField(AppCopy.text("studio.symbol"), text: bind(layer, canvas, \.symbol, undoable: false))
                    .textFieldStyle(.roundedBorder)
            }
        case .image:
            section(AppCopy.text("studio.ai.kind.image")) {
                TextField(
                    AppCopy.text("studio.imagePrompt"),
                    text: Binding(
                        get: { state.layer?.prompt ?? "" },
                        set: { value in
                            state.updateLayer(layer.id, in: canvas.id) { $0.prompt = value.isEmpty ? nil : value }
                            state.commit()
                        }
                    ),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                Button {
                    state.generateImage(for: state.layer ?? layer, in: canvas.id, model: model)
                } label: {
                    Label(AppCopy.text("studio.generateImage"), systemImage: "sparkles")
                }
                .disabled(state.aiBusy || (layer.prompt ?? "").isEmpty)
            }
        case .video:
            if let name = layer.assetName {
                section(AppCopy.text("studio.ai.kind.video")) {
                    Button(AppCopy.text("studio.playVideo")) { NSWorkspace.shared.open(state.assetURL(name)) }
                }
            }
        }

        if layer.kind != .video {
            section(AppCopy.text("studio.fill")) {
                HexColorPicker(title: AppCopy.text("studio.fill"), hex: bind(layer, canvas, \.colorHex, undoable: false))
                optionalColor(AppCopy.text("studio.gradient"), layer, canvas, \.gradientHex, initial: "#FFFFFF")
            }
        }
        if layer.kind == .shape {
            section(AppCopy.text("studio.stroke")) {
                optionalColor(AppCopy.text("studio.stroke"), layer, canvas, \.strokeHex, initial: "#111111")
                if layer.strokeHex != nil {
                    Slider(value: bind(layer, canvas, \.strokeWidth, undoable: false), in: 0...40)
                }
            }
        }

        exportSection(name: layer.name) {
            MediaExport.data(of: layer, format: exportFormat, scale: exportScale, assetURL: state.assetURL)
        }

        HStack {
            Button(AppCopy.text("studio.duplicate")) { state.duplicateSelectedLayer() }
            Button(AppCopy.text("common.delete"), role: .destructive) { state.deleteSelectedLayer() }
        }
        .padding(12)
    }

    // MARK: Canvas

    @ViewBuilder
    private func canvasInspector(_ canvas: MediaCanvas) -> some View {
        section(AppCopy.text("studio.size")) {
            HStack(spacing: 8) {
                numberField("W", bind(canvas, \.width))
                numberField("H", bind(canvas, \.height))
            }
            Menu(AppCopy.text("studio.size")) {
                ForEach(MediaFrameGroup.all) { group in
                    Menu(group.title) {
                        ForEach(group.presets) { preset in
                            Button("\(preset.name)  \(Int(preset.width)) × \(Int(preset.height))") {
                                state.checkpoint()
                                state.updateCanvas(canvas.id) {
                                    $0.width = preset.width
                                    $0.height = preset.height
                                }
                                state.commit()
                            }
                        }
                    }
                }
            }
        }
        section(AppCopy.text("studio.fill")) {
            HexColorPicker(title: AppCopy.text("studio.background"), hex: bind(canvas, \.backgroundHex, undoable: false))
        }
        exportSection(name: canvas.name) {
            MediaExport.data(
                of: canvas, nested: state.descendants(of: canvas.id), format: exportFormat, scale: exportScale,
                assetURL: state.assetURL
            )
        }
        VStack(alignment: .leading, spacing: 8) {
            if state.project.canvases.count > 1 {
                Button {
                    // Nested canvases come out as part of their parent, not as files of their own.
                    MediaExport.saveAll(
                        state.project.canvases.filter { $0.parentID == nil },
                        nested: { state.descendants(of: $0.id) },
                        format: exportFormat, scale: exportScale, assetURL: state.assetURL
                    )
                } label: {
                    Label(AppCopy.text("studio.exportAll"), systemImage: "square.and.arrow.down.on.square")
                }
            }
            Button(AppCopy.text("studio.deleteCanvas"), role: .destructive) { state.deleteSelectedCanvas() }
        }
        .padding(12)
    }

    // MARK: Pieces

    @ViewBuilder
    private func exportSection(name: String, data: @escaping () -> Data?) -> some View {
        section(AppCopy.text("studio.export")) {
            HStack {
                Picker("", selection: $exportScale) {
                    ForEach([0.5, 1, 2, 3] as [CGFloat], id: \.self) { scale in
                        Text(verbatim: "\(scale.formatted())x").tag(scale)
                    }
                }
                // A PDF is vector; scale means nothing there.
                .disabled(exportFormat == .pdf)
                Picker("", selection: $exportFormat) {
                    ForEach(MediaExportFormat.allCases) { Text(verbatim: $0.title).tag($0) }
                }
            }
            .labelsHidden()
            Button {
                MediaExport.save(data(), name: name, format: exportFormat)
            } label: {
                Label("\(AppCopy.text("studio.export")) \(name)", systemImage: "square.and.arrow.down")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold))
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        Divider()
    }

    private func alignButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A colour that can be switched off entirely, such as a gradient stop or a stroke.
    private func optionalColor(
        _ title: String,
        _ layer: MediaLayer,
        _ canvas: MediaCanvas,
        _ keyPath: WritableKeyPath<MediaLayer, String?>,
        initial: String
    ) -> some View {
        let state = state
        return HStack {
            Toggle(title, isOn: Binding(
                get: { state.layer?[keyPath: keyPath] != nil },
                set: { isOn in
                    state.checkpoint()
                    state.updateLayer(layer.id, in: canvas.id) {
                        $0[keyPath: keyPath] = isOn ? initial : nil
                        if isOn, keyPath == \.strokeHex, $0.strokeWidth == 0 { $0.strokeWidth = 2 }
                    }
                    state.commit()
                }
            ))
            Spacer()
            if layer[keyPath: keyPath] != nil {
                HexColorPicker(title: "", hex: Binding(
                    get: { state.layer?[keyPath: keyPath] ?? initial },
                    set: { value in
                        state.updateLayer(layer.id, in: canvas.id) { $0[keyPath: keyPath] = value }
                        state.commit()
                    }
                ))
                .labelsHidden()
            }
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func numberField(_ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, value: value, format: .number.precision(.fractionLength(0)).grouping(.never))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
    }

    /// Continuous controls (sliders, colour wells, typing) pass `undoable: false`
    /// so one gesture does not flood the undo history.
    private func bind<Value>(
        _ layer: MediaLayer,
        _ canvas: MediaCanvas,
        _ keyPath: WritableKeyPath<MediaLayer, Value>,
        undoable: Bool = true
    ) -> Binding<Value> {
        let state = state
        return Binding(
            get: { state.layer?[keyPath: keyPath] ?? layer[keyPath: keyPath] },
            set: { value in
                if undoable { state.checkpoint() }
                state.updateLayer(layer.id, in: canvas.id) { $0[keyPath: keyPath] = value }
                state.commit()
            }
        )
    }

    private func bind<Value>(
        _ canvas: MediaCanvas,
        _ keyPath: WritableKeyPath<MediaCanvas, Value>,
        undoable: Bool = true
    ) -> Binding<Value> {
        let state = state
        return Binding(
            get: { state.canvas?[keyPath: keyPath] ?? canvas[keyPath: keyPath] },
            set: { value in
                if undoable { state.checkpoint() }
                state.updateCanvas(canvas.id) { $0[keyPath: keyPath] = value }
                state.commit()
            }
        )
    }
}
