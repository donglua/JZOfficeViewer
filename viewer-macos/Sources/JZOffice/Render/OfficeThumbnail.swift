import Foundation
import CoreGraphics
import AppKit

/// macOS 端离屏文档封面/缩略图生成器（对齐 Android `OfficeThumbnail` 与鸿蒙 `renderOfficeThumbnail`）
public enum OfficeThumbnail {

    /// 同步解码并离屏渲染本地文档首页/首张幻灯片/首个工作表为指定最大尺寸的 `NSImage`（保持宽高比）
    public static func render(from url: URL, maxSize: CGSize) throws -> NSImage {
        try renderPage(from: url, pageNumber: 1, maxSize: maxSize)
    }

    /// 异步离屏渲染本地文档封面缩略图
    public static func renderAsync(from url: URL, maxSize: CGSize) async throws -> NSImage {
        try await renderPageAsync(from: url, pageNumber: 1, maxSize: maxSize)
    }

    /// 同步离屏渲染本地文档指定页（从 1 开始）为 `NSImage`
    public static func renderPage(from url: URL, pageNumber: Int, maxSize: CGSize) throws -> NSImage {
        let cgImage = try renderPageCGImage(from: url, pageNumber: pageNumber, maxSize: maxSize)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// 异步离屏渲染本地文档指定页（从 1 开始）为 `NSImage`
    public static func renderPageAsync(from url: URL, pageNumber: Int, maxSize: CGSize) async throws -> NSImage {
        let cgImage = try await Task.detached(priority: .userInitiated) {
            try renderPageCGImage(from: url, pageNumber: pageNumber, maxSize: maxSize)
        }.value
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// 同步离屏渲染本地文档首页为 `CGImage`
    public static func renderCGImage(from url: URL, maxSize: CGSize) throws -> CGImage {
        try renderPageCGImage(from: url, pageNumber: 1, maxSize: maxSize)
    }

    /// 同步离屏渲染本地文档指定页（从 1 开始）为 `CGImage`
    public static func renderPageCGImage(from url: URL, pageNumber: Int, maxSize: CGSize) throws -> CGImage {
        guard maxSize.width > 0 && maxSize.height > 0 else {
            throw OfficeError.invalidArguments("Target maxSize must be positive, got \(maxSize.width)x\(maxSize.height)")
        }
        guard pageNumber >= 1 else {
            throw OfficeError.invalidArguments("pageNumber must be >= 1, got \(pageNumber)")
        }
        let path = url.path
        // 封面只取首页：走首屏解析，避免为一张缩略图承担整篇文档的解析成本
        let doc = try NativeCore.parseFirstViewport(at: path)
        switch doc.kind {
        case .pptx:
            return try renderPptxThumbnail(filePath: path, doc: doc, pageIndex: pageNumber - 1, maxSize: maxSize)
        case .docx:
            return try renderDocxThumbnail(filePath: path, doc: doc, maxSize: maxSize)
        case .xlsx:
            defer { NativeCore.evictCache(at: path) }
            return try renderXlsxThumbnail(doc: doc, sheetIndex: pageNumber - 1, maxSize: maxSize)
        }
    }

    internal static func makeTopDownContext(width: Int, height: Int, scale: CGFloat) throws -> CGContext {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw OfficeError.renderFailed("Failed to allocate bitmap context \(width)x\(height)")
        }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        return ctx
    }

    private static func renderPptxThumbnail(
        filePath: String,
        doc: OfficeDocument,
        pageIndex: Int,
        maxSize: CGSize
    ) throws -> CGImage {
        guard !doc.pages.isEmpty else {
            NativeCore.evictCache(at: filePath)
            throw OfficeError.renderFailed("Presentation has no slides")
        }
        let clampedIndex = max(0, min(doc.pages.count - 1, pageIndex))
        let page = doc.pages[clampedIndex]
        let slideW = page.width > 0 ? page.width : 720
        let slideH = page.height > 0 ? page.height : 405
        let scale = min(maxSize.width / slideW, maxSize.height / slideH)
        let outW = max(1, Int(round(slideW * scale)))
        let outH = max(1, Int(round(slideH * scale)))

        let imageStore = ImageStore(filePath: filePath)
        defer { imageStore.release() }

        let budget = max(100_000, min(2_000_000, outW * outH * 2))
        for el in page.elements where el.type == .image {
            if let part = el.image {
                imageStore.loadSync(part: part, maxPixelBudget: budget)
            }
        }

        let ctx = try makeTopDownContext(width: outW, height: outH, scale: scale)
        let bg = CGElementDrawer.argbToCGColor(page.background) ?? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        ctx.setFillColor(bg)
        ctx.fill(CGRect(x: 0, y: 0, width: slideW, height: slideH))

        let cache = imageStore.snapshot
        for el in page.elements {
            CGElementDrawer.drawElement(in: ctx, element: el, images: cache)
        }
        guard let cgImage = ctx.makeImage() else {
            throw OfficeError.renderFailed("Failed to extract CGImage from PPTX context")
        }
        return cgImage
    }

    private static func renderDocxThumbnail(
        filePath: String,
        doc: OfficeDocument,
        maxSize: CGSize
    ) throws -> CGImage {
        let docW = doc.width > 0 ? doc.width : 595
        let docH = docW * 1.414
        let scale = min(maxSize.width / docW, maxSize.height / docH)
        let outW = max(1, Int(round(docW * scale)))
        let outH = max(1, Int(round(docH * scale)))

        let imageStore = ImageStore(filePath: filePath)
        defer { imageStore.release() }

        let allBlocks = doc.headerBlocks + doc.blocks + doc.footerBlocks
        let budget = max(100_000, min(2_000_000, outW * outH * 2))
        for block in allBlocks {
            if block.type == .image, let part = block.image {
                imageStore.loadSync(part: part, maxPixelBudget: budget)
            } else if block.type == .table {
                for row in block.rows {
                    for cell in row {
                        for p in cell {
                            if let part = p.image {
                                imageStore.loadSync(part: part, maxPixelBudget: budget)
                            }
                        }
                    }
                }
            }
        }

        let ctx = try makeTopDownContext(width: outW, height: outH, scale: scale)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: docW, height: docH))

        let marginX: CGFloat = doc.marginLeft > 0 ? doc.marginLeft : 24
        let marginR: CGFloat = doc.marginRight > 0 ? doc.marginRight : 24
        let availW = max(100, docW - marginX - marginR)
        var curY: CGFloat = doc.marginTop > 0 ? doc.marginTop : 24
        let cache = imageStore.snapshot

        for block in allBlocks {
            if curY >= docH - 16 { break }
            let elW = block.width > 0 ? min(availW, block.width) : availW
            var elH = block.height
            if elH <= 0 {
                if block.type == .table && !block.rows.isEmpty {
                    var tableBlock = block
                    tableBlock.width = elW
                    elH = CGElementDrawer.measureTableHeight(element: tableBlock)
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
            CGElementDrawer.drawElement(in: ctx, element: positioned, images: cache)
            curY += elH + 8
        }

        guard let cgImage = ctx.makeImage() else {
            throw OfficeError.renderFailed("Failed to extract CGImage from DOCX context")
        }
        return cgImage
    }

    private static func renderXlsxThumbnail(
        doc: OfficeDocument,
        sheetIndex: Int,
        maxSize: CGSize
    ) throws -> CGImage {
        guard !doc.sheets.isEmpty else {
            throw OfficeError.renderFailed("Spreadsheet has no sheets")
        }
        let clampedIndex = max(0, min(doc.sheets.count - 1, sheetIndex))
        let sheet = doc.sheets[clampedIndex]
        let (_, _, totalW, totalH) = CGElementDrawer.computeSheetExtents(sheet)
        let previewW = max(200, min(totalW > CGElementDrawer.sheetHeaderWidth ? totalW : 400, 800))
        let previewH = max(150, min(totalH > CGElementDrawer.sheetHeaderHeight ? totalH : 300, 600))
        let scale = min(maxSize.width / previewW, maxSize.height / previewH)
        let outW = max(1, Int(round(previewW * scale)))
        let outH = max(1, Int(round(previewH * scale)))

        let ctx = try makeTopDownContext(width: outW, height: outH, scale: scale)
        CGElementDrawer.drawSpreadsheet(
            in: ctx,
            sheet: sheet,
            styles: doc.cellStyles,
            viewport: CGRect(x: 0, y: 0, width: previewW, height: previewH)
        )
        guard let cgImage = ctx.makeImage() else {
            throw OfficeError.renderFailed("Failed to extract CGImage from XLSX context")
        }
        return cgImage
    }
}
