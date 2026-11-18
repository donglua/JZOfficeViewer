package cn.jingzhuan.lib.office;

import android.graphics.Canvas;
import android.graphics.Bitmap;
import android.graphics.Paint;
import android.graphics.Matrix;
import android.graphics.RectF;
import android.graphics.Path;
import android.graphics.Shader;
import android.graphics.LinearGradient;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.LinkedHashSet;
import java.util.Set;

final class OfficeRenderer {
    static final class CellImage {
        String image;
        final RectF rect = new RectF();
    }

    static final class Element {
        OfficeDocument.Element source;
        final List<OfficeTextLayout.Block> texts = new ArrayList<>();
        /**
         * 表格每个非空文本单元格在 {@link #texts} 中的起止范围，每项为
         * {@code {startTextIdx, endTextIdx}}（左闭右开），顺序与行优先遍历一致。
         * 非表格元素为空列表；选区模型据此把单元格聚合成独立文本块。
         */
        final List<int[]> cellTextRanges = new ArrayList<>();
        final List<RectF> cells = new ArrayList<>();
        /**
         * 与 {@link #cells} 严格一一对应的锚点坐标，每项为 {@code {row, column}}。
         * 合并区域只在锚点登记一次，用于按 (r, c) 查单元格底纹、边框与垂直对齐。
         */
        final List<int[]> cellAnchors = new ArrayList<>();
        final List<CellImage> cellImages = new ArrayList<>();
        float x, y, width, height;
        final Matrix transform = new Matrix();
        final RectF bounds = new RectF();
        final List<Path> paths = new ArrayList<>();
        Shader fillShader;
    }

    static final class Page {
        float y, width, height;
        int background;
        boolean ready;
        final List<Element> elements = new ArrayList<>();
        final List<Element> zElements = new ArrayList<>();
    }

    final List<Page> pages = new ArrayList<>();
    float width, height;
    private OfficeDocument document;
    private int preparedFirst, preparedLast = -1;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
    private final RectF drawRect = new RectF();
    private final RectF textBounds = new RectF();

    void clear() {
        pages.clear(); document = null; width = height = 0;
        preparedFirst = 0; preparedLast = -1;
    }

    void adopt(OfficeRenderer prepared) {
        clear();
        document = prepared.document;
        width = prepared.width;
        height = prepared.height;
        preparedFirst = prepared.preparedFirst;
        preparedLast = prepared.preparedLast;
        pages.addAll(prepared.pages);
    }

    void layout(OfficeDocument document) {
        layout(document, 0);
    }

    /**
     * 排版文档；{@code viewportHeight} 大于 0 时按首屏限定排版范围。
     * DOCX 是连续流，正文块可以超出视口任意长：只为封面排版时，越过视口底部后即可停止，
     * 已排好的前缀与完整排版的前缀逐块一致。PPTX / XLSX 由页与表本身限定，此参数无作用。
     */
    void layout(OfficeDocument document, float viewportHeight) {
        clear(); this.document = document; width = Math.max(1, document.width);
        boolean limitViewport = viewportHeight > 0;
        if (document.kind == OfficeDocument.Kind.DOCX) {
            float maxMargin = Math.max(36, (width - 120) / 2);
            float marginLeft = Math.min(maxMargin, document.marginLeft > 0 ? document.marginLeft : 72);
            float marginRight = Math.min(maxMargin, document.marginRight > 0 ? document.marginRight : 72);
            float contentX = marginLeft;
            float contentWidth = Math.max(1, width - marginLeft - marginRight);
            Page page = new Page(); page.width = width; page.background = 0xffffffff;
            List<Element> behindElements = new ArrayList<>();
            List<Element> flowElements = new ArrayList<>();
            List<Element> frontElements = new ArrayList<>();
            float[] maxBottom = {32f};
            float y = 32f;
            // 页眉作为文档流开头（随内容滚动）
            y = placeDocxBlocks(document.headerBlocks, y, 32f, width, contentX, contentWidth,
                false, 0f, document, page, behindElements, flowElements, frontElements, maxBottom);
            if (!document.headerBlocks.isEmpty()) y += 10f; // 页眉与正文间距
            // 正文
            y = placeDocxBlocks(document.blocks, y, y, width, contentX, contentWidth,
                limitViewport, viewportHeight, document, page, behindElements, flowElements, frontElements, maxBottom);
            // 页脚作为文档流末尾（随内容滚动）
            if (!document.footerBlocks.isEmpty()) y += 10f; // 正文与页脚间距
            y = placeDocxBlocks(document.footerBlocks, y, y, width, contentX, contentWidth,
                false, 0f, document, page, behindElements, flowElements, frontElements, maxBottom);
            page.zElements.addAll(behindElements);
            page.zElements.addAll(flowElements);
            page.zElements.addAll(frontElements);
            page.height = Math.max(300, Math.max(y, maxBottom[0]) + 32); page.ready = true; pages.add(page);
            // 首屏排版只保证视口内的高度，超出部分本就不参与封面绘制
            height = limitViewport ? Math.min(page.height, viewportHeight) : page.height;
        } else {
            for (OfficeDocument.Page source : document.pages) {
                Page page = new Page(); page.y = height;
                page.width = source.width; page.height = source.height; page.background = source.background;
                pages.add(page); height += page.height + 16;
            }
            height = Math.max(0, height - 16);
            if (!pages.isEmpty()) preparePages(0, pages.get(0).height);
        }
    }

    void preparePages(float top, float bottom) {
        if (document == null || document.kind != OfficeDocument.Kind.PPTX || pages.isEmpty()) return;
        int first = Math.max(0, pageAt(top) - 1);
        int last = pageAt(bottom);
        if (last > 0 && pages.get(last).y > bottom) last--;
        last = Math.min(pages.size() - 1, last + 1);
        if (first == preparedFirst && last == preparedLast) return;
        for (int i = preparedFirst; i <= preparedLast; i++) {
            if (i >= first && i <= last) continue;
            Page page = pages.get(i);
            page.elements.clear(); page.ready = false;
        }
        // Slide dimensions remain available for navigation after their layouts are released.
        for (int i = first; i <= last; i++) {
            Page page = pages.get(i);
            if (page.ready) continue;
            for (OfficeDocument.Element source : document.pages.get(i).elements) {
                page.elements.add(element(source, source.width, false, document));
            }
            page.ready = true;
        }
        preparedFirst = first; preparedLast = last;
    }

    private int pageAt(float y) {
        int low = 0, high = pages.size() - 1;
        while (low < high) {
            int middle = (low + high) >>> 1;
            Page page = pages.get(middle);
            if (page.y + page.height < y) low = middle + 1;
            else high = middle;
        }
        return low;
    }

    private Element element(OfficeDocument.Element source, float available, boolean flow, OfficeDocument document) {
        return element(source, available, flow, document, 0f, 0f, null);
    }

    private Element element(OfficeDocument.Element source, float available, boolean flow, OfficeDocument document,
                            float flowX, float flowY, List<OfficeTextLayout.WrapObstacle> obstacles) {
        Element d = new Element(); d.source = source; d.x = source.x; d.y = source.y;
        boolean floating = flow && !"INLINE".equals(source.wrapMode);
        boolean fixedShape = flow && source.type != OfficeDocument.Type.TEXT
            && source.type != OfficeDocument.Type.IMAGE && source.type != OfficeDocument.Type.TABLE;
        d.width = flow
            ? Math.max(1, fixedShape && source.width > 0
                ? (floating ? source.width : Math.min(available, source.width))
                : source.type == OfficeDocument.Type.TABLE && source.width > 0
                    ? Math.min(source.width, available)
                    : (floating && source.width > 0 ? source.width : available))
            : source.width;
        d.height = flow ? Math.max(1, source.height) : source.height;
        for (OfficeDocument.Path sourcePath : source.paths) {
            Path path = new Path();
            for (OfficeDocument.Command command : sourcePath.commands) {
                float[] p = command.points;
                if ("MOVE".equals(command.op)) path.moveTo(p[0], p[1]);
                else if ("LINE".equals(command.op)) path.lineTo(p[0], p[1]);
                else if ("QUAD".equals(command.op)) path.quadTo(p[0], p[1], p[2], p[3]);
                else if ("CUBIC".equals(command.op)) path.cubicTo(p[0], p[1], p[2], p[3], p[4], p[5]);
                else if ("CLOSE".equals(command.op)) path.close();
            }
            d.paths.add(path);
        }
        if (source.fillGradient != null) {
            d.fillShader = gradient(source.fillGradient);
        }
        if (source.type == OfficeDocument.Type.IMAGE && flow) {
            float w = source.width > 0 ? source.width : available;
            float h = source.height > 0 ? source.height : 100;
            if (floating) {
                d.width = Math.max(1, w);
                d.height = Math.max(1, h);
            } else {
                d.width = Math.min(available, w); d.height = h * d.width / Math.max(1, w);
            }
        } else if (source.type == OfficeDocument.Type.TABLE) {
            int cols = 0;
            for (List<List<OfficeDocument.Paragraph>> row : source.rows) cols = Math.max(cols, row.size());
            float total = 0;
            for (Float w : source.columnWidths) total += Math.max(1, w);
            float[] colX = new float[cols + 1];
            for (int c = 0; c < cols; c++) {
                float w = source.columnWidths.size() == cols && total > 0 ? d.width * Math.max(1, source.columnWidths.get(c)) / total : d.width / Math.max(1, cols);
                colX[c + 1] = colX[c] + w;
            }
            int numRows = source.rows.size();
            float[] rowTops = new float[numRows + 1];
            float y = 0;
            for (int r = 0; r < numRows; r++) {
                rowTops[r] = y;
                float rowHeight = 20;
                List<List<OfficeDocument.Paragraph>> row = source.rows.get(r);
                for (int c = 0; c < cols; c++) {
                    SpreadsheetDocument.CellRange m = findMerge(source.merges, r, c);
                    if (m != null && (m.startRow != r || m.startColumn != c)) continue;
                    float x1 = colX[c];
                    float x2 = m != null ? colX[Math.min(cols, (int) m.endColumn + 1)] : colX[c + 1];
                    float cellW = Math.max(1, x2 - x1);
                    List<OfficeDocument.Paragraph> cell = c < row.size() ? row.get(c) : Collections.emptyList();
                    if (!cell.isEmpty()) {
                        float availW = Math.max(1, cellW - 10);
                        float cellContentH = 0;
                        for (OfficeDocument.Paragraph para : cell) {
                            if (para.image != null && para.imageWidth != null && para.imageHeight != null
                                    && para.imageWidth > 0 && para.imageHeight > 0) {
                                float fitW = Math.min(availW, para.imageWidth);
                                float fitH = para.imageHeight * (fitW / para.imageWidth);
                                cellContentH += fitH + Math.max(0, para.before) + Math.max(0, para.after);
                            }
                        }
                        List<OfficeDocument.Paragraph> textParas = new ArrayList<>();
                        for (OfficeDocument.Paragraph p : cell) {
                            if (p.image == null) textParas.add(p);
                        }
                        if (!textParas.isEmpty()) {
                            cellContentH += OfficeTextLayout.measure(textParas, availW, !flow);
                        }
                        rowHeight = Math.max(rowHeight, cellContentH + 10);
                    }
                }
                y += rowHeight;
            }
            rowTops[numRows] = y;
            for (int r = 0; r < numRows; r++) {
                List<List<OfficeDocument.Paragraph>> row = source.rows.get(r);
                for (int c = 0; c < cols; c++) {
                    SpreadsheetDocument.CellRange m = findMerge(source.merges, r, c);
                    float x1, x2, y1, y2;
                    if (m != null) {
                        if (m.startRow != r || m.startColumn != c) continue;
                        x1 = colX[c];
                        x2 = colX[Math.min(cols, (int) m.endColumn + 1)];
                        y1 = rowTops[r];
                        y2 = rowTops[Math.min(numRows, (int) m.endRow + 1)];
                        d.cells.add(new RectF(x1, y1, x2, y2));
                    } else {
                        x1 = colX[c];
                        x2 = colX[c + 1];
                        y1 = rowTops[r];
                        y2 = rowTops[r + 1];
                        d.cells.add(new RectF(x1, y1, x2, y2));
                    }
                    // 锚点与 cells 同步登记，保证两者索引严格一一对应
                    d.cellAnchors.add(new int[] {r, c});
                    float cellW = Math.max(1, x2 - x1);
                    float cellH = Math.max(1, y2 - y1);
                    List<OfficeDocument.Paragraph> cell = c < row.size() ? row.get(c) : Collections.emptyList();
                    if (!cell.isEmpty()) {
                        float availW = Math.max(1, cellW - 10);
                        float cellContentH = 0;
                        for (OfficeDocument.Paragraph para : cell) {
                            if (para.image != null && para.imageWidth != null && para.imageHeight != null
                                    && para.imageWidth > 0 && para.imageHeight > 0) {
                                float fitW = Math.min(availW, para.imageWidth);
                                float fitH = para.imageHeight * (fitW / para.imageWidth);
                                cellContentH += fitH + Math.max(0, para.before) + Math.max(0, para.after);
                            }
                        }
                        List<OfficeDocument.Paragraph> textParas = new ArrayList<>();
                        for (OfficeDocument.Paragraph p : cell) {
                            if (p.image == null) textParas.add(p);
                        }
                        if (!textParas.isEmpty()) {
                            cellContentH += OfficeTextLayout.measure(textParas, availW, !flow);
                        }
                        float vOffset = cellVerticalOffset(source, r, c, cellH, cellContentH);
                        float curY = y1 + vOffset;
                        int startTextIdx = d.texts.size();
                        for (OfficeDocument.Paragraph para : cell) {
                            if (para.image != null && para.imageWidth != null && para.imageHeight != null
                                    && para.imageWidth > 0 && para.imageHeight > 0) {
                                curY += Math.max(0, para.before);
                                float fitW = Math.min(availW, para.imageWidth);
                                float fitH = para.imageHeight * (fitW / para.imageWidth);
                                float imgX = x1 + 5;
                                if (para.alignment == 1) {
                                    imgX += Math.max(0, (availW - fitW) / 2.0f);
                                } else if (para.alignment == 2) {
                                    imgX += Math.max(0, availW - fitW);
                                }
                                CellImage ci = new CellImage();
                                ci.image = para.image;
                                ci.rect.set(imgX, curY, imgX + fitW, curY + fitH);
                                d.cellImages.add(ci);
                                curY += fitH + Math.max(0, para.after);
                            } else {
                                curY = OfficeTextLayout.append(Collections.singletonList(para), x1 + 5, curY, availW, d.texts, !flow);
                            }
                        }
                        // 只登记产生了排版块的非空单元格，保证聚合时的块顺序与 texts 一致
                        if (d.texts.size() > startTextIdx) {
                            d.cellTextRanges.add(new int[] {startTextIdx, d.texts.size()});
                        }
                    }
                }
            }
            if (flow) d.height = Math.max(1, y);
            else if (y > d.height) document.warn("Table content exceeds its slide bounds and is clipped");
        } else if (!source.paragraphs.isEmpty()) {
            boolean fixedBox = !flow || fixedShape || (floating && source.width > 0 && source.height > 0);
            float padding = fixedBox ? Math.max(0, source.padding) : 0;
            List<OfficeTextLayout.WrapObstacle> localObstacles = (!fixedBox && obstacles != null && !obstacles.isEmpty())
                ? localizeObstacles(obstacles, flowX, flowY) : null;
            float textHeight = OfficeTextLayout.append(source.paragraphs, padding, padding,
                Math.max(1, d.width - 2 * padding), d.texts, !flow, !fixedBox || source.textWrap, localObstacles) + padding;
            if (!fixedBox) d.height = Math.max(1, textHeight);
            else {
                if (!flow && textHeight > d.height + 1) document.warn("Text exceeds its slide box and is clipped");
                if (flow && source.height <= 0) d.height = Math.max(1, textHeight);
                float remaining = Math.max(0, d.height - textHeight);
                float offset = source.verticalAlignment == OfficeDocument.VerticalAlignment.CENTER ? remaining / 2
                    : source.verticalAlignment == OfficeDocument.VerticalAlignment.BOTTOM ? remaining : 0;
                for (OfficeTextLayout.Block block : d.texts) block.y += offset;
            }
        }
        position(d, flow);
        return d;
    }

    private float placeDocxBlocks(List<OfficeDocument.Element> blocks, float y, float sectionMinY, float pageWidth,
                                float contentX, float contentWidth, boolean limitViewport, float viewportHeight,
                                OfficeDocument document, Page page,
                                List<Element> behindElements, List<Element> flowElements, List<Element> frontElements,
                                float[] maxBottom) {
        List<OfficeTextLayout.WrapObstacle> activeObstacles = new ArrayList<>();
        for (OfficeDocument.Element source : blocks) {
            if (limitViewport && y > viewportHeight) break;
            boolean floating = !"INLINE".equals(source.wrapMode);
            if (!floating) {
                pruneObstacles(activeObstacles, y);
                if (source.type == OfficeDocument.Type.TABLE && !activeObstacles.isEmpty()) {
                    y = Math.max(y, maxObstacleBottom(activeObstacles) + 6f);
                    activeObstacles.clear();
                }
            }
            Element drawn = element(source, contentWidth, true, document, contentX, y, activeObstacles);
            if (floating) {
                float floatX;
                if (source.horizontalAlign == 1) floatX = contentX;
                else if (source.horizontalAlign == 2) floatX = Math.max(0f, contentX + (contentWidth - drawn.width) / 2f);
                else if (source.horizontalAlign == 3) floatX = Math.max(0f, contentX + contentWidth - drawn.width);
                else floatX = Math.max(0f, Math.min(Math.max(0f, pageWidth - drawn.width), source.x));
                float floatY = Math.max(sectionMinY, y + source.y);
                drawn.x = floatX;
                if ("TOP_AND_BOTTOM".equals(source.wrapMode)) {
                    float clearY = Math.max(y, maxObstacleBottom(activeObstacles));
                    drawn.y = Math.max(floatY, clearY + Math.max(0f, source.distTop));
                    y = Math.max(y, drawn.y + drawn.height + Math.max(0f, source.distBottom) + 6f);
                    pruneObstacles(activeObstacles, y);
                } else {
                    drawn.y = floatY;
                    if (!"NONE".equals(source.wrapMode)) {
                        OfficeTextLayout.WrapObstacle obs = new OfficeTextLayout.WrapObstacle();
                        obs.top = drawn.y - Math.max(0f, source.distTop);
                        obs.bottom = drawn.y + drawn.height + Math.max(0f, source.distBottom);
                        obs.left = drawn.x - Math.max(0f, source.distLeft);
                        obs.right = drawn.x + drawn.width + Math.max(0f, source.distRight);
                        obs.side = source.horizontalAlign == 1 ? -1
                            : source.horizontalAlign == 3 ? 1
                            : (drawn.x + drawn.width * 0.5f <= contentX + contentWidth * 0.5f ? -1 : 1);
                        if (obs.left <= contentX + 40f && obs.right >= contentX + contentWidth - 40f) {
                            y = Math.max(y, obs.bottom + 6f);
                            pruneObstacles(activeObstacles, y);
                        } else {
                            activeObstacles.add(obs);
                        }
                    }
                }
                position(drawn, true);
                page.elements.add(drawn);
                (source.behindDoc ? behindElements : frontElements).add(drawn);
                maxBottom[0] = Math.max(maxBottom[0], drawn.y + drawn.height);
            } else {
                drawn.x = contentX;
                if (source.horizontalAlign == 2) {
                    drawn.x += Math.max(0f, (contentWidth - drawn.width) / 2f);
                } else if (source.horizontalAlign == 3) {
                    drawn.x += Math.max(0f, contentWidth - drawn.width);
                } else if (source.horizontalAlign == 0 && source.type == OfficeDocument.Type.IMAGE) {
                    drawn.x += Math.max(0f, (contentWidth - drawn.width) / 2f);
                }
                if (!activeObstacles.isEmpty() && source.type != OfficeDocument.Type.TEXT) {
                    float clearBottom = y;
                    for (OfficeTextLayout.WrapObstacle obs : activeObstacles) {
                        if (drawn.x < obs.right && drawn.x + drawn.width > obs.left) {
                            clearBottom = Math.max(clearBottom, obs.bottom + 6f);
                        }
                    }
                    if (clearBottom > y) {
                        y = clearBottom;
                        pruneObstacles(activeObstacles, y);
                    }
                }
                drawn.y = y;
                position(drawn, true);
                page.elements.add(drawn);
                flowElements.add(drawn);
                y += drawn.height + 6f;
                maxBottom[0] = Math.max(maxBottom[0], y);
            }
        }
        if (!activeObstacles.isEmpty()) {
            y = Math.max(y, maxObstacleBottom(activeObstacles) + 6f);
            activeObstacles.clear();
        }
        return y;
    }

    private static List<OfficeTextLayout.WrapObstacle> localizeObstacles(
            List<OfficeTextLayout.WrapObstacle> obstacles, float originX, float originY) {
        List<OfficeTextLayout.WrapObstacle> local = new ArrayList<>();
        for (OfficeTextLayout.WrapObstacle obs : obstacles) {
            if (obs.bottom <= originY) continue;
            OfficeTextLayout.WrapObstacle shifted = new OfficeTextLayout.WrapObstacle();
            shifted.top = obs.top - originY;
            shifted.bottom = obs.bottom - originY;
            shifted.left = obs.left - originX;
            shifted.right = obs.right - originX;
            shifted.side = obs.side;
            local.add(shifted);
        }
        return local;
    }

    private static void pruneObstacles(List<OfficeTextLayout.WrapObstacle> obstacles, float y) {
        for (int i = obstacles.size() - 1; i >= 0; i--) {
            if (obstacles.get(i).bottom <= y) obstacles.remove(i);
        }
    }

    private static float maxObstacleBottom(List<OfficeTextLayout.WrapObstacle> obstacles) {
        float max = 0f;
        for (OfficeTextLayout.WrapObstacle obs : obstacles) {
            if (obs.bottom > max) max = obs.bottom;
        }
        return max;
    }

    private Shader gradient(OfficeDocument.GradientFill source) {
        float[] p = source.points;
        Shader shader = new LinearGradient(p[0], p[1], p[2], p[3], source.colors, source.positions, Shader.TileMode.CLAMP);
        if (source.transform != null) {
            float[] m = source.transform;
            Matrix local = new Matrix();
            local.setValues(new float[] {m[0], m[2], m[4], m[1], m[3], m[5], 0, 0, 1});
            shader.setLocalMatrix(local);
        }
        return shader;
    }

    private void position(Element d, boolean flow) {
        OfficeDocument.Element e = d.source;
        float[] m = e.transform;
        d.transform.setValues(new float[] {m[0], m[2], m[4], m[1], m[3], m[5], 0, 0, 1});
        if (flow) d.transform.preTranslate(d.x, d.y);
        float stroke = (e.stroke >>> 24) == 0 ? 0 : Math.max(0, e.strokeWidth) / 2;
        d.bounds.set(-stroke, -stroke, d.width + stroke, d.height + stroke);
        if (!e.textWrap) for (OfficeTextLayout.Block block : d.texts) {
            d.bounds.union(block.x, block.y, block.x + block.layout.getWidth(), block.y + block.layout.getHeight());
        }
        d.transform.mapRect(d.bounds);
    }

    Set<String> visibleImages(float left, float top, float right, float bottom, int currentPage) {
        preparePages(top, bottom);
        Set<String> parts = new LinkedHashSet<>();
        for (int index = -1; index < pages.size(); index++) {
            if (index == currentPage || (index == -1 && (currentPage < 0 || currentPage >= pages.size()))) continue;
            Page page = pages.get(index == -1 ? currentPage : index);
            if (page.y + page.height < top || page.y > bottom) continue;
            float clippedLeft = Math.max(0, left), clippedRight = Math.min(page.width, right);
            float clippedTop = Math.max(page.y, top), clippedBottom = Math.min(page.y + page.height, bottom);
            if (clippedLeft >= clippedRight || clippedTop >= clippedBottom) continue;
            // Frontmost images on the current slide get spare decode budget before backgrounds.
            List<Element> paintOrder = page.zElements.isEmpty() ? page.elements : page.zElements;
            for (int element = paintOrder.size() - 1; element >= 0; element--) {
                Element e = paintOrder.get(element);
                if (e.source.image != null) {
                    RectF bounds = e.bounds;
                    if (bounds.right > clippedLeft && bounds.left < clippedRight
                        && page.y + bounds.bottom > clippedTop && page.y + bounds.top < clippedBottom) parts.add(e.source.image);
                }
                for (CellImage ci : e.cellImages) {
                    parts.add(ci.image);
                }
            }
        }
        return parts;
    }

    void draw(Canvas canvas, float visibleTop, float visibleBottom, Map<String, Bitmap> images) {
        preparePages(visibleTop, visibleBottom);
        for (Page page : pages) {
            if (page.y + page.height < visibleTop || page.y > visibleBottom) continue;
            canvas.save(); canvas.translate(0, page.y); canvas.clipRect(0, 0, page.width, page.height);
            paint.setStyle(Paint.Style.FILL); paint.setColor(page.background);
            canvas.drawRect(0, 0, page.width, page.height, paint);
            List<Element> paintOrder = page.zElements.isEmpty() ? page.elements : page.zElements;
            for (Element e : paintOrder) {
                if (e.bounds.bottom >= visibleTop - page.y && e.bounds.top <= visibleBottom - page.y) drawElement(canvas, e, images);
            }
            canvas.restore();
        }
    }

    private void drawElement(Canvas canvas, Element d, Map<String, Bitmap> images) {
        OfficeDocument.Element e = d.source;
        canvas.save(); canvas.concat(d.transform);
        drawRect.set(0, 0, d.width, d.height);
        RectF rect = drawRect;
        if (e.type == OfficeDocument.Type.PATH) {
            for (int i = 0; i < d.paths.size(); i++) {
                OfficeDocument.Path sourcePath = e.paths.get(i);
                if (sourcePath.fill) {
                    paint.setStyle(Paint.Style.FILL); paint.setShader(d.fillShader); paint.setColor(d.fillShader == null ? e.fill : 0xffffffff);
                    canvas.drawPath(d.paths.get(i), paint);
                }
                if (sourcePath.stroke && e.stroke != 0) {
                    paint.setShader(null); paint.setStyle(Paint.Style.STROKE); paint.setStrokeWidth(e.strokeWidth); paint.setColor(e.stroke);
                    canvas.drawPath(d.paths.get(i), paint);
                }
            }
            paint.setShader(null);
        } else {
            paint.setStyle(Paint.Style.FILL); paint.setShader(d.fillShader); paint.setColor(d.fillShader == null ? e.fill : 0xffffffff);
            if (e.type == OfficeDocument.Type.ELLIPSE) canvas.drawOval(rect, paint);
            else if (e.type != OfficeDocument.Type.LINE) canvas.drawRect(rect, paint);
            paint.setShader(null); paint.setStyle(Paint.Style.STROKE); paint.setStrokeWidth(e.strokeWidth); paint.setColor(e.stroke);
            if (e.type == OfficeDocument.Type.ELLIPSE) canvas.drawOval(rect, paint);
            else if (e.type == OfficeDocument.Type.LINE) canvas.drawLine(0, 0, e.width, e.height, paint);
            else if (e.stroke != 0) canvas.drawRect(rect, paint);
        }
        if (e.type == OfficeDocument.Type.TEXT) {
            textBounds.set(rect);
            for (OfficeTextLayout.Block block : d.texts) {
                textBounds.top = Math.min(textBounds.top, block.y);
                textBounds.bottom = Math.max(textBounds.bottom, block.y + block.layout.getHeight());
                if (!e.textWrap) {
                    textBounds.left = Math.min(textBounds.left, block.x);
                    textBounds.right = Math.max(textBounds.right, block.x + block.layout.getWidth());
                }
            }
            canvas.clipRect(textBounds);
        } else canvas.clipRect(rect);
        paint.setStyle(Paint.Style.FILL);
        if (e.type == OfficeDocument.Type.IMAGE) {
            Bitmap bitmap = images.get(e.image);
            if (bitmap != null) {
                paint.setColor(0xffffffff);
                if (e.imageBounds != null) {
                    float[] bounds = e.imageBounds;
                    rect.set(bounds[0], bounds[1], bounds[2], bounds[3]);
                }
                canvas.drawBitmap(bitmap, null, rect, paint);
            } else { paint.setColor(0xffe0e0e0); canvas.drawRect(rect, paint); }
        }
        if (e.type == OfficeDocument.Type.TABLE) {
            drawTableCellFills(canvas, e, d);
            if (e.cellBorders.isEmpty()) {
                // 无单元格级四边边框时沿用表格级统一网格框
                paint.setColor(e.stroke != 0 ? e.stroke : 0xffb7bec7);
                paint.setStyle(Paint.Style.STROKE);
                paint.setStrokeWidth(e.strokeWidth > 0 ? e.strokeWidth : 0.6f);
                for (RectF cell : d.cells) canvas.drawRect(cell, paint);
            } else {
                drawTableCellBorders(canvas, e, d);
            }
            for (CellImage ci : d.cellImages) {
                Bitmap bitmap = images.get(ci.image);
                if (bitmap != null) {
                    paint.setColor(0xffffffff);
                    paint.setStyle(Paint.Style.FILL);
                    canvas.drawBitmap(bitmap, null, ci.rect, paint);
                }
            }
        }
        for (OfficeTextLayout.Block block : d.texts) {
            float bx = block.x;
            float by = block.y;
            float bw = block.layout.getWidth();
            float bh = block.layout.getHeight();
            if (block.background != 0) {
                paint.setShader(null);
                paint.setStyle(Paint.Style.FILL);
                paint.setColor(block.background);
                canvas.drawRect(bx, by, bx + bw, by + bh, paint);
            }
            if (block.borderWidth > 0) {
                paint.setShader(null);
                paint.setStyle(Paint.Style.STROKE);
                paint.setStrokeWidth(block.borderWidth);
                if (block.borderTop != 0) {
                    paint.setColor(block.borderTop);
                    canvas.drawLine(bx, by, bx + bw, by, paint);
                }
                if (block.borderBottom != 0) {
                    paint.setColor(block.borderBottom);
                    canvas.drawLine(bx, by + bh, bx + bw, by + bh, paint);
                }
                if (block.borderLeft != 0) {
                    paint.setColor(block.borderLeft);
                    canvas.drawLine(bx, by, bx, by + bh, paint);
                }
                if (block.borderRight != 0) {
                    paint.setColor(block.borderRight);
                    canvas.drawLine(bx + bw, by, bx + bw, by + bh, paint);
                }
            }
            canvas.save(); canvas.translate(bx, by); block.layout.draw(canvas); canvas.restore();
        }
        canvas.restore();
    }

    /**
     * 绘制单元格底纹。
     *
     * 直接按可见单元格的锚点 (r, c) 查 cellFills，不再按顺序递增下标：
     * 存在合并单元格时非锚点会被跳过，顺序递增会把后续底纹画到错误的矩形上。
     */
    private void drawTableCellFills(Canvas canvas, OfficeDocument.Element e, Element d) {
        if (e.cellFills.isEmpty() || d.cellAnchors.isEmpty()) return;
        paint.setShader(null); paint.setStyle(Paint.Style.FILL);
        int count = Math.min(d.cells.size(), d.cellAnchors.size());
        for (int index = 0; index < count; index++) {
            int[] anchor = d.cellAnchors.get(index);
            int fill = cellFillAt(e, anchor[0], anchor[1]);
            if ((fill >>> 24) == 0) continue;
            paint.setColor(fill);
            canvas.drawRect(d.cells.get(index), paint);
        }
    }

    /**
     * 按单元格四边独立边框绘制线段。
     *
     * 顺序为 [top, right, bottom, left]，线宽使用该边自己的 width；仅绘制
     * {@code width > 0} 且颜色 alpha 不为 0 的边，因此全 none 的无框表不会再被默认灰框覆盖。
     */
    private void drawTableCellBorders(Canvas canvas, OfficeDocument.Element e, Element d) {
        paint.setShader(null);
        paint.setStyle(Paint.Style.STROKE);
        int count = Math.min(d.cells.size(), d.cellAnchors.size());
        for (int index = 0; index < count; index++) {
            int[] anchor = d.cellAnchors.get(index);
            OfficeDocument.CellBorder[] edges = cellBorderAt(e, anchor[0], anchor[1]);
            if (edges == null) continue;
            RectF cell = d.cells.get(index);
            for (int edge = 0; edge < 4 && edge < edges.length; edge++) {
                OfficeDocument.CellBorder border = edges[edge];
                if (border == null || !(border.width > 0) || (border.color >>> 24) == 0) continue;
                paint.setColor(border.color);
                paint.setStrokeWidth(border.width);
                switch (edge) {
                    case 0: canvas.drawLine(cell.left, cell.top, cell.right, cell.top, paint); break;
                    case 1: canvas.drawLine(cell.right, cell.top, cell.right, cell.bottom, paint); break;
                    case 2: canvas.drawLine(cell.left, cell.bottom, cell.right, cell.bottom, paint); break;
                    default: canvas.drawLine(cell.left, cell.top, cell.left, cell.bottom, paint); break;
                }
            }
        }
    }

    /**
     * 按单元格垂直对齐计算文字起排偏移，缺省（无 cellValigns 或坐标越界）按 1 垂直居中。
     *
     * <ul>
     *   <li>0 顶部：恒为 5；</li>
     *   <li>1 垂直居中：剩余空间充足时居中，否则回退 5；</li>
     *   <li>2 底部：剩余空间充足时贴近底部并预留 5 的内边距，否则回退 5。</li>
     * </ul>
     * 查询坐标必须是合并区域的锚点 (r, c)，与文字实际存放的单元格一致。
     */
    static float cellVerticalOffset(OfficeDocument.Element element, int r, int c,
                                    float cellH, float cellContentH) {
        int valign = 1;
        if (element.cellValigns != null && r >= 0 && r < element.cellValigns.size()) {
            List<Integer> rowValigns = element.cellValigns.get(r);
            if (rowValigns != null && c >= 0 && c < rowValigns.size()) {
                Integer value = rowValigns.get(c);
                if (value != null) valign = value;
            }
        }
        // 剩余空间不足时任何对齐方式都退回 5 的基准内边距，避免文字被贴边裁切
        if (!(cellH > cellContentH + 10) || valign == 0) return 5;
        if (valign == 2) return Math.max(5, cellH - cellContentH - 5);
        return Math.max(5, (cellH - cellContentH) / 2.0f);
    }

    /** 取单元格四边边框；无 cellBorders 或坐标越界时返回 null，由调用方回退统一网格框 */
    private static OfficeDocument.CellBorder[] cellBorderAt(OfficeDocument.Element element, int r, int c) {
        if (element.cellBorders == null || r < 0 || r >= element.cellBorders.size()) return null;
        List<OfficeDocument.CellBorder[]> row = element.cellBorders.get(r);
        if (row == null || c < 0 || c >= row.size()) return null;
        return row.get(c);
    }

    /** 取单元格底纹颜色；无 cellFills 或坐标越界时返回 0（透明） */
    private static int cellFillAt(OfficeDocument.Element element, int r, int c) {
        if (element.cellFills == null || r < 0 || r >= element.cellFills.size()) return 0;
        List<Integer> row = element.cellFills.get(r);
        if (row == null || c < 0 || c >= row.size()) return 0;
        Integer fill = row.get(c);
        return fill == null ? 0 : fill;
    }

    static SpreadsheetDocument.CellRange findMerge(List<SpreadsheetDocument.CellRange> merges, int r, int c) {
        if (merges == null) return null;
        for (SpreadsheetDocument.CellRange m : merges) {
            if (r >= m.startRow && r <= m.endRow && c >= m.startColumn && c <= m.endColumn) return m;
        }
        return null;
    }
}
