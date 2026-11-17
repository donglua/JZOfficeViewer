package cn.jingzhuan.lib.office;

import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/**
 * 纯 JVM 选区模型检查（无需 Android SDK / 设备）。
 *
 * <p>覆盖排版方案中 Task 1 的全部 7 项检查，并额外补充块局部高亮矩形、整行选区、
 * 代理对显式夹紧与空块拼接等回归项。编译与运行方式：
 *
 * <pre>
 * javac --release 11 -Xlint:all -Werror -d /tmp/jz-selection-checks \
 *   viewer/src/main/java/cn/jingzhuan/lib/office/TextSelectionModel.java \
 *   scripts/tests/TextSelectionChecks.java
 * java -cp /tmp/jz-selection-checks cn.jingzhuan.lib.office.TextSelectionChecks
 * </pre>
 */
public final class TextSelectionChecks {
    private static int checks = 0;

    private TextSelectionChecks() {
    }

    private static void check(boolean cond, String msg) {
        checks++;
        if (!cond) throw new AssertionError(msg);
    }

    /** 构造单行等宽文本块：块局部坐标 (0,0) 经平移矩阵落到文档坐标 (tx, ty)。 */
    private static TextSelectionModel.TextBlockLayout simpleBlock(
            int blockIndex, float tx, float ty, String text, float charWidth) {
        int len = text.length();
        float[] offsets = new float[len + 1];
        for (int i = 0; i <= len; i++) offsets[i] = i * charWidth;
        TextSelectionModel.ArrayLineMetrics line = new TextSelectionModel.ArrayLineMetrics(
            0f, 0f, len * charWidth, 20f, 0f, 0, len, 0, offsets);
        TextSelectionModel.Rect bounds = new TextSelectionModel.Rect(
            tx, ty, tx + Math.max(1f, len * charWidth), ty + 20f);
        return new TextSelectionModel.TextBlockLayout(
            blockIndex, 0, bounds, new float[] {1, 0, 0, 1, tx, ty}, text,
            Collections.singletonList(line));
    }

    public static void main(String[] args) {
        TextSelectionModel.TextBlockLayout b0 = simpleBlock(0, 10f, 20f, "Hello world", 10f);
        TextSelectionModel.TextBlockLayout b1 = simpleBlock(1, 10f, 60f, "你好世界", 16f);
        TextSelectionModel.DocumentTextLayout layout =
            new TextSelectionModel.DocumentTextLayout(Arrays.asList(b0, b1));

        // 1. 命中测试：x=10+25=35 落在第 2/3 字符边界上，按字形中点四舍五入取后一字符
        TextSelectionModel.TextPosition hit = layout.hitTest(35f, 30f);
        check(hit != null && hit.blockIndex == 0 && hit.charIndex == 3, "Hit test maps x=35 to char 3");

        // 2. 反向拖选：anchor > focus，跨块取子串并以 "\n" 连接
        TextSelectionModel.TextSelection rev = new TextSelectionModel.TextSelection(
            new TextSelectionModel.TextPosition(1, 2),
            new TextSelectionModel.TextPosition(0, 6));
        check("world\n你好".equals(layout.selectedText(rev)), "Reverse selection extracts cross-block text");

        // 3. 高亮矩形与手柄几何
        List<TextSelectionModel.Rect> rects = layout.selectionRects(rev);
        check(rects.size() == 2, "Cross-block selection yields 2 rects");
        TextSelectionModel.SelectionHandles handles = layout.handleGeometry(rev);
        check(handles != null && Math.abs(handles.start.docX - 70f) < 0.1f, "Start handle x matches offset");

        // 4. 分词选词（BreakIterator 词边界）
        TextSelectionModel.TextSelection word = layout.wordRange(new TextSelectionModel.TextPosition(0, 1));
        check(word != null && "Hello".equals(layout.selectedText(word)), "Word range selects Hello");

        // 5. 全选
        TextSelectionModel.TextSelection all = layout.allTextRange();
        check(all != null && "Hello world\n你好世界".equals(layout.selectedText(all)), "Select all joins blocks");

        // 6. 代理对夹紧（Emoji 😀 占 2 个 UTF-16 码元，索引 2 落在代理对中间）
        TextSelectionModel.TextBlockLayout emojiBlock = simpleBlock(2, 0f, 0f, "A\uD83D\uDE00B", 10f);
        TextSelectionModel.DocumentTextLayout emojiLayout =
            new TextSelectionModel.DocumentTextLayout(Collections.singletonList(emojiBlock));
        TextSelectionModel.TextPosition clamped = emojiLayout.hitTest(21f, 10f);
        check(clamped != null && (clamped.charIndex == 1 || clamped.charIndex == 3),
            "Surrogate pair boundary never splits UTF-16 pair");

        // 7. 逆时针旋转 90 度仿射矩阵逆变换命中
        float[] rot90 = new float[] {0f, 1f, -1f, 0f, 100f, 50f}; // local (x, y) -> (100 - y, 50 + x)
        float[] rotOffsets = new float[] {0f, 10f, 20f, 30f};
        TextSelectionModel.ArrayLineMetrics rotLine = new TextSelectionModel.ArrayLineMetrics(
            0f, 0f, 30f, 20f, 0f, 0, 3, 0, rotOffsets);
        TextSelectionModel.TextBlockLayout rotBlock = new TextSelectionModel.TextBlockLayout(
            0, 0, new TextSelectionModel.Rect(80f, 50f, 100f, 80f), rot90, "ABC",
            Collections.singletonList(rotLine));
        TextSelectionModel.DocumentTextLayout rotLayout =
            new TextSelectionModel.DocumentTextLayout(Collections.singletonList(rotBlock));
        TextSelectionModel.TextPosition rotHit = rotLayout.hitTest(90f, 65f); // local (15, 10)
        check(rotHit != null && rotHit.charIndex == 2, "Rotated block inverse hitTest");

        // 8. 结束手柄：跨块选区的 end 落在第二个块的字符 2 起点（局部 2*16=32，平移 10）
        check(handles.end.blockIndex == 1 && Math.abs(handles.end.docX - 42f) < 0.1f
            && Math.abs(handles.end.localX - 32f) < 0.1f,
            "End handle resolves into the following block");

        // 9. 块局部高亮矩形 + 块矩阵 + 文档包围盒三者自洽
        List<TextSelectionModel.BlockHighlightRect> blockRects = layout.blockSelectionRects(rev);
        boolean localOk = false;
        for (TextSelectionModel.BlockHighlightRect r : blockRects) {
            if (r.blockIndex == 1) {
                localOk = Math.abs(r.localRect.right - 32f) < 0.1f
                    && Math.abs(r.docBounds.right - 42f) < 0.1f
                    && Math.abs(r.transform[4] - 10f) < 0.1f;
            }
        }
        check(localOk, "Block highlight carries local rect, transform and doc bounds");

        // 10. 按块过滤只返回该块的高亮矩形
        List<TextSelectionModel.BlockHighlightRect> onlyB1 = layout.selectionRectsForBlock(rev, 1);
        boolean onlyB1Ok = !onlyB1.isEmpty();
        for (TextSelectionModel.BlockHighlightRect r : onlyB1) onlyB1Ok &= r.blockIndex == 1;
        check(onlyB1Ok, "selectionRectsForBlock filters by block index");

        // 11. 显式代理对边界夹紧
        check(TextSelectionModel.clampToCodePointBoundary("A\uD83D\uDE00B", 2) == 3
            && TextSelectionModel.clampToCodePointBoundary("A\uD83D\uDE00B", 1) == 1
            && TextSelectionModel.clampToCodePointBoundary("AB", 1) == 1,
            "clampToCodePointBoundary aligns to code point boundaries");

        // 12. 整行选区
        TextSelectionModel.TextSelection lineSel =
            layout.lineRange(new TextSelectionModel.TextPosition(0, 4));
        check(lineSel != null && "Hello world".equals(layout.selectedText(lineSel)),
            "lineRange selects the whole line");

        // 13. 空块不产生多余换行（全选拼接只在非空块之间连接）
        TextSelectionModel.DocumentTextLayout sparse = new TextSelectionModel.DocumentTextLayout(Arrays.asList(
            simpleBlock(0, 0f, 0f, "A", 10f),
            simpleBlock(1, 0f, 20f, "", 10f),
            simpleBlock(2, 0f, 40f, "B", 10f)));
        check("A\nB".equals(sparse.selectedText(sparse.allTextRange())),
            "Empty blocks are skipped when joining selected text");

        System.out.println("TextSelectionChecks passed: " + checks);
    }
}
