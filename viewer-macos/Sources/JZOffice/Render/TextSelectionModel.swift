import Foundation
import CoreGraphics
import CoreText
import AppKit

/// 表示文档文本流中的具体光标/字符位置
public struct TextPosition: Comparable, Hashable, Sendable {
    public let blockIndex: Int
    /// 字符在当前 block 的 fullText 中的索引（0 ... fullText.utf16.count）
    public let charIndex: Int

    public init(blockIndex: Int, charIndex: Int) {
        self.blockIndex = blockIndex
        self.charIndex = max(0, charIndex)
    }

    public static func < (lhs: TextPosition, rhs: TextPosition) -> Bool {
        if lhs.blockIndex != rhs.blockIndex {
            return lhs.blockIndex < rhs.blockIndex
        }
        return lhs.charIndex < rhs.charIndex
    }
}

/// 选区范围（包含锚点 anchor 与浮动焦点 focus，支持正向和反向拖选）
public struct TextSelection: Equatable, Sendable {
    public let anchor: TextPosition
    public let focus: TextPosition

    public init(anchor: TextPosition, focus: TextPosition) {
        self.anchor = anchor
        self.focus = focus
    }

    public init(position: TextPosition) {
        self.anchor = position
        self.focus = position
    }

    public var isEmpty: Bool {
        return anchor == focus
    }

    public var start: TextPosition {
        return min(anchor, focus)
    }

    public var end: TextPosition {
        return max(anchor, focus)
    }

    public func contains(blockIndex: Int) -> Bool {
        return blockIndex >= start.blockIndex && blockIndex <= end.blockIndex
    }
}

/// 单行排版几何与字符映射
public struct TextLineLayout: @unchecked Sendable {
    public let ctLine: CTLine
    /// 在 Block 局部坐标系下的矩形区域
    public let rect: CGRect
    /// 绘制时的文字起始点 (lineX, baselineY)
    public let lineX: CGFloat
    public let baselineY: CGFloat
    /// 字符在 Block 的 fullText 中的范围 (location: start, length: count)
    public let charRange: NSRange
    /// 该行所属段落在 Block 的 fullText 中的基准偏移
    public let paraBaseOffset: Int
    public let ascent: CGFloat
    public let descent: CGFloat
    public let lineHeight: CGFloat
    public let alignment: Int

    public init(
        ctLine: CTLine,
        rect: CGRect,
        lineX: CGFloat,
        baselineY: CGFloat,
        charRange: NSRange,
        paraBaseOffset: Int,
        ascent: CGFloat,
        descent: CGFloat,
        lineHeight: CGFloat,
        alignment: Int
    ) {
        self.ctLine = ctLine
        self.rect = rect
        self.lineX = lineX
        self.baselineY = baselineY
        self.charRange = charRange
        self.paraBaseOffset = paraBaseOffset
        self.ascent = ascent
        self.descent = descent
        self.lineHeight = lineHeight
        self.alignment = alignment
    }
}

/// 一个文本块（例如 DOCX 中的一个正文段落块/表格单元格，或 PPTX 中的一个文本形状）
public struct TextBlockLayout: Sendable {
    public let blockIndex: Int
    /// 块在文档全局坐标系下的外接矩形
    public let bounds: CGRect
    /// 局部坐标映射到文档全局坐标的仿射变换
    public let transform: CGAffineTransform
    /// 完整拼接后的纯文本（段落之间以换行符分隔）
    public let fullText: String
    /// 内部所有排版行
    public let lines: [TextLineLayout]

    public init(
        blockIndex: Int,
        bounds: CGRect,
        transform: CGAffineTransform,
        fullText: String,
        lines: [TextLineLayout]
    ) {
        self.blockIndex = blockIndex
        self.bounds = bounds
        self.transform = transform
        self.fullText = fullText
        self.lines = lines
    }
}

/// 全文档文本空间索引与选区计算引擎
public final class DocumentTextLayout: @unchecked Sendable {
    public let blocks: [TextBlockLayout]

    public init(blocks: [TextBlockLayout]) {
        self.blocks = blocks
    }

    // MARK: - 构建空间索引

    public static func build(from document: OfficeDocument) -> DocumentTextLayout {
        var blocks: [TextBlockLayout] = []
        var blockIdx = 0

        switch document.kind {
        case .docx:
            let docW = document.width > 0 ? document.width : 595
            let marginX: CGFloat = document.marginLeft > 0 ? document.marginLeft : 24
            let marginR: CGFloat = document.marginRight > 0 ? document.marginRight : 24
            let availW = max(100, docW - marginX - marginR)
            var curY: CGFloat = document.marginTop > 0 ? document.marginTop : 24

            let allElements = document.headerBlocks + document.blocks + document.footerBlocks
            for block in allElements {
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

                if block.type == .table && !block.rows.isEmpty {
                    let tableBlocks = buildTableBlocks(element: positioned, baseIndex: blockIdx)
                    blocks.append(contentsOf: tableBlocks)
                    blockIdx += tableBlocks.count
                } else if !positioned.paragraphs.isEmpty {
                    if let layout = buildParagraphsBlock(element: positioned, blockIndex: blockIdx) {
                        blocks.append(layout)
                        blockIdx += 1
                    }
                }
                curY += elH + 8
            }

        case .pptx:
            var curY: CGFloat = 0
            for page in document.pages {
                let pH = page.height > 0 ? page.height : 405
                for el in page.elements {
                    guard !el.paragraphs.isEmpty else { continue }
                    var positioned = el
                    if positioned.transform.count >= 6 {
                        var m = positioned.transform
                        m[5] += curY
                        positioned.transform = m
                    } else {
                        positioned.y += curY
                    }
                    if let layout = buildParagraphsBlock(element: positioned, blockIndex: blockIdx) {
                        blocks.append(layout)
                        blockIdx += 1
                    }
                }
                curY += pH + 16
            }

        case .xlsx:
            // 表格暂不参与自由框选，后续可通过单元格选择扩展
            break
        }

        return DocumentTextLayout(blocks: blocks)
    }

    private static func buildParagraphsBlock(
        element: OfficeElement,
        blockIndex: Int
    ) -> TextBlockLayout? {
        guard !element.paragraphs.isEmpty else { return nil }

        let padding = max(0, element.padding)
        let availW = max(1, element.width - padding * 2)
        let wrap = element.textWrap

        var lines: [TextLineLayout] = []
        var fullTextParts: [String] = []
        var paraBaseOffset = 0

        // 1. 预先排版并收集所有段落行
        struct ParaLineData {
            let ctLine: CTLine
            let width: CGFloat
            let ascent: CGFloat
            let descent: CGFloat
            let height: CGFloat
            let alignment: Int
            let leftIndent: CGFloat
            let rightIndent: CGFloat
            let before: CGFloat
            let after: CGFloat
            let localCharRange: NSRange
            let paraBaseOffset: Int
        }
        var rawLines: [ParaLineData] = []

        for (pIdx, para) in element.paragraphs.enumerated() {
            let baseIndent = max(0, para.indent)
            let firstIndent = max(0, baseIndent + para.firstLineIndent)
            let rightIndent = max(0, para.rightIndent)

            let attrString = CGElementDrawer.buildAttributedString(for: para)
            let paraStr = attrString.string
            fullTextParts.append(paraStr)

            let totalLen = attrString.length
            guard totalLen > 0 else {
                paraBaseOffset += 1 // 空行算换行
                continue
            }

            let typesetter = CTTypesetterCreateWithAttributedString(attrString as CFAttributedString)
            var startIdx = 0
            var lineIndex = 0

            while startIdx < totalLen {
                let leftInd = lineIndex == 0 ? firstIndent : baseIndent
                let limitW = wrap ? Double(max(8, availW - leftInd - rightIndent)) : 1_000_000.0
                let count = max(1, CTTypesetterSuggestLineBreak(typesetter, startIdx, limitW))
                let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: startIdx, length: count))

                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                let w = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
                let natural = max(10, ascent + descent + max(0, leading))
                let lineH = CGElementDrawer.computeLineHeight(para: para, naturalHeight: natural)

                let isFirst = startIdx == 0
                let isLast = (startIdx + count) >= totalLen

                rawLines.append(ParaLineData(
                    ctLine: ctLine,
                    width: w,
                    ascent: ascent,
                    descent: descent,
                    height: lineH,
                    alignment: para.alignment,
                    leftIndent: leftInd,
                    rightIndent: rightIndent,
                    before: isFirst ? max(0, para.before) : 0,
                    after: isLast ? max(0, para.after) : 0,
                    localCharRange: NSRange(location: startIdx, length: count),
                    paraBaseOffset: paraBaseOffset
                ))

                startIdx += count
                lineIndex += 1
            }

            paraBaseOffset += totalLen
            if pIdx < element.paragraphs.count - 1 {
                paraBaseOffset += 1 // 换行符
            }
        }

        guard !rawLines.isEmpty else { return nil }

        // 2. 纵向对齐计算
        let totalH = rawLines.reduce(0) { $0 + $1.before + $1.height + $1.after }
        var offsetY = padding
        let remaining = max(0, element.height - padding * 2 - totalH)
        switch element.verticalAlignment {
        case .center:
            offsetY += remaining / 2
        case .bottom:
            offsetY += remaining
        case .top:
            break
        }

        var curY = offsetY
        for raw in rawLines {
            curY += raw.before
            let lineAvailW = max(1, availW - raw.leftIndent - raw.rightIndent)
            var lineX = padding + raw.leftIndent
            if raw.alignment == 1 {
                lineX += (lineAvailW - raw.width) / 2.0
            } else if raw.alignment == 2 {
                lineX += lineAvailW - raw.width
            }
            let baselineY = curY + raw.ascent + max(0, (raw.height - (raw.ascent + raw.descent)) / 2.0)
            let lineRect = CGRect(x: lineX, y: curY, width: max(1, raw.width), height: raw.height)
            let globalCharRange = NSRange(
                location: raw.paraBaseOffset + raw.localCharRange.location,
                length: raw.localCharRange.length
            )

            lines.append(TextLineLayout(
                ctLine: raw.ctLine,
                rect: lineRect,
                lineX: lineX,
                baselineY: baselineY,
                charRange: globalCharRange,
                paraBaseOffset: raw.paraBaseOffset,
                ascent: raw.ascent,
                descent: raw.descent,
                lineHeight: raw.height,
                alignment: raw.alignment
            ))

            curY += raw.height + raw.after
        }

        let affine: CGAffineTransform
        if element.transform.count >= 6 {
            let m = element.transform
            affine = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
        } else {
            affine = CGAffineTransform(translationX: element.x, y: element.y)
        }

        let localBounds = CGRect(x: 0, y: 0, width: max(1, element.width), height: max(1, element.height))
        let docBounds = localBounds.applying(affine)
        let joinedText = fullTextParts.joined(separator: "\n")

        return TextBlockLayout(
            blockIndex: blockIndex,
            bounds: docBounds,
            transform: affine,
            fullText: joinedText,
            lines: lines
        )
    }

    private static func buildTableBlocks(
        element: OfficeElement,
        baseIndex: Int
    ) -> [TextBlockLayout] {
        let rows = element.rows
        var cols = 0
        for r in rows { cols = max(cols, r.count) }
        guard cols > 0 else { return [] }

        let colWidths = CGElementDrawer.resolveColumnWidths(element: element, cols: cols)
        var result: [TextBlockLayout] = []
        var curIdx = baseIndex
        var currentY: CGFloat = 0

        let tableAffine: CGAffineTransform
        if element.transform.count >= 6 {
            let m = element.transform
            tableAffine = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
        } else {
            tableAffine = CGAffineTransform(translationX: element.x, y: element.y)
        }

        for row in rows {
            var rowHeight: CGFloat = 20
            var cellLinesList: [[TextLineLayout]] = []
            var cellTexts: [String] = []

            for c in 0..<cols {
                let colW = colWidths[c]
                let cellParas = c < row.count ? row[c] : []
                if cellParas.isEmpty {
                    cellLinesList.append([])
                    cellTexts.append("")
                    continue
                }
                var dummyEl = element
                dummyEl.paragraphs = cellParas
                dummyEl.padding = 4
                dummyEl.width = max(1, colW - 10)
                dummyEl.height = 0
                dummyEl.transform = [1, 0, 0, 1, 0, 0]
                dummyEl.textWrap = true

                if let blk = buildParagraphsBlock(element: dummyEl, blockIndex: curIdx) {
                    cellLinesList.append(blk.lines)
                    cellTexts.append(blk.fullText)
                    let textH = blk.lines.reduce(0) { max($0, $1.rect.maxY) }
                    rowHeight = max(rowHeight, textH + 10)
                } else {
                    cellLinesList.append([])
                    cellTexts.append("")
                }
            }

            var currentX: CGFloat = 0
            for c in 0..<cols {
                let colW = colWidths[c]
                let rawLines = cellLinesList[c]
                let text = cellTexts[c]
                if !rawLines.isEmpty {
                    let cellLocalOrigin = CGPoint(x: currentX + 5, y: currentY + 5)
                    let cellTransform = tableAffine.concatenating(
                        CGAffineTransform(translationX: cellLocalOrigin.x, y: cellLocalOrigin.y)
                    )
                    let cellRect = CGRect(x: 0, y: 0, width: max(1, colW - 10), height: rowHeight - 10)
                    let docBounds = cellRect.applying(cellTransform)

                    result.append(TextBlockLayout(
                        blockIndex: curIdx,
                        bounds: docBounds,
                        transform: cellTransform,
                        fullText: text,
                        lines: rawLines
                    ))
                    curIdx += 1
                }
                currentX += colW
            }
            currentY += rowHeight
        }

        return result
    }

    // MARK: - 命中测试 (Hit Testing)

    /// 将文档全局坐标点转换为最贴近的文本字符位置
    public func hitTest(docPoint: CGPoint) -> TextPosition? {
        guard !blocks.isEmpty else { return nil }

        // 1. 查找包含或距离该点最近的 TextBlock
        var bestBlock: TextBlockLayout?
        var minDistance: CGFloat = .greatestFiniteMagnitude

        for block in blocks {
            let inv = block.transform.inverted()
            let localPoint = docPoint.applying(inv)

            let localBounds = CGRect(
                origin: .zero,
                size: CGSize(
                    width: block.lines.map { $0.rect.maxX }.max() ?? 100,
                    height: block.lines.map { $0.rect.maxY }.max() ?? 20
                )
            )

            if localBounds.insetBy(dx: -8, dy: -4).contains(localPoint) {
                bestBlock = block
                break
            }

            let dist = distanceToRect(point: docPoint, rect: block.bounds)
            if dist < minDistance {
                minDistance = dist
                bestBlock = block
            }
        }

        guard let block = bestBlock, !block.lines.isEmpty else { return nil }

        let inv = block.transform.inverted()
        let localPoint = docPoint.applying(inv)

        // 2. 在 Block 内部查找纵向最贴近的 Line
        var bestLine = block.lines[0]
        var minLineDist: CGFloat = .greatestFiniteMagnitude

        for line in block.lines {
            if localPoint.y >= line.rect.minY && localPoint.y <= line.rect.maxY {
                bestLine = line
                minLineDist = 0
                break
            }
            let dist = abs(localPoint.y - line.rect.midY)
            if dist < minLineDist {
                minLineDist = dist
                bestLine = line
            }
        }

        // 3. 利用 CoreText 命中行内精确字符
        let relativeX = localPoint.x - bestLine.lineX
        let attrCharIndex = CTLineGetStringIndexForPosition(bestLine.ctLine, CGPoint(x: relativeX, y: 0))

        let globalCharIndex = bestLine.paraBaseOffset + attrCharIndex
        let clampedCharIndex = max(
            bestLine.charRange.location,
            min(bestLine.charRange.location + bestLine.charRange.length, globalCharIndex)
        )

        return TextPosition(blockIndex: block.blockIndex, charIndex: clampedCharIndex)
    }

    private func distanceToRect(point: CGPoint, rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return sqrt(dx * dx + dy * dy)
    }

    // MARK: - 选区高亮矩形计算

    /// 计算选区在文档全局坐标系下的所有高亮矩形列表
    public func selectionRects(for selection: TextSelection) -> [CGRect] {
        guard !selection.isEmpty else { return [] }
        var result: [CGRect] = []

        let start = selection.start
        let end = selection.end

        for block in blocks where block.blockIndex >= start.blockIndex && block.blockIndex <= end.blockIndex {
            let startChar = (block.blockIndex == start.blockIndex) ? start.charIndex : 0
            let endChar = (block.blockIndex == end.blockIndex) ? end.charIndex : (block.fullText as NSString).length

            guard startChar < endChar else { continue }

            for line in block.lines {
                let lineStart = line.charRange.location
                let lineEnd = line.charRange.location + line.charRange.length

                let selStart = max(startChar, lineStart)
                let selEnd = min(endChar, lineEnd)

                guard selStart < selEnd else { continue }

                // 转换到 attrString 的局部索引
                let localStart = selStart - line.paraBaseOffset
                let localEnd = selEnd - line.paraBaseOffset

                let x1 = CTLineGetOffsetForStringIndex(line.ctLine, localStart, nil)
                let x2 = CTLineGetOffsetForStringIndex(line.ctLine, localEnd, nil)

                let highlightLocal = CGRect(
                    x: line.lineX + min(x1, x2),
                    y: line.rect.minY,
                    width: max(1.5, abs(x2 - x1)),
                    height: line.lineHeight
                )

                let highlightDoc = highlightLocal.applying(block.transform)
                result.append(highlightDoc)
            }
        }

        return result
    }

    // MARK: - 提取选区纯文本

    /// 提取选区覆盖的所有纯文本（跨段落与跨块以换行符连接）
    public func selectedText(for selection: TextSelection) -> String {
        guard !selection.isEmpty else { return "" }
        var parts: [String] = []

        let start = selection.start
        let end = selection.end

        for block in blocks where block.blockIndex >= start.blockIndex && block.blockIndex <= end.blockIndex {
            let ns = block.fullText as NSString
            guard ns.length > 0 else { continue }

            let startChar = max(0, min(ns.length, block.blockIndex == start.blockIndex ? start.charIndex : 0))
            let endChar = max(startChar, min(ns.length, block.blockIndex == end.blockIndex ? end.charIndex : ns.length))

            if startChar < endChar {
                let sub = ns.substring(with: NSRange(location: startChar, length: endChar - startChar))
                parts.append(sub)
            }
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - 双击选词与三击选行

    /// 根据当前光标位置计算单词边界
    public func wordRange(at position: TextPosition) -> TextSelection? {
        guard let block = blocks.first(where: { $0.blockIndex == position.blockIndex }) else { return nil }
        let text = block.fullText
        guard !text.isEmpty else { return nil }

        let cfStr = text as CFString
        let totalLen = CFStringGetLength(cfStr)
        let targetIdx = min(position.charIndex, max(0, totalLen - 1))

        guard let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            cfStr,
            CFRange(location: 0, length: totalLen),
            kCFStringTokenizerUnitWordBoundary,
            CFLocaleCopyCurrent()
        ) else { return nil }

        _ = CFStringTokenizerGoToTokenAtIndex(tokenizer, targetIdx)
        let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)

        if tokenRange.location != kCFNotFound && tokenRange.length > 0 {
            return TextSelection(
                anchor: TextPosition(blockIndex: block.blockIndex, charIndex: tokenRange.location),
                focus: TextPosition(blockIndex: block.blockIndex, charIndex: tokenRange.location + tokenRange.length)
            )
        }

        return nil
    }

    /// 根据当前光标位置计算整行边界
    public func lineRange(at position: TextPosition) -> TextSelection? {
        guard let block = blocks.first(where: { $0.blockIndex == position.blockIndex }) else { return nil }
        for line in block.lines {
            let lineStart = line.charRange.location
            let lineEnd = line.charRange.location + line.charRange.length
            if position.charIndex >= lineStart && position.charIndex <= lineEnd {
                return TextSelection(
                    anchor: TextPosition(blockIndex: block.blockIndex, charIndex: lineStart),
                    focus: TextPosition(blockIndex: block.blockIndex, charIndex: lineEnd)
                )
            }
        }
        return nil
    }

    /// 全选范围
    public func allTextRange() -> TextSelection? {
        guard let first = blocks.first, let last = blocks.last else { return nil }
        let lastLen = (last.fullText as NSString).length
        return TextSelection(
            anchor: TextPosition(blockIndex: first.blockIndex, charIndex: 0),
            focus: TextPosition(blockIndex: last.blockIndex, charIndex: lastLen)
        )
    }
}
