import Testing
import Foundation
import CoreGraphics
@testable import JZOffice

struct JZOfficeTests {

    private func samplePath(_ name: String) -> URL {
        // viewer-macos/Tests/JZOfficeTests/JZOfficeTests.swift -> repo root -> demo/src/main/assets/samples/<name>
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appendingPathComponent("demo/src/main/assets/samples/\(name)")
    }

    @Test("OfficeMetadata 读取 DOCX / PPTX / XLSX")
    func metadataAllFormats() throws {
        let docxURL = samplePath("sample.docx")
        let pptxURL = samplePath("sample.pptx")
        let xlsxURL = samplePath("sample.xlsx")

        guard FileManager.default.fileExists(atPath: docxURL.path) else {
            return
        }

        let docxMeta = try OfficeMetadata.read(from: docxURL)
        #expect(docxMeta.format == .docx)
        #expect(docxMeta.pageCount == 1)
        #expect(docxMeta.widthPt > 0)
        #expect(docxMeta.heightPt == 0)
        #expect(docxMeta.sheetNames.isEmpty)

        let pptxMeta = try OfficeMetadata.read(from: pptxURL)
        #expect(pptxMeta.format == .pptx)
        #expect(pptxMeta.pageCount >= 1)
        #expect(pptxMeta.widthPt > 0)
        #expect(pptxMeta.heightPt > 0)
        #expect(pptxMeta.sheetNames.isEmpty)

        let xlsxMeta = try OfficeMetadata.read(from: xlsxURL)
        #expect(xlsxMeta.format == .xlsx)
        #expect(xlsxMeta.pageCount == xlsxMeta.sheetNames.count)
        #expect(!xlsxMeta.sheetNames.isEmpty)
        #expect(xlsxMeta.widthPt >= 0)
        #expect(xlsxMeta.heightPt == 0)
    }

    @Test("OfficeThumbnail 离屏渲染 DOCX / PPTX / XLSX 非空白且遵守边界约束")
    func thumbnailAllFormats() throws {
        for name in ["sample.docx", "sample.pptx", "sample.xlsx"] {
            let url = samplePath(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let cgImg = try OfficeThumbnail.renderCGImage(from: url, maxSize: CGSize(width: 240, height: 240))
            #expect(cgImg.width > 0)
            #expect(cgImg.height > 0)
            #expect(cgImg.width <= 240)
            #expect(cgImg.height <= 240)
            #expect(hasNonWhitePixel(cgImg), "Thumbnail for \(name) should contain non-white content")
        }
    }

    @Test("OfficePreviewController 页码与工作表状态同步")
    @MainActor
    func previewControllerAndSheetSync() {
        let controller = OfficePreviewController()
        var callbackCount = 0
        var lastPage = -1
        var lastTotal = -1
        let id = controller.addOnPageChangeListener { page, count in
            callbackCount += 1
            lastPage = page
            lastTotal = count
        }
        #expect(callbackCount == 1)
        #expect(lastPage == 0)

        controller.updateDocumentState(page: 1, count: 3, sheets: ["概览", "明细", "汇总"])
        #expect(lastPage == 1)
        #expect(lastTotal == 3)

        controller.selectSheet(2)
        #expect(controller.currentPage == 2)
        #expect(lastPage == 2)

        controller.removeOnPageChangeListener(id)
    }

    @Test("ImageStore 从 ZIP 包内解码图片并驱逐缓存")
    func imageStoreDecodeAndCacheEviction() throws {
        let pptxURL = samplePath("sample.pptx")
        guard FileManager.default.fileExists(atPath: pptxURL.path) else { return }
        let doc = try NativeCore.parseDocument(at: pptxURL.path)
        let store = ImageStore(filePath: pptxURL.path)
        defer { store.release() }

        var decodedCount = 0
        for page in doc.pages {
            for el in page.elements where el.type == .image {
                if let part = el.image, store.loadSync(part: part, maxPixelBudget: 1_000_000) != nil {
                    decodedCount += 1
                }
            }
        }
        #expect(decodedCount >= 1)
    }

    @Test("按页缩略图与 PDF / PNG 矢量导出校验")
    func perPageThumbnailAndExporters() throws {
        let pptxURL = samplePath("sample.pptx")
        guard FileManager.default.fileExists(atPath: pptxURL.path) else { return }

        let slide2 = try OfficeThumbnail.renderPageCGImage(
            from: pptxURL,
            pageNumber: 2,
            maxSize: CGSize(width: 240, height: 240)
        )
        #expect(slide2.width > 0)
        #expect(hasNonWhitePixel(slide2))

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jz-office-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for name in ["sample.docx", "sample.pptx", "sample.xlsx"] {
            let src = samplePath(name)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            let pdfOut = tempDir.appendingPathComponent("\(name).pdf")
            try OfficeExporter.exportPDF(from: src, to: pdfOut)
            let pdfData = try Data(contentsOf: pdfOut)
            #expect(pdfData.count > 256)
        }

        let pngOut = tempDir.appendingPathComponent("slide1.png")
        try OfficeExporter.exportPNG(
            from: pptxURL,
            pageNumber: 1,
            maxSize: CGSize(width: 480, height: 480),
            to: pngOut
        )
        let pngData = try Data(contentsOf: pngOut)
        #expect(pngData.count > 256)
    }

    @Test("DocumentTextLayout 空间索引、命中测试与选区计算")
    func documentTextLayoutAndSelection() throws {
        let docxURL = samplePath("sample.docx")
        guard FileManager.default.fileExists(atPath: docxURL.path) else { return }

        let doc = try NativeCore.parseDocument(at: docxURL.path)
        let layout = DocumentTextLayout.build(from: doc)
        #expect(!layout.blocks.isEmpty)

        // 验证至少有一个 block 包含有效行与文本
        guard let firstBlock = layout.blocks.first(where: { !$0.lines.isEmpty && !$0.fullText.isEmpty }) else {
            Issue.record("未在 sample.docx 中解析出任何文本块")
            return
        }
        #expect(!firstBlock.fullText.isEmpty)

        // 1. 命中测试：取第一行的中心点
        let firstLine = firstBlock.lines[0]
        let hitPoint = CGPoint(
            x: firstBlock.bounds.minX + firstLine.rect.midX,
            y: firstBlock.bounds.minY + firstLine.rect.midY
        )
        let hitPos = layout.hitTest(docPoint: hitPoint)
        #expect(hitPos != nil)
        #expect(hitPos?.blockIndex == firstBlock.blockIndex)

        // 2. 选区与文本提取：选取该 block 的前几个字符
        let selEndChar = min(5, (firstBlock.fullText as NSString).length)
        let sel = TextSelection(
            anchor: TextPosition(blockIndex: firstBlock.blockIndex, charIndex: 0),
            focus: TextPosition(blockIndex: firstBlock.blockIndex, charIndex: selEndChar)
        )
        #expect(!sel.isEmpty)
        let extracted = layout.selectedText(for: sel)
        #expect(!extracted.isEmpty)
        #expect(extracted.count <= selEndChar)

        // 3. 高亮矩形计算
        let rects = layout.selectionRects(for: sel)
        #expect(!rects.isEmpty)
        for r in rects {
            #expect(r.width > 0)
            #expect(r.height > 0)
        }

        // 4. 双击选词
        if let wordSel = layout.wordRange(at: TextPosition(blockIndex: firstBlock.blockIndex, charIndex: 0)) {
            #expect(!wordSel.isEmpty)
            #expect(wordSel.start.charIndex <= wordSel.end.charIndex)
        }

        // 5. 全选
        if let allSel = layout.allTextRange() {
            #expect(!allSel.isEmpty)
            let allText = layout.selectedText(for: allSel)
            #expect(!allText.isEmpty)
        }

        // 6. PPTX 幻灯片多元素文本排版与选区验证
        let pptxURL = samplePath("sample.pptx")
        if FileManager.default.fileExists(atPath: pptxURL.path) {
            let pptxDoc = try NativeCore.parseDocument(at: pptxURL.path)
            let pptxLayout = DocumentTextLayout.build(from: pptxDoc)
            #expect(!pptxLayout.blocks.isEmpty)
            if let pptxSel = pptxLayout.allTextRange() {
                let pptxText = pptxLayout.selectedText(for: pptxSel)
                #expect(!pptxText.isEmpty)
            }
        }
    }

    private func hasNonWhitePixel(_ image: CGImage) -> Bool {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return false }
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &bytes,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: bytes.count, by: 16) {
            let r = bytes[i]
            let g = bytes[i + 1]
            let b = bytes[i + 2]
            if r < 248 || g < 248 || b < 248 {
                return true
            }
        }
        return false
    }
}
