import Testing
import Foundation
import CoreGraphics
import AppKit
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

        // 7. 针对 PPTX 表格与两端对齐段落的文本空间索引与选区校验
        let testPptxJson = """
        {
            "schemaVersion": 9,
            "kind": "PPTX",
            "width": 720,
            "pages": [{
                "width": 720,
                "height": 405,
                "elements": [
                    {
                        "type": "TABLE",
                        "width": 300,
                        "rows": [
                            [[{"runs": [{"text": "PPTX表格文字1"}]}], [{"runs": [{"text": "PPTX表格文字2"}]}]]
                        ]
                    },
                    {
                        "type": "TEXT",
                        "width": 120,
                        "paragraphs": [
                            {
                                "alignment": 3,
                                "runs": [{"text": "这是一个用于测试两端对齐排版以及末行不对齐行为的长文本测试段落。"}]
                            }
                        ]
                    }
                ]
            }]
        }
        """.data(using: .utf8)!
        let testPptxDoc = try JSONDecoder().decode(OfficeDocument.self, from: testPptxJson)
        let testPptxLayout = DocumentTextLayout.build(from: testPptxDoc)
        #expect(testPptxLayout.blocks.count >= 2)
        #expect(testPptxLayout.blocks[0].fullText.contains("PPTX表格文字1"))
        if let allSel = testPptxLayout.allTextRange() {
            let rects = testPptxLayout.selectionRects(for: allSel)
            #expect(!rects.isEmpty)
            for r in rects {
                #expect(r.width > 0)
                #expect(r.height > 0)
            }
        }
    }

    @Test("NativeCore 全文检索接口支持 DOCX / PPTX / XLSX 并返回 UTF-16 偏移与摘要")
    func fullTextSearchAllFormats() throws {
        let docxURL = samplePath("sample.docx")
        let pptxURL = samplePath("sample.pptx")
        let xlsxURL = samplePath("sample.xlsx")

        guard FileManager.default.fileExists(atPath: docxURL.path) else {
            return
        }

        // 空查询返回空数组
        let emptyMatches = try NativeCore.searchDocument(at: docxURL.path, query: "")
        #expect(emptyMatches.isEmpty)

        // DOCX 检索
        let docxDoc = try NativeCore.parseDocument(at: docxURL.path)
        let firstWord = docxDoc.blocks
            .flatMap(\.paragraphs)
            .flatMap(\.runs)
            .map(\.text)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !firstWord.isEmpty {
            let query = String(firstWord.prefix(2))
            let matches = try NativeCore.searchDocument(at: docxURL.path, query: query)
            #expect(!matches.isEmpty)
            #expect(matches[0].pageIndex == 0)
            #expect(matches[0].endChar > matches[0].startChar)
            #expect(!matches[0].snippet.isEmpty)
        }

        // PPTX 检索
        if FileManager.default.fileExists(atPath: pptxURL.path) {
            let pptxDoc = try NativeCore.parseDocument(at: pptxURL.path)
            let slideWord = pptxDoc.pages
                .flatMap(\.elements)
                .flatMap(\.paragraphs)
                .flatMap(\.runs)
                .map(\.text)
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !slideWord.isEmpty {
                let query = String(slideWord.prefix(2))
                let matches = try NativeCore.searchDocument(at: pptxURL.path, query: query)
                #expect(!matches.isEmpty)
                #expect(matches[0].endChar > matches[0].startChar)
            }
        }

        // XLSX 检索
        if FileManager.default.fileExists(atPath: xlsxURL.path) {
            let xlsxDoc = try NativeCore.parseDocument(at: xlsxURL.path)
            let cellWord = xlsxDoc.sheets
                .flatMap(\.cells)
                .map(\.text)
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !cellWord.isEmpty {
                let query = String(cellWord.prefix(2))
                let matches = try NativeCore.searchDocument(at: xlsxURL.path, query: query)
                #expect(!matches.isEmpty)
                #expect(matches[0].row != nil)
                #expect(matches[0].column != nil)
            }
        }
    }

    @Test("CGElementDrawer 全文检索高亮矩形计算与行偏移缓存")
    func computeHighlightRectsAllFormats() throws {
        let docxURL = samplePath("sample.docx")
        let pptxURL = samplePath("sample.pptx")
        let xlsxURL = samplePath("sample.xlsx")

        guard FileManager.default.fileExists(atPath: docxURL.path) else { return }

        // 1. DOCX 高亮矩形计算与行偏移缓存
        let docxDoc = try NativeCore.parseDocument(at: docxURL.path)
        let offsets = CGElementDrawer.computeDocxBlockYOffsets(in: docxDoc)
        #expect(offsets.count == docxDoc.headerBlocks.count + docxDoc.blocks.count + docxDoc.footerBlocks.count)
        for i in 1..<offsets.count {
            #expect(offsets[i] >= offsets[i - 1])
        }

        let docxWord = docxDoc.blocks
            .flatMap(\.paragraphs)
            .flatMap(\.runs)
            .map(\.text)
            .first { $0.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !docxWord.isEmpty {
            let matches = try NativeCore.searchDocument(at: docxURL.path, query: String(docxWord.prefix(2)))
            if let first = matches.first {
                let rects = CGElementDrawer.computeHighlightRects(for: first, in: docxDoc, docxBlockYOffsets: offsets)
                #expect(!rects.isEmpty)
                for r in rects {
                    #expect(r.width > 0)
                    #expect(r.height > 0)
                }
            }
        }

        // 2. PPTX 高亮矩形计算
        if FileManager.default.fileExists(atPath: pptxURL.path) {
            let pptxDoc = try NativeCore.parseDocument(at: pptxURL.path)
            let slideWord = pptxDoc.pages
                .flatMap(\.elements)
                .flatMap(\.paragraphs)
                .flatMap(\.runs)
                .map(\.text)
                .first { $0.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !slideWord.isEmpty {
                let matches = try NativeCore.searchDocument(at: pptxURL.path, query: String(slideWord.prefix(2)))
                if let first = matches.first {
                    let rects = CGElementDrawer.computeHighlightRects(for: first, in: pptxDoc)
                    #expect(!rects.isEmpty)
                    for r in rects {
                        #expect(r.width > 0)
                        #expect(r.height > 0)
                    }
                }
            }
        }

        // 3. XLSX 高亮矩形计算
        if FileManager.default.fileExists(atPath: xlsxURL.path) {
            let xlsxDoc = try NativeCore.parseDocument(at: xlsxURL.path)
            let cellWord = xlsxDoc.sheets
                .flatMap(\.cells)
                .map(\.text)
                .first { $0.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !cellWord.isEmpty {
                let matches = try NativeCore.searchDocument(at: xlsxURL.path, query: String(cellWord.prefix(2)))
                if let first = matches.first {
                    let rects = CGElementDrawer.computeHighlightRects(for: first, in: xlsxDoc)
                    #expect(!rects.isEmpty)
                    for r in rects {
                        #expect(r.width > 0)
                        #expect(r.height > 0)
                    }
                }
            }
        }
    }

    @Test("OfficePreviewController 检索状态转换与环形遍历")
    @MainActor
    func searchControllerStateTransitionsAndCycling() {
        let controller = OfficePreviewController()
        #expect(!controller.isSearchPresented)
        #expect(controller.searchQuery == "")
        #expect(controller.searchResults.isEmpty)
        #expect(controller.currentMatchIndex == -1)

        // 展示 / 收起交互
        controller.presentSearch()
        #expect(controller.isSearchPresented)

        controller.dismissSearch()
        #expect(!controller.isSearchPresented)
        #expect(controller.searchQuery == "")

        // 模拟命中项并测试环形跳转
        let match1 = OfficeSearchMatch(
            pageIndex: 0, elementIndex: 0, paragraphIndex: 0,
            row: nil, column: nil, startChar: 0, endChar: 2, snippet: "测试"
        )
        let match2 = OfficeSearchMatch(
            pageIndex: 0, elementIndex: 1, paragraphIndex: 0,
            row: nil, column: nil, startChar: 5, endChar: 7, snippet: "测试2"
        )
        controller.searchResults = [match1, match2]
        controller.currentMatchIndex = 0

        // findNext 环形递增
        #expect(controller.findNext())
        #expect(controller.currentMatchIndex == 1)
        #expect(controller.findNext())
        #expect(controller.currentMatchIndex == 0)

        // findPrevious 环形递减
        #expect(controller.findPrevious())
        #expect(controller.currentMatchIndex == 1)
        #expect(controller.findPrevious())
        #expect(controller.currentMatchIndex == 0)

        // 清空检索
        controller.clearSearch()
        #expect(controller.searchQuery == "")
        #expect(controller.searchResults.isEmpty)
        #expect(controller.currentMatchIndex == -1)
        #expect(controller.targetHighlightRect == nil)
    }

    @Test("DOCX 与 PPTX 表格横向与纵向合并单元格解析、几何测量与绘制")
    func tableMergedCellsDecodingMeasurementAndDrawing() throws {
        // 1. JSON 解码 OfficeElement 携带 merges
        let json = """
        {
            "type": "TABLE",
            "width": 300,
            "columnWidths": [100, 100, 100],
            "merges": [
                {"startRow": 0, "startColumn": 0, "endRow": 0, "endColumn": 1},
                {"startRow": 1, "startColumn": 0, "endRow": 2, "endColumn": 0}
            ],
            "rows": [
                [
                    [{"runs": [{"text": "跨2列合并"}]}],
                    [],
                    [{"runs": [{"text": "普通格0-2"}]}]
                ],
                [
                    [{"runs": [{"text": "跨2行纵向合并"}]}],
                    [{"runs": [{"text": "普通格1-1"}]}],
                    [{"runs": [{"text": "普通格1-2"}]}]
                ],
                [
                    [],
                    [{"runs": [{"text": "普通格2-1"}]}],
                    [{"runs": [{"text": "普通格2-2"}]}]
                ]
            ]
        }
        """.data(using: .utf8)!

        let element = try JSONDecoder().decode(OfficeElement.self, from: json)
        #expect(element.type == .table)
        #expect(element.merges.count == 2)
        #expect(element.merges[0].startRow == 0 && element.merges[0].endColumn == 1)
        #expect(element.merges[1].startRow == 1 && element.merges[1].endRow == 2)

        // 2. findMerge 命中与未命中校验
        let m0 = CGElementDrawer.findMerge(element.merges, r: 0, c: 0)
        #expect(m0 != nil)
        #expect(m0?.endColumn == 1)

        let m01 = CGElementDrawer.findMerge(element.merges, r: 0, c: 1)
        #expect(m01 != nil)
        #expect(m01?.startColumn == 0)

        let mNone = CGElementDrawer.findMerge(element.merges, r: 0, c: 2)
        #expect(mNone == nil)

        let mV = CGElementDrawer.findMerge(element.merges, r: 2, c: 0)
        #expect(mV != nil)
        #expect(mV?.startRow == 1 && mV?.endRow == 2)

        // 3. 几何测量：cols, colX, rowTops
        let geom = CGElementDrawer.computeTableGeometry(element: element)
        #expect(geom.cols == 3)
        #expect(geom.colX.count == 4)
        #expect(geom.rowTops.count == 4)
        #expect(geom.colX[0] == 0)
        #expect(geom.colX[3] == 300)
        let totalH = CGElementDrawer.measureTableHeight(element: element)
        #expect(totalH >= 60)
        #expect(geom.rowTops[3] == totalH)

        // 4. 离屏绘制无崩溃且产生非空白像素
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var bytes = [UInt8](repeating: 255, count: 300 * Int(totalH) * 4)
        let ctx = CGContext(
            data: &bytes,
            width: 300,
            height: Int(totalH),
            bitsPerComponent: 8,
            bytesPerRow: 300 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        CGElementDrawer.drawElement(in: ctx, element: element, images: [:])
        let img = ctx.makeImage()!
        #expect(hasNonWhitePixel(img))
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

    // MARK: - OfficeImageLoader 视口虚拟化与按需缓存测试

    @Test("OfficeImageLoader 基础请求、异步解码与回调触发")
    func imageLoaderBasicRequestAndDecode() async throws {
        let pptxURL = samplePath("sample.pptx")
        guard FileManager.default.fileExists(atPath: pptxURL.path) else { return }

        final class CallbackTracker: @unchecked Sendable {
            var count = 0
            let lock = NSLock()
            func increment() {
                lock.lock()
                defer { lock.unlock() }
                count += 1
            }
            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
        }

        let tracker = CallbackTracker()
        let loader = OfficeImageLoader(
            filePath: pptxURL.path,
            maxTotalPixels: 10_000,
            maxCachedImages: 5,
            onImageDecoded: {
                tracker.increment()
            }
        )
        defer { loader.close() }

        let targetPart = "ppt/showcase/base/media/pixel.png"
        loader.request(visibleParts: [targetPart], prefetchParts: [])

        let deadline = Date().addingTimeInterval(3.0)
        var loadedImage: CGImage?
        while Date() < deadline {
            if let img = loader.image(for: targetPart) {
                loadedImage = img
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(loadedImage != nil)
        #expect(loadedImage?.width == 1)
        #expect(loadedImage?.height == 1)
        #expect(loader.cachedCount >= 1)
        #expect(loader.currentTotalPixels >= 1)
        #expect(loader.snapshot[targetPart] != nil)

        // 等待主线程回调派发
        let callbackDeadline = Date().addingTimeInterval(1.0)
        while Date() < callbackDeadline && tracker.value == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(tracker.value >= 1)
    }

    @Test("OfficeImageLoader 空部件与无效部件容错")
    func imageLoaderFaultTolerance() async throws {
        let pptxURL = samplePath("sample.pptx")
        guard FileManager.default.fileExists(atPath: pptxURL.path) else { return }

        let loader = OfficeImageLoader(filePath: pptxURL.path)
        defer { loader.close() }

        // 请求空部件和无效部件
        loader.request(visibleParts: ["", "ppt/media/non_existent.png"], prefetchParts: [""])

        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(loader.image(for: "") == nil)
        #expect(loader.image(for: "ppt/media/non_existent.png") == nil)
        #expect(loader.cachedCount == 0)
        #expect(loader.failedCount >= 1)

        // 验证后续有效请求仍可正常工作
        let validPart = "ppt/showcase/base/media/pixel.png"
        loader.request(visibleParts: [validPart], prefetchParts: [])
        let deadline = Date().addingTimeInterval(3.0)
        var validImg: CGImage?
        while Date() < deadline {
            if let img = loader.image(for: validPart) {
                validImg = img
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(validImg != nil)
        #expect(loader.cachedCount == 1)
    }

    @Test("OfficeImageLoader 缓存上限与 LRU 淘汰：非 wanted 图片优先淘汰且 wanted 图片受保护")
    func imageLoaderLRUEvictionAndWantedProtection() throws {
        let pptxURL = samplePath("sample.pptx")
        let loader = OfficeImageLoader(
            filePath: pptxURL.path,
            maxTotalPixels: 10_000,
            maxCachedImages: 3
        )
        defer { loader.close() }

        let imgA = createTestCGImage(width: 10, height: 10) // 100 px
        let imgB = createTestCGImage(width: 10, height: 10) // 100 px
        let imgC = createTestCGImage(width: 10, height: 10) // 100 px
        let imgD = createTestCGImage(width: 10, height: 10) // 100 px

        // 1. 模拟视口请求 A 与 B
        loader.request(visibleParts: ["imgA", "imgB"], prefetchParts: [])
        loader.insertImageForTesting(part: "imgA", image: imgA)
        loader.insertImageForTesting(part: "imgB", image: imgB)
        #expect(loader.cachedCount == 2)
        #expect(loader.currentTotalPixels == 200)

        // 2. 插入 C（未超过上限 3）
        loader.insertImageForTesting(part: "imgC", image: imgC)
        #expect(loader.cachedCount == 3)

        // 3. 访问 imgA，使其在 LRU 队列中更新为最新
        #expect(loader.image(for: "imgA") != nil)
        // 此时 accessOrder 为 [imgB, imgC, imgA]

        // 4. 用户滚动：视口变为 [imgA, imgD]，此时 imgB 和 imgC 不在 wanted 中
        loader.request(visibleParts: ["imgA", "imgD"], prefetchParts: [])

        // 5. 插入 imgD，导致缓存达到 4 张，超过 maxCachedImages: 3
        // 淘汰候选人必须是不在 wanted 中的图片，accessOrder 中排在前面的是 imgB
        loader.insertImageForTesting(part: "imgD", image: imgD)

        #expect(loader.cachedCount == 3)
        #expect(loader.image(for: "imgB") == nil, "imgB 最久未访问且不在 wanted，应当被淘汰")
        #expect(loader.image(for: "imgC") != nil, "imgC 比 imgB 新，暂不淘汰")
        #expect(loader.image(for: "imgA") != nil, "imgA 在 wanted 中，应当受保护")
        #expect(loader.image(for: "imgD") != nil, "imgD 刚插入且在 wanted 中，应当存在")

        // 6. 再次插入一张新图 imgE，此时 non-wanted 中只剩下 imgC
        let imgE = createTestCGImage(width: 10, height: 10)
        loader.insertImageForTesting(part: "imgE", image: imgE)
        #expect(loader.cachedCount == 3)
        #expect(loader.image(for: "imgC") == nil, "imgC 作为剩余的 non-wanted 最老项被淘汰")
        #expect(loader.image(for: "imgA") != nil, "imgA 依然受保护")
        #expect(loader.image(for: "imgD") != nil, "imgD 依然受保护")
    }

    @Test("OfficeImageLoader 像素预算超额淘汰与降至预算范围校验")
    func imageLoaderPixelBudgetEviction() throws {
        let pptxURL = samplePath("sample.pptx")
        // 总像素预算 250 px
        let loader = OfficeImageLoader(
            filePath: pptxURL.path,
            maxTotalPixels: 250,
            maxCachedImages: 10
        )
        defer { loader.close() }

        let small1 = createTestCGImage(width: 10, height: 10) // 100 px
        let small2 = createTestCGImage(width: 10, height: 10) // 100 px
        let big = createTestCGImage(width: 15, height: 15)    // 225 px

        // 初始视口包含 small1 和 small2
        loader.request(visibleParts: ["small1", "small2"], prefetchParts: [])
        loader.insertImageForTesting(part: "small1", image: small1)
        loader.insertImageForTesting(part: "small2", image: small2)
        #expect(loader.currentTotalPixels == 200)
        #expect(loader.cachedCount == 2)

        // 视口移动到 big，small1 和 small2 脱离视口
        loader.request(visibleParts: ["big"], prefetchParts: [])

        // 插入 big（225 px），若不淘汰总像素将达到 425 px > 250 px
        loader.insertImageForTesting(part: "big", image: big)

        // 校验淘汰后总像素必须降至预算范围内 (225 <= 250)
        #expect(loader.currentTotalPixels <= 250)
        #expect(loader.currentTotalPixels == 225)
        #expect(loader.image(for: "small1") == nil, "small1 应当已被淘汰以腾出像素预算")
        #expect(loader.image(for: "small2") == nil, "small2 应当已被淘汰以腾出像素预算")
        #expect(loader.image(for: "big") != nil, "big 作为当前视口所需图片被保留")

        // 验证保护机制：若所有图片都在 wanted 中，即使超预算也不会被 trimLocked 强行淘汰
        let extra = createTestCGImage(width: 10, height: 10) // 100 px
        loader.request(visibleParts: ["big", "extra"], prefetchParts: [])
        loader.insertImageForTesting(part: "extra", image: extra)
        #expect(loader.cachedCount == 2)
        #expect(loader.image(for: "big") != nil)
        #expect(loader.image(for: "extra") != nil)
    }

    @Test("OfficeImageLoader 关闭与并发取消安全性")
    func imageLoaderCloseAndCancellationSafety() async throws {
        let pptxURL = samplePath("sample.pptx")
        guard FileManager.default.fileExists(atPath: pptxURL.path) else { return }

        let loader = OfficeImageLoader(filePath: pptxURL.path)

        // 发起批量加载
        loader.request(
            visibleParts: [
                "ppt/showcase/base/media/pixel.png",
                "ppt/showcase/compat/media/pixel.png"
            ],
            prefetchParts: [
                "ppt/showcase/charts/media/pixel.png",
                "ppt/showcase/colors/media/pixel.png"
            ]
        )

        // 立即关闭
        loader.close()

        #expect(loader.isClosedState)
        #expect(loader.cachedCount == 0)
        #expect(loader.currentTotalPixels == 0)
        #expect(loader.snapshot.isEmpty)

        // 等待后台任何可能在跑的任务完成
        try await Task.sleep(nanoseconds: 50_000_000)

        // 关闭后读取必须返回 nil
        #expect(loader.image(for: "ppt/showcase/base/media/pixel.png") == nil)

        // 再次调用 close 幂等且安全
        loader.close()
        #expect(loader.isClosedState)

        // 关闭后调用 request 必须直接忽略
        loader.request(visibleParts: ["ppt/showcase/base/media/pixel.png"], prefetchParts: [])
        #expect(loader.currentWanted.isEmpty)
        #expect(loader.cachedCount == 0)
    }

    @Test("CGElementDrawer 字体解析与排版修饰属性（删除线、上下标、字间距、字重）")
    func fontResolutionAndTypographyAttributes() throws {
        // 1. 字体族回退与解析
        let timesFont = CGElementDrawer.resolveNSFont(face: "Times New Roman", size: 14, bold: false, italic: false)
        #expect(timesFont.familyName == "Times New Roman")

        let simsunFont = CGElementDrawer.resolveNSFont(face: "SimSun", size: 14, bold: false, italic: false)
        #expect(simsunFont.familyName == "Times New Roman" || simsunFont.familyName == "Songti SC" || simsunFont.familyName == "Georgia")

        let consolasFont = CGElementDrawer.resolveNSFont(face: "Consolas", size: 14, bold: false, italic: false)
        #expect(consolasFont.isFixedPitch || consolasFont.fontDescriptor.symbolicTraits.contains(.monoSpace))

        let kaitiFont = CGElementDrawer.resolveNSFont(face: "KaiTi", size: 14, bold: false, italic: false)
        #expect(kaitiFont.familyName == "Kaiti SC" || kaitiFont.familyName == "Comic Sans MS")

        // 2. 线程安全缓存命中（同一请求返回相同实例）
        let fontA = CGElementDrawer.resolveNSFont(face: "Times New Roman", size: 16, bold: true, italic: false, weight: 700)
        let fontB = CGElementDrawer.resolveNSFont(face: "Times New Roman", size: 16, bold: true, italic: false, weight: 700)
        #expect(fontA === fontB)

        // 3. OfficeRun 与段落属性构建（删除线、上下标、字间距、字号缩放）
        let paraJson = """
        {
            "runs": [
                {"text": "正常文本", "size": 20, "bold": true, "strike": true, "color": 4294901760},
                {"text": "上标", "size": 20, "vertAlign": "superscript"},
                {"text": "下标", "size": 20, "vertAlign": "subscript"},
                {"text": "间距文本", "size": 20, "spacing": 2.5},
                {"text": "字重文本", "size": 20, "weight": 800}
            ]
        }
        """.data(using: .utf8)!
        let para = try JSONDecoder().decode(OfficeParagraph.self, from: paraJson)
        #expect(para.runs.count == 5)
        #expect(para.runs[0].strike == true)
        #expect(para.runs[1].vertAlign == "superscript")
        #expect(para.runs[2].vertAlign == "subscript")
        #expect(para.runs[3].spacing == 2.5)
        #expect(para.runs[4].weight == 800)

        let attr = CGElementDrawer.buildAttributedString(for: para)
        let str = attr.string as NSString

        let r0 = str.range(of: "正常文本")
        #expect(r0.location != NSNotFound)
        let strikeVal = attr.attribute(.strikethroughStyle, at: r0.location, effectiveRange: nil) as? Int
        #expect(strikeVal == NSUnderlineStyle.single.rawValue)
        let strikeColor = attr.attribute(.strikethroughColor, at: r0.location, effectiveRange: nil) as? NSColor
        #expect(strikeColor != nil)

        let r1 = str.range(of: "上标")
        #expect(r1.location != NSNotFound)
        let superFont = attr.attribute(.font, at: r1.location, effectiveRange: nil) as? NSFont
        #expect(abs((superFont?.pointSize ?? 0) - 13.0) < 0.1) // 20 * 0.65 = 13.0
        let superOffset = attr.attribute(.baselineOffset, at: r1.location, effectiveRange: nil) as? CGFloat
        #expect(abs((superOffset ?? 0) - (13.0 * 0.45)) < 0.1)

        let r2 = str.range(of: "下标")
        #expect(r2.location != NSNotFound)
        let subFont = attr.attribute(.font, at: r2.location, effectiveRange: nil) as? NSFont
        #expect(abs((subFont?.pointSize ?? 0) - 13.0) < 0.1) // 20 * 0.65 = 13.0
        let subOffset = attr.attribute(.baselineOffset, at: r2.location, effectiveRange: nil) as? CGFloat
        #expect(abs((subOffset ?? 0) - (-13.0 * 0.25)) < 0.1)

        let r3 = str.range(of: "间距文本")
        #expect(r3.location != NSNotFound)
        let kernVal = attr.attribute(.kern, at: r3.location, effectiveRange: nil) as? CGFloat
        #expect(abs((kernVal ?? 0) - 2.5) < 0.01)

        let r4 = str.range(of: "字重文本")
        #expect(r4.location != NSNotFound)
        let weightFont = attr.attribute(.font, at: r4.location, effectiveRange: nil) as? NSFont
        #expect(weightFont != nil)

        // 4. OfficeCellStyle 解码与属性完整性校验
        let cellStyleJson = """
        {
            "fontSize": 14,
            "bold": true,
            "italic": false,
            "underline": true,
            "color": 4278190080,
            "fill": 0,
            "alignment": 1,
            "verticalAlignment": "CENTER",
            "wrap": false,
            "borders": [],
            "fontFace": "Consolas",
            "strike": true,
            "vertAlign": "superscript"
        }
        """.data(using: .utf8)!
        let decodedStyle = try JSONDecoder().decode(OfficeCellStyle.self, from: cellStyleJson)
        #expect(decodedStyle.fontFace == "Consolas")
        #expect(decodedStyle.strike == true)
        #expect(decodedStyle.vertAlign == "superscript")

        // 5. 缺省字段时 OfficeCellStyle 回退默认值
        let legacyStyleJson = """
        {
            "fontSize": 12,
            "bold": false,
            "italic": false,
            "underline": false,
            "color": 4278190080,
            "fill": 0,
            "alignment": 0,
            "verticalAlignment": "TOP",
            "wrap": false,
            "borders": []
        }
        """.data(using: .utf8)!
        let defaultStyle = try JSONDecoder().decode(OfficeCellStyle.self, from: legacyStyleJson)
        #expect(defaultStyle.fontFace == "")
        #expect(defaultStyle.strike == false)
        #expect(defaultStyle.vertAlign == "")

        // 6. 电子表格单元格样式包含 fontFace、strike 与 vertAlign 时绘制无崩溃且生成有效图像
        let sheetJson = """
        {
            "name": "Sheet1",
            "rowHeights": [30],
            "columnWidths": [120],
            "cells": [
                {"row": 0, "column": 0, "text": "H2O", "style": 0, "numeric": false}
            ]
        }
        """.data(using: .utf8)!
        let testSheet = try JSONDecoder().decode(OfficeSheet.self, from: sheetJson)
        let cellStyle = OfficeCellStyle(
            fontSize: 12,
            bold: false,
            italic: false,
            underline: true,
            color: 0xff000000,
            fontFace: "Times New Roman",
            strike: true,
            vertAlign: "superscript"
        )
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var bytes = [UInt8](repeating: 255, count: 200 * 100 * 4)
        let ctx = CGContext(
            data: &bytes,
            width: 200,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 200 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        CGElementDrawer.drawSpreadsheet(in: ctx, sheet: testSheet, styles: [cellStyle], viewport: CGRect(x: 0, y: 0, width: 200, height: 100))
        let img = ctx.makeImage()!
        #expect(hasNonWhitePixel(img))
    }

    @Test("段落底纹、高亮与边框解码及渲染属性校验")
    func testParagraphShadingBordersAndHighlighting() throws {
        let json = """
        {
            "schemaVersion": 9,
            "kind": "DOCX",
            "width": 595,
            "blocks": [
                {
                    "type": "TEXT",
                    "width": 500,
                    "height": 100,
                    "paragraphs": [
                        {
                            "background": 4294901760,
                            "borderTop": 4278190080,
                            "borderBottom": 4278190080,
                            "borderLeft": 4278190080,
                            "borderRight": 4278190080,
                            "borderWidth": 1.5,
                            "runs": [
                                {
                                    "text": "高亮文本",
                                    "size": 16,
                                    "color": 4278190080,
                                    "background": 4294967040
                                }
                            ]
                        }
                    ]
                }
            ]
        }
        """.data(using: .utf8)!

        let doc = try JSONDecoder().decode(OfficeDocument.self, from: json)
        #expect(doc.blocks.count == 1)
        let block = doc.blocks[0]
        #expect(block.paragraphs.count == 1)
        let para = block.paragraphs[0]
        #expect(para.background == 4294901760)
        #expect(para.borderTop == 4278190080)
        #expect(para.borderBottom == 4278190080)
        #expect(para.borderLeft == 4278190080)
        #expect(para.borderRight == 4278190080)
        #expect(para.borderWidth == 1.5)
        #expect(para.runs.count == 1)
        let run = para.runs[0]
        #expect(run.text == "高亮文本")
        #expect(run.background == 4294967040)

        // 验证 buildAttributedString 挂载了 .backgroundColor
        let attr = CGElementDrawer.buildAttributedString(for: para)
        #expect(attr.length > 0)
        let bg = attr.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(bg != nil)

        // 验证 measureParagraphsHeight 与离屏渲染
        let measuredH = CGElementDrawer.measureParagraphsHeight(block.paragraphs, availableWidth: 500, wrap: true)
        #expect(measuredH > 0)

        // 验证绘制包含段落底纹、边框和高亮
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var bytes = [UInt8](repeating: 255, count: 500 * 200 * 4)
        let ctx = CGContext(
            data: &bytes,
            width: 500,
            height: 200,
            bitsPerComponent: 8,
            bytesPerRow: 500 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        CGElementDrawer.drawElement(in: ctx, element: block, images: [:])
        let img = ctx.makeImage()!
        #expect(hasNonWhitePixel(img))
    }

    private func createTestCGImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var bytes = [UInt8](repeating: 128, count: width * height * 4)
        let ctx = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }
}
