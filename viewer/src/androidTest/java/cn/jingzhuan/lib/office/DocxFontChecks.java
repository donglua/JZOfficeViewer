package cn.jingzhuan.lib.office;

import static cn.jingzhuan.lib.office.PptxRenderingChecks.check;

import android.content.Context;
import android.graphics.Paint;
import android.graphics.Typeface;
import android.net.Uri;
import android.text.Spanned;
import android.text.TextPaint;
import android.text.style.MetricAffectingSpan;
import java.io.File;

final class DocxFontChecks {
    private DocxFontChecks() { }

    static String run(OfficeInstrumentation instrumentation, PreviewTestActivity activity) throws Exception {
        Context context = instrumentation.getTargetContext();
        String namespace = " xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"";
        String body = "<w:p><w:r><w:t>Monospace: iiii WWWW 0123456789 中文</w:t></w:r></w:p>"
            + "<w:p><w:r><w:rPr>" + family("serif") + "<w:b/><w:i/></w:rPr><w:t>Serif: iiii WWWW 0123456789 中文</w:t></w:r></w:p>"
            + "<w:p><w:r><w:rPr>" + family("Unavailable Office Font") + "</w:rPr><w:t>Missing font: fallback 中文</w:t></w:r></w:p>"
            + "<w:p><w:r><w:rPr><w:rFonts w:ascii=\"monospace\" w:eastAsia=\"serif\"/></w:rPr>"
            + "<w:t>Mixed fonts: fallback 中文</w:t></w:r></w:p>"
            + "<w:p><w:r><w:rPr>" + family("Source Han Sans SC Light") + "<w:b/></w:rPr><w:t>Light bold 中文</w:t></w:r></w:p>";
        File source = CompatibilityChecks.document(context, "fonts", "word/document.xml", new String[][] {
            {"word/document.xml", "<w:document" + namespace + "><w:body>" + body + "</w:body></w:document>"},
            {"word/_rels/document.xml.rels", CompatibilityChecks.relationships("style", "styles", "styles.xml")},
            {"word/styles.xml", "<w:styles" + namespace + "><w:docDefaults><w:rPrDefault><w:rPr>"
                + family("monospace") + "<w:sz w:val=\"32\"/></w:rPr></w:rPrDefault></w:docDefaults></w:styles>"}
        });
        try (OfficePackage pkg = OfficePackage.open(context, Uri.fromFile(source))) {
            OfficeDocument document = pkg.document;
            check(document.blocks.size() == 5, "Font fixture has five paragraphs");
            check("Unavailable Office Font".equals(document.blocks.get(2).paragraphs.get(0).runs.get(0).fontFace), "Missing family is passed to device fallback");
            check(document.blocks.get(3).paragraphs.get(0).runs.get(0).fontFace.isEmpty(), "Mixed-script families retain default fallback");
            check(document.warnings.stream().anyMatch(w -> w.contains("device fonts"))
                && document.warnings.stream().anyMatch(w -> w.contains("Mixed-script")), "Font limitations remain visible");
            instrumentation.runOnMainChecked(() -> {
                TextPaint mono = paint(document.blocks.get(0).paragraphs.get(0));
                check(Math.abs(mono.measureText("iiii") - mono.measureText("WWWW")) < .01f, "Inherited monospace reaches measured text");
                TextPaint serif = paint(document.blocks.get(1).paragraphs.get(0));
                check(serif.measureText("WWWW") > serif.measureText("iiii") + 10, "Explicit serif overrides inherited monospace");
                check(serif.getTypeface().getStyle() == Typeface.BOLD_ITALIC, "Font override preserves bold and italic");
                TextPaint lightBold = paint(document.blocks.get(4).paragraphs.get(0));
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                    check(lightBold.getTypeface().getWeight() >= 700, "Explicit bold is not reduced by light font weight");
                } else {
                    check(lightBold.getTypeface().isBold(), "Explicit bold is preserved before API 28");
                }
            });
            CompatibilityChecks.show(instrumentation, activity, source, "compat-fonts-screen.png");
        } finally { check(source.delete(), "Delete font fixture"); }
        return "PASS DOCX explicit/inherited fonts through JNI, measured Android typefaces and URI preview; mixed/missing fallback retained\n";
    }

    private static String family(String name) {
        return "<w:rFonts w:ascii=\"" + name + "\" w:hAnsi=\"" + name
            + "\" w:eastAsia=\"" + name + "\" w:cs=\"" + name + "\"/>";
    }

    private static TextPaint paint(OfficeDocument.Paragraph paragraph) {
        Spanned text = (Spanned) OfficeTextLayout.paragraph(paragraph, 500).getText();
        TextPaint paint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
        for (MetricAffectingSpan span : text.getSpans(0, 1, MetricAffectingSpan.class)) span.updateMeasureState(paint);
        return paint;
    }
}
