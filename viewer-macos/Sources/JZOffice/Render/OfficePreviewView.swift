import Foundation
import SwiftUI
import AppKit

/// 文档加载完成后的快照信息（对齐 Android `OfficePreviewView.Info` 与鸿蒙 `OfficePreviewInfo`）
public struct OfficePreviewInfo: Sendable, Equatable {
    public let format: OfficeKind
    public let pageCount: Int
    public let warnings: [String]
    public let sheetNames: [String]

    public init(format: OfficeKind, pageCount: Int, warnings: [String], sheetNames: [String]) {
        self.format = format
        self.pageCount = pageCount
        self.warnings = warnings
        self.sheetNames = sheetNames
    }
}

/// JZOffice macOS 端预览控制器（对齐 Android `OfficePreviewView` 与鸿蒙 `OfficePreviewController`）
@MainActor
public final class OfficePreviewController: ObservableObject {
    @Published public internal(set) var currentPage: Int = 0
    @Published public internal(set) var pageCount: Int = 0
    @Published public internal(set) var sheetNames: [String] = []
    @Published public internal(set) var zoom: CGFloat = 1.0
    @Published public internal(set) var metadata: OfficeMetadata?

    @Published internal var document: OfficeDocument? {
        didSet {
            if let doc = document, doc.kind == .docx {
                docxBlockYOffsets = CGElementDrawer.computeDocxBlockYOffsets(in: doc)
            } else {
                docxBlockYOffsets = nil
            }
        }
    }
    private var docxBlockYOffsets: [CGFloat]?
    @Published internal var imageCache: [String: CGImage] = [:]
    @Published internal var isLoading: Bool = true
    @Published internal var errorMessage: String?

    // MARK: - 全文检索状态与控制器 API

    @Published public internal(set) var isSearchPresented: Bool = false
    @Published public internal(set) var searchQuery: String = ""
    @Published public internal(set) var searchResults: [OfficeSearchMatch] = []
    @Published public internal(set) var currentMatchIndex: Int = -1
    @Published public internal(set) var isSearching: Bool = false

    @Published internal var targetHighlightRect: CGRect? = nil
    internal var currentFilePath: String? = nil
    private var activeSearchTask: Task<Void, Never>? = nil

    private var pageListeners: [UUID: (Int, Int) -> Void] = [:]

    nonisolated public init() {}

    @discardableResult
    public func addOnPageChangeListener(_ listener: @escaping (Int, Int) -> Void) -> UUID {
        let id = UUID()
        pageListeners[id] = listener
        listener(currentPage, pageCount)
        return id
    }

    public func removeOnPageChangeListener(_ id: UUID) {
        pageListeners.removeValue(forKey: id)
    }

    public func setZoom(_ value: CGFloat) {
        let clamped = min(4.0, max(0.5, value))
        zoom = clamped
    }

    public func resetZoom() {
        zoom = 1.0
    }

    public func jumpToPage(_ pageNumber: Int) {
        guard pageNumber >= 1 && pageNumber <= pageCount else { return }
        if currentPage != pageNumber {
            currentPage = pageNumber
            notifyPageListeners()
        }
    }

    public func selectSheet(_ sheetNumber: Int) {
        guard !sheetNames.isEmpty, sheetNumber >= 1 && sheetNumber <= sheetNames.count else { return }
        if currentPage != sheetNumber {
            currentPage = sheetNumber
            notifyPageListeners()
        }
    }

    public func presentSearch() {
        isSearchPresented = true
    }

    public func dismissSearch() {
        isSearchPresented = false
        clearSearch()
    }

    public func search(query: String) {
        searchQuery = query
        activeSearchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let path = currentFilePath else {
            searchResults = []
            currentMatchIndex = -1
            targetHighlightRect = nil
            isSearching = false
            return
        }

        isSearching = true
        activeSearchTask = Task { [weak self] in
            do {
                let matches = try await NativeCore.searchDocumentAsync(at: path, query: trimmed)
                guard !Task.isCancelled else { return }
                self?.searchResults = matches
                self?.currentMatchIndex = matches.isEmpty ? -1 : 0
                self?.isSearching = false
                self?.updateTargetForCurrentMatch()
            } catch {
                guard !Task.isCancelled else { return }
                self?.searchResults = []
                self?.currentMatchIndex = -1
                self?.isSearching = false
                self?.targetHighlightRect = nil
            }
        }
    }

    @discardableResult
    public func findNext() -> Bool {
        guard !searchResults.isEmpty else { return false }
        currentMatchIndex = (currentMatchIndex + 1) % searchResults.count
        updateTargetForCurrentMatch()
        return true
    }

    @discardableResult
    public func findPrevious() -> Bool {
        guard !searchResults.isEmpty else { return false }
        currentMatchIndex = (currentMatchIndex - 1 + searchResults.count) % searchResults.count
        updateTargetForCurrentMatch()
        return true
    }

    public func clearSearch() {
        activeSearchTask?.cancel()
        searchQuery = ""
        searchResults = []
        currentMatchIndex = -1
        targetHighlightRect = nil
        isSearching = false
    }

    private func updateTargetForCurrentMatch() {
        guard currentMatchIndex >= 0 && currentMatchIndex < searchResults.count,
              let doc = document else {
            targetHighlightRect = nil
            return
        }
        let match = searchResults[currentMatchIndex]
        if doc.kind == .pptx && match.pageIndex + 1 != currentPage {
            jumpToPage(match.pageIndex + 1)
        } else if doc.kind == .xlsx && match.pageIndex + 1 != currentPage {
            selectSheet(match.pageIndex + 1)
        }

        let rects = CGElementDrawer.computeHighlightRects(
            for: match,
            in: doc,
            docxBlockYOffsets: docxBlockYOffsets
        )
        if let first = rects.first {
            targetHighlightRect = rects.reduce(first) { $0.union($1) }
        } else {
            targetHighlightRect = nil
        }
    }

    internal func updateDocumentState(page: Int, count: Int, sheets: [String]) {
        self.sheetNames = sheets
        self.pageCount = count
        self.currentPage = page
        notifyPageListeners()
    }

    private func notifyPageListeners() {
        let snapshot = Array(pageListeners.values)
        for listener in snapshot {
            listener(currentPage, pageCount)
        }
    }
}

/// JZOffice macOS 核心统一预览组件（SwiftUI `View`）
public struct OfficePreviewView: View {
    private let fileURL: URL
    @ObservedObject private var controller: OfficePreviewController
    private let onLoaded: ((OfficePreviewInfo) -> Void)?
    private let onError: ((Error) -> Void)?
    private let onPageChange: ((Int, Int) -> Void)?

    public init(
        fileURL: URL,
        controller: OfficePreviewController = OfficePreviewController(),
        onLoaded: ((OfficePreviewInfo) -> Void)? = nil,
        onError: ((Error) -> Void)? = nil,
        onPageChange: ((Int, Int) -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.controller = controller
        self.onLoaded = onLoaded
        self.onError = onError
        self.onPageChange = onPageChange
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(nsColor: NSColor(srgbRed: 0.97, green: 0.975, blue: 0.98, alpha: 1.0))
            if controller.isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在解析文档...")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = controller.errorMessage {
                VStack(spacing: 10) {
                    Text("⚠️")
                        .font(.system(size: 32))
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let doc = controller.document {
                ScrollViewReader { scrollProxy in
                    ScrollView([.horizontal, .vertical], showsIndicators: true) {
                        ZStack(alignment: .topLeading) {
                            OfficeCanvasRepresentable(
                                document: doc,
                                images: controller.imageCache,
                                currentPage: controller.currentPage,
                                zoom: controller.zoom,
                                searchResults: controller.searchResults,
                                currentMatchIndex: controller.currentMatchIndex,
                                targetHighlightRect: controller.targetHighlightRect,
                                onPresentSearch: { controller.presentSearch() },
                                onDismissSearch: { controller.dismissSearch() },
                                onFindNext: { _ = controller.findNext() },
                                onFindPrevious: { _ = controller.findPrevious() }
                            )
                            .frame(
                                width: canvasContentSize(for: doc).width * controller.zoom,
                                height: canvasContentSize(for: doc).height * controller.zoom
                            )

                            if doc.kind == .pptx {
                                VStack(spacing: 16 * controller.zoom) {
                                    ForEach(Array(doc.pages.enumerated()), id: \.offset) { index, page in
                                        let pH = page.height > 0 ? page.height : 405
                                        Color.clear
                                            .frame(width: 1, height: pH * controller.zoom)
                                            .id("slide-\(index + 1)")
                                    }
                                }
                                .allowsHitTesting(false)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: controller.currentPage) { _, newPage in
                        if doc.kind == .pptx, newPage >= 1 {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                scrollProxy.scrollTo("slide-\(newPage)", anchor: .top)
                            }
                        }
                    }
                }
            }

            if controller.isSearchPresented {
                OfficeSearchBarView(controller: controller)
                    .padding(.top, 14)
                    .padding(.trailing, 18)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
                    .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: controller.isSearchPresented)
        .task(id: fileURL) {
            await loadDocument(from: fileURL)
        }
        .onChange(of: controller.currentPage) { _, newPage in
            onPageChange?(newPage, controller.pageCount)
        }
    }

    private func canvasContentSize(for doc: OfficeDocument) -> CGSize {
        switch doc.kind {
        case .pptx:
            let maxW = doc.pages.map { $0.width > 0 ? $0.width : 720 }.max() ?? 720
            let totalH = doc.pages.reduce(CGFloat(0)) { $0 + ($1.height > 0 ? $1.height : 405) + 16 }
            return CGSize(width: maxW, height: max(405, totalH))
        case .docx:
            let docW = doc.width > 0 ? doc.width : 595
            let marginX: CGFloat = doc.marginLeft > 0 ? doc.marginLeft : 24
            let marginR: CGFloat = doc.marginRight > 0 ? doc.marginRight : 24
            let marginTop: CGFloat = doc.marginTop > 0 ? doc.marginTop : 24
            let marginBottom: CGFloat = doc.marginBottom > 0 ? doc.marginBottom : 24
            let availW = max(100, docW - marginX - marginR)
            var curY = marginTop
            for block in (doc.headerBlocks + doc.blocks + doc.footerBlocks) {
                let elW = block.width > 0 ? min(availW, block.width) : availW
                var elH = block.height
                if elH <= 0 {
                    if block.type == .table && !block.rows.isEmpty {
                        var tbl = block
                        tbl.width = elW
                        elH = CGElementDrawer.measureTableHeight(element: tbl)
                    } else if !block.paragraphs.isEmpty {
                        elH = CGElementDrawer.measureParagraphsHeight(block.paragraphs, availableWidth: elW, wrap: true) + 8
                    } else {
                        elH = 80
                    }
                }
                curY += elH + 8
            }
            curY += marginBottom
            return CGSize(width: docW, height: max(docW * 1.414, curY))
        case .xlsx:
            let idx = max(0, min(doc.sheets.count - 1, controller.currentPage - 1))
            guard idx < doc.sheets.count else { return CGSize(width: 800, height: 600) }
            let (_, _, totalW, totalH) = CGElementDrawer.computeSheetExtents(doc.sheets[idx])
            return CGSize(width: max(600, totalW + 24), height: max(400, totalH + 24))
        }
    }

    @MainActor
    private func loadDocument(from url: URL) async {
        controller.isLoading = true
        controller.errorMessage = nil
        controller.document = nil
        controller.metadata = nil
        controller.imageCache = [:]
        controller.currentFilePath = url.path
        controller.clearSearch()
        controller.updateDocumentState(page: 0, count: 0, sheets: [])

        let path = url.path
        do {
            let (parsed, loadedImages) = try await Task.detached(priority: .userInitiated) {
                let doc = try NativeCore.parseDocument(at: path)
                let store = ImageStore(filePath: path)
                defer { store.release() }
                // 整篇文档一次性渲染，工作集必须整体驻留，交由 preload 按预算等比降采样
                var parts: [String] = []
                for page in doc.pages {
                    for el in page.elements where el.type == .image {
                        if let part = el.image { parts.append(part) }
                    }
                }
                for block in (doc.headerBlocks + doc.blocks + doc.footerBlocks) {
                    if block.type == .image, let part = block.image { parts.append(part) }
                    if block.type == .table {
                        for row in block.rows {
                            for cell in row {
                                for p in cell {
                                    if let part = p.image { parts.append(part) }
                                }
                            }
                        }
                    }
                }
                store.preload(parts: parts)
                return (doc, store.snapshot)
            }.value

            controller.document = parsed
            controller.imageCache = loadedImages
            controller.isLoading = false

            let meta = OfficeMetadata.fromDocument(parsed)
            controller.metadata = meta
            let initialPage = meta.pageCount > 0 ? 1 : 0
            controller.updateDocumentState(page: initialPage, count: meta.pageCount, sheets: meta.sheetNames)
            let info = OfficePreviewInfo(
                format: meta.format,
                pageCount: meta.pageCount,
                warnings: meta.warnings,
                sheetNames: meta.sheetNames
            )
            onLoaded?(info)
            onPageChange?(initialPage, meta.pageCount)
        } catch {
            controller.isLoading = false
            controller.errorMessage = error.localizedDescription
            onError?(error)
        }
    }
}

private struct OfficeCanvasRepresentable: NSViewRepresentable {
    let document: OfficeDocument
    let images: [String: CGImage]
    let currentPage: Int
    let zoom: CGFloat
    let searchResults: [OfficeSearchMatch]
    let currentMatchIndex: Int
    let targetHighlightRect: CGRect?
    let onPresentSearch: () -> Void
    let onDismissSearch: () -> Void
    let onFindNext: () -> Void
    let onFindPrevious: () -> Void

    func makeNSView(context: Context) -> OfficeDocumentNSView {
        let view = OfficeDocumentNSView()
        view.setDocument(document)
        view.images = images
        view.currentPage = currentPage
        view.zoom = zoom
        view.onPresentSearch = onPresentSearch
        view.onDismissSearch = onDismissSearch
        view.onFindNext = onFindNext
        view.onFindPrevious = onFindPrevious
        view.updateSearchResults(searchResults, currentIndex: currentMatchIndex, targetRect: targetHighlightRect)
        return view
    }

    func updateNSView(_ nsView: OfficeDocumentNSView, context: Context) {
        nsView.setDocument(document)
        nsView.images = images
        nsView.currentPage = currentPage
        nsView.zoom = zoom
        nsView.onPresentSearch = onPresentSearch
        nsView.onDismissSearch = onDismissSearch
        nsView.onFindNext = onFindNext
        nsView.onFindPrevious = onFindPrevious
        nsView.updateSearchResults(searchResults, currentIndex: currentMatchIndex, targetRect: targetHighlightRect)
        nsView.needsDisplay = true
    }
}

private final class OfficeDocumentNSView: NSView, NSMenuItemValidation {
    private(set) var document: OfficeDocument?
    var images: [String: CGImage] = [:]
    var currentPage: Int = 1
    var zoom: CGFloat = 1.0 {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }

    var searchResults: [OfficeSearchMatch] = []
    var currentMatchIndex: Int = -1
    var onPresentSearch: (() -> Void)?
    var onDismissSearch: (() -> Void)?
    var onFindNext: (() -> Void)?
    var onFindPrevious: (() -> Void)?

    private var docxBlockYOffsets: [CGFloat]?
    private var lastScrolledMatchIndex: Int = -1
    private var textLayout: DocumentTextLayout?
    private var selection: TextSelection?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func setDocument(_ newDoc: OfficeDocument) {
        let isDocChanged = (document?.kind != newDoc.kind ||
            document?.width != newDoc.width ||
            document?.pages.count != newDoc.pages.count ||
            document?.sheets.count != newDoc.sheets.count ||
            document?.blocks.count != newDoc.blocks.count)
        document = newDoc
        if isDocChanged || docxBlockYOffsets == nil {
            docxBlockYOffsets = newDoc.kind == .docx ? CGElementDrawer.computeDocxBlockYOffsets(in: newDoc) : nil
            textLayout = nil
            selection = nil
            window?.invalidateCursorRects(for: self)
        }
    }

    func updateSearchResults(_ results: [OfficeSearchMatch], currentIndex: Int, targetRect: CGRect?) {
        let resultsChanged = (self.searchResults != results)
        let indexChanged = (self.currentMatchIndex != currentIndex)
        self.searchResults = results
        self.currentMatchIndex = currentIndex

        if results.isEmpty {
            lastScrolledMatchIndex = -1
            return
        }

        if (indexChanged || resultsChanged) && currentIndex >= 0 && currentIndex < results.count {
            if let targetRect = targetRect {
                scrollToHighlight(targetRect)
                lastScrolledMatchIndex = currentIndex
            } else if let doc = document {
                let rects = CGElementDrawer.computeHighlightRects(
                    for: results[currentIndex],
                    in: doc,
                    docxBlockYOffsets: docxBlockYOffsets
                )
                if let first = rects.first {
                    let union = rects.reduce(first) { $0.union($1) }
                    scrollToHighlight(union)
                    lastScrolledMatchIndex = currentIndex
                }
            }
        }
    }

    func scrollToHighlight(_ docRect: CGRect) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let clipView = self.enclosingScrollView?.contentView else { return }
            let viewRect = CGRect(
                x: docRect.origin.x * self.zoom,
                y: docRect.origin.y * self.zoom,
                width: docRect.width * self.zoom,
                height: docRect.height * self.zoom
            )
            let clipBounds = clipView.bounds
            let maxX = max(0, self.bounds.width - clipBounds.width)
            let maxY = max(0, self.bounds.height - clipBounds.height)
            let targetX = min(max(0, viewRect.midX - clipBounds.width / 2), maxX)
            let targetY = min(max(0, viewRect.midY - clipBounds.height / 2), maxY)
            clipView.animator().scroll(to: NSPoint(x: targetX, y: targetY))
            self.enclosingScrollView?.reflectScrolledClipView(clipView)
        }
    }

    private func ensureTextLayout() -> DocumentTextLayout? {
        guard let doc = document else { return nil }
        if let existing = textLayout {
            return existing
        }
        let layout = DocumentTextLayout.build(from: doc)
        textLayout = layout
        window?.invalidateCursorRects(for: self)
        return layout
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let layout = ensureTextLayout() else { return }
        for block in layout.blocks {
            let viewRect = CGRect(
                x: block.bounds.minX * zoom,
                y: block.bounds.minY * zoom,
                width: block.bounds.width * zoom,
                height: block.bounds.height * zoom
            )
            addCursorRect(viewRect, cursor: .iBeam)
        }
    }

    // MARK: - 绘制管线

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let doc = document else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.scaleBy(x: zoom, y: zoom)

        switch doc.kind {
        case .pptx:
            var curY: CGFloat = 0
            for page in doc.pages {
                let pW = page.width > 0 ? page.width : 720
                let pH = page.height > 0 ? page.height : 405
                ctx.saveGState()
                ctx.translateBy(x: 0, y: curY)
                let slideRect = CGRect(x: 0, y: 0, width: pW, height: pH)
                let bg = CGElementDrawer.argbToCGColor(page.background) ?? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
                ctx.setFillColor(bg)
                ctx.fill(slideRect)
                ctx.clip(to: slideRect)
                for el in page.elements {
                    CGElementDrawer.drawElement(in: ctx, element: el, images: images)
                }
                ctx.restoreGState()
                curY += pH + 16
            }
        case .docx:
            let docW = doc.width > 0 ? doc.width : 595
            let docH = bounds.height / max(0.1, zoom)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: docW, height: docH))
            let marginX: CGFloat = doc.marginLeft > 0 ? doc.marginLeft : 24
            let marginR: CGFloat = doc.marginRight > 0 ? doc.marginRight : 24
            let availW = max(100, docW - marginX - marginR)
            var curY: CGFloat = doc.marginTop > 0 ? doc.marginTop : 24
            for block in (doc.headerBlocks + doc.blocks + doc.footerBlocks) {
                let elW = block.width > 0 ? min(availW, block.width) : availW
                var elH = block.height
                if elH <= 0 {
                    if block.type == .table && !block.rows.isEmpty {
                        var tbl = block
                        tbl.width = elW
                        elH = CGElementDrawer.measureTableHeight(element: tbl)
                    } else if !block.paragraphs.isEmpty {
                        elH = CGElementDrawer.measureParagraphsHeight(block.paragraphs, availableWidth: elW, wrap: true) + 8
                    } else {
                        elH = 80
                    }
                }
                var positioned = block
                positioned.x = marginX
                positioned.y = curY
                positioned.width = elW
                positioned.height = elH
                positioned.transform = [1, 0, 0, 1, marginX, curY]
                positioned.textWrap = true
                CGElementDrawer.drawElement(in: ctx, element: positioned, images: images)
                curY += elH + 8
            }
        case .xlsx:
            let idx = max(0, min(doc.sheets.count - 1, currentPage - 1))
            guard idx < doc.sheets.count else { return }
            let viewport = CGRect(
                x: 0,
                y: 0,
                width: bounds.width / max(0.1, zoom),
                height: bounds.height / max(0.1, zoom)
            )
            CGElementDrawer.drawSpreadsheet(
                in: ctx,
                sheet: doc.sheets[idx],
                styles: doc.cellStyles,
                viewport: viewport
            )
        }

        // 绘制全文检索高亮（在文档未缩放坐标系下，由 ctx.scaleBy 统一放大）
        if !searchResults.isEmpty {
            let docVisibleRect = CGRect(
                x: visibleRect.minX / zoom,
                y: visibleRect.minY / zoom,
                width: visibleRect.width / zoom,
                height: visibleRect.height / zoom
            )
            ctx.saveGState()
            for (index, match) in searchResults.enumerated() {
                if doc.kind == .xlsx && match.pageIndex != (currentPage - 1) {
                    continue
                }
                let isCurrent = (index == currentMatchIndex)
                if !isCurrent {
                    if doc.kind == .docx, let offsets = docxBlockYOffsets, match.elementIndex < offsets.count {
                        let blockY = offsets[match.elementIndex]
                        if blockY > docVisibleRect.maxY + 50 || blockY + 1200 < docVisibleRect.minY {
                            continue
                        }
                    }
                }
                let rects = CGElementDrawer.computeHighlightRects(
                    for: match,
                    in: doc,
                    docxBlockYOffsets: docxBlockYOffsets
                )
                for r in rects {
                    if !isCurrent && !r.intersects(docVisibleRect) {
                        continue
                    }
                    let path = CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil)
                    if isCurrent {
                        ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.60, blue: 0.0, alpha: 0.75))
                        ctx.addPath(path)
                        ctx.fillPath()
                        ctx.setStrokeColor(CGColor(srgbRed: 0.90, green: 0.40, blue: 0.0, alpha: 1.0))
                        ctx.setLineWidth(1.5)
                        ctx.addPath(path)
                        ctx.strokePath()
                    } else {
                        ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.92, blue: 0.23, alpha: 0.45))
                        ctx.addPath(path)
                        ctx.fillPath()
                    }
                }
            }
            ctx.restoreGState()
        }

        // 绘制选区高亮（在文档未缩放坐标系下，由 ctx.scaleBy 统一放大）
        if let sel = selection, !sel.isEmpty, let layout = ensureTextLayout() {
            let rects = layout.selectionRects(for: sel)
            if !rects.isEmpty {
                ctx.saveGState()
                let highlightColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35).cgColor
                ctx.setFillColor(highlightColor)
                for r in rects {
                    let path = CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil)
                    ctx.addPath(path)
                    ctx.fillPath()
                }
                ctx.restoreGState()
            }
        }
    }

    // MARK: - 鼠标手势与文本框选

    private func documentPoint(for event: NSEvent) -> CGPoint {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let z = max(0.01, zoom)
        return CGPoint(x: viewPoint.x / z, y: viewPoint.y / z)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let docPoint = documentPoint(for: event)
        guard let layout = ensureTextLayout() else {
            super.mouseDown(with: event)
            return
        }

        if event.clickCount == 2 {
            // 双击：选词
            if let pos = layout.hitTest(docPoint: docPoint),
               let word = layout.wordRange(at: pos) {
                selection = word
                needsDisplay = true
                return
            }
        } else if event.clickCount >= 3 {
            // 三击：选整行/段落
            if let pos = layout.hitTest(docPoint: docPoint),
               let line = layout.lineRange(at: pos) {
                selection = line
                needsDisplay = true
                return
            }
        }

        // 单击：设置选区起点
        if let pos = layout.hitTest(docPoint: docPoint) {
            selection = TextSelection(position: pos)
            needsDisplay = true
        } else {
            if selection != nil {
                selection = nil
                needsDisplay = true
            }
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        _ = autoscroll(with: event)
        let docPoint = documentPoint(for: event)
        guard let layout = ensureTextLayout() else {
            super.mouseDragged(with: event)
            return
        }

        if let pos = layout.hitTest(docPoint: docPoint) {
            if let current = selection {
                selection = TextSelection(anchor: current.anchor, focus: pos)
            } else {
                selection = TextSelection(position: pos)
            }
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let sel = selection, sel.isEmpty {
            selection = nil
            needsDisplay = true
        }
        super.mouseUp(with: event)
    }

    // MARK: - 快捷键与剪贴板

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            if event.charactersIgnoringModifiers == "c" {
                copy(nil)
                return true
            } else if event.charactersIgnoringModifiers == "a" {
                selectAll(nil)
                return true
            } else if event.charactersIgnoringModifiers == "f" {
                onPresentSearch?()
                return true
            } else if event.charactersIgnoringModifiers == "g" {
                onFindNext?()
                return true
            }
        } else if flags == [.command, .shift] {
            if event.charactersIgnoringModifiers?.lowercased() == "g" {
                onFindPrevious?()
                return true
            }
        } else if flags.isEmpty {
            if event.keyCode == 53 { // Escape
                onDismissSearch?()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func copy(_ sender: Any?) {
        guard let sel = selection, !sel.isEmpty, let layout = ensureTextLayout() else { return }
        let text = layout.selectedText(for: sel)
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc override func selectAll(_ sender: Any?) {
        if let all = ensureTextLayout()?.allTextRange() {
            selection = all
            needsDisplay = true
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) {
            return selection != nil && !selection!.isEmpty
        }
        if menuItem.action == #selector(selectAll(_:)) {
            return !(ensureTextLayout()?.blocks.isEmpty ?? true)
        }
        return true
    }

    // MARK: - 右键上下文菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Context Menu")

        // 若右键时未选中文本，尝试智能选词
        if selection == nil || selection!.isEmpty {
            let docPoint = documentPoint(for: event)
            if let layout = ensureTextLayout(),
               let pos = layout.hitTest(docPoint: docPoint),
               let word = layout.wordRange(at: pos) {
                selection = word
                needsDisplay = true
            }
        }

        let hasSel = selection != nil && !selection!.isEmpty
        let copyItem = NSMenuItem(title: "拷贝", action: #selector(copy(_:)), keyEquivalent: "c")
        copyItem.target = self
        copyItem.isEnabled = hasSel
        menu.addItem(copyItem)

        menu.addItem(NSMenuItem.separator())

        let selectAllItem = NSMenuItem(title: "全选", action: #selector(selectAll(_:)), keyEquivalent: "a")
        selectAllItem.target = self
        selectAllItem.isEnabled = !(ensureTextLayout()?.blocks.isEmpty ?? true)
        menu.addItem(selectAllItem)

        return menu
    }
}

// MARK: - 全文检索工具栏

/// JZOffice 全文检索交互悬浮工具栏（SwiftUI）
public struct OfficeSearchBarView: View {
    @ObservedObject public var controller: OfficePreviewController
    @FocusState private var isFieldFocused: Bool

    public init(controller: OfficePreviewController) {
        self.controller = controller
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 12))

            TextField("搜索文档...", text: Binding(
                get: { controller.searchQuery },
                set: { controller.search(query: $0) }
            ))
            .textFieldStyle(.plain)
            .focused($isFieldFocused)
            .font(.system(size: 13))
            .frame(width: 140)
            .onSubmit {
                if NSEvent.modifierFlags.contains(.shift) {
                    controller.findPrevious()
                } else {
                    controller.findNext()
                }
            }

            if controller.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
            } else if !controller.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if controller.searchResults.isEmpty {
                    Text("无结果")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    Text("\(controller.currentMatchIndex + 1)/\(controller.searchResults.count)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Divider()
                .frame(height: 14)

            Button(action: { controller.findPrevious() }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(controller.searchResults.isEmpty)
            .help("上一个匹配项 (⇧↩ 或 ⌘⇧G)")

            Button(action: { controller.findNext() }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(controller.searchResults.isEmpty)
            .help("下一个匹配项 (↩ 或 ⌘G)")

            Button(action: { controller.dismissSearch() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("关闭 (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        .onAppear {
            isFieldFocused = true
        }
        .onExitCommand {
            controller.dismissSearch()
        }
    }
}
