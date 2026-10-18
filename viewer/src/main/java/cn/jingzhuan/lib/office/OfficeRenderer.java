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
    static final class Element {
        OfficeDocument.Element source;
        final List<OfficeTextLayout.Block> texts = new ArrayList<>();
        final List<RectF> cells = new ArrayList<>();
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
    }

    final List<Page> pages = new ArrayList<>();
    float width, height;
    private OfficeDocument document;
    private int preparedFirst, preparedLast = -1;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);

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
        clear(); this.document = document; width = Math.max(1, document.width);
        if (document.kind == OfficeDocument.Kind.DOCX) {
            Page page = new Page(); page.width = width; page.background = 0xffffffff;
            float y = 32;
            for (OfficeDocument.Element source : document.blocks) {
                Element drawn = element(source, width - 64, true, document);
                drawn.x = 32; drawn.y = y;
                if (source.type == OfficeDocument.Type.IMAGE) drawn.x += (width - 64 - drawn.width) / 2;
                position(drawn, true);
                page.elements.add(drawn); y += drawn.height + 6;
            }
            page.height = Math.max(300, y + 32); page.ready = true; pages.add(page); height = page.height;
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
        Element d = new Element(); d.source = source; d.x = source.x; d.y = source.y;
        d.width = flow ? Math.max(1, source.type == OfficeDocument.Type.TABLE && source.width > 0 ? Math.min(source.width, available) : available) : source.width;
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
            d.width = Math.min(available, w); d.height = h * d.width / Math.max(1, w);
        } else if (source.type == OfficeDocument.Type.TABLE) {
            int cols = 0;
            for (List<List<OfficeDocument.Paragraph>> row : source.rows) cols = Math.max(cols, row.size());
            float total = 0;
            for (Float w : source.columnWidths) total += Math.max(1, w);
            float y = 0;
            for (List<List<OfficeDocument.Paragraph>> row : source.rows) {
                float x = 0, rowHeight = 20;
                int first = d.cells.size();
                for (int c = 0; c < cols; c++) {
                    float w = source.columnWidths.size() == cols && total > 0 ? d.width * Math.max(1, source.columnWidths.get(c)) / total : d.width / Math.max(1, cols);
                    List<OfficeDocument.Paragraph> cell = c < row.size() ? row.get(c) : Collections.emptyList();
                    rowHeight = Math.max(rowHeight, OfficeTextLayout.append(cell, x + 5, y + 5, Math.max(1, w - 10), d.texts, !flow) - y + 5);
                    d.cells.add(new RectF(x, y, x + w, y)); x += w;
                }
                for (int i = first; i < d.cells.size(); i++) d.cells.get(i).bottom = y + rowHeight;
                y += rowHeight;
            }
            if (flow) d.height = Math.max(1, y);
            else if (y > d.height) document.warn("Table content exceeds its slide bounds and is clipped");
        } else if (!source.paragraphs.isEmpty()) {
            float padding = flow ? 0 : Math.max(0, source.padding);
            float textHeight = OfficeTextLayout.append(source.paragraphs, padding, padding,
                Math.max(1, d.width - 2 * padding), d.texts, !flow, flow || source.textWrap) + padding;
            if (flow) d.height = Math.max(1, textHeight);
            else {
                if (textHeight > d.height + 1) document.warn("Text exceeds its slide box and is clipped");
                float remaining = Math.max(0, d.height - textHeight);
                float offset = source.verticalAlignment == OfficeDocument.VerticalAlignment.CENTER ? remaining / 2
                    : source.verticalAlignment == OfficeDocument.VerticalAlignment.BOTTOM ? remaining : 0;
                for (OfficeTextLayout.Block block : d.texts) block.y += offset;
            }
        }
        position(d, flow);
        return d;
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
            for (int element = page.elements.size() - 1; element >= 0; element--) {
                Element e = page.elements.get(element);
                if (e.source.image == null) continue;
                RectF bounds = e.bounds;
                if (bounds.right > clippedLeft && bounds.left < clippedRight
                    && page.y + bounds.bottom > clippedTop && page.y + bounds.top < clippedBottom) parts.add(e.source.image);
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
            for (Element e : page.elements) {
                if (e.bounds.bottom >= visibleTop - page.y && e.bounds.top <= visibleBottom - page.y) drawElement(canvas, e, images);
            }
            canvas.restore();
        }
    }

    private void drawElement(Canvas canvas, Element d, Map<String, Bitmap> images) {
        OfficeDocument.Element e = d.source;
        canvas.save(); canvas.concat(d.transform);
        RectF rect = new RectF(0, 0, d.width, d.height);
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
            RectF textBounds = new RectF(rect);
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
            drawTableCellFills(canvas, e, d.cells);
            paint.setColor(0xffb7bec7); paint.setStyle(Paint.Style.STROKE); paint.setStrokeWidth(0.6f);
            for (RectF cell : d.cells) canvas.drawRect(cell, paint);
        }
        for (OfficeTextLayout.Block block : d.texts) {
            canvas.save(); canvas.translate(block.x, block.y); block.layout.draw(canvas); canvas.restore();
        }
        canvas.restore();
    }

    private void drawTableCellFills(Canvas canvas, OfficeDocument.Element e, List<RectF> cells) {
        if (e.cellFills.isEmpty()) return;
        int columns = 0;
        for (List<List<OfficeDocument.Paragraph>> row : e.rows) columns = Math.max(columns, row.size());
        if (columns == 0) return;
        paint.setShader(null); paint.setStyle(Paint.Style.FILL);
        int index = 0;
        for (int row = 0; row < e.rows.size() && index < cells.size(); row++) {
            List<Integer> fills = row < e.cellFills.size() ? e.cellFills.get(row) : Collections.emptyList();
            for (int column = 0; column < columns && index < cells.size(); column++, index++) {
                int fill = column < fills.size() ? fills.get(column) : 0;
                if ((fill >>> 24) == 0) continue;
                paint.setColor(fill);
                canvas.drawRect(cells.get(index), paint);
            }
        }
    }
}
