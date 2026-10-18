package cn.jingzhuan.lib.office;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

final class DocumentDecoder {
    static OfficeDocument decode(String json) throws IOException {
        if (json == null) throw new IOException("Invalid core display model");
        try {
            Cursor c = new Cursor(json);
            OfficeDocument document = new OfficeDocument();
            boolean hasVersion = false, hasKind = false, hasWidth = false;
            boolean hasWarnings = false, hasBlocks = false, hasPages = false, hasStyles = false, hasSheets = false;
            int schemaVersion = 0;
            List<RawSheet> rawSheets = new ArrayList<>();
            c.beginObject();
            while (c.hasNext()) {
                String key = c.nextName();
                switch (key) {
                    case "schemaVersion":
                        schemaVersion = c.nextInt();
                        hasVersion = true;
                        break;
                    case "kind":
                        document.kind = OfficeDocument.Kind.valueOf(c.nextString());
                        hasKind = true;
                        break;
                    case "width":
                        document.width = (float) c.nextDouble();
                        hasWidth = true;
                        break;
                    case "warnings":
                        c.beginArray();
                        while (c.hasNext()) document.warn(c.nextString());
                        c.endArray();
                        hasWarnings = true;
                        break;
                    case "blocks":
                        c.beginArray();
                        while (c.hasNext()) document.blocks.add(element(c));
                        c.endArray();
                        hasBlocks = true;
                        break;
                    case "pages":
                        c.beginArray();
                        while (c.hasNext()) document.pages.add(page(c));
                        c.endArray();
                        hasPages = true;
                        break;
                    case "cellStyles":
                        c.beginArray();
                        while (c.hasNext()) {
                            if (document.cellStyles.size() >= 2048) throw new IllegalArgumentException("Too many cell styles");
                            document.cellStyles.add(cellStyle(c));
                        }
                        c.endArray();
                        hasStyles = true;
                        break;
                    case "sheets":
                        c.beginArray();
                        while (c.hasNext()) {
                            if (rawSheets.size() >= 32) throw new IllegalArgumentException("Too many sheets");
                            rawSheets.add(rawSheet(c));
                        }
                        c.endArray();
                        hasSheets = true;
                        break;
                    default:
                        c.skipValue();
                        break;
                }
            }
            c.endObject();
            c.requireEnd();
            if (!hasVersion) throw new IllegalArgumentException("Missing schemaVersion");
            if (schemaVersion != 9) throw new IOException("Unsupported core model version");
            if (!hasKind || !hasWidth || !hasWarnings || !hasBlocks || !hasPages || !hasStyles || !hasSheets) {
                throw new IllegalArgumentException("Missing required document fields");
            }
            if (document.kind == OfficeDocument.Kind.XLSX && (rawSheets.isEmpty() || document.cellStyles.isEmpty())) {
                throw new IllegalArgumentException("Spreadsheet requires at least one sheet and cell style");
            }
            int cellCount = 0, mergeCount = 0;
            int styleCount = document.cellStyles.size();
            for (int i = 0; i < rawSheets.size(); i++) {
                SpreadsheetDocument.Sheet sheet = validateSheet(rawSheets.get(i), styleCount);
                cellCount += sheet.cells.size();
                mergeCount += sheet.merges.size();
                if (cellCount > 50000 || mergeCount > 1000) throw new IllegalArgumentException("Spreadsheet model exceeds limits");
                for (SpreadsheetDocument.Cell cell : sheet.cells) {
                    if (cell.text.length() > SpreadsheetDocument.Cell.MAX_PREVIEW_LENGTH) {
                        document.warn("Long spreadsheet cell text is truncated in the preview");
                        break;
                    }
                }
                document.sheets.add(sheet);
            }
            return document;
        } catch (IOException e) {
            throw e;
        } catch (RuntimeException e) {
            throw new IOException("Invalid core display model", e);
        }
    }

    private static OfficeDocument.Page page(Cursor c) {
        OfficeDocument.Page page = new OfficeDocument.Page();
        boolean hasWidth = false, hasHeight = false, hasBg = false, hasElements = false;
        c.beginObject();
        while (c.hasNext()) {
            switch (c.nextName()) {
                case "width": page.width = (float) c.nextDouble(); hasWidth = true; break;
                case "height": page.height = (float) c.nextDouble(); hasHeight = true; break;
                case "background": page.background = (int) c.nextLong(); hasBg = true; break;
                case "elements":
                    c.beginArray();
                    while (c.hasNext()) page.elements.add(element(c));
                    c.endArray();
                    hasElements = true;
                    break;
                default: c.skipValue(); break;
            }
        }
        c.endObject();
        if (!hasWidth || !hasHeight || !hasBg || !hasElements) throw new IllegalArgumentException("Missing page fields");
        return page;
    }

    private static SpreadsheetDocument.CellStyle cellStyle(Cursor c) {
        SpreadsheetDocument.CellStyle style = new SpreadsheetDocument.CellStyle();
        boolean hasSize = false, hasBold = false, hasItalic = false, hasUnderline = false, hasWrap = false;
        boolean hasColor = false, hasFill = false, hasAlign = false, hasValign = false, hasBorders = false;
        c.beginObject();
        while (c.hasNext()) {
            switch (c.nextName()) {
                case "fontSize":
                    style.fontSize = dimension(c.nextDouble());
                    if (style.fontSize == 0) throw new IllegalArgumentException("Cell font size must be positive");
                    hasSize = true;
                    break;
                case "bold": style.bold = c.nextBoolean(); hasBold = true; break;
                case "italic": style.italic = c.nextBoolean(); hasItalic = true; break;
                case "underline": style.underline = c.nextBoolean(); hasUnderline = true; break;
                case "wrap": style.wrap = c.nextBoolean(); hasWrap = true; break;
                case "color": style.color = (int) c.nextLong(); hasColor = true; break;
                case "fill": style.fill = (int) c.nextLong(); hasFill = true; break;
                case "alignment": style.alignment = indexValue(c.nextDouble(), 4, "alignment"); hasAlign = true; break;
                case "verticalAlignment":
                    style.verticalAlignment = OfficeDocument.VerticalAlignment.valueOf(c.nextString());
                    hasValign = true;
                    break;
                case "borders":
                    c.beginArray();
                    int count = 0;
                    while (c.hasNext()) {
                        if (count >= 4) throw new IllegalArgumentException("Expected four cell borders");
                        if (c.peekNull()) {
                            c.nextNull();
                            style.borders[count] = null;
                        } else {
                            style.borders[count] = (int) c.nextLong();
                        }
                        count++;
                    }
                    c.endArray();
                    if (count != 4) throw new IllegalArgumentException("Expected four cell borders");
                    hasBorders = true;
                    break;
                default: c.skipValue(); break;
            }
        }
        c.endObject();
        if (!hasSize || !hasBold || !hasItalic || !hasUnderline || !hasWrap
            || !hasColor || !hasFill || !hasAlign || !hasValign || !hasBorders) {
            throw new IllegalArgumentException("Missing cellStyle fields");
        }
        return style;
    }

    private static final class RawSheet {
        final SpreadsheetDocument.Sheet sheet = new SpreadsheetDocument.Sheet();
        boolean hasName, hasRows, hasCols, hasCells, hasMerges;
    }

    private static RawSheet rawSheet(Cursor c) {
        RawSheet raw = new RawSheet();
        SpreadsheetDocument.Sheet sheet = raw.sheet;
        c.beginObject();
        while (c.hasNext()) {
            switch (c.nextName()) {
                case "name": sheet.name = c.nextString(); raw.hasName = true; break;
                case "rowHeights": sheet.rowHeights = dimensions(c, 10000); raw.hasRows = true; break;
                case "columnWidths": sheet.columnWidths = dimensions(c, 256); raw.hasCols = true; break;
                case "cells":
                    c.beginArray();
                    while (c.hasNext()) {
                        if (sheet.cells.size() >= 50000) throw new IllegalArgumentException("Too many cells");
                        sheet.cells.add(rawCell(c));
                    }
                    c.endArray();
                    raw.hasCells = true;
                    break;
                case "merges":
                    c.beginArray();
                    while (c.hasNext()) {
                        if (sheet.merges.size() >= 1000) throw new IllegalArgumentException("Too many merged cells");
                        sheet.merges.add(rawMerge(c));
                    }
                    c.endArray();
                    raw.hasMerges = true;
                    break;
                default: c.skipValue(); break;
            }
        }
        c.endObject();
        if (!raw.hasName || !raw.hasRows || !raw.hasCols || !raw.hasCells || !raw.hasMerges) {
            throw new IllegalArgumentException("Missing sheet fields");
        }
        return raw;
    }

    private static SpreadsheetDocument.Cell rawCell(Cursor c) {
        SpreadsheetDocument.Cell cell = new SpreadsheetDocument.Cell();
        boolean hasRow = false, hasCol = false, hasStyle = false, hasText = false, hasNum = false;
        c.beginObject();
        while (c.hasNext()) {
            switch (c.nextName()) {
                case "row": cell.row = nonNegativeInt(c.nextDouble(), "row"); hasRow = true; break;
                case "column": cell.column = nonNegativeInt(c.nextDouble(), "column"); hasCol = true; break;
                case "style": cell.style = nonNegativeInt(c.nextDouble(), "style"); hasStyle = true; break;
                case "text": cell.text = c.nextString(); hasText = true; break;
                case "numeric": cell.numeric = c.nextBoolean(); hasNum = true; break;
                default: c.skipValue(); break;
            }
        }
        c.endObject();
        if (!hasRow || !hasCol || !hasStyle || !hasText || !hasNum) throw new IllegalArgumentException("Missing cell fields");
        return cell;
    }

    private static SpreadsheetDocument.CellRange rawMerge(Cursor c) {
        SpreadsheetDocument.CellRange range = new SpreadsheetDocument.CellRange();
        boolean hasSr = false, hasEr = false, hasSc = false, hasEc = false;
        c.beginObject();
        while (c.hasNext()) {
            switch (c.nextName()) {
                case "startRow": range.startRow = nonNegativeInt(c.nextDouble(), "startRow"); hasSr = true; break;
                case "endRow": range.endRow = nonNegativeInt(c.nextDouble(), "endRow"); hasEr = true; break;
                case "startColumn": range.startColumn = nonNegativeInt(c.nextDouble(), "startColumn"); hasSc = true; break;
                case "endColumn": range.endColumn = nonNegativeInt(c.nextDouble(), "endColumn"); hasEc = true; break;
                default: c.skipValue(); break;
            }
        }
        c.endObject();
        if (!hasSr || !hasEr || !hasSc || !hasEc) throw new IllegalArgumentException("Missing merge fields");
        return range;
    }

    private static SpreadsheetDocument.Sheet validateSheet(RawSheet raw, int styleCount) {
        SpreadsheetDocument.Sheet sheet = raw.sheet;
        int rowLimit = sheet.rowHeights.length, colLimit = sheet.columnWidths.length;
        int previousRow = -1, previousColumn = -1;
        for (int i = 0; i < sheet.cells.size(); i++) {
            SpreadsheetDocument.Cell cell = sheet.cells.get(i);
            if (cell.row >= rowLimit || cell.column >= colLimit || cell.style >= styleCount) {
                throw new IllegalArgumentException("Cell index out of bounds");
            }
            if (cell.row < previousRow || (cell.row == previousRow && cell.column <= previousColumn)) {
                throw new IllegalArgumentException("Cells must have unique coordinates in row order");
            }
            previousRow = cell.row;
            previousColumn = cell.column;
        }
        for (int i = 0; i < sheet.merges.size(); i++) {
            SpreadsheetDocument.CellRange range = sheet.merges.get(i);
            if (range.startRow >= rowLimit || range.endRow >= rowLimit
                || range.startColumn >= colLimit || range.endColumn >= colLimit) {
                throw new IllegalArgumentException("Merge index out of bounds");
            }
            if (range.endRow < range.startRow || range.endColumn < range.startColumn) {
                throw new IllegalArgumentException("Invalid merged cell range");
            }
            for (int j = 0; j < i; j++) {
                SpreadsheetDocument.CellRange previous = sheet.merges.get(j);
                if (range.startRow <= previous.endRow && range.endRow >= previous.startRow
                    && range.startColumn <= previous.endColumn && range.endColumn >= previous.startColumn) {
                    throw new IllegalArgumentException("Overlapping merged cell ranges");
                }
            }
        }
        return sheet;
    }

    private static int nonNegativeInt(double value, String name) {
        if (value < 0 || value > Integer.MAX_VALUE || value != Math.floor(value)) {
            throw new IllegalArgumentException("Invalid " + name);
        }
        return (int) value;
    }

    private static int indexValue(double value, int limit, String name) {
        if (value < 0 || value >= limit || value != Math.floor(value)) {
            throw new IllegalArgumentException("Invalid " + name);
        }
        return (int) value;
    }

    private static float[] dimensions(Cursor c, int limit) {
        c.beginArray();
        float[] temp = new float[Math.min(limit, 64)];
        int size = 0;
        double total = 0;
        while (c.hasNext()) {
            if (size >= limit) throw new IllegalArgumentException("Invalid sheet dimensions");
            if (size == temp.length) {
                float[] next = new float[Math.min(limit, temp.length * 2)];
                System.arraycopy(temp, 0, next, 0, size);
                temp = next;
            }
            float d = dimension(c.nextDouble());
            temp[size++] = d;
            total += d;
        }
        c.endArray();
        if (size == 0 || total >= Float.MAX_VALUE) throw new IllegalArgumentException("Invalid sheet dimensions");
        if (size == temp.length) return temp;
        float[] result = new float[size];
        System.arraycopy(temp, 0, result, 0, size);
        return result;
    }

    private static float dimension(double value) {
        float result = (float) value;
        if (result < 0 || Float.isNaN(result) || Float.isInfinite(result)) {
            throw new IllegalArgumentException("Invalid sheet dimension");
        }
        return result;
    }

    private static OfficeDocument.Element element(Cursor c) {
        OfficeDocument.Element e = new OfficeDocument.Element();
        boolean hasType = false, hasX = false, hasY = false, hasW = false, hasH = false;
        boolean hasPad = false, hasTransform = false, hasFill = false, hasStroke = false;
        boolean hasStrokeW = false, hasValign = false, hasWrap = false;
        c.beginObject();
        while (c.hasNext()) {
            switch (c.nextName()) {
                case "type": e.type = OfficeDocument.Type.valueOf(c.nextString()); hasType = true; break;
                case "x": e.x = (float) c.nextDouble(); hasX = true; break;
                case "y": e.y = (float) c.nextDouble(); hasY = true; break;
                case "width": e.width = (float) c.nextDouble(); hasW = true; break;
                case "height": e.height = (float) c.nextDouble(); hasH = true; break;
                case "padding": e.padding = (float) c.nextDouble(); hasPad = true; break;
                case "transform": e.transform = coordinates(c, 6, 100000); hasTransform = true; break;
                case "fill": e.fill = (int) c.nextLong(); hasFill = true; break;
                case "stroke": e.stroke = (int) c.nextLong(); hasStroke = true; break;
                case "strokeWidth": e.strokeWidth = (float) c.nextDouble(); hasStrokeW = true; break;
                case "fillGradient":
                    if (c.peekNull()) { c.nextNull(); e.fillGradient = null; }
                    else e.fillGradient = gradient(c);
                    break;
                case "verticalAlignment":
                    e.verticalAlignment = OfficeDocument.VerticalAlignment.valueOf(c.nextString());
                    hasValign = true;
                    break;
                case "textWrap": e.textWrap = c.nextBoolean(); hasWrap = true; break;
                case "imageBounds":
                    if (c.peekNull()) {
                        c.nextNull();
                        e.imageBounds = null;
                    } else {
                        e.imageBounds = coordinates(c, 4, 100000000);
                        if (e.imageBounds[0] > e.imageBounds[2] || e.imageBounds[1] > e.imageBounds[3]) {
                            throw new IllegalArgumentException("Invalid image bounds");
                        }
                    }
                    break;
                case "image":
                    if (c.peekNull()) { c.nextNull(); e.image = null; }
                    else e.image = c.nextString();
                    break;
                case "paragraphs":
                    if (c.peekNull()) c.nextNull();
                    else e.paragraphs.addAll(paragraphs(c));
                    break;
                case "columnWidths":
                    if (c.peekNull()) {
                        c.nextNull();
                    } else {
                        c.beginArray();
                        while (c.hasNext()) e.columnWidths.add((float) c.nextDouble());
                        c.endArray();
                    }
                    break;
                case "paths":
                    if (c.peekNull()) {
                        c.nextNull();
                    } else {
                        c.beginArray();
                        while (c.hasNext()) {
                            if (e.paths.size() >= 32) throw new IllegalArgumentException("Too many custom paths");
                            e.paths.add(path(c));
                        }
                        c.endArray();
                    }
                    break;
                case "rows":
                    if (c.peekNull()) {
                        c.nextNull();
                    } else {
                        c.beginArray();
                        while (c.hasNext()) {
                            List<List<OfficeDocument.Paragraph>> row = new ArrayList<>();
                            c.beginArray();
                            while (c.hasNext()) row.add(paragraphs(c));
                            c.endArray();
                            e.rows.add(row);
                        }
                        c.endArray();
                    }
                    break;
                case "cellFills":
                    if (c.peekNull()) {
                        c.nextNull();
                    } else {
                        c.beginArray();
                        while (c.hasNext()) {
                            List<Integer> row = new ArrayList<>();
                            c.beginArray();
                            while (c.hasNext()) row.add((int) c.nextLong());
                            c.endArray();
                            e.cellFills.add(row);
                        }
                        c.endArray();
                    }
                    break;
                default: c.skipValue(); break;
            }
        }
        c.endObject();
        if (!hasType || !hasX || !hasY || !hasW || !hasH || !hasPad || !hasTransform
            || !hasFill || !hasStroke || !hasStrokeW || !hasValign || !hasWrap) {
            throw new IllegalArgumentException("Missing required element fields");
        }
        if (!e.cellFills.isEmpty()) {
            if (e.cellFills.size() != e.rows.size()) throw new IllegalArgumentException("Invalid table fill rows");
            for (int i = 0; i < e.cellFills.size(); i++) {
                if (e.cellFills.get(i).size() != e.rows.get(i).size()) {
                    throw new IllegalArgumentException("Invalid table fill columns");
                }
            }
        }
        return e;
    }

    private static OfficeDocument.Path path(Cursor c) {
        OfficeDocument.Path path = new OfficeDocument.Path();
        boolean hasFill = false, hasStroke = false, hasCommands = false;
        c.beginObject();
        while (c.hasNext()) {
            switch (c.nextName()) {
                case "fill": path.fill = c.nextBoolean(); hasFill = true; break;
                case "stroke": path.stroke = c.nextBoolean(); hasStroke = true; break;
                case "commands":
                    c.beginArray();
                    while (c.hasNext()) {
                        if (path.commands.size() >= 10000) throw new IllegalArgumentException("Invalid custom path commands");
                        path.commands.add(command(c));
                    }
                    c.endArray();
                    if (path.commands.isEmpty()) throw new IllegalArgumentException("Invalid custom path commands");
                    hasCommands = true;
                    break;
                default: c.skipValue(); break;
            }
        }
        c.endObject();
        if (!hasFill || !hasStroke || !hasCommands) throw new IllegalArgumentException("Missing path fields");
        return path;
    }

    private static OfficeDocument.Command command(Cursor c) {
        OfficeDocument.Command command = new OfficeDocument.Command();
        boolean hasOp = false, hasPoints = false;
        List<Float> rawPoints = null;
        c.beginObject();
        while (c.hasNext()) {
            switch (c.nextName()) {
                case "op": command.op = c.nextString(); hasOp = true; break;
                case "points":
                    if (c.peekNull()) {
                        c.nextNull();
                    } else {
                        rawPoints = new ArrayList<>(6);
                        c.beginArray();
                        while (c.hasNext()) {
                            double value = c.nextDouble();
                            if (Double.isNaN(value) || Double.isInfinite(value) || Math.abs(value) > 100000) {
                                throw new IllegalArgumentException("Invalid custom path coordinate");
                            }
                            rawPoints.add((float) value);
                        }
                        c.endArray();
                        hasPoints = true;
                    }
                    break;
                default: c.skipValue(); break;
            }
        }
        c.endObject();
        if (!hasOp) throw new IllegalArgumentException("Missing command op");
        int expected = command.op.equals("MOVE") || command.op.equals("LINE") ? 2
            : command.op.equals("QUAD") ? 4 : command.op.equals("CUBIC") ? 6 : 0;
        if (expected == 0) {
            if (!command.op.equals("CLOSE") || hasPoints) throw new IllegalArgumentException("Invalid custom path command");
        } else {
            if (rawPoints == null || rawPoints.size() != expected) throw new IllegalArgumentException("Invalid custom path points");
            command.points = new float[expected];
            for (int i = 0; i < expected; i++) command.points[i] = rawPoints.get(i);
        }
        return command;
    }

    private static OfficeDocument.GradientFill gradient(Cursor c) {
        OfficeDocument.GradientFill gradient = new OfficeDocument.GradientFill();
        List<Integer> colors = null;
        List<Float> positions = null;
        boolean hasPoints = false;
        c.beginObject();
        while (c.hasNext()) {
            switch (c.nextName()) {
                case "colors":
                    colors = new ArrayList<>();
                    c.beginArray();
                    while (c.hasNext()) {
                        if (colors.size() >= 16) throw new IllegalArgumentException("Invalid gradient stops");
                        colors.add((int) c.nextLong());
                    }
                    c.endArray();
                    break;
                case "positions":
                    positions = new ArrayList<>();
                    c.beginArray();
                    while (c.hasNext()) {
                        if (positions.size() >= 16) throw new IllegalArgumentException("Invalid gradient stops");
                        float pos = (float) c.nextDouble();
                        if (Float.isNaN(pos) || pos < 0 || pos > 1
                            || (!positions.isEmpty() && pos < positions.get(positions.size() - 1))) {
                            throw new IllegalArgumentException("Invalid gradient position");
                        }
                        positions.add(pos);
                    }
                    c.endArray();
                    break;
                case "points":
                    gradient.points = coordinates(c, 4, 200000);
                    hasPoints = true;
                    break;
                case "transform":
                    if (c.peekNull()) { c.nextNull(); gradient.transform = null; }
                    else gradient.transform = coordinates(c, 6, Float.MAX_VALUE);
                    break;
                default: c.skipValue(); break;
            }
        }
        c.endObject();
        if (colors == null || positions == null || !hasPoints
            || colors.size() < 2 || colors.size() != positions.size()) {
            throw new IllegalArgumentException("Invalid gradient stops");
        }
        gradient.colors = new int[colors.size()];
        gradient.positions = new float[positions.size()];
        for (int i = 0; i < colors.size(); i++) {
            gradient.colors[i] = colors.get(i);
            gradient.positions[i] = positions.get(i);
        }
        return gradient;
    }

    private static float[] coordinates(Cursor c, int count, float limit) {
        c.beginArray();
        float[] result = new float[count];
        int index = 0;
        while (c.hasNext()) {
            if (index >= count) throw new IllegalArgumentException("Invalid geometry coordinate count");
            double value = c.nextDouble();
            if (Double.isNaN(value) || Double.isInfinite(value) || Math.abs(value) > limit) {
                throw new IllegalArgumentException("Invalid geometry coordinate");
            }
            result[index++] = (float) value;
        }
        c.endArray();
        if (index != count) throw new IllegalArgumentException("Invalid geometry coordinate count");
        return result;
    }

    private static List<OfficeDocument.Paragraph> paragraphs(Cursor c) {
        List<OfficeDocument.Paragraph> paragraphs = new ArrayList<>();
        c.beginArray();
        while (c.hasNext()) {
            OfficeDocument.Paragraph p = new OfficeDocument.Paragraph();
            boolean hasAlign = false, hasBefore = false, hasAfter = false, hasIndent = false;
            boolean hasRight = false, hasFirst = false, hasRule = false, hasSpacing = false, hasRuns = false;
            c.beginObject();
            while (c.hasNext()) {
                switch (c.nextName()) {
                    case "alignment": p.alignment = c.nextInt(); hasAlign = true; break;
                    case "before": p.before = (float) c.nextDouble(); hasBefore = true; break;
                    case "after": p.after = (float) c.nextDouble(); hasAfter = true; break;
                    case "indent": p.indent = (float) c.nextDouble(); hasIndent = true; break;
                    case "rightIndent": p.rightIndent = (float) c.nextDouble(); hasRight = true; break;
                    case "firstLineIndent": p.firstLineIndent = (float) c.nextDouble(); hasFirst = true; break;
                    case "lineSpacingRule":
                        p.lineSpacingRule = OfficeDocument.LineSpacingRule.valueOf(c.nextString());
                        hasRule = true;
                        break;
                    case "lineSpacing": p.lineSpacing = (float) c.nextDouble(); hasSpacing = true; break;
                    case "bullet":
                        if (c.peekNull()) { c.nextNull(); p.bullet = ""; }
                        else p.bullet = c.nextString();
                        break;
                    case "runs":
                        c.beginArray();
                        while (c.hasNext()) p.runs.add(run(c));
                        c.endArray();
                        hasRuns = true;
                        break;
                    default: c.skipValue(); break;
                }
            }
            c.endObject();
            if (!hasAlign || !hasBefore || !hasAfter || !hasIndent || !hasRight
                || !hasFirst || !hasRule || !hasSpacing || !hasRuns) {
                throw new IllegalArgumentException("Missing paragraph fields");
            }
            paragraphs.add(p);
        }
        c.endArray();
        return paragraphs;
    }

    private static OfficeDocument.Run run(Cursor c) {
        OfficeDocument.Run r = new OfficeDocument.Run();
        boolean hasText = false, hasSize = false, hasBold = false, hasItalic = false, hasUnderline = false, hasColor = false;
        c.beginObject();
        while (c.hasNext()) {
            switch (c.nextName()) {
                case "text": r.text = c.nextString(); hasText = true; break;
                case "size": r.size = (float) c.nextDouble(); hasSize = true; break;
                case "fontFace":
                    if (c.peekNull()) { c.nextNull(); r.fontFace = ""; }
                    else r.fontFace = c.nextString();
                    break;
                case "bold": r.bold = c.nextBoolean(); hasBold = true; break;
                case "italic": r.italic = c.nextBoolean(); hasItalic = true; break;
                case "underline": r.underline = c.nextBoolean(); hasUnderline = true; break;
                case "color": r.color = (int) c.nextLong(); hasColor = true; break;
                default: c.skipValue(); break;
            }
        }
        c.endObject();
        if (!hasText || !hasSize || !hasBold || !hasItalic || !hasUnderline || !hasColor) {
            throw new IllegalArgumentException("Missing run fields");
        }
        return r;
    }

    /** Zero-DOM single-pass JSON cursor over a String. */
    private static final class Cursor {
        private final String s;
        private final int len;
        private int pos;
        private boolean expectComma;
        private final StringBuilder sb = new StringBuilder(64);

        Cursor(String s) {
            this.s = s;
            this.len = s.length();
        }

        private void skipWhitespace() {
            while (pos < len) {
                char ch = s.charAt(pos);
                if (ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t') pos++;
                else break;
            }
        }

        void beginObject() {
            skipWhitespace();
            if (pos >= len || s.charAt(pos) != '{') throw new IllegalArgumentException("Expected '{'");
            pos++;
            expectComma = false;
        }

        void endObject() {
            skipWhitespace();
            if (pos >= len || s.charAt(pos) != '}') throw new IllegalArgumentException("Expected '}'");
            pos++;
            expectComma = true;
        }

        void beginArray() {
            skipWhitespace();
            if (pos >= len || s.charAt(pos) != '[') throw new IllegalArgumentException("Expected '['");
            pos++;
            expectComma = false;
        }

        void endArray() {
            skipWhitespace();
            if (pos >= len || s.charAt(pos) != ']') throw new IllegalArgumentException("Expected ']'");
            pos++;
            expectComma = true;
        }

        boolean hasNext() {
            skipWhitespace();
            if (pos >= len) throw new IllegalArgumentException("Unexpected end of JSON");
            char ch = s.charAt(pos);
            if (ch == '}' || ch == ']') return false;
            if (expectComma) {
                if (ch != ',') throw new IllegalArgumentException("Expected ','");
                pos++;
                skipWhitespace();
                if (pos >= len) throw new IllegalArgumentException("Unexpected end of JSON");
                char next = s.charAt(pos);
                if (next == '}' || next == ']') throw new IllegalArgumentException("Trailing comma");
            }
            return true;
        }

        String nextName() {
            String name = readString();
            skipWhitespace();
            if (pos >= len || s.charAt(pos) != ':') throw new IllegalArgumentException("Expected ':'");
            pos++;
            expectComma = false;
            return name;
        }

        boolean peekNull() {
            skipWhitespace();
            return pos + 4 <= len && s.charAt(pos) == 'n'
                && s.charAt(pos + 1) == 'u' && s.charAt(pos + 2) == 'l' && s.charAt(pos + 3) == 'l';
        }

        void nextNull() {
            if (!peekNull()) throw new IllegalArgumentException("Expected null");
            pos += 4;
            expectComma = true;
        }

        boolean nextBoolean() {
            skipWhitespace();
            if (pos + 4 <= len && s.startsWith("true", pos)) {
                pos += 4;
                expectComma = true;
                return true;
            }
            if (pos + 5 <= len && s.startsWith("false", pos)) {
                pos += 5;
                expectComma = true;
                return false;
            }
            throw new IllegalArgumentException("Expected boolean");
        }

        String nextString() {
            String value = readString();
            expectComma = true;
            return value;
        }

        private String readString() {
            skipWhitespace();
            if (pos >= len || s.charAt(pos) != '"') throw new IllegalArgumentException("Expected string");
            int start = ++pos;
            while (pos < len) {
                char ch = s.charAt(pos);
                if (ch == '"') {
                    return s.substring(start, pos++);
                }
                if (ch == '\\') {
                    return readEscapedString(start);
                }
                if (ch < 0x20) throw new IllegalArgumentException("Unescaped control char");
                pos++;
            }
            throw new IllegalArgumentException("Unterminated string");
        }

        private String readEscapedString(int start) {
            sb.setLength(0);
            sb.append(s, start, pos);
            while (pos < len) {
                char ch = s.charAt(pos++);
                if (ch == '"') return sb.toString();
                if (ch != '\\') {
                    if (ch < 0x20) throw new IllegalArgumentException("Unescaped control char");
                    sb.append(ch);
                    continue;
                }
                if (pos >= len) throw new IllegalArgumentException("Unterminated escape");
                char esc = s.charAt(pos++);
                switch (esc) {
                    case '"': case '\\': case '/': sb.append(esc); break;
                    case 'b': sb.append('\b'); break;
                    case 'f': sb.append('\f'); break;
                    case 'n': sb.append('\n'); break;
                    case 'r': sb.append('\r'); break;
                    case 't': sb.append('\t'); break;
                    case 'u':
                        if (pos + 4 > len) throw new IllegalArgumentException("Invalid unicode escape");
                        int code = Integer.parseInt(s.substring(pos, pos + 4), 16);
                        sb.append((char) code);
                        pos += 4;
                        break;
                    default:
                        throw new IllegalArgumentException("Invalid escape");
                }
            }
            throw new IllegalArgumentException("Unterminated string");
        }

        double nextDouble() {
            skipWhitespace();
            int start = pos;
            if (pos < len && (s.charAt(pos) == '-' || s.charAt(pos) == '+')) pos++;
            int digits = 0;
            while (pos < len && isDigit(s.charAt(pos))) { pos++; digits++; }
            if (pos < len && s.charAt(pos) == '.') {
                pos++;
                while (pos < len && isDigit(s.charAt(pos))) { pos++; digits++; }
            }
            if (digits == 0) throw new IllegalArgumentException("Expected number");
            if (pos < len && (s.charAt(pos) == 'e' || s.charAt(pos) == 'E')) {
                pos++;
                if (pos < len && (s.charAt(pos) == '+' || s.charAt(pos) == '-')) pos++;
                int expDigits = 0;
                while (pos < len && isDigit(s.charAt(pos))) { pos++; expDigits++; }
                if (expDigits == 0) throw new IllegalArgumentException("Invalid exponent");
            }
            double val = Double.parseDouble(s.substring(start, pos));
            if (Double.isNaN(val) || Double.isInfinite(val)) throw new IllegalArgumentException("Non-finite number");
            expectComma = true;
            return val;
        }

        long nextLong() {
            double val = nextDouble();
            if (val != Math.floor(val) || val < Long.MIN_VALUE || val > Long.MAX_VALUE) {
                throw new IllegalArgumentException("Expected integer");
            }
            return (long) val;
        }

        int nextInt() {
            long val = nextLong();
            if (val < Integer.MIN_VALUE || val > Integer.MAX_VALUE) {
                throw new IllegalArgumentException("Integer overflow");
            }
            return (int) val;
        }

        void skipValue() {
            skipWhitespace();
            if (pos >= len) throw new IllegalArgumentException("Unexpected end of JSON");
            char ch = s.charAt(pos);
            if (ch == '"') {
                nextString();
            } else if (ch == '{') {
                beginObject();
                while (hasNext()) {
                    nextName();
                    skipValue();
                }
                endObject();
            } else if (ch == '[') {
                beginArray();
                while (hasNext()) {
                    skipValue();
                }
                endArray();
            } else if (ch == 't' || ch == 'f') {
                nextBoolean();
            } else if (ch == 'n') {
                nextNull();
            } else {
                nextDouble();
            }
        }

        void requireEnd() {
            skipWhitespace();
            if (pos != len) throw new IllegalArgumentException("Trailing content after root JSON object");
        }

        private static boolean isDigit(char c) {
            return c >= '0' && c <= '9';
        }
    }
}
