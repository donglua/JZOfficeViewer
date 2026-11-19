package cn.jingzhuan.lib.office;

import java.util.List;

/**
 * 纯 JVM 表格选区模型检查（无需 Android SDK / 设备）。
 *
 * <p>覆盖设计文档 §4.1 的全部断言：普通单元格与合并单元格闭包扩张、隐藏行列跳过、
 * 冻结窗格四象限命中测试、单格与多格 TSV 格式化（含 RFC 4180 转义与合并格留空）、
 * 空表 {@code allRange} 返回 {@code null}。本类是三端语义对齐的基准——
 * {@code scripts/tests/SheetSelectionChecks.ts} 与 Swift 测试必须给出相同结论。
 *
 * <p>编译与运行方式：
 *
 * <pre>
 * javac --release 11 -Xlint:all -Werror -d /tmp/jz-sheet-selection-checks \
 *   viewer/src/main/java/cn/jingzhuan/lib/office/OfficeDocument.java \
 *   viewer/src/main/java/cn/jingzhuan/lib/office/SpreadsheetDocument.java \
 *   viewer/src/main/java/cn/jingzhuan/lib/office/SheetLayout.java \
 *   viewer/src/main/java/cn/jingzhuan/lib/office/SheetSelectionModel.java \
 *   scripts/tests/SheetSelectionChecks.java
 * java -cp /tmp/jz-sheet-selection-checks cn.jingzhuan.lib.office.SheetSelectionChecks
 * </pre>
 */
public final class SheetSelectionChecks {
    /** 与各端渲染常量一致：表头宽 42、行头高 20（Android 取值）。 */
    private static final float HEADER_WIDTH = 42f;
    private static final float HEADER_HEIGHT = 20f;
    private static int checks = 0;

    private SheetSelectionChecks() {
    }

    private static void check(boolean condition, String message) {
        checks++;
        if (!condition) throw new AssertionError(message);
    }

    private static void checkEquals(Object actual, Object expected, String message) {
        checks++;
        boolean same = actual == null ? expected == null : actual.equals(expected);
        if (!same) throw new AssertionError(message + ": expected " + expected + ", actual " + actual);
    }

    private static void checkText(String actual, String expected, String message) {
        checks++;
        if (!expected.equals(actual)) {
            throw new AssertionError(message + ": expected <" + expected + ">, actual <" + actual + ">");
        }
    }

    // ------------------------------------------------------------------
    // 构造辅助
    // ------------------------------------------------------------------

    /**
     * 构造工作表：所有行高、列宽相同，按行列二维数组填充文本。
     *
     * @param grid    {@code grid[row][column]} 为该格文本，{@code null} 表示无单元格
     * @param rowH    每行高度
     * @param colW    每列宽度
     */
    private static SpreadsheetDocument.Sheet sheet(String[][] grid, float rowH, float colW) {
        SpreadsheetDocument.Sheet sheet = new SpreadsheetDocument.Sheet();
        int rowCount = grid.length;
        int columnCount = rowCount == 0 ? 0 : grid[0].length;
        sheet.rowHeights = new float[rowCount];
        for (int i = 0; i < rowCount; i++) sheet.rowHeights[i] = rowH;
        sheet.columnWidths = new float[columnCount];
        for (int i = 0; i < columnCount; i++) sheet.columnWidths[i] = colW;
        // 单元格必须按行优先、行内列递增的顺序追加，满足 SheetLayout 的 rowStarts 约定
        for (int row = 0; row < rowCount; row++) {
            for (int column = 0; column < columnCount; column++) {
                String text = grid[row][column];
                if (text == null) continue;
                sheet.cells.add(cell(row, column, text));
            }
        }
        return sheet;
    }

    private static SpreadsheetDocument.Cell cell(int row, int column, String text) {
        SpreadsheetDocument.Cell cell = new SpreadsheetDocument.Cell();
        cell.row = row;
        cell.column = column;
        cell.text = text;
        cell.numeric = !text.isEmpty() && text.matches("[-+]?\\d+(\\.\\d+)?");
        return cell;
    }

    private static SpreadsheetDocument.CellRange merge(int startRow, int startColumn, int endRow, int endColumn) {
        SpreadsheetDocument.CellRange range = new SpreadsheetDocument.CellRange();
        range.startRow = startRow;
        range.startColumn = startColumn;
        range.endRow = endRow;
        range.endColumn = endColumn;
        return range;
    }

    private static SheetLayout layout(SpreadsheetDocument.Sheet sheet) {
        return new SheetLayout(sheet, HEADER_WIDTH, HEADER_HEIGHT);
    }

    private static SheetSelectionModel.CellCoord at(int row, int column) {
        return new SheetSelectionModel.CellCoord(row, column);
    }

    public static void main(String[] args) {
        mergedClosureSingle();
        mergedClosureChain();
        reversedDragSelection();
        hiddenRowsAndColumnsSkipped();
        singleCellAndMergedCellText();
        tsvEscaping();
        allEmptySelectionReturnsEmpty();
        hitTestWithoutFreeze();
        hitTestFrozenColumns();
        hitTestFrozenRows();
        hitTestFrozenCorner();
        hitTestClampsAndHeaders();
        allRangeRequiresText();
        selectionHeaderLinkage();
        selectionDocRect();

        System.out.println("ALL SHEET SELECTION CHECKS PASSED (" + checks + " checks)");
    }

    // ------------------------------------------------------------------
    // 1. 合并单元格不动点闭包扩张
    // ------------------------------------------------------------------

    /** 单格落在合并区域内时，选区应扩张成整个合并区域。 */
    private static void mergedClosureSingle() {
        SpreadsheetDocument.Sheet sheet = sheet(new String[][] {
            {"A1", "B1", "C1"},
            {"A2", "B2", "C2"},
            {"A3", "B3", "C3"},
        }, 20f, 64f);
        sheet.merges.add(merge(0, 0, 1, 1)); // A1:B2
        SheetLayout layout = layout(sheet);

        // 锚点落在合并区域右下角从属位置，闭包必须把它们拉回完整区域
        SheetSelectionModel.SheetSelection selection =
            SheetSelectionModel.resolve(sheet, at(1, 1), at(1, 1));
        check(selection != null, "Closure: selection resolved");
        checkEquals(selection.startRow, 0, "Closure: startRow pulled up to 0");
        checkEquals(selection.startColumn, 0, "Closure: startColumn pulled up to 0");
        checkEquals(selection.endRow, 1, "Closure: endRow stays 1");
        checkEquals(selection.endColumn, 1, "Closure: endColumn stays 1");

        // 完全重合的单合并格视为逻辑单格
        check(SheetSelectionModel.isSingleLogicalCell(sheet, selection),
            "Closure: merged region alone is a single logical cell");

        SheetSelectionModel.CellRect rect = SheetSelectionModel.docRect(layout, selection);
        check(rect != null, "Closure: merged doc rect available");
        checkEquals(Math.round(rect.left), Math.round(HEADER_WIDTH), "Closure: rect left at header + 0");
        checkEquals(Math.round(rect.right), Math.round(HEADER_WIDTH + 128), "Closure: rect right spans 2 columns");
        checkEquals(Math.round(rect.top), Math.round(HEADER_HEIGHT), "Closure: rect top at header + 0");
        checkEquals(Math.round(rect.bottom), Math.round(HEADER_HEIGHT + 40), "Closure: rect bottom spans 2 rows");
    }

    /**
     * 闭包必须迭代到不动点：只有在合并区域<b>相互重叠</b>时才能观察出差别。
     *
     * <p>先说明为什么"相邻但不重叠"的合并区域串不起来：闭包只并入与当前矩形<b>相交</b>
     * 的区域，而合法 XLSX 的合并区域两两不重叠。设当前矩形为 {@code R0}、并入的不相交
     * 区域为 {@code A}，新矩形 {@code R1 = bbox(R0 ∪ A)}；{@code R1} 中不属于 {@code R0}
     * 的部分必然落在 {@code A} 覆盖的单元格内。若某区域 {@code C} 与 {@code R1 \ R0}
     * 相交，则 {@code C} 必与 {@code A} 重叠 —— 与"两两不重叠"矛盾。因此对合法数据，
     * 单轮遍历已经收敛，多轮循环没有可观察差异。
     *
     * <p>所以要真正锁定"不动点"语义，必须用<b>重叠</b>的合并列表（core 遇到畸形工作表
     * 或后续引入跨表引用时可能出现）。构造如下：
     * <ol>
     *   <li>{@code C1:E1} 先声明，{@code A1:C1} 后声明 —— 二者在 C1 处重叠；</li>
     *   <li>起选 {@code A1}：单轮扫描先遇到 C1:E1，与 A1 不相交而跳过；
     *       再遇到 A1:C1 并入，边界变成 A1:C1，本轮结束；</li>
     *   <li>单轮实现在此收手，结果停在 C1（{@code endColumn=2}）；</li>
     *   <li>不动点实现进入第二轮，发现新边界 A1:C1 与 C1:E1 相交并并入，
     *       最终稳定在 A1:E1（{@code endColumn=4}）。</li>
     * </ol>
     * 把 {@link SheetSelectionModel#resolve} 退化为单轮遍历时，本用例会以
     * {@code endColumn=2} 失败，因此它真正锁定了这一语义。
     */
    private static void mergedClosureChain() {
        SpreadsheetDocument.Sheet sheet = sheet(new String[][] {
            {"A1", "B1", "C1", "D1", "E1"},
            {"A2", "B2", "C2", "D2", "E2"},
            {"A3", "B3", "C3", "D3", "E3"},
        }, 20f, 64f);
        // 逆序 + 重叠：远端的 C1:E1 先声明，起选所在的 A1:C1 后声明，二者在 C1 重叠
        sheet.merges.add(merge(0, 2, 0, 4)); // C1:E1
        sheet.merges.add(merge(0, 0, 0, 2)); // A1:C1
        sheet.merges.add(merge(1, 0, 1, 1)); // A2:B2
        SheetLayout layout = layout(sheet);

        // 单轮实现会停在 A1:C1（endColumn=2）；不动点闭包必须扩到 A1:E1
        SheetSelectionModel.SheetSelection selection =
            SheetSelectionModel.resolve(sheet, at(0, 0), at(0, 0));
        checkEquals(selection.startRow, 0, "Chain: startRow 0");
        checkEquals(selection.startColumn, 0, "Chain: startColumn 0");
        checkEquals(selection.endRow, 0, "Chain: endRow 0");
        checkEquals(selection.endColumn, 4,
            "Chain: endColumn reaches E, which requires a second closure round");
        check(!SheetSelectionModel.isSingleLogicalCell(sheet, selection),
            "Chain: two chained merges are not a single logical cell");

        // 反向锚点：从 E1 起选同样收敛到 A1:E1，证明闭包与遍历方向无关
        SheetSelectionModel.SheetSelection fromFar =
            SheetSelectionModel.resolve(sheet, at(0, 4), at(0, 4));
        checkEquals(fromFar.startColumn, 0, "Chain: reverse start converges to A");
        checkEquals(fromFar.endColumn, 4, "Chain: reverse end stays at E");

        // 触到底部合并区域：闭包下扩到 A2:B2 的末行
        SheetSelectionModel.SheetSelection lower =
            SheetSelectionModel.resolve(sheet, at(1, 0), at(1, 0));
        checkEquals(lower.startRow, 1, "Chain: lower startRow 1");
        checkEquals(lower.endRow, 1, "Chain: lower endRow 1");
        checkEquals(lower.startColumn, 0, "Chain: lower startColumn 0");
        checkEquals(lower.endColumn, 1, "Chain: lower endColumn 1");

        // 未与任何合并区域相交的普通矩形保持原样
        SheetSelectionModel.SheetSelection plain =
            SheetSelectionModel.resolve(sheet, at(2, 4), at(2, 4));
        checkEquals(plain.startRow, 2, "Chain: plain startRow unchanged");
        checkEquals(plain.endRow, 2, "Chain: plain endRow unchanged");
        checkEquals(plain.startColumn, 4, "Chain: plain startColumn unchanged");
        checkEquals(plain.endColumn, 4, "Chain: plain endColumn unchanged");
        check(layout != null, "Chain: layout built");
    }

    /** 反向拖选（焦点越过锚点）必须导出规范化边界，并保留原始锚点/焦点。 */
    private static void reversedDragSelection() {
        SpreadsheetDocument.Sheet sheet = sheet(new String[][] {
            {"0,0", "0,1", "0,2"},
            {"1,0", "1,1", "1,2"},
            {"2,0", "2,1", "2,2"},
        }, 20f, 64f);

        SheetSelectionModel.SheetSelection selection =
            SheetSelectionModel.resolve(sheet, at(2, 2), at(0, 0));
        checkEquals(selection.startRow, 0, "Reverse: startRow normalised");
        checkEquals(selection.startColumn, 0, "Reverse: startColumn normalised");
        checkEquals(selection.endRow, 2, "Reverse: endRow normalised");
        checkEquals(selection.endColumn, 2, "Reverse: endColumn normalised");
        check(selection.anchor.equals(at(2, 2)), "Reverse: anchor preserved");
        check(selection.focus.equals(at(0, 0)), "Reverse: focus preserved");
        checkEquals(selection.rowCount(), 3, "Reverse: rowCount 3");
        checkEquals(selection.columnCount(), 3, "Reverse: columnCount 3");
        check(SheetSelectionModel.resolve(sheet, null, at(0, 0)) == null,
            "Reverse: null anchor yields null selection");
    }

    // ------------------------------------------------------------------
    // 2. 隐藏行列跳过
    // ------------------------------------------------------------------

    /** 隐藏列不进入 TSV，也不产生多余制表符；隐藏行不产生换行。 */
    private static void hiddenRowsAndColumnsSkipped() {
        SpreadsheetDocument.Sheet sheet = sheet(new String[][] {
            {"A1", "hidden", "C1"},
            {"hiddenRow", "hiddenRow", "hiddenRow"},
            {"A3", "hidden", "C3"},
        }, 20f, 64f);
        sheet.columnWidths[1] = 0f; // B 列隐藏
        sheet.rowHeights[1] = 0f;   // 第 2 行隐藏
        SheetLayout layout = layout(sheet);

        // 隐藏行列不出现在 axis.visible 中
        checkEquals(layout.rows.visible.length, 2, "Hidden: only 2 rows visible");
        checkEquals(layout.columns.visible.length, 2, "Hidden: only 2 columns visible");

        SheetSelectionModel.SheetSelection selection =
            SheetSelectionModel.resolve(sheet, at(0, 0), at(2, 2));
        checkText(SheetSelectionModel.selectedText(sheet, layout, selection), "A1\tC1\nA3\tC3",
            "Hidden: hidden row and column skipped entirely");

        // 隐藏列上的单元格仍可被直接寻址（模型层不做额外过滤）
        checkText(SheetSelectionModel.cellTextAt(sheet, layout, 0, 1), "hidden",
            "Hidden: hidden column cell remains addressable");
    }

    // ------------------------------------------------------------------
    // 3. 单格 / 合并格 / 多格 TSV
    // ------------------------------------------------------------------

    /** 单格与单合并格输出裸文本；多格输出矩形网格。 */
    private static void singleCellAndMergedCellText() {
        SpreadsheetDocument.Sheet sheet = sheet(new String[][] {
            {"标题", null, null},
            {"x", "y", "z"},
        }, 20f, 64f);
        sheet.merges.add(merge(0, 0, 0, 2)); // A1:C1
        SheetLayout layout = layout(sheet);

        // 单格：裸文本，不带制表符
        SheetSelectionModel.SheetSelection single =
            SheetSelectionModel.resolve(sheet, at(1, 1), at(1, 1));
        checkText(SheetSelectionModel.selectedText(sheet, layout, single), "y",
            "Text: single cell exports bare text");

        // 单合并格：同样裸文本
        SheetSelectionModel.SheetSelection merged =
            SheetSelectionModel.resolve(sheet, at(0, 1), at(0, 1));
        check(SheetSelectionModel.isSingleLogicalCell(sheet, merged),
            "Text: merged region is single logical cell");
        checkText(SheetSelectionModel.selectedText(sheet, layout, merged), "标题",
            "Text: merged cell exports anchor text without tabs");

        // 多格：合并区域从属位置留空，保持矩形对齐
        SheetSelectionModel.SheetSelection multi =
            SheetSelectionModel.resolve(sheet, at(0, 0), at(1, 2));
        checkText(SheetSelectionModel.selectedText(sheet, layout, multi), "标题\t\t\nx\ty\tz",
            "Text: multi-cell grid keeps merged followers empty");

        // 空选区语义
        checkText(SheetSelectionModel.selectedText(sheet, layout, null), "",
            "Text: null selection exports empty string");
    }

    /** 含制表符、换行、双引号的文本按 RFC 4180 转义。 */
    private static void tsvEscaping() {
        checkText(SheetSelectionModel.formatTsvCell(null), "", "Escape: null is empty");
        checkText(SheetSelectionModel.formatTsvCell(""), "", "Escape: empty stays empty");
        checkText(SheetSelectionModel.formatTsvCell("plain"), "plain", "Escape: plain text untouched");
        checkText(SheetSelectionModel.formatTsvCell("a\tb"), "\"a\tb\"", "Escape: tab forces quoting");
        checkText(SheetSelectionModel.formatTsvCell("a\nb"), "\"a\nb\"", "Escape: newline forces quoting");
        checkText(SheetSelectionModel.formatTsvCell("a\rb"), "\"a\rb\"", "Escape: carriage return forces quoting");
        checkText(SheetSelectionModel.formatTsvCell("say \"hi\""), "\"say \"\"hi\"\"\"",
            "Escape: inner quotes doubled");
        checkText(SheetSelectionModel.formatTsvCell("\""), "\"\"\"\"", "Escape: lone quote becomes four");

        SpreadsheetDocument.Sheet sheet = sheet(new String[][] {
            {"a\tb", "c"},
            {"d", "e"},
        }, 20f, 64f);
        SheetLayout layout = layout(sheet);
        SheetSelectionModel.SheetSelection selection =
            SheetSelectionModel.resolve(sheet, at(0, 0), at(1, 1));
        checkText(SheetSelectionModel.selectedText(sheet, layout, selection), "\"a\tb\"\tc\nd\te",
            "Escape: quoted cell keeps grid shape inside TSV");
    }

    /** 选区内全为空文本时返回空串，避免复制出纯空白网格。 */
    private static void allEmptySelectionReturnsEmpty() {
        SpreadsheetDocument.Sheet sheet = sheet(new String[][] {
            {"only", null, null},
            {null, null, null},
        }, 20f, 64f);
        SheetLayout layout = layout(sheet);
        // 只能选中右下角空白矩形：A1 含文本但不在范围内
        SheetSelectionModel.SheetSelection blank = new SheetSelectionModel.SheetSelection(
            at(1, 1), at(1, 2), 1, 1, 1, 2);
        checkText(SheetSelectionModel.selectedText(sheet, layout, blank), "",
            "Empty: all-blank selection exports empty string");

        // 显式空串单元格同样视为空
        SpreadsheetDocument.Sheet withEmpty = sheet(new String[][] {{"", ""}}, 20f, 64f);
        SheetLayout emptyLayout = layout(withEmpty);
        SheetSelectionModel.SheetSelection emptyRange = new SheetSelectionModel.SheetSelection(
            at(0, 0), at(0, 1), 0, 0, 0, 1);
        checkText(SheetSelectionModel.selectedText(withEmpty, emptyLayout, emptyRange), "",
            "Empty: explicit empty cells export empty string");
    }

    // ------------------------------------------------------------------
    // 4. 冻结窗格命中测试
    // ------------------------------------------------------------------

    /** 无冻结时命中测试等价于"文档坐标 = 视图坐标 + 滚动量"。 */
    private static void hitTestWithoutFreeze() {
        SpreadsheetDocument.Sheet sheet = sheet(new String[][] {
            {"0,0", "0,1", "0,2"},
            {"1,0", "1,1", "1,2"},
            {"2,0", "2,1", "2,2"},
        }, 20f, 64f);
        SheetLayout layout = layout(sheet);

        // 无滚动：视图坐标 (42+1, 20+1) 落在 A1
        SheetSelectionModel.CellCoord hit = SheetSelectionModel.hitTest(layout,
            0, 0, 0f, 0f, 0f, 0f, HEADER_WIDTH + 1f, HEADER_HEIGHT + 1f, false);
        check(hit != null && hit.row == 0 && hit.column == 0, "Hit: no-freeze maps to A1");

        // 滚动 64（一列）+ 20（一行）后，同一点应落在 B2
        hit = SheetSelectionModel.hitTest(layout,
            0, 0, 0f, 0f, 64f, 20f, HEADER_WIDTH + 1f, HEADER_HEIGHT + 1f, false);
        check(hit != null && hit.row == 1 && hit.column == 1, "Hit: scroll offset maps to B2");
    }

    /** 冻结列：冻结区内的 X 轴不叠加滚动量，滚动区的 X 轴照常叠加。 */
    private static void hitTestFrozenColumns() {
        SpreadsheetDocument.Sheet sheet = sheet(new String[][] {
            {"0,0", "0,1", "0,2", "0,3"},
            {"1,0", "1,1", "1,2", "1,3"},
        }, 20f, 64f);
        SheetLayout layout = layout(sheet);
        float frozenW = 64f; // 冻结第 0 列

        // 冻结区内：视图 X 落在冻结区，命中列 0（不叠加滚动）
        SheetSelectionModel.CellCoord hit = SheetSelectionModel.hitTest(layout,
            0, 1, frozenW, 0f, 100f, 0f, HEADER_WIDTH + 10f, HEADER_HEIGHT + 1f, false);
        check(hit != null && hit.column == 0, "Hit: frozen column ignores scroll");

        // 滚动区内：视图 X 越过冻结区宽度，数据 X = (bodyX - frozenW) + frozenW + scrollX = bodyX + scrollX
        hit = SheetSelectionModel.hitTest(layout,
            0, 1, frozenW, 0f, 64f, 0f, HEADER_WIDTH + frozenW + 1f, HEADER_HEIGHT + 1f, false);
        check(hit != null && hit.column == 2, "Hit: scrollable column adds scroll offset");
    }

    /** 冻结行：冻结区内的 Y 轴不叠加滚动量。 */
    private static void hitTestFrozenRows() {
        // 8 行 × 20 = 160 的数据高度，留足滚动余量
        SpreadsheetDocument.Sheet sheet = sheet(new String[][] {
            {"r0"}, {"r1"}, {"r2"}, {"r3"}, {"r4"}, {"r5"}, {"r6"}, {"r7"},
        }, 20f, 64f);
        SheetLayout layout = layout(sheet);
        float frozenH = 20f; // 冻结第 0 行
        float scrollY = 60f;

        // 冻结行内：bodyY = 1 < frozenH，dataY 不叠加滚动量
        SheetSelectionModel.CellCoord hit = SheetSelectionModel.hitTest(layout,
            1, 0, 0f, frozenH, 0f, scrollY, HEADER_WIDTH + 1f, HEADER_HEIGHT + 1f, false);
        check(hit != null && hit.row == 0, "Hit: frozen row ignores scroll");

        // 滚动区内：bodyY = frozenH + 1 = 21 ≥ frozenH，dataY = 21 + 60 = 81 → 第 4 行
        hit = SheetSelectionModel.hitTest(layout,
            1, 0, 0f, frozenH, 0f, scrollY, HEADER_WIDTH + 1f, HEADER_HEIGHT + frozenH + 1f, false);
        check(hit != null && hit.row == 4, "Hit: scrollable row adds scroll offset");
    }

    /** 双轴冻结时交叉角两轴都不叠加滚动量。 */
    private static void hitTestFrozenCorner() {
        // 10 行 × 20 = 200 高、8 列 × 64 = 512 宽，为双轴滚动留足余量
        String[][] grid = new String[10][8];
        for (int row = 0; row < grid.length; row++) {
            for (int column = 0; column < grid[row].length; column++) {
                grid[row][column] = row + "," + column;
            }
        }
        SpreadsheetDocument.Sheet sheet = sheet(grid, 20f, 64f);
        SheetLayout layout = layout(sheet);
        float frozenW = 64f, frozenH = 40f;
        float scrollX = 128f, scrollY = 60f;

        // 交叉角（左上）：命中 (1, 0)，两轴都锁定
        SheetSelectionModel.CellCoord corner = SheetSelectionModel.hitTest(layout,
            2, 1, frozenW, frozenH, scrollX, scrollY,
            HEADER_WIDTH + frozenW - 1f, HEADER_HEIGHT + frozenH - 1f, false);
        check(corner != null && corner.row == 1 && corner.column == 0,
            "Hit: frozen corner locks both axes");

        // 冻结列 + 滚动行：bodyY = frozenH + 1，dataY = 41 + 60 = 101 → 第 5 行
        SheetSelectionModel.CellCoord frozenColumn = SheetSelectionModel.hitTest(layout,
            2, 1, frozenW, frozenH, scrollX, scrollY,
            HEADER_WIDTH + 1f, HEADER_HEIGHT + frozenH + 1f, false);
        check(frozenColumn != null && frozenColumn.column == 0 && frozenColumn.row == 5,
            "Hit: frozen column with scrolled row");

        // 冻结行 + 滚动列：bodyX = 65，dataX = 65 + 128 = 193 → 第 3 列
        SheetSelectionModel.CellCoord frozenRow = SheetSelectionModel.hitTest(layout,
            2, 1, frozenW, frozenH, scrollX, scrollY,
            HEADER_WIDTH + frozenW + 1f, HEADER_HEIGHT + 1f, false);
        check(frozenRow != null && frozenRow.row == 0 && frozenRow.column == 3,
            "Hit: frozen row with scrolled column");

        // 纯滚动区：两轴都叠加滚动量
        SheetSelectionModel.CellCoord scroll = SheetSelectionModel.hitTest(layout,
            2, 1, frozenW, frozenH, scrollX, scrollY,
            HEADER_WIDTH + frozenW + 1f, HEADER_HEIGHT + frozenH + 1f, false);
        check(scroll != null && scroll.row == 5 && scroll.column == 3,
            "Hit: scrolled quadrant adds both offsets");
    }

    /** 标头内与越界：不钳位返回 null，钳位则贴到边缘。 */
    private static void hitTestClampsAndHeaders() {
        SpreadsheetDocument.Sheet sheet = sheet(new String[][] {
            {"0,0", "0,1"},
            {"1,0", "1,1"},
        }, 20f, 64f);
        SheetLayout layout = layout(sheet);

        check(SheetSelectionModel.hitTest(layout, 0, 0, 0f, 0f, 0f, 0f,
            HEADER_WIDTH - 1f, HEADER_HEIGHT + 1f, false) == null,
            "Clamp: column header yields no cell hit");
        check(SheetSelectionModel.hitTest(layout, 0, 0, 0f, 0f, 0f, 0f,
            HEADER_WIDTH + 1f, HEADER_HEIGHT - 1f, false) == null,
            "Clamp: row header yields no cell hit");
        check(SheetSelectionModel.hitTest(layout, 0, 0, 0f, 0f, 0f, 0f,
            HEADER_WIDTH + 1f, HEADER_HEIGHT + 1f, false) != null,
            "Clamp: body point hits");

        // 越过右下边界：不钳位返回 null，钳位贴到末行末列
        float farX = HEADER_WIDTH + 64f * 2f + 50f;
        float farY = HEADER_HEIGHT + 20f * 2f + 50f;
        check(SheetSelectionModel.hitTest(layout, 0, 0, 0f, 0f, 0f, 0f, farX, farY, false) == null,
            "Clamp: out-of-bounds without clamp returns null");
        SheetSelectionModel.CellCoord clamped = SheetSelectionModel.hitTest(layout,
            0, 0, 0f, 0f, 0f, 0f, farX, farY, true);
        check(clamped != null && clamped.row == 1 && clamped.column == 1,
            "Clamp: out-of-bounds clamps to last visible cell");

        // 滚动量大于表格尺寸时数据坐标同样越界，钳位后仍落在合法末格（绝不返回负索引）
        SheetSelectionModel.CellCoord overScrolled = SheetSelectionModel.hitTest(layout,
            0, 0, 0f, 0f, 200f, 200f, HEADER_WIDTH + 1f, HEADER_HEIGHT + 1f, true);
        check(overScrolled != null && overScrolled.row == 1 && overScrolled.column == 1,
            "Clamp: over-scrolled data coordinate clamps to last visible cell");

        // 钳位结果恒为合法坐标：非钳位调用在同样输入下返回 null，绝不产生负索引
        check(SheetSelectionModel.hitTest(layout, 0, 0, 0f, 0f, 200f, 200f,
            HEADER_WIDTH + 1f, HEADER_HEIGHT + 1f, false) == null,
            "Clamp: over-scrolled point without clamp returns null");
        SheetSelectionModel.CellCoord origin = SheetSelectionModel.hitTest(layout,
            0, 0, 0f, 0f, 0f, 0f, HEADER_WIDTH, HEADER_HEIGHT, true);
        check(origin != null && origin.row == 0 && origin.column == 0,
            "Clamp: body origin maps to the first cell");
    }

    // ------------------------------------------------------------------
    // 5. 全选范围
    // ------------------------------------------------------------------

    /** 空表 selectAll 返回 null；有文本时覆盖首个到末个可见单元格。 */
    private static void allRangeRequiresText() {
        // 全空表
        SpreadsheetDocument.Sheet blank = sheet(new String[][] {{null, null}, {null, null}}, 20f, 64f);
        check(SheetSelectionModel.allRange(blank, layout(blank)) == null,
            "All: empty sheet yields null range");

        // 只有空白文本的单元格也算空
        SpreadsheetDocument.Sheet spaces = sheet(new String[][] {{"", ""}}, 20f, 64f);
        check(SheetSelectionModel.allRange(spaces, layout(spaces)) == null,
            "All: empty-string cells do not enable select-all");

        // 有文本的表：覆盖全部可见行列
        SpreadsheetDocument.Sheet sheet = sheet(new String[][] {
            {"A1", "B1", "C1"},
            {"A2", "B2", "C2"},
        }, 20f, 64f);
        SheetSelectionModel.SheetSelection all = SheetSelectionModel.allRange(sheet, layout(sheet));
        check(all != null, "All: non-empty sheet yields range");
        checkEquals(all.startRow, 0, "All: startRow 0");
        checkEquals(all.startColumn, 0, "All: startColumn 0");
        checkEquals(all.endRow, 1, "All: endRow last visible");
        checkEquals(all.endColumn, 2, "All: endColumn last visible");
        checkText(SheetSelectionModel.selectedText(sheet, layout(sheet), all), "A1\tB1\tC1\nA2\tB2\tC2",
            "All: select-all TSV covers whole sheet");

        // 末列/末行隐藏时全选跟随可见范围收缩
        SpreadsheetDocument.Sheet hiddenTail = sheet(new String[][] {
            {"A1", "B1", "C1"},
            {"A2", "B2", "C2"},
        }, 20f, 64f);
        hiddenTail.columnWidths[2] = 0f;
        hiddenTail.rowHeights[1] = 0f;
        SheetLayout hiddenLayout = layout(hiddenTail);
        SheetSelectionModel.SheetSelection shrunk = SheetSelectionModel.allRange(hiddenTail, hiddenLayout);
        check(shrunk != null, "All: hidden tail still selectable");
        checkEquals(shrunk.endRow, 0, "All: hidden last row excluded");
        checkEquals(shrunk.endColumn, 1, "All: hidden last column excluded");
        checkText(SheetSelectionModel.selectedText(hiddenTail, hiddenLayout, shrunk), "A1\tB1",
            "All: select-all skips hidden trailing row/column");
    }

    // ------------------------------------------------------------------
    // 6. 标头联动高亮判定
    // ------------------------------------------------------------------

    /** 行列标头联动高亮的判定：选区行/列范围应被精确报告。 */
    private static void selectionHeaderLinkage() {
        SpreadsheetDocument.Sheet sheet = sheet(new String[][] {
            {"a", "b", "c", "d"},
            {"e", "f", "g", "h"},
            {"i", "j", "k", "l"},
        }, 20f, 64f);
        SheetSelectionModel.SheetSelection selection =
            SheetSelectionModel.resolve(sheet, at(1, 1), at(2, 2));

        check(selection.containsRow(1), "Header: row 1 highlighted");
        check(selection.containsRow(2), "Header: row 2 highlighted");
        check(!selection.containsRow(0), "Header: row 0 not highlighted");
        check(!selection.containsRow(3), "Header: row 3 not highlighted");

        check(selection.containsColumn(1), "Header: column B highlighted");
        check(selection.containsColumn(2), "Header: column C highlighted");
        check(!selection.containsColumn(0), "Header: column A not highlighted");
        check(!selection.containsColumn(3), "Header: column D not highlighted");

        check(selection.covers(1, 2), "Header: covered cell inside range");
        check(!selection.covers(0, 0), "Header: cell outside range not covered");
    }

    // ------------------------------------------------------------------
    // 7. 选区几何
    // ------------------------------------------------------------------

    /** 选区矩形应精确对齐行列前缀和，且越界时安全返回 null。 */
    private static void selectionDocRect() {
        SpreadsheetDocument.Sheet sheet = sheet(new String[][] {
            {"a", "b", "c"},
            {"d", "e", "f"},
            {"g", "h", "i"},
        }, 20f, 64f);
        SheetLayout layout = layout(sheet);

        SheetSelectionModel.SheetSelection selection =
            SheetSelectionModel.resolve(sheet, at(1, 1), at(2, 2));
        SheetSelectionModel.CellRect rect = SheetSelectionModel.docRect(layout, selection);
        check(rect != null, "Rect: resolved");
        checkEquals(Math.round(rect.left), Math.round(HEADER_WIDTH + 64f), "Rect: left at column B origin");
        checkEquals(Math.round(rect.right), Math.round(HEADER_WIDTH + 192f), "Rect: right past column C");
        checkEquals(Math.round(rect.top), Math.round(HEADER_HEIGHT + 20f), "Rect: top at row 2 origin");
        checkEquals(Math.round(rect.bottom), Math.round(HEADER_HEIGHT + 60f), "Rect: bottom past row 3");
        checkEquals(Math.round(rect.width()), 128, "Rect: width spans 2 columns");
        checkEquals(Math.round(rect.height()), 40, "Rect: height spans 2 rows");

        // 越界选区安全返回 null，避免渲染层数组越界
        SheetSelectionModel.SheetSelection outOfBounds = new SheetSelectionModel.SheetSelection(
            at(0, 0), at(9, 9), 0, 0, 9, 9);
        check(SheetSelectionModel.docRect(layout, outOfBounds) == null, "Rect: out-of-bounds returns null");
        check(SheetSelectionModel.docRect(layout, null) == null, "Rect: null selection returns null");

        // 合并区域的矩形与选区矩形使用同一套坐标
        SpreadsheetDocument.Sheet merged = sheet(new String[][] {
            {"a", "b"},
            {"c", "d"},
        }, 20f, 64f);
        SpreadsheetDocument.CellRange range = merge(0, 0, 0, 1);
        merged.merges.add(range);
        SheetLayout mergedLayout = layout(merged);
        SheetSelectionModel.CellRect mergeRect = SheetSelectionModel.mergeDocRect(mergedLayout, range);
        check(mergeRect != null, "Rect: merge rect resolved");
        checkEquals(Math.round(mergeRect.width()), 128, "Rect: merge rect spans 2 columns");
        check(SheetSelectionModel.mergeDocRect(mergedLayout, merge(0, 0, 9, 9)) == null,
            "Rect: out-of-bounds merge returns null");
    }
}
