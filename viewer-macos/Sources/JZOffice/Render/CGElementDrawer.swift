import Foundation
import CoreGraphics
import CoreText
import AppKit

/// CoreGraphics + CoreText 统一文档元素绘制器
/// 假定输入 `CGContext` 已转换为左上角原点（Y 轴向下，与 Android Canvas 和鸿蒙 Canvas 2D 坐标系严格一致）
public enum CGElementDrawer {

    public static func argbToCGColor(_ argb: UInt32) -> CGColor? {
        let a = CGFloat((argb >> 24) & 0xff) / 255.0
        guard a > 0.001 else { return nil }
        let r = CGFloat((argb >> 16) & 0xff) / 255.0
        let g = CGFloat((argb >> 8) & 0xff) / 255.0
        let b = CGFloat(argb & 0xff) / 255.0
        return CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    public static func argbToNSColor(_ argb: UInt32, fallback: NSColor = .textColor) -> NSColor {
        let a = CGFloat((argb >> 24) & 0xff) / 255.0
        guard a > 0.001 else { return fallback }
        let r = CGFloat((argb >> 16) & 0xff) / 255.0
        let g = CGFloat((argb >> 8) & 0xff) / 255.0
        let b = CGFloat(argb & 0xff) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    public static func drawElement(
        in ctx: CGContext,
        element: OfficeElement,
        images: [String: CGImage]
    ) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // 1. 应用 2D 仿射变换矩阵 [a, b, c, d, e, f]
        if element.transform.count >= 6 {
            let m = element.transform
            let affine = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
            ctx.concatenate(affine)
        } else if element.x != 0 || element.y != 0 {
            ctx.translateBy(x: element.x, y: element.y)
        }

        let w = element.width
        let h = element.height
        let rect = CGRect(x: 0, y: 0, width: max(0, w), height: max(0, h))
        let fillColor = argbToCGColor(element.fill)
        let strokeColor = argbToCGColor(element.stroke)

        // 2. 绘制 PATH 矢量路径
        if element.type == .path && !element.paths.isEmpty {
            for p in element.paths {
                guard !p.commands.isEmpty else { continue }
                let cgPath = buildCGPath(from: p.commands)
                if p.fill {
                    if let grad = element.fillGradient, grad.colors.count >= 2 {
                        ctx.saveGState()
                        ctx.addPath(cgPath)
                        ctx.clip()
                        drawLinearGradient(in: ctx, gradient: grad)
                        ctx.restoreGState()
                    } else if let fillColor {
                        ctx.setFillColor(fillColor)
                        ctx.addPath(cgPath)
                        ctx.fillPath()
                    }
                }
                if p.stroke, let strokeColor {
                    ctx.setStrokeColor(strokeColor)
                    ctx.setLineWidth(max(0.5, element.strokeWidth))
                    ctx.addPath(cgPath)
                    ctx.strokePath()
                }
            }
        } else {
            // 3. 基础几何图形 (RECT / ELLIPSE / LINE)
            if element.type != .line {
                if let grad = element.fillGradient, grad.colors.count >= 2 {
                    ctx.saveGState()
                    if element.type == .ellipse {
                        ctx.addEllipse(in: rect)
                    } else {
                        ctx.addRect(rect)
                    }
                    ctx.clip()
                    drawLinearGradient(in: ctx, gradient: grad)
                    ctx.restoreGState()
                } else if let fillColor {
                    ctx.setFillColor(fillColor)
                    if element.type == .ellipse {
                        ctx.fillEllipse(in: rect)
                    } else {
                        ctx.fill(rect)
                    }
                }
            }

            if let strokeColor {
                ctx.setStrokeColor(strokeColor)
                ctx.setLineWidth(max(0.5, element.strokeWidth))
                if element.type == .ellipse {
                    ctx.strokeEllipse(in: rect)
                } else if element.type == .line {
                    ctx.move(to: .zero)
                    ctx.addLine(to: CGPoint(x: w, y: h))
                    ctx.strokePath()
                } else if element.stroke != 0 {
                    ctx.stroke(rect)
                }
            }
        }

        // 4. 绘制内嵌图片 (IMAGE)
        if element.type == .image {
            ctx.saveGState()
            if w > 0 && h > 0 {
                ctx.clip(to: rect)
            }
            if let part = element.image, let cgImage = images[part] {
                let targetRect: CGRect
                if let ib = element.imageBounds, ib.count >= 4 {
                    targetRect = CGRect(x: ib[0], y: ib[1], width: ib[2] - ib[0], height: ib[3] - ib[1])
                } else {
                    targetRect = rect
                }
                drawCGImageTopDown(in: ctx, image: cgImage, rect: targetRect)
            } else {
                if let placeholder = argbToCGColor(0xffe8eaed) {
                    ctx.setFillColor(placeholder)
                    ctx.fill(rect)
                }
            }
            ctx.restoreGState()
        }

        // 5. 绘制表格 (TABLE)
        if element.type == .table && !element.rows.isEmpty {
            drawTable(in: ctx, element: element)
        }

        // 6. 绘制段落文本 (TEXT 或形状内文字)
        if !element.paragraphs.isEmpty {
            drawParagraphs(in: ctx, element: element)
        }
    }

    private static func drawCGImageTopDown(in ctx: CGContext, image: CGImage, rect: CGRect) {
        guard rect.width > 0 && rect.height > 0 else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    private static func buildCGPath(from commands: [OfficePathCommand]) -> CGPath {
        let path = CGMutablePath()
        for cmd in commands {
            let pts = cmd.points
            switch cmd.op {
            case .move:
                if pts.count >= 2 {
                    path.move(to: CGPoint(x: pts[0], y: pts[1]))
                }
            case .line:
                if pts.count >= 2 {
                    path.addLine(to: CGPoint(x: pts[0], y: pts[1]))
                }
            case .quad:
                if pts.count >= 4 {
                    path.addQuadCurve(
                        to: CGPoint(x: pts[2], y: pts[3]),
                        control: CGPoint(x: pts[0], y: pts[1])
                    )
                }
            case .cubic:
                if pts.count >= 6 {
                    path.addCurve(
                        to: CGPoint(x: pts[4], y: pts[5]),
                        control1: CGPoint(x: pts[0], y: pts[1]),
                        control2: CGPoint(x: pts[2], y: pts[3])
                    )
                }
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }

    private static func drawLinearGradient(in ctx: CGContext, gradient g: OfficeGradientFill) {
        guard g.points.count >= 4, g.colors.count >= 2 else { return }
        var x0 = g.points[0]
        var y0 = g.points[1]
        var x1 = g.points[2]
        var y1 = g.points[3]
        if let m = g.transform, m.count >= 6 {
            let nx0 = m[0] * x0 + m[2] * y0 + m[4]
            let ny0 = m[1] * x0 + m[3] * y0 + m[5]
            let nx1 = m[0] * x1 + m[2] * y1 + m[4]
            let ny1 = m[1] * x1 + m[3] * y1 + m[5]
            x0 = nx0; y0 = ny0; x1 = nx1; y1 = ny1
        }
        let cgColors: [CGColor] = g.colors.map {
            argbToCGColor($0) ?? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        }
        var locations: [CGFloat] = g.positions.enumerated().map { idx, pos in
            min(1.0, max(0.0, pos))
        }
        while locations.count < cgColors.count {
            locations.append(1.0)
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cgGrad = CGGradient(
                  colorsSpace: space,
                  colors: cgColors as CFArray,
                  locations: locations
              ) else { return }
        ctx.drawLinearGradient(
            cgGrad,
            start: CGPoint(x: x0, y: y0),
            end: CGPoint(x: x1, y: y1),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    // MARK: - 表格测量与绘制

    public static func measureTableHeight(element: OfficeElement) -> CGFloat {
        let rows = element.rows
        var cols = 0
        for r in rows { cols = max(cols, r.count) }
        guard cols > 0 else { return 0 }

        let colWidths = resolveColumnWidths(element: element, cols: cols)
        var totalY: CGFloat = 0
        for row in rows {
            var rowHeight: CGFloat = 20
            for c in 0..<cols {
                let colW = colWidths[c]
                let cellParas = c < row.count ? row[c] : []
                if !cellParas.isEmpty {
                    let h = measureParagraphsHeight(cellParas, availableWidth: max(1, colW - 10), wrap: true)
                    rowHeight = max(rowHeight, h + 10)
                }
            }
            totalY += rowHeight
        }
        return totalY
    }

    public static func resolveColumnWidths(element: OfficeElement, cols: Int) -> [CGFloat] {
        let raw = element.columnWidths
        let totalWeight = raw.reduce(0) { $0 + max(1, $1) }
        let tableW = element.width > 0 ? element.width : 500
        return (0..<cols).map { c in
            if raw.count == cols && totalWeight > 0 {
                if abs(totalWeight - tableW) < 0.5 {
                    return max(1, raw[c])
                }
                return (tableW * max(1, raw[c])) / totalWeight
            }
            return tableW / CGFloat(cols)
        }
    }

    private static func drawTable(in ctx: CGContext, element: OfficeElement) {
        let rows = element.rows
        var cols = 0
        for r in rows { cols = max(cols, r.count) }
        guard cols > 0 else { return }

        let colWidths = resolveColumnWidths(element: element, cols: cols)
        let borderColor = argbToCGColor(0xffb7bec7)
        var currentY: CGFloat = 0

        for (rIdx, row) in rows.enumerated() {
            var rowHeight: CGFloat = 20
            var cellLayouts: [[LaidOutLine]] = []
            for c in 0..<cols {
                let colW = colWidths[c]
                let cellParas = c < row.count ? row[c] : []
                let lines = layoutParagraphs(cellParas, availableWidth: max(1, colW - 10), wrap: true)
                cellLayouts.append(lines)
                let textH = lines.reduce(0) { $0 + $1.before + $1.height + $1.after }
                if !cellParas.isEmpty {
                    rowHeight = max(rowHeight, textH + 10)
                }
            }

            var currentX: CGFloat = 0
            for c in 0..<cols {
                let colW = colWidths[c]
                let cellRect = CGRect(x: currentX, y: currentY, width: colW, height: rowHeight)
                if rIdx < element.cellFills.count && c < element.cellFills[rIdx].count {
                    if let fillCG = argbToCGColor(element.cellFills[rIdx][c]) {
                        ctx.setFillColor(fillCG)
                        ctx.fill(cellRect)
                    }
                }
                if let borderColor {
                    ctx.setStrokeColor(borderColor)
                    ctx.setLineWidth(0.6)
                    ctx.stroke(cellRect)
                }

                let lines = cellLayouts[c]
                if !lines.isEmpty {
                    ctx.saveGState()
                    ctx.clip(to: cellRect)
                    drawLaidOutLines(
                        in: ctx,
                        lines: lines,
                        originX: currentX + 5,
                        originY: currentY + 5,
                        availableWidth: max(1, colW - 10)
                    )
                    ctx.restoreGState()
                }
                currentX += colW
            }
            currentY += rowHeight
        }
    }

    // MARK: - CoreText 段落排版与绘制

    private struct LaidOutLine {
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
    }

    public static func measureParagraphsHeight(
        _ paragraphs: [OfficeParagraph],
        availableWidth: CGFloat,
        wrap: Bool
    ) -> CGFloat {
        let lines = layoutParagraphs(paragraphs, availableWidth: availableWidth, wrap: wrap)
        return lines.reduce(0) { $0 + $1.before + $1.height + $1.after }
    }

    private static func drawParagraphs(in ctx: CGContext, element: OfficeElement) {
        let padding = max(0, element.padding)
        let availW = max(1, element.width - padding * 2)
        let wrap = element.textWrap
        let lines = layoutParagraphs(element.paragraphs, availableWidth: availW, wrap: wrap)
        guard !lines.isEmpty else { return }

        let totalH = lines.reduce(0) { $0 + $1.before + $1.height + $1.after }
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

        ctx.saveGState()
        if wrap && element.width > 0 && element.height > 0 {
            ctx.clip(to: CGRect(x: 0, y: 0, width: element.width, height: element.height))
        }
        drawLaidOutLines(in: ctx, lines: lines, originX: padding, originY: offsetY, availableWidth: availW)
        ctx.restoreGState()
    }

    private static func drawLaidOutLines(
        in ctx: CGContext,
        lines: [LaidOutLine],
        originX: CGFloat,
        originY: CGFloat,
        availableWidth: CGFloat
    ) {
        var curY = originY
        ctx.saveGState()
        // CoreText 在翻转后的左上角坐标系中需要将 textMatrix 的 Y 轴取反，否则字形会上下颠倒
        ctx.textMatrix = CGAffineTransform(scaleX: 1.0, y: -1.0)
        for line in lines {
            curY += line.before
            let lineAvailW = max(1, availableWidth - line.leftIndent - line.rightIndent)
            var lineX = originX + line.leftIndent
            if line.alignment == 1 {
                lineX += (lineAvailW - line.width) / 2.0
            } else if line.alignment == 2 {
                lineX += lineAvailW - line.width
            }
            let baselineY = curY + line.ascent + max(0, (line.height - (line.ascent + line.descent)) / 2.0)
            ctx.textPosition = CGPoint(x: lineX, y: baselineY)
            if line.alignment == 3, let justified = CTLineCreateJustifiedLine(line.ctLine, 1.0, Double(lineAvailW)) {
                CTLineDraw(justified, ctx)
            } else {
                CTLineDraw(line.ctLine, ctx)
            }
            curY += line.height + line.after
        }
        ctx.restoreGState()
    }

    private static func layoutParagraphs(
        _ paragraphs: [OfficeParagraph],
        availableWidth: CGFloat,
        wrap: Bool
    ) -> [LaidOutLine] {
        var result: [LaidOutLine] = []
        for para in paragraphs {
            let baseIndent = max(0, para.indent)
            let firstIndent = max(0, baseIndent + para.firstLineIndent)
            let rightIndent = max(0, para.rightIndent)

            let attrString = buildAttributedString(for: para)
            guard attrString.length > 0 else {
                let defaultSize = para.runs.first?.size ?? 12
                let emptyLine = CTLineCreateWithAttributedString(NSAttributedString(string: " "))
                let h = computeLineHeight(para: para, naturalHeight: defaultSize * 1.2)
                result.append(LaidOutLine(
                    ctLine: emptyLine,
                    width: 0,
                    ascent: defaultSize * 0.8,
                    descent: defaultSize * 0.2,
                    height: h,
                    alignment: para.alignment,
                    leftIndent: firstIndent,
                    rightIndent: rightIndent,
                    before: max(0, para.before),
                    after: max(0, para.after)
                ))
                continue
            }

            let typesetter = CTTypesetterCreateWithAttributedString(attrString as CFAttributedString)
            let totalLen = attrString.length
            var startIdx = 0
            var lineIndex = 0

            while startIdx < totalLen {
                let leftInd = lineIndex == 0 ? firstIndent : baseIndent
                let limitW = wrap ? Double(max(8, availableWidth - leftInd - rightIndent)) : 1_000_000.0
                let count = max(1, CTTypesetterSuggestLineBreak(typesetter, startIdx, limitW))
                let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: startIdx, length: count))

                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                let w = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
                let natural = max(10, ascent + descent + max(0, leading))
                let lineH = computeLineHeight(para: para, naturalHeight: natural)

                let isFirst = startIdx == 0
                let isLast = (startIdx + count) >= totalLen
                result.append(LaidOutLine(
                    ctLine: ctLine,
                    width: w,
                    ascent: ascent,
                    descent: descent,
                    height: lineH,
                    alignment: para.alignment,
                    leftIndent: leftInd,
                    rightIndent: rightIndent,
                    before: isFirst ? max(0, para.before) : 0,
                    after: isLast ? max(0, para.after) : 0
                ))
                startIdx += count
                lineIndex += 1
            }
        }
        return result
    }

    public static func buildAttributedString(for para: OfficeParagraph) -> NSMutableAttributedString {
        let attr = NSMutableAttributedString()
        var allRuns: [OfficeRun] = []
        if !para.bullet.isEmpty {
            let first = para.runs.first
            allRuns.append(OfficeRun(
                text: para.bullet,
                fontFace: first?.fontFace ?? "",
                size: first?.size ?? 12,
                bold: first?.bold ?? false,
                italic: first?.italic ?? false,
                underline: false,
                color: first?.color ?? 0xff202124
            ))
        }
        allRuns.append(contentsOf: para.runs.filter { !$0.text.isEmpty })

        for run in allRuns {
            let fontSize = max(1, run.size)
            let font = resolveNSFont(face: run.fontFace, size: fontSize, bold: run.bold, italic: run.italic)
            let color = argbToNSColor(run.color)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color
            ]
            if run.underline {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = color
            }
            attr.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return attr
    }

    public static func resolveNSFont(face: String, size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        let trimmed = face.trimmingCharacters(in: .whitespacesAndNewlines)
        var effectiveBold = bold
        let lower = trimmed.lowercased()
        if lower.contains("impact") || lower.contains("black") || lower.contains("heavy") {
            effectiveBold = true
        }
        var font: NSFont?
        if !trimmed.isEmpty {
            font = NSFont(name: trimmed, size: size)
            if font == nil && (lower.contains("song") || lower.contains("宋体") || lower.contains("mincho")) {
                font = NSFont(name: "Songti SC", size: size)
            } else if font == nil && (lower.contains("hei") || lower.contains("黑体") || lower.contains("yahei") || lower.contains("雅黑")) {
                font = NSFont(name: "PingFang SC", size: size)
            } else if font == nil && (lower.contains("kai") || lower.contains("楷体")) {
                font = NSFont(name: "Kaiti SC", size: size)
            } else if font == nil && (lower.contains("mono") || lower.contains("consolas") || lower.contains("courier")) {
                font = NSFont.monospacedSystemFont(ofSize: size, weight: effectiveBold ? .bold : .regular)
            }
        }
        var resolved = font ?? NSFont.systemFont(ofSize: size, weight: effectiveBold ? .bold : .regular)
        var traits: NSFontTraitMask = []
        if effectiveBold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        if !traits.isEmpty {
            resolved = NSFontManager.shared.convert(resolved, toHaveTrait: traits)
        }
        return resolved
    }

    public static func computeLineHeight(para: OfficeParagraph, naturalHeight: CGFloat) -> CGFloat {
        switch para.lineSpacingRule {
        case .exact:
            return max(1, para.lineSpacing > 0 ? para.lineSpacing : naturalHeight)
        case .atLeast:
            return max(naturalHeight, para.lineSpacing > 0 ? para.lineSpacing : naturalHeight)
        case .auto:
            let factor = para.lineSpacing > 0 ? para.lineSpacing : 1.0
            return max(1, naturalHeight * factor)
        }
    }

    // MARK: - XLSX 电子表格绘制（复用 Rust SheetGeometry 预计算偏移与合并区域）

    public static let sheetHeaderWidth: CGFloat = 42
    public static let sheetHeaderHeight: CGFloat = 22

    public static func computeSheetExtents(_ sheet: OfficeSheet) -> (colOffsets: [CGFloat], rowOffsets: [CGFloat], totalWidth: CGFloat, totalHeight: CGFloat) {
        if let g = sheet.geometry,
           g.columnOffsets.count == sheet.columnWidths.count + 1,
           g.rowOffsets.count == sheet.rowHeights.count + 1 {
            let colOff = g.columnOffsets.map { $0 + sheetHeaderWidth }
            let rowOff = g.rowOffsets.map { $0 + sheetHeaderHeight }
            return (colOff, rowOff, colOff.last ?? sheetHeaderWidth, rowOff.last ?? sheetHeaderHeight)
        }
        var colOff: [CGFloat] = [sheetHeaderWidth]
        for w in sheet.columnWidths {
            colOff.append((colOff.last ?? sheetHeaderWidth) + max(0, w))
        }
        var rowOff: [CGFloat] = [sheetHeaderHeight]
        for h in sheet.rowHeights {
            rowOff.append((rowOff.last ?? sheetHeaderHeight) + max(0, h))
        }
        return (colOff, rowOff, colOff.last ?? sheetHeaderWidth, rowOff.last ?? sheetHeaderHeight)
    }

    public static func drawSpreadsheet(
        in ctx: CGContext,
        sheet: OfficeSheet,
        styles: [OfficeCellStyle],
        viewport: CGRect
    ) {
        let (colOffsets, rowOffsets, totalW, totalH) = computeSheetExtents(sheet)
        let drawW = min(totalW, viewport.maxX)
        let drawH = min(totalH, viewport.maxY)

        ctx.saveGState()
        defer { ctx.restoreGState() }

        // 背景
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(viewport)

        let mergedCellFlags = sheet.geometry?.mergedCells ?? []

        // 1. 绘制普通单元格背景与文本
        for (idx, cell) in sheet.cells.enumerated() {
            if idx < mergedCellFlags.count && mergedCellFlags[idx] {
                continue
            }
            guard cell.row >= 0, cell.row + 1 < rowOffsets.count,
                  cell.column >= 0, cell.column + 1 < colOffsets.count else { continue }
            let left = colOffsets[cell.column]
            let top = rowOffsets[cell.row]
            let right = colOffsets[cell.column + 1]
            let bottom = rowOffsets[cell.row + 1]
            if right < viewport.minX || left > viewport.maxX || bottom < viewport.minY || top > viewport.maxY {
                continue
            }
            let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            guard rect.width > 0 && rect.height > 0 else { continue }
            drawSpreadsheetCell(in: ctx, cell: cell, rect: rect, styles: styles)
        }

        // 2. 绘制网格线
        if let gridColor = argbToCGColor(0xffdce1e5) {
            ctx.setStrokeColor(gridColor)
            ctx.setLineWidth(0.5)
            for x in colOffsets where x >= viewport.minX && x <= drawW {
                ctx.move(to: CGPoint(x: x, y: max(sheetHeaderHeight, viewport.minY)))
                ctx.addLine(to: CGPoint(x: x, y: drawH))
            }
            for y in rowOffsets where y >= viewport.minY && y <= drawH {
                ctx.move(to: CGPoint(x: max(sheetHeaderWidth, viewport.minX), y: y))
                ctx.addLine(to: CGPoint(x: drawW, y: y))
            }
            ctx.strokePath()
        }

        // 3. 绘制合并单元格（覆盖内部网格线）
        if let g = sheet.geometry {
            for merge in g.mergeRects {
                let rect = CGRect(
                    x: merge.left + sheetHeaderWidth,
                    y: merge.top + sheetHeaderHeight,
                    width: merge.right - merge.left,
                    height: merge.bottom - merge.top
                )
                guard rect.width > 0, rect.height > 0, rect.intersects(viewport) else { continue }
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(rect)
                if merge.anchor >= 0 && merge.anchor < sheet.cells.count {
                    drawSpreadsheetCell(in: ctx, cell: sheet.cells[merge.anchor], rect: rect, styles: styles)
                }
                if let gridColor = argbToCGColor(0xffdce1e5) {
                    ctx.setStrokeColor(gridColor)
                    ctx.setLineWidth(0.5)
                    ctx.stroke(rect)
                }
            }
        }

        // 4. 绘制行列标头 (Row / Column Headers)
        if let headerBg = argbToCGColor(0xfff3f5f7) {
            ctx.setFillColor(headerBg)
            ctx.fill(CGRect(x: viewport.minX, y: viewport.minY, width: viewport.width, height: sheetHeaderHeight))
            ctx.fill(CGRect(x: viewport.minX, y: viewport.minY, width: sheetHeaderWidth, height: viewport.height))
        }
        let headerFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let headerColor = argbToNSColor(0xff52606d)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1.0, y: -1.0)
        for c in 0..<sheet.columnWidths.count {
            let left = colOffsets[c]
            let w = colOffsets[c + 1] - left
            if w <= 0 || left > drawW { continue }
            let label = columnLabel(for: c)
            drawCenteredSingleLine(in: ctx, text: label, font: headerFont, color: headerColor, rect: CGRect(x: left, y: viewport.minY, width: w, height: sheetHeaderHeight))
        }
        for r in 0..<sheet.rowHeights.count {
            let top = rowOffsets[r]
            let h = rowOffsets[r + 1] - top
            if h <= 0 || top > drawH { continue }
            drawCenteredSingleLine(in: ctx, text: "\(r + 1)", font: headerFont, color: headerColor, rect: CGRect(x: viewport.minX, y: top, width: sheetHeaderWidth, height: min(h, 32)))
        }
        ctx.restoreGState()
    }

    private static func drawSpreadsheetCell(
        in ctx: CGContext,
        cell: OfficeCell,
        rect: CGRect,
        styles: [OfficeCellStyle]
    ) {
        let style = (cell.style >= 0 && cell.style < styles.count) ? styles[cell.style] : nil
        if let style, let fillCG = argbToCGColor(style.fill) {
            ctx.setFillColor(fillCG)
            ctx.fill(rect)
        }
        guard !cell.text.isEmpty else { return }

        let fontSize = max(8, style?.fontSize ?? 11)
        let font = resolveNSFont(face: "", size: fontSize, bold: style?.bold ?? false, italic: style?.italic ?? false)
        let textColor = argbToNSColor(style?.color ?? 0xff202124)
        let attr = NSAttributedString(string: cell.text, attributes: [
            .font: font,
            .foregroundColor: textColor
        ])
        let ctLine = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let textW = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil))

        ctx.saveGState()
        ctx.clip(to: rect.insetBy(dx: 2, dy: 1))
        ctx.textMatrix = CGAffineTransform(scaleX: 1.0, y: -1.0)
        let align = style?.alignment ?? (cell.numeric ? 2 : 0)
        let tx: CGFloat
        if align == 1 {
            tx = rect.minX + max(3, (rect.width - textW) / 2.0)
        } else if align == 2 {
            tx = rect.maxX - 4 - textW
        } else {
            tx = rect.minX + 4
        }
        let ty = rect.minY + (rect.height + ascent - descent) / 2.0
        ctx.textPosition = CGPoint(x: tx, y: ty)
        CTLineDraw(ctLine, ctx)
        ctx.restoreGState()
    }

    private static func drawCenteredSingleLine(
        in ctx: CGContext,
        text: String,
        font: NSFont,
        color: NSColor,
        rect: CGRect
    ) {
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let x = rect.minX + (rect.width - w) / 2.0
        let y = rect.minY + (rect.height + ascent - descent) / 2.0
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }

    private static func columnLabel(for index: Int) -> String {
        var result = ""
        var temp = index
        while temp >= 0 {
            let scalar = UnicodeScalar((temp % 26) + 65)!
            result = String(Character(scalar)) + result
            temp = (temp / 26) - 1
        }
        return result
    }
}
