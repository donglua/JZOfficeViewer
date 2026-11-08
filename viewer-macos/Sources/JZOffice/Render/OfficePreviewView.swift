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

    @Published internal var document: OfficeDocument?
    @Published internal var imageCache: [String: CGImage] = [:]
    @Published internal var isLoading: Bool = true
    @Published internal var errorMessage: String?

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
        ZStack {
            Color(nsColor: NSColor(srgbRed: 0.97, green: 0.975, blue: 0.98, alpha: 1.0))
            if controller.isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在解析文档...")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
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
            } else if let doc = controller.document {
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    OfficeCanvasRepresentable(
                        document: doc,
                        images: controller.imageCache,
                        currentPage: controller.currentPage,
                        zoom: controller.zoom
                    )
                    .frame(
                        width: canvasContentSize(for: doc).width * controller.zoom,
                        height: canvasContentSize(for: doc).height * controller.zoom
                    )
                    .padding(16)
                }
            }
        }
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
            let allBlocks = doc.headerBlocks + doc.blocks + doc.footerBlocks
            let availW = max(100, docW - 48)
            var h: CGFloat = 48
            for block in allBlocks {
                if block.height > 0 {
                    h += block.height + 8
                } else if block.type == .table && !block.rows.isEmpty {
                    var tbl = block
                    tbl.width = availW
                    h += CGElementDrawer.measureTableHeight(element: tbl) + 8
                } else if !block.paragraphs.isEmpty {
                    h += CGElementDrawer.measureParagraphsHeight(block.paragraphs, availableWidth: availW, wrap: true) + 12
                } else {
                    h += 80
                }
            }
            return CGSize(width: docW, height: max(docW * 1.414, h))
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
        controller.imageCache = [:]
        controller.updateDocumentState(page: 0, count: 0, sheets: [])

        let path = url.path
        do {
            let (parsed, loadedImages) = try await Task.detached(priority: .userInitiated) {
                let doc = try NativeCore.parseDocument(at: path)
                let store = ImageStore(filePath: path)
                defer { store.release() }
                for page in doc.pages {
                    for el in page.elements where el.type == .image {
                        if let part = el.image {
                            store.loadSync(part: part, maxPixelBudget: 2_000_000)
                        }
                    }
                }
                for block in (doc.headerBlocks + doc.blocks + doc.footerBlocks) where block.type == .image {
                    if let part = block.image {
                        store.loadSync(part: part, maxPixelBudget: 2_000_000)
                    }
                }
                return (doc, store.snapshot)
            }.value

            controller.document = parsed
            controller.imageCache = loadedImages
            controller.isLoading = false

            let meta = OfficeMetadata.fromDocument(parsed)
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

    func makeNSView(context: Context) -> OfficeDocumentNSView {
        let view = OfficeDocumentNSView()
        view.document = document
        view.images = images
        view.currentPage = currentPage
        view.zoom = zoom
        return view
    }

    func updateNSView(_ nsView: OfficeDocumentNSView, context: Context) {
        nsView.document = document
        nsView.images = images
        nsView.currentPage = currentPage
        nsView.zoom = zoom
        nsView.needsDisplay = true
    }
}

private final class OfficeDocumentNSView: NSView {
    var document: OfficeDocument?
    var images: [String: CGImage] = [:]
    var currentPage: Int = 1
    var zoom: CGFloat = 1.0

    override var isFlipped: Bool { true }

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
    }
}
