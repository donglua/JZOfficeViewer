package cn.jingzhuan.lib.office;

import java.util.ArrayList;
import java.util.List;

/** Internal display model. Coordinates and font sizes are in points. */
final class OfficeDocument {
    enum Kind { DOCX, PPTX, XLSX }
    enum Type { TEXT, IMAGE, RECT, ELLIPSE, LINE, TABLE, PATH }
    enum VerticalAlignment { TOP, CENTER, BOTTOM }
    enum LineSpacingRule { AUTO, EXACT, AT_LEAST }
    Kind kind;
    float width = 595;
    final List<Page> pages = new ArrayList<>();
    final List<Element> blocks = new ArrayList<>();
    final List<SpreadsheetDocument.Sheet> sheets = new ArrayList<>();
    final List<SpreadsheetDocument.CellStyle> cellStyles = new ArrayList<>();
    final List<String> warnings = new ArrayList<>();
    // DOCX 页眉页脚与页边距（schemaVersion 9 新增的可选字段）
    final List<Element> headerBlocks = new ArrayList<>();
    final List<Element> footerBlocks = new ArrayList<>();
    float headerDistance, footerDistance;
    float marginTop, marginBottom, marginLeft, marginRight;

    void warn(String message) {
        if (!warnings.contains(message)) warnings.add(message);
    }

    static final class Page {
        float width = 720, height = 405;
        int background = 0xffffffff;
        final List<Element> elements = new ArrayList<>();
    }

    static final class Element {
        Type type = Type.TEXT;
        float x, y, width, height;
        float[] transform = {1, 0, 0, 1, 0, 0};
        float padding = 4;
        int fill = 0x00000000, stroke = 0x00000000;
        float strokeWidth = 1;
        String image;
        float[] imageBounds;
        VerticalAlignment verticalAlignment = VerticalAlignment.TOP;
        boolean textWrap = true;
        final List<Paragraph> paragraphs = new ArrayList<>();
        final List<List<List<Paragraph>>> rows = new ArrayList<>();
        final List<Float> columnWidths = new ArrayList<>();
        final List<List<Integer>> cellFills = new ArrayList<>();
        final List<SpreadsheetDocument.CellRange> merges = new ArrayList<>();
        final List<Path> paths = new ArrayList<>();
        GradientFill fillGradient;
    }

    static final class Path {
        boolean fill, stroke;
        final List<Command> commands = new ArrayList<>();
    }

    static final class Command {
        String op;
        float[] points = new float[0];
    }

    static final class GradientFill {
        int[] colors;
        float[] positions;
        float[] points;
        float[] transform;
    }

    static final class Paragraph {
        final List<Run> runs = new ArrayList<>();
        int alignment;
        float before, after = 6, indent;
        float rightIndent, firstLineIndent;
        LineSpacingRule lineSpacingRule = LineSpacingRule.AUTO;
        float lineSpacing = 1;
        String bullet = "";
    }

    static final class Run {
        String text = "";
        String fontFace = "";
        float size = 12;
        boolean bold, italic, underline;
        int color = 0xff202124;

        Run copy() {
            Run r = new Run();
            r.text = text; r.fontFace = fontFace; r.size = size; r.bold = bold;
            r.italic = italic; r.underline = underline; r.color = color;
            return r;
        }
    }
}
