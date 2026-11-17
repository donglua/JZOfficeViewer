package cn.jingzhuan.lib.office;

import android.graphics.Matrix;
import android.text.StaticLayout;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * 把 {@link OfficeRenderer} 的排版结果与 {@link OfficeDocument} 模型桥接为
 * {@link TextSelectionModel.DocumentTextLayout}，供选区内核做命中测试、高亮与文本提取。
 *
 * <p>本类只做坐标与字符索引换算，不参与绘制；所有行几何直接复用
 * {@link StaticLayout}，因此高亮与命中和实际渲染完全一致（“所见即所选”）。
 *
 * <p><b>块索引约定</b>：块按文档阅读顺序编号（{@code 0 .. n-1}），
 * 一个 DOCX 正文元素/表格单元格或 PPTX 文本框各占一个块；
 * 表格按行优先遍历，顺序与 {@link OfficeRenderer} 构造 {@code Element.texts} 的遍历序一致。
 * PPTX 远端页先用轻量占位块参与全选与文本提取，页滚入视口排版后由
 * {@link #ensurePageLayout} 补充行几何，{@code blockIndex} 保持不变。
 */
final class AndroidTextLayoutBuilder {
    /** 退化几何兜底尺寸，避免生成零面积外接矩形。 */
    private static final float MIN_BLOCK_SIZE = 1f;
    /** PPTX 幻灯片之间的文档流间距，与 {@link OfficeRenderer#layout} 保持一致。 */
    private static final float PAGE_GAP = 16f;

    private AndroidTextLayoutBuilder() {
    }

    /**
     * 由文档模型与排版结果构建全文档文本索引。
     *
     * <p>DOCX 直接复用已完整排版的 {@code pages.get(0)}；PPTX 逐页处理，
     * 已排版页构建完整行几何，未排版页构建仅含纯文本的占位块；
     * XLSX 不参与自由划词，返回空布局。
     */
    static TextSelectionModel.DocumentTextLayout build(OfficeDocument document, OfficeRenderer renderer) {
        List<TextSelectionModel.TextBlockLayout> blocks = new ArrayList<>();
        if (document == null) return new TextSelectionModel.DocumentTextLayout(blocks);
        if (document.kind == OfficeDocument.Kind.DOCX) {
            blocks.addAll(pageBlocks(document, renderer, 0, 0, true));
        } else if (document.kind == OfficeDocument.Kind.PPTX) {
            int baseBlockIndex = 0;
            for (int pageIndex = 0; pageIndex < document.pages.size(); pageIndex++) {
                List<TextSelectionModel.TextBlockLayout> page = pageBlocks(document, renderer, pageIndex,
                    baseBlockIndex, true);
                blocks.addAll(page);
                baseBlockIndex += page.size();
            }
        }
        return new TextSelectionModel.DocumentTextLayout(blocks);
    }

    /**
     * PPTX 某页进入视口排版后，把该页的轻量占位块升级为含 {@link StaticLayout} 行几何的完整布局。
     *
     * <p>占位块与完整块由同一遍历函数 {@link #pageBlocks} 生成，因此块顺序严格对齐，
     * 升级只替换 {@code bounds}、{@code transform} 与 {@code lines}，不改变 {@code blockIndex}。
     */
    static void ensurePageLayout(TextSelectionModel.DocumentTextLayout target, int pageIndex,
                                 OfficeDocument document, OfficeRenderer renderer) {
        if (target == null || document == null || renderer == null) return;
        if (document.kind != OfficeDocument.Kind.PPTX) return;
        if (pageIndex < 0 || pageIndex >= renderer.pages.size()) return;
        if (!renderer.pages.get(pageIndex).ready) return;
        int baseBlockIndex = Integer.MAX_VALUE;
        for (TextSelectionModel.TextBlockLayout block : target.blocks()) {
            if (block.pageIndex == pageIndex && !block.hasLines()) {
                baseBlockIndex = Math.min(baseBlockIndex, block.blockIndex);
            }
        }
        if (baseBlockIndex == Integer.MAX_VALUE) return;
        // 以该页首个待升级块的 blockIndex 为基准重建，使新块的 blockIndex 与占位块逐一对应
        List<TextSelectionModel.TextBlockLayout> fresh = pageBlocks(document, renderer, pageIndex,
            baseBlockIndex, true);
        for (TextSelectionModel.TextBlockLayout source : fresh) {
            TextSelectionModel.TextBlockLayout pending = target.block(source.blockIndex);
            if (pending == null || pending.hasLines()) continue;
            pending.setLayoutData(source.bounds(), source.transform(), source.lines());
        }
    }

    // ------------------------------------------------------------------
    // 页级块收集
    // ------------------------------------------------------------------

    /**
     * 收集单页的全部文本块，是 {@link #build} 与 {@link #ensurePageLayout} 的唯一遍历入口，
     * 保证两条路径产生完全一致的块顺序。
     *
     * @param withLines 为 {@code true} 时从已排版元素构建完整行几何，否则为纯文本占位块
     */
    private static List<TextSelectionModel.TextBlockLayout> pageBlocks(OfficeDocument document,
            OfficeRenderer renderer, int pageIndex, int baseBlockIndex, boolean withLines) {
        List<TextSelectionModel.TextBlockLayout> result = new ArrayList<>();
        if (document.kind == OfficeDocument.Kind.DOCX) {
            if (pageIndex != 0 || renderer == null || renderer.pages.isEmpty()) return result;
            appendRenderedBlocks(renderer.pages.get(0).elements, 0f, 0, baseBlockIndex, result);
            return result;
        }
        if (document.kind != OfficeDocument.Kind.PPTX) return result;
        if (pageIndex < 0 || pageIndex >= document.pages.size()) return result;
        float pageOffsetY = rendererPageOffset(document, renderer, pageIndex);
        boolean laidOut = withLines && renderer != null && pageIndex < renderer.pages.size()
            && renderer.pages.get(pageIndex).ready;
        if (laidOut) {
            appendRenderedBlocks(renderer.pages.get(pageIndex).elements, pageOffsetY, pageIndex,
                baseBlockIndex, result);
        } else {
            appendPlaceholderBlocks(document.pages.get(pageIndex).elements, pageIndex, pageOffsetY,
                baseBlockIndex, result);
        }
        return result;
    }

    /**
     * PPTX 幻灯片在文档流中的纵向偏移（{@code OfficePreviewView} 绘制时平移的 {@code page.y}）。
     *
     * <p>正常情况下直接取 {@link OfficeRenderer.Page#y}；若渲染器尚未 {@code layout}（页列表为空），
     * 按 {@link OfficeRenderer#layout} 的相同规则（页高 + 16 间距）现场累加，
     * 避免占位块外接矩形落到错误的纵向位置。
     */
    private static float rendererPageOffset(OfficeDocument document, OfficeRenderer renderer, int pageIndex) {
        if (renderer != null && pageIndex >= 0 && pageIndex < renderer.pages.size()) {
            return renderer.pages.get(pageIndex).y;
        }
        if (document == null || pageIndex <= 0) return 0f;
        float offset = 0f;
        for (int i = 0; i < pageIndex && i < document.pages.size(); i++) {
            offset += document.pages.get(i).height + PAGE_GAP;
        }
        return offset;
    }

    // ------------------------------------------------------------------
    // 已排版元素 → 完整文本块
    // ------------------------------------------------------------------

    /** 遍历元素，按表格单元格聚合或整元素聚合生成文本块（阅读顺序 = 元素顺序）。 */
    private static void appendRenderedBlocks(List<OfficeRenderer.Element> elements, float pageOffsetY,
            int pageIndex, int baseBlockIndex, List<TextSelectionModel.TextBlockLayout> out) {
        int blockIndex = baseBlockIndex;
        for (OfficeRenderer.Element element : elements) {
            float[] transform = matrixToAffine6(element.transform, pageOffsetY);
            if (!element.cellTextRanges.isEmpty()) {
                for (int[] range : element.cellTextRanges) {
                    TextSelectionModel.TextBlockLayout block = buildRenderedBlock(element.texts,
                        range[0], range[1], blockIndex, pageIndex, transform);
                    if (block == null) continue;
                    out.add(block);
                    blockIndex++;
                }
            } else if (!element.texts.isEmpty()) {
                TextSelectionModel.TextBlockLayout block = buildRenderedBlock(element.texts,
                    0, element.texts.size(), blockIndex, pageIndex, transform);
                if (block != null) {
                    out.add(block);
                    blockIndex++;
                }
            }
        }
    }

    /**
     * 把一段连续的 {@link OfficeTextLayout.Block}（同一元素或同一表格单元格的段落）聚合为一个文本块。
     *
     * <p>{@code fullText} 按段落以 {@code "\n"} 连接，并用 {@link OfficeTextLayout.Block#rawCharCount}
     * 截掉空段落为保证行高插入的 {@code " "}，使全选与跨段复制不引入多余空格。
     */
    private static TextSelectionModel.TextBlockLayout buildRenderedBlock(List<OfficeTextLayout.Block> blocks,
            int startIndex, int endIndex, int blockIndex, int pageIndex, float[] transform) {
        StringBuilder fullText = new StringBuilder();
        List<TextSelectionModel.LineMetrics> lines = new ArrayList<>();
        int paraBaseOffset = 0;
        boolean firstParagraph = true;
        for (int i = Math.max(0, startIndex); i < endIndex && i < blocks.size(); i++) {
            OfficeTextLayout.Block block = blocks.get(i);
            StaticLayout layout = block == null ? null : block.layout;
            if (layout == null) continue;
            int textLength = layout.getText().length();
            int rawLen = Math.max(0, Math.min(block.rawCharCount, textLength));
            if (!firstParagraph) {
                fullText.append('\n');
                paraBaseOffset += 1; // 段间换行符占用一个码元
            }
            firstParagraph = false;
            int lineCount = layout.getLineCount();
            for (int lineIndex = 0; lineIndex < lineCount; lineIndex++) {
                int lineStart = rawLen == 0 ? 0 : Math.min(layout.getLineStart(lineIndex), rawLen);
                int lineEnd = rawLen == 0 ? 0 : Math.min(layout.getLineEnd(lineIndex), rawLen);
                lines.add(new StaticLineMetrics(layout, lineIndex, block.x, block.y,
                    paraBaseOffset + lineStart, paraBaseOffset + lineEnd, paraBaseOffset, rawLen));
            }
            fullText.append(layout.getText(), 0, rawLen);
            paraBaseOffset += rawLen;
        }
        // 与占位路径严格对齐：整段无原始字符的块不参与选区索引（全选与复制都无需空块）
        if (fullText.length() == 0) return null;
        TextSelectionModel.Rect docBounds = docBoundsOf(lines, transform);
        return new TextSelectionModel.TextBlockLayout(blockIndex, pageIndex, docBounds, transform,
            fullText.toString(), lines);
    }

    /** 由行几何推算块外接矩形（块局部包围盒经块矩阵映射为文档坐标外接矩形）。 */
    private static TextSelectionModel.Rect docBoundsOf(List<TextSelectionModel.LineMetrics> lines,
            float[] transform) {
        if (lines.isEmpty()) return TextSelectionModel.transformRect(transform,
            new TextSelectionModel.Rect(0f, 0f, MIN_BLOCK_SIZE, MIN_BLOCK_SIZE));
        float left = Float.MAX_VALUE;
        float top = Float.MAX_VALUE;
        float right = -Float.MAX_VALUE;
        float bottom = -Float.MAX_VALUE;
        for (TextSelectionModel.LineMetrics line : lines) {
            left = Math.min(left, line.left());
            top = Math.min(top, line.top());
            right = Math.max(right, line.right());
            bottom = Math.max(bottom, line.bottom());
        }
        return TextSelectionModel.transformRect(transform, new TextSelectionModel.Rect(left, top, right, bottom));
    }

    // ------------------------------------------------------------------
    // 未排版元素 → 纯文本占位块
    // ------------------------------------------------------------------

    /**
     * 为尚未排版的 PPTX 页构建仅含纯文本的轻量占位块，只遍历文档模型、不触发任何文本测量，
     * 保证大文档在 {@code selectAll()} / {@code getSelectedText()} 场景下仍能 O(字符数) 返回全文。
     *
     * <p>元素/单元格遍历顺序与 {@link #appendRenderedBlocks} 完全一致，因此后续
     * {@link #ensurePageLayout} 能按位置一一对应地补充行几何。占位块的外接矩形按元素框近似给出，
     * 仅用于手柄兜底定位。
     */
    private static void appendPlaceholderBlocks(List<OfficeDocument.Element> elements, int pageIndex,
            float pageOffsetY, int baseBlockIndex, List<TextSelectionModel.TextBlockLayout> out) {
        int blockIndex = baseBlockIndex;
        for (OfficeDocument.Element element : elements) {
            float[] transform = affine6(element.transform, pageOffsetY);
            TextSelectionModel.Rect elementBounds = TextSelectionModel.transformRect(transform,
                new TextSelectionModel.Rect(0f, 0f, Math.max(MIN_BLOCK_SIZE, element.width),
                    Math.max(MIN_BLOCK_SIZE, element.height)));
            if (element.type == OfficeDocument.Type.TABLE && !element.rows.isEmpty()) {
                int columns = 0;
                for (List<List<OfficeDocument.Paragraph>> row : element.rows) {
                    columns = Math.max(columns, row.size());
                }
                for (int r = 0; r < element.rows.size(); r++) {
                    List<List<OfficeDocument.Paragraph>> row = element.rows.get(r);
                    for (int c = 0; c < columns; c++) {
                        SpreadsheetDocument.CellRange merge = OfficeRenderer.findMerge(element.merges, r, c);
                        if (merge != null && (merge.startRow != r || merge.startColumn != c)) continue;
                        List<OfficeDocument.Paragraph> cell = c < row.size() ? row.get(c) : Collections.emptyList();
                        String text = joinRawParagraphs(textParagraphs(cell));
                        if (text.isEmpty()) continue;
                        out.add(new TextSelectionModel.TextBlockLayout(blockIndex, pageIndex, elementBounds,
                            transform, text, Collections.emptyList()));
                        blockIndex++;
                    }
                }
            } else if (!element.paragraphs.isEmpty()) {
                String text = joinRawParagraphs(element.paragraphs);
                if (text.isEmpty()) continue;
                out.add(new TextSelectionModel.TextBlockLayout(blockIndex, pageIndex, elementBounds,
                    transform, text, Collections.emptyList()));
                blockIndex++;
            }
        }
    }

    /** 取单元格内参与文本排版的段落（与 {@link OfficeRenderer} 一致的图片段落过滤规则）。 */
    private static List<OfficeDocument.Paragraph> textParagraphs(List<OfficeDocument.Paragraph> cell) {
        List<OfficeDocument.Paragraph> result = new ArrayList<>();
        for (OfficeDocument.Paragraph paragraph : cell) {
            if (paragraph.image == null) result.add(paragraph);
        }
        return result;
    }

    /** 按段落以 {@code "\n"} 连接原始纯文本，与已排版路径的 {@code fullText} 构造规则一致。 */
    private static String joinRawParagraphs(List<OfficeDocument.Paragraph> paragraphs) {
        StringBuilder builder = new StringBuilder();
        boolean first = true;
        for (OfficeDocument.Paragraph paragraph : paragraphs) {
            if (!first) builder.append('\n');
            first = false;
            builder.append(OfficeTextLayout.rawParagraphText(paragraph));
        }
        return builder.toString();
    }

    // ------------------------------------------------------------------
    // 仿射矩阵换算
    // ------------------------------------------------------------------

    /**
     * 把 Android {@link Matrix} 的 9 元组换算为 {@code [a, b, c, d, tx, ty]} 6 元组。
     *
     * <p>{@link OfficeRenderer} 以 {@code setValues({m[0], m[2], m[4], m[1], m[3], m[5], 0, 0, 1})}
     * 填充矩阵，因此取回时 {@code a = v[0]}、{@code b = v[3]}、{@code c = v[1]}、
     * {@code d = v[4]}、{@code tx = v[2]}、{@code ty = v[5]}（与 macOS {@code CGAffineTransform} 同序）。
     *
     * @param pageOffsetY PPTX 幻灯片在文档流中的纵向偏移，DOCX 传 {@code 0}
     */
    private static float[] matrixToAffine6(Matrix matrix, float pageOffsetY) {
        if (matrix == null) return new float[] {1f, 0f, 0f, 1f, 0f, pageOffsetY};
        float[] values = new float[9];
        matrix.getValues(values);
        return new float[] {values[0], values[3], values[1], values[4], values[2], values[5] + pageOffsetY};
    }

    /** 文档模型自带 6 元组仿射矩阵的平移补偿（PPTX 页偏移）。 */
    private static float[] affine6(float[] transform, float pageOffsetY) {
        if (transform == null || transform.length < 6) {
            return new float[] {1f, 0f, 0f, 1f, 0f, pageOffsetY};
        }
        return new float[] {transform[0], transform[1], transform[2], transform[3], transform[4],
            transform[5] + pageOffsetY};
    }

    // ------------------------------------------------------------------
    // 行度量实现
    // ------------------------------------------------------------------

    /**
     * 基于 {@link StaticLayout} 的行度量实现。
     *
     * <p>坐标全部换算到<b>元素局部坐标系</b>（与 {@code OfficeRenderer} 绘制文本块时的
     * {@code canvas.translate(block.x, block.y)} 一致），再由块的仿射矩阵映射到文档坐标。
     *
     * <p>字符索引使用<b>块内 {@code fullText} 的绝对码元索引</b>，即
     * {@code paraBaseOffset + 段内排版索引}；空段落占位行（{@code rawLen == 0}）
     * 的 {@code charStart} 与 {@code charEnd} 重合，不产生任何高亮。
     */
    private static final class StaticLineMetrics implements TextSelectionModel.LineMetrics {
        private final StaticLayout layout;
        private final int lineIndex;
        private final float offsetX;
        private final float offsetY;
        private final int charStart;
        private final int charEnd;
        private final int paraBaseOffset;
        /** 该段落的原始字符数（不含空段占位 {@code " "}）。 */
        private final int rawLen;

        StaticLineMetrics(StaticLayout layout, int lineIndex, float offsetX, float offsetY,
                          int charStart, int charEnd, int paraBaseOffset, int rawLen) {
            this.layout = layout;
            this.lineIndex = lineIndex;
            this.offsetX = offsetX;
            this.offsetY = offsetY;
            this.charStart = charStart;
            this.charEnd = Math.max(charStart, charEnd);
            this.paraBaseOffset = paraBaseOffset;
            this.rawLen = rawLen;
        }

        @Override
        public float left() {
            return lineX() + horizontalOffset(charStart);
        }

        @Override
        public float top() {
            return offsetY + layout.getLineTop(lineIndex);
        }

        @Override
        public float right() {
            return lineX() + Math.max(horizontalOffset(charEnd),
                horizontalOffset(charStart) + MIN_BLOCK_SIZE);
        }

        @Override
        public float bottom() {
            return offsetY + layout.getLineBottom(lineIndex);
        }

        /**
         * 行内文字起点的<b>块局部</b> X（{@code block.x} + 段缩进/居中/右对齐偏移）。
         * 块局部坐标系与 {@code OfficeRenderer} 绘制文本块时的 {@code canvas.translate(block.x, block.y)}
         * 一致，因此 {@code lineX() + horizontalOffset(i)} 可直接映射到文档坐标。
         */
        @Override
        public float lineX() {
            return offsetX + layoutLineLeft();
        }

        @Override
        public int charStart() {
            return charStart;
        }

        @Override
        public int charEnd() {
            return charEnd;
        }

        @Override
        public int paraBaseOffset() {
            return paraBaseOffset;
        }

        /**
         * 返回相对 {@link #lineX()} 的 X 偏移（未加 {@code lineX()}）。
         * 空段落占位行恒返回 {@code 0}。
         */
        @Override
        public float horizontalOffset(int localCharIndex) {
            if (rawLen == 0) return 0f;
            int layoutIndex = clampToLine(localCharIndex - paraBaseOffset);
            return layout.getPrimaryHorizontal(layoutIndex) - layoutLineLeft();
        }

        /**
         * 根据相对 {@link #lineX()} 的 X 偏移反查字符索引，结果夹紧到本行的块内字符范围。
         * 空段落占位行返回 {@code paraBaseOffset}（即该段的块内起始偏移）。
         */
        @Override
        public int charIndexForX(float relativeX) {
            if (rawLen == 0) return paraBaseOffset;
            int lineStart = layout.getLineStart(lineIndex);
            int lineEnd = layout.getLineEnd(lineIndex);
            float layoutX = relativeX + layoutLineLeft();
            // 行首/行尾外侧直接归到端点，避免 getOffsetForHorizontal 在缩进区返回首字符
            if (layoutX <= Math.min(layoutLineLeft(), layout.getPrimaryHorizontal(lineStart))) {
                return charStart;
            }
            if (layoutX >= layout.getPrimaryHorizontal(lineEnd)) return charEnd;
            int offset = layout.getOffsetForHorizontal(lineIndex, layoutX);
            int blockIndex = paraBaseOffset + Math.max(lineStart, Math.min(lineEnd, offset));
            return Math.max(charStart, Math.min(charEnd, blockIndex));
        }

        /** 段落排版自身给出的行左端（段缩进 + 居中/右对齐偏移），不含 {@code block.x}。 */
        private float layoutLineLeft() {
            return layout.getLineLeft(lineIndex);
        }

        /** 把段内排版索引夹紧到本行的排版范围，避免跨行取值。 */
        private int clampToLine(int layoutIndex) {
            int lineStart = layout.getLineStart(lineIndex);
            int lineEnd = Math.min(layout.getLineEnd(lineIndex), rawLen);
            return Math.max(lineStart, Math.min(lineEnd, layoutIndex));
        }
    }
}
