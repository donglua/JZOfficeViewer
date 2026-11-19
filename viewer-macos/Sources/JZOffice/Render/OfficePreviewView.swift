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
    @Published public internal(set) var imageLoader: OfficeImageLoader?
    @Published internal var imageVersion: UInt = 0

    @Published internal var document: OfficeDocument? {
        didSet {
            if let doc = document, doc.kind == .docx {
                docxLayoutPlan = CGElementDrawer.layoutDocxBlocks(in: doc)
            } else {
                docxLayoutPlan = nil
            }
        }
    }
    internal var docxLayoutPlan: CGElementDrawer.DocxLayoutPlan?
    @Published internal var imageCache: [String: CGImage] = [:]
    @Published internal var isLoading: Bool = true
    @Published internal var errorMessage: String?

    @MainActor
    internal func notifyImageDecoded() {
        self.imageVersion &+= 1
        self.imageCache = self.imageLoader?.snapshot ?? [:]
    }

    @MainActor
    internal func onImageDecoded() {
        notifyImageDecoded()
    }

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

    internal struct ScrollRequest: Equatable {
        let id = UUID()
        let page: Int
        init(page: Int) {
            self.page = page
        }
    }
    @Published internal var scrollRequest: ScrollRequest? = nil
    private var programmaticScrollTarget: Int? = nil
    private var clearScrollTargetTask: Task<Void, Never>? = nil

    nonisolated public init() {}

    deinit {
        clearScrollTargetTask?.cancel()
        activeSearchTask?.cancel()
    }

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
        clearScrollTargetTask?.cancel()
        programmaticScrollTarget = pageNumber
        if currentPage != pageNumber {
            currentPage = pageNumber
            notifyPageListeners()
        }
        scrollRequest = ScrollRequest(page: pageNumber)
        clearScrollTargetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.programmaticScrollTarget = nil
        }
    }

    public func onPageScrollDetected(page: Int) {
        guard page >= 1 && page <= pageCount else { return }
        if let target = programmaticScrollTarget {
            if page == target {
                programmaticScrollTarget = nil
                clearScrollTargetTask?.cancel()
            } else {
                return
            }
        }
        guard page != currentPage else { return }
        currentPage = page
        notifyPageListeners()
    }

    public func onPageScrollDetected(_ page: Int) {
        onPageScrollDetected(page: page)
    }

    public func selectSheet(_ sheetNumber: Int) {
        guard !sheetNames.isEmpty, sheetNumber >= 1 && sheetNumber <= sheetNames.count else { return }
        // 切表必须立刻丢弃 XLSX 选区：单元格坐标只对原工作表有意义，跨表保留会指到不存在的位置
        clearSelection()
        if currentPage != sheetNumber {
            currentPage = sheetNumber
            notifyPageListeners()
        }
    }

    // MARK: - 选区公开 API（与 Android `OfficePreviewView` / 鸿蒙 `OfficePreviewController` 对齐）

    /// 承载画布的 NSView 弱引用：选区 API 统一转发到真正的视图，避免控制器与视图各存一份状态
    private weak var canvasView: OfficeDocumentNSView?

    @MainActor
    internal func attachCanvas(_ view: OfficeDocumentNSView) {
        canvasView = view
    }

    @MainActor
    internal func detachCanvas(_ view: OfficeDocumentNSView) {
        if canvasView === view {
            canvasView = nil
        }
    }

    /// 选中文档全部可选正文；XLSX 下选中整表可见数据区。
    ///
    /// - Returns: 选中成功返回 `true`；未加载文档、表格全空或无可见行列时返回 `false`
    @MainActor
    @discardableResult
    public func selectAll() -> Bool {
        canvasView?.performSelectAll() ?? false
    }

    /// 清除当前选区；无选区时为空操作
    @MainActor
    public func clearSelection() {
        canvasView?.performClearSelection()
    }

    /// 当前是否存在非空选区（仅反映状态，不触发任何重绘）
    @MainActor
    public func hasSelection() -> Bool {
        canvasView?.hasAnySelection ?? false
    }

    /// 返回当前选中的纯文本。
    ///
    /// DOCX / PPTX 跨段落与跨块以 `"\n"` 连接；XLSX 返回 TSV：同行以 `"\t"`、
    /// 跨行以 `"\n"` 分隔，隐藏行列跳过、合并单元格从属位置留空。
    ///
    /// - Returns: 无选区时返回空串
    @MainActor
    public func getSelectedText() -> String {
        canvasView?.currentSelectedText() ?? ""
    }

    /// 把当前选中文本写入系统剪贴板，选区保持不变。
    ///
    /// - Returns: 写入成功返回 `true`；无选区或文本为空时返回 `false`
    @MainActor
    @discardableResult
    public func copySelection() -> Bool {
        canvasView?.writeSelectionToPasteboard() ?? false
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
            docxPlan: docxLayoutPlan
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
                GeometryReader { viewportGeo in
                    let contentSize = canvasContentSize(for: doc)
                    let scaledW = contentSize.width * controller.zoom
                    let scaledH = contentSize.height * controller.zoom
                    let minContainerW = Self.minContainerWidth(for: viewportGeo.size.width, kind: doc.kind)

                    ScrollViewReader { scrollProxy in
                        ScrollView([.horizontal, .vertical], showsIndicators: true) {
                            ZStack(alignment: .topLeading) {
                                OfficeCanvasRepresentable(
                                    document: doc,
                                    images: controller.imageCache,
                                    imageLoader: controller.imageLoader,
                                    currentPage: controller.currentPage,
                                    zoom: controller.zoom,
                                    searchResults: controller.searchResults,
                                    currentMatchIndex: controller.currentMatchIndex,
                                    targetHighlightRect: controller.targetHighlightRect,
                                    controller: controller,
                                    onPresentSearch: { controller.presentSearch() },
                                    onDismissSearch: { controller.dismissSearch() },
                                    onFindNext: { _ = controller.findNext() },
                                    onFindPrevious: { _ = controller.findPrevious() },
                                    onPageDetected: { detectedPage in
                                        controller.onPageScrollDetected(page: detectedPage)
                                    }
                                )
                                .frame(width: scaledW, height: scaledH)

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
                            .frame(minWidth: minContainerW, alignment: .top)
                            .padding(16)
                        }
                        .onChange(of: controller.scrollRequest) { _, req in
                            if let req = req, doc.kind == .pptx, req.page >= 1 {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    scrollProxy.scrollTo("slide-\(req.page)", anchor: .top)
                                }
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
        .onDisappear {
            controller.imageLoader?.close()
            controller.imageLoader = nil
        }
    }

    /// 计算文档画布在滚动视口中的最小容器宽度：DOCX/PPTX 在窄于视口时水平居中，XLSX 保持左上对齐
    internal static func minContainerWidth(for viewportWidth: CGFloat, kind: OfficeKind) -> CGFloat {
        guard kind != .xlsx else { return 0 }
        return floor(max(0, viewportWidth - 32))
    }

    private func canvasContentSize(for doc: OfficeDocument) -> CGSize {
        switch doc.kind {
        case .pptx:
            let maxW = doc.pages.map { $0.width > 0 ? $0.width : 720 }.max() ?? 720
            let totalH = doc.pages.reduce(CGFloat(0)) { $0 + ($1.height > 0 ? $1.height : 405) + 16 }
            return CGSize(width: maxW, height: max(405, totalH))
        case .docx:
            let docW = doc.width > 0 ? doc.width : 595
            let plan = controller.docxLayoutPlan ?? CGElementDrawer.layoutDocxBlocks(in: doc)
            return CGSize(width: docW, height: max(docW * 1.414, plan.contentHeight))
        case .xlsx:
            let idx = max(0, min(doc.sheets.count - 1, controller.currentPage - 1))
            guard idx < doc.sheets.count else { return CGSize(width: 800, height: 600) }
            let (_, _, totalW, totalH) = CGElementDrawer.computeSheetExtents(doc.sheets[idx])
            return CGSize(width: max(600, totalW + 24), height: max(400, totalH + 24))
        }
    }

    @MainActor
    private func loadDocument(from url: URL) async {
        controller.imageLoader?.close()
        controller.imageLoader = nil
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
            let parsed = try await Task.detached(priority: .userInitiated) {
                return try NativeCore.parseDocument(at: path)
            }.value

            let loader = OfficeImageLoader(filePath: path) { [weak controller] in
                controller?.notifyImageDecoded()
            }
            controller.imageLoader = loader
            controller.document = parsed
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

struct OfficeCanvasRepresentable: NSViewRepresentable {
    let document: OfficeDocument
    let images: [String: CGImage]
    let imageLoader: OfficeImageLoader?
    let currentPage: Int
    let zoom: CGFloat
    let searchResults: [OfficeSearchMatch]
    let currentMatchIndex: Int
    let targetHighlightRect: CGRect?
    let controller: OfficePreviewController
    let onPresentSearch: () -> Void
    let onDismissSearch: () -> Void
    let onFindNext: () -> Void
    let onFindPrevious: () -> Void
    var onPageDetected: ((Int) -> Void)? = nil

    func makeNSView(context: Context) -> OfficeDocumentNSView {
        let view = OfficeDocumentNSView()
        view.imageLoader = imageLoader
        view.setDocument(document)
        view.images = images
        view.currentPage = currentPage
        view.zoom = zoom
        view.onPageDetected = onPageDetected
        view.onPresentSearch = onPresentSearch
        view.onDismissSearch = onDismissSearch
        view.onFindNext = onFindNext
        view.onFindPrevious = onFindPrevious
        view.updateSearchResults(searchResults, currentIndex: currentMatchIndex, targetRect: targetHighlightRect)
        // 控制器把选区 API 转发到真正的视图，避免两侧各存一份状态
        view.controllerRef = controller
        controller.attachCanvas(view)
        return view
    }

    func updateNSView(_ nsView: OfficeDocumentNSView, context: Context) {
        nsView.imageLoader = imageLoader
        nsView.setDocument(document)
        nsView.images = images
        nsView.currentPage = currentPage
        nsView.zoom = zoom
        nsView.onPageDetected = onPageDetected
        nsView.onPresentSearch = onPresentSearch
        nsView.onDismissSearch = onDismissSearch
        nsView.onFindNext = onFindNext
        nsView.onFindPrevious = onFindPrevious
        nsView.updateSearchResults(searchResults, currentIndex: currentMatchIndex, targetRect: targetHighlightRect)
        nsView.controllerRef = controller
        controller.attachCanvas(nsView)
        nsView.needsDisplay = true
        nsView.evaluateViewport()
    }

    static func dismantleNSView(_ nsView: OfficeDocumentNSView, coordinator: ()) {
        // 先摘掉控制器的画布回指，再释放视图状态，避免选区 API 命中已销毁的视图
        nsView.controllerRef?.detachCanvas(nsView)
        nsView.teardown()
    }
}

final class OfficeDocumentNSView: NSView, NSMenuItemValidation {
    private(set) var document: OfficeDocument?
    weak var imageLoader: OfficeImageLoader? {
        didSet {
            if imageLoader !== oldValue {
                evaluateViewport()
            }
        }
    }
    var images: [String: CGImage] = [:]
    private var isEvaluatingViewport = false
    var currentPage: Int = 1 {
        didSet {
            if currentPage != oldValue && !isEvaluatingViewport {
                // 切表即丢弃选区：单元格坐标只对原工作表有意义
                if document?.kind == .xlsx {
                    releaseSheetSelectionState()
                    needsDisplay = true
                }
                evaluateViewport()
            }
        }
    }
    var zoom: CGFloat = 1.0 {
        didSet {
            window?.invalidateCursorRects(for: self)
            evaluateViewport()
        }
    }

    var searchResults: [OfficeSearchMatch] = []
    var currentMatchIndex: Int = -1
    var onPageDetected: ((Int) -> Void)?
    var onPresentSearch: (() -> Void)?
    var onDismissSearch: (() -> Void)?
    var onFindNext: (() -> Void)?
    var onFindPrevious: (() -> Void)?
    /// 控制器的弱引用：拆卸时用它摘掉控制器的画布回指
    weak var controllerRef: OfficePreviewController?

    internal var docxLayoutPlan: CGElementDrawer.DocxLayoutPlan?
    private var lastScrolledMatchIndex: Int = -1
    private var textLayout: DocumentTextLayout?
    private var selection: TextSelection?
    /// XLSX 二维网格选区（与 DOCX/PPTX 的 `selection` 互斥：同一时刻只有一种文档类型生效）
    internal var sheetSelection: SheetSelectionModel.SheetSelection?
    /// XLSX 拖拽锚点：按下时固定，拖拽期间焦点跟随鼠标，松手后清空
    private var sheetDragAnchor: SheetSelectionModel.CellCoord?
    /// XLSX 模型布局缓存：以「工作表指纹 + 页码」为键，同一份表在滚动/缩放期间不重复构造前缀和
    private var sheetLayoutCache: (fingerprint: SheetLayoutFingerprint, layout: SheetSelectionModel.SheetSelectionLayout)?

    /// 工作表指纹：工作表是值类型无法用引用比较，这里用廉价字段组合判定"是不是同一份表"。
    /// 任何会改变前缀和或单元格定位的输入（行列数、单元格数、合并数、表名、页码）都参与，
    /// 因此真实文档切换一定失效，而同一文档的重绘、滚动与缩放一定命中。
    private struct SheetLayoutFingerprint: Equatable {
        let page: Int
        let name: String
        let rowCount: Int
        let columnCount: Int
        let cellCount: Int
        let mergeCount: Int

        init(page: Int, sheet: OfficeSheet) {
            self.page = page
            self.name = sheet.name
            self.rowCount = sheet.rowHeights.count
            self.columnCount = sheet.columnWidths.count
            self.cellCount = sheet.cells.count
            self.mergeCount = sheet.merges.count
        }
    }
    private weak var observedClipView: NSClipView?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    deinit {
        teardown()
    }

    func teardown() {
        if let clip = observedClipView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: clip
            )
            observedClipView = nil
        }
        NotificationCenter.default.removeObserver(self)
        imageLoader = nil
        textLayout = nil
        selection = nil
        releaseSheetSelectionState()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil && window == nil {
            teardown()
        } else if superview != nil {
            setupScrollViewObservation()
            evaluateViewport()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            teardown()
        } else {
            setupScrollViewObservation()
            evaluateViewport()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        evaluateViewport()
    }

    private func setupScrollViewObservation() {
        let currentClip = enclosingScrollView?.contentView
        if observedClipView === currentClip { return }
        if let oldClip = observedClipView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: oldClip
            )
        }
        observedClipView = currentClip
        if let clip = currentClip {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipViewBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clip
            )
        }
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        // 表格视图按真实滚动视口绘制，滚动后必须立即重绘，
        // 否则外围行列标头与冻结窗格在滚动期间会停留在旧位置
        if document?.kind == .xlsx {
            needsDisplay = true
        }
        evaluateViewport()
    }

    func setDocument(_ newDoc: OfficeDocument) {
        let isDocChanged = (document?.kind != newDoc.kind ||
            document?.width != newDoc.width ||
            document?.pages.count != newDoc.pages.count ||
            document?.sheets.count != newDoc.sheets.count ||
            document?.blocks.count != newDoc.blocks.count)
        if isDocChanged && document != nil {
            textLayout = nil
            selection = nil
        }
        document = newDoc
        // 文档真的换了才丢弃 XLSX 选区：SwiftUI 每次重绘都会重入本方法，
        // 无条件清理会把用户刚拖出来的选区在下一帧擦掉
        if isDocChanged {
            releaseSheetSelectionState()
        }
        if isDocChanged || docxLayoutPlan == nil {
            docxLayoutPlan = newDoc.kind == .docx ? CGElementDrawer.layoutDocxBlocks(in: newDoc) : nil
            textLayout = nil
            selection = nil
            window?.invalidateCursorRects(for: self)
        }
        evaluateViewport()
    }

    // MARK: - 视口监听与图片按需收集

    func updateVisibleAndPrefetchRects() -> (visible: CGRect, prefetch: CGRect)? {
        let safeZoom = max(0.1, zoom)
        let visible = visibleRect
        guard visible.width > 0, visible.height > 0 else { return nil }

        let docVisible = CGRect(
            x: visible.minX / safeZoom,
            y: visible.minY / safeZoom,
            width: visible.width / safeZoom,
            height: visible.height / safeZoom
        )
        let prefetch = docVisible.insetBy(dx: 0, dy: -docVisible.height * 0.75)
        return (docVisible, prefetch)
    }

    private func expandedDocxHitRect(_ placement: CGElementDrawer.DocxBlockPlacement) -> CGRect {
        let m = placement.element.transform
        let rotated = m.count >= 6 && (abs(m[1]) > 0.001 || abs(m[2]) > 0.001 || m[0] < 0 || m[3] < 0)
        let pad = rotated ? max(8, max(placement.frame.width, placement.frame.height) * 0.5) : 8
        return placement.frame.insetBy(dx: -pad, dy: -pad)
    }

    func collectWantedParts(in docVisible: CGRect, prefetch: CGRect) -> (visible: [String], prefetch: [String]) {
        guard let doc = document else { return ([], []) }
        var visibleImages: [String] = []
        var prefetchImages: [String] = []

        switch doc.kind {
        case .pptx:
            var curY: CGFloat = 0
            for page in doc.pages {
                let pW = page.width > 0 ? page.width : 720
                let pH = page.height > 0 ? page.height : 405
                let slideRect = CGRect(x: 0, y: curY, width: pW, height: pH)
                let isVisible = slideRect.intersects(docVisible)
                let isPrefetch = slideRect.intersects(prefetch)

                if isVisible || isPrefetch {
                    for el in page.elements where el.type == .image {
                        if let part = el.image {
                            if isVisible { visibleImages.append(part) }
                            else { prefetchImages.append(part) }
                        }
                    }
                }
                curY += pH + 16
            }

        case .docx:
            guard let plan = docxLayoutPlan else { return ([], []) }
            for placement in plan.placements {
                let hitRect = expandedDocxHitRect(placement)
                let isVisible = hitRect.intersects(docVisible)
                let isPrefetch = hitRect.intersects(prefetch)
                guard isVisible || isPrefetch else { continue }

                let block = placement.element
                if block.type == .image, let part = block.image {
                    if isVisible { visibleImages.append(part) }
                    else { prefetchImages.append(part) }
                }
                if block.type == .table {
                    for row in block.rows {
                        for cell in row {
                            for p in cell {
                                if let part = p.image {
                                    if isVisible { visibleImages.append(part) }
                                    else { prefetchImages.append(part) }
                                }
                            }
                        }
                    }
                }
            }

        case .xlsx:
            break
        }

        return (visibleImages, prefetchImages)
    }

    func evaluateViewport() {
        guard !isEvaluatingViewport else { return }
        isEvaluatingViewport = true
        defer { isEvaluatingViewport = false }

        guard let (docVisible, prefetch) = updateVisibleAndPrefetchRects() else { return }

        if let loader = imageLoader {
            let (visibleImages, prefetchImages) = collectWantedParts(in: docVisible, prefetch: prefetch)
            loader.request(visibleParts: visibleImages, prefetchParts: prefetchImages)
        }

        // 动态计算当前页码 (PPTX)
        if let doc = document, doc.kind == .pptx, !doc.pages.isEmpty {
            let midY = docVisible.midY
            var detectedPage: Int = 1
            let totalDocHeight = doc.pages.reduce(CGFloat(0)) { $0 + ($1.height > 0 ? $1.height : 405) + 16 }
            if docVisible.minY <= 2 {
                detectedPage = 1
            } else if docVisible.maxY >= totalDocHeight - 4 {
                detectedPage = doc.pages.count
            } else {
                var curY: CGFloat = 0
                for (index, page) in doc.pages.enumerated() {
                    let pH = page.height > 0 ? page.height : 405
                    let slideTop = curY
                    let slideBottom = curY + pH + 16
                    if midY >= slideTop && midY < slideBottom {
                        detectedPage = index + 1
                        break
                    }
                    curY += pH + 16
                }
            }

            if detectedPage != currentPage {
                currentPage = detectedPage
                onPageDetected?(detectedPage)
            }
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
                    docxPlan: docxLayoutPlan
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
            // 表格启用冻结窗格时按轴避让：命中冻结侧保持该轴滚动，避免目标被冻结区遮挡
            if let doc = self.document, doc.kind == .xlsx, self.zoom > 0 {
                let index = max(0, min(doc.sheets.count - 1, self.currentPage - 1))
                if index < doc.sheets.count {
                    let safeZoom = max(0.1, self.zoom)
                    let frozenViewport = CGRect(
                        x: clipBounds.minX / safeZoom,
                        y: clipBounds.minY / safeZoom,
                        width: clipBounds.width / safeZoom,
                        height: clipBounds.height / safeZoom
                    )
                    let plan = CGElementDrawer.sheetFreezePlan(sheet: doc.sheets[index], viewport: frozenViewport)
                    let target = CGElementDrawer.sheetScrollTarget(
                        docRect: docRect,
                        plan: plan,
                        clipSize: clipBounds.size,
                        contentOffset: clipBounds.origin,
                        contentSize: self.bounds.size,
                        zoom: self.zoom
                    )
                    // 剩余偏移换算回文档坐标后交给滚动视图
                    let resolvedX = min(max(0, target.x), maxX)
                    let resolvedY = min(max(0, target.y), maxY)
                    clipView.animator().scroll(to: NSPoint(x: resolvedX, y: resolvedY))
                    self.enclosingScrollView?.reflectScrolledClipView(clipView)
                    return
                }
            }
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
        // XLSX 不参与自由划词，避免构建空的文本索引
        guard document?.kind != .xlsx, let layout = ensureTextLayout() else { return }
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

        let safeZoom = max(0.1, zoom)
        let docVisible: CGRect
        if visibleRect.width > 0, visibleRect.height > 0 {
            docVisible = CGRect(
                x: visibleRect.minX / safeZoom,
                y: visibleRect.minY / safeZoom,
                width: visibleRect.width / safeZoom,
                height: visibleRect.height / safeZoom
            )
        } else {
            docVisible = CGRect(
                x: bounds.minX / safeZoom,
                y: bounds.minY / safeZoom,
                width: bounds.width / safeZoom,
                height: bounds.height / safeZoom
            )
        }
        let activeImages = imageLoader?.snapshot ?? images
        // 表格冻结几何：正文绘制时确定，检索高亮复用同一份结果保证裁剪一致
        var xlsxFreezePlan: CGElementDrawer.SheetFreezePlan? = nil

        switch doc.kind {
        case .pptx:
            var curY: CGFloat = 0
            for page in doc.pages {
                let pW = page.width > 0 ? page.width : 720
                let pH = page.height > 0 ? page.height : 405
                let slideRect = CGRect(x: 0, y: curY, width: pW, height: pH)

                // 视口裁剪：若幻灯片与当前视口不相交，直接跳过全量绘制
                if !slideRect.intersects(docVisible) {
                    curY += pH + 16
                    continue
                }

                ctx.saveGState()
                ctx.translateBy(x: 0, y: curY)
                let localRect = CGRect(x: 0, y: 0, width: pW, height: pH)
                let bg = CGElementDrawer.argbToCGColor(page.background) ?? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
                ctx.setFillColor(bg)
                ctx.fill(localRect)
                ctx.clip(to: localRect)
                for el in page.elements {
                    CGElementDrawer.drawElement(in: ctx, element: el, images: activeImages)
                }
                ctx.restoreGState()
                curY += pH + 16
            }
        case .docx:
            let docW = doc.width > 0 ? doc.width : 595
            let docH = bounds.height / safeZoom
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: docW, height: docH))
            let plan = docxLayoutPlan ?? CGElementDrawer.layoutDocxBlocks(in: doc)
            for idx in plan.zOrder {
                let placement = plan.placements[idx]
                if !expandedDocxHitRect(placement).intersects(docVisible) {
                    continue
                }
                CGElementDrawer.drawDocxPlacement(in: ctx, placement: placement, images: activeImages)
            }
        case .xlsx:
            let idx = max(0, min(doc.sheets.count - 1, currentPage - 1))
            guard idx < doc.sheets.count else { return }
            // 传入真实滚动视口：外围行列标头与冻结窗格据此固定在视口边缘
            let sheet = doc.sheets[idx]
            CGElementDrawer.drawSpreadsheet(
                in: ctx,
                sheet: sheet,
                styles: doc.cellStyles,
                viewport: docVisible,
                selection: sheetSelection,
                zoom: safeZoom
            )
            xlsxFreezePlan = CGElementDrawer.sheetFreezePlan(sheet: sheet, viewport: docVisible)
        }

        // 绘制全文检索高亮（在文档未缩放坐标系下，由 ctx.scaleBy 统一放大）
        if !searchResults.isEmpty {
            let docVisibleRect = docVisible
            ctx.saveGState()
            for (index, match) in searchResults.enumerated() {
                if doc.kind == .xlsx && match.pageIndex != (currentPage - 1) {
                    continue
                }
                let isCurrent = (index == currentMatchIndex)
                if !isCurrent {
                    if doc.kind == .docx, let placements = docxLayoutPlan?.placements,
                       match.elementIndex >= 0, match.elementIndex < placements.count {
                        let placement = placements[match.elementIndex]
                        let blockY = placement.frame.minY
                        let blockBottom = max(placement.frame.maxY, blockY + 1200)
                        if blockY > docVisibleRect.maxY + 50 || blockBottom < docVisibleRect.minY {
                            continue
                        }
                    }
                }
                let rects = CGElementDrawer.computeHighlightRects(
                    for: match,
                    in: doc,
                    docxPlan: docxLayoutPlan
                )
                for r in rects {
                    // 非表格文档可先按 docVisibleRect 预裁剪；表格需先经象限映射再裁剪，避免冻结区非当前命中随滚动消失
                    if doc.kind != .xlsx && !isCurrent && !r.intersects(docVisibleRect) {
                        continue
                    }
                    // 表格启用冻结时按象限裁剪：滚动区高亮绝不覆盖冻结区，冻结区高亮随未冻结轴滚动
                    let pieces: [(rect: CGRect, clip: CGRect?)] = if doc.kind == .xlsx, let plan = xlsxFreezePlan {
                        CGElementDrawer.clipSheetHighlight(
                            r,
                            plan: plan,
                            rowCount: doc.sheets[max(0, min(doc.sheets.count - 1, currentPage - 1))].rowHeights.count,
                            columnCount: doc.sheets[max(0, min(doc.sheets.count - 1, currentPage - 1))].columnWidths.count
                        ).map { (rect: $0.rect, clip: Optional($0.clip)) }
                    } else {
                        [(rect: r, clip: nil)]
                    }
                    for piece in pieces {
                        if let clip = piece.clip {
                            ctx.saveGState()
                            ctx.clip(to: clip)
                        }
                        let path = CGPath(roundedRect: piece.rect, cornerWidth: 2, cornerHeight: 2, transform: nil)
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
                        if piece.clip != nil {
                            ctx.restoreGState()
                        }
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
                    if !r.intersects(docVisible) {
                        continue
                    }
                    let path = CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil)
                    ctx.addPath(path)
                    ctx.fillPath()
                }
                ctx.restoreGState()
            }
        }
    }

    // MARK: - XLSX 单元格选区

    /// 当前工作表对象（非 XLSX 或没有工作表时返回 nil）
    private func currentSheet() -> OfficeSheet? {
        guard let document, document.kind == .xlsx, !document.sheets.isEmpty else { return nil }
        let index = max(0, min(document.sheets.count - 1, currentPage - 1))
        guard index < document.sheets.count else { return nil }
        return document.sheets[index]
    }

    /// 当前工作表的模型侧布局（按工作表指纹缓存，前缀和构造代价与行列数成正比）
    internal func currentSheetLayout() -> SheetSelectionModel.SheetSelectionLayout? {
        guard let sheet = currentSheet() else { return nil }
        let fingerprint = SheetLayoutFingerprint(page: currentPage, sheet: sheet)
        if let cached = sheetLayoutCache, cached.fingerprint == fingerprint {
            return cached.layout
        }
        let layout = CGElementDrawer.sheetSelectionLayout(sheet: sheet)
        sheetLayoutCache = (fingerprint, layout)
        return layout
    }

    /// 丢弃 XLSX 选区、拖拽锚点与布局缓存
    internal func releaseSheetSelectionState() {
        sheetSelection = nil
        sheetDragAnchor = nil
        sheetLayoutCache = nil
    }

    /// 是否存在任一格式的非空选区
    var hasAnySelection: Bool {
        if document?.kind == .xlsx { return sheetSelection != nil }
        return selection != nil && selection?.isEmpty == false
    }

    /// 当前选区的纯文本：XLSX 为 TSV，DOCX/PPTX 为换行连接的正文
    func currentSelectedText() -> String {
        if document?.kind == .xlsx {
            guard let sheetSelection, let sheet = currentSheet(), let layout = currentSheetLayout() else { return "" }
            return SheetSelectionModel.selectedText(sheet: sheet, layout: layout, selection: sheetSelection)
        }
        guard let selection, !selection.isEmpty, let layout = ensureTextLayout() else { return "" }
        return layout.selectedText(for: selection)
    }

    /// 当前工作表能否全选（存在至少一个非空文本单元格且有可见行列）
    func canSelectAll() -> Bool {
        if document?.kind == .xlsx {
            guard let sheet = currentSheet(), let layout = currentSheetLayout() else { return false }
            return SheetSelectionModel.allRange(sheet: sheet, layout: layout) != nil
        }
        return !(ensureTextLayout()?.blocks.isEmpty ?? true)
    }

    /// 选中全部内容；XLSX 下为整表可见数据区。返回是否成功建立选区
    @discardableResult
    func performSelectAll() -> Bool {
        if document?.kind == .xlsx {
            guard let sheet = currentSheet(), let layout = currentSheetLayout(),
                  let all = SheetSelectionModel.allRange(sheet: sheet, layout: layout) else { return false }
            sheetSelection = all
            sheetDragAnchor = nil
            needsDisplay = true
            return true
        }
        guard let all = ensureTextLayout()?.allTextRange(), !all.isEmpty else { return false }
        selection = all
        needsDisplay = true
        return true
    }

    /// 清除两种格式的选区；无选区时为空操作
    func performClearSelection() {
        let hadSheet = sheetSelection != nil
        let hadText = selection != nil
        releaseSheetSelectionState()
        selection = nil
        if hadSheet || hadText {
            needsDisplay = true
        }
    }

    /// 把当前选区写入系统剪贴板；返回是否真的写入了非空文本
    @discardableResult
    func writeSelectionToPasteboard() -> Bool {
        let text = currentSelectedText()
        guard !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    /// 把视图坐标下的鼠标点换算成模型需要的「视图数据坐标」，再交给命中测试。
    ///
    /// 模型的坐标约定（由 `scripts/tests/SheetSelectionChecks.java` 钉死）是：
    /// 标头块占据 `[0, headerWidth)`，冻结列区紧接其后占据 `[headerWidth, headerWidth + frozenDataW)`，
    /// 滚动区从 `headerWidth + frozenDataW` 起算并叠加 `scrollDataX`。也就是说原点落在
    /// **当前可见窗口的左上角**，而不是整张工作表的左上角。
    ///
    /// 换算链条（与 `draw(_:)` 的绘制链条严格对应）：
    ///
    /// 1. `draw(_:)` 只做了 `ctx.scaleBy(x: zoom, y: zoom)`，没有平移；
    ///    `drawSpreadsheet` 收到的 `viewport` 就是 `docVisible`，它把标头画在
    ///    `plan.headerLeft = scrollX`、把滚动区单元格画在原始文档位置、把冻结区单元格
    ///    平移 `scrollX` 后画在冻结边界内——三者都落在「文档坐标 == 视图坐标」这一套量纲里；
    /// 2. 因此鼠标视图点除以 `zoom` 得到的就是文档坐标 `docX`；
    /// 3. 再减去可见窗口原点 `docVisible.minX`，把「整表文档坐标」平移到「可见窗口原点」，
    ///    正好对应模型期望的原点约定。
    ///
    /// 换算结果自检：滚动区单元格的文档位置是 `colOffsets[c]`，模型收到的
    /// `viewX = colOffsets[c] - scrollX`，于是 `bodyX = viewX - headerWidth = cum[c] - scrollX`；
    /// 因 `bodyX >= frozenDataW` 而叠加滚动量后 `dataX = cum[c]`，
    /// `axis.first(headerWidth + dataX) = axis.first(colOffsets[c]) = c`，命中正确列。
    /// 冻结列单元格的文档位置是 `colOffsets[c] + scrollX`，
    /// `viewX = colOffsets[c]` 落在 `[headerWidth, headerWidth + frozenDataW)` 内、
    /// 不叠加滚动量，同样命中正确列。两处都对得上，说明该换算在四象限内一致。
    ///
    /// - Parameters:
    ///   - viewPoint: 视图坐标（`isFlipped` 为 true，原点在左上角，未除以缩放）
    ///   - docVisible: 当前可见窗口的文档坐标矩形；`nil` 时按视图实时状态推导
    func sheetCell(
        atViewPoint viewPoint: CGPoint,
        docVisible overrideDocVisible: CGRect? = nil,
        clampToBounds: Bool
    ) -> SheetSelectionModel.CellCoord? {
        guard let sheet = currentSheet(), let layout = currentSheetLayout() else { return nil }
        let docVisible = overrideDocVisible ?? currentDocVisibleRect()
        let plan = CGElementDrawer.sheetFreezePlan(sheet: sheet, viewport: docVisible)
        let safeZoom = max(0.01, zoom)
        return SheetSelectionModel.hitTest(
            layout: layout,
            effFrozenRows: plan.effectiveRows,
            effFrozenCols: plan.effectiveColumns,
            frozenDataW: plan.frozenDataWidth,
            frozenDataH: plan.frozenDataHeight,
            scrollDataX: plan.scrollX,
            scrollDataY: plan.scrollY,
            viewX: viewPoint.x / safeZoom - docVisible.minX,
            viewY: viewPoint.y / safeZoom - docVisible.minY,
            clampToBounds: clampToBounds
        )
    }

    /// 当前可见窗口在文档坐标系下的矩形（与 `draw(_:)` 里的 `docVisible` 同源）
    private func currentDocVisibleRect() -> CGRect {
        let safeZoom = max(0.1, zoom)
        if visibleRect.width > 0, visibleRect.height > 0 {
            return CGRect(
                x: visibleRect.minX / safeZoom,
                y: visibleRect.minY / safeZoom,
                width: visibleRect.width / safeZoom,
                height: visibleRect.height / safeZoom
            )
        }
        return CGRect(
            x: bounds.minX / safeZoom,
            y: bounds.minY / safeZoom,
            width: bounds.width / safeZoom,
            height: bounds.height / safeZoom
        )
    }

    /// 把鼠标事件命中成单元格坐标；`clampToBounds` 为 true 时越界钳位到边缘（拖拽扩选需要）
    func sheetCell(at event: NSEvent, clampToBounds: Bool) -> SheetSelectionModel.CellCoord? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        return sheetCell(atViewPoint: viewPoint, clampToBounds: clampToBounds)
    }

    /// XLSX 鼠标按下：建立单格选区并固定拖拽锚点
    private func handleSheetMouseDown(with event: NSEvent) -> Bool {
        guard document?.kind == .xlsx else { return false }
        guard let sheet = currentSheet() else { return false }
        guard let coord = sheetCell(at: event, clampToBounds: false) else {
            // 落在标头或表格外：沿用系统行为，同时清掉旧选区
            if sheetSelection != nil {
                sheetSelection = nil
                sheetDragAnchor = nil
                needsDisplay = true
            }
            return false
        }
        sheetDragAnchor = coord
        sheetSelection = SheetSelectionModel.resolve(sheet: sheet, anchor: coord, focus: coord)
        needsDisplay = true
        return true
    }

    /// XLSX 拖拽扩选：锚点固定，焦点跟随鼠标；拖出边缘时钳位以继续扩选
    private func handleSheetMouseDragged(with event: NSEvent) {
        guard document?.kind == .xlsx, let sheet = currentSheet() else { return }
        guard let anchor = sheetDragAnchor else {
            _ = handleSheetMouseDown(with: event)
            return
        }
        guard let focus = sheetCell(at: event, clampToBounds: true) else { return }
        let resolved = SheetSelectionModel.resolve(sheet: sheet, anchor: anchor, focus: focus)
        if resolved != sheetSelection {
            sheetSelection = resolved
            needsDisplay = true
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
        // XLSX 只做单元格点选，不构建文本索引（表格不参与自由划词）；
        // 点在标头或表格外时回落系统行为，同时清掉旧选区
        if document?.kind == .xlsx {
            if !handleSheetMouseDown(with: event) {
                super.mouseDown(with: event)
            }
            return
        }
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
        // XLSX：锚点固定、焦点随鼠标，拖出边缘时钳位继续扩选
        if document?.kind == .xlsx {
            handleSheetMouseDragged(with: event)
            return
        }
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
        // XLSX：松手结束拖拽，锚点保留在选区里（后续再按下会重新取锚点）
        if document?.kind == .xlsx {
            sheetDragAnchor = nil
            super.mouseUp(with: event)
            return
        }
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
        // XLSX 与文本共用同一出口：选区文本由 currentSelectedText 按文档类型分派
        _ = writeSelectionToPasteboard()
    }

    @objc override func selectAll(_ sender: Any?) {
        _ = performSelectAll()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) {
            return hasAnySelection
        }
        if menuItem.action == #selector(selectAll(_:)) {
            return canSelectAll()
        }
        return true
    }

    // MARK: - 右键上下文菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Context Menu")

        if document?.kind == .xlsx {
            // XLSX：右键落在未选中的单元格上时先选它，再展示菜单（与表格软件习惯一致）
            if sheetSelection == nil, let coord = sheetCell(at: event, clampToBounds: false),
               let sheet = currentSheet() {
                sheetSelection = SheetSelectionModel.resolve(sheet: sheet, anchor: coord, focus: coord)
                sheetDragAnchor = nil
                needsDisplay = true
            }
        } else if selection == nil || selection!.isEmpty {
            // 若右键时未选中文本，尝试智能选词
            let docPoint = documentPoint(for: event)
            if let layout = ensureTextLayout(),
               let pos = layout.hitTest(docPoint: docPoint),
               let word = layout.wordRange(at: pos) {
                selection = word
                needsDisplay = true
            }
        }

        let copyItem = NSMenuItem(title: "复制", action: #selector(copy(_:)), keyEquivalent: "c")
        copyItem.target = self
        copyItem.isEnabled = hasAnySelection
        menu.addItem(copyItem)

        menu.addItem(NSMenuItem.separator())

        let selectAllItem = NSMenuItem(title: "全选", action: #selector(selectAll(_:)), keyEquivalent: "a")
        selectAllItem.target = self
        selectAllItem.isEnabled = canSelectAll()
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
