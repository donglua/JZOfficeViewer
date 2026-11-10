package cn.jingzhuan.lib.office;

import android.graphics.Paint;
import android.graphics.Typeface;
import android.text.Layout;
import android.text.SpannableStringBuilder;
import android.text.Spanned;
import android.text.StaticLayout;
import android.text.TextPaint;
import android.text.style.AbsoluteSizeSpan;
import android.text.style.ForegroundColorSpan;
import android.text.style.LineHeightSpan;
import android.text.style.MetricAffectingSpan;
import android.text.style.StyleSpan;
import android.text.style.UnderlineSpan;
import java.util.List;

final class OfficeTextLayout {
    static final class Block {
        StaticLayout layout;
        float x, y;
    }

    static float append(List<OfficeDocument.Paragraph> paragraphs, float x, float y, float width, List<Block> out, boolean pptx) {
        return append(paragraphs, x, y, width, out, pptx, true);
    }

    static float append(List<OfficeDocument.Paragraph> paragraphs, float x, float y, float width, List<Block> out, boolean pptx, boolean wrap) {
        for (OfficeDocument.Paragraph paragraph : paragraphs) {
            y += Math.max(0, paragraph.before);
            Block block = new Block();
            block.x = x; block.y = y;
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
            int style = (run.bold ? Typeface.BOLD : 0) | (run.italic ? Typeface.ITALIC : 0);
            if (!run.fontFace.isEmpty()) text.setSpan(new FontFace(run.fontFace, style), start, text.length(), flags);
            else if (style != 0) text.setSpan(new StyleSpan(style), start, text.length(), flags);
            if (run.underline) text.setSpan(new UnderlineSpan(), start, text.length(), flags);
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

    private static final class FontSize extends MetricAffectingSpan {
        private final float size;

        FontSize(float size) { this.size = Math.max(1, size); }

        @Override public void updateMeasureState(TextPaint paint) { paint.setTextSize(size); }
        @Override public void updateDrawState(TextPaint paint) { paint.setTextSize(size); }
    }

    private static final class FontFace extends MetricAffectingSpan {
        private final Typeface typeface;

        FontFace(String face, int style) {
            if ("Impact".equalsIgnoreCase(face)) {
                face = "sans-serif-condensed";
                style |= Typeface.BOLD;
            } else if ("思源黑体 CN Light".equals(face) || "Source Han Sans CN Light".equals(face)
                || "Source Han Sans SC Light".equals(face) || "Noto Sans CJK SC Light".equals(face)) {
                face = "sans-serif-light";
            }
            typeface = Typeface.create(face, style);
        }

        @Override public void updateMeasureState(TextPaint paint) { paint.setTypeface(typeface); }
        @Override public void updateDrawState(TextPaint paint) { paint.setTypeface(typeface); }
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
