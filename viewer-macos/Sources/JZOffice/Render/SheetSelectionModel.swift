import CoreGraphics
import Foundation

/// XLSX 二维网格选区模型：纯 Swift 值类型逻辑，零 AppKit 依赖。
///
/// 本类型是设计文档 `docs/superpowers/specs/2026-11-18-xlsx-selection-copy-design.md`
/// §3.1 的 macOS 实现，与 Android `SheetSelectionModel.java`、HarmonyOS `SheetSelectionModel.ts`
/// 保持逐条语义一致：合并单元格不动点闭包扩张、冻结窗格命中测试、全选范围、
/// 可见行列 TSV 导出与 RFC 4180 转义都按同一套断言实现。
///
/// 之所以把模型做成不依赖任何视图类型的值类型：
///
/// - 绘制（`CGElementDrawer`）与交互（`OfficePreviewView`）共用同一套几何判定，
///   避免"高亮位置"与"命中位置"各算一遍而逐渐漂移；
/// - 全部输入都是值，可以在 Swift Testing 里直接构造工作表与轴来验证冻结四象限语义，
///   无需真实窗口或设备；
/// - 与 Java 参考实现一一对应，三端回归时对照断言即可定位差异。
///
/// **坐标约定**：`SheetAxis.offsets` 已把外围标头（gutter）计入 `offsets[0]`，
/// 因此文档坐标含标头偏移；`docRect` 与绘制层的 `computeSheetExtents` 处于同一套文档坐标系。
///
/// **命中测试的单位约定**：`hitTest` 的全部浮点入参处于同一套**视图数据坐标**——
/// 即已经扣掉滚动量、但保留标头原点的屏幕坐标（屏幕像素除以缩放倍数）。
/// 模型自己按冻结边界叠加滚动量，因此调用方既不需要关心缩放，也不会因为缩放引入舍入偏差。
/// 表头宽度/高度直接从 `layout.columns.offsets[0]` 与 `layout.rows.offsets[0]` 取得，
/// 天然与各端的 `sheetHeaderWidth` / `sheetHeaderHeight` 常量（macOS 为 42/22）同步。
public enum SheetSelectionModel {
    /// 拖拽到表格外缘继续扩选时钳位留白，避免落在末列/末行的开区间边界上。
    public static let edgeEpsilon: CGFloat = 0.01

    // MARK: - 基础值类型

    /// 工作表单元格坐标：`row` 与 `column` 均为 0 基，负数构造时钳位到 0。
    public struct CellCoord: Equatable, Hashable, Sendable {
        public let row: Int
        public let column: Int

        public init(row: Int, column: Int) {
            self.row = max(0, row)
            self.column = max(0, column)
        }
    }

    /// 矩形选区：保留用户按下的锚点与浮动的焦点，支持反向拖选（焦点可以越过锚点）。
    ///
    /// `startRow` / `startColumn` / `endRow` / `endColumn` 为 `anchor` 与 `focus` 张成的
    /// 规范化闭区间边界，且已由 `resolve` 并入所有相交合并区域，
    /// 因此可以直接用于高亮绘制与 TSV 遍历，无需再次计算。
    public struct SheetSelection: Equatable, Sendable {
        public let anchor: CellCoord
        public let focus: CellCoord
        public let startRow: Int
        public let startColumn: Int
        public let endRow: Int
        public let endColumn: Int

        /// 规范化构造：`anchor` 为 `nil` 时退化为 `(0, 0)`，`focus` 为 `nil` 时跟随 `anchor`；
        /// 四个边界两两取小/取大，调用方即使传反也不会得到空区间。
        public init(
            anchor: CellCoord? = nil,
            focus: CellCoord? = nil,
            startRow: Int,
            startColumn: Int,
            endRow: Int,
            endColumn: Int
        ) {
            let resolvedAnchor = anchor ?? CellCoord(row: 0, column: 0)
            self.anchor = resolvedAnchor
            self.focus = focus ?? resolvedAnchor
            self.startRow = min(startRow, endRow)
            self.endRow = max(startRow, endRow)
            self.startColumn = min(startColumn, endColumn)
            self.endColumn = max(startColumn, endColumn)
        }

        /// 单格选区（锚点与焦点重合）：仍按规范化边界记录，便于统一遍历。
        public init(coord: CellCoord?) {
            let resolved = coord ?? CellCoord(row: 0, column: 0)
            self.init(
                anchor: resolved,
                focus: resolved,
                startRow: resolved.row,
                startColumn: resolved.column,
                endRow: resolved.row,
                endColumn: resolved.column
            )
        }

        public var rowCount: Int { endRow - startRow + 1 }

        public var columnCount: Int { endColumn - startColumn + 1 }

        /// 是否恰好覆盖单个坐标（尚未做合并闭包扩张的原始判定）。
        public var isSingleCell: Bool { startRow == endRow && startColumn == endColumn }

        public func covers(row: Int, column: Int) -> Bool {
            row >= startRow && row <= endRow && column >= startColumn && column <= endColumn
        }

        /// 行索引是否落在选区行范围内，供外围行号标头联动高亮。
        public func containsRow(_ row: Int) -> Bool {
            row >= startRow && row <= endRow
        }

        /// 列索引是否落在选区列范围内，供外围列标（A/B/C）联动高亮。
        public func containsColumn(_ column: Int) -> Bool {
            column >= startColumn && column <= endColumn
        }

        /// 与 Java 参考实现一致：相等性只看规范化边界，不比较锚点与焦点。
        ///
        /// 两个选区只要覆盖同一块矩形就是同一个选区，这使"反向拖选回到原位"不会产生假的不相等。
        public static func == (lhs: SheetSelection, rhs: SheetSelection) -> Bool {
            lhs.startRow == rhs.startRow && lhs.startColumn == rhs.startColumn
                && lhs.endRow == rhs.endRow && lhs.endColumn == rhs.endColumn
        }
    }

    /// 文档坐标下的矩形（含外围标头偏移），左闭右开。
    public struct CellRect: Equatable, Sendable {
        public let left: CGFloat
        public let top: CGFloat
        public let right: CGFloat
        public let bottom: CGFloat

        public init(left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) {
            self.left = left
            self.top = top
            self.right = right
            self.bottom = bottom
        }

        public var width: CGFloat { right - left }

        public var height: CGFloat { bottom - top }

        public var isEmpty: Bool { right <= left || bottom <= top }
    }

    // MARK: - 轴与布局（对齐 Java SheetLayout.Axis / SheetLayout 的公开子集）

    /// 单个轴的偏移前缀和与可见索引：`offsets[i]` 是第 i 条格线位置，`visible` 是可见行列号升序表。
    ///
    /// 之所以自带 `first(_:)` 二分而不是复用绘制层内部函数：模型必须能脱离绘制层单独验证，
    /// 同时保持与 `SheetLayout.Axis#first` 完全相同的插入点语义（返回值是 `visible` 的下标，
    /// 越过末尾时等于 `visible.count`，由调用方再钳位）。
    public struct SheetAxis: Equatable, Sendable {
        public let offsets: [CGFloat]
        public let visible: [Int]

        public init(offsets: [CGFloat], visible: [Int]) {
            self.offsets = offsets
            self.visible = visible
        }

        /// 用 core 预计算的 offsets/visible 构造，gutter 加在 `offsets[0]` 上。
        ///
        /// 越界索引会让二分查找访问 offsets 之外的元素，因此直接滤除；
        /// 这与 Java 参考实现一致，可容忍旧 core 传入脏索引。
        public init(precomputedOffsets: [CGFloat], precomputedVisible: [Int]?, gutter: CGFloat) {
            self.offsets = precomputedOffsets.map { $0 + gutter }
            let limit = max(0, precomputedOffsets.count - 1)
            self.visible = (precomputedVisible ?? []).filter { $0 >= 0 && $0 < limit }
        }

        /// 现场计算（旧 core 无 geometry 时使用）。
        ///
        /// 尺寸为负时按 0 处理，保证前缀和单调不减——与绘制层 `computeSheetExtents` 的回退分支
        /// 采用同一规则，避免"画出位置"与"命中位置"在两处对负数尺寸的处理上分叉。
        public init(sizes: [CGFloat], gutter: CGFloat) {
            var computedOffsets: [CGFloat] = [gutter]
            computedOffsets.reserveCapacity(sizes.count + 1)
            var computedVisible: [Int] = []
            computedVisible.reserveCapacity(sizes.count)
            for (index, size) in sizes.enumerated() {
                computedOffsets.append((computedOffsets.last ?? gutter) + max(0, size))
                if size > 0 { computedVisible.append(index) }
            }
            self.offsets = computedOffsets
            self.visible = computedVisible
        }

        /// 在轴上二分定位偏移所在的可见下标；返回值可能等于 `visible.count`（表示越过末尾）。
        public func first(_ position: CGFloat) -> Int {
            var low = 0
            var high = visible.count
            while low < high {
                let middle = (low + high) / 2
                let endIndex = visible[middle] + 1
                guard endIndex >= 0 && endIndex < offsets.count else {
                    high = middle
                    continue
                }
                if offsets[endIndex] <= position {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return low
        }
    }

    /// 一个工作表的模型侧布局：行轴、列轴与稀疏单元格的行起始下标。
    ///
    /// `rowStarts` 为空表示不可用（等价于 Java 侧 `layout.rowStarts == null`），
    /// 此时 `cellAt` 直接返回 `nil` 而不是退化成全表扫描，保持与参考实现一致。
    public struct SheetSelectionLayout: Sendable {
        public let rows: SheetAxis
        public let columns: SheetAxis
        public let rowStarts: [Int]

        public init(rows: SheetAxis, columns: SheetAxis, rowStarts: [Int]) {
            self.rows = rows
            self.columns = columns
            self.rowStarts = rowStarts
        }

        /// 依工作表几何构造布局：core 预计算可用时直接复用，不可用时现场计算。
        ///
        /// **前缀和必须与绘制层逐像素一致**：这里的分支条件、gutter 叠加方式与
        /// `CGElementDrawer.computeSheetExtents` 完全相同（长度匹配就用 core 预计算，
        /// 否则按尺寸累加），因此模型算出的高亮矩形一定落在网格线上，不会随两边实现漂移。
        /// `rowStarts` 单独校验：只在「单调不减且不越过单元格数量」时复用，
        /// 否则现场重算，避免损坏的 core 输出让 `cellAt` 定位到错误的行区间。
        public init(sheet: OfficeSheet, headerWidth: CGFloat, headerHeight: CGFloat) {
            let rowCount = sheet.rowHeights.count
            let columnCount = sheet.columnWidths.count
            if let geometry = sheet.geometry,
               geometry.columnOffsets.count == columnCount + 1,
               geometry.rowOffsets.count == rowCount + 1 {
                self.columns = SheetAxis(
                    precomputedOffsets: geometry.columnOffsets,
                    precomputedVisible: geometry.columnVisible,
                    gutter: headerWidth
                )
                self.rows = SheetAxis(
                    precomputedOffsets: geometry.rowOffsets,
                    precomputedVisible: geometry.rowVisible,
                    gutter: headerHeight
                )
                self.rowStarts = Self.isUsableRowStarts(geometry.rowStarts, rowCount: rowCount, cellCount: sheet.cells.count)
                    ? geometry.rowStarts
                    : Self.computeRowStarts(cells: sheet.cells, rowCount: rowCount)
            } else {
                self.columns = SheetAxis(sizes: sheet.columnWidths, gutter: headerWidth)
                self.rows = SheetAxis(sizes: sheet.rowHeights, gutter: headerHeight)
                self.rowStarts = Self.computeRowStarts(cells: sheet.cells, rowCount: rowCount)
            }
        }

        /// 行数（格线条数减一），越界判定统一用它而不是 `rowHeights.count`。
        public var rowCount: Int { max(0, rows.offsets.count - 1) }

        public var columnCount: Int { max(0, columns.offsets.count - 1) }

        /// 预计算 rowStarts 是否可直接使用：长度须为 `rowCount + 1`，单调不减且不越过单元格数量。
        ///
        /// 长度必须参与判定：长度不符时 `cellAt` 的 `row + 1 < starts.count` 会直接放弃定位，
        /// 表现为"整表查不到任何单元格"，因此这里主动回退到现场重算。
        private static func isUsableRowStarts(_ starts: [Int], rowCount: Int, cellCount: Int) -> Bool {
            guard starts.count == rowCount + 1 else { return false }
            var previous = 0
            for start in starts {
                if start < previous || start > cellCount { return false }
                previous = start
            }
            return true
        }

        /// 现场计算 rowStarts：要求 `cells` 按行优先、行内列递增（core 输出契约）。
        private static func computeRowStarts(cells: [OfficeCell], rowCount: Int) -> [Int] {
            guard rowCount > 0 else { return [] }
            var starts = [Int](repeating: 0, count: rowCount + 1)
            var next = 0
            for row in 0..<rowCount {
                starts[row] = next
                while next < cells.count && cells[next].row == row { next += 1 }
            }
            starts[rowCount] = next
            return starts
        }
    }

    // MARK: - 合并单元格不动点闭包扩张

    /// 由锚点与焦点解析出选区，并把所有与选区相交的合并区域并入边界，直到一轮遍历不再变化。
    ///
    /// 这是"不动点闭包"的关键：合并区域之间可能串联（A 并入 B 后 B 又与新并入的区域相交），
    /// 单轮遍历只能覆盖一层，必须循环到稳定为止。闭包保证选区内不存在被合并区域
    /// "切开"的残缺单元格，于是高亮矩形与 TSV 网格都是用户看到的完整形状。
    ///
    /// - Parameters:
    ///   - sheet: 工作表；`merges` 为空时退化为普通矩形选区
    ///   - anchor: 按下时的单元格
    ///   - focus: 当前浮动端单元格
    /// - Returns: 已扩张到不动点的选区；`anchor` 或 `focus` 为 `nil` 时返回 `nil`
    public static func resolve(
        sheet: OfficeSheet?,
        anchor: CellCoord?,
        focus: CellCoord?
    ) -> SheetSelection? {
        guard let anchor, let focus else { return nil }
        var startRow = min(anchor.row, focus.row)
        var endRow = max(anchor.row, focus.row)
        var startColumn = min(anchor.column, focus.column)
        var endColumn = max(anchor.column, focus.column)
        let merges = sheet?.merges ?? []
        if !merges.isEmpty {
            var changed = true
            while changed {
                changed = false
                for merge in merges {
                    // 与当前矩形不相交则跳过（闭区间相交判定）
                    if merge.startRow > endRow || merge.endRow < startRow
                        || merge.startColumn > endColumn || merge.endColumn < startColumn { continue }
                    let nextStartRow = min(startRow, merge.startRow)
                    let nextEndRow = max(endRow, merge.endRow)
                    let nextStartColumn = min(startColumn, merge.startColumn)
                    let nextEndColumn = max(endColumn, merge.endColumn)
                    if nextStartRow != startRow || nextEndRow != endRow
                        || nextStartColumn != startColumn || nextEndColumn != endColumn {
                        startRow = nextStartRow
                        endRow = nextEndRow
                        startColumn = nextStartColumn
                        endColumn = nextEndColumn
                        changed = true
                    }
                }
            }
        }
        return SheetSelection(
            anchor: anchor,
            focus: focus,
            startRow: startRow,
            startColumn: startColumn,
            endRow: endRow,
            endColumn: endColumn
        )
    }

    /// 选区是否恰好等于一个逻辑单元格：单格，或与某个合并区域完全重合。
    ///
    /// 逻辑单格直接输出单元格文本（不输出网格），这样复制一个合并单元格得到的是
    /// 一行文本而不是带尾随制表符的网格。
    public static func isSingleLogicalCell(sheet: OfficeSheet?, selection: SheetSelection?) -> Bool {
        guard let selection else { return false }
        if selection.isSingleCell { return true }
        for merge in sheet?.merges ?? [] {
            if merge.startRow == selection.startRow && merge.endRow == selection.endRow
                && merge.startColumn == selection.startColumn && merge.endColumn == selection.endColumn {
                return true
            }
        }
        return false
    }

    /// 覆盖给定坐标的合并区域；未被任何合并区域覆盖时返回 `nil`。
    public static func mergeAt(sheet: OfficeSheet?, row: Int, column: Int) -> OfficeCellRange? {
        for merge in sheet?.merges ?? [] {
            if row >= merge.startRow && row <= merge.endRow
                && column >= merge.startColumn && column <= merge.endColumn {
                return merge
            }
        }
        return nil
    }

    // MARK: - 冻结窗格命中测试

    /// 把视图触点映射为单元格坐标，按冻结边界消解滚动偏移。
    ///
    /// 规则（设计文档 §3.1.2）：
    ///
    /// 1. 触点落在外围标头内直接返回 `nil`（交给标头自身的联动高亮处理）；
    /// 2. 冻结列区内（`bodyX < frozenDataW`）X 轴不叠加滚动量，否则叠加 `scrollDataX`；
    /// 3. Y 轴同理；
    /// 4. 换算后的数据坐标越界时，按 `clampToBounds` 决定返回 `nil` 还是钳位到表格边缘
    ///    （拖拽扩选需要后者，否则拖出边界选区就停住）。
    ///
    /// - Parameters:
    ///   - layout: 当前工作表布局，提供两轴与标头 gutter
    ///   - effFrozenRows: 本帧生效的冻结行数（已过视口占比保护）
    ///   - effFrozenCols: 本帧生效的冻结列数（已过视口占比保护）
    ///   - frozenDataW: 冻结列区宽度（视图数据坐标，未冻结时传 0）
    ///   - frozenDataH: 冻结行区高度（视图数据坐标，未冻结时传 0）
    ///   - scrollDataX: 水平滚动量（视图数据坐标，>= 0）
    ///   - scrollDataY: 垂直滚动量（视图数据坐标，>= 0）
    ///   - viewX: 触点 X（视图数据坐标，含标头原点）
    ///   - viewY: 触点 Y（视图数据坐标，含标头原点）
    ///   - clampToBounds: 越界时是否钳位到表格边缘
    /// - Returns: 命中的单元格坐标；越界且不钳位、或工作表为空时返回 `nil`
    public static func hitTest(
        layout: SheetSelectionLayout?,
        effFrozenRows: Int,
        effFrozenCols: Int,
        frozenDataW: CGFloat,
        frozenDataH: CGFloat,
        scrollDataX: CGFloat,
        scrollDataY: CGFloat,
        viewX: CGFloat,
        viewY: CGFloat,
        clampToBounds: Bool
    ) -> CellCoord? {
        guard let layout, !layout.columns.visible.isEmpty, !layout.rows.visible.isEmpty else { return nil }
        if viewX.isNaN || viewY.isNaN { return nil }
        guard let headerWidth = layout.columns.offsets.first,
              let headerHeight = layout.rows.offsets.first else { return nil }
        // 触点落在标头内：非钳位态不产生单元格命中；钳位态（拖拽扩选）收敛到正文左/上缘
        if !clampToBounds && (viewX < headerWidth || viewY < headerHeight) { return nil }
        let bodyX = (clampToBounds ? max(headerWidth, viewX) : viewX) - headerWidth
        let bodyY = (clampToBounds ? max(headerHeight, viewY) : viewY) - headerHeight

        let totalWidth = dataExtent(layout.columns)
        let totalHeight = dataExtent(layout.rows)

        // 冻结区内锁定该轴，不叠加滚动量；滚动区按滚动量平移到工作表数据坐标
        var dataX = effFrozenCols > 0 && bodyX < frozenDataW ? bodyX : bodyX + max(0, scrollDataX)
        var dataY = effFrozenRows > 0 && bodyY < frozenDataH ? bodyY : bodyY + max(0, scrollDataY)

        if dataX < 0 || dataX >= totalWidth || dataY < 0 || dataY >= totalHeight {
            if !clampToBounds { return nil }
            dataX = min(max(0, dataX), max(0, totalWidth - edgeEpsilon))
            dataY = min(max(0, dataY), max(0, totalHeight - edgeEpsilon))
        }

        guard let column = axisIndex(layout.columns, data: dataX, gutter: headerWidth),
              let row = axisIndex(layout.rows, data: dataY, gutter: headerHeight) else { return nil }
        return CellCoord(row: row, column: column)
    }

    /// 单个轴的数据总长（不含表头 gutter）。
    private static func dataExtent(_ axis: SheetAxis) -> CGFloat {
        guard let first = axis.offsets.first, let last = axis.offsets.last else { return 0 }
        return max(0, last - first)
    }

    /// 在轴上二分定位数据偏移对应的行列号。
    ///
    /// 先把"数据偏移"还原成轴偏移（补回表头 gutter）再复用 `SheetAxis.first` 的二分；
    /// 越过可见范围时钳位到首/末可见索引，保证拖出边缘仍有稳定命中结果。
    private static func axisIndex(_ axis: SheetAxis, data: CGFloat, gutter: CGFloat) -> Int? {
        guard !axis.visible.isEmpty else { return nil }
        var index = axis.first(gutter + data)
        if index < 0 { index = 0 }
        if index >= axis.visible.count { index = axis.visible.count - 1 }
        guard index >= 0 && index < axis.visible.count else { return nil }
        return axis.visible[index]
    }

    // MARK: - 全选范围

    /// 计算工作表的全选范围：首个可见单元格到末个可见单元格。
    ///
    /// 只有当工作表至少存在一个非空文本单元格时才可全选，否则 `selectAll()` 应当返回
    /// `false`，避免对空白表建立无意义的整表选区（设计文档 §3.1.3）。
    ///
    /// - Returns: 不可全选或没有可见行列时返回 `nil`
    public static func allRange(sheet: OfficeSheet?, layout: SheetSelectionLayout?) -> SheetSelection? {
        guard let sheet, let layout else { return nil }
        guard !layout.rows.visible.isEmpty, !layout.columns.visible.isEmpty else { return nil }
        guard hasAnyText(sheet) else { return nil }
        guard let firstRow = layout.rows.visible.first,
              let lastRow = layout.rows.visible.last,
              let firstColumn = layout.columns.visible.first,
              let lastColumn = layout.columns.visible.last else { return nil }
        // 整表范围几乎必然与合并区域相交，同样走闭包扩张以对齐边界语义
        return resolve(
            sheet: sheet,
            anchor: CellCoord(row: firstRow, column: firstColumn),
            focus: CellCoord(row: lastRow, column: lastColumn)
        )
    }

    /// 工作表是否至少存在一个非空文本单元格。
    private static func hasAnyText(_ sheet: OfficeSheet) -> Bool {
        sheet.cells.contains { !$0.text.isEmpty }
    }

    // MARK: - 选区几何

    /// 选区在文档坐标下的外接矩形（含外围标头偏移），供渲染层绘制填充与描边。
    ///
    /// 合并闭包已把边界并入完整合并区域，因此矩形天然覆盖被合并的整块，不会切掉一半。
    /// 越界时返回 `nil` 而不是数组越界崩溃，渲染层据此跳过绘制。
    public static func docRect(layout: SheetSelectionLayout?, selection: SheetSelection?) -> CellRect? {
        guard let layout, let selection else { return nil }
        let rowCount = layout.rowCount
        let columnCount = layout.columnCount
        if selection.startRow < 0 || selection.endRow >= rowCount
            || selection.startColumn < 0 || selection.endColumn >= columnCount {
            return nil
        }
        return CellRect(
            left: layout.columns.offsets[selection.startColumn],
            top: layout.rows.offsets[selection.startRow],
            right: layout.columns.offsets[selection.endColumn + 1],
            bottom: layout.rows.offsets[selection.endRow + 1]
        )
    }

    /// 合并区域在文档坐标下的外接矩形，供渲染层按合并区域裁剪绘制；越界时返回 `nil`。
    public static func mergeDocRect(layout: SheetSelectionLayout?, merge: OfficeCellRange?) -> CellRect? {
        guard let layout, let merge else { return nil }
        let rowCount = layout.rowCount
        let columnCount = layout.columnCount
        if merge.startRow < 0 || merge.endRow >= rowCount
            || merge.startColumn < 0 || merge.endColumn >= columnCount {
            return nil
        }
        return CellRect(
            left: layout.columns.offsets[merge.startColumn],
            top: layout.rows.offsets[merge.startRow],
            right: layout.columns.offsets[merge.endColumn + 1],
            bottom: layout.rows.offsets[merge.endRow + 1]
        )
    }

    // MARK: - TSV 格式化

    /// 把选区导出为 Tab 分隔文本（TSV）。
    ///
    /// 输出规则（设计文档 §3.1.3）：
    ///
    /// - 逻辑单格（含单合并格）直接返回该单元格文本，不带任何制表符或换行；
    /// - 多格区域按行优先拼接：同行可见列之间以 `"\t"` 分隔，行之间以 `"\n"` 分隔；
    /// - 隐藏行（高度 `<= 0`）与隐藏列（宽度 `<= 0`）整条跳过，因此隐藏列不会被复制成空列，
    ///   也不会留下多余的制表符；
    /// - 合并区域的非锚点位置输出空串，保持矩形网格的列数对齐；
    /// - 含制表符、换行、回车或双引号的文本按 RFC 4180 用双引号包裹并把内部引号翻倍；
    /// - 整个选区没有任何非空文本时返回 `""`，避免复制出纯空白网格。
    ///
    /// - Returns: 无选区时返回 `""`
    public static func selectedText(
        sheet: OfficeSheet?,
        layout: SheetSelectionLayout?,
        selection: SheetSelection?
    ) -> String {
        guard let sheet, let layout, let selection else { return "" }
        if isSingleLogicalCell(sheet: sheet, selection: selection) {
            return cellTextAt(sheet: sheet, layout: layout, row: selection.startRow, column: selection.startColumn) ?? ""
        }
        let rowCount = sheet.rowHeights.count
        let columnCount = sheet.columnWidths.count
        var result = ""
        var hasContent = false
        var firstRow = true
        for row in selection.startRow...max(selection.startRow, selection.endRow) {
            // 隐藏行整行跳过：既不出文本也不出换行，与 Excel 复制可见区域的行为一致
            if row < 0 || row >= rowCount || sheet.rowHeights[row] <= 0 { continue }
            if !firstRow { result.append("\n") }
            var firstColumn = true
            for column in selection.startColumn...max(selection.startColumn, selection.endColumn) {
                // 隐藏列整列跳过，且不计入制表符数量
                if column < 0 || column >= columnCount || sheet.columnWidths[column] <= 0 { continue }
                if !firstColumn { result.append("\t") }
                firstColumn = false
                if let merge = mergeAt(sheet: sheet, row: row, column: column),
                   row != merge.startRow || column != merge.startColumn {
                    // 合并区域的从属位置留空，保证网格矩形对齐
                    continue
                }
                let escaped = formatTsvCell(cellTextAt(sheet: sheet, layout: layout, row: row, column: column))
                if !escaped.isEmpty { hasContent = true }
                result.append(escaped)
            }
            firstRow = false
        }
        return hasContent ? result : ""
    }

    /// TSV 单元格转义：仅当文本含制表符、换行、回车或双引号时按 RFC 4180 / Excel 规范包裹。
    ///
    /// 判定与改写都按 **Unicode 标量**遍历，而不是按 `Character` 字形簇遍历：
    /// Swift 会把 `"\r\n"` 聚成单个字形簇，用字形簇比较 `== "\r"` 会漏判回车，
    /// 导致含 CRLF 的单元格不被引号包裹、复制出的 TSV 被下游解析成两行。
    /// 按标量遍历与 Java 参考实现的逐 `char` 扫描完全等价。
    ///
    /// - Returns: 空文本或 `nil` 返回 `""`
    public static func formatTsvCell(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        var needsQuote = false
        for scalar in text.unicodeScalars {
            if scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\"" {
                needsQuote = true
                break
            }
        }
        if !needsQuote { return text }
        var quoted = "\""
        quoted.reserveCapacity(text.unicodeScalars.count + 8)
        for scalar in text.unicodeScalars {
            if scalar == "\"" { quoted.append("\"") }
            quoted.unicodeScalars.append(scalar)
        }
        quoted.append("\"")
        return quoted
    }

    /// 查找指定坐标的单元格文本；该位置没有单元格时返回 `nil`（空文本单元格返回 `""`）。
    public static func cellTextAt(
        sheet: OfficeSheet?,
        layout: SheetSelectionLayout?,
        row: Int,
        column: Int
    ) -> String? {
        cellAt(sheet: sheet, layout: layout, row: row, column: column)?.text
    }

    /// 查找指定坐标的单元格对象，未命中返回 `nil`。
    ///
    /// 先按 `rowStarts` 定位到该行区间，再在行内按列号二分，整体代价为 `O(log R + log K)`
    /// （Java 参考实现用线性扫描，这里借用同一 `rowStarts` 契约改用二分，结果完全一致）。
    public static func cellAt(
        sheet: OfficeSheet?,
        layout: SheetSelectionLayout?,
        row: Int,
        column: Int
    ) -> OfficeCell? {
        guard let sheet, let layout, row >= 0, column >= 0 else { return nil }
        let starts = layout.rowStarts
        guard !starts.isEmpty, row + 1 < starts.count else { return nil }
        let lower = max(0, min(starts[row], sheet.cells.count))
        let upper = max(lower, min(starts[row + 1], sheet.cells.count))
        var low = lower
        var high = upper
        while low < high {
            let middle = (low + high) / 2
            let cell = sheet.cells[middle]
            if cell.row != row {
                // 行区间与行号不一致说明 rowStarts 与单元格序列不同源，放弃定位而不是给出错格
                return nil
            }
            if cell.column < column {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low < upper else { return nil }
        let cell = sheet.cells[low]
        return (cell.row == row && cell.column == column) ? cell : nil
    }
}
