import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// macOS 端矢量 PDF 与高清 PNG 导出器
public enum OfficeExporter {

    /// 同步将本地 Office 文档导出为矢量 PDF 文件
    public static func exportPDF(from sourceURL: URL, to destinationURL: URL) throws {
        let path = sourceURL.path
        let doc = try NativeCore.parseDocument(at: path)
        let imageStore = ImageStore(filePath: path)
        defer { imageStore.release() }

        for page in doc.pages {
            for el in page.elements where el.type == .image {
                if let part = el.image {
                    imageStore.loadSync(part: part, maxPixelBudget: 4_000_000)
                }
            }
        }
        for block in (doc.headerBlocks + doc.blocks + doc.footerBlocks) {
            if block.type == .image, let part = block.image {
                imageStore.loadSync(part: part, maxPixelBudget: 4_000_000)
            } else if block.type == .table {
                for row in block.rows {
                    for cell in row {
                        for p in cell {
                            if let part = p.image {
                                imageStore.loadSync(part: part, maxPixelBudget: 4_000_000)
                            }
                        }
                    }
                }
            }
        }

        let cache = imageStore.snapshot
        guard let pdfCtx = CGContext(destinationURL as CFURL, mediaBox: nil, nil) else {
            throw OfficeError.renderFailed("Failed to create PDF context at \(destinationURL.path)")
        }

        switch doc.kind {
        case .pptx:
            for page in doc.pages {
                let pW = page.width > 0 ? page.width : 720
                let pH = page.height > 0 ? page.height : 405
                var mediaBox = CGRect(x: 0, y: 0, width: pW, height: pH)
                pdfCtx.beginPage(mediaBox: &mediaBox)
                pdfCtx.saveGState()
                pdfCtx.translateBy(x: 0, y: pH)
                pdfCtx.scaleBy(x: 1, y: -1)
                let bg = CGElementDrawer.argbToCGColor(page.background) ?? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
                pdfCtx.setFillColor(bg)
                pdfCtx.fill(mediaBox)
                for el in page.elements {
                    CGElementDrawer.drawElement(in: pdfCtx, element: el, images: cache)
                }
                pdfCtx.restoreGState()
                pdfCtx.endPage()
            }
        case .docx:
            let docW = doc.width > 0 ? doc.width : 595
            let marginX: CGFloat = doc.marginLeft > 0 ? doc.marginLeft : 24
            let marginR: CGFloat = doc.marginRight > 0 ? doc.marginRight : 24
            let marginTop: CGFloat = doc.marginTop > 0 ? doc.marginTop : 24
            let marginBottom: CGFloat = doc.marginBottom > 0 ? doc.marginBottom : 24
            let availW = max(100, docW - marginX - marginR)
            let allBlocks = doc.headerBlocks + doc.blocks + doc.footerBlocks

            var measuredBlocks: [(OfficeElement, CGFloat)] = []
            var totalH: CGFloat = marginTop + marginBottom
            for block in allBlocks {
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
                measuredBlocks.append((block, elH))
                totalH += elH + 8
            }
            let pageH = max(docW * 1.414, totalH)
            var mediaBox = CGRect(x: 0, y: 0, width: docW, height: pageH)
            pdfCtx.beginPage(mediaBox: &mediaBox)
            pdfCtx.saveGState()
            pdfCtx.translateBy(x: 0, y: pageH)
            pdfCtx.scaleBy(x: 1, y: -1)
            pdfCtx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            pdfCtx.fill(mediaBox)

            var curY = marginTop
            for (block, elH) in measuredBlocks {
                let elW = block.width > 0 ? min(availW, block.width) : availW
                var positioned = block
                positioned.x = marginX
                positioned.y = curY
                positioned.width = elW
                positioned.height = elH
                positioned.transform = [1, 0, 0, 1, marginX, curY]
                positioned.textWrap = true
                CGElementDrawer.drawElement(in: pdfCtx, element: positioned, images: cache)
                curY += elH + 8
            }
            pdfCtx.restoreGState()
            pdfCtx.endPage()
        case .xlsx:
            for sheet in doc.sheets {
                let (_, _, totalW, totalH) = CGElementDrawer.computeSheetExtents(sheet)
                let pageW = max(595, min(totalW + 24, 2400))
                let pageH = max(420, min(totalH + 24, 3200))
                var mediaBox = CGRect(x: 0, y: 0, width: pageW, height: pageH)
                pdfCtx.beginPage(mediaBox: &mediaBox)
                pdfCtx.saveGState()
                pdfCtx.translateBy(x: 0, y: pageH)
                pdfCtx.scaleBy(x: 1, y: -1)
                CGElementDrawer.drawSpreadsheet(
                    in: pdfCtx,
                    sheet: sheet,
                    styles: doc.cellStyles,
                    viewport: mediaBox
                )
                pdfCtx.restoreGState()
                pdfCtx.endPage()
            }
        }
        pdfCtx.closePDF()
    }

    /// 异步将本地 Office 文档导出为矢量 PDF 文件
    public static func exportPDFAsync(from sourceURL: URL, to destinationURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try exportPDF(from: sourceURL, to: destinationURL)
        }.value
    }

    /// 同步将指定页导出为 PNG 图片
    public static func exportPNG(
        from sourceURL: URL,
        pageNumber: Int = 1,
        maxSize: CGSize = CGSize(width: 1920, height: 1920),
        to destinationURL: URL
    ) throws {
        let cgImage = try OfficeThumbnail.renderPageCGImage(from: sourceURL, pageNumber: pageNumber, maxSize: maxSize)
        guard let dest = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw OfficeError.renderFailed("Failed to create PNG destination at \(destinationURL.path)")
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw OfficeError.renderFailed("Failed to finalize PNG write at \(destinationURL.path)")
        }
    }

    /// 异步将指定页导出为 PNG 图片
    public static func exportPNGAsync(
        from sourceURL: URL,
        pageNumber: Int = 1,
        maxSize: CGSize = CGSize(width: 1920, height: 1920),
        to destinationURL: URL
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try exportPNG(from: sourceURL, pageNumber: pageNumber, maxSize: maxSize, to: destinationURL)
        }.value
    }
}
