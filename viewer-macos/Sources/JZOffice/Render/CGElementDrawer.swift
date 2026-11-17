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

    // MARK: - DOCX 浮动布局与文字环绕

    public enum DocxWrapSide: Int, Sendable, Equatable {
        case left = -1
        case right = 1
    }

    public struct DocxWrapObstacle: Sendable, Equatable {
        public var left: CGFloat
        public var right: CGFloat
        public var top: CGFloat
        public var bottom: CGFloat
        public var side: DocxWrapSide

        public init(left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat, side: DocxWrapSide) {
            self.left = left
            self.right = right
            self.top = top
            self.bottom = bottom
            self.side = side
        }
    }

    public struct DocxBlockPlacement: Sendable {
        public let elementIndex: Int
        public let element: OfficeElement
        public let frame: CGRect
        public let isFloating: Bool
        public let behindDoc: Bool
        public let obstacles: [DocxWrapObstacle]
    }

    public struct DocxLayoutPlan: Sendable {
        public let placements: [DocxBlockPlacement]
        public let zOrder: [Int]
        public let yOffsets: [CGFloat]
        public let contentHeight: CGFloat
    }

    // MARK: - CoreText 段落排版与绘制

    internal struct LaidOutLine {
        let paraIndex: Int
        let localCharRange: NSRange
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

    internal static func resolveLineIndents(
        lineIndex: Int,
        firstIndent: CGFloat,
        baseIndent: CGFloat,
        rightIndent: CGFloat,
        lineTop: CGFloat,
        estLineH: CGFloat,
        availableWidth: CGFloat,
        wrap: Bool,
        obstacles: [DocxWrapObstacle]
    ) -> (left: CGFloat, right: CGFloat) {
        var left = lineIndex == 0 ? firstIndent : baseIndent
        var right = rightIndent
        if wrap && !obstacles.isEmpty {
            let lineBottom = lineTop + estLineH
            for obs in obstacles where obs.bottom > lineTop && obs.top < lineBottom {
                switch obs.side {
                case .left:
                    left = max(left, max(0, obs.right))
                case .right:
                    right = max(right, max(0, availableWidth - obs.left))
                }
            }
            let minLineW = max(1, min(availableWidth, 24))
            let maxSum = max(0, availableWidth - minLineW)
            if left + right > maxSum {
                left = min(left, maxSum)
                right = min(right, max(0, maxSum - left))
            }
        }
        return (left, right)
    }

    public static func measureParagraphsHeight(
        _ paragraphs: [OfficeParagraph],
        availableWidth: CGFloat,
        wrap: Bool,
        obstacles: [DocxWrapObstacle] = []
    ) -> CGFloat {
        let lines = layoutParagraphs(paragraphs, availableWidth: availableWidth, wrap: wrap, obstacles: obstacles)
        return lines.reduce(0) { $0 + $1.before + $1.height + $1.after }
    }

    /// 计算不折行段落组所需的最大行宽（用于 `spAutoFit + wrap="none"` 文本框自适配宽度）
    internal static func measureParagraphsMaxLineWidth(
        _ paragraphs: [OfficeParagraph],
        maxWidth: CGFloat
    ) -> CGFloat {
        let lines = layoutParagraphs(paragraphs, availableWidth: maxWidth, wrap: false)
        var maxLineW: CGFloat = 0
        for line in lines {
            maxLineW = max(maxLineW, line.width + line.leftIndent + line.rightIndent)
        }
        return ceil(maxLineW)
    }

    internal static func resolveDocxTextWrap(for element: OfficeElement, isFloating: Bool) -> Bool {
        (isFloating || element.width <= 0) ? element.textWrap : true
    }

    private static func drawParagraphs(
        in ctx: CGContext,
        element: OfficeElement,
        obstacles: [DocxWrapObstacle] = []
    ) {
        let padding = max(0, element.padding)
        let availW = max(1, element.width - padding * 2)
        let wrap = element.textWrap
        let lines = layoutParagraphs(element.paragraphs, availableWidth: availW, wrap: wrap, obstacles: obstacles)
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

    internal static func layoutParagraphs(
        _ paragraphs: [OfficeParagraph],
        availableWidth: CGFloat,
        wrap: Bool,
        obstacles: [DocxWrapObstacle] = []
    ) -> [LaidOutLine] {
        var result: [LaidOutLine] = []
        var flowY: CGFloat = 0
        for (pIdx, para) in paragraphs.enumerated() {
            let baseIndent = max(0, para.indent)
            let firstIndent = max(0, baseIndent + para.firstLineIndent)
            let rightIndent = max(0, para.rightIndent)
            let paraBefore = max(0, para.before)
            let paraAfter = max(0, para.after)
            flowY += paraBefore

            let attrString = buildAttributedString(for: para)
            let defaultSize = para.runs.first?.size ?? 12
            let estLineH = computeLineHeight(para: para, naturalHeight: max(10, defaultSize * 1.2))
            guard attrString.length > 0 else {
                let emptyLine = CTLineCreateWithAttributedString(NSAttributedString(string: " "))
                let h = computeLineHeight(para: para, naturalHeight: defaultSize * 1.2)
                let (leftInd, rightInd) = resolveLineIndents(
                    lineIndex: 0,
                    firstIndent: firstIndent,
                    baseIndent: baseIndent,
                    rightIndent: rightIndent,
                    lineTop: flowY,
                    estLineH: h,
                    availableWidth: availableWidth,
                    wrap: wrap,
                    obstacles: obstacles
                )
                result.append(LaidOutLine(
                    paraIndex: pIdx,
                    localCharRange: NSRange(location: 0, length: 0),
                    ctLine: emptyLine,
                    width: 0,
                    ascent: defaultSize * 0.8,
                    descent: defaultSize * 0.2,
                    height: h,
                    alignment: para.alignment,
                    leftIndent: leftInd,
                    rightIndent: rightInd,
                    before: paraBefore,
                    after: paraAfter,
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
                flowY += h + paraAfter
                continue
            }

            let typesetter = CTTypesetterCreateWithAttributedString(attrString as CFAttributedString)
            let totalLen = attrString.length
            var startIdx = 0
            var lineIndex = 0
            var paraLines: [LaidOutLine] = []

            while startIdx < totalLen {
                let (leftInd, rightInd) = resolveLineIndents(
                    lineIndex: lineIndex,
                    firstIndent: firstIndent,
                    baseIndent: baseIndent,
                    rightIndent: rightIndent,
                    lineTop: flowY,
                    estLineH: estLineH,
                    availableWidth: availableWidth,
                    wrap: wrap,
                    obstacles: obstacles
                )
                let limitW = wrap ? Double(max(min(availableWidth, 8), availableWidth - leftInd - rightInd)) : 1_000_000.0
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
                    paraIndex: pIdx,
                    localCharRange: NSRange(location: startIdx, length: count),
                    ctLine: ctLine,
                    width: w,
                    ascent: ascent,
                    descent: descent,
                    height: lineH,
                    alignment: para.alignment,
                    leftIndent: leftInd,
                    rightIndent: rightInd,
                    before: isFirst ? paraBefore : 0,
                    after: isLast ? paraAfter : 0,
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
                flowY += lineH
                startIdx += count
                lineIndex += 1
            }

            flowY += paraAfter
            let paraH = paraLines.reduce(0) { $0 + $1.height }
            for (i, pl) in paraLines.enumerated() {
                result.append(LaidOutLine(
                    paraIndex: pl.paraIndex,
                    localCharRange: pl.localCharRange,
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

    private static func localizeObstacles(
        _ obstacles: [DocxWrapObstacle],
        originX: CGFloat,
        originY: CGFloat
    ) -> [DocxWrapObstacle] {
        obstacles.compactMap { obs in
            guard obs.bottom > originY else { return nil }
            return DocxWrapObstacle(
                left: obs.left - originX,
                right: obs.right - originX,
                top: obs.top - originY,
                bottom: obs.bottom - originY,
                side: obs.side
            )
        }
    }

    private static func pruneObstacles(_ obstacles: inout [DocxWrapObstacle], aboveY y: CGFloat) {
        obstacles.removeAll { $0.bottom <= y }
    }

    private static func maxObstacleBottom(_ obstacles: [DocxWrapObstacle]) -> CGFloat {
        obstacles.reduce(0) { max($0, $1.bottom) }
    }

    public static func layoutDocxBlocks(
        in doc: OfficeDocument,
        maxHeight: CGFloat? = nil
    ) -> DocxLayoutPlan {
        guard doc.kind == .docx else {
            return DocxLayoutPlan(placements: [], zOrder: [], yOffsets: [], contentHeight: 0)
        }

        let docW = doc.width > 0 ? doc.width : 595
        let marginL: CGFloat = doc.marginLeft > 0 ? doc.marginLeft : 24
        let marginR: CGFloat = doc.marginRight > 0 ? doc.marginRight : 24
        let marginTop: CGFloat = doc.marginTop > 0 ? doc.marginTop : 24
        let marginBottom: CGFloat = doc.marginBottom > 0 ? doc.marginBottom : 24
        let availW = max(100, docW - marginL - marginR)

        let totalCount = doc.headerBlocks.count + doc.blocks.count + doc.footerBlocks.count
        var placements: [DocxBlockPlacement] = []
        placements.reserveCapacity(totalCount)
        var behindIndices: [Int] = []
        var flowIndices: [Int] = []
        var frontIndices: [Int] = []
        var curY: CGFloat = marginTop
        var maxBottom: CGFloat = marginTop
        var globalIndex = 0

        let sections: [[OfficeElement]] = [doc.headerBlocks, doc.blocks, doc.footerBlocks]
        for (sectionIdx, section) in sections.enumerated() {
            let sectionMinY = sectionIdx == 0 ? min(marginTop, 24) : curY
            var activeObstacles: [DocxWrapObstacle] = []

            for block in section {
                let isFloating = block.wrapMode != .inline
                if let limitY = maxHeight, !isFloating && curY >= limitY - 16 {
                    break
                }

                if !isFloating {
                    pruneObstacles(&activeObstacles, aboveY: curY)
                    if block.type == .table && !activeObstacles.isEmpty {
                        curY = max(curY, maxObstacleBottom(activeObstacles) + 8)
                        activeObstacles.removeAll()
                    }
                }

                let elW: CGFloat
                if isFloating {
                    let rawW: CGFloat
                    if block.width > 0 {
                        rawW = block.width
                    } else if !block.textWrap && !block.paragraphs.isEmpty {
                        let padding = max(0, block.padding)
                        rawW = measureParagraphsMaxLineWidth(block.paragraphs, maxWidth: docW) + padding * 2
                    } else if block.type == .text {
                        rawW = min(availW, 240)
                    } else {
                        rawW = 80
                    }
                    elW = min(docW, max(1, rawW))
                } else if block.width > 0 {
                    elW = min(availW, block.width)
                } else if !block.textWrap && !block.paragraphs.isEmpty {
                    let padding = max(0, block.padding)
                    elW = min(availW, max(1, measureParagraphsMaxLineWidth(block.paragraphs, maxWidth: availW) + padding * 2))
                } else {
                    elW = availW
                }

                let blockMaxWidth = isFloating ? docW : availW
                var elH = block.height
                if elH > 0 {
                    if block.width > blockMaxWidth && block.width > 0 {
                        elH = block.height * (elW / block.width)
                    }
                } else if block.type == .line {
                    elH = 0
                } else if block.type == .table && !block.rows.isEmpty {
                    var tbl = block
                    tbl.width = elW
                    elH = measureTableHeight(element: tbl)
                }

                if isFloating {
                    if elH <= 0 && block.type != .line {
                        if !block.paragraphs.isEmpty {
                            let padding = max(0, block.padding)
                            let availTextW = max(1, elW - padding * 2)
                            elH = measureParagraphsHeight(block.paragraphs, availableWidth: availTextW, wrap: block.textWrap) + max(8, padding * 2)
                        } else {
                            elH = 80
                        }
                    }

                    let floatX: CGFloat
                    switch block.horizontalAlign {
                    case 1:
                        floatX = marginL
                    case 2:
                        floatX = max(0, marginL + (availW - elW) / 2.0)
                    case 3:
                        floatX = max(0, marginL + availW - elW)
                    default:
                        floatX = max(0, min(max(0, docW - elW), block.x))
                    }

                    let floatY = max(sectionMinY, curY + block.y)
                    let placedY: CGFloat
                    if block.wrapMode == .topAndBottom {
                        let clearY = max(curY, maxObstacleBottom(activeObstacles))
                        placedY = max(floatY, clearY + max(0, block.distTop))
                        curY = max(curY, placedY + elH + max(0, block.distBottom) + 8)
                        pruneObstacles(&activeObstacles, aboveY: curY)
                    } else {
                        placedY = floatY
                        if block.wrapMode != .none {
                            let obsTop = placedY - max(0, block.distTop)
                            let obsBottom = placedY + elH + max(0, block.distBottom)
                            let obsLeft = floatX - max(0, block.distLeft)
                            let obsRight = floatX + elW + max(0, block.distRight)
                            let side: DocxWrapSide
                            if block.horizontalAlign == 1 {
                                side = .left
                            } else if block.horizontalAlign == 3 {
                                side = .right
                            } else {
                                side = (floatX + elW * 0.5 <= marginL + availW * 0.5) ? .left : .right
                            }
                            if obsLeft <= marginL + 40 && obsRight >= marginL + availW - 40 {
                                curY = max(curY, obsBottom + 8)
                                pruneObstacles(&activeObstacles, aboveY: curY)
                            } else {
                                activeObstacles.append(DocxWrapObstacle(
                                    left: obsLeft,
                                    right: obsRight,
                                    top: obsTop,
                                    bottom: obsBottom,
                                    side: side
                                ))
                            }
                        }
                    }

                    let frame = CGRect(x: floatX, y: placedY, width: elW, height: elH)
                    let placementIdx = placements.count
                    placements.append(DocxBlockPlacement(
                        elementIndex: globalIndex,
                        element: block,
                        frame: frame,
                        isFloating: true,
                        behindDoc: block.behindDoc,
                        obstacles: []
                    ))
                    if block.behindDoc {
                        behindIndices.append(placementIdx)
                    } else {
                        frontIndices.append(placementIdx)
                    }
                    maxBottom = max(maxBottom, frame.maxY)
                } else {
                    let blockX: CGFloat
                    switch block.horizontalAlign {
                    case 2:
                        blockX = marginL + max(0, (availW - elW) / 2.0)
                    case 3:
                        blockX = marginL + max(0, availW - elW)
                    default:
                        blockX = marginL
                    }
                    if !activeObstacles.isEmpty && block.type != .text {
                        var clearBottom = curY
                        for obs in activeObstacles {
                            if blockX < obs.right && blockX + elW > obs.left {
                                clearBottom = max(clearBottom, obs.bottom + 8)
                            }
                        }
                        if clearBottom > curY {
                            curY = clearBottom
                            pruneObstacles(&activeObstacles, aboveY: curY)
                        }
                    }

                    var localObstacles: [DocxWrapObstacle] = []
                    if elH <= 0 && block.type != .line {
                        if !block.paragraphs.isEmpty {
                            let padding = max(0, block.padding)
                            let availTextW = max(1, elW - padding * 2)
                            let wrap = resolveDocxTextWrap(for: block, isFloating: false)
                            if block.type == .text && !activeObstacles.isEmpty {
                                localObstacles = localizeObstacles(
                                    activeObstacles,
                                    originX: blockX + padding,
                                    originY: curY + padding
                                )
                            }
                            elH = measureParagraphsHeight(
                                block.paragraphs,
                                availableWidth: availTextW,
                                wrap: wrap,
                                obstacles: localObstacles
                            ) + max(8, padding * 2)
                        } else {
                            elH = 80
                        }
                    }

                    let frame = CGRect(x: blockX, y: curY, width: elW, height: elH)
                    let placementIdx = placements.count
                    placements.append(DocxBlockPlacement(
                        elementIndex: globalIndex,
                        element: block,
                        frame: frame,
                        isFloating: false,
                        behindDoc: false,
                        obstacles: localObstacles
                    ))
                    flowIndices.append(placementIdx)
                    curY += elH + 8
                    maxBottom = max(maxBottom, curY)
                }

                globalIndex += 1
            }

            if !activeObstacles.isEmpty {
                curY = max(curY, maxObstacleBottom(activeObstacles) + 8)
                activeObstacles.removeAll()
                maxBottom = max(maxBottom, curY)
            }
        }

        return DocxLayoutPlan(
            placements: placements,
            zOrder: behindIndices + flowIndices + frontIndices,
            yOffsets: placements.map { $0.frame.minY },
            contentHeight: maxBottom + marginBottom
        )
    }

    public static func drawDocxPlacement(
        in ctx: CGContext,
        placement: DocxBlockPlacement,
        images: [String: CGImage]
    ) {
        var el = placement.element
        el.x = 0
        el.y = 0
        el.width = placement.frame.width
        el.height = placement.frame.height
        if !placement.isFloating && el.type == .text {
            el.textWrap = resolveDocxTextWrap(for: placement.element, isFloating: false)
        }

        ctx.saveGState()
        ctx.translateBy(x: placement.frame.minX, y: placement.frame.minY)
        if el.type == .text && !placement.obstacles.isEmpty {
            if el.transform.count >= 6 {
                let m = el.transform
                ctx.concatenate(CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]))
            }
            if let fillColor = argbToCGColor(el.fill) {
                ctx.setFillColor(fillColor)
                ctx.fill(CGRect(x: 0, y: 0, width: max(0, el.width), height: max(0, el.height)))
            }
            drawParagraphs(in: ctx, element: el, obstacles: placement.obstacles)
        } else {
            drawElement(in: ctx, element: el, images: images)
        }
        ctx.restoreGState()
    }

    public static func computeDocxBlockYOffsets(in doc: OfficeDocument) -> [CGFloat] {
        layoutDocxBlocks(in: doc).yOffsets
    }

    public static func computeHighlightRects(
        for match: OfficeSearchMatch,
        in doc: OfficeDocument,
        docxBlockYOffsets: [CGFloat]? = nil,
        docxPlan: DocxLayoutPlan? = nil
    ) -> [CGRect] {
        switch doc.kind {
        case .docx:
            let plan = docxPlan ?? layoutDocxBlocks(in: doc)
            guard match.elementIndex >= 0 && match.elementIndex < plan.placements.count else { return [] }
            let placement = plan.placements[match.elementIndex]
            let block = placement.element
            let elW = placement.frame.width
            let elH = placement.frame.height
            let blockOriginX = placement.frame.minX
            let blockOriginY = placement.frame.minY

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
                let cellX = blockOriginX + x1
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
                let cellOrigin = CGPoint(x: cellX + 5, y: blockOriginY + rowTops[anchorR] + vOffset)
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
                let padding = max(0, block.padding)
                let availBlockW = max(1, elW - padding * 2)
                let wrap = resolveDocxTextWrap(for: block, isFloating: placement.isFloating)
                let totalH = measureParagraphsHeight(
                    block.paragraphs,
                    availableWidth: availBlockW,
                    wrap: wrap,
                    obstacles: placement.obstacles
                )
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
                let localOrigin = CGPoint(x: padding, y: offsetY)
                let localRects = charHighlightRects(
                    paragraphs: block.paragraphs,
                    targetParagraphIndex: match.paragraphIndex,
                    startChar: match.startChar,
                    endChar: match.endChar,
                    availableWidth: availBlockW,
                    wrap: wrap,
                    origin: localOrigin,
                    obstacles: placement.obstacles
                )
                let blockAffine: CGAffineTransform
                if block.transform.count >= 6 {
                    let m = block.transform
                    blockAffine = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
                        .concatenating(CGAffineTransform(translationX: blockOriginX, y: blockOriginY))
                } else {
                    blockAffine = CGAffineTransform(translationX: blockOriginX, y: blockOriginY)
                }
                return localRects.map { $0.applying(blockAffine) }
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
        origin: CGPoint,
        obstacles: [DocxWrapObstacle] = []
    ) -> [CGRect] {
        let lines = layoutParagraphs(paragraphs, availableWidth: availableWidth, wrap: wrap, obstacles: obstacles)
        var curY = origin.y
        var rects: [CGRect] = []
        for line in lines {
            curY += line.before
            if line.paraIndex == targetParagraphIndex {
                let lineStart = line.localCharRange.location
                let lineEnd = lineStart + line.localCharRange.length
                let selStart = max(startChar, lineStart)
                let selEnd = min(endChar, lineEnd)

                if selStart < selEnd {
                    let lineAvailW = max(1, availableWidth - line.leftIndent - line.rightIndent)
                    var lineX = origin.x + line.leftIndent
                    if line.alignment == 1 {
                        lineX += (lineAvailW - line.width) / 2.0
                    } else if line.alignment == 2 {
                        lineX += lineAvailW - line.width
                    }

                    let effectiveLine: CTLine
                    if line.alignment == 3 && !line.isLast,
                       let justified = CTLineCreateJustifiedLine(line.ctLine, 1.0, Double(lineAvailW)) {
                        effectiveLine = justified
                    } else {
                        effectiveLine = line.ctLine
                    }

                    let x1 = CTLineGetOffsetForStringIndex(effectiveLine, selStart - lineStart, nil)
                    let x2 = CTLineGetOffsetForStringIndex(effectiveLine, selEnd - lineStart, nil)
                    rects.append(CGRect(
                        x: lineX + min(x1, x2),
                        y: curY,
                        width: max(2.0, abs(x2 - x1)),
                        height: line.height
                    ))
                }
            } else if line.paraIndex > targetParagraphIndex {
                break
            }
            curY += line.height + line.after
        }
        return rects
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

    /// 冻结区占可用正文区的最大比例：超出后该轴冻结降级为不冻结，避免正文被冻结区挤没
    public static let MAX_FROZEN_RATIO: CGFloat = 0.75

    /// 一帧内的冻结几何结果（文档坐标系，与 `viewport` 同一套坐标）
    public struct SheetFreezePlan: Sendable, Equatable {
        /// 工作表声明的冻结行/列数（已按表维度钳位）
        public let frozenRows: Int
        public let frozenColumns: Int
        /// 经视口占比保护后的有效冻结行/列数
        public let effectiveRows: Int
        public let effectiveColumns: Int
        /// 文档坐标系下的滚动量（viewport 原点小于 0 时按 0 处理）
        public let scrollX: CGFloat
        public let scrollY: CGFloat
        /// 冻结区左上角：等于表头右/下侧紧邻位置
        public let frozenOriginX: CGFloat
        public let frozenOriginY: CGFloat
        /// 冻结区在当前坐标系下的宽/高
        public let frozenDataWidth: CGFloat
        public let frozenDataHeight: CGFloat
        /// 冻结边界
        public let frozenRight: CGFloat
        public let frozenBottom: CGFloat
        /// 可滚动右/下边界
        public let bodyMaxRight: CGFloat
        public let bodyMaxBottom: CGFloat
        /// 表头左/上边界（文档坐标系下的固定表头起点）
        public let headerLeft: CGFloat
        public let headerTop: CGFloat

        /// 是否启用了任一轴的冻结
        public var hasFrozen: Bool { effectiveRows > 0 || effectiveColumns > 0 }
    }

    /// 单个绘制象限：行列范围、裁剪区域与内容平移量
    public struct SheetQuadrant: Sendable, Equatable {
        public let rowRange: Range<Int>
        public let columnRange: Range<Int>
        public let clip: CGRect
        public let translateX: CGFloat
        public let translateY: CGFloat
    }

    /// 计算冻结几何：按 X/Y 轴独立执行视口占比保护，两轴互不影响
    public static func resolveFreezePlan(
        frozenRows: Int,
        frozenColumns: Int,
        rowCount: Int,
        columnCount: Int,
        frozenDataWidth: CGFloat,
        frozenDataHeight: CGFloat,
        totalWidth: CGFloat,
        totalHeight: CGFloat,
        viewport: CGRect
    ) -> SheetFreezePlan {
        let scrollX = max(0, viewport.minX)
        let scrollY = max(0, viewport.minY)
        let frozenOriginX = sheetHeaderWidth + scrollX
        let frozenOriginY = sheetHeaderHeight + scrollY
        // 扣除表头后的可用正文区
        let availBodyW = max(0, viewport.width - sheetHeaderWidth)
        let availBodyH = max(0, viewport.height - sheetHeaderHeight)
        let rows = min(max(0, frozenRows), max(0, rowCount))
        let columns = min(max(0, frozenColumns), max(0, columnCount))
        let dataW = max(0, frozenDataWidth)
        let dataH = max(0, frozenDataHeight)
        // 高倍缩放或小窗口下冻结区可能占满视口，此时仅取消超限的那个轴
        let effectiveColumns = (columns == 0 || availBodyW <= 0 || dataW > availBodyW * MAX_FROZEN_RATIO) ? 0 : columns
        let effectiveRows = (rows == 0 || availBodyH <= 0 || dataH > availBodyH * MAX_FROZEN_RATIO) ? 0 : rows
        let effectiveWidth = effectiveColumns > 0 ? dataW : 0
        let effectiveHeight = effectiveRows > 0 ? dataH : 0
        return SheetFreezePlan(
            frozenRows: rows,
            frozenColumns: columns,
            effectiveRows: effectiveRows,
            effectiveColumns: effectiveColumns,
            scrollX: scrollX,
            scrollY: scrollY,
            frozenOriginX: frozenOriginX,
            frozenOriginY: frozenOriginY,
            frozenDataWidth: effectiveWidth,
            frozenDataHeight: effectiveHeight,
            frozenRight: frozenOriginX + effectiveWidth,
            frozenBottom: frozenOriginY + effectiveHeight,
            bodyMaxRight: min(totalWidth, viewport.maxX),
            bodyMaxBottom: min(totalHeight, viewport.maxY),
            headerLeft: scrollX,
            headerTop: scrollY
        )
    }

    /// 依据工作表冻结配置与当前视口计算冻结几何；冻结区尺寸取自 core 预计算的列/行前缀和
    public static func sheetFreezePlan(sheet: OfficeSheet, viewport: CGRect) -> SheetFreezePlan {
        let (colOffsets, rowOffsets, totalW, totalH) = computeSheetExtents(sheet)
        let frozenColumns = sheet.frozenColumns
        let frozenRows = sheet.frozenRows
        let dataW = frozenColumns > 0 && frozenColumns < colOffsets.count
            ? max(0, colOffsets[frozenColumns] - colOffsets[0])
            : 0
        let dataH = frozenRows > 0 && frozenRows < rowOffsets.count
            ? max(0, rowOffsets[frozenRows] - rowOffsets[0])
            : 0
        return resolveFreezePlan(
            frozenRows: frozenRows,
            frozenColumns: frozenColumns,
            rowCount: sheet.rowHeights.count,
            columnCount: sheet.columnWidths.count,
            frozenDataWidth: dataW,
            frozenDataHeight: dataH,
            totalWidth: totalW,
            totalHeight: totalH,
            viewport: viewport
        )
    }

    /// 切分最多 4 个互不重叠的绘制象限（从底到顶：滚动正文、冻结列、冻结行、交叉角）
    public static func sheetQuadrants(plan: SheetFreezePlan, rowCount: Int, columnCount: Int) -> [SheetQuadrant] {
        let rows = max(0, rowCount)
        let columns = max(0, columnCount)
        let frozenRows = min(plan.effectiveRows, rows)
        let frozenColumns = min(plan.effectiveColumns, columns)
        var quadrants: [SheetQuadrant] = []
        if frozenColumns < columns && frozenRows < rows {
            quadrants.append(SheetQuadrant(
                rowRange: frozenRows..<rows,
                columnRange: frozenColumns..<columns,
                clip: CGRect(
                    x: plan.frozenRight,
                    y: plan.frozenBottom,
                    width: max(0, plan.bodyMaxRight - plan.frozenRight),
                    height: max(0, plan.bodyMaxBottom - plan.frozenBottom)
                ),
                translateX: 0,
                translateY: 0
            ))
        }
        if frozenColumns > 0 && frozenRows < rows {
            quadrants.append(SheetQuadrant(
                rowRange: frozenRows..<rows,
                columnRange: 0..<frozenColumns,
                clip: CGRect(
                    x: plan.frozenOriginX,
                    y: plan.frozenBottom,
                    width: plan.frozenDataWidth,
                    height: max(0, plan.bodyMaxBottom - plan.frozenBottom)
                ),
                translateX: plan.scrollX,
                translateY: 0
            ))
        }
        if frozenRows > 0 && frozenColumns < columns {
            quadrants.append(SheetQuadrant(
                rowRange: 0..<frozenRows,
                columnRange: frozenColumns..<columns,
                clip: CGRect(
                    x: plan.frozenRight,
                    y: plan.frozenOriginY,
                    width: max(0, plan.bodyMaxRight - plan.frozenRight),
                    height: plan.frozenDataHeight
                ),
                translateX: 0,
                translateY: plan.scrollY
            ))
        }
        if frozenColumns > 0 && frozenRows > 0 {
            quadrants.append(SheetQuadrant(
                rowRange: 0..<frozenRows,
                columnRange: 0..<frozenColumns,
                clip: CGRect(
                    x: plan.frozenOriginX,
                    y: plan.frozenOriginY,
                    width: plan.frozenDataWidth,
                    height: plan.frozenDataHeight
                ),
                translateX: plan.scrollX,
                translateY: plan.scrollY
            ))
        }
        return quadrants
    }

    /// 把文档坐标下的检索高亮矩形按象限切分：滚动区严格裁剪在冻结区之外，绝不覆盖冻结区
    public static func clipSheetHighlight(
        _ rect: CGRect,
        plan: SheetFreezePlan,
        rowCount: Int,
        columnCount: Int
    ) -> [(rect: CGRect, clip: CGRect)] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        var pieces: [(rect: CGRect, clip: CGRect)] = []
        for quadrant in sheetQuadrants(plan: plan, rowCount: rowCount, columnCount: columnCount) {
            let moved = rect.offsetBy(dx: quadrant.translateX, dy: quadrant.translateY)
            let visible = moved.intersection(quadrant.clip)
            if visible.isNull || visible.width <= 0 || visible.height <= 0 { continue }
            pieces.append((rect: moved, clip: quadrant.clip))
        }
        return pieces
    }

    /// 计算检索跳转的目标滚动偏移（视图坐标）：命中冻结侧则该轴保持当前偏移，否则居中对齐到可滚动视口中心
    public static func sheetScrollTarget(
        docRect: CGRect,
        plan: SheetFreezePlan,
        clipSize: CGSize,
        contentOffset: CGPoint,
        contentSize: CGSize,
        zoom: CGFloat
    ) -> CGPoint {
        let maxX = max(0, contentSize.width - clipSize.width)
        let maxY = max(0, contentSize.height - clipSize.height)
        let centerX = docRect.midX * zoom
        let centerY = docRect.midY * zoom
        var targetX = contentOffset.x
        var targetY = contentOffset.y
        // 冻结列已在视口内固定可见，保持当前水平滚动位置不变
        let frozenWidthPx = (sheetHeaderWidth + plan.frozenDataWidth) * zoom
        let inFrozenColumn = plan.effectiveColumns > 0 && docRect.midX < sheetHeaderWidth + plan.frozenDataWidth
        if !inFrozenColumn {
            let scrollableCenterX = (frozenWidthPx + clipSize.width) / 2
            targetX = min(max(0, centerX - scrollableCenterX), maxX)
        }
        let frozenHeightPx = (sheetHeaderHeight + plan.frozenDataHeight) * zoom
        let inFrozenRow = plan.effectiveRows > 0 && docRect.midY < sheetHeaderHeight + plan.frozenDataHeight
        if !inFrozenRow {
            let scrollableCenterY = (frozenHeightPx + clipSize.height) / 2
            targetY = min(max(0, centerY - scrollableCenterY), maxY)
        }
        return CGPoint(x: targetX, y: targetY)
    }

    public static func drawSpreadsheet(
        in ctx: CGContext,
        sheet: OfficeSheet,
        styles: [OfficeCellStyle],
        viewport: CGRect
    ) {
        let (colOffsets, rowOffsets, totalW, totalH) = computeSheetExtents(sheet)
        let rowCount = sheet.rowHeights.count
        let columnCount = sheet.columnWidths.count
        let plan = sheetFreezePlan(sheet: sheet, viewport: viewport)

        ctx.saveGState()
        defer { ctx.restoreGState() }

        // 背景
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(viewport)

        let mergedCellFlags = sheet.geometry?.mergedCells ?? []
        // core 预计算的行起始索引：存在时按行区间二分遍历，避免每帧全表扫描
        let rowStarts = validRowStarts(sheet: sheet, rowCount: rowCount)

        // 1. 四象限正文绘制（从底到顶：滚动正文 → 冻结列 → 冻结行 → 交叉角）
        // 每象限独立 save → clip → 白底 → 单元格 → 网格线 → 合并单元格 → restore
        for quadrant in sheetQuadrants(plan: plan, rowCount: rowCount, columnCount: columnCount) {
            withClip(ctx, quadrant.clip) {
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(quadrant.clip)
                drawSheetQuadrantContent(
                    in: ctx,
                    sheet: sheet,
                    styles: styles,
                    quadrant: quadrant,
                    rowOffsets: rowOffsets,
                    colOffsets: colOffsets,
                    mergedCellFlags: mergedCellFlags,
                    rowStarts: rowStarts
                )
            }
        }

        // 2. 行列标头：可滚动区随内容滚动，冻结区锁定，左上角交汇块单独清理
        drawSheetHeaders(
            in: ctx,
            sheet: sheet,
            plan: plan,
            colOffsets: colOffsets,
            rowOffsets: rowOffsets,
            drawW: min(totalW, viewport.maxX),
            drawH: min(totalH, viewport.maxY),
            viewport: viewport
        )

        // 3. 冻结分割线：区别于普通网格线与表头分隔线的中性蓝灰
        if let divider = argbToCGColor(0xff9aa5b1) {
            ctx.setStrokeColor(divider)
            ctx.setLineWidth(1)
            ctx.beginPath()
            if plan.effectiveColumns > 0 {
                ctx.move(to: CGPoint(x: plan.frozenRight, y: plan.headerTop))
                ctx.addLine(to: CGPoint(x: plan.frozenRight, y: plan.bodyMaxBottom))
            }
            if plan.effectiveRows > 0 {
                ctx.move(to: CGPoint(x: plan.headerLeft, y: plan.frozenBottom))
                ctx.addLine(to: CGPoint(x: plan.bodyMaxRight, y: plan.frozenBottom))
            }
            ctx.strokePath()
        }
    }

    /// 裁剪 core 的 rowStarts 是否可用于按行遍历，不可用时返回 nil 走全表扫描回退
    private static func validRowStarts(sheet: OfficeSheet, rowCount: Int) -> [Int]? {
        guard let starts = sheet.geometry?.rowStarts, starts.count == rowCount + 1 else { return nil }
        var previous = 0
        for start in starts {
            if start < previous || start > sheet.cells.count { return nil }
            previous = start
        }
        return starts.filter { $0 <= sheet.cells.count }.count == starts.count ? starts : nil
    }

    /// 绘制单个象限内的单元格、网格线、合并单元格
    private static func drawSheetQuadrantContent(
        in ctx: CGContext,
        sheet: OfficeSheet,
        styles: [OfficeCellStyle],
        quadrant: SheetQuadrant,
        rowOffsets: [CGFloat],
        colOffsets: [CGFloat],
        mergedCellFlags: [Bool],
        rowStarts: [Int]?
    ) {
        let clip = quadrant.clip
        let tx = quadrant.translateX
        let ty = quadrant.translateY
        let rowCount = sheet.rowHeights.count
        let columnCount = sheet.columnWidths.count
        let firstRow = min(quadrant.rowRange.lowerBound, rowCount)
        let lastRow = min(quadrant.rowRange.upperBound, rowCount)
        let firstColumn = min(quadrant.columnRange.lowerBound, columnCount)
        let lastColumn = min(quadrant.columnRange.upperBound, columnCount)
        let gridColor = argbToCGColor(0xffdce1e5)

        // 1.1 普通单元格填充与文本
        for row in firstRow..<max(firstRow, lastRow) {
            let top = rowOffsets[row] + ty
            let bottom = rowOffsets[row + 1] + ty
            if bottom <= clip.minY || top >= clip.maxY { continue }
            for idx in cellIndices(row: row, rowStarts: rowStarts, cells: sheet.cells) {
                let cell = sheet.cells[idx]
                if idx < mergedCellFlags.count && mergedCellFlags[idx] { continue }
                // 无 rowStarts 回退全表遍历时仍按行号过滤，避免其它行单元格误绘到当前行
                if cell.row != row { continue }
                if cell.column < firstColumn || cell.column >= lastColumn { continue }
                if cell.column + 1 >= colOffsets.count { continue }
                let left = colOffsets[cell.column] + tx
                let right = colOffsets[cell.column + 1] + tx
                if right <= clip.minX || left >= clip.maxX { continue }
                let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                guard rect.width > 0 && rect.height > 0 else { continue }
                drawSpreadsheetCell(in: ctx, cell: cell, rect: rect, styles: styles)
            }
        }

        // 1.2 网格线（仅绘制象限内可见部分）
        if let gridColor {
            ctx.setStrokeColor(gridColor)
            ctx.setLineWidth(0.5)
            ctx.beginPath()
            for row in firstRow..<max(firstRow, lastRow) {
                let y = rowOffsets[row + 1] + ty
                if y < clip.minY || y > clip.maxY { continue }
                ctx.move(to: CGPoint(x: clip.minX, y: y))
                ctx.addLine(to: CGPoint(x: clip.maxX, y: y))
            }
            for column in firstColumn..<max(firstColumn, lastColumn) {
                let x = colOffsets[column + 1] + tx
                if x < clip.minX || x > clip.maxX { continue }
                ctx.move(to: CGPoint(x: x, y: clip.minY))
                ctx.addLine(to: CGPoint(x: x, y: clip.maxY))
            }
            ctx.strokePath()
        }

        // 1.3 合并单元格：利用 startRow/endRow 过滤，跨冻结边界的合并区域在各象限分别平移裁剪绘制
        if let g = sheet.geometry {
            for merge in g.mergeRects {
                if merge.endRow < firstRow || merge.startRow >= lastRow { continue }
                let rect = CGRect(
                    x: merge.left + sheetHeaderWidth + tx,
                    y: merge.top + sheetHeaderHeight + ty,
                    width: merge.right - merge.left,
                    height: merge.bottom - merge.top
                )
                guard rect.width > 0, rect.height > 0, rect.intersects(clip) else { continue }
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(rect)
                if merge.anchor >= 0 && merge.anchor < sheet.cells.count {
                    drawSpreadsheetCell(in: ctx, cell: sheet.cells[merge.anchor], rect: rect, styles: styles)
                }
                if let gridColor {
                    ctx.setStrokeColor(gridColor)
                    ctx.setLineWidth(0.5)
                    ctx.stroke(rect)
                }
            }
        }
    }

    /// 单行内要遍历的 cell 下标区间，未提供 rowStarts 时回退全表
    private static func cellIndices(row: Int, rowStarts: [Int]?, cells: [OfficeCell]) -> Range<Int> {
        guard let starts = rowStarts, row >= 0, row + 1 < starts.count else { return 0..<cells.count }
        let start = min(max(0, starts[row]), cells.count)
        let end = min(max(start, starts[row + 1]), cells.count)
        return start..<end
    }

    /// 在给定裁剪区域内执行绘制，退出时严格恢复图形状态
    private static func withClip(_ ctx: CGContext, _ rect: CGRect, _ body: () -> Void) {
        guard rect.width > 0, rect.height > 0 else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        body()
        ctx.restoreGState()
    }

    /// 绘制表头：可滚动段正常滚动，冻结段锁定，左上角交汇块保持干净
    private static func drawSheetHeaders(
        in ctx: CGContext,
        sheet: OfficeSheet,
        plan: SheetFreezePlan,
        colOffsets: [CGFloat],
        rowOffsets: [CGFloat],
        drawW: CGFloat,
        drawH: CGFloat,
        viewport: CGRect
    ) {
        let headerHeight = sheetHeaderHeight
        let headerWidth = sheetHeaderWidth
        let headerTop = plan.headerTop
        let headerLeft = plan.headerLeft
        let rowCount = sheet.rowHeights.count
        let columnCount = sheet.columnWidths.count
        let frozenColumns = min(plan.effectiveColumns, columnCount)
        let frozenRows = min(plan.effectiveRows, rowCount)
        let bodyRight = min(max(plan.bodyMaxRight, headerLeft), max(drawW, headerLeft))
        let bodyBottom = min(max(plan.bodyMaxBottom, headerTop), max(drawH, headerTop))
        let headerFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let headerColor = argbToNSColor(0xff52606d)
        let gridColor = argbToCGColor(0xffdce1e5)
        let headerBg = argbToCGColor(0xfff3f5f7)

        /// 顶部列头文本与分隔线
        func drawColumnHeader(_ column: Int, offsetX: CGFloat, clip: CGRect) {
            let left = colOffsets[column] + offsetX
            let width = colOffsets[column + 1] - colOffsets[column]
            guard width > 0 else { return }
            let rect = CGRect(x: left, y: headerTop, width: width, height: headerHeight)
            guard rect.intersects(clip) else { return }
            if let gridColor {
                ctx.setStrokeColor(gridColor)
                ctx.setLineWidth(0.5)
                ctx.stroke(rect)
            }
            drawCenteredSingleLine(in: ctx, text: columnLabel(for: column), font: headerFont, color: headerColor, rect: rect)
        }

        /// 左侧行头文本与分隔线
        func drawRowHeader(_ row: Int, offsetY: CGFloat, clip: CGRect) {
            let top = rowOffsets[row] + offsetY
            let height = rowOffsets[row + 1] - rowOffsets[row]
            guard height > 0 else { return }
            let cellRect = CGRect(x: headerLeft, y: top, width: headerWidth, height: height)
            guard cellRect.intersects(clip) else { return }
            if let gridColor {
                ctx.setStrokeColor(gridColor)
                ctx.setLineWidth(0.5)
                ctx.stroke(cellRect)
            }
            let textRect = CGRect(x: headerLeft, y: top, width: headerWidth, height: min(height, 32))
            drawCenteredSingleLine(in: ctx, text: "\(row + 1)", font: headerFont, color: headerColor, rect: textRect)
        }

        // 顶部列头底板：可滚动段 + 冻结段
        if let headerBg {
            ctx.setFillColor(headerBg)
            ctx.fill(CGRect(x: headerLeft, y: headerTop, width: max(0, bodyRight - headerLeft), height: headerHeight))
            if frozenColumns > 0 {
                ctx.fill(CGRect(x: plan.frozenOriginX, y: headerTop, width: plan.frozenDataWidth, height: headerHeight))
            }
        }
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1.0, y: -1.0)
        // 可滚动列头：[frozenRight..bodyRight]
        let scrollableColumnClip = CGRect(
            x: plan.frozenRight,
            y: headerTop,
            width: max(0, bodyRight - plan.frozenRight),
            height: headerHeight
        )
        withClip(ctx, scrollableColumnClip) {
            for column in frozenColumns..<max(frozenColumns, columnCount) {
                drawColumnHeader(column, offsetX: 0, clip: scrollableColumnClip)
            }
        }
        // 冻结列头：[frozenOriginX..frozenRight]，X 轴锁定
        if frozenColumns > 0 {
            let frozenColumnClip = CGRect(x: plan.frozenOriginX, y: headerTop, width: plan.frozenDataWidth, height: headerHeight)
            withClip(ctx, frozenColumnClip) {
                for column in 0..<frozenColumns {
                    drawColumnHeader(column, offsetX: plan.scrollX, clip: frozenColumnClip)
                }
            }
        }
        ctx.restoreGState()

        // 左侧行头底板：可滚动段 + 冻结段
        if let headerBg {
            ctx.setFillColor(headerBg)
            ctx.fill(CGRect(x: headerLeft, y: headerTop, width: headerWidth, height: max(0, bodyBottom - headerTop)))
            if frozenRows > 0 {
                ctx.fill(CGRect(x: headerLeft, y: plan.frozenOriginY, width: headerWidth, height: plan.frozenDataHeight))
            }
        }
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1.0, y: -1.0)
        // 可滚动行头：[frozenBottom..bodyBottom]
        let scrollableRowClip = CGRect(
            x: headerLeft,
            y: plan.frozenBottom,
            width: headerWidth,
            height: max(0, bodyBottom - plan.frozenBottom)
        )
        withClip(ctx, scrollableRowClip) {
            for row in frozenRows..<max(frozenRows, rowCount) {
                drawRowHeader(row, offsetY: 0, clip: scrollableRowClip)
            }
        }
        // 冻结行头：[frozenOriginY..frozenBottom]，Y 轴锁定
        if frozenRows > 0 {
            let frozenRowClip = CGRect(x: headerLeft, y: plan.frozenOriginY, width: headerWidth, height: plan.frozenDataHeight)
            withClip(ctx, frozenRowClip) {
                for row in 0..<frozenRows {
                    drawRowHeader(row, offsetY: plan.scrollY, clip: frozenRowClip)
                }
            }
        }
        ctx.restoreGState()

        // 左上角交汇块：覆盖 [scrollX..frozenOriginX, scrollY..frozenOriginY]
        if let headerBg {
            ctx.setFillColor(headerBg)
            ctx.fill(CGRect(x: plan.scrollX, y: plan.scrollY, width: headerWidth, height: headerHeight))
        }
        // 表头分隔线（固定贴在表头右/下边缘，不随内容滚动）
        if let separator = argbToCGColor(0xffbfc7cd) {
            ctx.setStrokeColor(separator)
            ctx.setLineWidth(0.75)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: headerLeft + headerWidth, y: plan.scrollY))
            ctx.addLine(to: CGPoint(x: headerLeft + headerWidth, y: viewport.maxY))
            ctx.move(to: CGPoint(x: plan.scrollX, y: headerTop + headerHeight))
            ctx.addLine(to: CGPoint(x: viewport.maxX, y: headerTop + headerHeight))
            ctx.strokePath()
        }
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
