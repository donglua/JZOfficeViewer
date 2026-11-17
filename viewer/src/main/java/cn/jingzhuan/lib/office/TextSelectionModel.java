package cn.jingzhuan.lib.office;

import java.text.BreakIterator;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * 文档文本选区模型：纯 Java 11 逻辑，零 {@code android.*} 依赖。
 *
 * <p>本类与 macOS 参考实现 {@code viewer-macos/Sources/JZOffice/Render/TextSelectionModel.swift}
 * 保持语义一致，并可由 {@code scripts/tests/TextSelectionChecks.java} 在无 Android SDK 的环境下验证：
 *
 * <ul>
 *   <li>文本位置 {@link TextPosition}：块索引 + 块内 {@code fullText} 的 UTF-16 码元偏移；</li>
 *   <li>选区 {@link TextSelection}：保留锚点/焦点，支持反向拖选与跨块范围；</li>
 *   <li>行度量 {@link LineMetrics}：由平台层（Android {@code StaticLayout}）实现，纯逻辑层只用抽象接口；</li>
 *   <li>文本块 {@link TextBlockLayout}：块外接矩形 + 2D 仿射矩阵 + 拼接纯文本 + 行几何（可延迟填充）；</li>
 *   <li>文档索引 {@link DocumentTextLayout}：命中测试、分词、选区高亮矩形、手柄几何与文本提取。</li>
 * </ul>
 *
 * <p><b>坐标系约定</b>：块内坐标（行矩形、{@code lineX}）为块局部（左上原点、y 向下）；
 * 文档坐标为页面拼接后的全局坐标。2D 仿射矩阵使用 6 元组 {@code [a, b, c, d, tx, ty]}，
 * 语义为 {@code dx = a * lx + c * ly + tx}、{@code dy = b * lx + d * ly + ty}，
 * 与 Android {@code Matrix} 及 macOS {@code CGAffineTransform} 一致。
 *
 * <p><b>字符索引约定</b>：{@link LineMetrics#charStart()}、{@link LineMetrics#charEnd()}、
 * {@link LineMetrics#horizontalOffset(int)} 与 {@link LineMetrics#charIndexForX(float)} 全部使用
 * <b>块内 {@code fullText} 的绝对码元索引</b>（与 {@link TextPosition#charIndex} 同一空间），
 * 因此模型层无需再做 {@code paraBaseOffset} 平移；{@code paraBaseOffset} 仅供实现类内部换算。
 *
 * <p><b>块顺序约定</b>：{@link DocumentTextLayout} 按文档阅读顺序持有块列表，
 * 且 {@code blockIndex} 必须单调递增，选区范围计算依赖该顺序。
 */
public final class TextSelectionModel {
    /** 文本块最大行高兜底值，避免无行几何时比较退化。 */
    private static final float MIN_HIGHLIGHT_WIDTH = 1.5f;
    /** 仿射矩阵退化判定阈值（行列式绝对值小于该值视为不可逆）。 */
    private static final float DETERMINANT_EPSILON = 1e-6f;
    /** 命中测试中块局部包围盒的宽松扩展量（横向 8、纵向 4），与 macOS 一致。 */
    private static final float HIT_SLACK_X = 8f;
    private static final float HIT_SLACK_Y = 4f;

    private TextSelectionModel() {
    }

    // ------------------------------------------------------------------
    // 基础值类型
    // ------------------------------------------------------------------

    /**
     * 文档文本流中的光标位置：{@code blockIndex} 为块索引，{@code charIndex} 为块内
     * {@code fullText} 的 UTF-16 码元偏移（{@code 0 .. fullText.length()}）。
     */
    public static final class TextPosition implements Comparable<TextPosition> {
        public final int blockIndex;
        public final int charIndex;

        public TextPosition(int blockIndex, int charIndex) {
            this.blockIndex = blockIndex;
            this.charIndex = Math.max(0, charIndex);
        }

        @Override
        public int compareTo(TextPosition other) {
            if (blockIndex != other.blockIndex) return Integer.compare(blockIndex, other.blockIndex);
            return Integer.compare(charIndex, other.charIndex);
        }

        @Override
        public boolean equals(Object other) {
            if (this == other) return true;
            if (!(other instanceof TextPosition)) return false;
            TextPosition position = (TextPosition) other;
            return blockIndex == position.blockIndex && charIndex == position.charIndex;
        }

        @Override
        public int hashCode() {
            return blockIndex * 31 + charIndex;
        }

        @Override
        public String toString() {
            return "TextPosition(" + blockIndex + ", " + charIndex + ")";
        }
    }

    /** 选区范围：保留锚点与焦点，支持正向/反向拖选。 */
    public static final class TextSelection {
        public final TextPosition anchor;
        public final TextPosition focus;

        public TextSelection(TextPosition anchor, TextPosition focus) {
            this.anchor = anchor == null ? new TextPosition(0, 0) : anchor;
            this.focus = focus == null ? this.anchor : focus;
        }

        /** 折叠选区（锚点与焦点重合），用于点击落点尚无选区时的占位。 */
        public TextSelection(TextPosition position) {
            this(position, position);
        }

        public boolean isEmpty() {
            return anchor.equals(focus);
        }

        public TextPosition start() {
            return anchor.compareTo(focus) <= 0 ? anchor : focus;
        }

        public TextPosition end() {
            return anchor.compareTo(focus) <= 0 ? focus : anchor;
        }

        public boolean containsBlock(int blockIndex) {
            return blockIndex >= start().blockIndex && blockIndex <= end().blockIndex;
        }

        @Override
        public String toString() {
            return "TextSelection(" + anchor + " -> " + focus + ")";
        }
    }

    /** 轴对齐矩形（左、上、右、下），构造时自动归一化保证 {@code left <= right}、{@code top <= bottom}。 */
    public static final class Rect {
        public final float left;
        public final float top;
        public final float right;
        public final float bottom;

        public Rect(float left, float top, float right, float bottom) {
            this.left = Math.min(left, right);
            this.top = Math.min(top, bottom);
            this.right = Math.max(left, right);
            this.bottom = Math.max(top, bottom);
        }

        public float width() {
            return right - left;
        }

        public float height() {
            return bottom - top;
        }

        public float centerX() {
            return (left + right) * 0.5f;
        }

        public float centerY() {
            return (top + bottom) * 0.5f;
        }

        public boolean isEmpty() {
            return right <= left || bottom <= top;
        }

        public boolean contains(float x, float y) {
            return x >= left && x <= right && y >= top && y <= bottom;
        }

        @Override
        public String toString() {
            return "Rect(" + left + ", " + top + ", " + right + ", " + bottom + ")";
        }
    }

    /**
     * 单个选区手柄的几何：同时携带文档坐标（供视图层在屏幕坐标系绘制水滴手柄）
     * 与块局部坐标（供需要按块矩阵斜绘竖线的场景）。
     * 无行几何的占位块只有文档坐标有效，局部坐标退化为 {@code 0}。
     */
    public static final class HandlePoint {
        /** 光标在文档全局坐标系下的 X。 */
        public final float docX;
        /** 光标竖线在文档全局坐标系下的顶部 Y。 */
        public final float docTopY;
        /** 光标竖线在文档全局坐标系下的底部 Y。 */
        public final float docBottomY;
        /** 所属块索引，{@code -1} 表示无块信息。 */
        public final int blockIndex;
        /** 光标在块局部坐标系下的 X。 */
        public final float localX;
        /** 光标竖线在块局部坐标系下的顶部 Y。 */
        public final float localTopY;
        /** 光标竖线在块局部坐标系下的底部 Y。 */
        public final float localBottomY;

        public HandlePoint(float docX, float docTopY, float docBottomY) {
            this(docX, docTopY, docBottomY, -1, 0f, 0f, 0f);
        }

        public HandlePoint(float docX, float docTopY, float docBottomY,
                           int blockIndex, float localX, float localTopY, float localBottomY) {
            this.docX = docX;
            this.docTopY = Math.min(docTopY, docBottomY);
            this.docBottomY = Math.max(docTopY, docBottomY);
            this.blockIndex = blockIndex;
            this.localX = localX;
            this.localTopY = Math.min(localTopY, localBottomY);
            this.localBottomY = Math.max(localTopY, localBottomY);
        }

        @Override
        public String toString() {
            return "HandlePoint(doc " + docX + ", " + docTopY + ".." + docBottomY
                + "; block " + blockIndex + " local " + localX + ")";
        }
    }

    /** 选区起止手柄几何。 */
    public static final class SelectionHandles {
        public final HandlePoint start;
        public final HandlePoint end;

        public SelectionHandles(HandlePoint start, HandlePoint end) {
            this.start = start;
            this.end = end;
        }
    }

    /**
     * 一段选区高亮矩形：同时给出块局部矩形、块仿射矩阵与文档坐标外接矩形。
     *
     * <p>视图层可在 {@code canvas.concat(transform)} 之后直接绘制 {@code localRect} 以获得
     * 旋转/翻转文本框的精确斜矩形；只做粗粒度裁剪时可直接使用 {@code docBounds}。
     */
    public static final class BlockHighlightRect {
        public final int blockIndex;
        /** 块局部坐标到文档全局坐标的 2D 仿射矩阵（6 元组副本，调用方可直接使用）。 */
        public final float[] transform;
        /** 块局部坐标系下的高亮矩形。 */
        public final Rect localRect;
        /** 文档全局坐标系下的外接矩形（旋转时为其包围盒）。 */
        public final Rect docBounds;

        public BlockHighlightRect(int blockIndex, float[] transform, Rect localRect, Rect docBounds) {
            this.blockIndex = blockIndex;
            this.transform = transform == null ? new float[] {1f, 0f, 0f, 1f, 0f, 0f} : transform.clone();
            this.localRect = localRect;
            this.docBounds = docBounds;
        }
    }

    // ------------------------------------------------------------------
    // 行度量抽象
    // ------------------------------------------------------------------

    /**
     * 单行排版几何与字符映射抽象。平台层用系统排版 API 实现，纯逻辑层只依赖本接口。
     *
     * <p>{@code rect} 为行在块局部坐标系下的矩形；{@code lineX} 为行内文字起点 X；
     * {@code charStart}/{@code charEnd} 为该行在块 {@code fullText} 中的绝对码元范围；
     * {@code paraBaseOffset} 为该行所属段落在 {@code fullText} 中的起始偏移，
     * 供实现类把平台排版索引换算到块索引空间。
     */
    public interface LineMetrics {
        float left();

        float top();

        float right();

        float bottom();

        /** 行内文字起点的块局部 X（已含段缩进与居中等对齐偏移）。 */
        float lineX();

        /** 该行覆盖的块内起始码元索引。 */
        int charStart();

        /** 该行覆盖的块内结束码元索引（不含）。 */
        int charEnd();

        /** 所属段落在 {@code fullText} 中的起始偏移。 */
        int paraBaseOffset();

        /**
         * 计算某字符边界相对 {@link #lineX()} 的 X 偏移。
         *
         * <p>返回值为行内相对量，未包含 {@link #lineX()}；块的绝对 X 为
         * {@code lineX() + horizontalOffset(index)}。Android {@code StaticLayout} 实现类会把
         * 系统排版的绝对坐标减去 {@code lineX()} 后返回。
         *
         * @param localCharIndex 块内绝对码元索引，实现类自行夹紧到 {@code [charStart, charEnd]}
         */
        float horizontalOffset(int localCharIndex);

        /**
         * 根据相对 {@link #lineX()} 的 X 偏移反查最邻近字符边界。
         *
         * @param relativeX 相对行内文字起点 {@link #lineX()} 的 X 偏移
         * @return 块内绝对码元索引，已夹紧到 {@code [charStart, charEnd]}
         */
        int charIndexForX(float relativeX);
    }

    /**
     * 基于单调递增字符偏移数组的默认行度量实现，供纯 JVM 测试与等宽占位场景使用。
     *
     * <p>{@code charOffsets} 长度为 {@code charEnd - charStart + 1}，第 {@code i} 项为
     * 块内第 {@code charStart + i} 个码元边界相对 {@code lineX} 的 X 偏移。
     */
    public static final class ArrayLineMetrics implements LineMetrics {
        private final float left;
        private final float top;
        private final float right;
        private final float bottom;
        private final float lineX;
        private final int charStart;
        private final int charEnd;
        private final int paraBaseOffset;
        private final float[] charOffsets;

        public ArrayLineMetrics(float left, float top, float right, float bottom, float lineX,
                                int charStart, int charEnd, int paraBaseOffset, float[] charOffsets) {
            int count = Math.max(0, charEnd - charStart);
            if (charOffsets == null || charOffsets.length < count + 1) {
                throw new IllegalArgumentException("charOffsets must hold charCount + 1 entries");
            }
            this.left = Math.min(left, right);
            this.top = Math.min(top, bottom);
            this.right = Math.max(left, right);
            this.bottom = Math.max(top, bottom);
            this.lineX = lineX;
            this.charStart = charStart;
            this.charEnd = Math.max(charStart, charEnd);
            this.paraBaseOffset = paraBaseOffset;
            this.charOffsets = charOffsets.clone();
        }

        @Override
        public float left() {
            return left;
        }

        @Override
        public float top() {
            return top;
        }

        @Override
        public float right() {
            return right;
        }

        @Override
        public float bottom() {
            return bottom;
        }

        @Override
        public float lineX() {
            return lineX;
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

        @Override
        public float horizontalOffset(int localCharIndex) {
            int relative = localCharIndex - charStart;
            if (relative < 0) relative = 0;
            int maxRelative = charOffsets.length - 1;
            if (relative > maxRelative) relative = maxRelative;
            return charOffsets[relative];
        }

        @Override
        public int charIndexForX(float relativeX) {
            int count = charOffsets.length - 1;
            if (count <= 0 || relativeX <= charOffsets[0]) return charStart;
            // 按字形中点四舍五入：落点越过某字符中点即归入该字符的右侧边界
            for (int i = 0; i < count; i++) {
                float middle = (charOffsets[i] + charOffsets[i + 1]) * 0.5f;
                if (relativeX < middle) return charStart + i;
            }
            return charStart + count;
        }
    }

    // ------------------------------------------------------------------
    // 文本块与文档索引
    // ------------------------------------------------------------------

    /**
     * 一个文本块（DOCX 正文段落、表格单元格或 PPTX 文本框）。
     *
     * <p>PPTX 远端未排版页先用轻量占位块（{@code lines} 为空）参与全选与文本提取，
     * 进入视口排版后通过 {@link #setLayoutData(Rect, float[], List)} 升级行几何，
     * {@code blockIndex} 在升级前后保持不变。
     */
    public static final class TextBlockLayout {
        public final int blockIndex;
        public final int pageIndex;
        private Rect bounds;
        private float[] transform;
        private final String fullText;
        private List<LineMetrics> lines;

        public TextBlockLayout(int blockIndex, int pageIndex, Rect bounds, float[] transform,
                               String fullText, List<LineMetrics> lines) {
            this.blockIndex = blockIndex;
            this.pageIndex = pageIndex;
            this.bounds = bounds == null ? new Rect(0f, 0f, 0f, 0f) : bounds;
            this.transform = transform == null
                ? new float[] {1f, 0f, 0f, 1f, 0f, 0f} : transform.clone();
            this.fullText = fullText == null ? "" : fullText;
            this.lines = copyLines(lines);
        }

        public Rect bounds() {
            return bounds;
        }

        /** 返回块局部到文档全局的仿射矩阵 6 元组副本。 */
        public float[] transform() {
            return transform.clone();
        }

        public String fullText() {
            return fullText;
        }

        public int charCount() {
            return fullText.length();
        }

        /** 行几何列表；占位块为空列表。 */
        public List<LineMetrics> lines() {
            return Collections.unmodifiableList(lines);
        }

        public boolean hasLines() {
            return !lines.isEmpty();
        }

        /** 懒加载填充行几何（PPTX 页滚入视口排版后调用）。 */
        public void setLines(List<LineMetrics> updated) {
            this.lines = copyLines(updated);
        }

        /** 一次性替换外接矩形、仿射矩阵与行几何（占位块升级为完整布局）。 */
        public void setLayoutData(Rect updatedBounds, float[] updatedTransform, List<LineMetrics> updatedLines) {
            if (updatedBounds != null) this.bounds = updatedBounds;
            if (updatedTransform != null) this.transform = updatedTransform.clone();
            this.lines = copyLines(updatedLines);
        }

        private static List<LineMetrics> copyLines(List<LineMetrics> source) {
            List<LineMetrics> copy = new ArrayList<>();
            if (source != null) {
                for (LineMetrics line : source) {
                    if (line != null) copy.add(line);
                }
            }
            return copy;
        }

        @Override
        public String toString() {
            return "TextBlockLayout(" + blockIndex + ", page " + pageIndex + ", "
                + fullText.length() + " chars, " + lines.size() + " lines)";
        }
    }

    /**
     * 全文档文本空间索引与选区计算引擎。
     *
     * <p>块列表必须按文档阅读顺序排列且 {@code blockIndex} 单调递增，选区范围计算依赖该顺序。
     */
    public static final class DocumentTextLayout {
        private final List<TextBlockLayout> blocks;
        private final Map<Integer, TextBlockLayout> blocksByIndex;

        public DocumentTextLayout(List<TextBlockLayout> blocks) {
            List<TextBlockLayout> copy = new ArrayList<>();
            Map<Integer, TextBlockLayout> index = new HashMap<>();
            if (blocks != null) {
                for (TextBlockLayout block : blocks) {
                    if (block == null) continue;
                    copy.add(block);
                    if (!index.containsKey(block.blockIndex)) index.put(block.blockIndex, block);
                }
            }
            this.blocks = copy;
            this.blocksByIndex = index;
        }

        /** 按阅读顺序返回全部块（只读视图）。 */
        public List<TextBlockLayout> blocks() {
            return Collections.unmodifiableList(blocks);
        }

        public int blockCount() {
            return blocks.size();
        }

        public boolean isEmpty() {
            return blocks.isEmpty();
        }

        /** 按块索引查找块，不存在时返回 {@code null}。 */
        public TextBlockLayout block(int blockIndex) {
            return blocksByIndex.get(blockIndex);
        }

        /** 是否存在可选正文（任一非空文本块）。 */
        public boolean hasSelectableText() {
            for (TextBlockLayout block : blocks) {
                if (block.charCount() > 0) return true;
            }
            return false;
        }

        // ------------------------------ 命中测试 ------------------------------

        /**
         * 将文档坐标点映射为最贴近的文本位置。
         *
         * <p>先用各块逆矩阵把点换算到块局部，优先选取局部包围盒（横向外扩 8、纵向外扩 4）
         * 命中的块；都不命中时退化为与块外接矩形欧氏距离最近的块，保证跨行空白处拖选不跳断。
         * 无行几何的占位块不参与命中。返回的字符索引始终落在合法码点边界上。
         */
        public TextPosition hitTest(float docX, float docY) {
            TextBlockLayout best = null;
            float bestDistance = Float.MAX_VALUE;
            for (TextBlockLayout candidate : blocks) {
                if (!candidate.hasLines()) continue;
                float[] inverse = invertTransform(candidate.transform);
                float localX = inverse[0] * docX + inverse[2] * docY + inverse[4];
                float localY = inverse[1] * docX + inverse[3] * docY + inverse[5];
                Rect local = localBounds(candidate);
                if (localX >= local.left - HIT_SLACK_X && localX <= local.right + HIT_SLACK_X
                    && localY >= local.top - HIT_SLACK_Y && localY <= local.bottom + HIT_SLACK_Y) {
                    best = candidate;
                    break;
                }
                float distance = distanceToRect(docX, docY, candidate.bounds);
                if (distance < bestDistance) {
                    bestDistance = distance;
                    best = candidate;
                }
            }
            if (best == null) return null;

            float[] inverse = invertTransform(best.transform);
            float localX = inverse[0] * docX + inverse[2] * docY + inverse[4];
            float localY = inverse[1] * docX + inverse[3] * docY + inverse[5];
            LineMetrics line = nearestLine(best, localY);
            if (line == null) return null;

            float relativeX = localX - line.lineX();
            int rawIndex = line.charIndexForX(relativeX);
            int clamped = clamp(rawIndex, line.charStart(), line.charEnd());
            String text = best.fullText;
            clamped = clamp(clamped, 0, text.length());
            if (isSplitSurrogate(text, clamped)) {
                // 落点位于代理对中间时，按代理对字形中点就近对齐到左右两个合法字符边界
                float leftX = line.horizontalOffset(clamped - 1);
                float rightX = line.horizontalOffset(clamped + 1);
                clamped = relativeX < (leftX + rightX) * 0.5f ? clamped - 1 : clamped + 1;
                clamped = clamp(clamped, 0, text.length());
            }
            return new TextPosition(best.blockIndex, clamped);
        }

        /** 行几何在块局部坐标系下的包围盒（无行时退化为块外接矩形的局部近似）。 */
        private static Rect localBounds(TextBlockLayout block) {
            float left = Float.MAX_VALUE;
            float top = Float.MAX_VALUE;
            float right = -Float.MAX_VALUE;
            float bottom = -Float.MAX_VALUE;
            for (LineMetrics line : block.lines) {
                left = Math.min(left, line.left());
                top = Math.min(top, line.top());
                right = Math.max(right, line.right());
                bottom = Math.max(bottom, line.bottom());
            }
            if (right <= left || bottom <= top) return new Rect(0f, 0f, 1f, 1f);
            return new Rect(left, top, right, bottom);
        }

        /** 选取纵向包含该点或中线距离最近的行。 */
        private static LineMetrics nearestLine(TextBlockLayout block, float localY) {
            LineMetrics best = null;
            float bestDistance = Float.MAX_VALUE;
            for (LineMetrics line : block.lines) {
                if (localY >= line.top() && localY <= line.bottom()) return line;
                float distance = Math.abs(localY - (line.top() + line.bottom()) * 0.5f);
                if (distance < bestDistance) {
                    bestDistance = distance;
                    best = line;
                }
            }
            return best;
        }

        private static float distanceToRect(float x, float y, Rect rect) {
            float dx = Math.max(Math.max(rect.left - x, 0f), x - rect.right);
            float dy = Math.max(Math.max(rect.top - y, 0f), y - rect.bottom);
            return (float) Math.sqrt(dx * dx + dy * dy);
        }

        // ------------------------------ 分词与整行 ------------------------------

        /**
         * 按词边界扩展选区（长按默认选词）。使用 {@link BreakIterator#getWordInstance(Locale)}
         * 的词边界，优先返回非空白词元；落点在空白处时先向后、再向前寻找相邻非空白词元，
         * 都没有时退化为当前码点范围。
         */
        public TextSelection wordRange(TextPosition position) {
            if (position == null) return null;
            TextBlockLayout block = block(position.blockIndex);
            if (block == null) return null;
            String text = block.fullText;
            if (text.isEmpty()) return null;

            int probe = clamp(position.charIndex, 0, text.length() - 1);
            List<int[]> tokens = wordTokens(text);
            if (tokens.isEmpty()) return null;

            int tokenIndex = -1;
            for (int i = 0; i < tokens.size(); i++) {
                int[] token = tokens.get(i);
                if (probe >= token[0] && probe < token[1]) {
                    tokenIndex = i;
                    break;
                }
            }
            if (tokenIndex < 0) tokenIndex = tokens.size() - 1;

            int[] token = tokens.get(tokenIndex);
            if (isBlankRange(text, token[0], token[1])) {
                token = nextNonBlankToken(text, tokens, tokenIndex, probe);
            }
            return new TextSelection(new TextPosition(block.blockIndex, token[0]),
                new TextPosition(block.blockIndex, token[1]));
        }

        /** 落点在空白时先向后、再向前寻找相邻非空白词元；仍无则取当前码点范围。 */
        private static int[] nextNonBlankToken(String text, List<int[]> tokens, int tokenIndex, int probe) {
            for (int i = tokenIndex + 1; i < tokens.size(); i++) {
                int[] candidate = tokens.get(i);
                if (!isBlankRange(text, candidate[0], candidate[1])) return candidate;
            }
            for (int i = tokenIndex - 1; i >= 0; i--) {
                int[] candidate = tokens.get(i);
                if (!isBlankRange(text, candidate[0], candidate[1])) return candidate;
            }
            int end = Math.min(text.length(), probe + Character.charCount(text.codePointAt(probe)));
            return new int[] {probe, end};
        }

        /** 用 {@link BreakIterator} 拆出全部词元区间，代理对与中英文标点由 JDK 词边界处理。 */
        private static List<int[]> wordTokens(String text) {
            List<int[]> tokens = new ArrayList<>();
            BreakIterator iterator = BreakIterator.getWordInstance(Locale.ROOT);
            iterator.setText(text);
            int start = iterator.first();
            for (int end = iterator.next(); end != BreakIterator.DONE; start = end, end = iterator.next()) {
                tokens.add(new int[] {start, end});
            }
            return tokens;
        }

        private static boolean isBlankRange(String text, int start, int end) {
            for (int i = Math.max(0, start); i < Math.min(text.length(), end); i++) {
                if (!Character.isWhitespace(text.charAt(i))) return false;
            }
            return true;
        }

        /** 按行边界扩展选区（整行选中）。 */
        public TextSelection lineRange(TextPosition position) {
            if (position == null) return null;
            TextBlockLayout block = block(position.blockIndex);
            if (block == null) return null;
            int index = clamp(position.charIndex, 0, block.charCount());
            for (LineMetrics line : block.lines) {
                if (index >= line.charStart() && index <= line.charEnd()) {
                    return new TextSelection(new TextPosition(block.blockIndex, line.charStart()),
                        new TextPosition(block.blockIndex, line.charEnd()));
                }
            }
            return null;
        }

        /** 全选范围：首个非空文本块起点到末个非空文本块末尾；无可选文本返回 {@code null}。 */
        public TextSelection allTextRange() {
            TextBlockLayout first = null;
            TextBlockLayout last = null;
            for (TextBlockLayout block : blocks) {
                if (block.charCount() <= 0) continue;
                if (first == null) first = block;
                last = block;
            }
            if (first == null || last == null) return null;
            return new TextSelection(new TextPosition(first.blockIndex, 0),
                new TextPosition(last.blockIndex, last.charCount()));
        }

        // ------------------------------ 选区高亮几何 ------------------------------

        /** 选区高亮矩形（文档坐标外接矩形），按块与行顺序返回。 */
        public List<Rect> selectionRects(TextSelection selection) {
            List<Rect> rects = new ArrayList<>();
            for (BlockHighlightRect highlight : blockSelectionRects(selection)) {
                rects.add(highlight.docBounds);
            }
            return rects;
        }

        /** 选区高亮矩形（含块局部矩形与块矩阵），供视图层按块仿射精确斜绘。 */
        public List<BlockHighlightRect> blockSelectionRects(TextSelection selection) {
            List<BlockHighlightRect> result = new ArrayList<>();
            if (selection == null || selection.isEmpty()) return result;
            TextPosition start = selection.start();
            TextPosition end = selection.end();
            for (TextBlockLayout block : blocks) {
                if (block.blockIndex < start.blockIndex || block.blockIndex > end.blockIndex) continue;
                for (Rect local : blockLocalHighlightRects(block, start, end)) {
                    result.add(new BlockHighlightRect(block.blockIndex, block.transform, local,
                        transformRect(block.transform, local)));
                }
            }
            return result;
        }

        /** 只计算指定块内的选区高亮矩形（供列表虚拟化的子组件仅绘制自身块）。 */
        public List<BlockHighlightRect> selectionRectsForBlock(TextSelection selection, int blockIndex) {
            List<BlockHighlightRect> result = new ArrayList<>();
            if (selection == null || selection.isEmpty()) return result;
            TextBlockLayout block = block(blockIndex);
            if (block == null) return result;
            TextPosition start = selection.start();
            TextPosition end = selection.end();
            if (blockIndex < start.blockIndex || blockIndex > end.blockIndex) return result;
            for (Rect local : blockLocalHighlightRects(block, start, end)) {
                result.add(new BlockHighlightRect(block.blockIndex, block.transform, local,
                    transformRect(block.transform, local)));
            }
            return result;
        }

        /**
         * 指定块内选区高亮矩形（文档坐标外接矩形），是
         * {@link #selectionRectsForBlock(TextSelection, int)} 的简写形式，
         * 供只做粗粒度绘制、不需要块矩阵的调用方使用。
         */
        public List<Rect> highlightRectsForBlock(TextSelection selection, int blockIndex) {
            List<Rect> rects = new ArrayList<>();
            for (BlockHighlightRect highlight : selectionRectsForBlock(selection, blockIndex)) {
                rects.add(highlight.docBounds);
            }
            return rects;
        }

        /** 单个块内的选区高亮矩形（块局部坐标）：逐行裁剪后按字符 X 偏移生成。 */
        private static List<Rect> blockLocalHighlightRects(TextBlockLayout block, TextPosition start,
                                                           TextPosition end) {
            List<Rect> rects = new ArrayList<>();
            int startChar = block.blockIndex == start.blockIndex ? start.charIndex : 0;
            int endChar = block.blockIndex == end.blockIndex ? end.charIndex : block.charCount();
            startChar = clamp(startChar, 0, block.charCount());
            endChar = clamp(endChar, 0, block.charCount());
            if (startChar >= endChar) return rects;
            for (LineMetrics line : block.lines) {
                int selectedStart = Math.max(startChar, line.charStart());
                int selectedEnd = Math.min(endChar, line.charEnd());
                if (selectedStart >= selectedEnd) continue;
                float x1 = line.horizontalOffset(selectedStart);
                float x2 = line.horizontalOffset(selectedEnd);
                float left = line.lineX() + Math.min(x1, x2);
                float width = Math.max(MIN_HIGHLIGHT_WIDTH, Math.abs(x2 - x1));
                rects.add(new Rect(left, line.top(), left + width, line.bottom()));
            }
            return rects;
        }

        // ------------------------------ 手柄几何 ------------------------------

        /**
         * 计算选区起止手柄几何；任一端无法定位时返回 {@code null}。
         * 起始手柄优先落到后一行的行首、结束手柄优先落到前一行的行尾（与文本编辑习惯一致）。
         */
        public SelectionHandles handleGeometry(TextSelection selection) {
            if (selection == null) return null;
            HandlePoint start = handleFor(selection.start(), true);
            HandlePoint end = handleFor(selection.end(), false);
            if (start == null || end == null) return null;
            return new SelectionHandles(start, end);
        }

        private HandlePoint handleFor(TextPosition position, boolean preferLaterLine) {
            TextBlockLayout block = block(position.blockIndex);
            if (block == null) return null;
            if (!block.hasLines()) {
                // 无行几何的占位块：退化为块外接矩形左边缘，保证全选时手柄仍可绘制
                Rect bounds = block.bounds;
                return new HandlePoint(bounds.left, bounds.top, bounds.bottom,
                    block.blockIndex, 0f, 0f, bounds.height());
            }
            LineMetrics line = lineForIndex(block, position.charIndex, preferLaterLine);
            if (line == null) return null;
            int index = clamp(position.charIndex, line.charStart(), line.charEnd());
            float localX = line.lineX() + line.horizontalOffset(index);
            float localTop = line.top();
            float localBottom = line.bottom();
            float[] matrix = block.transform;
            float docX = matrix[0] * localX + matrix[2] * localTop + matrix[4];
            float docTopY = matrix[1] * localX + matrix[3] * localTop + matrix[5];
            float docBottomY = matrix[1] * localX + matrix[3] * localBottom + matrix[5];
            return new HandlePoint(docX, docTopY, docBottomY, block.blockIndex, localX, localTop, localBottom);
        }

        /** 定位字符索引所在行：起始手柄偏好后一行，结束手柄偏好前一行。 */
        private static LineMetrics lineForIndex(TextBlockLayout block, int charIndex, boolean preferLaterLine) {
            LineMetrics first = null;
            LineMetrics last = null;
            LineMetrics match = null;
            for (LineMetrics line : block.lines) {
                if (first == null) first = line;
                last = line;
                if (charIndex >= line.charStart() && charIndex <= line.charEnd()) {
                    // 行首/行尾边界同时属于相邻两行，按手柄类型选择偏好的一侧
                    if (preferLaterLine || match == null) match = line;
                }
            }
            if (match != null) return match;
            if (first == null) return null;
            return charIndex < first.charStart() ? first : last;
        }

        // ------------------------------ 文本提取 ------------------------------

        /** 提取选区纯文本：跨段落与跨块以 {@code "\n"} 连接，空块不产生多余换行。 */
        public String selectedText(TextSelection selection) {
            if (selection == null || selection.isEmpty()) return "";
            TextPosition start = selection.start();
            TextPosition end = selection.end();
            List<String> parts = new ArrayList<>();
            for (TextBlockLayout block : blocks) {
                if (block.blockIndex < start.blockIndex || block.blockIndex > end.blockIndex) continue;
                int length = block.charCount();
                if (length <= 0) continue;
                int startChar = block.blockIndex == start.blockIndex ? start.charIndex : 0;
                int endChar = block.blockIndex == end.blockIndex ? end.charIndex : length;
                startChar = clamp(startChar, 0, length);
                endChar = clamp(endChar, 0, length);
                if (startChar >= endChar) continue;
                parts.add(block.fullText.substring(startChar, endChar));
            }
            return join(parts);
        }

        private static String join(List<String> parts) {
            if (parts.isEmpty()) return "";
            StringBuilder builder = new StringBuilder();
            for (int i = 0; i < parts.size(); i++) {
                if (i > 0) builder.append('\n');
                builder.append(parts.get(i));
            }
            return builder.toString();
        }
    }

    // ------------------------------------------------------------------
    // 纯工具函数
    // ------------------------------------------------------------------

    /**
     * 把任意码元索引夹紧到合法字符（码点）边界。
     *
     * <p>若索引落在高位代理与低位代理之间（即指向低位代理），则向字符末端对齐（{@code index + 1}），
     * 保证永不切分 Emoji 或扩展汉字。索引本身越界时先夹紧到 {@code [0, length]}。
     */
    public static int clampToCodePointBoundary(String text, int index) {
        if (text == null) return Math.max(0, index);
        int length = text.length();
        int clamped = clamp(index, 0, length);
        if (isSplitSurrogate(text, clamped)) return clamped + 1;
        return clamped;
    }

    /** 判断索引是否切分了一个代理对。 */
    public static boolean isSplitSurrogate(String text, int index) {
        return text != null && index > 0 && index < text.length()
            && Character.isLowSurrogate(text.charAt(index))
            && Character.isHighSurrogate(text.charAt(index - 1));
    }

    /**
     * 计算 2D 仿射矩阵 {@code [a, b, c, d, tx, ty]} 的逆矩阵（同样为 6 元组）。
     *
     * <p>行列式绝对值小于 {@code 1e-6} 时矩阵退化，此时仅减去平移量，
     * 保证奇异矩阵（例如零缩放元素）也能得到确定的命中结果而不抛异常。
     */
    public static float[] invertTransform(float[] transform) {
        if (transform == null || transform.length < 6) return new float[] {1f, 0f, 0f, 1f, 0f, 0f};
        float a = transform[0];
        float b = transform[1];
        float c = transform[2];
        float d = transform[3];
        float tx = transform[4];
        float ty = transform[5];
        float determinant = a * d - b * c;
        if (Math.abs(determinant) < DETERMINANT_EPSILON) {
            return new float[] {1f, 0f, 0f, 1f, -tx, -ty};
        }
        float inverse = 1f / determinant;
        return new float[] {
            d * inverse,
            -b * inverse,
            -c * inverse,
            a * inverse,
            (c * ty - d * tx) * inverse,
            (b * tx - a * ty) * inverse
        };
    }

    /** 将块局部矩形经仿射矩阵映射为文档坐标外接矩形（旋转时返回包围盒）。 */
    public static Rect transformRect(float[] transform, Rect local) {
        if (local == null) return new Rect(0f, 0f, 0f, 0f);
        if (transform == null || transform.length < 6) return local;
        float a = transform[0];
        float b = transform[1];
        float c = transform[2];
        float d = transform[3];
        float tx = transform[4];
        float ty = transform[5];
        float x1 = a * local.left + c * local.top + tx;
        float y1 = b * local.left + d * local.top + ty;
        float x2 = a * local.right + c * local.top + tx;
        float y2 = b * local.right + d * local.top + ty;
        float x3 = a * local.right + c * local.bottom + tx;
        float y3 = b * local.right + d * local.bottom + ty;
        float x4 = a * local.left + c * local.bottom + tx;
        float y4 = b * local.left + d * local.bottom + ty;
        return new Rect(Math.min(Math.min(x1, x2), Math.min(x3, x4)),
            Math.min(Math.min(y1, y2), Math.min(y3, y4)),
            Math.max(Math.max(x1, x2), Math.max(x3, x4)),
            Math.max(Math.max(y1, y2), Math.max(y3, y4)));
    }

    private static int clamp(int value, int min, int max) {
        if (value < min) return min;
        if (value > max) return max;
        return value;
    }
}
