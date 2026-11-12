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
            drawTable(in: ctx, element: element, images: images)
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

    public static func findMerge(_ merges: [OfficeCellRange], r: Int, c: Int) -> OfficeCellRange? {
        for m in merges {
            if r >= m.startRow && r <= m.endRow && c >= m.startColumn && c <= m.endColumn {
                return m
            }
        }
        return nil
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

    public static func computeTableGeometry(
        element: OfficeElement
    ) -> (cols: Int, colWidths: [CGFloat], colX: [CGFloat], rowTops: [CGFloat]) {
        let rows = element.rows
        var cols = 0
        for r in rows { cols = max(cols, r.count) }
        guard cols > 0 else { return (0, [], [], []) }
        let numRows = rows.count
        let colWidths = resolveColumnWidths(element: element, cols: cols)
        var colX = [CGFloat](repeating: 0, count: cols + 1)
        for c in 0..<cols {
            colX[c + 1] = colX[c] + colWidths[c]
        }
        var rowTops = [CGFloat](repeating: 0, count: numRows + 1)
        var y: CGFloat = 0
        for (r, row) in rows.enumerated() {
            rowTops[r] = y
            var rowHeight: CGFloat = 20
            for c in 0..<cols {
                let m = findMerge(element.merges, r: r, c: c)
                if let m, (m.startRow != r || m.startColumn != c) {
                    continue
                }
                let x1 = colX[c]
                let x2 = m != nil ? colX[min(cols, m!.endColumn + 1)] : colX[c + 1]
                let cellW = max(1, x2 - x1)
                let cellParas = c < row.count ? row[c] : []
                if !cellParas.isEmpty {
                    var cellContentH: CGFloat = 0
                    let availW = max(1, cellW - 10)
                    for para in cellParas {
                        if let _ = para.image, let w = para.imageWidth, let h = para.imageHeight, w > 0, h > 0 {
                            let fitW = min(availW, w)
                            let fitH = h * (fitW / w)
                            cellContentH += fitH + max(0, para.before) + max(0, para.after)
                        }
                    }
                    let textParas = cellParas.filter { $0.image == nil }
                    if !textParas.isEmpty {
                        cellContentH += measureParagraphsHeight(textParas, availableWidth: availW, wrap: true)
                    }
                    rowHeight = max(rowHeight, cellContentH + 10)
                }
            }
            y += rowHeight
        }
        rowTops[numRows] = y
        return (cols, colWidths, colX, rowTops)
    }

    public static func measureTableHeight(element: OfficeElement) -> CGFloat {
        let geom = computeTableGeometry(element: element)
        return geom.rowTops.last ?? 0
    }

    private static func drawTable(
        in ctx: CGContext,
        element: OfficeElement,
        images: [String: CGImage]
    ) {
        let rows = element.rows
        let geom = computeTableGeometry(element: element)
        let cols = geom.cols
        let colX = geom.colX
        let rowTops = geom.rowTops
        let numRows = rows.count
        guard cols > 0 && numRows > 0 else { return }

        let borderColor = element.stroke != 0 ? (argbToCGColor(element.stroke) ?? argbToCGColor(0xffb7bec7)) : argbToCGColor(0xffb7bec7)
        let borderWidth = element.strokeWidth > 0 ? element.strokeWidth : 0.6

        for r in 0..<numRows {
            let row = rows[r]
            for c in 0..<cols {
                let m = findMerge(element.merges, r: r, c: c)
                let x1: CGFloat
                let x2: CGFloat
                let y1: CGFloat
                let y2: CGFloat

                if let m {
                    // 非锚点合并单元格直接跳过，防止内部网格线横穿合并区域
                    guard m.startRow == r && m.startColumn == c else { continue }
                    x1 = colX[c]
                    x2 = colX[min(cols, m.endColumn + 1)]
                    y1 = rowTops[r]
                    y2 = rowTops[min(numRows, m.endRow + 1)]
                } else {
                    x1 = colX[c]
                    x2 = colX[c + 1]
                    y1 = rowTops[r]
                    y2 = rowTops[r + 1]
                }

                let cellRect = CGRect(x: x1, y: y1, width: max(1, x2 - x1), height: max(1, y2 - y1))

                if r < element.cellFills.count && c < element.cellFills[r].count {
                    if let fillCG = argbToCGColor(element.cellFills[r][c]) {
                        ctx.setFillColor(fillCG)
                        ctx.fill(cellRect)
                    }
                }
                if let borderColor {
                    ctx.setStrokeColor(borderColor)
                    ctx.setLineWidth(borderWidth)
                    ctx.stroke(cellRect)
                }

                let cellParas = c < row.count ? row[c] : []
                if !cellParas.isEmpty {
                    let availW = max(1, cellRect.width - 10)
                    var contentHeight: CGFloat = 0
                    for p in cellParas {
                        if let _ = p.image, let w = p.imageWidth, let h = p.imageHeight, w > 0, h > 0 {
                            let fitW = min(availW, w)
                            let fitH = h * (fitW / w)
                            contentHeight += fitH + max(0, p.before) + max(0, p.after)
                        }
                    }
                    let textParas = cellParas.filter { $0.image == nil }
                    let lines = textParas.isEmpty ? [] : layoutParagraphs(textParas, availableWidth: availW, wrap: true)
                    for line in lines {
                        contentHeight += line.before + line.height + line.after
                    }

                    let vOffset: CGFloat
                    if cellRect.height > contentHeight + 10 {
                        vOffset = max(5, (cellRect.height - contentHeight) / 2.0)
                    } else {
                        vOffset = 5
                    }

                    ctx.saveGState()
                    ctx.clip(to: cellRect)

                    var curCellY = y1 + vOffset
                    for p in cellParas {
                        if let part = p.image, let w = p.imageWidth, let h = p.imageHeight, w > 0, h > 0 {
                            curCellY += max(0, p.before)
                            let fitW = min(availW, w)
                            let fitH = h * (fitW / w)
                            var imgX = x1 + 5
                            if p.alignment == 1 {
                                imgX += (availW - fitW) / 2.0
                            } else if p.alignment == 2 {
                                imgX += availW - fitW
                            }
                            let imgRect = CGRect(x: imgX, y: curCellY, width: fitW, height: fitH)
                            if let cgImg = images[part] {
                                drawCGImageTopDown(in: ctx, image: cgImg, rect: imgRect)
                            } else {
                                if let placeholder = argbToCGColor(0xffe8eaed) {
                                    ctx.setFillColor(placeholder)
                                    ctx.fill(imgRect)
                                }
                            }
                            curCellY += fitH + max(0, p.after)
                        }
                    }

                    if !lines.isEmpty {
                        drawLaidOutLines(
                            in: ctx,
                            lines: lines,
                            originX: x1 + 5,
                            originY: curCellY,
                            availableWidth: availW
                        )
                    }
                    ctx.restoreGState()
                }
            }
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
        let isLast: Bool
        let paraBackground: UInt32
        let borderTop: UInt32
        let borderBottom: UInt32
        let borderLeft: UInt32
        let borderRight: UInt32
        let borderWidth: CGFloat
        let isParagraphStart: Bool
        let isParagraphEnd: Bool
        let paragraphHeight: CGFloat
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

            // 1. 段落底纹绘制
            if line.isParagraphStart && line.paraBackground != 0 {
                let bgColor = argbToNSColor(line.paraBackground).cgColor
                ctx.saveGState()
                ctx.setFillColor(bgColor)
                ctx.fill(CGRect(x: originX, y: curY, width: availableWidth, height: line.paragraphHeight))
                ctx.restoreGState()
            }

            // 2. 段落边框绘制
            if line.isParagraphStart && line.borderWidth > 0 {
                let bw = line.borderWidth
                let pHeight = line.paragraphHeight
                let halfBw = bw / 2.0
                ctx.saveGState()
                ctx.setLineWidth(bw)
                if line.borderTop != 0 {
                    ctx.setStrokeColor(argbToNSColor(line.borderTop).cgColor)
                    ctx.beginPath()
                    ctx.move(to: CGPoint(x: originX, y: curY + halfBw))
                    ctx.addLine(to: CGPoint(x: originX + availableWidth, y: curY + halfBw))
                    ctx.strokePath()
                }
                if line.borderBottom != 0 {
                    ctx.setStrokeColor(argbToNSColor(line.borderBottom).cgColor)
                    ctx.beginPath()
                    ctx.move(to: CGPoint(x: originX, y: curY + pHeight - halfBw))
                    ctx.addLine(to: CGPoint(x: originX + availableWidth, y: curY + pHeight - halfBw))
                    ctx.strokePath()
                }
                if line.borderLeft != 0 {
                    ctx.setStrokeColor(argbToNSColor(line.borderLeft).cgColor)
                    ctx.beginPath()
                    ctx.move(to: CGPoint(x: originX + halfBw, y: curY))
                    ctx.addLine(to: CGPoint(x: originX + halfBw, y: curY + pHeight))
                    ctx.strokePath()
                }
                if line.borderRight != 0 {
                    ctx.setStrokeColor(argbToNSColor(line.borderRight).cgColor)
                    ctx.beginPath()
                    ctx.move(to: CGPoint(x: originX + availableWidth - halfBw, y: curY))
                    ctx.addLine(to: CGPoint(x: originX + availableWidth - halfBw, y: curY + pHeight))
                    ctx.strokePath()
                }
                ctx.restoreGState()
            }

            let lineAvailW = max(1, availableWidth - line.leftIndent - line.rightIndent)
            var lineX = originX + line.leftIndent
            if line.alignment == 1 {
                lineX += (lineAvailW - line.width) / 2.0
            } else if line.alignment == 2 {
                lineX += lineAvailW - line.width
            }

            let drawLine: CTLine
            if line.alignment == 3 && !line.isLast, let justified = CTLineCreateJustifiedLine(line.ctLine, 1.0, Double(lineAvailW)) {
                drawLine = justified
            } else {
                drawLine = line.ctLine
            }

            // 3. 绘制文本高亮背景
            let glyphRuns = (CTLineGetGlyphRuns(drawLine) as [AnyObject])
            for runObj in glyphRuns {
                let ctRun = runObj as! CTRun
                let runAttrs = CTRunGetAttributes(ctRun) as NSDictionary
                if let bgColor = (runAttrs[NSAttributedString.Key.backgroundColor] ?? runAttrs[NSAttributedString.Key.backgroundColor.rawValue as NSString]) as? NSColor {
                    let stringRange = CTRunGetStringRange(ctRun)
                    let xOffset = CTLineGetOffsetForStringIndex(drawLine, stringRange.location, nil)
                    let runWidth = CGFloat(CTRunGetTypographicBounds(ctRun, CFRange(location: 0, length: 0), nil, nil, nil))
                    if runWidth > 0 {
                        ctx.saveGState()
                        ctx.setFillColor(bgColor.cgColor)
                        ctx.fill(CGRect(x: lineX + CGFloat(xOffset), y: curY, width: CGFloat(runWidth), height: line.height))
                        ctx.restoreGState()
                    }
                }
            }

            let baselineY = curY + line.ascent + max(0, (line.height - (line.ascent + line.descent)) / 2.0)
            ctx.textPosition = CGPoint(x: lineX, y: baselineY)
            CTLineDraw(drawLine, ctx)
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
                    after: max(0, para.after),
                    isLast: true,
                    paraBackground: para.background,
                    borderTop: para.borderTop,
                    borderBottom: para.borderBottom,
                    borderLeft: para.borderLeft,
                    borderRight: para.borderRight,
                    borderWidth: para.borderWidth,
                    isParagraphStart: true,
                    isParagraphEnd: true,
                    paragraphHeight: h
                ))
                continue
            }

            let typesetter = CTTypesetterCreateWithAttributedString(attrString as CFAttributedString)
            let totalLen = attrString.length
            var startIdx = 0
            var lineIndex = 0
            var paraLines: [LaidOutLine] = []

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
                paraLines.append(LaidOutLine(
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
                    isLast: isLast,
                    paraBackground: para.background,
                    borderTop: para.borderTop,
                    borderBottom: para.borderBottom,
                    borderLeft: para.borderLeft,
                    borderRight: para.borderRight,
                    borderWidth: para.borderWidth,
                    isParagraphStart: isFirst,
                    isParagraphEnd: isLast,
                    paragraphHeight: 0
                ))
                startIdx += count
                lineIndex += 1
            }

            let paraH = paraLines.reduce(0) { $0 + $1.height }
            for (i, pl) in paraLines.enumerated() {
                result.append(LaidOutLine(
                    ctLine: pl.ctLine,
                    width: pl.width,
                    ascent: pl.ascent,
                    descent: pl.descent,
                    height: pl.height,
                    alignment: pl.alignment,
                    leftIndent: pl.leftIndent,
                    rightIndent: pl.rightIndent,
                    before: pl.before,
                    after: pl.after,
                    isLast: pl.isLast,
                    paraBackground: pl.paraBackground,
                    borderTop: pl.borderTop,
                    borderBottom: pl.borderBottom,
                    borderLeft: pl.borderLeft,
                    borderRight: pl.borderRight,
                    borderWidth: pl.borderWidth,
                    isParagraphStart: i == 0,
                    isParagraphEnd: i == paraLines.count - 1,
                    paragraphHeight: paraH
                ))
            }
        }
        return result
    }

    /// 有容量上限的字体 LRU 缓存；数组保存从最早到最近使用的键。
    struct FontLRUCache {
        private let capacity: Int
        private var values: [String: NSFont] = [:]
        private var keys: [String] = []

        init(capacity: Int) {
            self.capacity = max(1, capacity)
        }

        var count: Int {
            values.count
        }

        mutating func value(forKey key: String) -> NSFont? {
            guard let font = values[key] else { return nil }
            markAsRecentlyUsed(key)
            return font
        }

        mutating func insert(_ font: NSFont, forKey key: String) -> NSFont {
            if let cached = values[key] {
                markAsRecentlyUsed(key)
                return cached
            }
            values[key] = font
            keys.append(key)
            if keys.count > capacity {
                let evicted = keys.removeFirst()
                values.removeValue(forKey: evicted)
            }
            return font
        }

        private mutating func markAsRecentlyUsed(_ key: String) {
            keys.removeAll { $0 == key }
            keys.append(key)
        }
    }

    private static var fontCache = FontLRUCache(capacity: 64)
    private static let fontCacheLock = NSLock()

    private static func mapFontWeight(weight: Int, bold: Bool, lowerFace: String) -> NSFont.Weight {
        if weight > 0 {
            switch weight {
            case ..<150: return .ultraLight
            case 150..<250: return .thin
            case 250..<350: return .light
            case 350..<450: return .regular
            case 450..<550: return .medium
            case 550..<650: return .semibold
            case 650..<750: return .bold
            case 750..<850: return .heavy
            default: return .black
            }
        }
        if bold || lowerFace.contains("bold") { return .bold }
        if lowerFace.contains("black") || lowerFace.contains("heavy") || lowerFace.contains("impact") { return .heavy }
        if lowerFace.contains("medium") { return .medium }
        if lowerFace.contains("light") { return .light }
        return .regular
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
                color: first?.color ?? 0xff202124,
                strike: false,
                vertAlign: "",
                spacing: 0,
                weight: first?.weight ?? 0
            ))
        }
        allRuns.append(contentsOf: para.runs.filter { !$0.text.isEmpty })

        for run in allRuns {
            let isScript = run.vertAlign == "superscript" || run.vertAlign == "subscript"
            let effectiveSize = isScript ? max(1, run.size * 0.65) : max(1, run.size)
            let font = resolveNSFont(face: run.fontFace, size: effectiveSize, bold: run.bold, italic: run.italic, weight: run.weight)
            let color = argbToNSColor(run.color)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color
            ]
            if run.underline {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = color
            }
            if run.strike {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.strikethroughColor] = color
            }
            if run.vertAlign == "superscript" {
                attributes[.baselineOffset] = effectiveSize * 0.45
            } else if run.vertAlign == "subscript" {
                attributes[.baselineOffset] = -effectiveSize * 0.25
            }
            if run.spacing != 0 {
                attributes[.kern] = run.spacing
            }
            if run.background != 0 {
                attributes[.backgroundColor] = argbToNSColor(run.background)
            }
            attr.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return attr
    }

    public static func resolveNSFont(face: String, size: CGFloat, bold: Bool, italic: Bool, weight: Int = 0) -> NSFont {
        let trimmed = face.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "\(trimmed)#\(size)#\(bold)#\(italic)#\(weight)"
        fontCacheLock.lock()
        if let cached = fontCache.value(forKey: key) {
            fontCacheLock.unlock()
            return cached
        }
        fontCacheLock.unlock()

        let lower = trimmed.lowercased()
        let targetWeight = mapFontWeight(weight: weight, bold: bold, lowerFace: lower)
        let effectiveBold = bold || targetWeight == .bold || targetWeight == .heavy || targetWeight == .black || weight >= 600

        var font: NSFont?
        if !trimmed.isEmpty {
            font = NSFont(name: trimmed, size: size)
            if font == nil && (lower.contains("song") || lower.contains("宋体") || lower.contains("mincho") || lower.contains("times") || lower.contains("georgia") || lower.contains("cambria") || lower.contains("fangsong") || lower.contains("仿宋") || lower.contains("serif") || lower.contains("simsun")) {
                font = NSFont(name: "Times New Roman", size: size) ?? NSFont(name: "Songti SC", size: size) ?? NSFont(name: "Georgia", size: size)
            } else if font == nil && (lower.contains("mono") || lower.contains("consolas") || lower.contains("courier") || lower.contains("menlo") || lower.contains("monaco")) {
                font = NSFont.monospacedSystemFont(ofSize: size, weight: targetWeight)
            } else if font == nil && (lower.contains("kai") || lower.contains("楷体") || lower.contains("cursive") || lower.contains("comic")) {
                font = NSFont(name: "Kaiti SC", size: size) ?? NSFont(name: "Comic Sans MS", size: size)
            } else if font == nil && (lower.contains("hei") || lower.contains("黑体") || lower.contains("yahei") || lower.contains("雅黑")) {
                font = NSFont(name: "PingFang SC", size: size)
            }
        }

        var resolved = font ?? NSFont.systemFont(ofSize: size, weight: targetWeight)
        var traits: NSFontTraitMask = []
        if effectiveBold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        if !traits.isEmpty {
            resolved = NSFontManager.shared.convert(resolved, toHaveTrait: traits)
        }

        fontCacheLock.lock()
        let cached = fontCache.insert(resolved, forKey: key)
        fontCacheLock.unlock()

        return cached
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

    // MARK: - 全文检索高亮矩形计算

    public static func computeDocxBlockYOffsets(in doc: OfficeDocument) -> [CGFloat] {
        guard doc.kind == .docx else { return [] }
        let allBlocks = doc.headerBlocks + doc.blocks + doc.footerBlocks
        let docW = doc.width > 0 ? doc.width : 595
        let marginX: CGFloat = doc.marginLeft > 0 ? doc.marginLeft : 24
        let marginR: CGFloat = doc.marginRight > 0 ? doc.marginRight : 24
        let availW = max(100, docW - marginX - marginR)
        var curY: CGFloat = doc.marginTop > 0 ? doc.marginTop : 24
        var offsets: [CGFloat] = []
        offsets.reserveCapacity(allBlocks.count)
        for b in allBlocks {
            offsets.append(curY)
            let elW = b.width > 0 ? min(availW, b.width) : availW
            var elH = b.height
            if elH <= 0 {
                if b.type == .table && !b.rows.isEmpty {
                    var tbl = b
                    tbl.width = elW
                    elH = measureTableHeight(element: tbl)
                } else if !b.paragraphs.isEmpty {
                    elH = measureParagraphsHeight(b.paragraphs, availableWidth: elW, wrap: true) + 8
                } else {
                    elH = 80
                }
            }
            curY += elH + 8
        }
        return offsets
    }

    public static func computeHighlightRects(
        for match: OfficeSearchMatch,
        in doc: OfficeDocument,
        docxBlockYOffsets: [CGFloat]? = nil
    ) -> [CGRect] {
        switch doc.kind {
        case .docx:
            let allBlocks = doc.headerBlocks + doc.blocks + doc.footerBlocks
            guard match.elementIndex >= 0 && match.elementIndex < allBlocks.count else { return [] }
            let docW = doc.width > 0 ? doc.width : 595
            let marginX: CGFloat = doc.marginLeft > 0 ? doc.marginLeft : 24
            let marginR: CGFloat = doc.marginRight > 0 ? doc.marginRight : 24
            let availW = max(100, docW - marginX - marginR)
            let curY: CGFloat
            if let offsets = docxBlockYOffsets, match.elementIndex < offsets.count {
                curY = offsets[match.elementIndex]
            } else {
                var calculatedY: CGFloat = doc.marginTop > 0 ? doc.marginTop : 24
                for i in 0..<match.elementIndex {
                    let b = allBlocks[i]
                    let elW = b.width > 0 ? min(availW, b.width) : availW
                    var elH = b.height
                    if elH <= 0 {
                        if b.type == .table && !b.rows.isEmpty {
                            var tbl = b
                            tbl.width = elW
                            elH = measureTableHeight(element: tbl)
                        } else if !b.paragraphs.isEmpty {
                            elH = measureParagraphsHeight(b.paragraphs, availableWidth: elW, wrap: true) + 8
                        } else {
                            elH = 80
                        }
                    }
                    calculatedY += elH + 8
                }
                curY = calculatedY
            }

            let block = allBlocks[match.elementIndex]
            let elW = block.width > 0 ? min(availW, block.width) : availW
            if block.type == .table && !block.rows.isEmpty {
                guard let r = match.row, let c = match.column,
                      r >= 0, r < block.rows.count, c >= 0, c < block.rows[r].count else { return [] }
                let cellParas = block.rows[r][c]
                guard match.paragraphIndex >= 0 && match.paragraphIndex < cellParas.count else { return [] }
                var tbl = block
                tbl.width = elW
                let geom = computeTableGeometry(element: tbl)
                let cols = geom.cols
                let colX = geom.colX
                let rowTops = geom.rowTops
                guard cols > 0, r < rowTops.count - 1, c < colX.count - 1 else { return [] }

                let m = findMerge(block.merges, r: r, c: c)
                let anchorR = m?.startRow ?? r
                let anchorC = m?.startColumn ?? c
                let x1 = colX[anchorC]
                let x2 = m != nil ? colX[min(cols, m!.endColumn + 1)] : colX[anchorC + 1]
                let cellX = marginX + x1
                let cellW = max(1, x2 - x1)
                let availCellW = max(1, cellW - 10)
                let cellH = rowTops[min(block.rows.count, (m?.endRow ?? r) + 1)] - rowTops[anchorR]
                var contentHeight: CGFloat = 0
                for p in cellParas {
                    if let _ = p.image, let w = p.imageWidth, let h = p.imageHeight, w > 0, h > 0 {
                        let fitW = min(availCellW, w)
                        let fitH = h * (fitW / w)
                        contentHeight += fitH + max(0, p.before) + max(0, p.after)
                    }
                }
                let textParas = cellParas.filter { $0.image == nil }
                if !textParas.isEmpty {
                    contentHeight += measureParagraphsHeight(textParas, availableWidth: availCellW, wrap: true)
                }
                let vOffset: CGFloat = cellH > contentHeight + 10 ? max(5, (cellH - contentHeight) / 2.0) : 5
                let cellOrigin = CGPoint(x: cellX + 5, y: curY + rowTops[anchorR] + vOffset)
                return charHighlightRects(
                    paragraphs: cellParas,
                    targetParagraphIndex: match.paragraphIndex,
                    startChar: match.startChar,
                    endChar: match.endChar,
                    availableWidth: availCellW,
                    wrap: true,
                    origin: cellOrigin
                )
            } else {
                guard match.paragraphIndex >= 0 && match.paragraphIndex < block.paragraphs.count else { return [] }
                var elH = block.height
                if elH <= 0 {
                    elH = measureParagraphsHeight(block.paragraphs, availableWidth: elW, wrap: true) + 8
                }
                let padding = max(0, block.padding)
                let availBlockW = max(1, elW - padding * 2)
                let totalH = measureParagraphsHeight(block.paragraphs, availableWidth: availBlockW, wrap: true)
                var offsetY = padding
                let remaining = max(0, elH - padding * 2 - totalH)
                switch block.verticalAlignment {
                case .center:
                    offsetY += remaining / 2
                case .bottom:
                    offsetY += remaining
                case .top:
                    break
                }
                let origin = CGPoint(x: marginX + padding, y: curY + offsetY)
                return charHighlightRects(
                    paragraphs: block.paragraphs,
                    targetParagraphIndex: match.paragraphIndex,
                    startChar: match.startChar,
                    endChar: match.endChar,
                    availableWidth: availBlockW,
                    wrap: true,
                    origin: origin
                )
            }

        case .pptx:
            guard match.pageIndex >= 0 && match.pageIndex < doc.pages.count else { return [] }
            var curY: CGFloat = 0
            for i in 0..<match.pageIndex {
                let pH = doc.pages[i].height > 0 ? doc.pages[i].height : 405
                curY += pH + 16
            }
            let page = doc.pages[match.pageIndex]
            guard match.elementIndex >= 0 && match.elementIndex < page.elements.count else { return [] }
            let el = page.elements[match.elementIndex]

            let affine: CGAffineTransform
            if el.transform.count >= 6 {
                let m = el.transform
                affine = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5] + curY)
            } else {
                affine = CGAffineTransform(translationX: el.x, y: el.y + curY)
            }

            if el.type == .table && !el.rows.isEmpty {
                guard let r = match.row, let c = match.column,
                      r >= 0, r < el.rows.count, c >= 0, c < el.rows[r].count else { return [] }
                let cellParas = el.rows[r][c]
                guard match.paragraphIndex >= 0 && match.paragraphIndex < cellParas.count else { return [] }
                let geom = computeTableGeometry(element: el)
                let cols = geom.cols
                let colX = geom.colX
                let rowTops = geom.rowTops
                guard cols > 0, r < rowTops.count - 1, c < colX.count - 1 else { return [] }

                let m = findMerge(el.merges, r: r, c: c)
                let anchorR = m?.startRow ?? r
                let anchorC = m?.startColumn ?? c
                let x1 = colX[anchorC]
                let x2 = m != nil ? colX[min(cols, m!.endColumn + 1)] : colX[anchorC + 1]
                let cellW = max(1, x2 - x1)
                let availCellW = max(1, cellW - 10)
                let cellH = rowTops[min(el.rows.count, (m?.endRow ?? r) + 1)] - rowTops[anchorR]
                var contentHeight: CGFloat = 0
                for p in cellParas {
                    if let _ = p.image, let w = p.imageWidth, let h = p.imageHeight, w > 0, h > 0 {
                        let fitW = min(availCellW, w)
                        let fitH = h * (fitW / w)
                        contentHeight += fitH + max(0, p.before) + max(0, p.after)
                    }
                }
                let textParas = cellParas.filter { $0.image == nil }
                if !textParas.isEmpty {
                    contentHeight += measureParagraphsHeight(textParas, availableWidth: availCellW, wrap: true)
                }
                let vOffset: CGFloat = cellH > contentHeight + 10 ? max(5, (cellH - contentHeight) / 2.0) : 5
                let cellOrigin = CGPoint(x: x1 + 5, y: rowTops[anchorR] + vOffset)
                let localRects = charHighlightRects(
                    paragraphs: cellParas,
                    targetParagraphIndex: match.paragraphIndex,
                    startChar: match.startChar,
                    endChar: match.endChar,
                    availableWidth: availCellW,
                    wrap: true,
                    origin: cellOrigin
                )
                return localRects.map { $0.applying(affine) }
            } else {
                guard match.paragraphIndex >= 0 && match.paragraphIndex < el.paragraphs.count else { return [] }
                let padding = max(0, el.padding)
                let availW = max(1, el.width - padding * 2)
                let totalH = measureParagraphsHeight(el.paragraphs, availableWidth: availW, wrap: el.textWrap)
                var offsetY = padding
                let remaining = max(0, el.height - padding * 2 - totalH)
                if el.verticalAlignment == .center {
                    offsetY += remaining / 2
                } else if el.verticalAlignment == .bottom {
                    offsetY += remaining
                }
                let origin = CGPoint(x: padding, y: offsetY)
                let localRects = charHighlightRects(
                    paragraphs: el.paragraphs,
                    targetParagraphIndex: match.paragraphIndex,
                    startChar: match.startChar,
                    endChar: match.endChar,
                    availableWidth: availW,
                    wrap: el.textWrap,
                    origin: origin
                )
                return localRects.map { $0.applying(affine) }
            }

        case .xlsx:
            guard match.pageIndex >= 0 && match.pageIndex < doc.sheets.count else { return [] }
            let sheet = doc.sheets[match.pageIndex]
            let (colOffsets, rowOffsets, _, _) = computeSheetExtents(sheet)
            let r = match.row ?? 0
            let c = match.column ?? 0
            guard r >= 0, r + 1 < rowOffsets.count, c >= 0, c + 1 < colOffsets.count else { return [] }

            if let g = sheet.geometry {
                for m in g.mergeRects {
                    if m.anchor == match.elementIndex {
                        return [CGRect(
                            x: m.left + sheetHeaderWidth,
                            y: m.top + sheetHeaderHeight,
                            width: max(1, m.right - m.left),
                            height: max(1, m.bottom - m.top)
                        )]
                    }
                }
            }
            let cellRect = CGRect(
                x: colOffsets[c],
                y: rowOffsets[r],
                width: max(1, colOffsets[c + 1] - colOffsets[c]),
                height: max(1, rowOffsets[r + 1] - rowOffsets[r])
            )
            return [cellRect]
        }
    }

    private static func charHighlightRects(
        paragraphs: [OfficeParagraph],
        targetParagraphIndex: Int,
        startChar: Int,
        endChar: Int,
        availableWidth: CGFloat,
        wrap: Bool,
        origin: CGPoint
    ) -> [CGRect] {
        var curY = origin.y
        for (pIdx, para) in paragraphs.enumerated() {
            let baseIndent = max(0, para.indent)
            let firstIndent = max(0, baseIndent + para.firstLineIndent)
            let rightIndent = max(0, para.rightIndent)

            let attrString = buildAttributedString(for: para)
            let totalLen = attrString.length

            guard totalLen > 0 else {
                let defaultSize = para.runs.first?.size ?? 12
                let h = computeLineHeight(para: para, naturalHeight: defaultSize * 1.2)
                curY += max(0, para.before) + h + max(0, para.after)
                continue
            }

            let typesetter = CTTypesetterCreateWithAttributedString(attrString as CFAttributedString)
            var startIdx = 0
            var lineIndex = 0
            let isTargetPara = (pIdx == targetParagraphIndex)
            var rects: [CGRect] = []

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

                let before = lineIndex == 0 ? max(0, para.before) : 0
                let isLast = (startIdx + count) >= totalLen
                let after = isLast ? max(0, para.after) : 0

                curY += before

                if isTargetPara {
                    let lineStart = startIdx
                    let lineEnd = startIdx + count
                    let selStart = max(startChar, lineStart)
                    let selEnd = min(endChar, lineEnd)

                    if selStart < selEnd {
                        let lineAvailW = max(1, availableWidth - leftInd - rightIndent)
                        var lineX = origin.x + leftInd
                        if para.alignment == 1 {
                            lineX += (lineAvailW - w) / 2.0
                        } else if para.alignment == 2 {
                            lineX += lineAvailW - w
                        }

                        let effectiveLine: CTLine
                        if para.alignment == 3 && !isLast, let justified = CTLineCreateJustifiedLine(ctLine, 1.0, Double(lineAvailW)) {
                            effectiveLine = justified
                        } else {
                            effectiveLine = ctLine
                        }

                        let x1 = CTLineGetOffsetForStringIndex(effectiveLine, selStart - lineStart, nil)
                        let x2 = CTLineGetOffsetForStringIndex(effectiveLine, selEnd - lineStart, nil)
                        let rect = CGRect(
                            x: lineX + min(x1, x2),
                            y: curY,
                            width: max(2.0, abs(x2 - x1)),
                            height: lineH
                        )
                        rects.append(rect)
                    }
                }

                curY += lineH + after
                startIdx += count
                lineIndex += 1
            }

            if isTargetPara {
                return rects
            }
        }
        return []
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

        var rawFontSize = style?.fontSize ?? 11
        if let vertAlign = style?.vertAlign, !vertAlign.isEmpty {
            rawFontSize *= 0.65
        }
        let fontSize = max(6, rawFontSize)
        let font = resolveNSFont(
            face: style?.fontFace ?? "",
            size: fontSize,
            bold: style?.bold ?? false,
            italic: style?.italic ?? false
        )
        let textColor = argbToNSColor(style?.color ?? 0xff202124)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        if style?.underline == true {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.underlineColor] = textColor
        }
        if style?.strike == true {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = textColor
        }
        if let vertAlign = style?.vertAlign {
            if vertAlign == "superscript" {
                attributes[.baselineOffset] = fontSize * 0.45
            } else if vertAlign == "subscript" {
                attributes[.baselineOffset] = -fontSize * 0.25
            }
        }
        let attr = NSAttributedString(string: cell.text, attributes: attributes)
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
