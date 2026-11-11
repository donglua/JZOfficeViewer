package cn.jingzhuan.lib.office;

import android.graphics.Paint;
import android.graphics.Typeface;
import android.text.Layout;
import android.text.SpannableStringBuilder;
import android.text.Spanned;
import android.text.StaticLayout;
import android.text.TextPaint;
import android.text.style.AbsoluteSizeSpan;
import android.text.style.BackgroundColorSpan;
import android.text.style.ForegroundColorSpan;
import android.text.style.LineHeightSpan;
import android.text.style.MetricAffectingSpan;
import android.text.style.StrikethroughSpan;
import android.text.style.StyleSpan;
import android.text.style.UnderlineSpan;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

final class OfficeTextLayout {
    static final class Block {
        StaticLayout layout;
        float x, y;
        int background;
        int borderTop, borderBottom, borderLeft, borderRight;
        float borderWidth;
    }

    static float append(List<OfficeDocument.Paragraph> paragraphs, float x, float y, float width, List<Block> out, boolean pptx) {
        return append(paragraphs, x, y, width, out, pptx, true);
    }

    static float append(List<OfficeDocument.Paragraph> paragraphs, float x, float y, float width, List<Block> out, boolean pptx, boolean wrap) {
        for (OfficeDocument.Paragraph paragraph : paragraphs) {
            y += Math.max(0, paragraph.before);
            Block block = new Block();
            block.x = x; block.y = y;
            block.background = paragraph.background;
            block.borderTop = paragraph.borderTop;
            block.borderBottom = paragraph.borderBottom;
            block.borderLeft = paragraph.borderLeft;
            block.borderRight = paragraph.borderRight;
            block.borderWidth = paragraph.borderWidth;
            block.layout = paragraph(paragraph, width, pptx, wrap);
            if (!wrap) {
                float extra = Math.max(1, (int) width) - block.layout.getWidth();
                block.x += paragraph.alignment == 1 ? extra / 2 : paragraph.alignment == 2 ? extra : 0;
            }
            if (out != null) out.add(block);
            y += block.layout.getHeight() + Math.max(0, paragraph.after);
        }
        return y;
    }

    static float measure(List<OfficeDocument.Paragraph> paragraphs, float width, boolean pptx) {
        return append(paragraphs, 0, 0, width, null, pptx, true);
    }

    static StaticLayout paragraph(OfficeDocument.Paragraph paragraph, float width) {
        return paragraph(paragraph, width, false, true);
    }

    private static StaticLayout paragraph(OfficeDocument.Paragraph paragraph, float width, boolean pptx, boolean wrap) {
        SpannableStringBuilder text = new SpannableStringBuilder(paragraph.bullet);
        for (OfficeDocument.Run run : paragraph.runs) {
            int start = text.length(); text.append(run.text);
            if (start == text.length()) continue;
            int flags = Spanned.SPAN_EXCLUSIVE_EXCLUSIVE;
            text.setSpan(pptx ? new FontSize(run.size) : new AbsoluteSizeSpan(Math.max(1, Math.round(run.size))),
                start, text.length(), flags);
            text.setSpan(new ForegroundColorSpan(run.color), start, text.length(), flags);
            if (run.background != 0) {
                text.setSpan(new BackgroundColorSpan(run.background), start, text.length(), flags);
            }
            int style = (run.bold ? Typeface.BOLD : 0) | (run.italic ? Typeface.ITALIC : 0);
            if (!run.fontFace.isEmpty() || run.weight > 0) {
                text.setSpan(new FontFace(run.fontFace, style, run.weight), start, text.length(), flags);
            } else if (style != 0) {
                text.setSpan(new StyleSpan(style), start, text.length(), flags);
            }
            if (run.underline) text.setSpan(new UnderlineSpan(), start, text.length(), flags);
            if (run.strike) text.setSpan(new StrikethroughSpan(), start, text.length(), flags);
            if ("superscript".equals(run.vertAlign) || "subscript".equals(run.vertAlign)) {
                text.setSpan(new ScriptSpan("superscript".equals(run.vertAlign)), start, text.length(), flags);
            }
            if (run.spacing != 0) {
                text.setSpan(new LetterSpacingSpan(run.spacing), start, text.length(), flags);
            }
        }
        if (text.length() == 0) text.append(" ");
        TextPaint font = new TextPaint(Paint.ANTI_ALIAS_FLAG);
        font.setTextSize(paragraph.runs.isEmpty() ? 12 : paragraph.runs.get(0).size);
        font.setColor(0xff202124);
        Layout.Alignment align = paragraph.alignment == 1 ? Layout.Alignment.ALIGN_CENTER
            : paragraph.alignment == 2 ? Layout.Alignment.ALIGN_OPPOSITE : Layout.Alignment.ALIGN_NORMAL;
        int layoutWidth = Math.max(1, (int) width);
        int right = Math.max(0, Math.min(layoutWidth - 1, Math.round(paragraph.rightIndent)));
        int rest = Math.max(0, Math.min(layoutWidth - right - 1, Math.round(paragraph.indent)));
        int first = Math.max(0, Math.min(layoutWidth - right - 1, Math.round(paragraph.indent + paragraph.firstLineIndent)));
        if (!wrap) {
            layoutWidth = Math.max(layoutWidth,
                (int) Math.ceil(Layout.getDesiredWidth(text, font) + Math.max(first, rest) + right));
        }
        StaticLayout.Builder builder = StaticLayout.Builder.obtain(text, 0, text.length(), font, layoutWidth)
            .setAlignment(align).setIncludePad(false)
            .setIndents(new int[] {first, rest}, new int[] {right});
        if (paragraph.alignment == 3 && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            builder.setJustificationMode(Layout.JUSTIFICATION_MODE_INTER_WORD);
        }
        if (paragraph.lineSpacingRule == OfficeDocument.LineSpacingRule.AUTO) {
            if (pptx && paragraph.lineSpacing != 1) {
                text.setSpan(new PptxLineHeight(font, paragraph.lineSpacing),
                    0, text.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            } else builder.setLineSpacing(0, paragraph.lineSpacing);
        } else {
            text.setSpan(new FixedLineHeight(paragraph.lineSpacing,
                paragraph.lineSpacingRule == OfficeDocument.LineSpacingRule.EXACT),
                0, text.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        }
        return builder.build();
    }

    private static final Map<String, Typeface> TYPEFACE_CACHE =
        new LinkedHashMap<String, Typeface>(64, 0.75f, true) {
            @Override protected boolean removeEldestEntry(Map.Entry<String, Typeface> eldest) {
                return size() > 64;
            }
        };

    static Typeface resolveTypeface(String face, int style, int weight) {
        String cleanFace = face == null ? "" : face.trim();
        String key = cleanFace + "#" + style + "#" + weight;
        synchronized (TYPEFACE_CACHE) {
            Typeface cached = TYPEFACE_CACHE.get(key);
            if (cached != null) return cached;
            Typeface tf = createTypeface(cleanFace, style, weight);
            TYPEFACE_CACHE.put(key, tf);
            return tf;
        }
    }

    private static Typeface createTypeface(String face, int style, int weight) {
        String target;
        String lower = face.toLowerCase(java.util.Locale.ROOT);
        if (face.isEmpty()) {
            target = null;
        } else if ("impact".equals(lower)) {
            target = "sans-serif-condensed";
            style |= Typeface.BOLD;
        } else if (containsAny(lower, "song", "宋体", "times new roman", "times", "georgia", "cambria", "fangsong", "仿宋", "mincho", "细明体", "pmingliu")) {
            target = "serif";
        } else if (containsAny(lower, "mono", "courier", "consolas", "menlo", "monaco", "lucida console")) {
            target = "monospace";
        } else if (containsAny(lower, "kai", "楷体", "comic sans", "casual", "cursive")) {
            target = "cursive";
        } else if (weight == 300 || lower.contains("light")) {
            target = "sans-serif-light";
        } else if (weight == 500 || lower.contains("medium")) {
            target = "sans-serif-medium";
        } else if (weight >= 800 || lower.contains("black") || lower.contains("heavy")) {
            target = "sans-serif-black";
        } else {
            target = face;
        }

        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P && weight > 0) {
            Typeface base = target == null ? Typeface.DEFAULT : Typeface.create(target, Typeface.NORMAL);
            return Typeface.create(base, weight, (style & Typeface.ITALIC) != 0);
        } else {
            return target == null ? Typeface.defaultFromStyle(style) : Typeface.create(target, style);
        }
    }

    private static boolean containsAny(String str, String... keywords) {
        for (String kw : keywords) {
            if (str.contains(kw)) return true;
        }
        return false;
    }

    private static final class FontSize extends MetricAffectingSpan {
        private final float size;

        FontSize(float size) { this.size = Math.max(1, size); }

        @Override public void updateMeasureState(TextPaint paint) { paint.setTextSize(size); }
        @Override public void updateDrawState(TextPaint paint) { paint.setTextSize(size); }
    }

    private static final class FontFace extends MetricAffectingSpan {
        private final Typeface typeface;

        FontFace(String face, int style) {
            this(face, style, 0);
        }

        FontFace(String face, int style, int weight) {
            typeface = resolveTypeface(face, style, weight);
        }

        @Override public void updateMeasureState(TextPaint paint) { paint.setTypeface(typeface); }
        @Override public void updateDrawState(TextPaint paint) { paint.setTypeface(typeface); }
    }

    private static final class ScriptSpan extends MetricAffectingSpan {
        private final boolean superscript;

        ScriptSpan(boolean superscript) { this.superscript = superscript; }

        @Override public void updateMeasureState(TextPaint p) { apply(p); }
        @Override public void updateDrawState(TextPaint p) { apply(p); }

        private void apply(TextPaint p) {
            p.setTextSize(Math.max(1f, p.getTextSize() * 0.65f));
            if (superscript) {
                p.baselineShift += (int) (p.ascent() * 0.35f);
            } else {
                p.baselineShift -= (int) (p.descent() * 0.35f);
            }
        }
    }

    private static final class LetterSpacingSpan extends MetricAffectingSpan {
        private final float spacingPt;

        LetterSpacingSpan(float spacingPt) { this.spacingPt = spacingPt; }

        @Override public void updateMeasureState(TextPaint p) {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.LOLLIPOP) {
                p.setLetterSpacing(spacingPt / Math.max(1f, p.getTextSize()));
            }
        }

        @Override public void updateDrawState(TextPaint p) {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.LOLLIPOP) {
                p.setLetterSpacing(spacingPt / Math.max(1f, p.getTextSize()));
            }
        }
    }

    private static final class PptxLineHeight implements LineHeightSpan {
        private final TextPaint base;
        private final float spacing;

        PptxLineHeight(TextPaint base, float spacing) { this.base = new TextPaint(base); this.spacing = spacing; }

        @Override public void chooseHeight(CharSequence text, int start, int end, int spanStartY, int lineTop, Paint.FontMetricsInt metrics) {
            float size = 0;
            int ascent = 0, descent = 0;
            TextPaint font = new TextPaint(base);
            Spanned spans = text instanceof Spanned ? (Spanned) text : null;
            // StaticLayout can reuse metrics already changed by a previous line.
            for (int offset = start; offset < end;) {
                int next = spans == null ? end : spans.nextSpanTransition(offset, end, MetricAffectingSpan.class);
                font.set(base);
                if (spans != null) {
                    for (MetricAffectingSpan span : spans.getSpans(offset, next, MetricAffectingSpan.class)) {
                        span.updateMeasureState(font);
                    }
                }
                Paint.FontMetricsInt natural = font.getFontMetricsInt();
                ascent = Math.min(ascent, natural.ascent); descent = Math.max(descent, natural.descent);
                size = Math.max(size, font.getTextSize());
                offset = next;
            }
            if (size == 0) {
                Paint.FontMetricsInt natural = base.getFontMetricsInt();
                ascent = natural.ascent; descent = natural.descent; size = base.getTextSize();
            }
            int natural = descent - ascent;
            // DrawingML leading belongs to the whole line box, including a single line.
            int extra = Math.max(1, Math.round(Math.max(natural, size * 1.2f) * spacing)) - natural;
            metrics.ascent = ascent - (extra - extra / 2);
            metrics.descent = descent + extra / 2;
            metrics.top = metrics.ascent; metrics.bottom = metrics.descent;
        }
    }

    private static final class FixedLineHeight implements LineHeightSpan {
        private final int height;
        private final boolean exact;

        FixedLineHeight(float height, boolean exact) {
            this.height = Math.max(1, Math.round(height)); this.exact = exact;
        }

        @Override public void chooseHeight(CharSequence text, int start, int end, int spanStartY, int lineTop, Paint.FontMetricsInt metrics) {
            int natural = Math.max(1, metrics.descent - metrics.ascent);
            if (!exact && natural >= height) return;
            int descent = Math.round(metrics.descent * (float) height / natural);
            metrics.descent = metrics.bottom = descent;
            metrics.ascent = metrics.top = descent - height;
        }
    }
}
