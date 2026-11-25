//
//  PhotoToolsView.swift
//  wonni
//
//  The web's photo tools on iOS (2026-11-25, mock https://claude.ai/artifact/1L7JKHqXkmPP5MAkJLn6Eu):
//  tap a photo in Edit → full screen with Cover · Crop · Split · Identify · Delete.
//  - Crop replaces the photo with the cropped one (Free / Square / 4:3).
//  - Split (no AI) cuts it into pieces: Boxes you draw, an even Grid, or Rows.
//  - Identify asks `identifyProductsInImage` (local bytes, so it works before upload)
//    for one box per item; boxes can be moved, resized or tapped away.
//  Split and Identify REPLACE the photo with the pieces, in its place — same as the
//  web (user rule). Like the rest of Edit, photo changes write to the draft at once
//  (not to PendingDraftEdit); the last change can be undone from the toast. Storage
//  copies of replaced photos are deleted when the viewer closes, so Undo stays cheap.
//

import SwiftUI
import SwiftData
import FirebaseAuth
import FirebaseFunctions

// MARK: - Pure geometry (unit-tested in PickerCloseoutTests.swift › PhotoToolsGeometryTests)

enum PhotoToolsGeometry {
    /// Rects are normalized to the image: 0...1 on both axes, origin top-left.
    static let full = CGRect(x: 0, y: 0, width: 1, height: 1)
    static let minSide: CGFloat = 0.05

    static func grid(rows: Int, cols: Int) -> [CGRect] {
        let r = max(1, rows), c = max(1, cols)
        return (0..<r).flatMap { i in
            (0..<c).map { j in
                CGRect(x: CGFloat(j) / CGFloat(c), y: CGFloat(i) / CGFloat(r), width: 1 / CGFloat(c), height: 1 / CGFloat(r))
            }
        }
    }

    static func rows(_ n: Int) -> [CGRect] { grid(rows: n, cols: 1) }

    /// Gemini's `[ymin, xmin, ymax, xmax]`, 0–1000, to a normalized rect. nil if unusable.
    static func rect(fromGeminiBox box: [Double]) -> CGRect? {
        guard box.count == 4 else { return nil }
        let (y0, x0, y1, x1) = (box[0] / 1000, box[1] / 1000, box[2] / 1000, box[3] / 1000)
        let r = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
        // Size check BEFORE clamp: clamp grows tiny boxes to minSide, which would keep junk.
        guard r.width >= 0.01, r.height >= 0.01 else { return nil }
        return clamp(r)
    }

    /// Keeps a rect inside the image and at least `minSide` wide/tall.
    static func clamp(_ r: CGRect) -> CGRect {
        let w = min(max(r.width, minSide), 1), h = min(max(r.height, minSide), 1)
        let x = min(max(r.minX, 0), 1 - w), y = min(max(r.minY, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Normalized rect → pixel rect, rounded to whole pixels and kept inside the image.
    static func pixelRect(_ r: CGRect, imageSize: CGSize) -> CGRect {
        let px = CGRect(x: r.minX * imageSize.width, y: r.minY * imageSize.height,
                        width: r.width * imageSize.width, height: r.height * imageSize.height).integral
        return px.intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// Resizes from the bottom-right corner; `aspect` (width / height in PIXELS) locks the shape.
    static func resized(_ r: CGRect, by delta: CGSize, aspect: CGFloat?, imageSize: CGSize) -> CGRect {
        var w = r.width + delta.width, h = r.height + delta.height
        if let aspect, imageSize.width > 0, imageSize.height > 0 {
            // height in normalized units for a given normalized width at this pixel aspect
            h = w * imageSize.width / imageSize.height / aspect
        }
        w = min(max(w, minSide), 1 - r.minX)
        h = min(max(h, minSide), 1 - r.minY)
        if let aspect, imageSize.width > 0 { w = min(w, h * imageSize.height * aspect / imageSize.width) }
        return CGRect(x: r.minX, y: r.minY, width: w, height: h)
    }

    /// The photo order after replacing `assetId` with `pieces`, in its place.
    static func replacing(_ assetId: String, with pieces: [String], in order: [String]) -> [String] {
        guard let i = order.firstIndex(of: assetId) else { return order + pieces }
        var out = order
        out.replaceSubrange(i...i, with: pieces)
        return out
    }
}

// MARK: - Image helpers

private extension UIImage {
    /// Draws the image upright so pixel crops match what's on screen.
    func uprighted() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size.width * scale, height: size.height * scale), format: format)
            .image { _ in draw(in: CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale))) }
    }

    func scaledToFit(maxSide: CGFloat) -> UIImage {
        let px = pixelSize, longest = max(px.width, px.height)
        guard longest > maxSide else { return self }
        let k = maxSide / longest
        let format = UIGraphicsImageRendererFormat.default(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: px.width * k, height: px.height * k), format: format)
            .image { _ in draw(in: CGRect(origin: .zero, size: CGSize(width: px.width * k, height: px.height * k))) }
    }

    var pixelSize: CGSize { cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? size }

    func cropped(to normalized: CGRect) -> Data? {
        guard let cg = cgImage else { return nil }
        let rect = PhotoToolsGeometry.pixelRect(normalized, imageSize: pixelSize)
        guard rect.width >= 1, rect.height >= 1, let piece = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: piece).jpegData(compressionQuality: 0.9)
    }
}

// MARK: - View

/// Which photo the tools open on (fullScreenCover(item:) needs Identifiable).
struct PhotoToolsTarget: Identifiable { let id: String }

struct PhotoToolsView: View {
    let item: Item
    @State var assetId: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var uploadManager: UploadManager

    enum Mode: Equatable { case menu, crop, split, identify }
    enum SplitKind: String, CaseIterable { case boxes = "Boxes", grid = "Grid", rows = "Rows" }
    enum CropShape: String, CaseIterable { case free = "Free", square = "Square", fourThree = "4:3"
        var aspect: CGFloat? { self == .square ? 1 : self == .fourThree ? 4.0 / 3.0 : nil }
    }

    @State private var image: UIImage?
    @State private var mode: Mode = .menu
    @State private var boxes: [CGRect] = []
    @State private var labels: [String] = []
    @State private var splitKind: SplitKind = .grid
    @State private var gridRows = 2
    @State private var gridCols = 2
    @State private var cropShape: CropShape = .free
    @State private var drawing: CGRect?
    @State private var isWorking = false
    @State private var errorText: String?
    @State private var toast: String?
    @State private var undo: UndoStep?
    /// Storage paths of photos replaced/deleted this session; deleted on close.
    @State private var pathsToDelete: [String] = []

    /// One step back: restore these photos (bytes + uploaded path) in this order.
    struct UndoStep {
        let order: [String]
        let removed: [(assetId: String, data: Data?, path: String?)]
        let added: [String]
        let focus: String
    }

    /// Local bytes first; a camera-roll draft may only hold the PhotoKit id.
    private func loadImage(_ id: String) async -> UIImage? {
        if let local = item.image(for: id) { return local.uprighted() }
        return await PhotoAsset(identifier: id).fullResolutionImage()?.uprighted()
    }

    private var index: Int { item.sourceAssetIdentifiers.firstIndex(of: assetId) ?? 0 }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()
                VStack(spacing: 0) {
                    canvas.padding(12)
                    bottomBar
                }
                if let toast { toastView(toast) }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(mode == .menu ? "Done" : "Cancel") {
                        if mode == .menu { close() } else { leaveTool() }
                    }
                    .accessibilityIdentifier("photoToolsDoneButton")
                }
                if mode != .menu {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }
                            .disabled(!canSave || isWorking)
                            .accessibilityIdentifier("photoToolsSaveButton")
                    }
                }
            }
            .alert("Couldn't do that", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
        .task(id: assetId) { image = await loadImage(assetId) }
    }

    private var title: String {
        switch mode {
        case .menu: return "\(index + 1) of \(item.sourceAssetIdentifiers.count)"
        case .crop: return "Crop"
        case .split: return "Split"
        case .identify: return "Identify"
        }
    }

    private var canSave: Bool {
        switch mode {
        case .menu: return false
        case .crop: return boxes.count == 1
        case .split, .identify: return !boxes.isEmpty
        }
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            if let image {
                let fit = fittedRect(image.pixelSize, in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: fit.width, height: fit.height)
                        .offset(x: fit.minX, y: fit.minY)
                    if mode == .crop, let box = boxes.first {
                        CropDim(box: box, fit: fit).allowsHitTesting(false)
                    }
                    ForEach(boxes.indices, id: \.self) { i in
                        boxView(i, fit: fit)
                    }
                    if let drawing { boxShape(drawing, fit: fit, label: nil, color: .orange.opacity(0.7)) }
                    if isWorking {
                        ProgressView().tint(.white).frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .contentShape(Rectangle())
                .gesture(drawGesture(fit: fit))
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func fittedRect(_ size: CGSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let s = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func onScreen(_ r: CGRect, fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + r.minX * fit.width, y: fit.minY + r.minY * fit.height, width: r.width * fit.width, height: r.height * fit.height)
    }

    private var boxesEditable: Bool { mode == .crop || mode == .identify || (mode == .split && splitKind == .boxes) }

    @ViewBuilder
    private func boxView(_ i: Int, fit: CGRect) -> some View {
        let r = boxes[i]
        let color: Color = mode == .crop ? .white : .orange
        let label = mode == .identify ? (i < labels.count ? labels[i] : nil) : (mode == .split && splitKind == .boxes ? "\(i + 1)" : nil)
        boxShape(r, fit: fit, label: label, color: color)
            .gesture(boxesEditable ? moveGesture(i, fit: fit) : nil)
            .onTapGesture {
                // Tap a box to remove it (Split › Boxes and Identify).
                guard mode == .identify || (mode == .split && splitKind == .boxes) else { return }
                boxes.remove(at: i)
                if i < labels.count { labels.remove(at: i) }
            }
        if boxesEditable {
            let s = onScreen(r, fit: fit)
            Circle().fill(color).frame(width: 22, height: 22)
                .position(x: s.maxX, y: s.maxY)
                .gesture(resizeGesture(i, fit: fit))
                .accessibilityLabel("Resize")
        }
    }

    private func boxShape(_ r: CGRect, fit: CGRect, label: String?, color: Color) -> some View {
        let s = onScreen(r, fit: fit)
        return ZStack(alignment: .topLeading) {
            Rectangle().strokeBorder(color, lineWidth: 2)
                .background(Color.white.opacity(0.001))
            if let label, !label.isEmpty {
                Text(label).font(.caption2.weight(.bold)).lineLimit(1)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(color).foregroundStyle(.black)
            }
        }
        .frame(width: s.width, height: s.height)
        .position(x: s.midX, y: s.midY)
    }

    @State private var dragStart: CGRect?

    private func moveGesture(_ i: Int, fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                guard i < boxes.count else { return }
                if dragStart == nil { dragStart = boxes[i] }
                guard let start = dragStart else { return }
                boxes[i] = PhotoToolsGeometry.clamp(start.offsetBy(dx: v.translation.width / fit.width, dy: v.translation.height / fit.height))
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ i: Int, fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                guard i < boxes.count, let image else { return }
                if dragStart == nil { dragStart = boxes[i] }
                guard let start = dragStart else { return }
                boxes[i] = PhotoToolsGeometry.resized(start, by: CGSize(width: v.translation.width / fit.width, height: v.translation.height / fit.height),
                                                      aspect: mode == .crop ? cropShape.aspect : nil, imageSize: image.pixelSize)
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Split › Boxes: drag on empty space to draw a new box.
    private func drawGesture(fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                guard mode == .split, splitKind == .boxes, fit.width > 0 else { return }
                let a = CGPoint(x: (v.startLocation.x - fit.minX) / fit.width, y: (v.startLocation.y - fit.minY) / fit.height)
                let b = CGPoint(x: (v.location.x - fit.minX) / fit.width, y: (v.location.y - fit.minY) / fit.height)
                drawing = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            }
            .onEnded { _ in
                if let d = drawing, d.width > 0.03, d.height > 0.03 { boxes.append(PhotoToolsGeometry.clamp(d)) }
                drawing = nil
            }
    }

    // MARK: Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        Group {
            switch mode {
            case .menu: toolRow
            case .crop:
                Picker("Shape", selection: $cropShape) {
                    ForEach(CropShape.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: cropShape) { _, shape in
                    guard let first = boxes.first, let image else { return }
                    boxes = [PhotoToolsGeometry.resized(first, by: .zero, aspect: shape.aspect, imageSize: image.pixelSize)]
                }
            case .split:
                VStack(spacing: 10) {
                    Picker("Split", selection: $splitKind) {
                        ForEach(SplitKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: splitKind) { _, _ in layoutSplit() }
                    HStack {
                        switch splitKind {
                        case .boxes: Text("Drag to draw a box. Tap a box to remove it.")
                        case .grid:
                            Stepper("Rows \(gridRows)", value: $gridRows, in: 1...6).onChange(of: gridRows) { _, _ in layoutSplit() }
                            Stepper("Cols \(gridCols)", value: $gridCols, in: 1...6).onChange(of: gridCols) { _, _ in layoutSplit() }
                        case .rows:
                            Stepper("Pieces \(gridRows)", value: $gridRows, in: 2...8).onChange(of: gridRows) { _, _ in layoutSplit() }
                        }
                    }
                    .font(.footnote)
                    Text("Replaces this photo with \(boxes.count)").font(.footnote).foregroundStyle(.secondary)
                }
            case .identify:
                VStack(spacing: 6) {
                    Text(isWorking ? "Finding items…" : boxes.isEmpty ? "No items found." : "Found \(boxes.count). Drag to adjust, tap to remove.")
                    if !boxes.isEmpty { Text("Replaces this photo with \(boxes.count)").foregroundStyle(.secondary) }
                }
                .font(.footnote)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.07))
        .environment(\.colorScheme, .dark)
    }

    private var toolRow: some View {
        HStack {
            tool("Cover", "star", disabled: index == 0) { setCover() }
            tool("Crop", "crop") { enter(.crop) }
            tool("Split", "square.split.2x2") { enter(.split) }
            tool("Identify", "sparkles") { enter(.identify) }
            tool("Delete", "trash", role: .destructive) { deletePhoto() }
        }
    }

    private func tool(_ label: String, _ icon: String, role: ButtonRole? = nil, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(label).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(role == .destructive ? .red : .white)
            .opacity(disabled ? 0.35 : 1)
        }
        .disabled(disabled || image == nil)
        .accessibilityIdentifier("photoTool\(label)")
    }

    private func toastView(_ text: String) -> some View {
        HStack {
            Text(text)
            Spacer()
            if undo != nil { Button("Undo") { performUndo() }.fontWeight(.semibold) }
        }
        .font(.subheadline)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12).padding(.bottom, 90)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Actions

    private func enter(_ m: Mode) {
        mode = m
        labels = []
        switch m {
        case .crop: boxes = [CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)]; cropShape = .free
        case .split: splitKind = .grid; gridRows = 2; gridCols = 2; layoutSplit()
        case .identify: boxes = []; identify()
        case .menu: boxes = []
        }
    }

    private func leaveTool() { mode = .menu; boxes = []; labels = [] }

    private func layoutSplit() {
        switch splitKind {
        case .boxes: boxes = []
        case .grid: boxes = PhotoToolsGeometry.grid(rows: gridRows, cols: gridCols)
        case .rows: if gridRows < 2 { gridRows = 2 }; boxes = PhotoToolsGeometry.rows(gridRows)
        }
    }

    private func identify() {
        // A scaled copy is plenty for finding boxes (they're 0–1000 normalized) and keeps
        // the request well under the callable size limit.
        guard let data = image?.scaledToFit(maxSide: 1600).jpegData(compressionQuality: 0.85) else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let result = try await Functions.functions().httpsCallable("identifyProductsInImage")
                    .call(["imageBase64": data.base64EncodedString()])
                let objects = ((result.data as? [String: Any])?["objects"] as? [[String: Any]]) ?? []
                var found: [CGRect] = [], names: [String] = []
                for o in objects {
                    let raw = (o["box"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
                    if let r = PhotoToolsGeometry.rect(fromGeminiBox: raw) {
                        found.append(r)
                        names.append(o["label"] as? String ?? "")
                    }
                }
                guard mode == .identify else { return }
                boxes = found; labels = names
            } catch {
                errorText = "Identify failed: \(error.localizedDescription)"
                leaveTool()
            }
        }
    }

    private func save() {
        guard let image else { return }
        let pieces = boxes.compactMap { image.cropped(to: $0) }
        guard !pieces.isEmpty else { errorText = "Couldn't cut the photo."; return }
        replaceCurrent(with: pieces, message: mode == .crop ? "Cropped" : "Replaced with \(pieces.count) photos")
        leaveTool()
    }

    /// Replaces the shown photo with `pieces` in its place (crop = 1 piece).
    private func replaceCurrent(with pieces: [Data], message: String) {
        let before = item.sourceAssetIdentifiers
        let removed = item.removePhoto(assetId: assetId)
        let newIds = pieces.map { _ in UUID().uuidString }
        let at = before.firstIndex(of: assetId) ?? before.count
        for (k, data) in pieces.enumerated() { item.insertPhoto(assetId: newIds[k], data: data, at: at + k) }
        commit(UndoStep(order: before, removed: [(assetId, removed.data, removed.firebasePhotoPath)], added: newIds, focus: assetId), message: message)
        assetId = newIds[0]
    }

    private func setCover() {
        let before = item.sourceAssetIdentifiers
        guard let i = before.firstIndex(of: assetId), i > 0 else { return }
        item.movePhoto(from: i, to: 0)
        commit(UndoStep(order: before, removed: [], added: [], focus: assetId), message: "Set as cover")
    }

    private func deletePhoto() {
        let before = item.sourceAssetIdentifiers
        guard let i = before.firstIndex(of: assetId) else { return }
        let removed = item.removePhoto(assetId: assetId)
        commit(UndoStep(order: before, removed: [(assetId, removed.data, removed.firebasePhotoPath)], added: [], focus: assetId), message: "Photo deleted")
        let remaining = item.sourceAssetIdentifiers
        if remaining.isEmpty { close(); return }
        assetId = remaining[min(i, remaining.count - 1)]
    }

    private func commit(_ step: UndoStep, message: String) {
        // The previous step can no longer be undone: its replaced photos are gone for good.
        if let old = undo { pathsToDelete += old.removed.compactMap(\.path) }
        undo = step
        try? modelContext.save()
        uploadManager.startBackgroundUpload(draft: item, modelContext: modelContext)
        uploadManager.syncProductData(item)
        withAnimation { toast = message }
        let shown = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if toast == shown { withAnimation { toast = nil } }
        }
    }

    private func performUndo() {
        guard let step = undo else { return }
        for id in step.added { _ = item.removePhoto(assetId: id) }
        for r in step.removed { item.insertPhoto(assetId: r.assetId, data: r.data, at: item.sourceAssetIdentifiers.count, firebasePhotoPath: r.path) }
        item.reorderPhotos(to: step.order.filter { item.sourceAssetIdentifiers.contains($0) })
        undo = nil
        try? modelContext.save()
        uploadManager.syncProductData(item)
        assetId = step.focus
        withAnimation { toast = nil }
    }

    /// Deletes the uploaded copies of photos that were replaced or deleted (and not undone).
    private func close() {
        if let step = undo { pathsToDelete += step.removed.compactMap(\.path) }
        let paths = pathsToDelete
        dismiss()
        guard !paths.isEmpty, let uid = Auth.auth().currentUser?.uid else { return }
        Task {
            for path in paths { try? await StorageService.shared.deletePhoto(path: path, userId: uid) }
        }
    }
}

/// Darkens everything outside the crop box.
private struct CropDim: View {
    let box: CGRect
    let fit: CGRect

    var body: some View {
        Canvas { ctx, size in
            var p = Path(CGRect(origin: .zero, size: size))
            p.addRect(CGRect(x: fit.minX + box.minX * fit.width, y: fit.minY + box.minY * fit.height,
                             width: box.width * fit.width, height: box.height * fit.height))
            ctx.fill(p, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
        }
    }
}
