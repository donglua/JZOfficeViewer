package cn.jingzhuan.lib.office;

import java.util.List;

/**
 * XLSX 二维网格选区模型：纯 Java 11 逻辑，零 {@code android.*} 依赖。
 *
 * <p>本类是设计文档 {@code docs/superpowers/specs/2026-11-18-xlsx-selection-copy-design.md}
 * §3.1 的参考实现，与 HarmonyOS {@code SheetSelectionModel.ts}、
 * macOS {@code SheetSelectionModel.swift} 保持逐条语义一致，
 * 并由 {@code scripts/tests/SheetSelectionChecks.java} 在无 Android SDK 的环境下验证：
 *
 * <ul>
 *   <li>坐标 {@link CellCoord} 与选区 {@link SheetSelection}：保留锚点/焦点，导出规范化边界；</li>
 *   <li>合并单元格不动点闭包扩张 {@link #resolve}：选区与任何合并区域相交即并入其完整范围；</li>
 *   <li>冻结窗格命中测试 {@link #hitTest}：按冻结边界消解滚动偏移，锁定轴不叠加滚动量；</li>
 *   <li>全选范围 {@link #allRange}：仅当工作表存在非空文本单元格时给出首个到末个可见单元格；</li>
 *   <li>TSV 格式化 {@link #selectedText}：跳过隐藏行列、合并从属位置留空、按 RFC 4180 转义。</li>
 * </ul>
 *
 * <p><b>坐标约定</b>：{@link SheetLayout.Axis#offsets} 已把外围标头（gutter）计入
 * {@code offsets[0]}，因此文档坐标含标头偏移。选区矩形 {@link #docRect} 与命中测试
 * {@link #hitTest} 均使用该坐标系，调用方只需保持"文档坐标"与"视图坐标"两套量纲不混用。
 *
 * <p><b>命中测试的单位约定</b>：{@link #hitTest} 的全部浮点入参处于<b>同一套视图数据坐标</b>——
 * 即调用方已把屏幕坐标除以当前缩放（{@code scale}），使 {@code 1} 单位等于 1 个文档单位。
 * 因此模型层无需知道缩放值，也不会因缩放引入舍入偏差。表头宽度/高度直接从
 * {@code layout.columns.offsets[0]} 与 {@code layout.rows.offsets[0]} 取得，天然与各端
 * 的 {@code HEADER_WIDTH} / {@code HEADER_HEIGHT} 常量同步（Android 为 42/20，
 * HarmonyOS 与 macOS 为 42/22）。
 */
public final class SheetSelectionModel {
    /** 拖拽到表格外缘继续扩选时钳位留白，避免落在末列/末行的开区间边界上。 */
    private static final float EDGE_EPSILON = 0.01f;
    /** TSV 单元格转义时需要用双引号包裹的字符集合判定。 */
    private static final String TSV_ESCAPE_CHARS = "\t\n\r\"";

    private SheetSelectionModel() {
    }

    // ------------------------------------------------------------------
    // 基础值类型
    // ------------------------------------------------------------------

    /** 工作表单元格坐标：{@code row} 与 {@code column} 均为 0 基。 */
    public static final class CellCoord {
        public final int row;
        public final int column;

        public CellCoord(int row, int column) {
            this.row = Math.max(0, row);
            this.column = Math.max(0, column);
        }

        @Override
        public boolean equals(Object other) {
            if (this == other) return true;
            if (!(other instanceof CellCoord)) return false;
            CellCoord coord = (CellCoord) other;
            return row == coord.row && column == coord.column;
        }

        @Override
        public int hashCode() {
            return row * 31 + column;
        }

        @Override
        public String toString() {
            return "CellCoord(" + row + ", " + column + ")";
        }
    }

    /**
     * 矩形选区：保留用户按下的锚点与浮动的焦点，支持反向拖选（焦点可以越过锚点）。
     *
     * <p>{@code startRow}/{@code startColumn}/{@code endRow}/{@code endColumn} 为
     * {@code anchor} 与 {@code focus} 张成的规范化闭区间边界，且已并入所有相交合并区域，
     * 因此可直接用于高亮绘制与 TSV 遍历，无需再次计算。
     */
    public static final class SheetSelection {
        public final CellCoord anchor;
        public final CellCoord focus;
        public final int startRow;
        public final int startColumn;
        public final int endRow;
        public final int endColumn;

        public SheetSelection(CellCoord anchor, CellCoord focus,
                              int startRow, int startColumn, int endRow, int endColumn) {
            this.anchor = anchor == null ? new CellCoord(0, 0) : anchor;
            this.focus = focus == null ? this.anchor : focus;
            this.startRow = Math.min(startRow, endRow);
            this.endRow = Math.max(startRow, endRow);
            this.startColumn = Math.min(startColumn, endColumn);
            this.endColumn = Math.max(startColumn, endColumn);
        }

        /** 单格选区（锚点与焦点重合）：仍按规范化边界记录，便于统一遍历。 */
        public SheetSelection(CellCoord coord) {
            this(coord, coord, coord == null ? 0 : coord.row, coord == null ? 0 : coord.column,
                coord == null ? 0 : coord.row, coord == null ? 0 : coord.column);
        }

        public int rowCount() {
            return endRow - startRow + 1;
        }

        public int columnCount() {
            return endColumn - startColumn + 1;
        }

        /** 是否恰好覆盖单个坐标（尚未做合并闭包扩张的原始判定）。 */
        public boolean isSingleCell() {
            return startRow == endRow && startColumn == endColumn;
        }

        public boolean covers(int row, int column) {
            return row >= startRow && row <= endRow && column >= startColumn && column <= endColumn;
        }

        /** 行索引是否落在选区行范围内，供外围行号标头联动高亮。 */
        public boolean containsRow(int row) {
            return row >= startRow && row <= endRow;
        }

        /** 列索引是否落在选区列范围内，供外围列标（A/B/C）联动高亮。 */
        public boolean containsColumn(int column) {
            return column >= startColumn && column <= endColumn;
        }

        @Override
        public boolean equals(Object other) {
            if (this == other) return true;
            if (!(other instanceof SheetSelection)) return false;
            SheetSelection range = (SheetSelection) other;
            return startRow == range.startRow && startColumn == range.startColumn
                && endRow == range.endRow && endColumn == range.endColumn;
        }

        @Override
        public int hashCode() {
            return ((startRow * 31 + startColumn) * 31 + endRow) * 31 + endColumn;
        }

        @Override
        public String toString() {
            return "SheetSelection(" + startRow + ", " + startColumn + " .. "
                + endRow + ", " + endColumn + ")";
        }
    }

    /** 文档坐标下的矩形（含外围标头偏移），左闭右开。 */
    public static final class CellRect {
        public final float left, top, right, bottom;

        public CellRect(float left, float top, float right, float bottom) {
            this.left = left;
            this.top = top;
            this.right = right;
            this.bottom = bottom;
        }

        public float width() {
            return right - left;
        }

        public float height() {
            return bottom - top;
        }

        public boolean isEmpty() {
            return right <= left || bottom <= top;
        }

        @Override
        public String toString() {
            return "CellRect(" + left + ", " + top + ", " + right + ", " + bottom + ")";
        }
    }

    // ------------------------------------------------------------------
    // 合并单元格不动点闭包扩张
    // ------------------------------------------------------------------

    /**
     * 由锚点与焦点解析出选区，并把所有与选区相交的合并区域并入边界，直到一轮遍历不再变化。
     *
     * <p>这是"不动点闭包"的关键：合并区域之间的相邻关系可能串联（A 并入 B 后 B 又与新并入的
     * 区域相交），因此必须循环到稳定为止，单轮遍历只能覆盖一层。闭包保证选区内不存在
     * 被合并区域"切开"的残缺单元格，高亮矩形与 TSV 网格才是用户看到的完整形状。
     *
     * @param sheet  工作表；{@code merges} 为空时退化为普通矩形选区
     * @param anchor 按下时的单元格
     * @param focus  当前浮动端单元格
     * @return 已扩张到不动点的选区；{@code anchor} 或 {@code focus} 为 null 时返回 {@code null}
     */
    public static SheetSelection resolve(SpreadsheetDocument.Sheet sheet, CellCoord anchor, CellCoord focus) {
        if (anchor == null || focus == null) return null;
        int startRow = Math.min(anchor.row, focus.row);
        int endRow = Math.max(anchor.row, focus.row);
        int startColumn = Math.min(anchor.column, focus.column);
        int endColumn = Math.max(anchor.column, focus.column);
        List<SpreadsheetDocument.CellRange> merges = sheet == null ? null : sheet.merges;
        if (merges != null && !merges.isEmpty()) {
            boolean changed = true;
            while (changed) {
                changed = false;
                for (int i = 0; i < merges.size(); i++) {
                    SpreadsheetDocument.CellRange merge = merges.get(i);
                    if (merge == null) continue;
                    // 与当前矩形不相交则跳过（闭区间相交判定）
                    if (merge.startRow > endRow || merge.endRow < startRow
                        || merge.startColumn > endColumn || merge.endColumn < startColumn) continue;
                    int nextStartRow = Math.min(startRow, merge.startRow);
                    int nextEndRow = Math.max(endRow, merge.endRow);
                    int nextStartColumn = Math.min(startColumn, merge.startColumn);
                    int nextEndColumn = Math.max(endColumn, merge.endColumn);
                    if (nextStartRow != startRow || nextEndRow != endRow
                        || nextStartColumn != startColumn || nextEndColumn != endColumn) {
                        startRow = nextStartRow;
                        endRow = nextEndRow;
                        startColumn = nextStartColumn;
                        endColumn = nextEndColumn;
                        changed = true;
                    }
                }
            }
        }
        return new SheetSelection(anchor, focus, startRow, startColumn, endRow, endColumn);
    }

    /**
     * 选区是否恰好等于一个逻辑单元格：单格，或与某个合并区域完全重合。
     *
     * <p>逻辑单格直接输出单元格文本（不输出网格），这样复制一个合并单元格得到的是
     * 一行文本而不是带尾随制表符的网格。
     */
    public static boolean isSingleLogicalCell(SpreadsheetDocument.Sheet sheet, SheetSelection selection) {
        if (selection == null) return false;
        if (selection.isSingleCell()) return true;
        List<SpreadsheetDocument.CellRange> merges = sheet == null ? null : sheet.merges;
        if (merges == null) return false;
        for (int i = 0; i < merges.size(); i++) {
            SpreadsheetDocument.CellRange merge = merges.get(i);
            if (merge == null) continue;
            if (merge.startRow == selection.startRow && merge.endRow == selection.endRow
                && merge.startColumn == selection.startColumn && merge.endColumn == selection.endColumn) {
                return true;
            }
        }
        return false;
    }

    /**
     * 覆盖给定坐标的合并区域。
     *
     * @return 未被任何合并区域覆盖时返回 {@code null}
     */
    public static SpreadsheetDocument.CellRange mergeAt(SpreadsheetDocument.Sheet sheet, int row, int column) {
        List<SpreadsheetDocument.CellRange> merges = sheet == null ? null : sheet.merges;
        if (merges == null) return null;
        for (int i = 0; i < merges.size(); i++) {
            SpreadsheetDocument.CellRange merge = merges.get(i);
            if (merge == null) continue;
            if (row >= merge.startRow && row <= merge.endRow
                && column >= merge.startColumn && column <= merge.endColumn) {
                return merge;
            }
        }
        return null;
    }

    // ------------------------------------------------------------------
    // 冻结窗格命中测试
    // ------------------------------------------------------------------

    /**
     * 把视图触点映射为单元格坐标，按冻结边界消解滚动偏移。
     *
     * <p>规则（设计文档 §3.1.2）：
     * <ol>
     *   <li>触点落在外围标头内直接返回 {@code null}；</li>
     *   <li>冻结列区内（{@code bodyX < frozenDataW}）X 轴不叠加滚动量，否则叠加 {@code scrollDataX}；</li>
     *   <li>Y 轴同理；</li>
     *   <li>换算后的数据坐标越界时，按 {@code clampToBounds} 决定返回 {@code null}
     *       还是钳位到表格边缘（拖拽扩选需要后者）。</li>
     * </ol>
     *
     * @param layout         当前工作表布局，提供 axes 与表头 gutter
     * @param effFrozenRows  本帧生效的冻结行数（已过视口占比保护）
     * @param effFrozenCols  本帧生效的冻结列数（已过视口占比保护）
     * @param frozenDataW    冻结列区宽度（视图数据坐标，未冻结时传 0）
     * @param frozenDataH    冻结行区高度（视图数据坐标，未冻结时传 0）
     * @param scrollDataX    水平滚动量（视图数据坐标，>= 0）
     * @param scrollDataY    垂直滚动量（视图数据坐标，>= 0）
     * @param viewX          触点 X（视图数据坐标，含标头原点）
     * @param viewY          触点 Y（视图数据坐标，含标头原点）
     * @param clampToBounds  越界时是否钳位到表格边缘
     * @return 命中的单元格坐标；越界且不钳位、或工作表为空时返回 {@code null}
     */
    public static CellCoord hitTest(SheetLayout layout, int effFrozenRows, int effFrozenCols,
                                    float frozenDataW, float frozenDataH,
                                    float scrollDataX, float scrollDataY,
                                    float viewX, float viewY, boolean clampToBounds) {
        if (layout == null || layout.columns.visible.length == 0 || layout.rows.visible.length == 0) return null;
        if (Float.isNaN(viewX) || Float.isNaN(viewY)) return null;
        float headerWidth = layout.columns.offsets[0];
        float headerHeight = layout.rows.offsets[0];
        // 触点落在外围行列标头内：不产生单元格命中，交给标头自身的联动高亮处理
        if (viewX < headerWidth || viewY < headerHeight) return null;
        float bodyX = viewX - headerWidth;
        float bodyY = viewY - headerHeight;

        float totalWidth = dataExtent(layout.columns);
        float totalHeight = dataExtent(layout.rows);

        float dataX = effFrozenCols > 0 && bodyX < frozenDataW ? bodyX : bodyX + Math.max(0f, scrollDataX);
        float dataY = effFrozenRows > 0 && bodyY < frozenDataH ? bodyY : bodyY + Math.max(0f, scrollDataY);

        if (dataX < 0f || dataX >= totalWidth || dataY < 0f || dataY >= totalHeight) {
            if (!clampToBounds) return null;
            dataX = Math.min(Math.max(0f, dataX), Math.max(0f, totalWidth - EDGE_EPSILON));
            dataY = Math.min(Math.max(0f, dataY), Math.max(0f, totalHeight - EDGE_EPSILON));
        }

        int row = axisIndex(layout.rows, dataY, headerHeight);
        int column = axisIndex(layout.columns, dataX, headerWidth);
        if (row < 0 || column < 0) return null;
        return new CellCoord(row, column);
    }

    /** 单个轴的数据总长（不含表头 gutter）。 */
    private static float dataExtent(SheetLayout.Axis axis) {
        return Math.max(0f, axis.offsets[axis.offsets.length - 1] - axis.offsets[0]);
    }

    /**
     * 在轴上二分定位 {@code data} 偏移对应的行列索引。
     *
     * <p>先把"数据偏移"还原成轴偏移（补回表头 gutter），再复用 {@link SheetLayout.Axis#first}
     * 的二分实现；超出可见范围时钳位到首/末可见索引，保证拖出边缘仍有稳定命中结果。
     */
    private static int axisIndex(SheetLayout.Axis axis, float data, float gutter) {
        int index = axis.first(gutter + data);
        if (index < 0) index = 0;
        if (index >= axis.visible.length) index = axis.visible.length - 1;
        return index < 0 ? -1 : axis.visible[index];
    }

    // ------------------------------------------------------------------
    // 全选范围
    // ------------------------------------------------------------------

    /**
     * 计算工作表的全选范围：首个可见单元格到末个可见单元格。
     *
     * <p>只有当工作表至少存在一个非空文本单元格时才可全选；否则 {@code selectAll()} 应当
     * 返回 {@code false}，避免对空白表建立无意义的整表选区。
     *
     * @return 不可全选或没有可见行列时返回 {@code null}
     */
    public static SheetSelection allRange(SpreadsheetDocument.Sheet sheet, SheetLayout layout) {
        if (sheet == null || layout == null) return null;
        if (layout.rows.visible.length == 0 || layout.columns.visible.length == 0) return null;
        if (!hasAnyText(sheet)) return null;
        int firstRow = layout.rows.visible[0];
        int lastRow = layout.rows.visible[layout.rows.visible.length - 1];
        int firstColumn = layout.columns.visible[0];
        int lastColumn = layout.columns.visible[layout.columns.visible.length - 1];
        CellCoord start = new CellCoord(firstRow, firstColumn);
        CellCoord end = new CellCoord(lastRow, lastColumn);
        // 整表范围几乎必然与合并区域相交，同样走闭包扩张以对齐边界语义
        return resolve(sheet, start, end);
    }

    /** 工作表是否至少存在一个非空文本单元格。 */
    private static boolean hasAnyText(SpreadsheetDocument.Sheet sheet) {
        List<SpreadsheetDocument.Cell> cells = sheet.cells;
        for (int i = 0; i < cells.size(); i++) {
            SpreadsheetDocument.Cell cell = cells.get(i);
            if (cell == null) continue;
            if (cell.text != null && !cell.text.isEmpty()) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------
    // 选区几何
    // ------------------------------------------------------------------

    /**
     * 选区在文档坐标下的外接矩形（含外围标头偏移），供渲染层绘制填充与描边。
     *
     * <p>合并闭包已把边界并入完整合并区域，因此矩形天然覆盖被合并的整块，不会切掉一半。
     *
     * @return 工作表为空或范围越界时返回 {@code null}
     */
    public static CellRect docRect(SheetLayout layout, SheetSelection selection) {
        if (layout == null || selection == null) return null;
        int rowCount = layout.rows.offsets.length - 1;
        int columnCount = layout.columns.offsets.length - 1;
        if (selection.startRow < 0 || selection.endRow >= rowCount
            || selection.startColumn < 0 || selection.endColumn >= columnCount) {
            return null;
        }
        return new CellRect(
            layout.columns.offsets[selection.startColumn],
            layout.rows.offsets[selection.startRow],
            layout.columns.offsets[selection.endColumn + 1],
            layout.rows.offsets[selection.endRow + 1]);
    }

    /**
     * 合并区域在文档坐标下的外接矩形，供渲染层按合并区域裁剪绘制。
     *
     * @return 合并区域越界时返回 {@code null}
     */
    public static CellRect mergeDocRect(SheetLayout layout, SpreadsheetDocument.CellRange merge) {
        if (layout == null || merge == null) return null;
        int rowCount = layout.rows.offsets.length - 1;
        int columnCount = layout.columns.offsets.length - 1;
        if (merge.startRow < 0 || merge.endRow >= rowCount
            || merge.startColumn < 0 || merge.endColumn >= columnCount) {
            return null;
        }
        return new CellRect(
            layout.columns.offsets[merge.startColumn],
            layout.rows.offsets[merge.startRow],
            layout.columns.offsets[merge.endColumn + 1],
            layout.rows.offsets[merge.endRow + 1]);
    }

    // ------------------------------------------------------------------
    // TSV 格式化
    // ------------------------------------------------------------------

    /**
     * 把选区导出为 Tab 分隔文本（TSV）。
     *
     * <p>输出规则（设计文档 §3.1.3）：
     * <ul>
     *   <li>逻辑单格（含单合并格）直接返回该单元格文本，不带任何制表符或换行；</li>
     *   <li>多格区域按行优先拼接：同行可见列之间以 {@code "\t"} 分隔，行之间以 {@code "\n"} 分隔；</li>
     *   <li>隐藏行（高度 {@code <= 0}）与隐藏列（宽度 {@code <= 0}）整条跳过，
     *       因此隐藏列不会被复制出空列；</li>
     *   <li>合并区域的非锚点位置输出空串，保持矩形网格的列数对齐；</li>
     *   <li>含制表符、换行或双引号的文本按 RFC 4180 用双引号包裹并把内部引号翻倍；</li>
     *   <li>整个选区没有任何非空文本时返回 {@code ""}，避免复制出纯空白网格。</li>
     * </ul>
     *
     * @return 无选区时返回 {@code ""}
     */
    public static String selectedText(SpreadsheetDocument.Sheet sheet, SheetLayout layout,
                                      SheetSelection selection) {
        if (sheet == null || layout == null || selection == null) return "";
        if (isSingleLogicalCell(sheet, selection)) {
            String text = cellTextAt(sheet, layout, selection.startRow, selection.startColumn);
            return text == null ? "" : text;
        }
        int rowCount = sheet.rowHeights == null ? 0 : sheet.rowHeights.length;
        int columnCount = sheet.columnWidths == null ? 0 : sheet.columnWidths.length;
        StringBuilder result = new StringBuilder();
        boolean hasContent = false;
        boolean firstRow = true;
        for (int row = selection.startRow; row <= selection.endRow; row++) {
            // 隐藏行整行跳过：既不出文本也不出换行，与 Excel 复制可见区域的行为一致
            if (row < 0 || row >= rowCount || sheet.rowHeights[row] <= 0f) continue;
            if (!firstRow) result.append('\n');
            boolean firstColumn = true;
            for (int column = selection.startColumn; column <= selection.endColumn; column++) {
                // 隐藏列整列跳过，且不计入制表符数量
                if (column < 0 || column >= columnCount || sheet.columnWidths[column] <= 0f) continue;
                if (!firstColumn) result.append('\t');
                firstColumn = false;
                SpreadsheetDocument.CellRange merge = mergeAt(sheet, row, column);
                if (merge != null && (row != merge.startRow || column != merge.startColumn)) {
                    // 合并区域的从属位置留空，保证网格矩形对齐
                    continue;
                }
                String text = cellTextAt(sheet, layout, row, column);
                String escaped = formatTsvCell(text);
                if (!escaped.isEmpty()) hasContent = true;
                result.append(escaped);
            }
            firstRow = false;
        }
        return hasContent ? result.toString() : "";
    }

    /**
     * TSV 单元格转义：仅当文本含制表符、换行、回车或双引号时按 RFC 4180 / Excel 规范包裹。
     *
     * @return 空文本返回 {@code ""}；{@code null} 同样按空文本处理
     */
    public static String formatTsvCell(String text) {
        if (text == null || text.isEmpty()) return "";
        boolean escape = false;
        for (int i = 0; i < text.length(); i++) {
            if (TSV_ESCAPE_CHARS.indexOf(text.charAt(i)) >= 0) {
                escape = true;
                break;
            }
        }
        if (!escape) return text;
        StringBuilder quoted = new StringBuilder(text.length() + 8);
        quoted.append('"');
        for (int i = 0; i < text.length(); i++) {
            char value = text.charAt(i);
            if (value == '"') quoted.append('"');
            quoted.append(value);
        }
        quoted.append('"');
        return quoted.toString();
    }

    /**
     * 查找指定坐标的单元格文本。
     *
     * <p>先按 {@code rowStarts} 对该行做二分定位，再在该行的稀疏单元格序列中线性扫描列；
     * 单行内的列数远小于整表单元格数，因此整体代价为 {@code O(log R + K)}。
     *
     * @return 该位置没有单元格时返回 {@code null}
     */
    public static String cellTextAt(SpreadsheetDocument.Sheet sheet, SheetLayout layout, int row, int column) {
        SpreadsheetDocument.Cell cell = cellAt(sheet, layout, row, column);
        return cell == null || cell.text == null ? null : cell.text;
    }

    /** 查找指定坐标的单元格对象，未命中返回 {@code null}。 */
    public static SpreadsheetDocument.Cell cellAt(SpreadsheetDocument.Sheet sheet, SheetLayout layout,
                                                  int row, int column) {
        if (sheet == null || layout == null || row < 0 || column < 0) return null;
        if (layout.rowStarts == null || row + 1 >= layout.rowStarts.length) return null;
        List<SpreadsheetDocument.Cell> cells = sheet.cells;
        int end = Math.min(layout.rowStarts[row + 1], cells.size());
        for (int i = Math.max(0, layout.firstCell(row, column)); i < end; i++) {
            SpreadsheetDocument.Cell cell = cells.get(i);
            if (cell == null) continue;
            if (cell.column == column) return cell;
            if (cell.column > column) break;
        }
        return null;
    }
}
