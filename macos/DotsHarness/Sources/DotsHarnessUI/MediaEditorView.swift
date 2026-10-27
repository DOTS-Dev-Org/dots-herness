// Copyright (c) 2026 DOTS
// Media editor: layers on the left, a zoomable board of canvases, the inspector on the right.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DotsHarnessCore

/// A resize grip, placed by its fraction along each side of the frame it resizes.
private struct ResizeHandle: Identifiable {
    let fx: CGFloat
    let fy: CGFloat
    var id: String { "\(fx)-\(fy)" }

    static let all: [ResizeHandle] = [0, 0.5, 1].flatMap { fx in
        [0, 0.5, 1].compactMap { fy in fx == 0.5 && fy == 0.5 ? nil : ResizeHandle(fx: fx, fy: fy) }
    }
    /// A canvas grows from its top-left corner, so only the far edges move.
    static let canvas = all.filter { $0.fx != 0 && $0.fy != 0 }

    func apply(dx: Double, dy: Double, x: inout Double, y: inout Double, width: inout Double, height: inout Double) {
        let minimum = 8.0
        if fx == 0 {
            let delta = min(dx, width - minimum)
            x += delta
            width -= delta
        } else if fx == 1 {
            width = max(minimum, width + dx)
        }
        if fy == 0 {
            let delta = min(dy, height - minimum)
            y += delta
            height -= delta
        } else if fy == 1 {
            height = max(minimum, height + dy)
        }
        x = x.rounded()
        y = y.rounded()
        width = width.rounded()
        height = height.rounded()
    }
}

struct MediaEditorView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: MediaStudioStore
    @StateObject private var state: MediaEditorState

    @State private var prompt = ""
    @State private var aiKind: MediaEditorState.AIKind = .design
    @State private var showSettings = false
    /// The layer or canvas as it was when the current drag began.
    @State private var dragLayer: MediaLayer?
    @State private var dragCanvas: MediaCanvas?
    @State private var panStart: CGSize?
    /// The shape being dragged out, and the points of a pen or pencil stroke in progress; board coordinates.
    @State private var draftBox: (start: CGPoint, end: CGPoint)?
    @State private var draftPoints: [CGPoint] = []
    /// The tool each dock group last used, so its button brings that one back.
    @State private var groupTool: [String: MediaTool] = [:]
    /// The dock menu that is open, by group id.
    @State private var openMenu: String?
    @State private var actionSearch = ""
    /// Canvases nested in the one being dragged, as they were when the drag began.
    @State private var dragCarried: [MediaCanvas] = []
    @FocusState private var boardFocused: Bool

    private static let board = "media-board"

    /// A request typed on the Media home screen; run once when the editor opens.
    @State private var initialPrompt: String

    init(model: AppModel, project: MediaProject, initialPrompt: String = "") {
        self.model = model
        self.store = model.mediaStudio
        _initialPrompt = State(initialValue: initialPrompt)
        _state = StateObject(wrappedValue: MediaEditorState(project: project, store: model.mediaStudio))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                // The side panels give way before the board does, so the dock keeps its room in a narrow window.
                MediaLayersPanel(state: state)
                    .frame(minWidth: 160, idealWidth: 230, maxWidth: 230)
                Divider()
                board
                    .frame(minWidth: 340)
                    .layoutPriority(1)
                Divider()
                MediaInspector(state: state, model: model)
                    .frame(minWidth: 200, idealWidth: 250, maxWidth: 250)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showSettings) {
            MediaSettingsSheet(model: model)
        }
        .onAppear {
            state.startScrollMonitor()
            if !initialPrompt.isEmpty {
                state.runAI(prompt: initialPrompt, kind: .design, model: model)
                initialPrompt = ""
            }
        }
        .onDisappear {
            state.stopScrollMonitor()
            state.commit()
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                state.commit()
                store.openProjectID = nil
            } label: {
                Label(AppCopy.text("studio.projects"), systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            TextField(AppCopy.text("studio.projectName"), text: Binding(
                get: { state.project.name },
                set: {
                    state.project.name = $0
                    state.commit()
                }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: 220)

            Spacer(minLength: 8)

            Button { state.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!state.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .help(AppCopy.text("studio.undo"))
            Button { state.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!state.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help(AppCopy.text("studio.redo"))

            Divider().frame(height: 16)

            Button { state.zoom(by: 1 / 1.25) } label: { Image(systemName: "minus") }
                .help(AppCopy.text("studio.zoomOut"))
            Button { state.fit() } label: {
                Text("\(Int((state.zoom * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 40)
            }
            .help(AppCopy.text("studio.zoomFit"))
            Button { state.zoom(by: 1.25) } label: { Image(systemName: "plus") }
                .help(AppCopy.text("studio.zoomIn"))

            Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                .help(AppCopy.text("studio.settings.title"))
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    // MARK: Board

    private var board: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)

                // Parents before their children, sections under their neighbours. A canvas that is wholly
                // off screen is not built at all, which is what keeps a large board cheap to redraw.
                ForEach(state.orderedCanvases) { canvas in
                    if isOnScreen(canvas, in: proxy.size) {
                        canvasView(canvas)
                    }
                }

                if state.tool != .move {
                    // A drawing tool owns every press on the board, whatever lies under the pointer.
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(toolGesture)
                    draftPreview
                }

                promptBar(in: proxy.size)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .coordinateSpace(name: Self.board)
            .gesture(panGesture)
            .onTapGesture {
                state.layerID = nil
                boardFocused = true
            }
            .contextMenu { boardMenu }
            .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers, location in
                drop(providers, at: state.boardPoint(location))
                return true
            }
            .onCopyCommand { clipProviders(cut: false) }
            .onCutCommand { clipProviders(cut: true) }
            .onPasteCommand(of: [.json, .fileURL, .image]) { _ in state.paste() }
            .onContinuousHover(coordinateSpace: .named(Self.board)) { phase in
                if case .active(let point) = phase { state.hover = point } else { state.hover = nil }
            }
            .onChange(of: proxy.size, initial: true) { _, size in
                state.viewport = size
                state.fitOnce()
            }
            .focusable(true, interactions: .edit)
            .focusEffectDisabled()
            .focused($boardFocused)
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                state.deleteSelection()
                return .handled
            }
            .onKeyPress(keys: [.return, .escape]) { _ in
                finishPen()
                openMenu = nil
                state.tool = .move
                return .handled
            }
            .onKeyPress(characters: .letters) { press in
                if press.modifiers.contains(.command) {
                    guard press.modifiers.contains(.shift), press.characters.lowercased() == "k" else { return .ignored }
                    state.importFiles()
                    return .handled
                }
                guard let tool = MediaTool.all.first(where: { $0.key.map(String.init) == press.characters }) else { return .ignored }
                pick(tool)
                return .handled
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                guard state.layer != nil else { return .ignored }
                let step: Double = press.modifiers.contains(.shift) ? 10 : 1
                switch press.key {
                case .leftArrow: state.nudge(dx: -step, dy: 0)
                case .rightArrow: state.nudge(dx: step, dy: 0)
                case .upArrow: state.nudge(dx: 0, dy: -step)
                default: state.nudge(dx: 0, dy: step)
                }
                return .handled
            }
            // Canvas coordinates are absolute; a right-to-left interface must not mirror the board.
            .environment(\.layoutDirection, .leftToRight)
        }
        .overlay {
            // A click anywhere on the board closes an open tool menu.
            if openMenu != nil {
                Color.clear.contentShape(Rectangle()).onTapGesture { openMenu = nil }
            }
        }
        .overlay(alignment: .bottom) { dock.padding(.bottom, 12) }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.board))
            .onChanged { value in
                let start = panStart ?? state.pan
                panStart = start
                state.pan = CGSize(
                    width: start.width + value.translation.width,
                    height: start.height + value.translation.height
                )
            }
            .onEnded { _ in panStart = nil }
    }

    // MARK: Clipboard, menus and drops

    private func isOnScreen(_ canvas: MediaCanvas, in viewport: CGSize) -> Bool {
        let origin = state.screenOrigin(of: canvas)
        return CGRect(x: origin.x, y: origin.y, width: canvas.width * state.zoom, height: canvas.height * state.zoom)
            .insetBy(dx: -60, dy: -60)
            .intersects(CGRect(origin: .zero, size: viewport))
    }

    /// What Edit ▸ Copy and Cut hand to the system; the editor also keeps its own copy.
    private func clipProviders(cut: Bool) -> [NSItemProvider] {
        guard let data = state.copySelection() else { return [] }
        if cut { state.deleteSelection() }
        return [NSItemProvider(item: data as NSData, typeIdentifier: UTType.json.identifier)]
    }

    /// Where the pointer is on the board, so a paste from a menu lands under it.
    private var pointerOnBoard: CGPoint? { state.hover.map(state.boardPoint) }

    @ViewBuilder
    private var pasteAndAdd: some View {
        Button(AppCopy.text("studio.paste")) { state.paste(at: pointerOnBoard) }
        Button(AppCopy.text("studio.layer.upload")) { state.importFiles() }
    }

    @ViewBuilder
    private var boardMenu: some View {
        pasteAndAdd
        Divider()
        Button(AppCopy.text("studio.zoomFit")) { state.fit() }
    }

    @ViewBuilder
    private func canvasMenu(_ canvas: MediaCanvas) -> some View {
        pasteAndAdd
        Divider()
        Button(AppCopy.text("studio.cut")) { selectCanvas(canvas.id); state.cutSelection() }
        Button(AppCopy.text("conversation.copy")) { selectCanvas(canvas.id); state.copySelection() }
        Button(AppCopy.text("studio.duplicate")) { selectCanvas(canvas.id); state.duplicateSelectedCanvas() }
        Divider()
        Button(AppCopy.text("studio.deleteCanvas"), role: .destructive) { selectCanvas(canvas.id); state.deleteSelectedCanvas() }
    }

    @ViewBuilder
    private func layerMenu(_ layer: MediaLayer, in canvas: MediaCanvas) -> some View {
        let select = { state.select(canvas: canvas.id, layer: layer.id) }
        Button(AppCopy.text("studio.cut")) { select(); state.cutSelection() }
        Button(AppCopy.text("conversation.copy")) { select(); state.copySelection() }
        Button(AppCopy.text("studio.paste")) { state.paste(at: pointerOnBoard) }
        Button(AppCopy.text("studio.duplicate")) { select(); state.duplicateSelectedLayer() }
        Divider()
        Button(AppCopy.text("studio.layer.front")) { select(); state.reorderSelectedLayer(toFront: true) }
        Button(AppCopy.text("studio.layer.back")) { select(); state.reorderSelectedLayer(toFront: false) }
        Divider()
        Button(AppCopy.text("common.delete"), role: .destructive) { select(); state.deleteSelectedLayer() }
    }

    /// Files become layers where they were let go; a picture dragged without a file is saved first.
    private func drop(_ providers: [NSItemProvider], at point: CGPoint) {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in state.addFiles([url], at: point) }
                }
            } else {
                _ = provider.loadDataRepresentation(for: .image) { data, _ in
                    guard let data, let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
                    else { return }
                    Task { @MainActor in state.addImageData(png, at: point) }
                }
            }
        }
    }

    // MARK: Tools

    private func pick(_ tool: MediaTool) {
        finishPen()
        openMenu = nil
        state.tool = tool
        if let group = Self.toolGroups.first(where: { $0.tools.contains(tool) }) { groupTool[group.id] = tool }
        boardFocused = true
    }

    /// A pen path ends on Return, Escape, a second click on its last point, or a change of tool.
    private func finishPen() {
        if state.tool == .pen, draftPoints.count >= 2 { state.addPath(draftPoints, name: MediaTool.pen.title) }
        draftPoints = []
    }

    private var toolGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.board))
            .onChanged { value in
                let point = state.boardPoint(value.location)
                switch state.tool {
                case .hand:
                    let start = panStart ?? state.pan
                    panStart = start
                    state.pan = CGSize(
                        width: start.width + value.translation.width,
                        height: start.height + value.translation.height
                    )
                case .pencil, .marker:
                    // Skip points closer than two screen points: enough for a smooth line, far fewer to store.
                    if let last = draftPoints.last, hypot(point.x - last.x, point.y - last.y) * state.zoom < 2 { return }
                    draftPoints.append(point)
                case .scale:
                    // Dragging right grows the selection, left shrinks it; a layer if one is selected, else its canvas.
                    guard let canvas = state.canvas else { return }
                    if let layer = state.layer {
                        let start = beginLayerDrag(layer, in: canvas)
                        state.scale(start, in: canvas.id, by: max(0.05, 1 + value.translation.width / state.zoom / start.width))
                    } else {
                        let start = beginCanvasDrag(canvas)
                        state.scale(start, by: max(0.05, 1 + value.translation.width / state.zoom / start.width))
                    }
                case .pen, .move:
                    break
                default:
                    draftBox = (state.boardPoint(value.startLocation), point)
                }
            }
            .onEnded { value in
                let point = state.boardPoint(value.location)
                boardFocused = true
                switch state.tool {
                case .hand:
                    panStart = nil
                case .scale:
                    endDrag()
                case .pencil, .marker:
                    if state.tool == .marker {
                        state.addPath(draftPoints, name: MediaTool.marker.title, colorHex: "#FFD400", strokeWidth: 24, opacity: 0.42)
                    } else {
                        state.addPath(draftPoints, name: MediaTool.pencil.title)
                    }
                    draftPoints = []
                case .pen:
                    if let last = draftPoints.last, hypot(point.x - last.x, point.y - last.y) * state.zoom < 6 {
                        finishPen()
                    } else {
                        draftPoints.append(point)
                    }
                case .move:
                    break
                default:
                    state.place(state.tool, from: state.boardPoint(value.startLocation), to: point)
                    draftBox = nil
                }
            }
    }

    @ViewBuilder
    private var draftPreview: some View {
        Group {
            if let box = draftBox {
                let start = state.screenPoint(box.start)
                let end = state.screenPoint(box.end)
                if state.tool == .line || state.tool == .arrow {
                    Path { $0.addLines([start, end]) }.stroke(Color.accentColor, lineWidth: 1.5)
                } else {
                    Rectangle()
                        .stroke(Color.accentColor, lineWidth: 1.5)
                        .frame(width: abs(end.x - start.x), height: abs(end.y - start.y))
                        .offset(x: min(start.x, end.x), y: min(start.y, end.y))
                }
            }
            if !draftPoints.isEmpty {
                let points = draftPoints.map(state.screenPoint)
                Path { $0.addLines(points) }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                if state.tool == .pen {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        Circle().fill(Color.white)
                            .overlay { Circle().stroke(Color.accentColor, lineWidth: 1.5) }
                            .frame(width: 7, height: 7)
                            .offset(x: point.x - 3.5, y: point.y - 3.5)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func canvasView(_ canvas: MediaCanvas) -> some View {
        let origin = state.screenOrigin(of: canvas)
        let zoom = state.zoom
        let isSelected = state.canvasID == canvas.id
        // While one of its layers is dragged the canvas stops clipping, so the layer stays in view on its way to another canvas.
        let isDraggingLayer = isSelected && dragLayer != nil

        // The name tag doubles as the grip that moves the canvas around the board.
        Text(verbatim: "\(canvas.name)  \(Int(canvas.width)) × \(Int(canvas.height))")
            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture { selectCanvas(canvas.id) }
            .gesture(canvasMoveGesture(canvas))
            .offset(x: origin.x, y: origin.y - 22)

        ZStack(alignment: .topLeading) {
            Color(hex: canvas.backgroundHex)
                .onTapGesture { selectCanvas(canvas.id) }
                .contextMenu { canvasMenu(canvas) }
            ForEach(canvas.layers.filter { !$0.hidden }) { layer in
                MediaLayerContent(layer: layer, assetURL: layer.assetName.map(state.assetURL))
                    .help(layer.comment ? layer.text : "")
                    .contentShape(Rectangle())
                    .onTapGesture {
                        state.select(canvas: canvas.id, layer: layer.id)
                        boardFocused = true
                    }
                    .gesture(layerMoveGesture(layer, in: canvas))
                    .contextMenu { layerMenu(layer, in: canvas) }
                    // A locked layer lets clicks through to whatever is under it; the layers panel still selects it.
                    .allowsHitTesting(!layer.locked)
                    .offset(x: layer.x, y: layer.y)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .clipShape(Rectangle().inset(by: isDraggingLayer ? -100_000 : 0))
        .contentShape(Rectangle())
        .scaleEffect(zoom, anchor: .topLeading)
        .frame(width: canvas.width * zoom, height: canvas.height * zoom, alignment: .topLeading)
        .overlay {
            Rectangle().stroke(isSelected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .offset(x: origin.x, y: origin.y)
        .zIndex(isDraggingLayer ? 1 : 0)

        if isSelected {
            if let layer = state.layer {
                selectionFrame(
                    CGRect(
                        x: origin.x + layer.x * zoom,
                        y: origin.y + layer.y * zoom,
                        width: layer.width * zoom,
                        height: layer.height * zoom
                    ),
                    // ponytail: grips assume an upright frame; a rotated layer is resized from the inspector.
                    handles: layer.rotation == 0 && !layer.locked ? ResizeHandle.all : [],
                    rotation: layer.rotation,
                    badge: "\(Int(layer.width)) × \(Int(layer.height))"
                ) { handle in layerResizeGesture(handle, layer: layer, in: canvas) }
            } else {
                selectionFrame(
                    CGRect(x: origin.x, y: origin.y, width: canvas.width * zoom, height: canvas.height * zoom),
                    handles: ResizeHandle.canvas,
                    badge: "\(Int(canvas.width)) × \(Int(canvas.height))"
                ) { handle in canvasResizeGesture(handle, canvas: canvas) }
            }
        }
    }

    private func selectCanvas(_ id: String) {
        state.select(canvas: id)
        boardFocused = true
    }

    private func selectionFrame<G: Gesture>(
        _ rect: CGRect,
        handles: [ResizeHandle],
        rotation: Double = 0,
        badge: String,
        gesture: @escaping (ResizeHandle) -> G
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(Color.accentColor, lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .rotationEffect(.degrees(rotation))
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
            Text(verbatim: badge)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3))
                .fixedSize()
                .frame(width: max(rect.width, 1))
                .offset(x: rect.minX, y: rect.maxY + 6)
                .allowsHitTesting(false)
            ForEach(handles) { handle in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .overlay { RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor, lineWidth: 1.5) }
                    .frame(width: 9, height: 9)
                    // A larger hit area than the drawn grip, so it is easy to grab.
                    .padding(5)
                    .contentShape(Rectangle())
                    .gesture(gesture(handle))
                    .offset(
                        x: rect.minX + rect.width * handle.fx - 9.5,
                        y: rect.minY + rect.height * handle.fy - 9.5
                    )
            }
        }
    }

    // MARK: Gestures

    private func layerMoveGesture(_ layer: MediaLayer, in canvas: MediaCanvas) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.board))
            .onChanged { value in
                let start = beginLayerDrag(layer, in: canvas)
                state.updateLayer(layer.id, in: canvas.id) {
                    $0.x = (start.x + value.translation.width / state.zoom).rounded()
                    $0.y = (start.y + value.translation.height / state.zoom).rounded()
                }
            }
            .onEnded { _ in endDrag() }
    }

    private func layerResizeGesture(_ handle: ResizeHandle, layer: MediaLayer, in canvas: MediaCanvas) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.board))
            .onChanged { value in
                let start = beginLayerDrag(layer, in: canvas)
                state.updateLayer(layer.id, in: canvas.id) { target in
                    target.x = start.x
                    target.y = start.y
                    target.width = start.width
                    target.height = start.height
                    handle.apply(
                        dx: value.translation.width / state.zoom,
                        dy: value.translation.height / state.zoom,
                        x: &target.x, y: &target.y, width: &target.width, height: &target.height
                    )
                }
            }
            .onEnded { _ in endDrag() }
    }

    private func canvasMoveGesture(_ canvas: MediaCanvas) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.board))
            .onChanged { value in
                let start = beginCanvasDrag(canvas)
                let dx = (value.translation.width / state.zoom).rounded()
                let dy = (value.translation.height / state.zoom).rounded()
                for moved in [start] + dragCarried {
                    state.updateCanvas(moved.id) {
                        $0.x = moved.x + dx
                        $0.y = moved.y + dy
                    }
                }
            }
            .onEnded { _ in endDrag() }
    }

    private func canvasResizeGesture(_ handle: ResizeHandle, canvas: MediaCanvas) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.board))
            .onChanged { value in
                let start = beginCanvasDrag(canvas)
                state.updateCanvas(canvas.id) { target in
                    target.width = start.width
                    target.height = start.height
                    var x = start.x
                    var y = start.y
                    handle.apply(
                        dx: value.translation.width / state.zoom,
                        dy: value.translation.height / state.zoom,
                        x: &x, y: &y, width: &target.width, height: &target.height
                    )
                }
            }
            .onEnded { _ in endDrag() }
    }

    /// The first change of a drag records the undo point and the starting frame.
    private func beginLayerDrag(_ layer: MediaLayer, in canvas: MediaCanvas) -> MediaLayer {
        if let dragLayer, dragLayer.id == layer.id { return dragLayer }
        state.checkpoint()
        state.select(canvas: canvas.id, layer: layer.id)
        dragLayer = layer
        return layer
    }

    private func beginCanvasDrag(_ canvas: MediaCanvas) -> MediaCanvas {
        if let dragCanvas, dragCanvas.id == canvas.id { return dragCanvas }
        state.checkpoint()
        state.select(canvas: canvas.id)
        dragCanvas = canvas
        dragCarried = state.descendants(of: canvas.id)
        return canvas
    }

    private func endDrag() {
        // Where it was let go decides where it now belongs.
        if let dragLayer, let canvasID = state.canvasID { state.rehomeLayer(dragLayer.id, from: canvasID) }
        if let dragCanvas { state.reparentCanvas(dragCanvas.id) }
        dragLayer = nil
        dragCanvas = nil
        dragCarried = []
        state.commit()
    }

    // MARK: Dock

    private struct ToolGroup: Identifiable {
        let id: String
        let tools: [MediaTool]
    }

    private static let toolGroups = [
        ToolGroup(id: "move", tools: [.move, .hand, .scale]),
        ToolGroup(id: "frame", tools: [.frame, .section, .slice]),
        ToolGroup(id: "shape", tools: [.rectangle, .line, .arrow, .ellipse, .polygon, .star]),
        ToolGroup(id: "draw", tools: [.pen, .pencil, .marker]),
        ToolGroup(id: "text", tools: [.text, .textPath]),
        ToolGroup(id: "comment", tools: [.comment]),
    ]

    private struct DockAction: Identifiable {
        let id: String
        let systemImage: String
        let title: String
        let enabled: Bool
        let run: () -> Void
    }

    private var dockActions: [DockAction] {
        let hasLayer = state.layer != nil
        let layer = state.layer
        let canvasID = state.canvasID ?? ""
        return [
            DockAction(id: "icon", systemImage: "seal", title: AppCopy.text("studio.layer.icon"), enabled: true) { state.addIcon() },
            DockAction(id: "duplicate", systemImage: "plus.square.on.square", title: AppCopy.text("studio.duplicate"), enabled: hasLayer) {
                state.duplicateSelectedLayer()
            },
            DockAction(id: "front", systemImage: "square.3.layers.3d.top.filled", title: AppCopy.text("studio.layer.front"), enabled: hasLayer) {
                state.reorderSelectedLayer(toFront: true)
            },
            DockAction(id: "back", systemImage: "square.3.layers.3d.bottom.filled", title: AppCopy.text("studio.layer.back"), enabled: hasLayer) {
                state.reorderSelectedLayer(toFront: false)
            },
            DockAction(
                id: "lock", systemImage: layer?.locked == true ? "lock.open" : "lock",
                title: AppCopy.text(layer?.locked == true ? "studio.layer.unlock" : "studio.layer.lock"), enabled: hasLayer
            ) { if let layer { state.toggle(\.locked, layer: layer.id, in: canvasID) } },
            DockAction(id: "unlockAll", systemImage: "lock.open", title: AppCopy.text("studio.unlockAll"), enabled: true) {
                state.unlockAllLayers()
            },
            DockAction(
                id: "hide", systemImage: layer?.hidden == true ? "eye" : "eye.slash",
                title: AppCopy.text(layer?.hidden == true ? "studio.layer.show" : "studio.layer.hide"), enabled: hasLayer
            ) { if let layer { state.toggle(\.hidden, layer: layer.id, in: canvasID) } },
            DockAction(id: "upload", systemImage: "photo", title: AppCopy.text("studio.layer.upload"), enabled: true) { state.importFiles() },
            DockAction(id: "fit", systemImage: "arrow.up.left.and.arrow.down.right", title: AppCopy.text("studio.zoomFit"), enabled: true) {
                state.fit()
            },
            DockAction(id: "undo", systemImage: "arrow.uturn.backward", title: AppCopy.text("studio.undo"), enabled: state.canUndo) { state.undo() },
            DockAction(id: "redo", systemImage: "arrow.uturn.forward", title: AppCopy.text("studio.redo"), enabled: state.canRedo) { state.redo() },
        ]
    }

    /// The tool bar stays at the foot of the board, dark in either appearance, like the tools it borrows from.
    /// Its menus open upward, over the board.
    private var dock: some View {
        HStack(spacing: 6) {
            ForEach(Self.toolGroups) { group in
                toolGroup(group)
            }
            Button {
                actionSearch = ""
                openMenu = openMenu == "actions" ? nil : "actions"
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 16))
                    .frame(width: 32, height: 32)
                    .background(openMenu == "actions" ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(AppCopy.text("studio.actions"))
            .accessibilityLabel(AppCopy.text("studio.actions"))
            .overlay(alignment: .topTrailing) {
                if openMenu == "actions" { Self.raised(actionsPanel, alignment: .bottomTrailing) }
            }
            .zIndex(openMenu == "actions" ? 1 : 0)
        }
        .editorDockChrome()
        .padding(.horizontal, 12)
    }


    /// Hangs `panel` from a zero-size anchor by its bottom edge, so it grows upward over the board
    /// whatever its height. (An alignment guide on the panel itself was ignored and it opened downward.)
    private static func raised(_ panel: some View, alignment: Alignment) -> some View {
        Color.clear
            .frame(width: 0, height: 0)
            .overlay(alignment: alignment) { panel.fixedSize().padding(.bottom, 14) }
    }

    private static func raised(alignment: Alignment, _ panel: some View) -> some View {
        raised(panel, alignment: alignment)
    }

    private func menuPanel<Content: View>(width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 1, content: content)
            .padding(6)
            .frame(width: width, alignment: .leading)
            .background(Color.editorDock, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
            .foregroundStyle(.white)
    }

    private var actionsPanel: some View {
        let query = actionSearch.trimmingCharacters(in: .whitespaces)
        let actions = dockActions.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        return menuPanel(width: 260) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                TextField(AppCopy.text("studio.search"), text: $actionSearch)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        if let first = actions.first(where: \.enabled) {
                            first.run()
                            openMenu = nil
                        }
                    }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(.bottom, 5)
            ForEach(actions) { action in
                DockMenuRow(systemImage: action.systemImage, title: action.title, enabled: action.enabled) {
                    action.run()
                    openMenu = nil
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    /// The group's current tool as a button; the arrow beside it opens the rest of the group above the bar.
    @ViewBuilder
    private func toolGroup(_ group: ToolGroup) -> some View {
        let current = groupTool[group.id] ?? group.tools[0]
        let isActive = group.tools.contains(state.tool)
        let isOpen = openMenu == group.id
        HStack(spacing: 1) {
            Button { pick(current) } label: {
                toolIcon(current)
                    .frame(width: 32, height: 32)
                    .background(isActive ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(current.keyLabel.isEmpty ? current.title : "\(current.title) (\(current.keyLabel))")
            .accessibilityLabel(current.title)

            if group.tools.count > 1 {
                Button { openMenu = isOpen ? nil : group.id } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 6, weight: .bold))
                        .frame(width: 14, height: 32)
                        .background(isOpen ? Color.white.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(alignment: .topLeading) {
            if isOpen {
                Self.raised(alignment: .bottomLeading, menuPanel(width: 200) {
                    ForEach(group.tools, id: \.self) { tool in
                        DockMenuRow(
                            systemImage: tool == .text ? nil : tool.systemImage, title: tool.title,
                            shortcut: tool.keyLabel, checked: tool == current
                        ) { pick(tool) }
                    }
                    if group.id == "shape" {
                        DockMenuRow(systemImage: "photo", title: AppCopy.text("studio.layer.upload"), shortcut: "⇧⌘K") {
                            openMenu = nil
                            state.importFiles()
                        }
                    }
                })
            }
        }
        .zIndex(isOpen ? 1 : 0)
    }

    @ViewBuilder
    private func toolIcon(_ tool: MediaTool) -> some View {
        if tool == .text {
            Text(verbatim: "T").font(.system(size: 18, weight: .regular))
        } else {
            Image(systemName: tool.systemImage).font(.system(size: 16))
        }
    }

    /// The request field sits under the selected canvas and follows it, staying clear of the tool bar
    /// and on screen when the canvas runs past an edge. With no canvas yet it waits above the tool bar.
    private func promptBar(in viewport: CGSize) -> some View {
        let width = min(520, max(240, viewport.width - 24))
        let lowest = max(14, viewport.height - 150)
        var centre = viewport.width / 2
        var top = lowest
        if let canvas = state.canvas {
            let origin = state.screenOrigin(of: canvas)
            centre = origin.x + canvas.width * state.zoom / 2
            top = min(max(origin.y + canvas.height * state.zoom + 32, 14), lowest)
        }
        centre = min(max(centre, width / 2 + 12), max(width / 2 + 12, viewport.width - width / 2 - 12))

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(MediaEditorState.AIKind.allCases) { kind in
                        Button { aiKind = kind } label: { Label(kind.title, systemImage: kind.systemImage) }
                    }
                } label: {
                    Label(aiKind.title, systemImage: aiKind.systemImage)
                }
                .fixedSize()

                TextField(AppCopy.text("studio.ai.placeholder.\(aiKind.rawValue)"), text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .frame(minWidth: 80)
                    .onSubmit(runAI)

                // Sized to its label; squeezed, the menu collapsed to a bare arrow.
                modelMenu
                    .fixedSize()

                if state.aiBusy {
                    Button { state.stopAI() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 20)) }
                        .buttonStyle(.plain)
                        .help(AppCopy.text("common.stop"))
                } else {
                    Button(action: runAI) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(canRunAI ? Color.accentColor : Color.secondary)
                        .disabled(!canRunAI)
                        .help(AppCopy.text("studio.ai.run"))
                }
            }
            if state.aiBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(state.aiStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let error = state.aiError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            if let note = state.aiNote {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
        // Swallow clicks on the bar itself so they do not pan or deselect underneath.
        .onTapGesture {}
        .offset(x: centre - width / 2, y: top)
    }

    /// A next screen needs no words: the screen before it is the brief.
    private var canRunAI: Bool {
        aiKind == .next || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Designs run on a chat model; image and video on the source set in Media settings.
    @ViewBuilder
    private var modelMenu: some View {
        if aiKind == .design || aiKind == .next {
            ChatModelMenu(router: model.router, modelID: $store.settings.plannerModelID)
        } else {
            let kind: MediaKind = aiKind == .video ? .video : .image
            Button { showSettings = true } label: {
                Text(MediaSettingsView.summary(of: store.settings, for: kind)).lineLimit(1)
            }
            .help(AppCopy.text("studio.settings.title"))
        }
    }

    private func runAI() {
        state.runAI(prompt: prompt, kind: aiKind, model: model)
        if state.aiBusy { prompt = "" }
    }
}

/// One line of a dock menu: a tick for the current choice, its mark, its name and its key.
private struct DockMenuRow: View {
    var systemImage: String?
    let title: String
    var shortcut = ""
    var checked = false
    var enabled = true
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(checked ? 1 : 0)
                    .frame(width: 12)
                Group {
                    if let systemImage {
                        Image(systemName: systemImage).font(.system(size: 13))
                    } else {
                        Text(verbatim: "T").font(.system(size: 15))
                    }
                }
                .frame(width: 18)
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: shortcut).font(.system(size: 12)).opacity(0.8)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(hovered && enabled ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovered = $0 }
    }
}

extension Color {
    static let editorDock = Color(white: 0.17)
}

extension View {
    /// The floating dark bar the media and music editors dock their tools in.
    func editorDockChrome() -> some View {
        foregroundStyle(.white)
            .padding(8)
            .background(Color.editorDock, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
    }
}
